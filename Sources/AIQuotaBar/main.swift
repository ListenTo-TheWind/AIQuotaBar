import AppKit
import Foundation
import SwiftUI

private let logURL = URL(fileURLWithPath: "/tmp/aiq-state.log")
private func log(_ message: String) {
    let line = "[\(ISO8601DateFormatter().string(from: .now))] \(message)\n"
    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: logURL.path), let handle = try? FileHandle(forWritingTo: logURL) {
            _ = try? handle.seekToEnd(); try? handle.write(contentsOf: data); try? handle.close()
        } else { try? data.write(to: logURL) }
    }
}

@main
struct AIQuotaBar {
    @MainActor private static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        app.run()
    }
}

struct Quota: Codable, Equatable, Sendable {
    let fiveHourRemaining: Double?
    let weeklyRemaining: Double?
    let updatedAt: Date

    static let unavailable = Quota(fiveHourRemaining: nil, weeklyRemaining: nil, updatedAt: .distantPast)
}

protocol QuotaProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    func fetch(completion: @escaping @Sendable (Result<Quota, Error>) -> Void)
}

/// Reads the latest actual Codex `rate_limits` payload from local session JSONL files.
/// Session content stays on this Mac; no Codex request is made from the quota bar.
final class CodexProvider: QuotaProvider, @unchecked Sendable {
    let id = "codex"
    let displayName = "Codex"

    func fetch(completion: @escaping @Sendable (Result<Quota, Error>) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let sessions = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex/sessions")
            let enumerator = FileManager.default.enumerator(at: sessions, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])
            var candidates: [(URL, Date)] = []
            while let url = enumerator?.nextObject() as? URL {
                guard url.pathExtension == "jsonl" else { continue }
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                candidates.append((url, date))
            }
            for (url, _) in candidates.sorted(by: { $0.1 > $1.1 }).prefix(12) {
                guard let text = try? String(contentsOf: url), let last = text.split(separator: "\n").reversed().first(where: { $0.contains("rate_limits") }), let data = last.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data), let limits = findDictionary(named: "rate_limits", in: json) else { continue }
                let windows = [limits["primary"], limits["secondary"]].compactMap { $0 as? [String: Any] }
                let weekly = remaining(forWindowNear: 10_080, in: windows)
                    ?? windows.compactMap(remaining(in:)).first
                let fiveHour = windows
                    .filter { number($0["window_minutes"]) ?? 0 >= 300 && number($0["window_minutes"]) ?? 0 < 10_080 }
                    .compactMap(remaining(in:))
                    .first
                if weekly != nil || fiveHour != nil {
                    completion(.success(Quota(fiveHourRemaining: fiveHour, weeklyRemaining: weekly, updatedAt: .now)))
                    return
                }
            }
            log("Codex rate_limits missing from recent sessions")
            completion(.success(.unavailable))
        }
    }
}

private func remaining(forWindowNear target: Double, in windows: [[String: Any]]) -> Double? {
    windows
        .compactMap { window -> (distance: Double, remaining: Double)? in
            guard let minutes = number(window["window_minutes"]), let value = remaining(in: window) else { return nil }
            return (abs(minutes - target), value)
        }
        .min(by: { $0.distance < $1.distance })?
        .remaining
}

private func findDictionary(named key: String, in value: Any) -> [String: Any]? {
    if let dict = value as? [String: Any] {
        if let match = dict[key] as? [String: Any] { return match }
        for child in dict.values { if let match = findDictionary(named: key, in: child) { return match } }
    } else if let items = value as? [Any] {
        for child in items { if let match = findDictionary(named: key, in: child) { return match } }
    }
    return nil
}

private func percentage(in dictionary: [String: Any]?) -> Double? {
    guard let raw = number(dictionary?["used_percent"]) ?? number(dictionary?["usedPercent"]) else { return nil }
    return min(1, max(0, raw > 1 ? raw / 100 : raw))
}

private func remaining(in dictionary: [String: Any]) -> Double? {
    percentage(in: dictionary).map { 1 - $0 }
}

private func number(_ value: Any?) -> Double? {
    if let value = value as? NSNumber { return value.doubleValue }
    if let value = value as? String { return Double(value) }
    return nil
}

private enum SecretStore {
    static func value(named name: String) -> String? {
        if let value = ProcessInfo.processInfo.environment[name], !value.isEmpty { return value }
        let rc = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".zshrc")
        guard let source = try? String(contentsOf: rc, encoding: .utf8) else { return nil }
        let escaped = NSRegularExpression.escapedPattern(for: name)
        guard let regex = try? NSRegularExpression(pattern: "(?:export\\s+)?\(escaped)\\s*=\\s*[\\\"']?([^\\s\\\"']+)"),
              let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
              let range = Range(match.range(at: 1), in: source) else { return nil }
        return String(source[range])
    }

    /// 从 zshrc 的指定 plan 块中提取 key（无论是否被注释）
    static func valueFromPlan(keyName: String, plan: String) -> String? {
        let rc = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".zshrc")
        guard let source = try? String(contentsOf: rc, encoding: .utf8) else { return nil }

        // 查找 plan 块的开始和结束（允许前面有 # 注释符）
        let startPattern = "~~~ PLAN: \(plan) ~~~"
        let endPattern = "~~~ END: \(plan) ~~~"

        guard let startRange = source.range(of: startPattern, options: .caseInsensitive),
              let endRange = source.range(of: endPattern, options: .caseInsensitive) else { return nil }

        // 提取块内容
        let block = String(source[startRange.upperBound..<endRange.lowerBound])

        // 在块中查找 key（忽略注释符 # 和 export）
        let escaped = NSRegularExpression.escapedPattern(for: keyName)
        guard let regex = try? NSRegularExpression(pattern: "#?\\s*(?:export\\s+)?\(escaped)\\s*=\\s*[\\\"']?([^\\s\\\"']+)"),
              let match = regex.firstMatch(in: block, range: NSRange(block.startIndex..., in: block)),
              let valueRange = Range(match.range(at: 1), in: block) else { return nil }

        return String(block[valueRange])
    }
}
final class MiniMaxProvider: QuotaProvider, @unchecked Sendable {
    let id = "minimax"
    let displayName = "MiniMax"

