import AppKit
import Foundation
import SwiftUI

private let logURL = URL(fileURLWithPath: "/tmp/aiq-state.log")
/// ISO8601DateFormatter 线程安全;避免每次写日志都分配一个 formatter
private nonisolated(unsafe) let logTimestampFormatter = ISO8601DateFormatter()

private func log(_ message: String) {
    let line = "[\(logTimestampFormatter.string(from: .now))] \(message)\n"
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
    /// 拉取额度(0-1 的剩余比例)。网络、鉴权、解析等任何失败都以 throw 报告,
    /// 由刷新循环统一记录日志并把该套餐显示为 "—";provider 内部不再各自兜底。
    func fetchQuota() async throws -> Quota
}

/// Reads the latest actual Codex `rate_limits` payload from local session JSONL files.
/// Session content stays on this Mac; no Codex request is made from the quota bar.
final class CodexProvider: QuotaProvider, @unchecked Sendable {
    let id = "codex"
    let displayName = "Codex"

    /// rate_limits 快照随会话追加,最新一条总在文件末尾附近,只读末尾这段即可,
    /// 避免 session 文件(可达数 MB)整文件读入内存。
    private static let tailBytes = 524_288
    private static let maxFiles = 12

    func fetchQuota() async throws -> Quota {
        let quota = await Task.detached(priority: .utility) { () -> Quota? in
            Self.scanSessions()
        }.value
        guard let quota else {
            throw FetchError.parse("rate_limits missing from latest \(Self.maxFiles) sessions")
        }
        return quota
    }

    private static func scanSessions() -> Quota? {
        let sessions = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex/sessions")
        let enumerator = FileManager.default.enumerator(at: sessions, includingPropertiesForKeys: [.contentModificationDateKey])
        var candidates: [(URL, Date)] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "jsonl" else { continue }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            candidates.append((url, date))
        }
        let newest = candidates.sorted { $0.1 > $1.1 }.prefix(maxFiles)
        for (url, _) in newest {
            if let quota = quota(inTailOfFile: url) { return quota }
        }
        // 极端情况下 tail 截断可能截掉唯一的 rate_limits 行,退回整文件读最新的一个
        if let (url, _) = newest.first, let text = try? String(contentsOf: url, encoding: .utf8) {
            return quota(from: text)
        }
        return nil
    }

    private static func quota(inTailOfFile url: URL) -> Quota? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd(), end > 0 else { return nil }
        try? handle.seek(toOffset: end > UInt64(tailBytes) ? end - UInt64(tailBytes) : 0)
        return quota(from: String(decoding: handle.readData(ofLength: tailBytes), as: UTF8.self))
    }

    private static func quota(from text: String) -> Quota? {
        guard let last = text.split(separator: "\n").reversed().first(where: { $0.contains("rate_limits") }),
              let data = last.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data),
              let limits = findDictionary(named: "rate_limits", in: json) else { return nil }
        let windows = [limits["primary"], limits["secondary"]].compactMap { $0 as? [String: Any] }
        let fiveHour = windows
            .filter { (number($0["window_minutes"]) ?? 0) >= 300 && (number($0["window_minutes"]) ?? 0) < 10_080 }
            .compactMap(remaining(in:))
            .first
        // 周窗口必须真实存在(minutes >= 4320,取最接近 10080 的一个),
        // 否则只有 5h 窗口的会话会把 5 小时额度错标成周额度
        let weeklyWindows = windows.filter { (number($0["window_minutes"]) ?? 0) >= 4_320 }
        let weekly = remaining(forWindowNear: 10_080, in: weeklyWindows)
        if fiveHour == nil && weekly == nil { return nil }
        return Quota(fiveHourRemaining: fiveHour, weeklyRemaining: weekly, updatedAt: .now)
    }
}

func remaining(forWindowNear target: Double, in windows: [[String: Any]]) -> Double? {
    windows
        .compactMap { window -> (distance: Double, remaining: Double)? in
            guard let minutes = number(window["window_minutes"]), let value = remaining(in: window) else { return nil }
            return (abs(minutes - target), value)
        }
        .min(by: { $0.distance < $1.distance })?
        .remaining
}

