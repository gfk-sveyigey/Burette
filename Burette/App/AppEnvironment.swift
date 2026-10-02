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
    @Published var messagesByRepository: [UUID: [ChatMessage]] = [:]
    @Published var changesByRepository: [UUID: [FileChange]] = [:]
    @Published var branchesByRepository: [UUID: [String]] = [:]
    @Published var appliedMessageIDs: Set<UUID> = []
    @Published var tokenScopes: [String] = []

    @Published var currentUser: GitHubUser?
    @Published var isAuthenticated = false
    @Published var isSending = false
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

    func messages(for repository: Repository) -> [ChatMessage] {
        messagesByRepository[repository.id] ?? []
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
            messagesByRepository = try store.load([UUID: [ChatMessage]].self, from: "messages") ?? [:]
            changesByRepository = try store.load([UUID: [FileChange]].self, from: "changes") ?? [:]
            appliedMessageIDs = Set(try store.load([UUID].self, from: "applied-messages") ?? [])
            selectedRepositoryID = repositories.first?.id
            selectedAIConfigID = aiConfigs.first?.id
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func persistAll() {
        do {
            try store.save(repositories, to: "repositories")
            try store.save(aiConfigs, to: "ai-configs")
            try store.save(messagesByRepository, to: "messages")
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
            lastError = error.localizedDescription
            Log.error(error, .app)
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
        messagesByRepository[repository.id] = nil
        branchesByRepository[repository.id] = nil
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
            persistAll()
            Log.info("拉取完成：\(repository.fullName)，\(result.fileCount) 个文件，base \(result.sha.prefix(7))", .workspace)
        } catch {
            lastError = error.localizedDescription
            Log.error(error, .workspace)
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
    func send(_ text: String, in repository: Repository, contextPaths: [String] = []) async {
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
        defer { isSending = false }
        Log.info("发送对话请求：\(repository.fullName)，\(trimmed.count) 字", .ai)

        var history = messages(for: repository)
        history.append(ChatMessage(role: .user, content: trimmed))
        messagesByRepository[repository.id] = history
        persistAll()

        let snapshot = (try? workspace.snapshot(repository: repository)) ?? [:]
        let tree = (try? workspace.listFiles(repository: repository)) ?? []

        let files: [FileContext]
        if contextPaths.isEmpty {
            // 未显式指定时，把该项目所有文本文件都作为参考。
            files = snapshot.keys.sorted().compactMap { path in
                snapshot[path].map { FileContext(path: path, content: $0) }
            }
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
        for message in history.suffix(20) where message.role != .system {
            apiMessages.append(message.apiMessage)
        }

        do {
            let reply = try await aiClient.complete(config: config, apiKey: apiKey, messages: apiMessages)
            let diffText = DiffExtractor.extract(from: reply)
            let patches = try? DiffParser.parse(diffText)

            var updated = messagesByRepository[repository.id] ?? []
            updated.append(ChatMessage(role: .assistant, content: reply, patches: patches))
            messagesByRepository[repository.id] = updated
            persistAll()
            Log.info("收到 AI 回复：\(reply.count) 字，解析出 \(patches?.count ?? 0) 个文件改动", .ai)
        } catch {
            lastError = error.localizedDescription
            Log.error(error, .ai)
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
            lastError = error.localizedDescription
            Log.error(error, .github)
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
            lastError = error.localizedDescription
            Log.error(error, .github)
        }
    }

    // MARK: - 改动

    @discardableResult
    func apply(patches: [FilePatch], in repository: Repository, messageID: UUID? = nil) -> Bool {
        do {
            for patch in patches {
                let original = try workspace.read(repository: repository, path: patch.path)
                let updated = try PatchApplier.apply(patch, to: original)

                if patch.kind == .deleted {
                    try workspace.delete(repository: repository, path: patch.path)
                } else {
                    try workspace.write(repository: repository, path: patch.path, content: updated)
                }

                record(
                    repository: repository,
                    path: patch.path,
                    original: original,
                    current: patch.kind == .deleted ? "" : updated,
                    status: status(for: patch.kind, original: original)
                )
            }
            if let messageID {
                appliedMessageIDs.insert(messageID)
            }
            persistAll()
            Log.info("应用改动：\(patches.count) 个文件\(messageID == nil ? "" : "（来自消息 \(messageID!.uuidString.prefix(8))）")", .diff)
            return true
        } catch {
            lastError = error.localizedDescription
            Log.error(error, .diff)
            return false
        }
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
            lastError = error.localizedDescription
            Log.error(error, .workspace)
        }
    }

    func setStaged(_ staged: Bool, for change: FileChange, in repository: Repository) {
        guard var changes = changesByRepository[repository.id],
              let index = changes.firstIndex(where: { $0.id == change.id }) else { return }
        changes[index].isStaged = staged
        changesByRepository[repository.id] = changes
        persistAll()
    }

    func discard(change: FileChange, in repository: Repository) {
        guard var changes = changesByRepository[repository.id] else { return }
        changes.removeAll { $0.id == change.id }
        changesByRepository[repository.id] = changes
        persistAll()
    }

    func commitStaged(in repository: Repository, message: String) async {
        let staged = pendingChanges(for: repository).filter { $0.isStaged }
        guard !staged.isEmpty else {
            lastError = "请先勾选要提交的文件。"
            return
        }
        busyMessage = "正在提交并推送…"
        defer { busyMessage = nil }
        do {
            let sha = try await gitData.commit(repository: repository, changes: staged, message: message)
            if let index = repositories.firstIndex(where: { $0.id == repository.id }) {
                repositories[index].baseCommitSHA = sha
                repositories[index].lastSyncedAt = Date()
            }
            var remaining = pendingChanges(for: repository)
            remaining.removeAll { $0.isStaged }
            changesByRepository[repository.id] = remaining
            persistAll()
            Log.info("提交并推送成功：\(staged.count) 个文件，新 commit \(sha.prefix(7))", .github)
        } catch {
            lastError = error.localizedDescription
            Log.error(error, .github)
        }
    }

    // MARK: - 私有

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
