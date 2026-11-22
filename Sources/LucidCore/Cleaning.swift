import Foundation

/// One chat message sent to the cleanup model.
public struct ChatMessage: Codable, Equatable, Sendable {
    public var role: String
    public var content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

/// Everything the cleanup model needs for one dictation.
public struct CleanupRequest: Equatable, Sendable {
    /// The transcript after the rules stage.
    public var transcript: String
    public var level: CleanupLevel
    public var category: AppCategory
    /// Words to spell exactly as written.
    public var terms: [String]
    /// True when the text will be inserted in the middle of an existing sentence.
    public var midSentence: Bool

    public init(
        transcript: String,
        level: CleanupLevel = .light,
        category: AppCategory = .other,
        terms: [String] = [],
        midSentence: Bool = false
    ) {
        self.transcript = transcript
        self.level = level
        self.category = category
        self.terms = terms
        self.midSentence = midSentence
    }
}

public enum CleanerError: Error, Equatable {
    /// The model did not answer within the time allowed.
    case timeout
    case failed(String)
}

/// Stage 2 of cleanup. Implemented by the llama.cpp client, and by fakes in tests.
public protocol TextCleaner: Sendable {
    /// Returns the model's raw reply. Throws `CleanerError.timeout` when `timeout` elapses.
    func clean(_ request: CleanupRequest, timeout: TimeInterval) async throws -> String
}

/// Speech recognition. Implemented by the whisper.cpp client.
public protocol Transcriber: Sendable {
    /// `prompt` is a short glossary that biases spelling. It may be empty.
    func transcribe(wav: Data, prompt: String) async throws -> String
}
