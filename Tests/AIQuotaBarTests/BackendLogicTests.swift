import Foundation
import Testing
@testable import AIQuotaBar

/// 后端纯解析逻辑的单元测试:窗口分类、字段路径下钻、百分比换算、zshrc 解析、Copilot 快照。
struct BackendLogicTests {
    // MARK: - Codex 窗口分类

    @Test func codexWindowsPrimarySecondary() {
        // Codex 真实 schema:primary=5h(300min),secondary=周(10080min),used_percent 为已用
        let limits: [String: Any] = [
            "primary": ["used_percent": 29, "window_minutes": 300],
            "secondary": ["used_percent": 31, "window_minutes": 10_080],
        ]
        let windows = [limits["primary"]!, limits["secondary"]!] as! [[String: Any]]
        let fiveHour = windows
            .filter { (number($0["window_minutes"]) ?? 0) >= 300 && (number($0["window_minutes"]) ?? 0) < 10_080 }
            .compactMap(remaining(in:)).first
        let weekly = remaining(forWindowNear: 10_080, in: windows.filter { (number($0["window_minutes"]) ?? 0) >= 4_320 })
        #expect(fiveHour == 0.71)
        #expect(weekly == 0.69)
    }

    /// 回归:只有 5h 窗口的会话不得把 5 小时额度错标成周额度
    @Test func codexWeeklyAbsentWhenOnlyFiveHourWindow() {
        let windows: [[String: Any]] = [["used_percent": 29, "window_minutes": 300]]
        let fiveHour = windows.compactMap(remaining(in:)).first
        let weekly = remaining(forWindowNear: 10_080, in: windows.filter { (number($0["window_minutes"]) ?? 0) >= 4_320 })
        #expect(fiveHour != nil)
        #expect(weekly == nil)
    }

    @Test func percentageNormalizesOverOne() {
        #expect(percentage(in: ["used_percent": 45]) == 0.45)
        #expect(percentage(in: ["used_percent": 0.3]) == 0.30)
        #expect(percentage(in: ["usedPercent": "12.5"]) == 0.125)
        #expect(percentage(in: ["foo": 1]) == nil)
    }

    // MARK: - GLM 窗口排序与占比

    @Test func glmOrdersWindowsByDuration() {
        // 实测 schema:unit=3 表示小时、unit=6 表示周;输入乱序,输出必须 5h 在前
        let payload: [String: Any] = [
            "limits": [
                ["type": "TOKENS_LIMIT", "unit": 6, "number": 1, "percentage": 20],
                ["type": "CREDIT_LIMIT", "unit": 3, "number": 5, "percentage": 99],
                ["type": "TOKENS_LIMIT", "unit": 3, "number": 5, "percentage": 10],
            ]
        ]
        let ordered = GLMProvider.orderedWindowLimits(in: payload)
        #expect(ordered.count == 2)
        #expect(GLMProvider.remainingFraction(ordered[0]) == 0.90)
        #expect(GLMProvider.remainingFraction(ordered[1]) == 0.80)
    }

    @Test func glmRemainingFractionFromTotals() {
        let item: [String: Any] = ["usage": 1_000, "remaining": 250]
        #expect(GLMProvider.remainingFraction(item) == 0.25)
        #expect(GLMProvider.remainingFraction(["usage": 1_000]) == nil)
    }

    /// 国际版与国内版共用解析,但域名、密钥、认证方式不同
    @Test func glmInternationalInstance() {
        let provider = GLMProvider.international()
        #expect(provider.id == "zai")
        #expect(provider.baseURL == "https://api.z.ai")
        #expect(provider.authPrefix == nil) // z.ai 要求原始 key,不带 Bearer
        #expect(GLMProvider().authPrefix == "Bearer") // 国内保持 Bearer
    }

    // MARK: - 自定义套餐路径下钻与百分比换算

