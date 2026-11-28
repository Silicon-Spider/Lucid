import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LucidCore

/// Transcript cleanup through a local `llama-server`.
public struct LlamaClient: TextCleaner {
    public let baseURL: URL
    public let style: PromptStyle

    public init(baseURL: URL, style: PromptStyle) {
        self.baseURL = baseURL
        self.style = style
    }

    public func clean(_ request: CleanupRequest, timeout: TimeInterval) async throws -> String {
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("v1/chat/completions"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = timeout
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try Self.requestBody(for: request, style: style)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await LocalHTTP.session.data(for: urlRequest)
        } catch let error as URLError where error.code == .timedOut {
            throw CleanerError.timeout
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw CleanerError.failed("the cleanup engine answered with HTTP \(code)")
        }
        return try Self.parseReply(data)
    }

    private struct ChatRequest: Encodable {
        let messages: [ChatMessage]
        let temperature: Double
        let max_tokens: Int
        let cache_prompt: Bool
    }

    private struct ChatReply: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String?
            }

            let message: Message
            let finish_reason: String?
        }

        let choices: [Choice]
    }

    public static func requestBody(for request: CleanupRequest, style: PromptStyle) throws -> Data {
        let words = request.transcript.split(whereSeparator: { $0 == " " || $0.isNewline }).count
        let body = ChatRequest(
            messages: style.messages(for: request),
            temperature: 0,
            max_tokens: PromptBuilder.maxOutputTokens(forWordCount: words),
            cache_prompt: true
        )
        return try JSONEncoder().encode(body)
    }

    public static func parseReply(_ data: Data) throws -> String {
        guard let reply = try? JSONDecoder().decode(ChatReply.self, from: data),
              let choice = reply.choices.first else {
            throw CleanerError.failed("the cleanup engine sent a reply that could not be read")
        }
        // A reply cut off by the token limit would be inserted half-finished.
        if choice.finish_reason == "length" {
            throw CleanerError.failed("the cleanup engine's reply was cut off")
        }
        return choice.message.content ?? ""
    }
}
