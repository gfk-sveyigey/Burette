import Foundation

// MARK: - 消息 / 工具模型

/// 模型发起的一次工具调用。
struct AIToolCall: Codable, Sendable, Hashable {
    struct Function: Codable, Sendable, Hashable {
        var name: String
        var arguments: String
    }

    var id: String
    var type: String
    var function: Function

    init(id: String, type: String = "function", function: Function) {
        self.id = id
        self.type = type
        self.function = function
    }
}

/// 一条发送给 OpenAI 兼容接口的消息。
///
/// 除普通对话外还支持工具调用：assistant 消息可以带 toolCalls，
/// 工具结果则是 role = "tool" + toolCallID。
struct AIChatMessage: Codable, Sendable {
    var role: String
    var content: String?
    var toolCalls: [AIToolCall]?
    var toolCallID: String?

    init(role: String, content: String?, toolCalls: [AIToolCall]? = nil, toolCallID: String? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
    }

    enum CodingKeys: String, CodingKey {
        case role
        case content
        case toolCalls = "tool_calls"
        case toolCallID = "tool_call_id"
    }
}

/// 供工具参数使用的动态 JSON 值。
enum JSONValue: Encodable, Sendable {
    case string(String)
    case integer(Int)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

/// 一个函数工具（OpenAI tools 数组元素）。
struct AITool: Encodable, Sendable {
    struct Function: Encodable, Sendable {
        let name: String
        let description: String
        let parameters: JSONValue
    }

    let type: String
    let function: Function

    init(name: String, description: String, parameters: JSONValue) {
        self.type = "function"
        self.function = Function(name: name, description: description, parameters: parameters)
    }
}

/// 一次模型调用的结果：文本 + 工具调用。
struct AICompletion: Sendable {
    var text: String
    var toolCalls: [AIToolCall]
    var finishReason: String?

    var isEmpty: Bool { text.isEmpty && toolCalls.isEmpty }
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
///
/// 默认使用 SSE 流式返回，支持函数工具调用（list_files / read_file / grep / apply_patch）。
struct AIClient: Sendable {
    let session: URLSession

    /// 请求超时（秒）。代码生成往往较慢，给足时间。
    private let requestTimeout: TimeInterval = 180
    private let maxAttempts = 6

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

    /// 只取文本的便捷入口（连通性检测、整文件兜底重写等场景）。
    func complete(
        config: AIProviderConfig,
        apiKey: String,
        messages: [AIChatMessage]
    ) async throws -> String {
        try await run(config: config, apiKey: apiKey, messages: messages, tools: nil, stream: true, onText: nil).text
    }

    /// 主入口：带重试的流式调用。onText 会收到「当前累计文本」，用于界面实时展示。
    func run(
        config: AIProviderConfig,
        apiKey: String,
        messages: [AIChatMessage],
        tools: [AITool]?,
        stream: Bool = true,
        onText: ((String) -> Void)? = nil
    ) async throws -> AICompletion {
        guard config.chatCompletionsURL != nil else { throw AIError.invalidEndpoint }
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIError.missingAPIKey
        }

        let promptChars = messages.reduce(0) { $0 + ($1.content?.count ?? 0) }
        var lastError: Error = AIError.emptyResponse

        for attempt in 1...maxAttempts {
            let startedAt = Date()
            do {
                let completion = try await perform(
                    config: config,
                    apiKey: apiKey,
                    messages: messages,
                    tools: tools,
                    stream: stream,
                    onText: onText
                )
                let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
                Log.info("AI 调用成功：\(config.model)，提示 \(promptChars) 字，返回 \(completion.text.count) 字 / \(completion.toolCalls.count) 个工具调用，用时 \(elapsed) ms（第 \(attempt) 次）", .ai)
                return completion
            } catch {
                lastError = error
                let retryable = Self.isRetryable(error)
                Log.warning("AI 调用失败（第 \(attempt)/\(maxAttempts) 次）：\(error.localizedDescription)\(retryable ? "，将重试" : "")", .ai)
                guard retryable, attempt < maxAttempts else { throw error }
                // 指数退避，退到后台 / 网络抖动时给足恢复时间。
                let seconds = min(20.0, pow(1.6, Double(attempt)))
                Log.debug("等待 \(String(format: "%.1f", seconds)) 秒后重试", .ai)
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                onText?("")
            }
        }
        throw lastError
    }

    // MARK: - 单次请求

    private func perform(
        config: AIProviderConfig,
        apiKey: String,
        messages: [AIChatMessage],
        tools: [AITool]?,
        stream: Bool,
        onText: ((String) -> Void)?
    ) async throws -> AICompletion {
        guard let url = config.chatCompletionsURL else { throw AIError.invalidEndpoint }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if stream { request.setValue("text/event-stream", forHTTPHeaderField: "Accept") }
        request.httpBody = try JSONEncoder().encode(
            RequestBody(
                model: config.model,
                messages: messages,
                temperature: config.temperature,
                stream: stream,
                reasoningEffort: config.reasoningEffort,
                tools: tools
            )
        )

        Log.debug("AI 请求：\(config.model) → \(url.absoluteString)，\(messages.count) 条消息 / \(request.httpBody?.count ?? 0) 字节\(tools == nil ? "" : "，\(tools?.count ?? 0) 个工具")", .ai)

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AIError.http(status: -1, message: "无效的服务器响应。")
        }
        guard (200..<300).contains(http.statusCode) else {
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > 8192 { break }
            }
            let body = String(data: data, encoding: .utf8).map { String($0.prefix(300)) } ?? ""
            throw AIError.http(status: http.statusCode, message: body)
        }

        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if !contentType.contains("text/event-stream") {
            // 服务端忽略了 stream 参数，按普通 JSON 整体响应处理。
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            return try completion(fromJSON: data, onText: onText)
        }

