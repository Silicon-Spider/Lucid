import Foundation

/// One entry in the cleanup test set: a transcript, and what its cleaned text must look like.
public struct EvalCase: Codable, Equatable, Sendable {
    public var id: String
    public var group: String
    public var input: String
    public var level: CleanupLevel?
    public var category: AppCategory?
    public var midSentence: Bool?
    public var terms: [String]?
    public var replacements: [Replacement]?
    /// The output, with surrounding whitespace removed, must equal this.
    public var exact: String?
    /// Each phrase must appear as whole words, in any capitalisation.
    public var mustContain: [String]?
    /// Each phrase must appear with exactly this capitalisation.
    public var mustContainCased: [String]?
    /// For each inner list, at least one phrase must appear as whole words.
    public var mustContainAny: [[String]]?
    /// No phrase may appear as whole words.
    public var mustNotContain: [String]?
    /// Regular expressions the output must match, ignoring case.
    public var mustMatch: [String]?
    /// Regular expressions the output must not match, ignoring case.
    public var mustNotMatch: [String]?
    public var maxWords: Int?

    public init(
        id: String,
        group: String,
        input: String,
        level: CleanupLevel? = nil,
        category: AppCategory? = nil,
        midSentence: Bool? = nil,
        terms: [String]? = nil,
        replacements: [Replacement]? = nil,
        exact: String? = nil,
        mustContain: [String]? = nil,
        mustContainCased: [String]? = nil,
        mustContainAny: [[String]]? = nil,
        mustNotContain: [String]? = nil,
        mustMatch: [String]? = nil,
        mustNotMatch: [String]? = nil,
        maxWords: Int? = nil
    ) {
        self.id = id
        self.group = group
        self.input = input
        self.level = level
        self.category = category
        self.midSentence = midSentence
        self.terms = terms
        self.replacements = replacements
        self.exact = exact
        self.mustContain = mustContain
        self.mustContainCased = mustContainCased
        self.mustContainAny = mustContainAny
        self.mustNotContain = mustNotContain
        self.mustMatch = mustMatch
        self.mustNotMatch = mustNotMatch
        self.maxWords = maxWords
    }

    public var context: PipelineContext {
        PipelineContext(
            level: level ?? .light,
            category: category ?? .other,
            dictionary: PersonalDictionary(terms: terms ?? [], replacements: replacements ?? []),
            midSentence: midSentence ?? false
        )
    }

    /// The reasons the output fails this case. Empty means it passed.
    public func failures(in output: String) -> [String] {
        var problems: [String] = []
        if let exact, output.trimmingCharacters(in: .whitespacesAndNewlines) != exact {
            problems.append("expected exactly \(String(reflecting: exact))")
        }
        for phrase in mustContain ?? [] where !Self.hasWords(output, phrase) {
            problems.append("missing \(String(reflecting: phrase))")
        }
        for phrase in mustContainCased ?? [] where !output.contains(phrase) {
            problems.append("missing \(String(reflecting: phrase)) with that capitalisation")
        }
        for alternatives in mustContainAny ?? [] where !alternatives.contains(where: { Self.hasWords(output, $0) }) {
            problems.append("missing one of \(alternatives)")
        }
        for phrase in mustNotContain ?? [] where Self.hasWords(output, phrase) {
            problems.append("should not contain \(String(reflecting: phrase))")
        }
        for pattern in mustMatch ?? [] where !Self.matches(output, pattern) {
            problems.append("should match \(pattern)")
        }
        for pattern in mustNotMatch ?? [] where Self.matches(output, pattern) {
            problems.append("should not match \(pattern)")
        }
        if let maxWords {
            let count = WordComparison.words(output).count
            if count > maxWords { problems.append("has \(count) words, more than \(maxWords)") }
        }
        return problems
    }

    /// True when `phrase` appears in `text` as whole words, in any capitalisation.
    static func hasWords(_ text: String, _ phrase: String) -> Bool {
        let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: phrase) + "(?![\\p{L}\\p{N}])"
        return matches(text, pattern)
    }

    static func matches(_ text: String, _ pattern: String) -> Bool {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return false }
        return re.firstMatch(in: text, range: TextUtil.fullRange(text)) != nil
    }

    public static func load(from url: URL) throws -> [EvalCase] {
        try JSONDecoder().decode([EvalCase].self, from: Data(contentsOf: url))
    }
}
