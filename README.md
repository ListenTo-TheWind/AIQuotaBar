# AI Quota Bar

macOS 菜单栏的 AI 编程套餐额度监控条。原生 Swift/AppKit,无第三方依赖。

菜单栏直接显示各套餐的 5 小时(H)/一周(W)剩余额度分段彩条:绿 ≥70%,橙 40–69%,红 <40%。点击查看大图概览,30 秒自动刷新。

```
Codex ▐●●●●●●○○○ 71%▐   GLM ▐●●●●●●●●○ 91%▐
      ▐●●●●●○○○○ 69%▐       ▐●●●●●●●●○ 88%▐
```

## 套餐支持

| 套餐 | 数据来源 | 默认 |
|---|---|---|
| Codex | 本地 `~/.codex/sessions/*.jsonl` 的 `rate_limits` 快照,无网络请求 | 启用 |
| GLM(智谱 BigModel) | `GET open.bigmodel.cn/api/monitor/usage/quota/limit` | 启用 |
| MiniMax | `api.minimax.chat/v1/token_plan/remains` | 关闭 |
| ZenMux | `zenmux.ai/api/v1/management/subscription/detail` | 关闭 |

启用/关闭:菜单栏点击 → **管理套餐…**(⌘,)勾选即生效,持久化在 UserDefaults(`enabledProviders`)。API 失效时可设"备用值"兜底显示。

## GLM 接入说明

- 认证:`Authorization: Bearer <BIGMODEL_API_KEY>`,key 从 `~/.zshrc` 读取(环境变量优先)。普通 API key 即可查到 Coding Plan 额度;套餐专用 key 在 bigmodel.cn 控制台 → 套餐概览页获取
- 响应要点:`data.limits[]` 每条含 `type`(`CREDIT_LIMIT`)、`unit`+`number`(窗口长度,3=小时/6=周)、`usage`(总额)、`currentValue`(已用)、`percentage`(已用百分比)、`nextResetTime`(epoch ms);**错误也返回 HTTP 200**,必须检查 body 的 `success` 字段
- 该接口无公开文档,与官方 `glm-plan-usage` 插件、CodexBar 所用端点一致

## 构建与安装

```sh
scripts/install.sh        # release 构建 + 打包 .app + 装配 LaunchAgent 开机自启 + 启动
```

日常控制:

```sh
scripts/quota-bar start | stop | status | debug
```

- 日志:`/tmp/aiq-state.log`
- 开机自启:`~/Library/LaunchAgents/local.ai-quota-bar.plist`(install.sh 自动装配;卸载即删除该文件)

## 代码结构

```
Sources/AIQuotaBar/main.swift   # 全部实现(约 870 行)
  ├─ QuotaProvider 协议          # fetch(completion:) -> Quota(5h/周 剩余比例)
  ├─ CodexProvider / GLMProvider / MiniMaxProvider / ZenMuxProvider
  ├─ ProviderCatalog / ProviderStore   # 套餐目录 + 启用状态持久化
  ├─ SecretStore                 # 密钥:环境变量 → ~/.zshrc(支持 PLAN 块内注释行)
  ├─ AppDelegate                 # 状态栏、刷新循环、菜单、管理窗口
  ├─ QuotaOverviewView           # 点击弹出的大图概览
  └─ MenuBarImage                # 菜单栏分段条自绘(按启用数自适应宽度)
archive/pre-glm-main.swift      # GLM 接入前的原始版本存档
```

新增套餐:实现 `QuotaProvider` → 在 `ProviderCatalog.all` 和 `make(id:)` 各登记一行即可出现在管理窗口。

## 新增套餐踩坑提醒

- 菜单栏图标被吞:macOS 26 菜单栏空间不足时新图标会进"折叠区";图标不显示先查 `com.apple.controlcenter` 的 `NSStatusItem Visible Item-N` 黑名单,再看系统设置 → 菜单栏 的应用权限
- SwiftPM 可执行目标目录里的 `.bak` 等文件会产生构建警告,放 `archive/` 之外需在 Package.swift 排除
