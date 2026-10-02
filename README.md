# Burette

Burette 是一个 Swift 原生 iOS 应用，把 Codex + GitHub Desktop 的工作流搬到手机上：

> PAT 登录 GitHub → 克隆 / 管理多仓库 → 与 AI 对话让它返回 unified diff → 预览并应用改动 → 用编辑器手动修改 → commit & push

第一版只做「对话改代码 + 手动编辑 + 提交推送」这条主线，不涉及 GitHub Actions、编译器与多人协作。

## 状态

早期开发中。已完成基础脚手架（M0），正在实现核心链路（M1–M3），详见 [docs/ROADMAP.md](docs/ROADMAP.md)。

## 目录结构

```
Burette/
├── project.yml            # XcodeGen 工程定义
├── Burette/               # 应用源码
│   ├── App/               # 入口与全局环境
│   ├── Models/            # 数据模型
│   ├── Services/          # 网络 / 存储 / diff / AI
│   └── Features/          # SwiftUI 界面，按功能分目录
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