func findDictionary(named key: String, in value: Any) -> [String: Any]? {
    if let dict = value as? [String: Any] {
        if let match = dict[key] as? [String: Any] { return match }
        for child in dict.values { if let match = findDictionary(named: key, in: child) { return match } }
    } else if let items = value as? [Any] {
        for child in items { if let match = findDictionary(named: key, in: child) { return match } }
    }
    return nil
}

func percentage(in dictionary: [String: Any]?) -> Double? {
    guard let raw = number(dictionary?["used_percent"]) ?? number(dictionary?["usedPercent"]) else { return nil }
    return min(1, max(0, raw > 1 ? raw / 100 : raw))
}

func remaining(in dictionary: [String: Any]) -> Double? {
    percentage(in: dictionary).map { 1 - $0 }
}

func number(_ value: Any?) -> Double? {
    if let value = value as? NSNumber { return value.doubleValue }
    if let value = value as? String { return Double(value) }
    return nil
}

/// 初始化向导保存的密钥:明文存本机 UserDefaults,与自定义套餐密钥同级,不随仓库分发。
enum SecretOverrides {
    static let defaultsKey = "secretOverrides"

    private static var all: [String: String] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return dict
    }

    static func value(named name: String) -> String? {
        guard let value = all[name], !value.isEmpty else { return nil }
        return value
    }

    static func set(name: String, value: String) {
        var dict = all
        dict[name] = value
        if let data = try? JSONEncoder().encode(dict) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    static func remove(name: String) {
        var dict = all
        dict.removeValue(forKey: name)
        if let data = try? JSONEncoder().encode(dict) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}

/// 密钥读取。优先级:环境变量 → 初始化向导保存 → ~/.zshrc。
/// actor 隔离内部缓存:zshrc 按修改时间缓存,改动后 30 秒内下一次拉取自动生效,无需重启 app。
actor SecretStore {
    static let shared = SecretStore()

    private var zshrcCache: (mtime: Date, text: String)?

    func value(named name: String) -> String? {
        if let value = ProcessInfo.processInfo.environment[name], !value.isEmpty { return value }
        if let value = SecretOverrides.value(named: name) { return value }
        guard let source = zshrcText() else { return nil }
        return Self.match(name: name, in: source, allowsComment: false)
    }

    /// 从 zshrc 的指定 plan 块中提取 key（无论是否被注释）
    func valueFromPlan(keyName: String, plan: String) -> String? {
        guard let source = zshrcText(),
              let block = Self.planBlock(source, plan: plan) else { return nil }
        return Self.match(name: keyName, in: String(block), allowsComment: true)
    }

    // MARK: - 纯解析(无副作用,便于单元测试)

    /// 提取 "~~~ PLAN: xxx ~~~" 到 "~~~ END: xxx ~~~" 之间的内容
    static func planBlock(_ source: String, plan: String) -> Substring? {
        guard let start = source.range(of: "~~~ PLAN: \(plan) ~~~", options: .caseInsensitive),
              let end = source.range(of: "~~~ END: \(plan) ~~~", options: .caseInsensitive) else { return nil }
        return source[start.upperBound..<end.lowerBound]
    }

    static func match(name: String, in source: String, allowsComment: Bool) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let commentPrefix = allowsComment ? "#?\\s*" : ""
        let pattern = "\(commentPrefix)(?:export\\s+)?\(escaped)\\s*=\\s*[\\\"']?([^\\s\\\"']+)"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
              let range = Range(match.range(at: 1), in: source) else { return nil }
        return String(source[range])
    }

    private func zshrcText() -> String? {
        let path = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".zshrc")
        let mtime = (try? FileManager.default.attributesOfItem(atPath: path.path)[.modificationDate]) as? Date
        if let zshrcCache, zshrcCache.mtime == mtime { return zshrcCache.text }
        guard let text = try? String(contentsOf: path, encoding: .utf8) else { return nil }
        zshrcCache = (mtime ?? .distantPast, text)
        return text
    }
}
final class MiniMaxProvider: QuotaProvider, @unchecked Sendable {
    let id = "minimax"
    let displayName = "MiniMax"

