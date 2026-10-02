import Foundation

/// 一个被 Burette 管理的 GitHub 仓库。
///
/// 本地不维护 .git 目录，只保存「工作区文件 + 元数据」。
/// baseCommitSHA 记录当前工作区所基于的远端提交，用于判断远端是否领先。
struct Repository: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var owner: String
    var name: String
    var defaultBranch: String
    var currentBranch: String

    /// 工作区在应用沙盒 Workspaces 目录下的相对文件夹名。
    var workspaceFolder: String

    /// 当前分支工作区所基于的远端 commit SHA。
    var baseCommitSHA: String?

    var isPrivate: Bool
    var lastSyncedAt: Date?

    init(
        id: UUID = UUID(),
        owner: String,
        name: String,
        defaultBranch: String = "main",
        currentBranch: String? = nil,
        workspaceFolder: String? = nil,
        baseCommitSHA: String? = nil,
        isPrivate: Bool = false,
        lastSyncedAt: Date? = nil
    ) {
        self.id = id
        self.owner = owner
        self.name = name
        self.defaultBranch = defaultBranch
        self.currentBranch = currentBranch ?? defaultBranch
        self.workspaceFolder = workspaceFolder ?? "\(owner)--\(name)"
        self.baseCommitSHA = baseCommitSHA
        self.isPrivate = isPrivate
        self.lastSyncedAt = lastSyncedAt
    }

    var fullName: String { "\(owner)/\(name)" }
}
