# Burette

Burette 是一个 Swift 原生 iOS 应用，把 Codex + GitHub Desktop 的工作流搬到手机上：

> PAT 登录 GitHub → 克隆 / 管理多仓库 → 与 AI 对话让它直接改代码 → 自动应用到工作区 → 用编辑器手动修改 → commit & push

除了「对话改代码 + 手动编辑 + 提交推送」这条主线，还内置了 GitHub Actions 运行查看、提交历史、离线推送队列与灵动岛实时进度。

## 状态

核心功能已完成（M0–M5），详见 [docs/ROADMAP.md](docs/ROADMAP.md)。

## 主要功能

- **登录与多仓库**：PAT 登录、账户切换 / 信息修改、仓库增删、分支切换、拉取、提交历史、私有仓库。
- **AI 对话改代码**：多套 OpenAI 兼容配置、可选模型强度；对话式工具循环（列目录 / 读文件 / 搜索 / apply_patch），改动自动应用到工作区并通知。支持对话管理、中断、灵动岛 / 锁屏进度。
- **编辑器**：语法高亮、行号、自动缩进、括号匹配、查找替换；保存即进入待提交。
- **提交与推送**：改动列表 + GitHub 风格 diff、选择性 stage、commit message、一键 commit & push；推送前检查远端，远端领先时提示。
- **GitHub Actions**：查看 workflow 运行、job / step 详情与完整日志，支持重新运行与取消。
- **稳定性**：统一日志（内存环形缓冲 + 落盘 + 崩溃捕获）、离线推送队列、后台任务保活、大仓库并发拉取。

## 目录结构

```
Burette/
├── project.yml            # XcodeGen 工程定义
├── Burette/               # 应用源码
│   ├── App/               # 入口与全局环境
│   ├── Models/            # 数据模型
│   ├── Services/          # 网络 / 存储 / diff / AI
│   └── Features/          # SwiftUI 界面，按功能分目录
├── BuretteWidget/         # 灵动岛 / 锁屏实时活动扩展
├── Shared/                # App 与扩展共享的实时活动属性
├── BuretteTests/          # 单元测试
└── docs/                  # 设计文档
```

## 构建

需要 macOS + Xcode 26（iOS 26 SDK 以启用 Liquid Glass；iOS 17–25 设备自动降级外观）。

```sh
brew install xcodegen
xcodegen generate
open Burette.xcodeproj
```

## 构建与发布

CI 由 GitHub Actions 驱动（`macos-26` + Xcode 26.6 + XcodeGen），版本号来自仓库根目录的 `VERSION` 文件：

| 触发 | 行为 |
|---|---|
| 推送到 `dev` | 编译 Debug 版无签名 IPA，上传为 Actions 工件（保留 14 天），不发布 |
| PR 合并到 `main` | 编译 Release 版无签名 IPA 并发布 Release（标签 `v<VERSION>`），附带 IPA 与 SHA256 |
| 手动 `workflow_dispatch` | 同 dev，用于验证流水线 |

只改 `VERSION` 的 `dev` 推送不会触发构建；标签已存在时发布步骤自动跳过。

发布新版本：修改 `VERSION`（例如 `0.2.0`）→ 推到 `dev` → 开 PR 到 `main` 并合并。详见 [docs/RELEASING.md](docs/RELEASING.md)。

产物是**未签名** IPA，需要自行重签名（AltStore / Sideloadly / 企业证书）后才能装到设备。

## 文档

- [需求文档](REQUIREMENTS.md)
- [架构设计](docs/ARCHITECTURE.md)
- [路线图](docs/ROADMAP.md)
- [构建与发布](docs/RELEASING.md)
