import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LucidCore

/// Speech recognition through a local `whisper-server`.
public struct WhisperClient: Transcriber {
    public let baseURL: URL

    public init(baseURL: URL) {
        self.baseURL = baseURL
    }

    public func transcribe(wav: Data, prompt: String) async throws -> String {
        // An unreadable header is treated as a long clip, which selects the safe full window.
        let seconds = WAV.seconds(of: wav) ?? 30
        var fields = [
            ("response_format", "json"),
            ("temperature", "0.0"),
            ("audio_ctx", String(WhisperWindow.audioContext(forSeconds: seconds))),
        ]
        if !prompt.isEmpty { fields.append(("prompt", prompt)) }

        let boundary = "lucid-\(UUID().uuidString)"
        var request = URLRequest(url: baseURL.appendingPathComponent("inference"))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.multipartBody(fields: fields, fileName: "audio.wav", file: wav, boundary: boundary)

        let (data, response) = try await LocalHTTP.session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw EngineError.badResponse("the speech engine answered with HTTP \(code)")
        }
        return try Self.parseTranscript(data)
    }

    public static func multipartBody(
        fields: [(String, String)],
        fileName: String,
        file: Data,
        boundary: String
    ) -> Data {
        var body = Data()
        for (name, value) in fields {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        body.append(Data((
            "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n"
            + "Content-Type: audio/wav\r\n\r\n"
        ).utf8))
        body.append(file)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }

    private struct Reply: Decodable {
        let text: String?
    }

    /// Reads the transcript from the server's JSON reply. The server puts a line break between
    /// 30-second windows; those are not paragraph breaks, so they become spaces.
    public static func parseTranscript(_ data: Data) throws -> String {
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data), let text = reply.text else {
            throw EngineError.badResponse("the speech engine sent a reply with no text")
        }
        return text
            .split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
