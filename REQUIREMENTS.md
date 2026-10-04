# Burette · iOS AI 代码助手 App 需求文档

## 一、核心目标

Burette 是一个 Swift 原生 iOS App，复刻接近 Codex + GitHub Desktop 的工作流：

1. PAT 登录 GitHub
2. 连第三方 AI API，对话改代码
3. AI 返回 unified diff，App 解析、预览、应用
4. 手动编辑（内置高亮编辑器；Runestone 为可选增强）
5. commit + push
6. 支持多仓库

> 不涉及编译器 / 完整 IDE；已支持查看 GitHub Actions 运行记录。

## 二、功能需求

### 1. 登录与多仓库管理
- GitHub PAT 登录，token 存 Keychain
- clone / 添加多个仓库，列表可切换、删除、刷新
- 分支切换、拉取、查看提交历史
- 支持私有仓库

### 2. AI 对话改代码（核心）
- 自定义 API：Base URL + API Key + 模型名，OpenAI 兼容格式
- 可保存多套配置，随时切换（增删改查）
- AI 读取仓库内文件作为上下文
- AI 返回 unified diff（`---` / `+++` / `@@`）
- App 解析 diff → 展示预览 → 用户确认 → 写入本地文件
- 多轮对话，保留上下文
- 支持单文件修改和跨文件批量修改

### 3. 手动编辑（Runestone）
- 用 Runestone（纯 Swift 原生，基于 UITextView + Tree-sitter）
- 语法高亮：覆盖常用语言（Swift / JS / TS / Python / Go / HTML / CSS / JSON / Markdown 等）
- 行号
- 自动缩进
- 括号匹配
- 搜索替换
- 保存后进入待提交状态

### 4. Git 操作
- 用 GitHub REST API（Git Data API 走多文件提交）
- 查看所有改动文件的 diff
- 选择性 stage 单文件或全部
- 写 commit message
- commit + push 一键完成
- push 前拉取远程，冲突至少能提示

## 三、非功能需求

- 平台：iOS，Swift 原生，SwiftUI 优先
- 系统版本：最低 iOS 17
- 安全：PAT、API Key 存 Keychain，不明文落盘
- 离线：本地仓库可离线编辑，联网后再 push
- 性能：大仓库不卡死，文件读写异步
- 多 API 配置：可增删改查、快速切换
- 视觉效果：采用 Apple 官方 Liquid Glass 设计系统
  - 使用 Xcode 26+ / iOS 26 SDK 编译，标准组件（NavigationStack、TabView、Toolbar、Sheet 等）自动应用 Liquid Glass，无需额外代码
  - iOS 17～25 设备自动降级为旧版外观

## 四、技术选型

| 模块 | 方案 |
|---|---|
| UI | SwiftUI |
| 编辑器 | 内置 UITextView + 正则高亮（Support/CodeHighlighting.swift）；Runestone 为可选增强 |
| Git | GitHub REST API（Git Data API） |
| 本地存储 | 文件系统 + SQLite（对话/配置/元数据） |
| AI 调用 | URLSession，OpenAI 兼容接口 |
| Patch 格式 | unified diff |
| Patch 应用 | 自研 parser + apply，或引现成 diff 库 |
| Keychain | iOS Keychain Services |

## 五、明确不做

- 编译器 / 构建
- 完整 IDE
- 多人协作 / PR review
- OAuth（第一版只用 PAT）

## 六、MVP 链路

> PAT 登录 → clone 多仓库 → 对话让 AI 返回 unified diff → 预览并应用 → Runestone 手动编辑 → commit → push

## 七、多文件推送实现要点（GitHub REST API）

一次提交多个文件走 Git Data API，流程：

1. `GET /repos/{owner}/{repo}/git/ref/heads/{branch}` → 拿当前 commit SHA
2. `GET /repos/{owner}/{repo}/git/commits/{sha}` → 拿当前 tree SHA
3. 对每个改动文件：`POST /repos/{owner}/{repo}/git/blobs` → 拿 blob SHA
4. `POST /repos/{owner}/{repo}/git/trees` → 传 base_tree + 所有新 blob，生成新 tree SHA
5. `POST /repos/{owner}/{repo}/git/commits` → 用新 tree + parent commit 生成新 commit
6. `PATCH /repos/{owner}/{repo}/git/refs/heads/{branch}` → 把分支指向新 commit

一次推送 N 个文件 = N 次 blob + 1 次 tree + 1 次 commit + 1 次 ref 更新。

### REST API 已知局限

| 问题 | 影响 |
|---|---|
| 必须联网 | 离线改完没法 commit，只能等联网 |
| 没有本地 Git 历史 | 看不了本地 log、没法本地 diff、没法切分支 |
| 冲突处理弱 | 远程被推过需先拉再重试 |
| 频繁调用限流 | PAT 认证 5000 次/时 |
| 大仓库 clone 慢 | 逐个文件拉，不如 git clone 快 |

### 应对策略

- 本地只存「工作区文件 + 元数据（当前分支、base commit SHA）」
- 离线改动先攒着，联网后一次性走上面 6 步推送
- 冲突时提示用户「远程有新提交，请先拉取」，App 重新拉取覆盖本地工作区

## 八、已实现的能力（超出 MVP 的部分）

- **编辑器**：语法高亮、行号、自动缩进、括号匹配、查找 / 替换；保存进入待提交。
- **提交历史**：仓库页可查看当前分支最近提交（提交标题、作者、时间、SHA）。
- **GitHub Actions**：查看 workflow 运行、job / step 详情与完整日志，支持重新运行 / 取消。
- **AI Agent 过程可见**：对话时实时展示当前状态、已完成步骤与流式输出；支持中断。
- **灵动岛 / 锁屏实时活动**：对话进行时展示进度与已用时长（带 App 图标）。
- **离线推送队列**：断网时提交先入队，联网或回到前台自动补推；改动页可查看 / 重试 / 删除。
- **稳定性**：统一日志中心（内存 + 落盘 + 崩溃捕获）、后台任务保活、网络中断自动重试、大仓库并发拉取。
- **存储**：SQLite（首次启动自动迁移旧 JSON 数据，打不开时回退 JSON）。

