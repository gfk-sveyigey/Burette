import Foundation
import SwiftUI

/// 全局依赖装配与状态中心。
///
/// 持有各 Service，并把持久化状态暴露给 SwiftUI。所有界面通过
/// @EnvironmentObject 访问它。
@MainActor
final class AppEnvironment: ObservableObject {

    // MARK: - 持久化状态

    @Published var repositories: [Repository] = []
    @Published var aiConfigs: [AIProviderConfig] = []
    @Published var selectedRepositoryID: UUID?
    @Published var selectedAIConfigID: UUID?
    @Published var conversationsByRepository: [UUID: [Conversation]] = [:]
    @Published var selectedConversationIDs: [UUID: UUID] = [:]
    @Published var changesByRepository: [UUID: [FileChange]] = [:]
    @Published var branchesByRepository: [UUID: [String]] = [:]
    @Published var remoteUpdates: [UUID: Bool] = [:]
    @Published var appliedMessageIDs: Set<UUID> = []
    @Published var tokenScopes: [String] = []
    /// 提交历史缓存（按仓库，不落盘）。
    @Published var commitsByRepository: [UUID: [GitHubCommitSummary]] = [:]
    /// 离线推送队列：网络恢复后自动补推。
    @Published var pendingPushes: [PendingPush] = []

    @Published var currentUser: GitHubUser?
    @Published var isAuthenticated = false
    @Published var isSending = false
    /// 正在进行中的 agent 步骤描述（对话页实时展示）。
    @Published var agentStatus: String?
    /// 本次请求的开始时间，用于界面显示已用时长。
    @Published var agentStartedAt: Date?
    /// 本次请求的 Codex 式执行记录（读取了哪些文件、第几轮请求模型等）。
    @Published var agentSteps: [String] = []
    /// 模型当前的流式输出（截取尾部），用于对话页实时预览。
    @Published var agentStream: String = ""
    /// 最近一次自动应用改动的提示，界面读取后置空。
    @Published var applyNotice: String?
    @Published var busyMessage: String?
    @Published var lastError: String?

    // MARK: - Service

    let keychain: KeychainStore
    let workspace: WorkspaceManager
    let github: GitHubClient
    let aiClient: AIClient
    let syncService: RepositorySyncService
    let gitData: GitDataService

    private let store: PersistenceStore
    private var sendTask: Task<Void, Never>?
    /// 因网络中断 / 锁屏被系统打断的请求：回到前台或稍后自动重试，用户不必重新发一遍。
    private var pendingResend: (text: String, repositoryID: UUID)?
    /// 本次请求是否由用户主动中断（用于区分系统级中断）。
    private var cancelledByUser = false
    /// 当前实时活动对应的仓库名（用于灵动岛展示）。
    private var liveActivityRepository: String?
    /// 接口是否已被判定为不支持工具调用（一旦判定就回退到文本协议）。
    private var toolsUnsupported = false
    /// 每个仓库最近读过的文件内容，供后续轮次复用。
    private var agentFileMemory: [UUID: [(path: String, content: String)]] = [:]
    /// 流式输出节流用的时间戳。
    private var lastStreamUpdate = Date.distantPast
    /// 已完成轮次累积的流式文本；新一轮在它后面继续追加，避免把 AI 之前说的话删掉。
    private var streamBase = ""
    /// 离线队列是否正在重试，避免并发重入。
    private var isFlushingPushes = false

