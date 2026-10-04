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

    /// 模型强度，映射到 OpenAI 兼容接口的 reasoning_effort（low / medium / high）。
    /// nil 表示不发送该参数，兼容不支持它的模型。
    var reasoningEffort: String?

    init(
        id: UUID = UUID(),
        name: String,
        baseURL: String,
        model: String,
        apiKeyID: String,
        extraInstructions: String? = nil,
        temperature: Double = 0.2,
        reasoningEffort: String? = "high"
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.model = model
        self.apiKeyID = apiKeyID
        self.extraInstructions = extraInstructions
        self.temperature = temperature
        self.reasoningEffort = reasoningEffort
    }

    /// 一个「模型强度」选项。
    struct Strength: Identifiable, Hashable {
        let value: String?
        let label: String
        var id: String { value ?? "default" }
    }

    /// 「模型强度」可选项，value 为空表示不发送 reasoning_effort。
    static let strengthOptions: [Strength] = [
        Strength(value: nil, label: "默认（不发送）"),
        Strength(value: "none", label: "关闭"),
        Strength(value: "minimal", label: "极低"),
        Strength(value: "low", label: "低"),
        Strength(value: "medium", label: "中"),
        Strength(value: "high", label: "高"),
        Strength(value: "xhigh", label: "极高")
    ]

    /// 把 strengthOptions 里的 value 还原成展示用文案。
    static func strengthLabel(for value: String) -> String? {
        strengthOptions.first { $0.value == value }?.label
    }

    /// 归一化后的 chat completions 端点。
    var chatCompletionsURL: URL? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let base = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        return URL(string: base + "/chat/completions")
    }
}
