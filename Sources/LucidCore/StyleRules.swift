import Foundation

/// Stage 5 of cleanup: small deterministic touches that depend on where the text is going.
public enum StyleRules {
    public static func apply(_ text: String, category: AppCategory) -> String {
        guard category == .chat else { return text }
        return droppingFinalStop(text)
    }

    /// A sentence end that has more text after it.
    private static let innerSentenceEnd = TextUtil.regex(#"[.!?…]["”’)]*\s+\S"#)

    /// A one-sentence chat message reads better without its closing full stop.
    static func droppingFinalStop(_ text: String) -> String {
        guard text.hasSuffix("."), !text.hasSuffix(".."), !text.contains("\n") else { return text }
        if innerSentenceEnd.firstMatch(in: text, range: TextUtil.fullRange(text)) != nil { return text }
        // "p.m." and "e.g." end in a full stop that belongs to the word.
        let lastWord = text.split(separator: " ").last.map(String.init) ?? text
        if lastWord.dropLast().contains(".") { return text }
        return String(text.dropLast())
    }
}
