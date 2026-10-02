import Foundation

/// 与 OpenAI 兼容接口对应的消息体。
struct AIChatMessage: Codable, Sendable {
    let role: String
    let content: String
}

enum AIError: Error, LocalizedError {
    case invalidEndpoint
    case missingAPIKey
    case http(status: Int, message: String)
    case emptyResponse
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "API 地址无效，请检查 Base URL。"
        case .missingAPIKey:
            return "缺少 API Key。"
        case .http(let status, let message):
            return "AI 接口返回错误（HTTP \(status)）：\(message)"
        case .emptyResponse:
            return "AI 没有返回任何内容。"
        case .decoding(let message):
            return "解析 AI 响应失败：\(message)"
        }
    }
}

/// 调用 OpenAI 兼容的 chat completions 接口。
struct AIClient: Sendable {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func complete(
        config: AIProviderConfig,
        apiKey: String,
        messages: [AIChatMessage]
    ) async throws -> String {
        guard let url = config.chatCompletionsURL else { throw AIError.invalidEndpoint }
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIError.missingAPIKey
        }

        struct RequestBody: Encodable {
            let model: String
            let messages: [AIChatMessage]
            let temperature: Double
            let stream: Bool
        }

        struct Response: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable {
                    let role: String?
                    let content: String?
                }
                let message: Message
                let finishReason: String?
            }
            let choices: [Choice]
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(
            RequestBody(
                model: config.model,
                messages: messages,
                temperature: config.temperature,
                stream: false
            )
        )

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AIError.http(status: -1, message: "无效的服务器响应。")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AIError.http(
                status: http.statusCode,
                message: String(data: data, encoding: .utf8) ?? ""
            )
        }

        let decoded: Response
        do {
            decoded = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw AIError.decoding(String(describing: error))
        }

        guard let content = decoded.choices.first?.message.content, !content.isEmpty else {
            throw AIError.emptyResponse
        }
        return content
    }
}
