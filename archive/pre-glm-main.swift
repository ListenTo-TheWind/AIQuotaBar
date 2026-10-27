import AppKit
import Foundation

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
final class ManualProvider: QuotaProvider, @unchecked Sendable {
    let id: String
    let displayName: String

    init(id: String, displayName: String) { self.id = id; self.displayName = displayName }

    func fetch(completion: @escaping @Sendable (Result<Quota, Error>) -> Void) {
        completion(.success(manualQuota(id: id)))
    }
}

private func manualQuota(id: String) -> Quota {
    let defaults = UserDefaults.standard
    // No hardcoded sample values: the bar shows "—" until the user either saves
    // values in the settings dialog or the live API returns real data.
    let fiveHour = defaults.object(forKey: "\(id).fiveHour") as? Double
        ?? defaults.object(forKey: "\(id).shortTerm") as? Double
    let weekly = defaults.object(forKey: "\(id).weekly") as? Double
        ?? defaults.object(forKey: "\(id).longTerm") as? Double
    return Quota(fiveHourRemaining: fiveHour, weeklyRemaining: weekly, updatedAt: .now)
}

final class MiniMaxProvider: QuotaProvider, @unchecked Sendable {
    let id = "minimax"
    let displayName = "MiniMax"

    func fetch(completion: @escaping @Sendable (Result<Quota, Error>) -> Void) {
        guard let token = SecretStore.valueFromPlan(keyName: "ANTHROPIC_API_KEY", plan: "minimax") else {
            log("MiniMax: ANTHROPIC_API_KEY not found in minimax plan block; falling back to manual value if configured")
            completion(.success(manualQuota(id: id)))
            return
        }
        // Token Plan quota endpoint. Docs: platform.minimax.io/docs/token-plan/faq.
        // The legacy /v1/api/openplatform/coding_plan/remains requires browser cookies,
        // so the bar must call /v1/token_plan/remains instead.
        fetchData(url: "https://api.minimax.chat/v1/token_plan/remains", token: token) { result in
            switch result {
            case .failure(let error):
                log("MiniMax fetch failed: \(error.localizedDescription)")
                completion(.success(manualQuota(id: self.id)))
            case .success(let data):
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                guard let decoded = try? decoder.decode(MiniMaxQuotaResponse.self, from: data) else {
                    let snippet = String(data: data.prefix(160), encoding: .utf8) ?? ""
                    log("MiniMax: response decode failed: \(snippet)")
                    completion(.success(manualQuota(id: self.id)))
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
            log("ZenMux: ZENMUX_MGMT_KEY not found; falling back to manual value if configured")
            completion(.success(manualQuota(id: id)))
            return
        }
        // Management keys currently use sk-mg-v1-*; retain the older sk-mgmt-*
        // spelling for compatibility. Subscription keys (sk-ss-v1-*) cannot
        // access the management quota endpoint.
        let isManagementKey = token.hasPrefix("sk-mg-v1-") || token.hasPrefix("sk-mgmt-")
        if !isManagementKey {
            log("ZenMux: non-management key detected. Quota API requires ZENMUX_MGMT_KEY (sk-mg-v1-*). See: zenmux.ai/platform/management")
            completion(.success(manualQuota(id: id)))
            return
        }
        // /v1/management/* requires a Management API Key (not sk-ss-v1-* subscription key).
        // Without the correct key type, the server returns 403.
        // See: zenmux.ai/docs/api/platform/subscription-detail
        fetchData(url: "https://zenmux.ai/api/v1/management/subscription/detail", token: token) { result in
            switch result {
            case .failure(let error):
                log("ZenMux fetch failed: \(error.localizedDescription)")
                completion(.success(manualQuota(id: self.id)))
            case .success(let data):
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                guard let decoded = try? decoder.decode(ZenMuxSubscriptionDetail.self, from: data),
                      decoded.success,
                      let payload = decoded.data else {
                    let snippet = String(data: data.prefix(160), encoding: .utf8) ?? ""
                    log("ZenMux: response decode failed or success=false: \(snippet)")
                    completion(.success(manualQuota(id: self.id)))
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

private func fetchData(url address: String, token: String, completion: @escaping @Sendable (Result<Data, Error>) -> Void) {
    guard let url = URL(string: address) else { completion(.failure(FetchError.invalidURL)); return }
    var request = URLRequest(url: url, timeoutInterval: 12)
    request.httpMethod = "GET"
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
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
    private let providers: [QuotaProvider] = [
        CodexProvider(),
        MiniMaxProvider(),
        ZenMuxProvider()
    ]
    private var quotas: [String: Quota] = [:]
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var refreshTimer: Timer?
    private var isRefreshing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.set(
            210,
            forKey: "NSStatusItem Preferred Position AIQuotaBar.MainQuota"
        )
        statusItem.autosaveName = "AIQuotaBar.MainQuota"
        statusItem.button?.toolTip = "AI Quota Bar · 正在读取额度…"
        statusItem.button?.title = ""
        statusItem.button?.image = MenuBarImage.make(
            providers: providers.map { ($0.displayName, Quota.unavailable) }
        )
        statusItem.button?.imagePosition = .imageOnly
        rebuildMenu()
        log("status item visible=\(statusItem.isVisible) frame=\(String(describing: statusItem.button?.window?.frame))")
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refreshTimer?.tolerance = 3
    }

    @objc private func refresh() {
        guard !isRefreshing else {
            log("refresh skipped: previous refresh is still running")
            return
        }
        isRefreshing = true
        log("refresh started")
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
        overview.view = QuotaOverviewView(
            providers: providers.map { ($0.displayName, quotas[$0.id] ?? .unavailable) }
        )
        menu.addItem(overview)
        menu.addItem(.separator())
        let refresh = NSMenuItem(title: "刷新额度", action: #selector(refresh), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)
        let settings = NSMenuItem(title: "设置 MiniMax / ZenMux 备用值…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 AI Quota Bar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu
        updateStatusTitle()
    }

    private func updateStatusTitle() {
        let values = providers.map { quotas[$0.id] ?? .unavailable }
        // Keep the item inside the right safe area on notched MacBooks. AppKit adds
        // roughly 16 pt of button chrome around this explicit length.
        statusItem.length = 250
        statusItem.button?.title = ""
        statusItem.button?.image = MenuBarImage.make(providers: zip(providers, values).map { ($0.displayName, $1) })
        statusItem.button?.imagePosition = .imageOnly
        let newest = values.map(\.updatedAt).filter { $0 != .distantPast }.max()
        statusItem.button?.toolTip = newest.map {
            "AI Quota Bar · 更新于 \($0.formatted(date: .omitted, time: .standard))"
        } ?? "AI Quota Bar · 暂无额度数据"
        let screenFrame = statusItem.button?.window.map { $0.convertToScreen(NSRect(origin: .zero, size: $0.frame.size)) }
        log("updated status item visible=\(statusItem.isVisible) frame=\(String(describing: screenFrame))")
    }

    @objc private func openSettings() {
        let alert = NSAlert()
        alert.messageText = "手动设置备用额度"
        alert.informativeText = "API 密钥不可用时显示这些值；实时 API 返回成功后会自动覆盖备用值。请输入 0–100 的剩余百分比，留空则显示“—”。"
        let fields = ["MiniMax · 5 小时", "MiniMax · 一周", "ZenMux · 5 小时", "ZenMux · 一周"].map { label -> NSTextField in
            let field = NSTextField(string: "")
            field.placeholderString = "\(label)（留空 = —）"
            return field
        }
        let keys = ["minimax.fiveHour", "minimax.weekly", "zenmux.fiveHour", "zenmux.weekly"]
        for (field, key) in zip(fields, keys) {
            if let stored = UserDefaults.standard.object(forKey: key) as? Double {
                field.stringValue = String(Int(stored * 100))
            }
        }
        let stack = NSStackView(views: fields)
        stack.orientation = .vertical; stack.spacing = 8; stack.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 0, right: 0)
        alert.accessoryView = stack
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            for (field, key) in zip(fields, keys) {
                let trimmed = field.stringValue.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    UserDefaults.standard.removeObject(forKey: key)
                } else {
                    let value = min(100, max(0, field.doubleValue)) / 100
                    UserDefaults.standard.set(value, forKey: key)
                }
            }
            refresh()
        }
    }
}

final class QuotaOverviewView: NSView {
    private let providers: [(name: String, quota: Quota)]

    init(providers: [(String, Quota)]) {
        self.providers = providers.map { (name: $0.0, quota: $0.1) }
        super.init(frame: NSRect(x: 0, y: 0, width: 468, height: 158))
    }
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let titleStyle = NSMutableParagraphStyle()
        titleStyle.lineBreakMode = .byTruncatingTail
        "AI Quota Bar".draw(
            in: NSRect(x: 16, y: 128, width: 180, height: 18),
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
            in: NSRect(x: 210, y: 129, width: 242, height: 16),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .regular),
                .foregroundColor: NSColor.tertiaryLabelColor,
                .paragraphStyle: right
            ]
        )

        NSColor.separatorColor.setFill()
        NSRect(x: 14, y: 118, width: bounds.width - 28, height: 1).fill()

        let outerPadding: CGFloat = 14
        let gap: CGFloat = 12
        let columnWidth = (bounds.width - outerPadding * 2 - gap * 2) / 3

        for (index, provider) in providers.enumerated() {
            let x = outerPadding + CGFloat(index) * (columnWidth + gap)
            drawColumn(provider, in: NSRect(x: x, y: 8, width: columnWidth, height: 102))
            if index < providers.count - 1 {
                NSColor.separatorColor.withAlphaComponent(0.7).setFill()
                NSRect(x: x + columnWidth + gap / 2, y: 14, width: 1, height: 88).fill()
            }
        }
    }

    private func drawColumn(_ provider: (name: String, quota: Quota), in rect: NSRect) {
        provider.name.draw(
            in: NSRect(x: rect.minX + 4, y: rect.maxY - 22, width: rect.width - 8, height: 18),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 15, weight: .bold),
                .foregroundColor: NSColor.labelColor
            ]
        )

        drawMetric(title: "H", subtitle: "5 小时", value: provider.quota.fiveHourRemaining, y: 49, in: rect)
        drawMetric(title: "W", subtitle: "一周", value: provider.quota.weeklyRemaining, y: 14, in: rect)
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
        let size = NSSize(width: 250, height: 28)
        let image = NSImage(size: size)
        image.lockFocus()
        let widths: [CGFloat] = [79, 84, 79]
        var x: CGFloat = 2
        for (index, item) in providers.prefix(3).enumerated() {
            let width = widths[index]
            drawProvider(item, in: NSRect(x: x, y: 0, width: width, height: size.height))
            x += width
            if index < min(providers.count, 3) - 1 {
                NSColor.white.withAlphaComponent(0.48).setFill()
                NSRect(x: x + 1, y: 2, width: 1, height: 24).fill()
                x += 3
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
