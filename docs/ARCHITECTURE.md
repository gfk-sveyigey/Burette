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
| `Services/AI/` | OpenAI 兼容接口调用与提示词构造 |
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

`DiffParser` 把 AI 返回的文本解析为 `[FilePatch]`，逐文件包含若干 `DiffHunk`。
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

- OSLog（可在 Console.app 按子系统 `com.burette.app` 过滤）
- 内存环形缓冲（最近 800 条，设置页「运行日志」可实时查看、按级别筛选、导出）
- 沙盒 `Documents/Logs/burette.log`（超过 1 MB 轮转为 `burette.1.log`），可在「运行日志」里导出

`CrashReporter` 把 stderr 重定向到 `Documents/Logs/stderr.log`，并安装未捕获异常与致命信号处理；
下次启动时崩溃信息会并入主日志，并在「运行日志」里标注为「上一次会话的崩溃 / 错误输出」。

日志中不会写入 Token / API Key 等明文密钥。

### 3.7 Agent 对话

每个仓库可保存多条对话（Conversation），支持新建、切换、重命名、删除与中断：

- ChatView 顶栏左侧进入对话列表；AppEnvironment 维护 conversationsByRepository 与 selectedConversationIDs。
- 发送时把整个项目文件作为上下文（contextPaths 非空时只取指定文件），依次经过「整理上下文 → 请求模型 → 解析 diff」，agentStatus 实时暴露给界面，由 AgentRunView 以步骤卡片呈现，使过程更像一次 agent 任务执行。
- send 为非阻塞：内部持有 sendTask，再次发送或点击停止键会调用 cancelSend() 取消在途请求，取消不写入错误提示。
- AI 返回的 diff 会自动应用到工作区（agentStatus 走完后由 AppEnvironment.apply 写入），界面只展示说明文字与「已自动应用 N 个文件」提示；气泡正文用 DiffExtractor.prose 去掉 diff 原文。
- 稳定性：请求期间用 BackgroundTask 申请后台执行时间，退到后台 / 锁屏时尽量跑完；上下文按字符预算裁剪（PromptBuilder.contextFiles，超出时优先相关文件并截断），历史只带最近 12 条；AIClient 最多重试 4 次并指数退避。
- 界面用 agentStartedAt 实时显示已用时长，回复气泡展示最终用时。
- 改动页用 LineDiff + DiffView 以 GitHub 风格展示：旧/新行号 + 增删颜色 + 统计条；PatchApplier 在行号不准时按内容模糊定位，整文件重写则直接采用新内容。

## 4. 并发约定

- 所有 IO（网络、文件）使用 `async/await`，不阻塞主线程
- ViewModel 标注 `@MainActor`，模型与 Service 为 `Sendable` 值类型
- 大文件读写放在后台任务，界面只做轻量状态更新

## 5. 与需求的取舍

| 需求 | 当前实现 | 说明 |
|---|---|---|
| 本地存储 SQLite | 先用 JSON 文件 | 已通过协议隔离，替换成本低 |
| 语法高亮(Runestone) | 内置正则高亮 + 行号栏（`Support/CodeHighlighting.swift`） | 覆盖注释/字符串/数字/关键字/类型/函数/装饰器等 token 及 Markdown、HTML、CSS、JSON、YAML 特例；Runestone 见 project.yml，接入后替换 |
| Liquid Glass | 标准组件 + `Support/LiquidGlass.swift` 封装 | iOS 26 用 `glassEffect`；iOS 17–25 降级为 `ultraThinMaterial` |
