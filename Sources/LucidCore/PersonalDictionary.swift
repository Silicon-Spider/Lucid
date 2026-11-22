import Foundation

/// One "misheard → correct" pair.
public struct Replacement: Codable, Equatable, Sendable {
    public var from: String
    public var to: String

    public init(from: String, to: String) {
        self.from = from
        self.to = to
    }
}

/// The user's own words: spellings to keep, and misheard words to correct.
public struct PersonalDictionary: Codable, Equatable, Sendable {
    /// Words and names to spell exactly as written, such as "GitHub".
    public var terms: [String]
    /// "Misheard → correct" pairs, such as "jon" → "John".
    public var replacements: [Replacement]

    public init(terms: [String] = [], replacements: [Replacement] = []) {
        self.terms = terms
        self.replacements = replacements
    }

    public static let empty = PersonalDictionary()

    /// Lower-cased, with runs of whitespace collapsed, so phrases compare reliably.
    private static func key(_ phrase: String) -> String {
        phrase.lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .joined(separator: " ")
    }

    /// Stage 4 of cleanup. Whole words only, any capitalisation, longest phrase first, one pass.
    public func apply(to text: String) -> String {
        var targets: [String: String] = [:]
        for term in terms {
            let key = Self.key(term)
            if !key.isEmpty { targets[key] = term.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        for replacement in replacements {
            let key = Self.key(replacement.from)
            if !key.isEmpty { targets[key] = replacement.to }
        }
        guard !targets.isEmpty else { return text }

        // Longest first, so "cube control" is tried before "cube".
        let alternatives = targets.keys
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
            .map { phrase in
                phrase.split(separator: " ")
                    .map { NSRegularExpression.escapedPattern(for: String($0)) }
                    .joined(separator: "[ \\t]+")
            }
        let pattern = "(?<![\\p{L}\\p{N}])(?:" + alternatives.joined(separator: "|") + ")(?![\\p{L}\\p{N}])"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }

        return TextUtil.replace(re, in: text) { match, source in
            guard let target = targets[Self.key(source.substring(with: match.range))] else { return nil }
            return (target, false)
        }
    }

    /// A short glossary handed to the speech model so it spells these words correctly.
    public func recognitionPrompt(maxCharacters: Int = 600) -> String {
        var seen = Set<String>()
        var words: [String] = []
        for candidate in terms + replacements.map(\.to) {
            let word = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if word.isEmpty || !seen.insert(word.lowercased()).inserted { continue }
            words.append(word)
        }

        var list = ""
        for word in words {
            let next = list.isEmpty ? word : list + ", " + word
            if "Glossary: \(next).".count > maxCharacters { break }
            list = next
        }
        return list.isEmpty ? "" : "Glossary: \(list)."
    }

    /// Reads a dictionary from disk. A missing file is an empty dictionary.
    public static func load(from url: URL) throws -> PersonalDictionary {
        guard FileManager.default.fileExists(atPath: url.path) else { return .empty }
        return try JSONDecoder().decode(PersonalDictionary.self, from: Data(contentsOf: url))
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
