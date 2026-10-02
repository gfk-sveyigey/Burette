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

    init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        createdAt: Date = Date(),
        patches: [FilePatch]? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.patches = patches
    }

    /// 转换为 OpenAI 兼容的消息体。
    var apiMessage: AIChatMessage {
        AIChatMessage(role: role.rawValue, content: content)
    }
}