    func fetch(completion: @escaping @Sendable (Result<Quota, Error>) -> Void) {
        guard let token = SecretStore.valueFromPlan(keyName: "ANTHROPIC_API_KEY", plan: "minimax") else {
            log("MiniMax: ANTHROPIC_API_KEY not found in minimax plan block")
            completion(.success(.unavailable))
            return
        }
        // Token Plan quota endpoint. Docs: platform.minimax.io/docs/token-plan/faq.
        // The legacy /v1/api/openplatform/coding_plan/remains requires browser cookies,
        // so the bar must call /v1/token_plan/remains instead.
        fetchData(url: "https://api.minimax.chat/v1/token_plan/remains", token: token) { result in
            switch result {
            case .failure(let error):
                log("MiniMax fetch failed: \(error.localizedDescription)")
                completion(.success(.unavailable))
            case .success(let data):
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                guard let decoded = try? decoder.decode(MiniMaxQuotaResponse.self, from: data) else {
                    let snippet = String(data: data.prefix(160), encoding: .utf8) ?? ""
                    log("MiniMax: response decode failed: \(snippet)")
                    completion(.success(.unavailable))
                    return
                }
                // Token Plan returns one entry per model. Surface the tightest remaining
                // % so the bar reflects the most constrained quota rather than silently
                // mixing in the most generous one.
                // API returns percentages (0-100), convert to fractions (0-1) for storage.
                let weekly = decoded.modelRemains
                    .compactMap { $0.currentWeeklyRemainingPercent }
                    .min()
                    .map { $0 / 100 }
                let interval = decoded.modelRemains
                    .compactMap { $0.currentIntervalRemainingPercent }
                    .min()
                    .map { $0 / 100 }
                log("MiniMax: \(decoded.modelRemains.count) model(s) weekly=\(weekly.map { String(format: "%.2f", $0) } ?? "-") interval=\(interval.map { String(format: "%.2f", $0) } ?? "-")")
                completion(.success(Quota(
                    fiveHourRemaining: interval,
                    weeklyRemaining: weekly,
                    updatedAt: .now
                )))
            }
        }
    }
}

private struct MiniMaxQuotaResponse: Decodable {
    let modelRemains: [ModelRemain]
    struct ModelRemain: Decodable {
        let modelName: String?
        let currentIntervalRemainingPercent: Double?
        let currentWeeklyRemainingPercent: Double?
    }
}

final class ZenMuxProvider: QuotaProvider, @unchecked Sendable {
    let id = "zenmux"
    let displayName = "ZenMux"

    func fetch(completion: @escaping @Sendable (Result<Quota, Error>) -> Void) {
        // Prefer the dedicated Management API key. It intentionally lives outside
        // the switchable provider plan and may be commented out in ~/.zshrc because
        // this app reads the file directly rather than sourcing it in a shell.
        let token = SecretStore.value(named: "ZENMUX_MANAGEMENT_KEY")
            ?? SecretStore.value(named: "ZENMUX_MGMT_KEY")
            ?? SecretStore.valueFromPlan(keyName: "ANTHROPIC_API_KEY", plan: "zenmux")
        guard let token else {
            log("ZenMux: ZENMUX_MGMT_KEY not found")
            completion(.success(.unavailable))
            return
        }
        // Management keys currently use sk-mg-v1-*; retain the older sk-mgmt-*
        // spelling for compatibility. Subscription keys (sk-ss-v1-*) cannot
        // access the management quota endpoint.
        let isManagementKey = token.hasPrefix("sk-mg-v1-") || token.hasPrefix("sk-mgmt-")
        if !isManagementKey {
            log("ZenMux: non-management key detected. Quota API requires ZENMUX_MGMT_KEY (sk-mg-v1-*). See: zenmux.ai/platform/management")
            completion(.success(.unavailable))
            return
        }
        // /v1/management/* requires a Management API Key (not sk-ss-v1-* subscription key).
        // Without the correct key type, the server returns 403.
        // See: zenmux.ai/docs/api/platform/subscription-detail
        fetchData(url: "https://zenmux.ai/api/v1/management/subscription/detail", token: token) { result in
            switch result {
            case .failure(let error):
                log("ZenMux fetch failed: \(error.localizedDescription)")
                completion(.success(.unavailable))
            case .success(let data):
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                guard let decoded = try? decoder.decode(ZenMuxSubscriptionDetail.self, from: data),
                      decoded.success,
                      let payload = decoded.data else {
                    let snippet = String(data: data.prefix(160), encoding: .utf8) ?? ""
                    log("ZenMux: response decode failed or success=false: \(snippet)")
                    completion(.success(.unavailable))
                    return
                }
                // usage_percentage is a 0-1 fraction. remaining = 1 - usage.
                let fiveHour = Self.remaining(payload.quota5Hour?.usagePercentage)
                let weekly = Self.remaining(payload.quota7Day?.usagePercentage)
                log("ZenMux: tier=\(payload.plan?.tier ?? "-") 5h=\(fiveHour.map { String(format: "%.2f", $0) } ?? "-") week=\(weekly.map { String(format: "%.2f", $0) } ?? "-")")
                completion(.success(Quota(
                    fiveHourRemaining: fiveHour,
                    weeklyRemaining: weekly,
                    updatedAt: .now
                )))
            }
        }
    }

    private static func remaining(_ usage: Double?) -> Double? {
        guard let raw = usage else { return nil }
        return 1 - min(1, max(0, raw > 1 ? raw / 100 : raw))
    }
}

private struct ZenMuxSubscriptionDetail: Decodable {
    let success: Bool
    let data: Data?
    struct Data: Decodable {
        let plan: Plan?
        let quota5Hour: QuotaWindow?
        let quota7Day: QuotaWindow?
        struct Plan: Decodable { let tier: String? }
        struct QuotaWindow: Decodable {
            let usagePercentage: Double?
            let maxFlows: Double?
            let usedFlows: Double?
        }
    }
}

/// 智谱 GLM Coding Plan 额度。接口未公开文档,与官方 glm-plan-usage 插件一致:
/// GET /api/monitor/usage/quota/limit;平台对错误也返回 HTTP 200,必须检查 body 的 success 字段。
final class GLMProvider: QuotaProvider, @unchecked Sendable {
    let id = "glm"
    let displayName = "GLM"

    static var apiKey: String? {
        SecretStore.value(named: "BIGMODEL_API_KEY")
            ?? SecretStore.value(named: "GLM_API_KEY")
            ?? SecretStore.value(named: "ZHIPU_API_KEY")
    }

    func fetch(completion: @escaping @Sendable (Result<Quota, Error>) -> Void) {
        guard let token = Self.apiKey else {
            log("GLM: BIGMODEL_API_KEY 未设置")
            completion(.success(.unavailable))
            return
        }
        fetchData(url: "https://open.bigmodel.cn/api/monitor/usage/quota/limit", token: token) { result in
            switch result {
            case .failure(let error):
                log("GLM fetch failed: \(error.localizedDescription)")
                completion(.success(.unavailable))
            case .success(let data):
                self.parse(data, completion: completion)
            }
        }
    }

