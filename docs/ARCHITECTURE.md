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

## 4. 并发约定

- 所有 IO（网络、文件）使用 `async/await`，不阻塞主线程
- ViewModel 标注 `@MainActor`，模型与 Service 为 `Sendable` 值类型
- 大文件读写放在后台任务，界面只做轻量状态更新

## 5. 与需求的取舍

| 需求 | 当前实现 | 说明 |
|---|---|---|
| 本地存储 SQLite | 先用 JSON 文件 | 已通过协议隔离，替换成本低 |
| 语法高亮(Runestone) | 由 SPM 引入 | 见 project.yml |
| Liquid Glass | 使用标准组件 | Xcode 26 编译自动生效 |
