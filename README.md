# AI Quota Bar

macOS 菜单栏的 AI 编程套餐额度监控条。原生 Swift/AppKit,零第三方依赖,密钥不出本机。

菜单栏常驻显示各套餐的 5 小时(H)/ 一周(W)剩余额度分段彩条:绿 ≥70%,橙 40–69%,红 <40%。30 秒自动刷新,点击查看大图概览。

```
Codex ▐●●●●●●○○○ 71%▐   GLM ▐●●●●●●●●○ 91%▐
      ▐●●●●●○○○○ 69%▐       ▐●●●●●●●●○ 88%▐
```

## 功能

- **菜单栏概览**:宽度按启用套餐数自适应;点击弹出大图,含每个套餐 H/W 与最近更新时间
- **管理套餐**(⌘,):内置 Codex / GLM / MiniMax / ZenMux,勾选即启停,实时生效并持久化
- **模型配置**:GLM 按"5 小时窗口 / 本周 / 今日"列出各模型用量与占比,勾选控制哪些模型显示在概览下方
- **添加套餐**:在管理窗口里把任意"GET 返回 JSON"的额度接口接入为新套餐,点分字段路径取值,无需写代码
- **失败可观测**:某套餐拉取失败时对应列显示"—",原因写入日志,不显示编造数字

## 套餐支持

| 套餐 | 数据来源 | 密钥 | 默认 |
|---|---|---|---|
| Codex | 本地 `~/.codex/sessions/*.jsonl` 的 `rate_limits` 快照(不联网) | 无需 | 启用 |
| GLM(智谱 BigModel) | `GET /api/monitor/usage/quota/limit`;按模型用量另用 `usageDetails` 与 `model-usage` 接口 | `BIGMODEL_API_KEY` | 启用 |
| MiniMax | `api.minimax.chat/v1/token_plan/remains` | `~/.zshrc` `minimax` 块内 `ANTHROPIC_API_KEY` | 关闭 |
| ZenMux | `zenmux.ai/api/v1/management/subscription/detail` | `ZENMUX_MGMT_KEY`(sk-mg-v1-*) | 关闭 |
| 自定义 | 管理窗口"添加套餐…"配置的任意接口 | 可选;明文存本地 UserDefaults | 手动添加 |

## 安装

要求:macOS 14+,Swift 6 工具链(Xcode 16+ 或 swiftly)。

```sh
git clone https://github.com/ListenTo-TheWind/AIQuotaBar.git
cd AIQuotaBar
scripts/install.sh     # release 构建 → 打包 .app → 装配 LaunchAgent 开机自启 → 启动
```

日常控制与卸载:

```sh
scripts/quota-bar start | stop | status        # 日常控制

launchctl bootout gui/$(id -u)/local.ai-quota-bar
rm ~/Library/LaunchAgents/local.ai-quota-bar.plist
rm -rf AIQuotaBar.app                          # 卸载
```

## 配置密钥

所有密钥只保存在你本机,不随仓库分发、不出进程。

- **GLM**:bigmodel.cn 控制台 → 套餐概览 → 新建 API Key(普通 API key 即可查询 Coding Plan 额度),写入 `~/.zshrc` 后重启 app:
  ```sh
  export BIGMODEL_API_KEY=你的key
  ```
- **MiniMax**:`~/.zshrc` 中 `~~~ PLAN: minimax ~~~` 块内的 `ANTHROPIC_API_KEY`(被注释的行也能读取)
- **ZenMux**:Management API Key,export `ZENMUX_MGMT_KEY`(sk-ss-v1-* 订阅 key 无权限,需 sk-mg-v1-*)
- **Codex**:无需配置,读取本机已有会话

## 使用说明

菜单栏点击 bar 弹出菜单:

- **刷新额度**(⌘R):立即重拉全部启用的套餐
- **管理套餐…**(⌘,):勾选启停;"添加套餐…"表单依次填名称、接口 URL、可选 API Key、5 小时与一周字段路径、字段语义(剩余/已用百分比)。路径如 `data.limits.0.percentage`,数字段表示数组下标;取值 0–100 或 0–1 自动识别。添加后自动启用,自定义条目可删除。注意自定义 API Key 为明文存本地 UserDefaults
- **模型配置**:目前仅 GLM。按"5 小时窗口 / 本周 / 今日"三组展示模型用量与占比,勾选控制概览中显示哪些模型(未配置 = 全部显示)
- **退出**

## 工作原理

- 定时器每 30 秒并发拉取启用的套餐;GLM 的按模型用量额外拉取,节流为最长 150 秒一次
- **Codex**:扫描 `~/.codex/sessions` 最近 12 个 rollout 文件,取最新一条 `rate_limits` 解析(`primary` ≈ 5 小时窗,`secondary` ≈ 周,按 `window_minutes` 区分)。Codex 周窗口为滚动 7 天制,数值可能跳变,属正常
- **GLM**:`data.limits[]` 按窗口时长排序区分 5h 与周窗口;平台对错误也返回 HTTP 200,代码以 body 的 `success` 字段为准。监控接口无官方公开文档,字段若变更导致解析失败,日志会打印原因
- **MiniMax**:Token Plan 多模型额度取最紧剩余百分比
- **ZenMux**:订阅详情接口的 5 小时 / 7 天 usage_percentage

## 排障

- 日志:`/tmp/aiq-state.log`
- **菜单栏看不到图标**(macOS 26 常见,非本应用问题):
  1. 菜单栏空间不足时新图标被收进">"折叠区:点 ">" 找它,或 ⌘-拖走其他图标腾空间
  2. 被系统隐藏:`defaults delete com.apple.controlcenter "NSStatusItem Visible Item-N"` 后 `killall ControlCenter`(操作前先备份该 plist)
  3. 系统设置 → 控制中心 → 菜单栏,管理各项显隐
- **某列一直 "—"**:看日志中对应 provider 的行(GLM 无 key、接口 `success=false`、自定义套餐路径没取到值等都有明确日志)
- **自定义套餐没数据**:核对 URL 可直接 curl 返回 JSON、字段路径逐级存在、数值为百分比(0–100 或 0–1)

## 代码结构

```
Sources/AIQuotaBar/main.swift   # 全部实现
  ├─ QuotaProvider 协议                       # fetch(completion:) -> Quota(5h/周 剩余比例)
  ├─ CodexProvider / GLMProvider / MiniMaxProvider / ZenMuxProvider
  ├─ CustomProvider / CustomProviderStore     # 自定义套餐(GET JSON + 字段路径),UserDefaults 持久化
  ├─ GLMProvider 按模型用量                    # ModelUsage + fetchModelBreakdown(usageDetails + model-usage)
  ├─ ModelStore / ModelUsageStore             # 概览模型显隐 + 按模型用量共享数据源(节流)
  ├─ SecretStore                              # 密钥:环境变量 → ~/.zshrc(支持 PLAN 块内注释行)
  ├─ AppDelegate                              # 状态栏、刷新循环、菜单、管理/模型配置窗口
  ├─ QuotaOverviewView / ConfigView / ModelConfigView
  └─ MenuBarImage                             # 菜单栏分段条自绘(按启用数自适应宽度)
archive/pre-glm-main.swift                    # GLM 接入前的旧版存档(不参与编译)
```

新增内置套餐:实现 `QuotaProvider` → 在 `ProviderCatalog.builtin` 与 `make(id:)` 各登记一行;通用场景直接在管理窗口"添加套餐…"配置即可。

## License

MIT(见 LICENSE 文件)
