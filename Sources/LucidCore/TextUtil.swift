import Foundation

/// Regex and string helpers shared by the cleanup stages.
enum TextUtil {
    /// Compiles a pattern that is a constant in the source. A failure is a programming error.
    static func regex(_ pattern: String, caseInsensitive: Bool = true) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
        } catch {
            preconditionFailure("Invalid built-in pattern \(pattern): \(error)")
        }
    }

    static func fullRange(_ text: String) -> NSRange {
        NSRange(location: 0, length: (text as NSString).length)
    }

    /// Replaces every match with a regex template such as "$1".
    static func replace(_ re: NSRegularExpression, in text: String, with template: String) -> String {
        re.stringByReplacingMatches(in: text, range: fullRange(text), withTemplate: template)
    }

    /// Replaces matches one at a time, last to first, so earlier text is still original
    /// when each match is examined. `transform` returns the replacement and whether the
    /// first letter after it should be capitalised, or nil to leave the match alone.
    static func replace(
        _ re: NSRegularExpression,
        in text: String,
        _ transform: (NSTextCheckingResult, NSString) -> (replacement: String, capitaliseNext: Bool)?
    ) -> String {
        let source = text as NSString
        let result = NSMutableString(string: text)
        for match in re.matches(in: text, range: fullRange(text)).reversed() {
            guard let edit = transform(match, source) else { continue }
            result.replaceCharacters(in: match.range, with: edit.replacement)
            if edit.capitaliseNext {
                capitaliseWord(in: result, from: match.range.location + (edit.replacement as NSString).length)
            }
        }
        return result as String
    }

    /// Upper-cases the first letter at or after `index`, skipping spaces and line breaks.
    /// A word with an internal capital, such as "iPhone", is left alone.
    static func capitaliseWord(in text: NSMutableString, from index: Int) {
        var start = index
        while start < text.length {
            let unit = text.character(at: start)
            if unit == 0x20 || unit == 0x09 || unit == 0x0A { start += 1 } else { break }
        }
        guard start < text.length else { return }

        let firstRange = text.rangeOfComposedCharacterSequence(at: start)
        let first = text.substring(with: firstRange)
        guard first.rangeOfCharacter(from: .lowercaseLetters) != nil else { return }

        let restStart = firstRange.location + firstRange.length
        var end = restStart
        while end < text.length,
              let scalar = Unicode.Scalar(text.character(at: end)),
              CharacterSet.letters.contains(scalar) {
            end += 1
        }
        let rest = text.substring(with: NSRange(location: restStart, length: end - restStart))
        if rest.rangeOfCharacter(from: .uppercaseLetters) != nil { return }

        text.replaceCharacters(in: firstRange, with: first.uppercased())
    }

    /// True when the text before `index` ends a sentence, or when nothing comes before it.
    static func isSentenceStart(_ text: NSString, before index: Int) -> Bool {
        // Space, tab, and closing quotes and brackets may sit between a full stop and the next word.
        let skippable: Set<unichar> = [0x20, 0x09, 0x22, 0x27, 0x29, 0x5D, 0x201D, 0x2019]
        // Full stop, exclamation mark, question mark, ellipsis, line break.
        let enders: Set<unichar> = [0x2E, 0x21, 0x3F, 0x2026, 0x0A]
        var position = index - 1
        while position >= 0, skippable.contains(text.character(at: position)) { position -= 1 }
        if position < 0 { return true }
        return enders.contains(text.character(at: position))
    }
}