        var text = ""
        var toolCalls: [Int: AIToolCall] = [:]
        var finishReason: String?

        for try await line in bytes.lines {
            try Task.checkCancellation()
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("data:") else { continue }
            let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload.isEmpty { continue }
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let chunk = try? JSONDecoder().decode(StreamChunk.self, from: data),
                  let choice = chunk.choices.first else { continue }

            if let reason = choice.finishReason { finishReason = reason }
            guard let delta = choice.delta else { continue }

            if let piece = delta.content, !piece.isEmpty {
                text += piece
                onText?(text)
            }

            for call in delta.toolCalls ?? [] {
                let index = call.index ?? toolCalls.count
                var existing = toolCalls[index] ?? AIToolCall(id: call.id ?? "", function: .init(name: "", arguments: ""))
                if let id = call.id, !id.isEmpty { existing.id = id }
                if let type = call.type, !type.isEmpty { existing.type = type }
                if let function = call.function {
                    if let name = function.name, !name.isEmpty { existing.function.name = name }
                    if let arguments = function.arguments, !arguments.isEmpty { existing.function.arguments += arguments }
                }
                toolCalls[index] = existing
            }
        }

        let calls = toolCalls.keys.sorted().compactMap { toolCalls[$0] }.filter { !$0.function.name.isEmpty }
        if text.isEmpty && calls.isEmpty { throw AIError.emptyResponse }
        return AICompletion(text: text, toolCalls: calls, finishReason: finishReason)
    }

    private func completion(fromJSON data: Data, onText: ((String) -> Void)?) throws -> AICompletion {
        let decoded = try decode(Response.self, from: data)
        guard let choice = decoded.choices.first, let message = choice.message else {
            throw AIError.emptyResponse
        }
        let text = message.content ?? ""
        let calls = message.toolCalls ?? []
        if text.isEmpty && calls.isEmpty { throw AIError.emptyResponse }
        if !text.isEmpty { onText?(text) }
        return AICompletion(text: text, toolCalls: calls, finishReason: choice.finishReason)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw AIError.decoding(String(describing: error))
        }
    }

    /// 判断错误是否值得重试（锁屏 / 切网导致的临时失败都会走到这里）。
    static func isRetryable(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .networkConnectionLost, .notConnectedToInternet,
                 .cannotConnectToHost, .dnsLookupFailed, .badServerResponse,
                 .cannotFindHost, .resourceUnavailable, .dataNotAllowed,
                 .internationalRoamingOff, .callIsActive, .cannotLoadFromNetwork,
                 .secureConnectionFailed:
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

    /// 接口是否明确表示不支持工具 / 函数调用（用于回退到文本协议）。
    static func isToolUnsupported(_ error: Error) -> Bool {
        guard case AIError.http(let status, let message) = error else { return false }
        guard status == 400 || status == 404 || status == 422 || status == 501 else { return false }
        let lower = message.lowercased()
        return lower.contains("tool") || lower.contains("function") || lower.contains("unsupported")
            || lower.contains("not support") || lower.contains("unknown parameter")
    }

    // MARK: - 请求 / 响应模型

    private struct RequestBody: Encodable {
        let model: String
        let messages: [AIChatMessage]
        let temperature: Double
        let stream: Bool
        /// 模型强度；为 nil 时不会出现在请求体里（兼容不支持该参数的模型）。
        var reasoningEffort: String?
        /// 工具定义；为 nil 时不会出现在请求体里。
        var tools: [AITool]?

        enum CodingKeys: String, CodingKey {
            case model, messages, temperature, stream
            case reasoningEffort = "reasoning_effort"
            case tools
        }
    }

    private struct StreamChunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable {
                struct ToolCall: Decodable {
                    struct Function: Decodable {
                        let name: String?
                        let arguments: String?
                    }
                    let index: Int?
                    let id: String?
                    let type: String?
                    let function: Function?
                }
                let role: String?
                let content: String?
                let toolCalls: [ToolCall]?

                enum CodingKeys: String, CodingKey {
                    case role, content
                    case toolCalls = "tool_calls"
                }
            }
            let delta: Delta?
            let finishReason: String?

            enum CodingKeys: String, CodingKey {
                case delta
                case finishReason = "finish_reason"
            }
        }
        let choices: [Choice]
    }

    private struct Response: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let role: String?
                let content: String?
                let toolCalls: [AIToolCall]?

                enum CodingKeys: String, CodingKey {
                    case role, content
                    case toolCalls = "tool_calls"
                }
            }
            let message: Message?
            let finishReason: String?

            enum CodingKeys: String, CodingKey {
                case message
                case finishReason = "finish_reason"
            }
        }
        let choices: [Choice]
    }
}
