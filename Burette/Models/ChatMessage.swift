import Foundation

/// 一条对话消息。
struct ChatMessage: Identifiable, Codable, Hashable, Sendable {
    enum Role: String, Codable, Sendable {
        case system
        case user
        case assistant
    }

    /// 这条回复里的改动最终是否写入了工作区。
    enum ApplyState: String, Codable, Sendable {
        case applied
        case partial
        case failed
    }

    var id: UUID
    var role: Role
    var content: String
    var createdAt: Date

    /// assistant 消息中解析出的改动，用于预览与应用。
    var patches: [FilePatch]?

    /// 生成这条消息所用的时长（秒），仅 assistant 消息有值。
    var duration: TimeInterval?

    /// 改动应用结果，nil 表示这条回复没有改动。
    var applyState: ApplyState?

    init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        createdAt: Date = Date(),
        patches: [FilePatch]? = nil,
        duration: TimeInterval? = nil,
        applyState: ApplyState? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.patches = patches
        self.duration = duration
        self.applyState = applyState
    }

    /// 转换为 OpenAI 兼容的消息体。
    var apiMessage: AIChatMessage {
        AIChatMessage(role: role.rawValue, content: content)
    }
}