    private func parse(_ data: Data, completion: @escaping @Sendable (Result<Quota, Error>) -> Void) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            log("GLM: response is not JSON")
            completion(.success(.unavailable))
            return
        }
        if let success = object["success"] as? Bool, !success {
            log("GLM: API error code=\(object["code"] ?? "-") msg=\(object["msg"] ?? "-")")
            completion(.success(.unavailable))
            return
        }
        let payload = object["data"] as? [String: Any] ?? object
        let ordered = Self.orderedWindowLimits(in: payload)
        guard !ordered.isEmpty else {
            log("GLM: no quota entries; keys=\(payload.keys.sorted())")
            completion(.success(.unavailable))
            return
        }
        let fiveHour = Self.remainingFraction(ordered[0])
        let weekly = ordered.count > 1 ? Self.remainingFraction(ordered[1]) : nil
        log("GLM: 5h=\(fiveHour.map(percent) ?? "-") W=\(weekly.map(percent) ?? "-") entries=\(ordered.count)")
        completion(.success(Quota(fiveHourRemaining: fiveHour, weeklyRemaining: weekly, updatedAt: .now)))
    }

    private static func tokenLimits(in object: [String: Any]) -> [[String: Any]] {
        if let list = object["limits"] as? [[String: Any]] {
            let tokens = list.filter { ($0["type"] as? String) == "TOKENS_LIMIT" }
            if !tokens.isEmpty { return tokens }
            return list.filter { ($0["type"] as? String) == "CREDIT_LIMIT" }
        }
        for value in object.values {
            if let nested = value as? [String: Any] {
                let found = tokenLimits(in: nested)
                if !found.isEmpty { return found }
            }
        }
        return []
    }

    /// duration 升序:第一个是 5 小时窗口,第二个是周窗口;字段名未详时保持返回顺序
    static func orderedWindowLimits(in payload: [String: Any]) -> [[String: Any]] {
        let limits = tokenLimits(in: payload)
        return limits.enumerated().sorted { lhs, rhs in
            let l = duration(lhs.element) ?? .infinity
            let r = duration(rhs.element) ?? .infinity
            return l != r ? l < r : lhs.offset < rhs.offset
        }.map(\.element)
    }

    private static func duration(_ item: [String: Any]) -> Double? {
        for key in ["duration", "windowSeconds", "durationSeconds", "window", "cycle", "period"] {
            if let n = item[key] as? NSNumber { return n.doubleValue }
            if let s = item[key] as? String, let d = Double(s) { return d }
        }
        // 实测 schema:unit=3 表示小时、unit=6 表示周,number 为窗口数
        if let unit = item["unit"] as? NSNumber, let num = item["number"] as? NSNumber {
            let hoursPerUnit: [Int: Double] = [1: 1.0 / 60, 2: 1.0 / 24, 3: 1, 4: 24, 5: 24, 6: 168]
            if let h = hoursPerUnit[Int(unit.intValue)] { return h * num.doubleValue }
        }
        return nil
    }

    private static func remainingFraction(_ item: [String: Any]) -> Double? {
        // percentage 为已用百分比;实测 usage=总额度、currentValue=已用、remaining=剩余
        if let p = item["percentage"] as? NSNumber { return max(0, min(1, 1 - p.doubleValue / 100)) }
        if let s = item["percentage"] as? String, let d = Double(s) { return max(0, min(1, 1 - d / 100)) }
        if let total = number(item["usage"]) ?? number(item["total"]), total != 0,
           let remain = number(item["remaining"]) {
            return max(0, min(1, remain / total))
        }
        return nil
    }
}

/// 按模型用量:某口径(5h/周/今日)内该模型的消耗;share 为占该口径总量的比例(0-1)。
struct ModelUsage: Equatable, Hashable, Sendable {
    enum Source: Int, Hashable, Sendable {
        case fiveHour = 0
        case week = 1
        case today = 2

        var label: String {
            switch self {
            case .fiveHour: return "5 小时窗口"
            case .week: return "本周"
            case .today: return "今日"
            }
        }
    }

    let model: String
    let usage: Double
    let share: Double?
    let source: Source

    static func text(_ value: Double) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", value / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fk", value / 1_000) }
        return String(Int(value))
    }
}

extension GLMProvider {
    /// 按模型用量汇总:quota/limit 各窗口条目的 usageDetails(5h/周)+ model-usage(今日 token)。
    /// model-usage 无公开文档(结构取自 CodexBar 插件):请求带 startTime/endTime
    /// (YYYY-MM-DD HH:mm:ss),响应为 data.modelDataList[].{modelName, tokensUsage[](与 x_time 按下标对应)}。
    static func fetchModelBreakdown(completion: @escaping @Sendable ([ModelUsage]?, String?) -> Void) {
        guard let token = apiKey else {
            completion(nil, "未找到 BIGMODEL_API_KEY(检查 ~/.zshrc)")
            return
        }
        fetchData(url: "https://open.bigmodel.cn/api/monitor/usage/quota/limit", token: token) { quotaResult in
            let quota = parseResult(quotaResult, parser: parseBreakdown)
            fetchData(url: modelUsageURL(), token: token) { usageResult in
                let today = parseResult(usageResult, parser: parseModelUsage)
                let rows = quota.rows + today.rows
                if rows.isEmpty {
                    completion(nil, quota.error ?? today.error ?? "接口未返回按模型用量数据")
                } else {
                    log("GLM model breakdown: \(rows.count) rows (quota=\(quota.rows.count) today=\(today.rows.count))")
                    completion(rows, nil)
                }
            }
        }
    }

    private static func parseResult(
        _ result: Result<Data, Error>,
        parser: (Data) -> [ModelUsage]
    ) -> (rows: [ModelUsage], error: String?) {
        switch result {
        case .success(let data): return (parser(data), nil)
        case .failure(let error): return ([], error.localizedDescription)
        }
    }

