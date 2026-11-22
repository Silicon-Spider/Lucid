import Foundation

/// How much Lucid edits a transcript.
public enum CleanupLevel: String, Codable, CaseIterable, Sendable {
    /// Verbatim. Only non-speech tags and spoken line-break commands are handled.
    case off
    /// Fillers, false starts, self-corrections, punctuation and lists. Every other word is kept.
    case light
    /// Light, plus tightening of wordy phrasing and grammar.
    case medium
}

/// The kind of app the text is going into. Decides tone and formatting.
public enum AppCategory: String, Codable, CaseIterable, Sendable {
    case email, chat, code, other
}
