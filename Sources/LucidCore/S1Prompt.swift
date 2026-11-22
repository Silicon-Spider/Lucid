import Foundation

/// Which prompt format a cleanup model expects.
public enum PromptStyle: String, Codable, CaseIterable, Sendable {
    /// S1-mini by Superwhisper: a fixed system prompt and a control line.
    case s1
    /// Any general instruction-following model: Lucid's own prompt from `PromptBuilder`.
    case general

    public func messages(for request: CleanupRequest) -> [ChatMessage] {
        switch self {
        case .s1: return S1Prompt.messages(for: request)
        case .general: return PromptBuilder.messages(for: request)
        }
    }
}

/// The input format for S1-mini by Superwhisper, a small model trained to clean speech transcripts.
///
/// The system prompt and the control line are part of what the model was trained on.
/// Changing their wording, or sending values outside the trained sets, makes it produce garbage.
public enum S1Prompt {
    public static let systemPrompt = "You are a text normalizer for speech-to-text transcripts. "
        + "The input begins with a control line specifying the styling, structure, and context settings; "
        + "clean the transcript to match those settings and output only the cleaned text."

    /// The trained values are: Styling casual, semi-casual, semi-formal or formal;
    /// Structure prose or lists; Context general or email.
    public static func controlLine(for category: AppCategory) -> String {
        switch category {
        case .email: return "[Styling: semi-formal] [Structure: lists] [Context: email]"
        case .chat, .code: return "[Styling: semi-formal] [Structure: prose] [Context: general]"
        case .other: return "[Styling: semi-formal] [Structure: lists] [Context: general]"
        }
    }

    public static func messages(for request: CleanupRequest) -> [ChatMessage] {
        [
            ChatMessage(role: "system", content: systemPrompt),
            ChatMessage(role: "user", content: controlLine(for: request.category) + "\n" + request.transcript),
        ]
    }
}
