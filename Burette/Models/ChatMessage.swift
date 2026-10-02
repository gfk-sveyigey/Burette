import Foundation

/// 一条对话消息。
struct ChatMessage: Identifiable, Codable, Hashable, Sendable {
    enum Role: String, Codable, Sendable {
        case system
        case user
        case assistant
    }

    var id: UUID
    var role: Role
    var content: String
    var createdAt: Date

    /// assistant 消息中解析出的改动，用于预览与应用。
    var patches: [FilePatch]?

    /// 生成这条消息所用的时长（秒），仅 assistant 消息有值。
    var duration: TimeInterval?

    init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        createdAt: Date = Date(),
        patches: [FilePatch]? = nil,
        duration: TimeInterval? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.patches = patches
        self.duration = duration
    }

    /// 转换为 OpenAI 兼容的消息体。
    var apiMessage: AIChatMessage {
        AIChatMessage(role: role.rawValue, content: content)
    }
}