    @Test func customResolveDrillsArraysAndDictionaries() {
        let json: [String: Any] = [
            "data": ["limits": [["percentage": 71], ["percentage": 88]]]
        ]
        #expect(CustomProvider.resolve("data.limits.0.percentage", in: json) == 71)
        #expect(CustomProvider.resolve("data.limits.1.percentage", in: json) == 88)
        #expect(CustomProvider.resolve("data.limits.2.percentage", in: json) == nil)
        #expect(CustomProvider.resolve("missing.path", in: json) == nil)
        #expect(CustomProvider.resolve("", in: json) == nil)
    }

    @Test func customRemainingConversion() {
        // 0-100 与 0-1 自动识别;used 表示字段是"已用百分比"需翻转;超界截断
        #expect(CustomProvider.remaining(88, used: false) == 0.88)  // 剩余 88%
        #expect(CustomProvider.remaining(12, used: true) == 0.88)   // 已用 12%
        #expect(CustomProvider.remaining(0.88, used: false) == 0.88) // 0-1 直接归一
        #expect(CustomProvider.remaining(140, used: false) == 1.0)  // 剩余超 100% 截到 1
        #expect(CustomProvider.remaining(140, used: true) == 0.0)   // 已用超 100% 剩 0
        #expect(CustomProvider.remaining(nil, used: false) == nil)
    }

    // MARK: - zshrc 密钥解析

    @Test func planBlockExtraction() {
        let source = """
        export OTHER_KEY=zzz
        # ~~~ PLAN: minimax ~~~
        # export ANTHROPIC_API_KEY=sk-abc123
        # ~~~ END: minimax ~~~
        """
        let block = SecretStore.planBlock(source, plan: "minimax")
        #expect(SecretStore.match(name: "ANTHROPIC_API_KEY", in: String(block ?? ""), allowsComment: true) == "sk-abc123")
        #expect(SecretStore.planBlock("no markers here", plan: "minimax") == nil)
    }

    @Test func matchHandlesExportAndQuotes() {
        #expect(SecretStore.match(name: "BIGMODEL_API_KEY", in: "export BIGMODEL_API_KEY=\"abc-123\"", allowsComment: false) == "abc-123")
        #expect(SecretStore.match(name: "K", in: "K = 'xyz'", allowsComment: false) == "xyz")
        #expect(SecretStore.match(name: "K", in: "K=v1 K2=v2", allowsComment: false) == "v1")
        #expect(SecretStore.match(name: "MISSING", in: "export K=v", allowsComment: false) == nil)
    }

    // MARK: - Copilot quota_snapshots

    /// 回归:snake_case 响应字段解码 + unlimited 视为满格 + 百分比归一
    @Test func copilotQuotaParsing() throws {
        let json = """
        {
          "access_type_sku": "copilot_pro",
          "quota_reset_date": "2026-11-01",
          "quota_snapshots": {
            "premium_interactions": {"percent_remaining": 42.0, "entitlement": 300},
            "chat": {"unlimited": true},
            "completions": {"unlimited": true}
          }
        }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let decoded = try decoder.decode(CopilotUserResponse.self, from: Data(json.utf8))
        let quota = GitHubCopilotProvider.quotaFraction(decoded)
        #expect(quota.weekly == 0.42)
        #expect(quota.chat == 1.0)
        #expect(decoded.accessTypeSku == "copilot_pro")
    }

    @Test func copilotQuotaClampsAndMissing() {
        let decoded = CopilotUserResponse(
            accessTypeSku: nil, quotaResetDate: nil,
            quotaSnapshots: .init(
                premiumInteractions: .init(percentRemaining: 140, unlimited: false, entitlement: nil),
                chat: nil, completions: nil))
        let quota = GitHubCopilotProvider.quotaFraction(decoded)
        #expect(quota.weekly == 1.0) // 超过 100% 截断
        #expect(quota.chat == nil)

        let empty = CopilotUserResponse(accessTypeSku: nil, quotaResetDate: nil, quotaSnapshots: nil)
        #expect(GitHubCopilotProvider.quotaFraction(empty).weekly == nil)
    }
}
