# 构建与发布

版本号只有一个来源：仓库根目录的 **VERSION** 文件（形如 `0.1.0`）。

## 触发规则

| 工作流 | 触发 | 行为 |
|---|---|---|
| `build-dev.yml`（Build (dev)） | push 到 `dev` | 编译 Debug 版无签名 IPA，上传为 Actions 工件，保留 14 天 |
| `build-dev.yml` | 手动 `workflow_dispatch` | 同上，用于验证流水线 |
| `release.yml`（Build & Release） | PR 到 `main` 被**合并**（`closed` + `merged`） | 编译 Release 版无签名 IPA，创建标签 `v<VERSION>` 与 Release |

两个工作流都会：

- 用 `maxim-lobanov/setup-xcode` 选 Xcode 26.6，runner 为 `macos-26`
- 用 XcodeGen 生成 `Burette.xcodeproj`（工程文件不提交）
- 校验根目录 `Info.plist`：`plutil -lint` 通过，且
  `UIFileSharingEnabled`、`LSSupportsOpeningDocumentsInPlace` 必须为 `<true/>`
- 读取 `VERSION` 并作为 `MARKETING_VERSION` 传入；构建号用 `CURRENT_PROJECT_VERSION = github.run_number`
- 以 `CODE_SIGNING_ALLOWED=NO` 编译，再把 `*.app` 打成 `Payload/` 结构的 IPA

差异：

- dev 工作流开了 `paths-ignore: [VERSION]`，只改版本号的推送不触发（省 runner 时间）；`concurrency` 会取消同分支上旧的进行中构建
- 发布工作流的 `VERSION` 必须是合法 semver，否则直接失败；标签 `v<VERSION>` 已存在时整个发布跳过

## 发布步骤

1. 修改 `VERSION`，例如从 `0.1.0` 改成 `0.2.0`
2. 提交并推送到 `dev`，确认 Build (dev) 通过
3. 从 `dev` 开 PR 到 `main`，写清楚这个版本改了什么（PR 描述会作为 Release 说明）
4. 合并 PR，Build & Release 自动构建并发布

版本号带连字符（如 `0.3.0-beta.1`）时，Release 会自动标记为 prerelease。

## 产物与安装

Release 附带的 `Burette-<VERSION>-unsigned.ipa` 与 `SHA256.txt` 都是**未签名**的。
未签名 IPA 不能直接安装，需要重签名：

- 桌面工具：Sideloadly、AltStore
- 或用自己的开发者证书重签名后再用 Xcode / `ios-deploy` 安装

如果以后要产出已签名 IPA，需要在工作流里加证书导入步骤，并把
`CODE_SIGNING_ALLOWED=NO` 改成使用对应的签名身份与 Profile
（Bundle ID 为 `com.aholic.burette`）。

## 注意事项

- **Info.plist 是硬性校验**：两个工作流都会检查
  `UIFileSharingEnabled` 与 `LSSupportsOpeningDocumentsInPlace`，
  它们是「文件」App 访问工作区的前提，删掉或改成 false 会让 CI 直接失败。
- **发布只认合并**：`release.yml` 有 `if: github.event.pull_request.merged == true`，
  仅关闭 PR 而不合并不会发布。
- **标签即版本**：同一个 `VERSION` 只会发布一次；要重新发一版必须先提升 `VERSION`。
- **Fork PR**：来自 fork 的 PR 合并后同样会触发发布；`GITHUB_TOKEN` 由
  `permissions: contents: write` 授权，无需额外配置 Secrets。