    /// model-usage 按时间段查询;取今天 00:00:00–23:59:59(本地时区)。
    private static func modelUsageURL() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: Date())
        let dayEnd = calendar.date(bySettingHour: 23, minute: 59, second: 59, of: dayStart) ?? Date()
        var components = URLComponents(string: "https://open.bigmodel.cn/api/monitor/usage/model-usage")
        components?.queryItems = [
            URLQueryItem(name: "startTime", value: formatter.string(from: dayStart)),
            URLQueryItem(name: "endTime", value: formatter.string(from: dayEnd)),
        ]
        return components?.url?.absoluteString ?? "https://open.bigmodel.cn/api/monitor/usage/model-usage"
    }

    /// quota/limit 各窗口条目自带的 usageDetails:[{modelCode, usage}]
    private static func parseBreakdown(from data: Data) -> [ModelUsage] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            log("GLM breakdown: response is not JSON")
            return []
        }
        if let success = object["success"] as? Bool, !success {
            log("GLM breakdown: API error code=\(object["code"] ?? "-") msg=\(object["msg"] ?? "-")")
            return []
        }
        let payload = object["data"] as? [String: Any] ?? object
        let ordered = orderedWindowLimits(in: payload)
        var rows: [ModelUsage] = []
        for (index, source) in [ModelUsage.Source.fiveHour, .week].enumerated() where ordered.count > index {
            let details = ordered[index]["usageDetails"] as? [[String: Any]] ?? []
            rows += details.compactMap { detail -> ModelUsage? in
                guard let code = detail["modelCode"] as? String, !code.isEmpty,
                      let usage = number(detail["usage"]) else { return nil }
                return ModelUsage(model: code, usage: usage, share: nil, source: source)
            }
        }
        return withShares(rows)
    }

    /// model-usage:data.x_time[] + data.modelDataList[].{modelName, tokensUsage[]},逐模型求和为今日用量
    private static func parseModelUsage(from data: Data) -> [ModelUsage] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            log("GLM model-usage: response is not JSON")
            return []
        }
        if let success = object["success"] as? Bool, !success {
            log("GLM model-usage: API error code=\(object["code"] ?? "-") msg=\(object["msg"] ?? "-")")
            return []
        }
        let payload = object["data"] as? [String: Any] ?? [:]
        let list = payload["modelDataList"] as? [[String: Any]] ?? []
        var rows: [ModelUsage] = []
        for entry in list {
            guard let name = entry["modelName"] as? String, !name.isEmpty else { continue }
            let tokens = (entry["tokensUsage"] as? [Any])?.compactMap { number($0) } ?? []
            let total = tokens.reduce(0.0, +)
            guard total > 0 else { continue }
            rows.append(ModelUsage(model: name, usage: total, share: nil, source: .today))
        }
        return withShares(rows)
    }

    /// 按口径分组:组内按用量降序,并计算组内占比
    private static func withShares(_ rows: [ModelUsage]) -> [ModelUsage] {
        var result: [ModelUsage] = []
        for source in [ModelUsage.Source.fiveHour, .week, .today] {
            let group = rows.filter { $0.source == source }.sorted { $0.usage > $1.usage }
            let total = group.reduce(0.0) { $0 + $1.usage }
            result += group.map {
                ModelUsage(model: $0.model, usage: $0.usage, share: total > 0 ? $0.usage / total : nil, source: source)
            }
        }
        return result
    }
}

/// 用户在"管理套餐"窗口添加的自定义套餐:任意 GET JSON 接口,按点分路径提取两个百分比。
struct CustomProviderConfig: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var url: String
    var key: String            // 空 = 无鉴权;明文存本地 UserDefaults
    var path5h: String         // 如 data.limits.0.percentage
    var pathWeekly: String     // 空 = 不显示周额度
    var usedNotRemaining: Bool // true = 字段是已用百分比;false = 剩余百分比
}

enum CustomProviderStore {
    static let defaultsKey = "customProviders"

    static func load() -> [CustomProviderConfig] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let list = try? JSONDecoder().decode([CustomProviderConfig].self, from: data) else { return [] }
        return list
    }

    static func save(_ list: [CustomProviderConfig]) {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    static func add(_ config: CustomProviderConfig) { save(load() + [config]) }

    static func remove(id: String) { save(load().filter { $0.id != id }) }
}

/// 自定义套餐:GET url(可选 Bearer key),按点分路径(字典键/数组下标)取 JSON 数值;0-1 与 0-100 自动识别。
final class CustomProvider: QuotaProvider, @unchecked Sendable {
    let id: String
    let displayName: String
    private let config: CustomProviderConfig

    init(config: CustomProviderConfig) {
        self.config = config
        self.id = config.id
        self.displayName = config.name
    }

    func fetch(completion: @escaping @Sendable (Result<Quota, Error>) -> Void) {
        guard URL(string: config.url)?.scheme != nil else {
            log("Custom \(config.name): invalid url")
            completion(.success(.unavailable))
            return
        }
        fetchData(url: config.url, token: config.key.isEmpty ? nil : config.key) { result in
            switch result {
            case .failure(let error):
                log("Custom \(self.config.name) fetch failed: \(error.localizedDescription)")
                completion(.success(.unavailable))
            case .success(let data):
                guard let object = try? JSONSerialization.jsonObject(with: data) else {
                    log("Custom \(self.config.name): response is not JSON")
                    completion(.success(.unavailable))
                    return
                }
                let fiveHour = Self.remaining(Self.resolve(config.path5h, in: object), used: config.usedNotRemaining)
                let weekly = config.pathWeekly.isEmpty
                    ? nil
                    : Self.remaining(Self.resolve(config.pathWeekly, in: object), used: config.usedNotRemaining)
                if fiveHour == nil && weekly == nil {
                    log("Custom \(self.config.name): paths not found (5h=\(config.path5h) weekly=\(config.pathWeekly))")
                    completion(.success(.unavailable))
                    return
                }
                log("Custom \(self.config.name): 5h=\(fiveHour.map(percent) ?? "-") W=\(weekly.map(percent) ?? "-")")
                completion(.success(Quota(fiveHourRemaining: fiveHour, weeklyRemaining: weekly, updatedAt: .now)))
            }
        }
    }

    /// "data.limits.0.percentage" 逐段下钻:数字段取数组下标,其余取字典键
    private static func resolve(_ path: String, in json: Any) -> Double? {
        var current: Any = json
        for part in path.split(separator: ".").map(String.init) {
            if let index = Int(part), let array = current as? [Any], array.indices.contains(index) {
                current = array[index]
            } else if let dict = current as? [String: Any], let value = dict[part] {
                current = value
            } else {
                return nil
            }
        }
        return number(current)
    }

    private static func remaining(_ raw: Double?, used: Bool) -> Double? {
        guard let raw else { return nil }
        let clamped = min(1, max(0, raw > 1 ? raw / 100 : raw))
        return used ? 1 - clamped : clamped
    }
}

struct ProviderInfo: Sendable {
    let id: String
    let displayName: String
    let summary: String
}

