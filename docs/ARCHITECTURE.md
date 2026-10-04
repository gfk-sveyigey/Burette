# 架构设计

## 1. 总览

应用分三层，依赖方向自上而下，Services 层不依赖 SwiftUI，便于单元测试。

    Features (SwiftUI View + ViewModel)
        │
        ▼
    Services (网络 / diff / AI / 存储)
        │
        ▼
    Models (纯数据，Codable)

核心数据流：

    ChatView ─▶ ChatViewModel ─▶ AIClient ─▶ DiffParser ─▶ PatchApplier
                                                  │
                                                  ▼
                                          WorkspaceManager (本地工作区)
                                                  │
                                                  ▼
    ChangesView ─▶ GitDataService ─▶ GitHubClient ─▶ GitHub REST API

## 2. 模块职责

| 目录 | 职责 |
|---|---|
| `App/` | 应用入口、依赖装配、全局环境对象 |
| `Models/` | Repository、AIProviderConfig、ChatMessage、FileChange、diff 相关模型 |
| `Services/Keychain/` | PAT 与 API Key 的安全存储 |
| `Services/Diff/` | unified diff 解析与回写 |
| `Services/AI/` | OpenAI 兼容接口调用（工具 / 流式）与提示词构造、Agent 工具定义（`AgentTools`） |
| `Services/GitHub/` | REST 客户端与 Git Data API 提交流程 |
| `Services/Workspace/` | 本地工作区读写、仓库与配置持久化 |
| `Features/` | 按功能划分的界面：Auth / Repositories / Chat / Changes / Editor / Settings |
| `Support/` | 通用视图与工具：Liquid Glass 封装、文件路径树（`FileNode`）、代码高亮与行号栏（`CodeEditor` / `LineNumberTextView` / `CodeHighlighter`）、双指手势（`TwoFingerPanCatcher`）、日志（`Log` / `LogCenter` / `CrashReporter`） |

## 3. 关键设计

### 3.1 工作区模型

本地只保存「工作区文件 + 元数据」，不维护 `.git` 目录：

- 仓库元数据：owner/repo、默认分支、当前分支、base commit SHA、上次同步时间
- 文件：按仓库分目录存放的纯工作区副本

这样离线也能编辑；联网后基于 base commit 重放改动并推送。

### 3.2 diff 解析与应用

`DiffExtractor` 会合并回复里**所有**包含 diff 的围栏代码块（模型常把每个文件放进各自的代码块，只取第一块会导致多文件改动只能应用一个文件）。`DiffParser` 把 AI 返回的文本解析为 `[FilePatch]`，逐文件包含若干 `DiffHunk`；解析遇到新的文件头（`diff --git` / `--- x` + `+++ y`）会收尾上一个文件，即使模型给的行数有偏差也不会把后续文件吞掉。
`PatchApplier` 采用「上下文匹配 + 行偏移累积」把 hunk 写回原文：

- 只按 `@@` 里的行号定位，同时校验上下文行，避免错位覆盖
- 上下文不匹配时抛出可读错误（例如「第 N 个 hunk 上下文不匹配」）
- 支持新增文件（`/dev/null` 起始）与删除文件

### 3.3 GitHub 提交

多文件提交走 Git Data API 六步（ref → commit → blob × N → tree → commit → 更新 ref），
见 REQUIREMENTS.md 第七节。任何一步失败都中止，不产生半成品提交。

### 3.4 凭据管理

PAT 与 AI API Key 只存 Keychain；持久化配置里仅保存 Keychain 条目的引用 id，
磁盘上不出现明文密钥。

### 3.5 持久化

定义 `PersistenceStore` 协议，MVP 用 `JSONStore`（JSON 文件）实现，
后续可无痛替换为 SQLite，调用方无需改动。

### 3.6 日志

`Support/Log.swift` 提供统一入口 `Log.debug/info/warning/error(_:_:)`，按分类
（app / ui / github / ai / workspace / diff / persistence）写入：

- OSLog（可在 Console.app 按子系统 `com.aholic.burette` 过滤）
- 内存环形缓冲（最近 800 条，设置页「运行日志」可实时查看、按级别筛选、导出）
- 沙盒 `Documents/Logs/burette.log`（超过 1 MB 轮转为 `burette.1.log`），可在「运行日志」里导出

