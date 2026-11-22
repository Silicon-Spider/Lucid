import Foundation

/// Decides how dictated text joins what is already in the document.
///
/// `before` is the few characters just before the cursor, or nil when the app being
/// dictated into does not reveal them. An empty string means the start of the document.
public enum InsertionPlanner {
    /// True when the text before the cursor stops part-way through a sentence, so the
    /// dictated text should carry on in lower case.
    public static func isMidSentence(before: String?) -> Bool {
        guard let before, let last = before.last else { return false }
        if last.isNewline { return false }
        guard let significant = before.last(where: { !$0.isWhitespace }) else { return false }
        return !".!?…".contains(significant)
    }

    /// The text to insert. A space is added in front when the cursor sits directly after a
    /// word or punctuation, so the two do not run together.
    public static func textToInsert(_ text: String, before: String?) -> String {
        guard let first = text.first, let last = before?.last else { return text }
        if last.isWhitespace { return text }
        // An opening bracket or quote, a slash or a hyphen is followed directly by text.
        if "([{\"'“‘/-".contains(last) { return text }
        if first.isNewline { return text }
        if ".,;:!?)]}".contains(first) { return text }
        return " " + text
    }
}