    // MARK: - Init

    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Burette", isDirectory: true)
    }

    init(store: PersistenceStore? = nil) {
        let resolvedStore = store ?? AppEnvironment.makeDefaultStore(directory: AppEnvironment.supportDirectory)
        let workspaceRoot = AppEnvironment.supportDirectory
            .appendingPathComponent("Workspaces", isDirectory: true)
        let workspace = WorkspaceManager(root: workspaceRoot)
        let client = GitHubClient()

        self.store = resolvedStore
        self.workspace = workspace
        self.keychain = KeychainStore()
        self.github = client
        self.aiClient = AIClient()
        self.syncService = RepositorySyncService(client: client, workspace: workspace)
        self.gitData = GitDataService(client: client)
    }

    /// 默认存储：优先 SQLite；打不开时回退 JSON。首次启用 SQLite 会把既有 JSON 数据迁移过来。
    private static func makeDefaultStore(directory: URL) -> PersistenceStore {
        let json = JSONStore(directory: directory)
        guard let sqlite = SQLiteStore(directory: directory) else {
            Log.warning("SQLite 打开失败，回退到 JSON 存储", .persistence)
            return json
        }
        migrateLegacyJSON(from: json, to: sqlite)
        return sqlite
    }

    /// 迁移用键：与 persistAll / loadFromDisk 保持一致。
    private static let persistedNames = [
        "repositories", "ai-configs", "conversations", "selected-conversations",
        "changes", "applied-messages", "messages", "pending-pushes"
    ]

    private static func migrateLegacyJSON(from json: JSONStore, to sqlite: SQLiteStore) {
        var migrated = 0
        for name in persistedNames {
            guard !sqlite.contains(name) else { continue }
            let url = json.url(for: name)
            guard FileManager.default.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url)
            else { continue }
            do {
                try sqlite.saveRaw(data, name: name)
                migrated += 1
            } catch {
                Log.warning("迁移 \(name) 到 SQLite 失败：\(error.localizedDescription)", .persistence)
            }
        }
        if migrated > 0 {
            Log.info("已把 \(migrated) 项 JSON 数据迁移到 SQLite", .persistence)
        }
    }

    // MARK: - 派生状态

    var selectedRepository: Repository? {
        repositories.first { $0.id == selectedRepositoryID }
    }

    var activeAIConfig: AIProviderConfig? {
        if let id = selectedAIConfigID, let config = aiConfigs.first(where: { $0.id == id }) {
            return config
        }
        return aiConfigs.first
    }

    func pendingChanges(for repository: Repository) -> [FileChange] {
        changesByRepository[repository.id] ?? []
    }

    // MARK: - 对话管理

    /// 该仓库的全部对话，按最近更新排序。
    func conversations(for repository: Repository) -> [Conversation] {
        (conversationsByRepository[repository.id] ?? [])
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// 当前选中的对话；没有选中时回退到最近更新的一条。
    func currentConversation(for repository: Repository) -> Conversation? {
        let list = conversationsByRepository[repository.id] ?? []
        if let id = selectedConversationIDs[repository.id],
           let match = list.first(where: { $0.id == id }) {
            return match
        }
        return list.max { $0.updatedAt < $1.updatedAt }
    }

    func messages(for repository: Repository) -> [ChatMessage] {
        currentConversation(for: repository)?.messages ?? []
    }

    /// 保证仓库至少有一条对话，并返回当前对话。
    @discardableResult
    func ensureConversation(for repository: Repository) -> Conversation {
        if let existing = currentConversation(for: repository) {
            selectedConversationIDs[repository.id] = existing.id
            return existing
        }
        return createConversation(in: repository)
    }

    func newConversation(in repository: Repository) {
        _ = createConversation(in: repository)
        Log.info("新建对话：\(repository.fullName)", .app)
    }

    @discardableResult
    private func createConversation(in repository: Repository) -> Conversation {
        let conversation = Conversation()
        var list = conversationsByRepository[repository.id] ?? []
        list.append(conversation)
        conversationsByRepository[repository.id] = list
        selectedConversationIDs[repository.id] = conversation.id
        persistAll()
        return conversation
    }

    func selectConversation(_ conversation: Conversation, in repository: Repository) {
        selectedConversationIDs[repository.id] = conversation.id
        persistAll()
    }

    func renameConversation(_ conversation: Conversation, in repository: Repository, title: String) {
        guard var list = conversationsByRepository[repository.id],
              let index = list.firstIndex(where: { $0.id == conversation.id }) else { return }
        list[index].title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        list[index].updatedAt = Date()
        conversationsByRepository[repository.id] = list
        persistAll()
        Log.info("重命名对话：\(list[index].displayTitle)", .app)
    }

    func deleteConversation(_ conversation: Conversation, in repository: Repository) {
        guard var list = conversationsByRepository[repository.id] else { return }
        list.removeAll { $0.id == conversation.id }
        conversationsByRepository[repository.id] = list
        if selectedConversationIDs[repository.id] == conversation.id {
            selectedConversationIDs[repository.id] = list.max { $0.updatedAt < $1.updatedAt }?.id
        }
        persistAll()
        Log.info("删除对话：\(conversation.displayTitle)", .app)
        if list.isEmpty {
            _ = createConversation(in: repository)
        }
    }

    private func appendMessage(_ message: ChatMessage, to conversationID: UUID, in repository: Repository) {
        guard var list = conversationsByRepository[repository.id],
              let index = list.firstIndex(where: { $0.id == conversationID }) else { return }
        list[index].messages.append(message)
        list[index].updatedAt = Date()
        if list[index].title == "新对话", message.role == .user {
            list[index].title = Conversation.defaultTitle(from: message.content)
        }
        conversationsByRepository[repository.id] = list
    }

    // MARK: - 生命周期

    func bootstrap() async {
        loadFromDisk()
        do {
            if let token = try keychain.get(KeychainStore.gitHubTokenKey), !token.isEmpty {
                await github.updateToken(token)
                isAuthenticated = true
                currentUser = try? await github.currentUser()
                tokenScopes = await github.currentScopes()
                Log.info("已恢复登录：\(currentUser?.login ?? "未知账户")，令牌权限：\(tokenScopes.isEmpty ? "未知" : tokenScopes.joined(separator: ", "))", .app)
            } else {
                Log.info("未找到已保存的登录凭据", .app)
            }
        } catch {
            lastError = error.localizedDescription
        }
        // 上次断网时攒下的提交，网络恢复后自动补推。
        await flushPendingPushes()
    }

    private func loadFromDisk() {
        do {
            repositories = try store.load([Repository].self, from: "repositories") ?? []
            aiConfigs = try store.load([AIProviderConfig].self, from: "ai-configs") ?? []
            conversationsByRepository = try store.load([UUID: [Conversation]].self, from: "conversations") ?? [:]
            selectedConversationIDs = try store.load([UUID: UUID].self, from: "selected-conversations") ?? [:]
            migrateLegacyMessagesIfNeeded()
            changesByRepository = try store.load([UUID: [FileChange]].self, from: "changes") ?? [:]
            appliedMessageIDs = Set(try store.load([UUID].self, from: "applied-messages") ?? [])
            pendingPushes = try store.load([PendingPush].self, from: "pending-pushes") ?? []
            selectedRepositoryID = repositories.first?.id
            selectedAIConfigID = aiConfigs.first?.id
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// 把旧版本「每个仓库一条消息列表」迁移成对话。
    private func migrateLegacyMessagesIfNeeded() {
        guard conversationsByRepository.isEmpty else { return }
        guard let legacy = try? store.load([UUID: [ChatMessage]].self, from: "messages"),
              !legacy.isEmpty else { return }
        var converted: [UUID: [Conversation]] = [:]
        for (repositoryID, messages) in legacy where !messages.isEmpty {
            converted[repositoryID] = [Conversation(title: "历史对话", messages: messages)]
        }
        conversationsByRepository = converted
        Log.info("已迁移 \(converted.count) 个仓库的历史消息为对话", .app)
    }

    private func persistAll() {
        do {
            try store.save(repositories, to: "repositories")
            try store.save(aiConfigs, to: "ai-configs")
            try store.save(conversationsByRepository, to: "conversations")
            try store.save(selectedConversationIDs, to: "selected-conversations")
            try store.save(changesByRepository, to: "changes")
            try store.save(Array(appliedMessageIDs), to: "applied-messages")
            try store.save(pendingPushes, to: "pending-pushes")
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - 登录

    func signIn(token: String) async {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await github.updateToken(trimmed)
        do {
            currentUser = try await github.currentUser()
            tokenScopes = await github.currentScopes()
            try keychain.set(trimmed, for: KeychainStore.gitHubTokenKey)
            isAuthenticated = true
            lastError = nil
            Log.info("登录成功：\(currentUser?.login ?? "未知账户")，令牌权限：\(tokenScopes.isEmpty ? "未知" : tokenScopes.joined(separator: ", "))", .app)
        } catch {
            await github.updateToken(nil)
            report(error, .app)
        }
    }

    func signOut() {
        try? keychain.delete(KeychainStore.gitHubTokenKey)
        Task { await github.updateToken(nil) }
        isAuthenticated = false
        currentUser = nil
        tokenScopes = []
        repositories = []
        selectedRepositoryID = nil
        appliedMessageIDs = []
        persistAll()
        Log.info("已退出登录", .app)
    }

    /// 切换到另一个 GitHub 账户：允许 login 变化，切换成功后清空仓库列表。
    @discardableResult
    func switchAccount(token: String) async -> Bool {
        await applyAccount(token: token, allowSwitch: true)
    }

    /// 修改当前账户的登录凭据：要求新 token 仍属于当前账户。
    @discardableResult
    func updateAccountToken(token: String) async -> Bool {
        await applyAccount(token: token, allowSwitch: false)
    }

    private func applyAccount(token: String, allowSwitch: Bool) async -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let previousLogin = currentUser?.login
        do {
            await github.updateToken(trimmed)
            let user = try await github.currentUser()

            if !allowSwitch, let previousLogin, previousLogin != user.login {
                await restoreToken()
                lastError = "这是另一个账号（\(user.login)），请使用「切换账户」。"
                Log.warning("凭据属于其他账号：\(user.login)", .app)
                return false
            }

            try keychain.set(trimmed, for: KeychainStore.gitHubTokenKey)
            currentUser = user
            tokenScopes = await github.currentScopes()
            isAuthenticated = true
            lastError = nil
            Log.info("账户凭据已更新：\(user.login)，令牌权限：\(tokenScopes.isEmpty ? "未知" : tokenScopes.joined(separator: ", "))", .app)

            if allowSwitch, let previousLogin, previousLogin != user.login {
                repositories = []
                selectedRepositoryID = nil
                persistAll()
                Log.info("已切换账户：\(previousLogin) → \(user.login)", .app)
            }
            return true
        } catch {
            await restoreToken()
            lastError = error.localizedDescription
            Log.error(error, .app)
            return false
        }
    }

    private func restoreToken() async {
        if let old = try? keychain.get(KeychainStore.gitHubTokenKey), !old.isEmpty {
            await github.updateToken(old)
        } else {
            await github.updateToken(nil)
        }
    }

    // MARK: - 仓库

    func addRepositories(from remote: [GitHubRepository]) {
        for repo in remote {
            let exists = repositories.contains { $0.owner == repo.owner.login && $0.name == repo.name }
            guard !exists else { continue }
            repositories.append(
                Repository(
                    owner: repo.owner.login,
                    name: repo.name,
                    defaultBranch: repo.defaultBranch,
                    isPrivate: repo.isPrivate
                )
            )
        }
        if selectedRepositoryID == nil { selectedRepositoryID = repositories.first?.id }
        persistAll()
        Log.info("添加了 \(remote.count) 个仓库，当前共 \(repositories.count) 个", .app)
    }

    func removeRepository(_ repository: Repository) {
        repositories.removeAll { $0.id == repository.id }
        changesByRepository[repository.id] = nil
        conversationsByRepository[repository.id] = nil
        selectedConversationIDs[repository.id] = nil
        branchesByRepository[repository.id] = nil
        remoteUpdates[repository.id] = nil
        if selectedRepositoryID == repository.id { selectedRepositoryID = repositories.first?.id }
        let folder = workspace.folder(for: repository)
        try? FileManager.default.removeItem(at: folder)
        persistAll()
        Log.info("删除仓库：\(repository.fullName)", .app)
    }

    func clone(_ repository: Repository) async {
        busyMessage = "正在拉取 \(repository.fullName)…"
        defer { busyMessage = nil }
        Log.info("开始拉取 \(repository.fullName)＠\(repository.currentBranch)", .workspace)
        do {
            let result = try await syncService.pull(repository: repository)
            if let index = repositories.firstIndex(where: { $0.id == repository.id }) {
                repositories[index].baseCommitSHA = result.sha
                repositories[index].lastSyncedAt = Date()
            }
            remoteUpdates[repository.id] = false
            // 工作区内容整体更新，之前缓存的文件内容可能已过期，清掉。
            agentFileMemory[repository.id] = nil
            persistAll()
            Log.info("拉取完成：\(repository.fullName)，\(result.fileCount) 个文件，base \(result.sha.prefix(7))", .workspace)
        } catch {
            report(error, .workspace)
        }
    }

    // MARK: - AI 配置

    func upsert(_ config: AIProviderConfig, apiKey: String?) {
        if let apiKey, !apiKey.isEmpty {
            try? keychain.set(apiKey, for: config.apiKeyID)
        }
        if let index = aiConfigs.firstIndex(where: { $0.id == config.id }) {
            aiConfigs[index] = config
        } else {
            aiConfigs.append(config)
        }
        if selectedAIConfigID == nil { selectedAIConfigID = config.id }
        persistAll()
    }

    func removeConfig(_ config: AIProviderConfig) {
        aiConfigs.removeAll { $0.id == config.id }
        try? keychain.delete(config.apiKeyID)
        if selectedAIConfigID == config.id { selectedAIConfigID = aiConfigs.first?.id }
        persistAll()
    }

    func apiKey(for config: AIProviderConfig) -> String {
        (try? keychain.get(config.apiKeyID)) ?? ""
    }

    /// 用一条极小的请求检测配置是否可用。
    func checkAI(_ config: AIProviderConfig) async -> Result<String, Error> {
        let apiKey = apiKey(for: config)
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(AIError.missingAPIKey)
        }
        let messages = [
            AIChatMessage(role: "system", content: "你是一个连通性检测服务，请只回复 OK。"),
            AIChatMessage(role: "user", content: "ping")
        ]
        do {
            let reply = try await aiClient.complete(config: config, apiKey: apiKey, messages: messages)
            return .success(reply)
        } catch {
            return .failure(error)
        }
    }

    /// 刷新当前登录的 GitHub 账户信息与令牌权限。
    func refreshCurrentUser() async {
        currentUser = try? await github.currentUser()
        tokenScopes = await github.currentScopes()
    }

    // MARK: - 对话

    /// contextPaths 非空时只把这些文件作为上下文；否则按关键词自动挑选。
    /// 启动一次对话（非阻塞）。再次调用会先取消上一次请求。
    func send(_ text: String, in repository: Repository, contextPaths: [String] = []) {
        sendTask?.cancel()
        cancelledByUser = false
        pendingResend = nil
        sendTask = Task { [weak self] in
            await self?.performSend(text, in: repository, contextPaths: contextPaths)
        }
    }

    /// 更新 agent 步骤，并把最新状态同步到灵动岛实时活动。
    private func setAgentStatus(_ value: String) {
        // 状态是「当前正在做的事」，单独展示；不写进历史步骤，避免刷屏。
        agentStatus = value
        AgentLiveActivity.shared.update(
            repository: liveActivityRepository ?? "",
            status: value,
            startedAt: agentStartedAt ?? Date()
        )
    }

    /// 追加一条具体的执行记录（Codex 式过程日志），最多保留 80 条。
    private func appendAgentStep(_ value: String) {
        let line = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, line != agentSteps.last else { return }
        agentSteps.append(line)
        if agentSteps.count > 80 {
            agentSteps.removeFirst(agentSteps.count - 80)
        }
    }

    /// 中断正在进行的对话请求（保留已经发出的用户消息）。
    func cancelSend() {
        guard sendTask != nil || isSending else { return }
        cancelledByUser = true
        pendingResend = nil
        sendTask?.cancel()
        sendTask = nil
        isSending = false
        agentStatus = nil
        agentStartedAt = nil
        agentSteps = []
        agentStream = ""
        streamBase = ""
        lastStreamUpdate = .distantPast
        AgentLiveActivity.shared.end()
        liveActivityRepository = nil
        Log.info("已中断对话请求", .ai)
    }

    private func performSend(_ text: String, in repository: Repository, contextPaths: [String], appendUserMessage: Bool = true) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        guard let config = activeAIConfig else {
            lastError = "请先在「设置」里添加一套 AI 配置。"
            return
        }
        let apiKey = apiKey(for: config)
        guard !apiKey.isEmpty else {
            lastError = "当前 AI 配置缺少 API Key。"
            return
        }

        isSending = true
        let startedAt = Date()
        agentStartedAt = startedAt
        agentSteps = []
        agentStream = ""
        streamBase = ""
        lastStreamUpdate = .distantPast
        liveActivityRepository = repository.fullName
        // 对话进行时把进度同步到灵动岛 / 锁屏。
        AgentLiveActivity.shared.start(
            repository: repository.fullName,
            status: "正在读取工作区…",
            startedAt: startedAt
        )
        defer {
            isSending = false
            agentStatus = nil
            agentStartedAt = nil
            agentSteps = []
            agentStream = ""
            AgentLiveActivity.shared.end()
            liveActivityRepository = nil
        }
        Log.info("发送对话请求：\(repository.fullName)，\(trimmed.count) 字", .ai)

        let conversation = ensureConversation(for: repository)
        if appendUserMessage {
            appendMessage(ChatMessage(role: .user, content: trimmed), to: conversation.id, in: repository)
            persistAll()
        }

        let history = messages(for: repository)

        // 读取工作区放到后台线程：仓库大时这里是主要耗时点，放主线程会卡住界面与状态更新。
        let workspace = self.workspace
        setAgentStatus("正在读取工作区文件…")
        var snapshot = await Task.detached(priority: .userInitiated) {
            (try? workspace.snapshot(repository: repository)) ?? [:]
        }.value
        // 工作区为空（还没拉取过 / 上次拉取失败）时先自动拉一次，
        // 否则模型只能看到空文件树，就会反过来要求用户粘贴文件内容。
        if snapshot.isEmpty {
            Log.warning("工作区为空，发送前自动拉取：\(repository.fullName)", .workspace)
            setAgentStatus("工作区为空，正在拉取 \(repository.fullName)…")
            await clone(repository)
            snapshot = await Task.detached(priority: .userInitiated) {
                (try? workspace.snapshot(repository: repository)) ?? [:]
            }.value
            guard !snapshot.isEmpty else {
                agentStatus = nil
                lastError = "工作区里没有可用文件，AI 无法读取项目。请先在「仓库」页对 \(repository.fullName) 执行一次拉取，并确认仓库不是空的。"
                Log.error("工作区仍为空，已中止本次对话：\(repository.fullName)", .workspace)
                return
            }
        }
        setAgentStatus("已载入 \(snapshot.count) 个文件，正在整理文件树…")
        let tree = await Task.detached(priority: .userInitiated) {
            (try? workspace.listFiles(repository: repository)) ?? []
        }.value
        appendAgentStep("已整理文件树：\(tree.count) 项")

        var bodyMessages: [AIChatMessage] = [PromptBuilder.treeMessage(fileTree: tree)]
        // 带回之前几轮读过的文件内容，减少重复读取、保持跨轮一致。
        if let memory = PromptBuilder.memoryMessage(files: agentFileMemory[repository.id] ?? []) {
            bodyMessages.append(memory)
        }
        // 兼容旧的显式参考文件：有的话先直接附带，省一次往返。
        if !contextPaths.isEmpty {
            let initial = contextPaths.compactMap { path -> FileContext? in
                guard let content = snapshot[path] else { return nil }
                return FileContext(path: path, content: content)
            }
            let missing = contextPaths.filter { snapshot[$0] == nil }
            bodyMessages.append(PromptBuilder.readResultMessage(requested: contextPaths, files: initial, missing: missing))
        }
        for message in history.suffix(12) where message.role != .system {
            bodyMessages.append(message.apiMessage)
        }
        Log.debug("上下文：文件树 \(tree.count) 项，历史 \(history.suffix(12).count) 条", .ai)

        // 退到后台 / 锁屏时申请额外执行时间，尽量让请求跑完。
        let backgroundTask = BackgroundTask()
        backgroundTask.begin("AIRequest")
        defer { backgroundTask.end() }

        do {
            let turn = try await runAgentLoop(
                repository: repository,
                config: config,
                apiKey: apiKey,
                body: bodyMessages,
                fileTree: tree,
                snapshot: snapshot
            )
            try Task.checkCancellation()

            let messageID = UUID()
            let patches = turn.patches
            var applied = turn.applied
            var failedCount = turn.failed
            var failureSummary = turn.failureSummary

            // 文本回退模式：补丁在这里统一应用（工具模式已在 apply_patch 里落盘）。
            if !turn.appliedInsideLoop, !patches.isEmpty {
                setAgentStatus("正在解析改动…")
                var outcome = apply(patches: patches, in: repository, messageID: messageID)
                if !outcome.isComplete, !outcome.failedPaths.isEmpty {
                    setAgentStatus("正在修复无法应用的改动…")
                    let repaired = await repairFiles(
                        outcome.failedPaths,
                        instruction: trimmed,
                        in: repository
                    )
                    if repaired > 0 {
                        let stillFailed = max(0, outcome.failed - repaired)
                        outcome = ApplyOutcome(
                            applied: outcome.applied + repaired,
                            failed: stillFailed,
                            failureSummary: stillFailed == 0 ? nil : outcome.failureSummary,
                            failedPaths: []
                        )
                    }
                }
                applied = outcome.applied
                failedCount = outcome.failed
                failureSummary = outcome.failureSummary
            }

            let elapsed = Date().timeIntervalSince(startedAt)
            var applyState: ChatMessage.ApplyState?
            if !patches.isEmpty {
                if failedCount == 0 {
                    applyState = .applied
                    appliedMessageIDs.insert(messageID)
                    appendAgentStep("已应用 \(patches.count) 个文件的改动")
                    applyNotice = "已自动应用 \(patches.count) 个文件的改动"
                    Log.info("自动应用完成：\(patches.count) 个文件，用时 \(DurationFormat.short(elapsed))", .ai)
                } else {
                    applyState = applied > 0 ? .partial : .failed
                    let reason = failureSummary ?? "未知错误"
                    appendAgentStep("改动应用失败：\(failedCount)/\(patches.count) 个文件")
                    applyNotice = reason.count > 160 ? String(reason.prefix(160)) + "…" : reason
                    Log.warning("自动应用改动失败 \(failedCount)/\(patches.count)：\(reason)", .diff)
                }
                lastError = nil
            } else {
                Log.info("收到 AI 回复：\(turn.reply.count) 字，没有可应用的改动", .ai)
            }

            let content: String
            if turn.appliedInsideLoop {
                content = turn.reply.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                content = PromptBuilder.strippingReadMarkers(DiffExtractor.prose(from: turn.reply))
            }
            let message = ChatMessage(
                id: messageID,
                role: .assistant,
                content: content.isEmpty ? "已根据你的要求更新项目。" : content,
                patches: patches.isEmpty ? nil : patches,
                duration: elapsed,
                applyState: applyState
            )
            appendMessage(message, to: conversation.id, in: repository)
            persistAll()
            pendingResend = nil
        } catch {
            if Cancellation.isCancellation(error) {
                if cancelledByUser {
                    cancelledByUser = false
                    Log.info("对话请求已被用户中断", .ai)
                } else {
                    // 锁屏 / 切后台等系统级中断：保留请求，回到前台自动重试。
                    pendingResend = (trimmed, repository.id)
                    lastError = "网络中断，已保留你的请求，回到前台会自动重试。"
                    Log.warning("对话请求被系统中断，已保留待重试：\(repository.fullName)", .ai)
                    schedulePendingResend()
                }
            } else if AIClient.isRetryable(error) {
                // 切网 / 信号抖动：保留请求，稍后自动重试，不必重新发一遍。
                pendingResend = (trimmed, repository.id)
                lastError = "网络不稳定，已保留你的请求，稍后自动重试。"
                Log.warning("网络错误，已保留待重试：\(error.localizedDescription)", .ai)
                schedulePendingResend()
            } else {
                lastError = error.localizedDescription
                Log.error(error, .ai)
            }
        }
    }

    // MARK: - Agent 循环

    /// 一次对话回合的结果。
    private struct AgentTurn {
        var reply: String = ""
        var patches: [FilePatch] = []
        var applied: Int = 0
        var failed: Int = 0
        var failureSummary: String?
        /// 补丁是否已经在工具循环里落盘（apply_patch 工具）。
        var appliedInsideLoop = false
    }

    /// 优先走工具调用；接口不支持工具调用时回退到文本协议。
    private func runAgentLoop(
        repository: Repository,
        config: AIProviderConfig,
        apiKey: String,
        body: [AIChatMessage],
        fileTree: [String],
        snapshot: [String: String]
    ) async throws -> AgentTurn {
        if toolsUnsupported {
            return try await runTextLoop(
                repository: repository,
                config: config,
                apiKey: apiKey,
                body: body,
                fileTree: fileTree,
                snapshot: snapshot
            )
        }
        do {
            return try await runToolLoop(
                repository: repository,
                config: config,
                apiKey: apiKey,
                body: body,
                fileTree: fileTree,
                snapshot: snapshot
            )
        } catch {
            if AIClient.isToolUnsupported(error) {
                toolsUnsupported = true
                appendAgentStep("接口不支持工具调用，改用文本模式")
                Log.warning("接口不支持工具调用，回退到文本协议：\(error.localizedDescription)", .ai)
                return try await runTextLoop(
                    repository: repository,
                    config: config,
                    apiKey: apiKey,
                    body: body,
                    fileTree: fileTree,
                    snapshot: snapshot
                )
            }
            throw error
        }
    }

    /// Codex 式工具循环：模型可反复调用 list_files / read_file / grep / apply_patch。
    private func runToolLoop(
        repository: Repository,
        config: AIProviderConfig,
        apiKey: String,
        body: [AIChatMessage],
        fileTree: [String],
        snapshot: [String: String]
    ) async throws -> AgentTurn {
        var turn = AgentTurn()
        turn.appliedInsideLoop = true
        var messages: [AIChatMessage] = [PromptBuilder.systemMessage(config: config)]
        messages.append(contentsOf: body)
        var executedPatches = Set<String>()
        let maxRounds = 24

        for round in 1...maxRounds {
            try Task.checkCancellation()
            setAgentStatus("正在请求模型…（第 \(round) 轮）")
            streamBase = agentStream
            let completion = try await aiClient.run(
                config: config,
                apiKey: apiKey,
                messages: messages,
                tools: AgentTools.specs
            ) { [weak self] text in
                Task { @MainActor in self?.updateAgentStream(text) }
            }
            try Task.checkCancellation()

            if completion.toolCalls.isEmpty {
                turn.reply = completion.text
                appendAgentStep("模型给出结论")
                break
            }

            var assistant = AIChatMessage(role: "assistant", content: completion.text.isEmpty ? nil : completion.text)
            assistant.toolCalls = completion.toolCalls
            messages.append(assistant)

            for call in completion.toolCalls {
                try Task.checkCancellation()
                let name = call.function.name
                let arguments = AgentTools.arguments(from: call.function.arguments)

                if name == AgentTools.applyPatchName {
                    let patch = arguments.patch ?? ""
                    let result: String
                    if patch.isEmpty {
                        result = "错误：缺少 patch 参数。"
                    } else if executedPatches.contains(patch) {
                        result = "这个补丁已经提交过，请勿重复提交；如果还需要修改，请先 read_file 读取最新内容。"
                    } else {
                        executedPatches.insert(patch)
                        appendAgentStep(AgentTools.stepDescription(name: name, arguments: arguments))
                        result = applyAgentPatch(patch, in: repository, turn: &turn)
                    }
                    messages.append(PromptBuilder.toolResultMessage(callID: call.id, name: name, content: result))
                    continue
                }

                appendAgentStep(AgentTools.stepDescription(name: name, arguments: arguments))
                // 读文件 / 搜索可能很耗时，放到后台线程避免卡住界面。
                // 显式捕获为局部常量：Task.detached 逃逸出 @MainActor，
                // 直接引用 self 的 workspace 会触发「requires explicit use of self」编译错误。
                let workspace = self.workspace
                let toolResult = await Task.detached(priority: .userInitiated) {
                    AgentTools.run(
                        name: name,
                        arguments: arguments,
                        fileTree: fileTree,
                        repository: repository,
                        workspace: workspace
                    )
                }.value
                let result = toolResult ?? "错误：未知工具 \(name)。"
                if name == "read_file", let path = arguments.path {
                    rememberFile(path, in: repository, snapshot: snapshot)
                }
                messages.append(PromptBuilder.toolResultMessage(callID: call.id, name: name, content: result))
            }
        }
        return turn
    }

    /// 文本回退循环：<<READ>> 索要文件 + 最终输出 unified diff。
    private func runTextLoop(
        repository: Repository,
        config: AIProviderConfig,
        apiKey: String,
        body: [AIChatMessage],
        fileTree: [String],
        snapshot: [String: String]
    ) async throws -> AgentTurn {
        var turn = AgentTurn()
        var messages: [AIChatMessage] = [PromptBuilder.textSystemMessage(config: config)]
        messages.append(contentsOf: body)
        var readPaths = Set<String>()
        var totalReadChars = 0
        var stopReading = false
        var reply = ""
        let maxRounds = 10

        for round in 1...maxRounds {
            try Task.checkCancellation()
            setAgentStatus(round == 1
                ? "正在请求模型…（第 1 轮，先只发文件树）"
                : "正在请求模型…（第 \(round) 轮）")
            streamBase = agentStream
            let completion = try await aiClient.run(
                config: config,
                apiKey: apiKey,
                messages: messages,
                tools: nil
            ) { [weak self] text in
                Task { @MainActor in self?.updateAgentStream(text) }
            }
            try Task.checkCancellation()
            let output = completion.text

            let requests = stopReading ? [] : PromptBuilder.requestedPaths(in: output)
            let fresh = requests.filter { !readPaths.contains($0) }
            let outputHasDiff = Self.looksLikeDiff(output)

            if fresh.isEmpty || outputHasDiff || round == maxRounds {
                reply = output
                break
            }

            setAgentStatus("模型请求读取 \(fresh.count) 个文件…")
            let (found, missing) = Self.resolveRequestedPaths(fresh, in: fileTree)
            var files: [FileContext] = []
            for path in found {
                guard let content = snapshot[path] else { continue }
                let trimmedBody = content.count > Self.readFileLimit
                    ? String(content.prefix(Self.readFileLimit)) + "\n…（内容过长已截断）"
                    : content
                files.append(FileContext(path: path, content: trimmedBody))
                totalReadChars += trimmedBody.count
            }

            messages.append(AIChatMessage(role: "assistant", content: output))
            messages.append(PromptBuilder.readResultMessage(requested: fresh, files: files, missing: missing))
            readPaths.formUnion(found)
            readPaths.formUnion(missing)
            // 把模型这次读了哪些文件写进过程记录，让进度像 Codex 一样具体。
            for path in found.prefix(12) {
                appendAgentStep("读取 \(path)")
                rememberFile(path, in: repository, snapshot: snapshot)
            }
            if found.count > 12 {
                appendAgentStep("…其余 \(found.count - 12) 个文件")
            }
            if !missing.isEmpty {
                appendAgentStep("未找到 \(missing.count) 个文件，已告知模型")
            }
            Log.debug("按需读取：请求 \(fresh.count) 个，命中 \(files.count) 个，缺失 \(missing.count) 个", .ai)

            if totalReadChars > Self.readBudget {
                stopReading = true
                messages.append(AIChatMessage(role: "user", content: "已读取足够多的内容，请直接基于现有信息输出 unified diff，不要再请求文件。"))
            }
        }

        turn.reply = reply
        let diffText = DiffExtractor.extract(from: reply)
        turn.patches = (try? DiffParser.parse(diffText)) ?? []
        return turn
    }

    /// 执行 apply_patch 工具：解析 → 应用 → 记录，并把结果回给模型。
    private func applyAgentPatch(_ text: String, in repository: Repository, turn: inout AgentTurn) -> String {
        do {
            let filePatches = try ApplyPatchParser.parse(text)
            let outcome = apply(patches: filePatches, in: repository)
            turn.patches.append(contentsOf: filePatches)
            turn.applied += outcome.applied
            turn.failed += outcome.failed
            if let summary = outcome.failureSummary { turn.failureSummary = summary }

            if outcome.isComplete {
                lastError = nil
                appendAgentStep("已应用 \(filePatches.count) 个文件的改动")
                return "已成功应用 \(filePatches.count) 个文件的改动：\(filePatches.map(\.path).joined(separator: "、"))"
            }
            if outcome.isPartial {
                appendAgentStep("部分改动失败（\(outcome.failed)/\(filePatches.count)）")
                return "部分成功：已应用 \(outcome.applied) 个，失败 \(outcome.failed) 个（\(outcome.failureSummary ?? "未知错误")）。请 read_file 读取失败文件的最新内容后重新提交补丁。"
            }
            appendAgentStep("改动应用失败")
            return "补丁应用失败：\(outcome.failureSummary ?? "未知错误")。请 read_file 读取最新内容后重新提交。"
        } catch {
            appendAgentStep("补丁格式无法解析")
            return "补丁无法解析：\(error.localizedDescription)。请严格使用 *** Begin Patch / *** Update File 格式重新提交。"
        }
    }

    /// 更新流式输出（节流，避免每个 token 都刷新界面）。
    private func updateAgentStream(_ text: String) {
        let now = Date()
        guard now.timeIntervalSince(lastStreamUpdate) >= 0.12 else { return }
        lastStreamUpdate = now
        // 拼接之前轮次的输出，保证「AI 说过的话」不因进入下一轮被清空。
        agentStream = String((streamBase + text).suffix(6_000))
    }

    /// 记住某个文件内容，供后续轮次复用（最多 8 个 / 20 万字符）。
    private func rememberFile(_ path: String, in repository: Repository, snapshot: [String: String]) {
        guard let content = snapshot[path] else { return }
        var items = agentFileMemory[repository.id] ?? []
        items.removeAll { $0.path == path }
        items.append((path: path, content: String(content.prefix(40_000))))
        var total = items.reduce(0) { $0 + $1.content.count }
        while items.count > 8 || (total > 200_000 && items.count > 1) {
            total -= items[0].content.count
            items.removeFirst()
        }
        agentFileMemory[repository.id] = items
    }

    /// 回到前台 / 网络恢复后自动重试被中断的请求。
    func resumePendingSendIfNeeded() async {
        guard pendingResend != nil, !isSending else { return }
        guard let pending = pendingResend,
              let repository = repositories.first(where: { $0.id == pending.repositoryID }) else {
            pendingResend = nil
            return
        }
        pendingResend = nil
        Log.info("自动恢复被中断的对话：\(repository.fullName)", .ai)
        await performSend(pending.text, in: repository, contextPaths: [], appendUserMessage: false)
    }

    /// 网络抖动时在后台稍等一会儿再自动重试一次；若仍失败会再次排队。
    private func schedulePendingResend() {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard let self, self.pendingResend != nil, !self.isSending else { return }
            await self.resumePendingSendIfNeeded()
        }
    }


    /// 读取指定文件内容，用于对话上下文。
    func fileContents(for repository: Repository, paths: [String]) -> [FileContext] {
        let snapshot = (try? workspace.snapshot(repository: repository)) ?? [:]
        return paths.compactMap { path in
            guard let content = snapshot[path] else { return nil }
            return FileContext(path: path, content: content)
        }
    }

    /// 判断模型回复里是否已经包含可用的 unified diff。
    ///
    /// 注意不能直接用 DiffExtractor.extract 是否非空：它在没有 diff 头时会把整段
    /// 文本原样返回，会把纯文字 / <<READ>> 回复误判成 diff。
    private static func looksLikeDiff(_ text: String) -> Bool {
        if text.contains("@@ -") { return true }
        return text.contains("--- ") && text.contains("+++ ")
    }

    /// 单次读取的文件体积上限（避免一个超大文件撑爆请求）。
    private static let readFileLimit = 120_000

    /// 一轮对话里按需读取的总体积上限，超过后要求模型直接给出 diff。
    private static let readBudget = 600_000

    /// 把模型请求的路径解析到文件树里的真实路径（大小写不敏感）。
    private static func resolveRequestedPaths(
        _ requested: [String],
        in tree: [String]
    ) -> (found: [String], missing: [String]) {
        var index: [String: String] = [:]
        for path in tree { index[path.lowercased()] = path }

        var found: [String] = []
        var missing: [String] = []
        for raw in requested {
            let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let real = index[key] {
                found.append(real)
            } else {
                missing.append(raw)
            }
        }
        return (found, missing)
    }

    // MARK: - 分支

    func branches(for repository: Repository) -> [String] {
        branchesByRepository[repository.id] ?? [repository.currentBranch]
    }

    func loadBranches(for repository: Repository) async {
        do {
            let list = try await github.branches(owner: repository.owner, repo: repository.name)
            var names = list.map(\.name)
            if !names.contains(repository.currentBranch) {
                names.insert(repository.currentBranch, at: 0)
            }
            branchesByRepository[repository.id] = names
            persistAll()
            Log.debug("加载分支：\(repository.fullName) → \(names.count) 个分支", .github)
        } catch {
            report(error, .github)
        }
    }

    /// 加载当前分支最近的提交历史（供「提交历史」页展示）。
    func loadCommits(for repository: Repository, perPage: Int = 50) async {
        do {
            let list = try await github.commits(
                owner: repository.owner,
                repo: repository.name,
                branch: repository.currentBranch,
                perPage: perPage
            )
            commitsByRepository[repository.id] = list
            Log.debug("加载提交历史：\(repository.fullName)＠\(repository.currentBranch) → \(list.count) 条", .github)
        } catch {
            report(error, .github)
        }
    }

    /// 推送前检查远端分支是否领先本地 base：true 领先，false 未领先，nil 无法判断。
    func remoteBranchAhead(of repository: Repository) async -> Bool? {
        do {
            let ref = try await github.ref(
                owner: repository.owner,
                repo: repository.name,
                branch: repository.currentBranch
            )
            let ahead = repository.baseCommitSHA != nil && repository.baseCommitSHA != ref.object.sha
            remoteUpdates[repository.id] = ahead
            return ahead
        } catch {
            if Cancellation.isCancellation(error) {
                Log.debug("推送前远端检查已取消：\(repository.fullName)", .github)
            } else {
                Log.warning("推送前远端检查失败：\(repository.fullName)：\(error.localizedDescription)", .github)
            }
            return nil
        }
    }

    /// 依次检查所有仓库的远端是否有新提交。
    func checkForUpdates() async {
        for repository in repositories {
            await checkForUpdates(for: repository)
        }
    }

    /// 检查单个仓库的远端分支是否领先本地 base commit。
    func checkForUpdates(for repository: Repository) async {
        do {
            let ref = try await github.ref(
                owner: repository.owner,
                repo: repository.name,
                branch: repository.currentBranch
            )
            let remote = ref.object.sha
            let outdated = repository.baseCommitSHA != nil && repository.baseCommitSHA != remote
            remoteUpdates[repository.id] = outdated
            Log.debug(
                "远端检查：\(repository.fullName)＠\(repository.currentBranch) → \(remote.prefix(7))，本地 base \(repository.baseCommitSHA?.prefix(7) ?? "无")",
                .github
            )
        } catch {
            if Cancellation.isCancellation(error) {
                Log.debug("远端检查已取消：\(repository.fullName)", .github)
            } else {
                Log.warning("远端检查失败：\(repository.fullName)：\(error.localizedDescription)", .github)
            }
        }
    }

    /// 切换分支：更新元数据后按新分支重新拉取工作区。
    /// 切换会丢弃当前未提交的改动（旧 base 已失效）。
    func switchBranch(_ repository: Repository, to branch: String) async {
        guard branch != repository.currentBranch,
              let index = repositories.firstIndex(where: { $0.id == repository.id }) else { return }

        busyMessage = "正在切换到 \(branch)…"
        defer { busyMessage = nil }
        Log.info("切换分支：\(repository.fullName) → \(branch)", .github)

        do {
            var updated = repositories[index]
            updated.currentBranch = branch
            let result = try await syncService.pull(repository: updated, branch: branch)
            updated.baseCommitSHA = result.sha
            updated.lastSyncedAt = Date()
            repositories[index] = updated
            changesByRepository[repository.id] = []
            agentFileMemory[repository.id] = nil
            persistAll()
            Log.info("分支切换完成：\(repository.fullName) → \(branch)", .github)
        } catch {
            report(error, .github)
        }
    }

    // MARK: - 改动

    /// 一次批量应用的结果。
    struct ApplyOutcome {
        let applied: Int
        let failed: Int
        let failureSummary: String?
        let failedPaths: [String]

        var isComplete: Bool { failed == 0 }
        var isPartial: Bool { applied > 0 && failed > 0 }
    }

    @discardableResult
    func apply(patches: [FilePatch], in repository: Repository, messageID: UUID? = nil) -> ApplyOutcome {
        var applied = 0
        var failures: [String] = []
        var failedPaths: [String] = []

        for patch in patches {
            do {
                let target = resolvedPatch(patch, in: repository)
                let original = try workspace.read(repository: repository, path: target.path)
                let updated = try PatchApplier.apply(target, to: original)

                if target.kind == .deleted {
                    try workspace.delete(repository: repository, path: target.path)
                } else {
                    try workspace.write(repository: repository, path: target.path, content: updated)
                }

                record(
                    repository: repository,
                    path: target.path,
                    original: original,
                    current: target.kind == .deleted ? "" : updated,
                    status: status(for: target.kind, original: original)
                )
                applied += 1
                Log.debug("应用文件改动：\(target.path)", .diff)
            } catch {
                failures.append("\(patch.path)：\(error.localizedDescription)")
                failedPaths.append(patch.path)
                Log.error(error, .diff)
            }
        }

        persistAll()

        if failures.isEmpty {
            if let messageID {
                appliedMessageIDs.insert(messageID)
            }
            Log.info("应用改动：\(patches.count) 个文件\(messageID == nil ? "" : "（来自消息 \(messageID!.uuidString.prefix(8))）")", .diff)
            return ApplyOutcome(applied: applied, failed: 0, failureSummary: nil, failedPaths: [])
        }

        let summary = failures.joined(separator: "；")
        lastError = failures.count == patches.count
            ? "改动无法应用：\(summary)"
            : "部分改动无法应用（\(failures.count)/\(patches.count)）：\(summary)"
        Log.warning("改动应用失败 \(failures.count)/\(patches.count)：\(summary)", .diff)
        return ApplyOutcome(applied: applied, failed: failures.count, failureSummary: summary, failedPaths: failedPaths)
    }

    /// 模型偶尔会把路径写错（内容其实属于另一个文件）。某个改动在声明的文件里定位不到时，
    /// 在整个工作区里查找唯一包含这些旧内容的文件，并把改动改到该文件上。
    private func resolvedPatch(_ patch: FilePatch, in repository: Repository) -> FilePatch {
        guard patch.kind == .modified else { return patch }

        var declared: String?
        if let value = try? workspace.read(repository: repository, path: patch.path) {
            declared = value
        }
        if let declared, PatchApplier.canLocate(patch, in: declared) {
            return patch
        }

        let snapshot = (try? workspace.snapshot(repository: repository)) ?? [:]
        let candidates = snapshot.filter { element in
            element.key != patch.path && PatchApplier.canLocate(patch, in: element.value)
        }

        guard candidates.count == 1, let path = candidates.keys.first else {
            if candidates.count > 1 {
                Log.warning("改动 \(patch.path) 在多个文件中都能匹配，无法确定目标", .diff)
            }
            return patch
        }

        Log.warning("改动路径与内容不符，改为应用到 \(path)（原声明 \(patch.path)）", .diff)
        var corrected = patch
        corrected.oldPath = path
        corrected.newPath = path
        corrected.declaredKind = .modified
        return corrected
    }

    /// diff 无法应用时的兜底：请模型直接给出修改后的完整文件内容，覆盖写入工作区。
    private func repairFiles(_ paths: [String], instruction: String, in repository: Repository) async -> Int {
        guard !paths.isEmpty, let config = activeAIConfig else { return 0 }
        let apiKey = apiKey(for: config)
        guard !apiKey.isEmpty else { return 0 }

        var repaired = 0
        for path in paths {
            if Task.isCancelled { break }

            var existing: String?
            do {
                existing = try workspace.read(repository: repository, path: path)
            } catch {
                continue
            }
            guard let current = existing else { continue }

            let prompt = """
            之前针对文件 \(path) 的 unified diff 无法应用。请直接给出修改后的完整文件内容：
            用三反引号代码块包裹整份文件，代码块内不要出现任何说明或 diff。
            只改动与用户要求相关的部分，其余内容必须与下面给出的内容完全一致。

            ===== 当前内容 \(path) =====
            \(current)
            ===== end \(path) =====

            用户要求：
            \(instruction)
            """
            let messages: [AIChatMessage] = [
                AIChatMessage(role: "system", content: "你是一个精确的代码编辑器：只输出修改后的完整文件内容，用三反引号代码块包裹，不要输出解释、不要输出 diff。"),
                AIChatMessage(role: "user", content: prompt)
            ]

            do {
                let reply = try await aiClient.complete(config: config, apiKey: apiKey, messages: messages)
                guard let updated = Self.extractCodeBlock(from: reply), !updated.isEmpty else {
                    Log.warning("兜底整文件重写没有拿到代码块：\(path)", .diff)
                    continue
                }
                try workspace.write(repository: repository, path: path, content: updated)
                record(
                    repository: repository,
                    path: path,
                    original: current,
                    current: updated,
                    status: .modified
                )
                repaired += 1
                Log.info("兜底整文件重写成功：\(path)", .diff)
            } catch {
                report(error, .diff)
            }
        }

        if repaired > 0 { persistAll() }
        return repaired
    }

    /// 取第一段围栏代码块的内容。
    private static func extractCodeBlock(from text: String) -> String? {
        let fence = "\u{0060}\u{0060}\u{0060}"
        let lines = text.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.hasPrefix(fence) }) else { return nil }
        var body: [String] = []
        var index = start + 1
        while index < lines.count && !lines[index].hasPrefix(fence) {
            body.append(lines[index])
            index += 1
        }
        let content = body.joined(separator: "\n").trimmingCharacters(in: .newlines)
        return content.isEmpty ? nil : content
    }

    /// 该消息的改动是否已经应用过。
    func isApplied(_ message: ChatMessage) -> Bool {
        appliedMessageIDs.contains(message.id)
    }

    func saveEditedFile(_ repository: Repository, path: String, content: String) {
        do {
            let existing = pendingChanges(for: repository).first { $0.path == path }
            let original: String?
            if let recorded = existing?.original {
                original = recorded
            } else {
                original = try workspace.read(repository: repository, path: path)
            }
            try workspace.write(repository: repository, path: path, content: content)
            let fallback: FileChange.Status = original == nil ? .added : .modified
            let status: FileChange.Status = existing?.status ?? fallback
            record(
                repository: repository,
                path: path,
                original: original,
                current: content,
                status: status
            )
            persistAll()
            Log.info("保存文件：\(repository.fullName)/\(path)", .workspace)
        } catch {
            report(error, .workspace)
        }
    }

    func setStaged(_ staged: Bool, for change: FileChange, in repository: Repository) {
        guard var changes = changesByRepository[repository.id],
              let index = changes.firstIndex(where: { $0.id == change.id }) else { return }
        changes[index].isStaged = staged
        changesByRepository[repository.id] = changes
        persistAll()
    }

    /// 丢弃一处改动：从列表移除，并把工作区文件恢复到改动前的状态。
    func discard(change: FileChange, in repository: Repository) {
        guard var changes = changesByRepository[repository.id] else { return }
        changes.removeAll { $0.id == change.id }
        changesByRepository[repository.id] = changes

        do {
            if change.status == .added {
                // 新增的文件直接删除。
                try workspace.delete(repository: repository, path: change.path)
            } else if let original = change.original {
                // 修改 / 删除的文件用改动前的内容覆盖回去。
                try workspace.write(repository: repository, path: change.path, content: original)
            }
            Log.info("丢弃改动并还原文件：\(repository.fullName)/\(change.path)", .workspace)
        } catch {
            report(error, .workspace)
        }
        persistAll()
    }

    /// force 为 false 时先检查远端分支是否领先本地 base；领先则拦截并提示先拉取。
    @discardableResult
    func commitStaged(in repository: Repository, message: String, force: Bool = false) async -> Bool {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastError = "请先填写提交说明。"
            return false
        }
        let staged = pendingChanges(for: repository).filter { $0.isStaged }
        guard !staged.isEmpty else {
            lastError = "请先勾选要提交的文件。"
            return false
        }
        if !force {
            if let ahead = await remoteBranchAhead(of: repository), ahead {
                lastError = "远程分支 \(repository.currentBranch) 有新的提交。请先拉取最新代码（本地未提交的改动会被覆盖），再重新提交。"
                Log.warning("推送被拦截：远端领先 \(repository.fullName)＠\(repository.currentBranch)", .github)
                return false
            }
        }
        busyMessage = "正在提交并推送…"
        defer { busyMessage = nil }
        Log.info("开始提交：\(repository.fullName)＠\(repository.currentBranch)，\(staged.count) 个文件", .github)
        do {
            let sha = try await gitData.commit(repository: repository, changes: staged, message: trimmed)
            var remaining = pendingChanges(for: repository)
            remaining.removeAll { $0.isStaged }
            changesByRepository[repository.id] = remaining
            persistAll()
            Log.info("提交并推送成功：\(staged.count) 个文件，新 commit \(sha.prefix(7))", .github)

            // 推送成功后重新拉取一次，让本地工作区与 base 跟上远端的最新提交。
            busyMessage = "正在同步远端…"
            do {
                let result = try await syncService.pull(repository: repository)
                if let index = repositories.firstIndex(where: { $0.id == repository.id }) {
                    repositories[index].baseCommitSHA = result.sha
                    repositories[index].lastSyncedAt = Date()
                }
                // 工作区已被远端内容整体覆盖，未提交的改动不再存在于磁盘上，一并清掉避免列表与工作区不一致。
                changesByRepository[repository.id] = []
                agentFileMemory[repository.id] = nil
                remoteUpdates[repository.id] = false
                persistAll()
                Log.info("推送后重新拉取完成：\(repository.fullName)，base \(result.sha.prefix(7))", .workspace)
            } catch {
                report(error, .workspace)
            }
            return true
        } catch {
            if isRetryable(error) {
                enqueuePendingPush(repository: repository, message: trimmed, changes: staged, error: error)
                lastError = "网络不可用，已把 \(staged.count) 个文件加入离线队列，联网后会自动推送。"
                Log.warning("提交失败，进入离线队列：\(repository.fullName)：\(error.localizedDescription)", .github)
            } else {
                report(error, .github)
            }
            return false
        }
    }

    // MARK: - 离线推送队列

    /// 可重试的错误（网络中断 / 服务端 5xx）。
    private func isRetryable(_ error: Error) -> Bool {
        if Cancellation.isCancellation(error) { return false }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost,
                 .cannotFindHost, .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff:
                return true
            default:
                return false
            }
        }
        if let gitHubError = error as? GitHubError, case .http(let status, _) = gitHubError {
            return status >= 500
        }
        return false
    }

    private func enqueuePendingPush(
        repository: Repository,
        message: String,
        changes: [FileChange],
        error: Error
    ) {
        let item = PendingPush(
            repositoryID: repository.id,
            owner: repository.owner,
            name: repository.name,
            branch: repository.currentBranch,
            message: message,
            changes: changes,
            lastError: error.localizedDescription
        )
        // 同一个仓库、同一批文件如果已经在队列里（用户重试又失败），覆盖旧条目而不是叠加。
        let paths = Set(changes.map(\.path))
        pendingPushes.removeAll { existing in
            existing.repositoryID == repository.id && Set(existing.changes.map(\.path)) == paths
        }
        pendingPushes.append(item)
        persistAll()
        Log.warning("已加入离线队列（\(changes.count) 个文件）：\(repository.fullName)", .github)
    }

    /// 网络恢复 / 应用回到前台时，重试队列里的提交。
    func flushPendingPushes() async {
        guard !pendingPushes.isEmpty, !isFlushingPushes else { return }
        isFlushingPushes = true
        defer { isFlushingPushes = false }
        Log.info("开始重试 \(pendingPushes.count) 条离线推送", .github)
        for item in pendingPushes {
            let repository = repositories.first { $0.id == item.repositoryID } ?? item.placeholderRepository
            do {
                let sha = try await gitData.commit(repository: repository, changes: item.changes, message: item.message)
                pendingPushes.removeAll { $0.id == item.id }
                if let index = repositories.firstIndex(where: { $0.id == item.repositoryID }) {
                    repositories[index].baseCommitSHA = sha
                    repositories[index].lastSyncedAt = Date()
                }
                let pushedPaths = Set(item.changes.map(\.path))
                changesByRepository[repository.id]?.removeAll { pushedPaths.contains($0.path) }
                agentFileMemory[repository.id] = nil
                remoteUpdates[repository.id] = false
                persistAll()
                Log.info("离线队列推送成功：\(item.fullName)，commit \(sha.prefix(7))", .github)
            } catch {
                if let index = pendingPushes.firstIndex(where: { $0.id == item.id }) {
                    pendingPushes[index].attempts += 1
                    pendingPushes[index].lastAttemptAt = Date()
                    pendingPushes[index].lastError = error.localizedDescription
                }
                persistAll()
                if isRetryable(error) {
                    Log.warning("离线队列推送仍失败：\(item.fullName)：\(error.localizedDescription)", .github)
                } else {
                    Log.error("离线队列推送失败（不可重试，保留队列）：\(item.fullName)：\(error.localizedDescription)", .github)
                }
            }
        }
    }

    /// 用户手动放弃一条离线队列记录。
    func removePendingPush(_ item: PendingPush) {
        pendingPushes.removeAll { $0.id == item.id }
        persistAll()
    }

    // MARK: - 私有

    /// 统一错误上报：取消类错误只记调试日志，不弹错。
    private func report(_ error: Error, _ category: LogCategory) {
        if Cancellation.isCancellation(error) {
            Log.debug("请求已取消：\(error.localizedDescription)", category)
            return
        }
        lastError = error.localizedDescription
        Log.error(error, category)
    }

    private func status(for kind: FilePatch.Kind, original: String?) -> FileChange.Status {
        switch kind {
        case .added: return .added
        case .deleted: return .deleted
        case .modified: return original == nil ? .added : .modified
        }
    }

    private func record(
        repository: Repository,
        path: String,
        original: String?,
        current: String,
        status: FileChange.Status
    ) {
        var changes = changesByRepository[repository.id] ?? []
        if let index = changes.firstIndex(where: { $0.path == path }) {
            changes[index].current = current
            changes[index].status = status
            if changes[index].original == nil { changes[index].original = original }
        } else {
            changes.append(
                FileChange(
                    path: path,
                    status: status,
                    original: original,
                    current: current,
                    isStaged: true
                )
            )
        }
        changesByRepository[repository.id] = changes
    }
}