enum ProviderCatalog {
    static let builtin: [ProviderInfo] = [
        ProviderInfo(id: "codex", displayName: "Codex", summary: "读取本地会话快照,无需密钥"),
        ProviderInfo(id: "glm", displayName: "GLM(智谱)", summary: "Coding Plan;需 BIGMODEL_API_KEY"),
        ProviderInfo(id: "minimax", displayName: "MiniMax", summary: "Token Plan;需 zshrc minimax 块密钥"),
        ProviderInfo(id: "zenmux", displayName: "ZenMux", summary: "订阅额度;需 ZENMUX_MGMT_KEY"),
    ]

    /// 内置 + 用户在管理窗口添加的自定义套餐
    static var all: [ProviderInfo] {
        builtin + CustomProviderStore.load().map { config in
            let host = URL(string: config.url)?.host ?? config.url
            return ProviderInfo(id: config.id, displayName: config.name, summary: "自定义 · \(host)")
        }
    }

    static func make(id: String) -> (any QuotaProvider)? {
        switch id {
        case "codex": return CodexProvider()
        case "glm": return GLMProvider()
        case "minimax": return MiniMaxProvider()
        case "zenmux": return ZenMuxProvider()
        default:
            if let config = CustomProviderStore.load().first(where: { $0.id == id }) {
                return CustomProvider(config: config)
            }
            return nil
        }
    }
}

enum ProviderStore {
    static let defaultsKey = "enabledProviders"
    // ZenMux / MiniMax 保留实现但默认关闭;GLM 默认开启
    static let defaultEnabled = ["codex", "glm"]

    static var enabledIDs: [String] {
        let stored = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? defaultEnabled
        return ProviderCatalog.all.map(\.id).filter { stored.contains($0) }
    }

    static func setEnabled(_ id: String, _ on: Bool) {
        var current = Set(enabledIDs)
        if on { current.insert(id) } else { current.remove(id) }
        UserDefaults.standard.set(ProviderCatalog.all.map(\.id).filter { current.contains($0) }, forKey: defaultsKey)
    }
}

/// 概览中显示哪些 GLM 模型;UserDefaults 未配置 = 全部显示。
enum ModelStore {
    static let defaultsKey = "glm.trackedModels"

    static func tracked(all: [String]) -> Set<String> {
        guard let stored = UserDefaults.standard.stringArray(forKey: defaultsKey) else { return Set(all) }
        return Set(all).intersection(stored)
    }

    static func save(_ ids: Set<String>) {
        UserDefaults.standard.set(ids.sorted(), forKey: defaultsKey)
    }
}

/// 按模型用量的共享数据源:模型配置窗口与菜单概览共用;30 秒刷新周期内最多每 150 秒拉一次。
@MainActor
final class ModelUsageStore: ObservableObject {
    @Published private(set) var models: [ModelUsage] = []
    @Published private(set) var statusText: String?
    @Published private(set) var isLoading = false
    /// nil = 用户未配置过(全部显示)
    @Published private(set) var tracked: Set<String>?
    var onModelsUpdated: (() -> Void)?
    private var lastFetch = Date.distantPast

    func isChecked(_ model: String) -> Bool { tracked?.contains(model) ?? true }

    func toggle(_ model: String, on: Bool) {
        // 首次改动以当前全部模型为基准,避免只存下勾选的那一个
        var current = tracked ?? Set(models.map(\.model))
        if on { current.insert(model) } else { current.remove(model) }
        tracked = current
        ModelStore.save(current)
    }

    func refreshIfNeeded(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastFetch) > 150 else { return }
        guard !isLoading else { return }
        isLoading = true
        GLMProvider.fetchModelBreakdown { [weak self] models, errorMessage in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isLoading = false
                self.lastFetch = Date()
                if let models {
                    self.models = models
                    self.statusText = models.isEmpty ? "接口未返回按模型用量数据" : nil
                    self.onModelsUpdated?()
                } else {
                    self.statusText = errorMessage
                }
            }
        }
    }

    /// 概览行:每个勾选模型取优先级最高(5h > 本周 > 今日)的一条
    func overviewRows() -> [ModelUsage] {
        let selected = ModelStore.tracked(all: models.map(\.model))
        var seen = Set<String>()
        return models.filter { row in
            guard selected.contains(row.model) else { return false }
            return seen.insert(row.model).inserted
        }
    }
}

private enum FetchError: LocalizedError {
    case invalidURL
    case transport(Error)
    case http(Int)
    case empty

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "invalid URL"
        case .transport(let error): return "transport: \(error.localizedDescription)"
        case .http(let code): return "HTTP \(code)"
        case .empty: return "empty body"
        }
    }
}

