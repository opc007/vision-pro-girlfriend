import Foundation

enum DeepSeekError: LocalizedError {
    case missingAPIKey
    case badURL
    case http(status: Int, body: String)
    case streamEndedUnexpectedly

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "没有读到 DEEPSEEK_API_KEY 环境变量。"
        case .badURL:
            return "DEEPSEEK_BASE_URL 拼出来的地址不合法。"
        case let .http(status, body):
            return "DeepSeek 返回 HTTP \(status)：\(body.prefix(300))"
        case .streamEndedUnexpectedly:
            return "DeepSeek 的流式连接提前断开了。"
        }
    }
}

/// DeepSeek Chat Completions，SSE 流式。
/// 逐 token 回调，文本同时喂给 UI 和 TTS。
struct DeepSeekClient {

    struct Message: Encodable {
        let role: String
        let content: String
    }

    private struct RequestBody: Encodable {
        let model: String
        let messages: [Message]
        let stream: Bool
        let temperature: Double
        let maxTokens: Int

        enum CodingKeys: String, CodingKey {
            case model
            case messages
            case stream
            case temperature
            case maxTokens = "max_tokens"
        }
    }

    private struct StreamChunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable {
                let content: String?
            }
            let delta: Delta?
        }
        let choices: [Choice]?
    }

    let config: AppConfig
    var session: URLSession = .shared

    init(config: AppConfig) {
        self.config = config
    }

    /// 发起一次对话，逐段吐出增量文本。
    /// - Parameter onDelta: 每收到一个增量片段调用一次，顺序与流一致。
    func stream(messages: [Message], onDelta: @escaping (String) -> Void) async throws {
        guard !config.deepSeekAPIKey.isEmpty else { throw DeepSeekError.missingAPIKey }
        guard let url = config.deepSeekChatCompletionsURL else { throw DeepSeekError.badURL }

        let body = RequestBody(
            model: config.deepSeekModel,
            messages: messages,
            stream: true,
            temperature: 0.7,
            maxTokens: 512
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.deepSeekAPIKey)", forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(body)
        request.timeoutInterval = 60

        let (bytes, response) = try await session.bytes(for: request)

        guard let http = response as? HTTPURLResponse else { throw DeepSeekError.streamEndedUnexpectedly }
        guard http.statusCode == 200 else {
            var text = ""
            for try await line in bytes.lines {
                text += line
                if text.count > 500 { break }
            }
            throw DeepSeekError.http(status: http.statusCode, body: text)
        }

        var sawAnyChunk = false

        for try await line in bytes.lines {
            // SSE 每行形如 `data: {...}`，结束标记是 `data: [DONE]`
            guard line.hasPrefix("data:") else { continue }
            let payload = line
                .dropFirst("data:".count)
                .trimmingCharacters(in: .whitespaces)
            guard !payload.isEmpty else { continue }
            if payload == "[DONE]" { break }

            guard let data = payload.data(using: .utf8),
                  let chunk = try? JSONDecoder().decode(StreamChunk.self, from: data),
                  let content = chunk.choices?.first?.delta?.content,
                  !content.isEmpty
            else { continue }

            sawAnyChunk = true
            onDelta(content)
        }

        if !sawAnyChunk { throw DeepSeekError.streamEndedUnexpectedly }
    }
}
