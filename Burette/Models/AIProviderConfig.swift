import Foundation

/// 一套 OpenAI 兼容的 API 配置。
///
/// 出于安全考虑，这里只保存密钥在 Keychain 中的引用 id，绝不保存明文。
struct AIProviderConfig: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String

    /// 形如 https://api.openai.com/v1 的基地址。
    var baseURL: String

    var model: String

    /// Keychain 条目 key。实际密钥通过 KeychainStore 读写。
    var apiKeyID: String

    /// 附加的系统提示词，用于追加仓库级约定。
    var extraInstructions: String?

    var temperature: Double

    init(
        id: UUID = UUID(),
        name: String,
        baseURL: String,
        model: String,
        apiKeyID: String,
        extraInstructions: String? = nil,
        temperature: Double = 0.2
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.model = model
        self.apiKeyID = apiKeyID
        self.extraInstructions = extraInstructions
        self.temperature = temperature
    }

    /// 归一化后的 chat completions 端点。
    var chatCompletionsURL: URL? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let base = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        return URL(string: base + "/chat/completions")
    }
}