private func fetchData(url address: String, token: String?, completion: @escaping @Sendable (Result<Data, Error>) -> Void) {
    guard let url = URL(string: address) else { completion(.failure(FetchError.invalidURL)); return }
    var request = URLRequest(url: url, timeoutInterval: 12)
    request.httpMethod = "GET"
    if let token, !token.isEmpty {
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    URLSession.shared.dataTask(with: request) { data, response, error in
        if let error { completion(.failure(FetchError.transport(error))); return }
        guard let data, !data.isEmpty else { completion(.failure(FetchError.empty)); return }
        guard let http = response as? HTTPURLResponse else { completion(.success(data)); return }
        guard (200..<300).contains(http.statusCode) else {
            completion(.failure(FetchError.http(http.statusCode))); return
        }
        completion(.success(data))
    }.resume()
}


@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var providers: [any QuotaProvider] = ProviderStore.enabledIDs.compactMap { ProviderCatalog.make(id: $0) }
    private var configWindow: NSWindow?
    private var modelWindow: NSWindow?
    private let modelStore = ModelUsageStore()
    private var quotas: [String: Quota] = [:]
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var refreshTimer: Timer?
    private var isRefreshing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.autosaveName = "AIQuotaBar.MainQuota"
        statusItem.button?.toolTip = "AI Quota Bar · 正在读取额度…"
        statusItem.button?.title = ""
        statusItem.button?.image = MenuBarImage.make(
            providers: providers.map { ($0.displayName, Quota.unavailable) }
        )
        statusItem.button?.imagePosition = .imageOnly
        rebuildMenu()
        modelStore.onModelsUpdated = { [weak self] in self?.rebuildMenu() }
        log("status item visible=\(statusItem.isVisible) frame=\(String(describing: statusItem.button?.window?.frame))")
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refreshTimer?.tolerance = 3
    }

    @objc private func openConfig() {
        // 每次重建窗口:套餐目录(含自定义)可能已变化,避免显示过期列表
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 620),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "管理套餐"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ConfigView(onApplied: { [weak self] in self?.applyProviderChange() }))
        window.center()
        configWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 模型配置窗口:按窗口展示 GLM 各模型用量,勾选控制概览中显示哪些模型。
    @objc private func openModelConfig() {
        if let modelWindow { modelWindow.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "模型配置"
        window.isReleasedWhenClosed = false
        modelStore.refreshIfNeeded(force: modelStore.models.isEmpty)
        window.contentView = NSHostingView(rootView: ModelConfigView(store: modelStore, onChanged: { [weak self] in self?.rebuildMenu() }))
        window.center()
        modelWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 管理窗口改动后回调:重建 provider 列表并立即刷新。
    private func applyProviderChange() {
        providers = ProviderStore.enabledIDs.compactMap { ProviderCatalog.make(id: $0) }
        let ids = Set(providers.map(\.id))
        quotas = quotas.filter { ids.contains($0.key) }
        refresh()
    }

    @objc private func refresh() {
        guard !isRefreshing else {
            log("refresh skipped: previous refresh is still running")
            return
        }
        isRefreshing = true
        log("refresh started")
        if providers.contains(where: { $0.id == "glm" }) {
            modelStore.refreshIfNeeded()
        }
        let group = DispatchGroup()
        providers.forEach { provider in
            group.enter()
            provider.fetch { [weak self] result in
                DispatchQueue.main.async {
                    if case .success(let quota) = result { self?.quotas[provider.id] = quota }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) { [weak self] in
            self?.isRefreshing = false
            self?.rebuildMenu()
        }
    }

    private func rebuildMenu() {
        let summary = providers.map { provider in
            let quota = quotas[provider.id] ?? .unavailable
            return "\(provider.id):5h=\(quota.fiveHourRemaining.map(percent) ?? "-") W=\(quota.weeklyRemaining.map(percent) ?? "-")"
        }.joined(separator: " ")
        log("refresh completed \(summary)")
        let menu = NSMenu()
        menu.autoenablesItems = false
        let overview = NSMenuItem()
        let modelRows = modelStore.overviewRows()
        overview.view = QuotaOverviewView(
            providers: providers.map { provider in
                ProviderOverviewData(
                    name: provider.displayName,
                    quota: quotas[provider.id] ?? .unavailable,
                    models: provider.id == "glm" ? modelRows : []
                )
            }
        )
        menu.addItem(overview)
        menu.addItem(.separator())
        let refresh = NSMenuItem(title: "刷新额度", action: #selector(refresh), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)
        let config = NSMenuItem(title: "管理套餐…", action: #selector(openConfig), keyEquivalent: ",")
        config.target = self
        menu.addItem(config)
        let modelConfig = NSMenuItem(title: "模型配置…", action: #selector(openModelConfig), keyEquivalent: "")
        modelConfig.target = self
        menu.addItem(modelConfig)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 AI Quota Bar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu
        updateStatusTitle()
    }

    private func updateStatusTitle() {
        let values = providers.map { quotas[$0.id] ?? .unavailable }
        // Keep the item inside the right safe area on notched MacBooks. AppKit adds
        // roughly 16 pt of button chrome around the rendered image width.
        let image = MenuBarImage.make(providers: zip(providers, values).map { ($0.displayName, $1) })
        statusItem.length = image.size.width + 8
        statusItem.button?.title = ""
        statusItem.button?.image = image
        statusItem.button?.imagePosition = .imageOnly
        let newest = values.map(\.updatedAt).filter { $0 != .distantPast }.max()
        statusItem.button?.toolTip = newest.map {
            "AI Quota Bar · 更新于 \($0.formatted(date: .omitted, time: .standard))"
        } ?? "AI Quota Bar · 暂无额度数据"
        let screenFrame = statusItem.button?.window.map { $0.convertToScreen(NSRect(origin: .zero, size: $0.frame.size)) }
        log("updated status item visible=\(statusItem.isVisible) frame=\(String(describing: screenFrame))")
    }
}

struct ProviderOverviewData {
    let name: String
    let quota: Quota
    let models: [ModelUsage]
}

final class QuotaOverviewView: NSView {
    private let providers: [ProviderOverviewData]
    /// 底部预留的模型行区域高度(取各 provider 中最多模型行数;0 = 不显示模型)
    private let modelsExtra: CGFloat

    init(providers: [ProviderOverviewData]) {
        self.providers = providers
        let maxModels = providers.map { $0.models.count }.max() ?? 0
        modelsExtra = maxModels > 0 ? CGFloat(maxModels) * 13 + 4 : 0
        let count = CGFloat(max(1, providers.count))
        let width = 28 + count * 140 + (count - 1) * 12
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 158 + modelsExtra))
    }
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let titleStyle = NSMutableParagraphStyle()
        titleStyle.lineBreakMode = .byTruncatingTail
        "AI Quota Bar".draw(
            in: NSRect(x: 16, y: 128 + modelsExtra, width: 180, height: 18),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: titleStyle
            ]
        )
        let newest = providers.map(\.quota.updatedAt).filter { $0 != .distantPast }.max()
        let updated = newest.map { "30 秒自动刷新 · \($0.formatted(date: .omitted, time: .shortened))" }
            ?? "30 秒自动刷新 · 等待数据"
        let right = NSMutableParagraphStyle()
        right.alignment = .right
        updated.draw(
            in: NSRect(x: 210, y: 129 + modelsExtra, width: 242, height: 16),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .regular),
                .foregroundColor: NSColor.tertiaryLabelColor,
                .paragraphStyle: right
            ]
        )

        NSColor.separatorColor.setFill()
        NSRect(x: 14, y: 118 + modelsExtra, width: bounds.width - 28, height: 1).fill()

        let outerPadding: CGFloat = 14
        let gap: CGFloat = 12
        let count = CGFloat(max(1, providers.count))
        let columnWidth = (bounds.width - outerPadding * 2 - gap * (count - 1)) / count

        for (index, provider) in providers.enumerated() {
            let x = outerPadding + CGFloat(index) * (columnWidth + gap)
            drawColumn(provider, in: NSRect(x: x, y: 8 + modelsExtra, width: columnWidth, height: 102))
            if index < providers.count - 1 {
                NSColor.separatorColor.withAlphaComponent(0.7).setFill()
                NSRect(x: x + columnWidth + gap / 2, y: 14 + modelsExtra, width: 1, height: 88).fill()
            }
        }
    }

    private func drawColumn(_ provider: ProviderOverviewData, in rect: NSRect) {
        provider.name.draw(
            in: NSRect(x: rect.minX + 4, y: rect.maxY - 22, width: rect.width - 8, height: 18),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 15, weight: .bold),
                .foregroundColor: NSColor.labelColor
            ]
        )

        drawMetric(title: "H", subtitle: "5 小时", value: provider.quota.fiveHourRemaining, y: rect.maxY - 61, in: rect)
        drawMetric(title: "W", subtitle: "一周", value: provider.quota.weeklyRemaining, y: rect.maxY - 96, in: rect)

        guard !provider.models.isEmpty else { return }
        NSColor.separatorColor.withAlphaComponent(0.7).setFill()
        NSRect(x: rect.minX + 4, y: rect.minY + 2, width: rect.width - 8, height: 1).fill()
        for (index, model) in provider.models.enumerated() {
            drawModelRow(model, y: rect.minY - 15 - CGFloat(index) * 13, in: rect)
        }
    }

    /// 模型行:名称截断 + 右侧紧凑用量(优先 5h 窗口口径,见 ModelUsageStore.overviewRows)
    private func drawModelRow(_ model: ModelUsage, y: CGFloat, in rect: NSRect) {
        let truncating = NSMutableParagraphStyle()
        truncating.lineBreakMode = .byTruncatingMiddle
        model.model.draw(
            in: NSRect(x: rect.minX + 4, y: y, width: rect.width - 44, height: 11),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 9.5),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: truncating
            ]
        )
        let rightAligned = NSMutableParagraphStyle()
        rightAligned.alignment = .right
        ModelUsage.text(model.usage).draw(
            in: NSRect(x: rect.maxX - 40, y: y, width: 36, height: 11),
            withAttributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: rightAligned
            ]
        )
    }

    private func drawMetric(title: String, subtitle: String, value: Double?, y: CGFloat, in column: NSRect) {
        let rightAligned = NSMutableParagraphStyle()
        rightAligned.alignment = .right
        title.draw(
            in: NSRect(x: column.minX + 4, y: y + 5, width: 14, height: 15),
            withAttributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .bold),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        )
        subtitle.draw(
            in: NSRect(x: column.minX + 19, y: y + 6, width: 42, height: 14),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 9, weight: .regular),
                .foregroundColor: NSColor.tertiaryLabelColor
            ]
        )
        let valueText = value.map(percent) ?? "—"
        valueText.draw(
            in: NSRect(x: column.maxX - 42, y: y + 4, width: 38, height: 17),
            withAttributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold),
                .foregroundColor: value.map(quotaColor) ?? NSColor.tertiaryLabelColor,
                .paragraphStyle: rightAligned
            ]
        )

        drawSegments(
            in: NSRect(x: column.minX + 5, y: y, width: column.width - 10, height: 5),
            value: value,
            count: 10,
            activeColor: value.map(quotaColor) ?? .clear,
            inactiveColor: .quaternaryLabelColor
        )
    }
}