    func fetchQuota() async throws -> Quota {
        guard let token = await SecretStore.shared.valueFromPlan(keyName: "ANTHROPIC_API_KEY", plan: "minimax") else {
            throw FetchError.parse("ANTHROPIC_API_KEY not found in minimax plan block")
        }
        // Token Plan quota endpoint. Docs: platform.minimax.io/docs/token-plan/faq.
        // The legacy /v1/api/openplatform/coding_plan/remains requires browser cookies,
        // so the bar must call /v1/token_plan/remains instead.
        let data = try await HTTP.getJSON("https://api.minimax.chat/v1/token_plan/remains", token: token)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let decoded = try? decoder.decode(MiniMaxQuotaResponse.self, from: data) else {
            throw FetchError.parse("response decode failed: \(bodySnippet(data))")
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
        return Quota(fiveHourRemaining: interval, weeklyRemaining: weekly, updatedAt: .now)
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

    func fetchQuota() async throws -> Quota {
        let token = await Self.managementToken()
        guard let token else {
            throw FetchError.parse("ZENMUX_MGMT_KEY not found")
        }

        // Management keys currently use sk-mg-v1-*; retain the older sk-mgmt-*
        // spelling for compatibility. Subscription keys (sk-ss-v1-*) cannot
        // access the management quota endpoint.
        let isManagementKey = token.hasPrefix("sk-mg-v1-") || token.hasPrefix("sk-mgmt-")
        guard isManagementKey else {
            throw FetchError.parse("non-management key detected. Quota API requires ZENMUX_MGMT_KEY (sk-mg-v1-*). See: zenmux.ai/platform/management")
        }
        // /v1/management/* requires a Management API Key (not sk-ss-v1-* subscription key).
        // Without the correct key type, the server returns 403.
        // See: zenmux.ai/docs/api/platform/subscription-detail
        let data = try await HTTP.getJSON("https://zenmux.ai/api/v1/management/subscription/detail", token: token)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let decoded = try? decoder.decode(ZenMuxSubscriptionDetail.self, from: data),
              decoded.success,
              let payload = decoded.data else {
            throw FetchError.parse("response decode failed or success=false: \(bodySnippet(data))")
        }
        // usage_percentage is a 0-1 fraction. remaining = 1 - usage.
        let fiveHour = Self.remaining(payload.quota5Hour?.usagePercentage)
        let weekly = Self.remaining(payload.quota7Day?.usagePercentage)
        log("ZenMux: tier=\(payload.plan?.tier ?? "-") 5h=\(fiveHour.map { String(format: "%.2f", $0) } ?? "-") week=\(weekly.map { String(format: "%.2f", $0) } ?? "-")")
        return Quota(fiveHourRemaining: fiveHour, weeklyRemaining: weekly, updatedAt: .now)
    }

    private static func managementToken() async -> String? {
        // Prefer the dedicated Management API key. It intentionally lives outside
        // the switchable provider plan and may be commented out in ~/.zshrc because
        // this app reads the file directly rather than sourcing it in a shell.
        if let key = await SecretStore.shared.value(named: "ZENMUX_MANAGEMENT_KEY") { return key }
        if let key = await SecretStore.shared.value(named: "ZENMUX_MGMT_KEY") { return key }
        return await SecretStore.shared.valueFromPlan(keyName: "ANTHROPIC_API_KEY", plan: "zenmux")
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

/// GitHub Copilot 额度。接口无官方文档但被社区工具广泛使用(pi-copilot-usage、tokscale 等):
/// GET https://api.github.com/copilot_internal/user(Authorization: token <PAT>)
/// → quota_snapshots.{premiumInteractions,chat,completions}.{percentRemaining,unlimited}。
/// premium_interactions 为月度高级请求额度,显示在 W 列;chat/completions 多数套餐 unlimited。
/// 内部接口,字段若变更会导致解析失败,日志会带响应片段。
final class GitHubCopilotProvider: QuotaProvider, @unchecked Sendable {
    let id = "copilot"
    let displayName = "Copilot"

    func fetchQuota() async throws -> Quota {
        guard let token = await Self.patToken() else {
            throw FetchError.parse("未设置 GITHUB_TOKEN(GitHub PAT,需 Copilot 订阅)")
        }
        let data = try await HTTP.getJSON("https://api.github.com/copilot_internal/user", token: token, authPrefix: "token")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let decoded = try? decoder.decode(CopilotUserResponse.self, from: data) else {
            throw FetchError.parse("response decode failed: \(bodySnippet(data))")
        }
        let quota = Self.quotaFraction(decoded)
        guard quota.weekly != nil else {
            throw FetchError.parse("no premium quota snapshot; sku=\(decoded.accessTypeSku ?? "-")")
        }
        log("Copilot: sku=\(decoded.accessTypeSku ?? "-") premium=\(quota.weekly.map(percent) ?? "-")")
        return Quota(fiveHourRemaining: nil, weeklyRemaining: quota.weekly, updatedAt: .now)
    }

    /// PAT 读取顺序:环境变量 → 向导保存 → zshrc
    private static func patToken() async -> String? {
        if let token = await SecretStore.shared.value(named: "GITHUB_TOKEN") { return token }
        return await SecretStore.shared.value(named: "GH_TOKEN")
    }

    /// premium_interactions 剩余比例(0-1);unlimited 视为满格。暴露 static 供单元测试。
    static func quotaFraction(_ decoded: CopilotUserResponse) -> (weekly: Double?, chat: Double?) {
        let snapshots = decoded.quotaSnapshots
        let premium = snapshots?.premiumInteractions.map { snapshot in
            snapshot.unlimited == true ? 1.0 : snapshot.percentRemaining.map { min(1, max(0, $0 / 100)) }
        }
        let chat = snapshots?.chat.map { snapshot in
            snapshot.unlimited == true ? 1.0 : snapshot.percentRemaining.map { min(1, max(0, $0 / 100)) }
        }
        return (premium ?? nil, chat ?? nil)
    }
}

struct CopilotUserResponse: Decodable {
    let accessTypeSku: String?
    let quotaResetDate: String?
    let quotaSnapshots: QuotaSnapshots?

    struct QuotaSnapshots: Decodable {
        let premiumInteractions: Snapshot?
        let chat: Snapshot?
        let completions: Snapshot?
    }

    struct Snapshot: Decodable {
        let percentRemaining: Double?
        let unlimited: Bool?
        let entitlement: Double?
    }
}

/// 智谱 GLM Coding Plan 额度(国内 open.bigmodel.cn / 国际 api.z.ai 同构)。
/// 接口未公开文档,与官方 glm-plan-usage 插件一致:
/// GET /api/monitor/usage/quota/limit;平台对错误也返回 HTTP 200,必须检查 body 的 success 字段。
final class GLMProvider: QuotaProvider, @unchecked Sendable {
    let id: String
    let displayName: String
    let baseURL: String
    let keyNames: [String]
    /// z.ai 文档要求 Authorization 直接放 key 不带 Bearer;bigmodel.cn 保持 Bearer
    let authPrefix: String?

    static let cnBaseURL = "https://open.bigmodel.cn"
    static let cnKeyNames = ["BIGMODEL_API_KEY", "GLM_API_KEY", "ZHIPU_API_KEY"]

    init(id: String = "glm",
         displayName: String = "GLM",
         baseURL: String = GLMProvider.cnBaseURL,
         keyNames: [String] = GLMProvider.cnKeyNames,
         authPrefix: String? = "Bearer") {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
        self.keyNames = keyNames
        self.authPrefix = authPrefix
    }

    /// 国际版(z.ai):域名与密钥不同,接口结构与国内一致
    static func international() -> GLMProvider {
        GLMProvider(id: "zai", displayName: "GLM国际", baseURL: "https://api.z.ai",
                    keyNames: ["ZAI_API_KEY", "Z_AI_API_KEY", "GLM_API_KEY"], authPrefix: nil)
    }

    static func apiKey(named names: [String]) async -> String? {
        for name in names {
            if let key = await SecretStore.shared.value(named: name) { return key }
        }
        return nil
    }

    func fetchQuota() async throws -> Quota {
        guard let token = await Self.apiKey(named: keyNames) else {
            throw FetchError.parse("未设置 \(keyNames.joined(separator: "/"))")
        }
        let data = try await HTTP.getJSON("\(baseURL)/api/monitor/usage/quota/limit", token: token, authPrefix: authPrefix)
        let object = try Self.jsonObject(data)
        if let success = object["success"] as? Bool, !success {
            throw FetchError.parse("API error code=\(object["code"] ?? "-") msg=\(object["msg"] ?? "-")")
        }
        let payload = object["data"] as? [String: Any] ?? object
        let ordered = Self.orderedWindowLimits(in: payload)
        guard !ordered.isEmpty else {
            throw FetchError.parse("no quota entries; keys=\(payload.keys.sorted())")
        }
        let fiveHour = Self.remainingFraction(ordered[0])
        let weekly = ordered.count > 1 ? Self.remainingFraction(ordered[1]) : nil
        log("GLM(\(id)): 5h=\(fiveHour.map(percent) ?? "-") W=\(weekly.map(percent) ?? "-") entries=\(ordered.count)")
        return Quota(fiveHourRemaining: fiveHour, weeklyRemaining: weekly, updatedAt: .now)
    }

    static func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FetchError.parse("response is not JSON: \(bodySnippet(data))")
        }
        return object
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

    static func duration(_ item: [String: Any]) -> Double? {
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

    static func remainingFraction(_ item: [String: Any]) -> Double? {
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
    /// 两个数据源相互独立:任一失败不影响另一个,任一有数据即成功。
    static func fetchModelBreakdown() async -> (rows: [ModelUsage]?, error: String?) {
        guard let token = await apiKey(named: cnKeyNames) else {
            return (nil, "未找到 BIGMODEL_API_KEY(检查 ~/.zshrc 或在初始化向导中填写)")
        }
        var rows: [ModelUsage] = []
        var quotaCount = 0
        var todayCount = 0
        var firstError: String?
        do {
            let quotaRows = parseBreakdown(from: try await HTTP.getJSON("\(cnBaseURL)/api/monitor/usage/quota/limit", token: token))
            quotaCount = quotaRows.count
            rows += quotaRows
        } catch {
            firstError = error.localizedDescription
        }
        do {
            let todayRows = parseModelUsage(from: try await HTTP.getJSON(modelUsageURL(), token: token))
            todayCount = todayRows.count
            rows += todayRows
        } catch {
            if firstError == nil { firstError = error.localizedDescription }
        }
        if rows.isEmpty {
            return (nil, firstError ?? "接口未返回按模型用量数据")
        }
        log("GLM model breakdown: \(rows.count) rows (quota=\(quotaCount) today=\(todayCount))")
        return (rows, nil)
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

    func fetchQuota() async throws -> Quota {
        guard URL(string: config.url)?.scheme != nil else { throw FetchError.invalidURL }
        let data = try await HTTP.getJSON(config.url, token: config.key.isEmpty ? nil : config.key)
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            throw FetchError.parse("response is not JSON: \(bodySnippet(data))")
        }
        let fiveHour = Self.remaining(Self.resolve(config.path5h, in: object), used: config.usedNotRemaining)
        let weekly = config.pathWeekly.isEmpty
            ? nil
            : Self.remaining(Self.resolve(config.pathWeekly, in: object), used: config.usedNotRemaining)
        if fiveHour == nil && weekly == nil {
            throw FetchError.parse("paths not found (5h=\(config.path5h) weekly=\(config.pathWeekly))")
        }
        log("Custom \(config.name): 5h=\(fiveHour.map(percent) ?? "-") W=\(weekly.map(percent) ?? "-")")
        return Quota(fiveHourRemaining: fiveHour, weeklyRemaining: weekly, updatedAt: .now)
    }

    /// "data.limits.0.percentage" 逐段下钻:数字段取数组下标,其余取字典键
    static func resolve(_ path: String, in json: Any) -> Double? {
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

    /// 字段是剩余或已用百分比;0-100 或 0-1 自动识别
    static func remaining(_ raw: Double?, used: Bool) -> Double? {
        guard let raw else { return nil }
        let clamped = min(1, max(0, raw > 1 ? raw / 100 : raw))
        return used ? 1 - clamped : clamped
    }
}

struct ProviderInfo: Sendable {
    let id: String
    let displayName: String
    let summary: String
    /// 需要的密钥环境变量名;nil = 无需密钥
    var secretName: String? = nil
    /// 密钥获取方式提示(初始化向导展示)
    var secretHint: String? = nil

    /// 向导中"需要填密钥"才出现输入框
    var requiresSecret: Bool { secretName != nil }
}

enum ProviderCatalog {
    static let builtin: [ProviderInfo] = [
        ProviderInfo(id: "codex", displayName: "Codex", summary: "读取本地 ~/.codex 会话快照,无需密钥"),
        ProviderInfo(id: "glm", displayName: "GLM(智谱)", summary: "Coding Plan 国内版",
                     secretName: "BIGMODEL_API_KEY", secretHint: "bigmodel.cn 控制台 → 套餐概览 → 新建 API Key"),
        ProviderInfo(id: "zai", displayName: "GLM 国际版", summary: "z.ai Coding Plan(Global)",
                     secretName: "ZAI_API_KEY", secretHint: "z.ai 平台 → API Keys(需国际版 Coding Plan)"),
        ProviderInfo(id: "copilot", displayName: "Copilot", summary: "GitHub Copilot 高级请求额度(月度,显示在 W 列)",
                     secretName: "GITHUB_TOKEN", secretHint: "GitHub → Settings → Developer settings → PAT(需 Copilot 订阅)"),
        ProviderInfo(id: "minimax", displayName: "MiniMax", summary: "Token Plan(读取 ~/.zshrc minimax 块)"),
        ProviderInfo(id: "zenmux", displayName: "ZenMux", summary: "订阅额度",
                     secretName: "ZENMUX_MGMT_KEY", secretHint: "zenmux.ai → Management API Key(sk-mg-v1-*)"),
    ]

    /// 内置 + 用户在管理窗口添加的自定义套餐
    static var all: [ProviderInfo] {
        builtin + CustomProviderStore.load().map { config in
            let host = URL(string: config.url)?.host ?? config.url
            return ProviderInfo(id: config.id, displayName: config.name, summary: "自定义 · \(host)")
        }
    }

    static func info(id: String) -> ProviderInfo? {
        all.first { $0.id == id }
    }

    static func make(id: String) -> (any QuotaProvider)? {
        switch id {
        case "codex": return CodexProvider()
        case "glm": return GLMProvider()
        case "zai": return GLMProvider.international()
        case "copilot": return GitHubCopilotProvider()
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
    // 初始化向导完成后由向导结果接管;未跑向导时保持原有默认(Codex + GLM)
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

    /// 整体替换启用列表(初始化向导完成时调用)
    static func replaceAll(_ ids: Set<String>) {
        UserDefaults.standard.set(ProviderCatalog.all.map(\.id).filter { ids.contains($0) }, forKey: defaultsKey)
    }
}

/// 首次启动初始化向导的完成标记
enum OnboardingStore {
    static let defaultsKey = "hasCompletedOnboarding"

    static var hasCompleted: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }

    static func markCompleted() {
        UserDefaults.standard.set(true, forKey: defaultsKey)
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
        Task { [weak self] in
            let (models, errorMessage) = await GLMProvider.fetchModelBreakdown()
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
    case empty
    case http(Int, snippet: String)
    case parse(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "invalid URL"
        case .empty: return "empty body"
        case .http(let code, let snippet): return "HTTP \(code)\(snippet.isEmpty ? "" : ": \(snippet)")"
        case .parse(let detail): return detail
        }
    }
}

/// 响应体前 160 字节,用于失败日志定位
func bodySnippet(_ data: Data) -> String {
    String(data: data.prefix(160), encoding: .utf8) ?? ""
}

private enum HTTP {
    /// GET JSON。显式绕过 URLCache(额度接口的响应不应复用缓存);
    /// authPrefix 为 Authorization 前缀(默认 "Bearer";z.ai 要求原始 key 传 nil,GitHub 惯例 "token")。
    /// 传输错误直接抛 URLError,HTTP 非 2xx 带响应片段抛 http 错误,便于日志定位。
    static func getJSON(_ address: String, token: String?, authPrefix: String? = "Bearer", timeout: TimeInterval = 12) async throws -> Data {
        guard let url = URL(string: address) else { throw FetchError.invalidURL }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"
        if let token, !token.isEmpty {
            request.setValue(authPrefix.map { "\($0) \(token)" } ?? token, forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw FetchError.http(http.statusCode, snippet: bodySnippet(data))
        }
        guard !data.isEmpty else { throw FetchError.empty }
        return data
    }
}


@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var providers: [any QuotaProvider] = ProviderStore.enabledIDs.compactMap { ProviderCatalog.make(id: $0) }
    private var configWindow: NSWindow?
    private var modelWindow: NSWindow?
    private var onboardingWindow: NSWindow?
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
        // 首次启动弹初始化向导;完成后 applyProviderChange 按用户选择重建套餐
        if !OnboardingStore.hasCompleted {
            openOnboarding()
        }
    }

    @objc private func openOnboarding() {
        if let onboardingWindow {
            onboardingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 540),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "欢迎使用 AI Quota Bar"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: OnboardingView(onFinish: { [weak self, weak window] in
            window?.close()
            self?.onboardingWindow = nil
            self?.applyProviderChange()
        }))
        window.center()
        onboardingWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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

    /// 菜单/定时器入口:同步方法,内部启动异步刷新周期
    @objc private func refresh() {
        Task { @MainActor in await self.refreshCycle() }
    }

    /// 并发拉取全部启用套餐;任一失败记录日志并把该套餐显示为 "—"。
    /// provider 不再各自吞错,失败原因(缺 key、success=false、HTTP 状态等)统一从这里进日志。
    private func refreshCycle() async {
        guard !isRefreshing else {
            log("refresh skipped: previous refresh is still running")
            return
        }
        isRefreshing = true
        log("refresh started")
        if providers.contains(where: { $0.id == "glm" }) {
            modelStore.refreshIfNeeded()
        }
        let results = await withTaskGroup(of: (String, Result<Quota, Error>).self) { group in
            for provider in providers {
                group.addTask {
                    do { return (provider.id, .success(try await provider.fetchQuota())) }
                    catch { return (provider.id, .failure(error)) }
                }
            }
            var collected: [(String, Result<Quota, Error>)] = []
            for await item in group { collected.append(item) }
            return collected
        }
        for (id, result) in results {
            switch result {
            case .success(let quota):
                quotas[id] = quota
            case .failure(let error):
                log("\(id) fetch failed: \(error.localizedDescription)")
                quotas[id] = .unavailable
            }
        }
        isRefreshing = false
        rebuildMenu()
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
        let onboarding = NSMenuItem(title: "初始化向导…", action: #selector(openOnboarding), keyEquivalent: "")
        onboarding.target = self
        menu.addItem(onboarding)
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
                Text("密钥读取顺序:环境变量 → 初始化向导保存(明文本机 UserDefaults)→ ~/.zshrc 同名变量,改动即时生效无需重启。GLM key 在 bigmodel.cn 控制台 → 套餐概览 获取,需绑定 Coding Plan。")
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

/// 首次启动初始化向导:选平台 → 填密钥(可跳过)→ 立即生效。
/// 不再默认启用任何套餐,由用户在向导中勾选;可从菜单随时重跑。
struct OnboardingView: View {
    var onFinish: () -> Void

    @State private var step = 0 // 0 欢迎 · 1 选平台 · 2 密钥
    @State private var selected: Set<String> = []
    @State private var keys: [String: String] = [:]

    private var catalog: [ProviderInfo] { ProviderCatalog.builtin }
    private var selectedInfos: [ProviderInfo] {
        catalog.filter { selected.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch step {
            case 0: welcome
            case 1: pickPlatforms
            default: enterSecrets
            }
            Divider()
            HStack {
                if step > 0 {
                    Button("上一步") { withAnimation { step -= 1 } }
                }
                Spacer()
                if step < 2 {
                    Button(step == 0 ? "开始" : "下一步") { withAnimation { step += 1 } }
                        .disabled(step == 1 && selected.isEmpty)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("完成") { finish() }
                        .disabled(selected.isEmpty)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 500, alignment: .topLeading)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("欢迎使用 AI Quota Bar")
                .font(.title2.weight(.semibold))
            Text("菜单栏常驻显示各 AI 编程套餐的 5 小时 / 一周剩余额度,30 秒自动刷新,点击查看概览。")
            VStack(alignment: .leading, spacing: 6) {
                Label("所有密钥与数据只保存在本机,不经过任何第三方", systemImage: "lock.shield")
                Label("支持 Codex / GLM / GLM 国际版 / Copilot / MiniMax / ZenMux,以及任意 GET JSON 接口", systemImage: "list.bullet.rectangle")
                Label("之后可随时在「管理套餐」中增删或重跑本向导", systemImage: "arrow.triangle.2.circlepath")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            Text("选择你正在使用的平台,开始配置 ↓")
                .font(.callout.weight(.medium))
        }
    }

    private var pickPlatforms: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("选择要监控的套餐")
                .font(.title3.weight(.semibold))
            ForEach(catalog, id: \.id) { info in
                Toggle(isOn: Binding(
                    get: { selected.contains(info.id) },
                    set: { on in
                        if on { selected.insert(info.id) } else { selected.remove(info.id) }
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
            if selected.isEmpty {
                Text("至少选择一个套餐才能继续。")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var enterSecrets: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("填写 API 密钥(可跳过)")
                .font(.title3.weight(.semibold))
            let needingKeys = selectedInfos.filter(\.requiresSecret)
            if needingKeys.isEmpty {
                Text("所选套餐均无需密钥。")
                    .foregroundStyle(.secondary)
            }
            ForEach(needingKeys, id: \.id) { info in
                VStack(alignment: .leading, spacing: 4) {
                    SecureField(info.secretName ?? "", text: bindingKey(info))
                        .textFieldStyle(.roundedBorder)
                    Text(info.secretHint ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Label("密钥明文保存在本机 UserDefaults,不随仓库分发、不出进程", systemImage: "lock")
                Label("留空 = 暂不保存;稍后写入 ~/.zshrc 同名变量也行,改动即时生效,无需重启", systemImage: "clock.arrow.circlepath")
                Label("MiniMax 从 ~/.zshrc 的 minimax PLAN 块读取 ANTHROPIC_API_KEY", systemImage: "terminal")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func bindingKey(_ info: ProviderInfo) -> Binding<String> {
        Binding(get: { keys[info.id] ?? "" }, set: { keys[info.id] = $0 })
    }

    private func finish() {
        for info in selectedInfos {
            guard let name = info.secretName, let key = keys[info.id], !key.isEmpty else { continue }
            SecretOverrides.set(name: name, value: key)
        }
        ProviderStore.replaceAll(selected)
        OnboardingStore.markCompleted()
        onFinish()
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
