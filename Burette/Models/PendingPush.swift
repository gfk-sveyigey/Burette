import Foundation

/// 离线推送队列里的一条待推送提交。
///
/// 断网时点「提交并推送」不会把改动丢掉：改动内容与提交说明先进入队列，
/// 等网络恢复 / 应用回到前台再自动重试（见 AppEnvironment.flushPendingPushes）。
struct PendingPush: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var repositoryID: UUID
    var owner: String
    var name: String
    var branch: String
    var message: String
    var changes: [FileChange]
    var createdAt: Date
    var attempts: Int
    var lastAttemptAt: Date?
    var lastError: String?

    init(
        id: UUID = UUID(),
        repositoryID: UUID,
        owner: String,
        name: String,
        branch: String,
        message: String,
        changes: [FileChange],
        createdAt: Date = Date(),
        attempts: Int = 0,
        lastAttemptAt: Date? = nil,
        lastError: String? = nil
    ) {
        self.id = id
        self.repositoryID = repositoryID
        self.owner = owner
        self.name = name
        self.branch = branch
        self.message = message
        self.changes = changes
        self.createdAt = createdAt
        self.attempts = attempts
        self.lastAttemptAt = lastAttemptAt
        self.lastError = lastError
    }

    var fullName: String { "\(owner)/\(name)" }

    /// 用队列里的信息还原一个 Repository（用于在无本地仓库对象时推送）。
    var placeholderRepository: Repository {
        Repository(
            id: repositoryID,
            owner: owner,
            name: name,
            defaultBranch: branch,
            currentBranch: branch
        )
    }
}
