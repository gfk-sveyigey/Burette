# 路线图

按「先打通链路，再补体验」的顺序推进。

## M0 · 脚手架（已完成）

- [x] 工程结构、XcodeGen 定义与设计文档
- [x] 数据模型（仓库、AI 配置、消息、改动、diff）
- [x] unified diff 解析与回写 + 单元测试
- [x] Keychain 封装
- [x] GitHub REST 客户端与 Git Data API 提交流程
- [x] OpenAI 兼容 AI 客户端与提示词构造
- [x] SwiftUI 主界面骨架
- [x] GitHub Actions：dev 构建打包，PR 合并到 main 发布 Release（版本号取自 VERSION）

## M1 · GitHub 登录与仓库

- [ ] PAT 输入与有效性校验（GET /user）
- [ ] 拉取仓库列表、克隆到本地工作区
- [ ] 分支切换、拉取、查看提交历史
- [ ] 私有仓库支持

## M2 · AI 对话改代码

- [ ] 多套 API 配置的增删改查与切换
- [ ] 读取仓库文件作为上下文
- [ ] 解析模型返回的 unified diff
- [ ] 改动预览与「应用 / 丢弃」
- [ ] 多轮对话上下文维护

## M3 · 编辑器

- [ ] 引入 Runestone 与 Tree-sitter 语言包
- [ ] 行号、自动缩进、括号匹配、搜索替换
- [ ] 保存后进入待提交状态

## M4 · 提交与推送

- [ ] 改动文件列表与 diff 查看
- [ ] 选择性 stage、commit message
- [ ] 一键 commit + push
- [ ] push 前拉取远程，冲突提示

## M5 · 打磨

- [ ] 离线队列：联网后批量推送
- [ ] 大仓库性能优化
- [ ] Liquid Glass 外观回归（iOS 17–25 降级检查）
- [ ] SQLite 替换 JSON 存储
