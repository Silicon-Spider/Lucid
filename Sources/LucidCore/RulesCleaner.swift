import Foundation

/// Stage 1 of cleanup: instant, deterministic edits that need no understanding.
public enum RulesCleaner {
    public static func clean(_ text: String, level: CleanupLevel) -> String {
        var result = removeTags(text)
        result = applyLineCommands(result)
        if level != .off {
            result = removeFillers(result)
            result = collapseRepeats(result)
        }
        return tidy(result)
    }

    // MARK: Non-speech tags

    private static let bracketTag = TextUtil.regex(#"\[[ \t]*[\p{L}_ ]{2,30}[ \t]*\]"#)
    private static let parenTag = TextUtil.regex(
        #"\((?:blank[ _]audio|no audio|silence|music|music playing|inaudible|laughs|laughter|laughing|applause|sighs|coughs|coughing|clears throat|noise|background noise)\)"#
    )

    static func removeTags(_ text: String) -> String {
        let withoutBrackets = TextUtil.replace(bracketTag, in: text, with: " ")
        return TextUtil.replace(parenTag, in: withoutBrackets, with: " ")
    }

    // MARK: Spoken line commands

    /// "new line" or "new paragraph" counts as a command only when it is its own clause:
    /// at the start, or after punctuation, and followed by punctuation or the end.
    private static let lineCommand = TextUtil.regex(
        #"(^|\n|[.!?…,;:])[ \t]*(?:(?:start|begin)[ \t]+(?:a[ \t]+)?)?new[ \t]*(paragraph|line)[ \t]*(?:[.!?…,;:]+|(?=\n)|\z)[ \t]*"#
    )

    static func applyLineCommands(_ text: String) -> String {
        var current = text
        // Back-to-back commands share punctuation, so one pass can miss the second. Repeat until stable.
        for _ in 0..<10 {
            let next = TextUtil.replace(lineCommand, in: current) { match, source in
                let before = source.substring(with: match.range(at: 1))
                let isParagraph = source.substring(with: match.range(at: 2)).lowercased() == "paragraph"
                return (before + (isParagraph ? "\n\n" : "\n"), true)
            }
            if next == current { break }
            current = next
        }
        return current
    }

    // MARK: Fillers

    private static let filler = "(?:u+m+|u+h+m*|e+r+m+|er|h+m+)"
    /// A character that would make the match part of a longer word, such as "umbrella" or "uh-huh".
    private static let wordCharacter = #"[\p{L}\p{N}'’-]"#
    private static let fillerRun = TextUtil.regex(
        "([,;]?[ \\t]*)(?<!\(wordCharacter))(\(filler)(?:[,;]?[ \\t]+\(filler))*)(?!\(wordCharacter))([ \\t]*(?:[,;]|[.!?…]+))?"
    )

    static func removeFillers(_ text: String) -> String {
        TextUtil.replace(fillerRun, in: text) { match, source in
            let lead = source.substring(with: match.range(at: 1))
            let run = source.substring(with: match.range(at: 2))
            let trailRange = match.range(at: 3)
            let trail = trailRange.location == NSNotFound
                ? ""
                : source.substring(with: trailRange).trimmingCharacters(in: .whitespaces)

            // "ER", "UM" and "UH" in capitals are abbreviations, not hesitations.
            if run.count > 1, run == run.uppercased() { return nil }

            let leadHasComma = lead.contains(",") || lead.contains(";")
            let opensSentence = !leadHasComma && TextUtil.isSentenceStart(source, before: match.range.location)
            if opensSentence {
                // "Um, so..." and "Um. So..." both lose the filler and its punctuation.
                return (lead, true)
            }

            let endsSentence = trail.first.map { ".!?…".contains($0) } ?? false
            if endsSentence {
                // "Well, um." keeps the full stop and loses the comma.
                return (trail, false)
            }
            return (" ", false)
        }
    }

    // MARK: Repeated words

    /// Only words that are almost never doubled on purpose. "had had" and "that that" are real English.
    private static let repeatable = [
        "a", "an", "the", "i", "we", "you", "he", "she", "it", "they", "to", "of", "in", "on", "at", "for",
        "and", "but", "or", "so", "my", "your", "our", "this", "if", "with", "was", "are", "can", "will",
        "would", "should", "could", "just", "because", "when", "what", "where",
    ]
    private static let repeated = TextUtil.regex(
        "(?<!\(wordCharacter))(\(repeatable.joined(separator: "|")))((?:,?[ \\t]+\\1(?![\\p{L}\\p{N}-]))+)"
    )

    static func collapseRepeats(_ text: String) -> String {
        TextUtil.replace(repeated, in: text, with: "$1")
    }

    // MARK: Tidying

    private static let spaces = TextUtil.regex(#"[ \t]+"#)
    private static let spaceBeforePunctuation = TextUtil.regex(#" +([,.;:!?…]+)(?=\s|\z|["”’])"#)
    private static let doubledCommas = TextUtil.regex(#",(?: *,)+"#)
    private static let spaceAroundBreak = TextUtil.regex(#" *\n *"#)
    private static let extraBreaks = TextUtil.regex(#"\n{3,}"#)
    private static let leadingJunk = TextUtil.regex(#"\A[,;: ]+"#)
    private static let trailingSpaces = TextUtil.regex(#" +\z"#)

    static func tidy(_ text: String) -> String {
        guard text.rangeOfCharacter(from: .alphanumerics) != nil else { return "" }
        var result = TextUtil.replace(spaces, in: text, with: " ")
        result = TextUtil.replace(spaceBeforePunctuation, in: result, with: "$1")
        result = TextUtil.replace(doubledCommas, in: result, with: ",")
        result = TextUtil.replace(spaceAroundBreak, in: result, with: "\n")
        result = TextUtil.replace(extraBreaks, in: result, with: "\n\n")
        result = TextUtil.replace(leadingJunk, in: result, with: "")
        result = TextUtil.replace(trailingSpaces, in: result, with: "")
        return result
    }
}