enum MenuBarImage {
    static func make(providers: [(String, Quota)]) -> NSImage {
        let itemWidth: CGFloat = 79
        let separatorSpace: CGFloat = 4
        let count = max(1, providers.count)
        let size = NSSize(width: 4 + itemWidth * CGFloat(count) + separatorSpace * CGFloat(count - 1), height: 28)
        let image = NSImage(size: size)
        image.lockFocus()
        var x: CGFloat = 2
        for (index, item) in providers.enumerated() {
            drawProvider(item, in: NSRect(x: x, y: 0, width: itemWidth, height: size.height))
            x += itemWidth
            if index < providers.count - 1 {
                NSColor.white.withAlphaComponent(0.48).setFill()
                NSRect(x: x + 1, y: 2, width: 1, height: 24).fill()
                x += separatorSpace
            }
        }
        image.unlockFocus()
        image.isTemplate = false
        image.accessibilityDescription = providers.map { item in
            "\(item.0), H \(item.1.fiveHourRemaining.map(percent) ?? "无数据"), W \(item.1.weeklyRemaining.map(percent) ?? "无数据")"
        }.joined(separator: "; ")
        return image
    }

    private static func drawProvider(_ item: (String, Quota), in rect: NSRect) {
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        centered.lineBreakMode = .byClipping
        item.0.draw(
            in: NSRect(x: rect.minX, y: 19, width: rect.width, height: 9),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 7.8, weight: .bold),
                .foregroundColor: NSColor.white,
                .paragraphStyle: centered
            ]
        )
        drawMetric(label: "H", value: item.1.fiveHourRemaining, rect: rect, y: 13)
        drawMetric(label: "W", value: item.1.weeklyRemaining, rect: rect, y: 5)
    }

    private static func drawMetric(label: String, value: Double?, rect: NSRect, y: CGFloat) {
        label.draw(
            in: NSRect(x: rect.minX, y: y - 2, width: 7, height: 7),
            withAttributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 6.8, weight: .bold),
                .foregroundColor: NSColor.white.withAlphaComponent(0.82)
            ]
        )
        let percentageWidth: CGFloat = 19
        let segmentRect = NSRect(
            x: rect.minX + 7,
            y: y,
            width: max(8, rect.width - 7 - percentageWidth),
            height: 3.6
        )
        drawSegments(
            in: segmentRect,
            value: value,
            count: 8,
            activeColor: value.map(quotaColor) ?? .clear,
            inactiveColor: NSColor.white.withAlphaComponent(0.25)
        )
        let right = NSMutableParagraphStyle()
        right.alignment = .right
        (value.map(percent) ?? "—").draw(
            in: NSRect(x: rect.maxX - percentageWidth, y: y - 3, width: percentageWidth, height: 8),
            withAttributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 7.6, weight: .bold),
                .foregroundColor: NSColor.white,
                .paragraphStyle: right
            ]
        )
    }
}

private func quotaColor(_ remaining: Double) -> NSColor {
    if remaining >= 0.70 {
        return NSColor(srgbRed: 0.16, green: 0.86, blue: 0.25, alpha: 1)
    }
    if remaining >= 0.40 {
        return NSColor(srgbRed: 1.00, green: 0.68, blue: 0.03, alpha: 1)
    }
    return NSColor(srgbRed: 1.00, green: 0.34, blue: 0.08, alpha: 1)
}

private func drawSegments(
    in rect: NSRect,
    value: Double?,
    count: Int,
    activeColor: NSColor,
    inactiveColor: NSColor
) {
    guard count > 0, rect.width > 0 else { return }
    let gap = min(1.2, max(0.5, rect.height * 0.28))
    let segmentWidth = max(1, (rect.width - gap * CGFloat(count - 1)) / CGFloat(count))
    let clamped = min(1, max(0, value ?? 0))
    let activeCount = value == nil ? 0 : Int(ceil(clamped * Double(count)))
    for index in 0..<count {
        let segment = NSRect(
            x: rect.minX + CGFloat(index) * (segmentWidth + gap),
            y: rect.minY,
            width: segmentWidth,
            height: rect.height
        )
        (index < activeCount ? activeColor : inactiveColor).setFill()
        NSBezierPath(roundedRect: segment, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
    }
}

func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }

