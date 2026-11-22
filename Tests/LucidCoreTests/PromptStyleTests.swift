import LucidCore

func promptStyleTests() {
    suite("PromptStyle") {
        test("S1 uses its fixed system prompt") {
            let messages = S1Prompt.messages(for: CleanupRequest(transcript: "hello there"))
            expectEqual(messages.count, 2)
            expectEqual(messages[0], ChatMessage(role: "system", content: S1Prompt.systemPrompt))
            expectTrue(S1Prompt.systemPrompt.hasPrefix("You are a text normalizer for speech-to-text transcripts."))
            expectTrue(S1Prompt.systemPrompt.hasSuffix("output only the cleaned text."))
        }

        test("S1 puts a control line above the transcript") {
            let message = S1Prompt.messages(for: CleanupRequest(transcript: "hello there")).last
            expectEqual(message?.role, "user")
            expectEqual(
                message?.content,
                "[Styling: semi-formal] [Structure: lists] [Context: general]\nhello there"
            )
        }

        test("S1 control line follows the app category") {
            expectEqual(S1Prompt.controlLine(for: .email), "[Styling: semi-formal] [Structure: lists] [Context: email]")
            expectEqual(S1Prompt.controlLine(for: .chat), "[Styling: semi-formal] [Structure: prose] [Context: general]")
            expectEqual(S1Prompt.controlLine(for: .code), "[Styling: semi-formal] [Structure: prose] [Context: general]")
            expectEqual(S1Prompt.controlLine(for: .other), "[Styling: semi-formal] [Structure: lists] [Context: general]")
        }

        test("each style builds its own messages") {
            let request = CleanupRequest(transcript: "hello there", category: .chat)
            expectEqual(PromptStyle.s1.messages(for: request), S1Prompt.messages(for: request))
            expectEqual(PromptStyle.general.messages(for: request), PromptBuilder.messages(for: request))
        }
    }
}
