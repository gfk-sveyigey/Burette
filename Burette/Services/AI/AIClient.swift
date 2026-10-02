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

    /// 请求超时（秒）。代码生成往往较慢，给足时间。
    private let requestTimeout: TimeInterval = 180
    private let maxAttempts = 3

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 180
            configuration.timeoutIntervalForResource = 900
            configuration.waitsForConnectivity = true
            self.session = URLSession(configuration: configuration)
        }
    }

    func complete(
        config: AIProviderConfig,
        apiKey: String,
        messages: [AIChatMessage]
    ) async throws -> String {
        guard config.chatCompletionsURL != nil else { throw AIError.invalidEndpoint }
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIError.missingAPIKey
        }

        let promptChars = messages.reduce(0) { $0 + $1.content.count }
        var lastError: Error = AIError.emptyResponse

        for attempt in 1...maxAttempts {
            let startedAt = Date()
            do {
                let reply = try await perform(config: config, apiKey: apiKey, messages: messages)
                let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
                Log.info("AI 调用成功：\(config.model)，提示 \(promptChars) 字，返回 \(reply.count) 字，用时 \(elapsed) ms（第 \(attempt) 次）", .ai)
                return reply
            } catch {
                lastError = error
                let retryable = Self.isRetryable(error)
                Log.warning("AI 调用失败（第 \(attempt)/\(maxAttempts) 次）：\(error.localizedDescription)\(retryable ? "，将重试" : "")", .ai)
                guard retryable, attempt < maxAttempts else { throw error }
                let delay = UInt64(attempt) * 1_000_000_000
                try? await Task.sleep(nanoseconds: delay)
            }
        }
        throw lastError
    }

    // MARK: - 单次请求

    private func perform(
        config: AIProviderConfig,
        apiKey: String,
        messages: [AIChatMessage]
    ) async throws -> String {
        guard let url = config.chatCompletionsURL else { throw AIError.invalidEndpoint }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
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

        Log.debug("AI 请求：\(config.model) → \(url.absoluteString)，\(messages.count) 条消息 / \(request.httpBody?.count ?? 0) 字节", .ai)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AIError.http(status: -1, message: "无效的服务器响应。")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8).map { String($0.prefix(300)) } ?? ""
            throw AIError.http(status: http.statusCode, message: body)
        }

        let decoded = try decode(Response.self, from: data)
        guard let content = decoded.choices.first?.message.content, !content.isEmpty else {
            throw AIError.emptyResponse
        }
        return content
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw AIError.decoding(String(describing: error))
        }
    }

    private static func isRetryable(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .networkConnectionLost, .notConnectedToInternet,
                 .cannotConnectToHost, .dnsLookupFailed, .badServerResponse,
                 .cannotFindHost, .resourceUnavailable:
                return true
            default:
                return false
            }
        }
        if case AIError.http(let status, _) = error {
            return status == 429 || (500..<600).contains(status)
        }
        return false
    }

    // MARK: - 请求 / 响应模型

    private struct RequestBody: Encodable {
        let model: String
        let messages: [AIChatMessage]
        let temperature: Double
        let stream: Bool
    }

    private struct Response: Decodable {
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
}
