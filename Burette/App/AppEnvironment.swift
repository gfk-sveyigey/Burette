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

    @Published var currentUser: GitHubUser?
    @Published var isAuthenticated = false
    @Published var isSending = false
    /// 正在进行中的 agent 步骤描述（对话页实时展示）。
    @Published var agentStatus: String?
    /// 本次请求的开始时间，用于界面显示已用时长。
    @Published var agentStartedAt: Date?
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

    // MARK: - Init

    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Burette", isDirectory: true)
    }

    init(store: PersistenceStore? = nil) {
        let resolvedStore = store ?? JSONStore(directory: AppEnvironment.supportDirectory)
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
        sendTask = Task { [weak self] in
            await self?.performSend(text, in: repository, contextPaths: contextPaths)
        }
    }

    /// 中断正在进行的对话请求（保留已经发出的用户消息）。
    func cancelSend() {
        guard sendTask != nil || isSending else { return }
        sendTask?.cancel()
        sendTask = nil
        isSending = false
        agentStatus = nil
        Log.info("已中断对话请求", .ai)
    }

    private func performSend(_ text: String, in repository: Repository, contextPaths: [String]) async {
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
        defer {
            isSending = false
            agentStatus = nil
            agentStartedAt = nil
        }
        Log.info("发送对话请求：\(repository.fullName)，\(trimmed.count) 字", .ai)

        let conversation = ensureConversation(for: repository)
        appendMessage(ChatMessage(role: .user, content: trimmed), to: conversation.id, in: repository)
        persistAll()

        let history = messages(for: repository)

        agentStatus = "正在整理仓库上下文…"
        let snapshot = (try? workspace.snapshot(repository: repository)) ?? [:]
        let tree = (try? workspace.listFiles(repository: repository)) ?? []

        let files: [FileContext]
        if contextPaths.isEmpty {
            // 未显式指定时把整个项目作为参考；超出预算会自动挑选相关文件并截断。
            files = PromptBuilder.contextFiles(for: trimmed, snapshot: snapshot)
        } else {
            files = contextPaths.compactMap { path in
                guard let content = snapshot[path] else { return nil }
                return FileContext(path: path, content: content)
            }
        }

        let contextChars = files.reduce(0) { $0 + $1.content.count }
        Log.debug("上下文：文件树 \(tree.count) 项，参考文件 \(files.count) 个，共 \(contextChars) 字", .ai)

        var apiMessages: [AIChatMessage] = [PromptBuilder.systemMessage(config: config)]
        apiMessages.append(PromptBuilder.contextMessage(fileTree: tree, files: files))
        for message in history.suffix(12) where message.role != .system {
            apiMessages.append(message.apiMessage)
        }

        // 退到后台 / 锁屏时申请额外执行时间，尽量让请求跑完。
        let backgroundTask = BackgroundTask()
        backgroundTask.begin("AIRequest")
        defer { backgroundTask.end() }

        do {
            agentStatus = "正在请求 AI 模型…"
            let reply = try await aiClient.complete(config: config, apiKey: apiKey, messages: apiMessages)
            try Task.checkCancellation()
            agentStatus = "正在解析改动…"
            let diffText = DiffExtractor.extract(from: reply)
            let patches = try? DiffParser.parse(diffText)

            let elapsed = Date().timeIntervalSince(startedAt)
            let messageID = UUID()

            // 先应用改动，再按真实结果生成消息，避免失败时也显示「已应用」。
            var applyState: ChatMessage.ApplyState?
            if let patches, !patches.isEmpty {
                let outcome = apply(patches: patches, in: repository, messageID: messageID)
                if outcome.isComplete {
                    applyState = .applied
                    applyNotice = "已自动应用 \(patches.count) 个文件的改动"
                    Log.info("收到 AI 回复并自动应用：\(reply.count) 字，\(patches.count) 个文件改动，用时 \(DurationFormat.short(elapsed))", .ai)
                } else {
                    applyState = outcome.isPartial ? .partial : .failed
                    // 用 toast 提示失败原因，不弹全局错误框打断。
                    let reason = lastError ?? outcome.failureSummary ?? "未知错误"
                    lastError = nil
                    applyNotice = reason.count > 160 ? String(reason.prefix(160)) + "…" : reason
                    Log.warning("自动应用改动失败 \(outcome.applied)/\(patches.count)：\(reason)", .diff)
                }
            } else {
                Log.info("收到 AI 回复：\(reply.count) 字，没有可应用的改动", .ai)
            }

            let message = ChatMessage(
                id: messageID,
                role: .assistant,
                content: DiffExtractor.prose(from: reply),
                patches: patches,
                duration: elapsed,
                applyState: applyState
            )
            appendMessage(message, to: conversation.id, in: repository)
            persistAll()
        } catch {
            if Cancellation.isCancellation(error) {
                Log.info("对话请求已中断", .ai)
            } else {
                lastError = error.localizedDescription
                Log.error(error, .ai)
            }
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

        var isComplete: Bool { failed == 0 }
        var isPartial: Bool { applied > 0 && failed > 0 }
    }

    @discardableResult
    func apply(patches: [FilePatch], in repository: Repository, messageID: UUID? = nil) -> ApplyOutcome {
        var applied = 0
        var failures: [String] = []

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
                Log.error(error, .diff)
            }
        }

        persistAll()

        if failures.isEmpty {
            if let messageID {
                appliedMessageIDs.insert(messageID)
            }
            Log.info("应用改动：\(patches.count) 个文件\(messageID == nil ? "" : "（来自消息 \(messageID!.uuidString.prefix(8))）")", .diff)
            return ApplyOutcome(applied: applied, failed: 0, failureSummary: nil)
        }

        let summary = failures.joined(separator: "；")
        lastError = failures.count == patches.count
            ? "改动无法应用：\(summary)"
            : "部分改动无法应用（\(failures.count)/\(patches.count)）：\(summary)"
        Log.warning("改动应用失败 \(failures.count)/\(patches.count)：\(summary)", .diff)
        return ApplyOutcome(applied: applied, failed: failures.count, failureSummary: summary)
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

    @discardableResult
    func commitStaged(in repository: Repository, message: String) async -> Bool {
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
                remoteUpdates[repository.id] = false
                persistAll()
                Log.info("推送后重新拉取完成：\(repository.fullName)，base \(result.sha.prefix(7))", .workspace)
            } catch {
                report(error, .workspace)
            }
            return true
        } catch {
            report(error, .github)
            return false
        }
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