/// 管理窗口:勾选即启用/停用,实时保存并刷新菜单栏;支持添加/删除自定义套餐。
struct ConfigView: View {
    var onApplied: () -> Void
    @State private var enabled: Set<String> = Set(ProviderStore.enabledIDs)
    @State private var customs: [CustomProviderConfig] = CustomProviderStore.load()
    @State private var showForm = false
    @State private var newName = ""
    @State private var newURL = ""
    @State private var newKey = ""
    @State private var newPath5h = ""
    @State private var newPathWeekly = ""
    @State private var newUsedNotRemaining = false
    @State private var errorText: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("套餐监控")
                    .font(.headline)
                Text("勾选即启用,立即生效并保存。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(ProviderCatalog.all, id: \.id) { info in
                    if let custom = customs.first(where: { $0.id == info.id }) {
                        customRow(custom, info: info)
                    } else {
                        toggleRow(info)
                    }
                }
                Divider()
                DisclosureGroup("添加套餐…", isExpanded: $showForm) {
                    form
                }
                Divider()
                Text("GLM 额度:从环境变量 BIGMODEL_API_KEY(或 ~/.zshrc 同名变量)读取,使用绑定 Coding Plan 的 key。若失效,到 bigmodel.cn 控制台 → 套餐概览 重新获取。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let errorText {
                    Text(errorText)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(16)
            .frame(width: 440)
        }
    }

    private func toggleRow(_ info: ProviderInfo) -> some View {
        Toggle(isOn: Binding(
            get: { enabled.contains(info.id) },
            set: { on in
                if on { enabled.insert(info.id) } else { enabled.remove(info.id) }
                ProviderStore.setEnabled(info.id, on)
                onApplied()
            }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text(info.displayName)
                    .font(.system(size: 13, weight: .medium))
                Text(info.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func customRow(_ custom: CustomProviderConfig, info: ProviderInfo) -> some View {
        HStack(alignment: .top) {
            toggleRow(info)
            Spacer()
            Button {
                CustomProviderStore.remove(id: custom.id)
                ProviderStore.setEnabled(custom.id, false)
                enabled.remove(custom.id)
                customs = CustomProviderStore.load()
                onApplied()
            } label: {
                Text("删除")
                    .font(.caption)
            }
            .buttonStyle(.link)
            .padding(.top, 2)
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("名称(如:GLM 国际版)", text: $newName)
            TextField("接口 URL(GET,返回 JSON)", text: $newURL)
            SecureField("API Key(留空 = 无鉴权;明文存本地)", text: $newKey)
            TextField("5 小时字段路径(如 data.limits.0.percentage)", text: $newPath5h)
            TextField("一周字段路径(可选)", text: $newPathWeekly)
            Picker("字段含义", selection: $newUsedNotRemaining) {
                Text("剩余百分比").tag(false)
                Text("已用百分比").tag(true)
            }
            .pickerStyle(.segmented)
            HStack {
                Button("添加") { addCustom() }
                Spacer()
                Text("取值 0-100 或 0-1 自动识别;数组用数字下标")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 4)
    }

    private func addCustom() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        let url = newURL.trimmingCharacters(in: .whitespaces)
        let path5h = newPath5h.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let parsed = URL(string: url), parsed.scheme != nil, !path5h.isEmpty else {
            errorText = "名称、URL、5 小时字段路径均为必填;URL 需带 http(s):// 前缀。"
            return
        }
        let config = CustomProviderConfig(
            id: "custom-\(UUID().uuidString.prefix(8))",
            name: name,
            url: url,
            key: newKey.trimmingCharacters(in: .whitespaces),
            path5h: path5h,
            pathWeekly: newPathWeekly.trimmingCharacters(in: .whitespaces),
            usedNotRemaining: newUsedNotRemaining
        )
        CustomProviderStore.add(config)
        ProviderStore.setEnabled(config.id, true)
        enabled.insert(config.id)
        customs = CustomProviderStore.load()
        newName = ""; newURL = ""; newKey = ""; newPath5h = ""; newPathWeekly = ""
        newUsedNotRemaining = false
        errorText = nil
        onApplied()
    }
}

/// 模型配置窗口:按窗口展示 GLM 各模型用量与占比,勾选控制概览中显示哪些模型。
struct ModelConfigView: View {
    @ObservedObject var store: ModelUsageStore
    var onChanged: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("模型配置")
                .font(.headline)
            Text("勾选的模型会显示在菜单栏概览的 GLM 列下方,取消勾选即隐藏。百分比为该模型占对应窗口总用量的比例,用量单位为 token。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if store.isLoading && store.models.isEmpty {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在加载模型用量…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if store.models.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(store.statusText ?? "暂无模型用量数据")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("重新加载") { store.refreshIfNeeded(force: true) }
                }
            } else {
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(section.source.label)
                            .font(.subheadline.weight(.semibold))
                        ForEach(section.rows, id: \.self) { row in
                            rowView(row)
                        }
                    }
                }
            }
            Divider()
            HStack {
                Button("刷新") { store.refreshIfNeeded(force: true) }
                Spacer()
                Text("随额度每 30 秒周期刷新,此处约 2.5 分钟更新一次")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 480, alignment: .topLeading)
        .onAppear { store.refreshIfNeeded(force: store.models.isEmpty) }
    }

    private struct Section: Identifiable {
        let source: ModelUsage.Source
        let rows: [ModelUsage]
        var id: ModelUsage.Source { source }
    }

    private var sections: [Section] {
        [ModelUsage.Source.fiveHour, .week, .today].compactMap { source in
            let rows = store.models.filter { $0.source == source }
            return rows.isEmpty ? nil : Section(source: source, rows: rows)
        }
    }

    private func rowView(_ row: ModelUsage) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(
                get: { store.isChecked(row.model) },
                set: { on in
                    store.toggle(row.model, on: on)
                    onChanged()
                }
            ))
            .labelsHidden()
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(row.model)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    if let share = row.share {
                        Text("\(Int((share * 100).rounded()))%")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                if let share = row.share {
                    ProgressView(value: min(1, max(0, share)))
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                }
                Text("\(ModelUsage.text(row.usage)) tokens · \(row.source.label)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
