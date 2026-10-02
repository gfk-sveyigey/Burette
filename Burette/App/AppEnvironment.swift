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
            _ = try await github.currentUser()
            try keychain.set(trimmed, for: KeychainStore.gitHubTokenKey)
            isAuthenticated = true
            lastError = nil
        } catch {
            await github.updateToken(nil)
            lastError = error.localizedDescription
        }
    }

    func signOut() {
        try? keychain.delete(KeychainStore.gitHubTokenKey)
        Task { await github.updateToken(nil) }
        isAuthenticated = false
        repositories = []
        selectedRepositoryID = nil
        persistAll()
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
    }

    func clone(_ repository: Repository) async {
        busyMessage = "正在拉取 \(repository.fullName)…"
        defer { busyMessage = nil }
        do {
            let result = try await syncService.pull(repository: repository)
            if let index = repositories.firstIndex(where: { $0.id == repository.id }) {
                repositories[index].baseCommitSHA = result.sha
                repositories[index].lastSyncedAt = Date()
            }
            persistAll()
        } catch {
            lastError = error.localizedDescription
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

        var history = messages(for: repository)
        history.append(ChatMessage(role: .user, content: trimmed))
        messagesByRepository[repository.id] = history
        persistAll()

        let snapshot = (try? workspace.snapshot(repository: repository)) ?? [:]
        let tree = (try? workspace.listFiles(repository: repository)) ?? []

        let files: [FileContext]
        if contextPaths.isEmpty {
            files = PromptBuilder.relevantFiles(for: trimmed, in: snapshot)
        } else {
            files = contextPaths.compactMap { path in
                guard let content = snapshot[path] else { return nil }
                return FileContext(path: path, content: content)
            }
        }

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
        } catch {
            lastError = error.localizedDescription
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
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// 切换分支：更新元数据后按新分支重新拉取工作区。
    /// 切换会丢弃当前未提交的改动（旧 base 已失效）。
    func switchBranch(_ repository: Repository, to branch: String) async {
        guard branch != repository.currentBranch,
              let index = repositories.firstIndex(where: { $0.id == repository.id }) else { return }

        busyMessage = "正在切换到 \(branch)…"
        defer { busyMessage = nil }

        do {
            var updated = repositories[index]
            updated.currentBranch = branch
            let result = try await syncService.pull(repository: updated, branch: branch)
            updated.baseCommitSHA = result.sha
            updated.lastSyncedAt = Date()
            repositories[index] = updated
            changesByRepository[repository.id] = []
            persistAll()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - 改动

    func apply(patches: [FilePatch], in repository: Repository) {
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
            persistAll()
        } catch {
            lastError = error.localizedDescription
        }
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
        } catch {
            lastError = error.localizedDescription
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
        } catch {
            lastError = error.localizedDescription
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
