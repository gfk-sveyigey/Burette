import Foundation

/// 一个仓库下的一条对话。
///
/// 之前每个仓库只有一条隐式的消息列表；引入对话管理后，
/// 每个仓库可以保存多条对话，并在它们之间切换。
struct Conversation: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var messages: [ChatMessage]

    init(
        id: UUID = UUID(),
        title: String = "新对话",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        messages: [ChatMessage] = []
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
    }

    /// 展示用标题。
    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未命名对话" : trimmed
    }

    /// 副标题：最后一条消息的摘要。
    var subtitle: String {
        guard let last = messages.last else { return "还没有消息" }
        let text = last.content.replacingOccurrences(of: "\n", with: " ")
        let summary = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { return "还没有消息" }
        return String(summary.prefix(40))
    }

    /// 用第一条用户消息生成默认标题。
    static func defaultTitle(from message: String) -> String {
        let text = message
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "新对话" }
        return String(text.prefix(16))
    }
}