`CrashReporter` 把 stderr 重定向到 `Documents/Logs/stderr.log`，并安装未捕获异常与致命信号处理；
下次启动时崩溃信息会并入主日志，并在「运行日志」里标注为「上一次会话的崩溃 / 错误输出」。

日志中不会写入 Token / API Key 等明文密钥。

### 3.7 Agent 对话

每个仓库可保存多条对话（Conversation），支持新建、切换、重命名、删除与中断：

- ChatView 顶栏左侧进入对话列表；AppEnvironment 维护 conversationsByRepository 与 selectedConversationIDs。
- 发送时先把仓库**文件树**作为初始上下文，然后进入 Codex 式**工具循环**：模型可反复调用 `list_files` / `read_file` / `grep` / `apply_patch`（`AgentTools` 定义，AIClient 以 OpenAI `tools` 格式随请求发送）。agentStatus / agentSteps / agentStream 实时暴露给界面，由 AgentRunView 以步骤卡片 + 流式预览呈现。
- 流式：AIClient 默认 `stream: true`，按 SSE（`data:` 行）解析文本增量与工具调用增量，onText 回调把累计文本节流地推给界面；服务端若忽略 stream、直接返回整体 JSON 也能兼容。
- apply_patch：模型用 `*** Begin Patch / *** Update File / *** Add File / *** Delete File` 提交改动（`ApplyPatchParser` 解析，hunk 不带行号），由 PatchApplier 的「内容搜索 + fuzz」定位落盘；一个补丁可同时改多个文件，落盘结果作为工具结果回给模型，失败时模型可重读后重试，重复提交会被拒绝。
- 兼容回退：接口返回「不支持 tools」时（HTTP 400 / 404 / 422 / 501 且信息含 tool / function / unsupported），自动回退到 `<<READ: 路径>> + unified diff` 文本协议，并记住该接口不再尝试工具调用；回退路径上限 10 轮、单文件 12 万字符、单轮累计 60 万字符。
- 跨轮记忆：read_file（或文本模式读取）过的文件内容按仓库缓存（最多 8 个 / 20 万字符），下一轮作为上下文带回；拉取或切换分支后清空，避免用到过期内容。
- send 为非阻塞：内部持有 sendTask，再次发送或点击停止键会调用 cancelSend() 取消在途请求，取消不写入错误提示。
- AI 应用改动后界面只展示说明文字与结果徽标（applied / partial / failed，只有真正写入工作区才显示「已应用」）；文本回退路径的气泡正文用 DiffExtractor.prose 去掉 diff 原文，并去掉 `<<READ: …>>` 标记。
- 工作区为空（未拉取 / 拉取失败）时，发送前会自动拉取一次；仍为空则直接提示用户去「仓库」页拉取，而不是把空文件树丢给模型让它要求用户粘贴代码。读取工作区时单个非 UTF-8 文件会按 lossy 解码跳过，不会让整份快照失败。
- 稳定性：请求期间用 BackgroundTask 申请后台执行时间，退到后台 / 锁屏时尽量跑完；历史只带最近 12 条；AIClient 最多重试 6 次并指数退避。AI 配置里的「模型强度」映射到接口的 reasoning_effort，默认 `high`，也可选「默认（不发送）」以兼容不支持的模型。
- 界面用 agentStartedAt 实时显示已用时长（统一中文单位，如「45秒」「1分23秒」），回复气泡展示最终用时。
- 取消类错误（URLError.cancelled / CancellationError）统一由 Support/Cancellation.swift 识别，只记调试日志，不弹错。
- 改动页用 LineDiff + DiffView 以 GitHub 风格展示：旧/新行号 + 增删颜色 + 统计条；PatchApplier 逐级放宽定位：精确行号 → 全文件内容搜索 → 忽略首尾空白 → fuzz（保留删除行、丢弃首尾上下文）→ 已是改动后状态则跳过 → 整文件重写；若声明的文件里定位不到，AppEnvironment.resolvedPatch 会在工作区中寻找唯一匹配的文件来纠正路径；仍无法应用的，performSend 会再请模型直接返回完整文件内容作为兜底。

### 3.8 GitHub Actions

进入仓库后的文件页顶栏可打开 Actions，查看该仓库的 workflow 运行记录：

