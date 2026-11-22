import Foundation
import LucidCore
import LucidEngines

func clientTests() {
    suite("Clients") {
        test("builds a multipart body") {
            let body = WhisperClient.multipartBody(
                fields: [("temperature", "0.0"), ("prompt", "Glossary: Lucid.")],
                fileName: "audio.wav",
                file: Data([1, 2, 3]),
                boundary: "B"
            )
            let head = "--B\r\nContent-Disposition: form-data; name=\"temperature\"\r\n\r\n0.0\r\n"
                + "--B\r\nContent-Disposition: form-data; name=\"prompt\"\r\n\r\nGlossary: Lucid.\r\n"
                + "--B\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n"
                + "Content-Type: audio/wav\r\n\r\n"
            expectEqual(body, Data(head.utf8) + Data([1, 2, 3]) + Data("\r\n--B--\r\n".utf8))
        }

        test("reads a transcript and joins window breaks") {
            let reply = Data(#"{"text": " First part.\n Second part.\n"}"#.utf8)
            expectEqual(try WhisperClient.parseTranscript(reply), "First part. Second part.")
        }

        test("rejects a speech reply with no text") {
            expectThrows { try WhisperClient.parseTranscript(Data(#"{"error": "bad audio"}"#.utf8)) }
        }

        test("builds a chat request") {
            let request = CleanupRequest(transcript: "one two three", category: .chat)
            let data = try LlamaClient.requestBody(for: request, style: .s1)
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            expectEqual(object?["temperature"] as? Int, 0)
            expectEqual(object?["max_tokens"] as? Int, 54)
            expectEqual(object?["cache_prompt"] as? Bool, true)
            let messages = object?["messages"] as? [[String: String]]
            expectEqual(messages?.count, 2)
            expectEqual(
                messages?.last?["content"],
                "[Styling: semi-formal] [Structure: prose] [Context: general]\none two three"
            )
        }

        test("reads a chat reply") {
            let reply = Data(
                #"{"choices": [{"finish_reason": "stop", "message": {"role": "assistant", "content": "At 3."}}]}"#.utf8
            )
            expectEqual(try LlamaClient.parseReply(reply), "At 3.")
        }

        test("rejects a cut-off or unreadable chat reply") {
            let cutOff = #"{"choices": [{"finish_reason": "length", "message": {"role": "assistant", "content": "At"}}]}"#
            expectThrows { try LlamaClient.parseReply(Data(cutOff.utf8)) }
            expectThrows { try LlamaClient.parseReply(Data(#"{"choices": []}"#.utf8)) }
            expectThrows { try LlamaClient.parseReply(Data("not json".utf8)) }
        }
    }
}
