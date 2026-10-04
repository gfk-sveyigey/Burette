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

## M1 · GitHub 登录与仓库（已完成）

- [x] PAT 输入与有效性校验（GET /user）
- [x] 拉取仓库列表、克隆到本地工作区
- [x] 分支切换、拉取、查看提交历史（仓库页 →「提交历史」）
- [x] 私有仓库支持

## M2 · AI 对话改代码（已完成）

- [x] 多套 API 配置的增删改查与切换（含模型强度 reasoning_effort）
- [x] 读取仓库文件作为上下文（工具循环 list_files / read_file / grep）
- [x] 解析模型返回的 unified diff 与 `apply_patch` 补丁
- [x] 改动预览与自动应用（应用失败时回退让模型重发完整文件）
- [x] 多轮对话上下文维护、对话管理（新建 / 切换 / 重命名 / 删除 / 中断）
- [x] 灵动岛 / 锁屏实时活动展示进度与时长

## M3 · 编辑器（功能已完成，未采用 Runestone）

- [x] 行号栏
- [x] 自动缩进（回车沿用当前缩进，大括号 / 括号换行补全）
- [x] 括号匹配高亮
- [x] 查找 / 替换（下一个、替换、全部替换）
- [x] 保存后进入待提交状态
- [~] 引入 Runestone 与 Tree-sitter：未接入。当前用内置正则词法器
      （`Support/CodeHighlighting.swift`）实现高亮，覆盖常用语言；
      `project.yml` 里保留了 Runestone 依赖的注释，可随时替换。

## M4 · 提交与推送（已完成）

- [x] 改动文件列表与 diff 查看（GitHub 风格行号 + 增删配色）
- [x] 选择性 stage、commit message
- [x] 一键 commit + push（Git Data API 六步）
- [x] push 前拉取远程检查，远端领先时提示先拉取 / 或确认强制推送

## M5 · 打磨（已完成）

- [x] 离线队列：断网时提交进入队列，联网 / 回到前台自动补推（改动页可查看 / 重试 / 删除）
- [x] 大仓库性能优化：拉取 blob 改为有限并发（6 路），递归树被截断时逐目录遍历补全
- [x] Liquid Glass 外观回归（iOS 26 `glassEffect`；iOS 17–25 降级为 `ultraThinMaterial`）
- [x] SQLite 替换 JSON 存储（`SQLiteStore`，首次启动自动迁移旧 JSON 数据，失败回退 JSONStore）

## 后续可选

- [ ] 接入 Runestone / Tree-sitter 做更精确的语法高亮
- [ ] 基于 `PersistenceStore` 做增量同步与更细的缓存失效
- [ ] PR 创建 / review（当前明确不做）