- \`GitHubClient.workflowRuns / workflowRun / workflowJobs / rerunWorkflow / cancelWorkflow\` 封装 \`/repos/{owner}/{repo}/actions/*\`
- 列表默认展示**全部分支**（否则进行中的运行不在当前分支就会看不到），顶部显示仓库 / 分支与「进行中」指示
- 有排队 / 进行中的运行时每 10 秒自动刷新，详情页同样轮询 job / step 状态
- 详情页展示 job / step 状态，并支持重新运行与取消（需要 PAT 具备 Actions 读 / 写权限）

### 3.9 实时活动（灵动岛）

对话进行时通过 ActivityKit 把进度同步到灵动岛 / 锁屏：

- \`Shared/AgentActivityAttributes.swift\` 同时编译进 App 与 \`BuretteWidget\` 扩展（同名类型才能匹配）
- \`AppEnvironment\` 在 performSend 开始时 \`AgentLiveActivity.start\`，每次 \`setAgentStatus\` 更新状态，结束 / 取消时 \`end\`
- 展示当前步骤（如「正在请求 AI 模型…」）与已用时长；Widget 用 \`Text(date, style: .timer)\` 自动走秒
- CI 的无签名构建也会编译并嵌入该扩展

### 3.10 编辑器

编辑器是 UITextView（Support/CodeHighlighting.swift）而非 Runestone：

- 高亮：正则词法器 CodeHighlighter，覆盖注释 / 字符串 / 数字 / 关键字 / 类型 / 函数 / 装饰器，并对 Markdown / HTML / CSS / JSON / YAML 有专门规则；超过 20 万字符跳过，避免卡顿。
- 行号：LineNumberTextView 在 draw(_:) 里按 layoutManager 的片段绘制行号栏。
- 自动缩进：回车时沿用当前行缩进；上一行以 {( : [ 结尾时再加一级；光标在 () / {} / [] 之间时补出成对闭合行。缩进单位从文件已有缩进推断（Tab 或 N 空格）。
- 括号匹配：光标两侧的括号用 layoutManager 临时属性高亮，切换光标即更新，不改动文本。
- 查找 / 替换：EditorView 底部的查找栏通过 CodeEditorController 驱动同一个 UITextView，支持下一个 / 上一个 / 替换 / 全部替换。

### 3.11 提交历史

GitHubClient.commits（GET /repos/{owner}/{repo}/commits?sha={branch}）在仓库文件页顶栏的「提交历史」入口加载，展示提交标题 / 作者 / 时间 / 短 SHA。结果缓存在 AppEnvironment.commitsByRepository（不落盘）。

### 3.12 离线推送队列

Models/PendingPush.swift + AppEnvironment：

- 提交失败且错误可重试（URLError 网络类 / HTTP 5xx）时，改动快照与提交说明写入 pendingPushes 并持久化。
- flushPendingPushes() 在启动、应用回到前台、以及改动页手动点「立即重试」时执行；成功后从工作区与队列中移除对应改动。
- 改动页一级列表展示队列（可查看失败原因、左滑删除）。

## 4. 并发约定

- 所有 IO（网络、文件）使用 `async/await`，不阻塞主线程
- ViewModel 标注 `@MainActor`，模型与 Service 为 `Sendable` 值类型
- 大文件读写放在后台任务，界面只做轻量状态更新

## 5. 与需求的取舍

| 需求 | 当前实现 | 说明 |
|---|---|---|
| 推送确认 | 改动页顶部显示仓库 + 分支，推送前弹确认框；推送前先查远端，领先则提示先拉取（也可确认强制推送） | 避免推错库 / 覆盖别人的提交 |
| 本地存储 SQLite | SQLiteStore（键 → JSON blob）；首次启动自动迁移旧 JSON，打不开时回退 JSONStore | 通过 PersistenceStore 协议隔离，调用方无感 |
| 语法高亮(Runestone) | 内置正则高亮 + 行号栏（`Support/CodeHighlighting.swift`） | 覆盖注释/字符串/数字/关键字/类型/函数/装饰器等 token 及 Markdown、HTML、CSS、JSON、YAML 特例；另含自动缩进 / 括号匹配 / 查找替换。Runestone 见 project.yml，接入后替换 |
| Liquid Glass | 标准组件 + `Support/LiquidGlass.swift` 封装 | iOS 26 用 `glassEffect`；iOS 17–25 降级为 `ultraThinMaterial` |
| 大仓库性能 | 拉取 blob 有限并发（6 路）；递归树被截断时逐目录遍历补全 | 避免逐个 blob 串行拉取过慢 / 缺文件 |
| 离线推送 | 断网时提交入 pendingPushes，联网 / 回前台自动补推 | 见 3.12 |
