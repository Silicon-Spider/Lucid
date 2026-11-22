import Foundation

/// Stage 5 of cleanup: small deterministic touches that depend on where the text is going.
public enum StyleRules {
    public static func apply(_ text: String, category: AppCategory) -> String {
        guard category == .chat else { return text }
        return droppingFinalStop(text)
    }

    /// A sentence end that has more text after it.
    private static let innerSentenceEnd = TextUtil.regex(#"[.!?…]["”’)]*\s+\S"#)

    /// A short chat message, one or two sentences, reads better without its closing full stop.
    static func droppingFinalStop(_ text: String) -> String {
        guard text.hasSuffix("."), !text.hasSuffix(".."), !text.contains("\n") else { return text }
        if innerSentenceEnd.numberOfMatches(in: text, range: TextUtil.fullRange(text)) > 1 { return text }
        // "p.m." and "e.g." end in a full stop that belongs to the word.
        let lastWord = text.split(separator: " ").last.map(String.init) ?? text
        if lastWord.dropLast().contains(".") { return text }
        return String(text.dropLast())
    }

    /// Words that are safe to lower-case at the start of a continuation. No name is in
    /// this list, so "John agreed" keeps its capital.
    private static let continuationWords: Set<String> = [
        "a", "an", "the", "and", "but", "or", "so", "then", "also", "because", "which", "that",
        "when", "while", "if", "as", "to", "of", "in", "on", "at", "for", "with", "from", "by",
        "about", "we", "you", "they", "he", "she", "it", "this", "these", "those", "there", "here",
        "my", "your", "our", "their", "is", "are", "was", "were", "will", "can", "should", "would",
        "could", "do", "does", "did", "have", "has", "had", "not", "just", "please", "let's",
        "what", "where", "how", "why", "who", "however", "maybe",
    ]

    /// When text is inserted in the middle of a sentence, its first word should not be capitalised.
    public static func continuingSentence(_ text: String) -> String {
        guard let first = text.first, first.isUppercase else { return text }
        let word = text.prefix(while: { $0.isLetter || $0 == "'" || $0 == "’" })
            .lowercased()
            .replacingOccurrences(of: "’", with: "'")
        guard continuationWords.contains(word) else { return text }
        return first.lowercased() + text.dropFirst()
    }
}
