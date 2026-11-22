import Foundation

/// Why the model's output was not used.
public enum FallbackReason: String, Codable, Equatable, Sendable {
    case empty, grew, inventedWords, overDeleted, droppedWords, timeout, engineError
}

/// Thresholds for the guardrails. The defaults are tuned against the cleanup test set.
public struct GuardrailConfig: Equatable, Sendable {
    /// The output may have at most `growthFactor` × the input's words, plus `growthAllowance`.
    public var growthFactor = 1.2
    public var growthAllowance = 5
    /// Largest share of output words that may fail to line up, in order, with the input.
    public var maxUnalignedLight = 0.15
    public var maxUnalignedMedium = 0.35
    /// At Light, the output must keep at least this share of the input's words.
    public var minKeptLight = 0.30
    /// Over-deletion is not judged on inputs shorter than this.
    public var overDeletionMinWords = 8
    public var timeoutBase: TimeInterval = 2.5
    public var timeoutPerWord: TimeInterval = 0.04

    public init() {}
    public static let standard = GuardrailConfig()
}

public enum GuardrailVerdict: Equatable, Sendable {
    /// The output is safe to use. The associated text has wrappers removed.
    case accepted(String)
    case rejected(FallbackReason)
}

/// Stage 3 of cleanup: decides whether the model's output is safe to use.
public enum Guardrails {
    /// How long to wait for the model before falling back to the rules output.
    public static func timeout(forWordCount count: Int, config: GuardrailConfig = .standard) -> TimeInterval {
        config.timeoutBase + config.timeoutPerWord * Double(count)
    }

    public static func check(
        input: String,
        output: String,
        level: CleanupLevel,
        config: GuardrailConfig = .standard
    ) -> GuardrailVerdict {
        let text = unwrap(output, input: input)
        let outputWords = WordComparison.words(text)
        guard !outputWords.isEmpty else { return .rejected(.empty) }
        let inputWords = WordComparison.words(input)

        let growthLimit = config.growthFactor * Double(inputWords.count) + Double(config.growthAllowance)
        if Double(outputWords.count) > growthLimit { return .rejected(.grew) }

        let share = level == .medium ? config.maxUnalignedMedium : config.maxUnalignedLight
        let allowed = max(1, Int((share * Double(outputWords.count)).rounded(.up)))
        let aligned = WordComparison.commonSubsequenceLength(inputWords, outputWords)
        if outputWords.count - aligned > allowed { return .rejected(.inventedWords) }

        if level == .light,
           inputWords.count >= config.overDeletionMinWords,
           Double(outputWords.count) < config.minKeptLight * Double(inputWords.count) {
            return .rejected(.overDeleted)
        }
        if level == .light, droppedContent(input: inputWords, output: outputWords) {
            return .rejected(.droppedWords)
        }
        return .accepted(text)
    }

    // MARK: Dropped content

    /// Above this many table cells the comparison is skipped. It covers a ten-minute dictation.
    private static let maxComparisonCells = 6_000_000

    /// Words whose removal says nothing: fillers, function words, and the number words that
    /// disappear when "one thousand two hundred" becomes "1,200".
    private static let ignorable: Set<String> = [
        "a", "an", "the", "and", "or", "but", "so", "then", "also", "well", "okay", "ok", "right",
        "yeah", "yes", "no", "not", "i", "you", "he", "she", "it", "we", "they", "me", "him", "her",
        "us", "them", "my", "your", "his", "its", "our", "their", "this", "that", "these", "those",
        "is", "are", "was", "were", "be", "been", "being", "am", "do", "does", "did", "have", "has",
        "had", "will", "would", "can", "could", "should", "shall", "may", "might", "must", "to",
        "of", "in", "on", "at", "for", "with", "from", "by", "about", "into", "over", "under", "as",
        "if", "because", "when", "while", "than", "before", "after", "um", "uh", "er", "erm", "hmm",
        "like", "know", "mean", "basically", "actually", "literally", "just", "kind", "sort",
        "really", "very", "quite", "there", "here", "what", "which", "who", "whom", "whose",
        "where", "why", "how", "thousand", "hundred", "million", "billion", "point", "dollars",
        "dollar", "percent", "cents", "pounds", "euros", "dot", "gonna", "wanna", "gotta", "kinda",
        "sorta", "pm",
    ]

    /// Words a speaker uses to take something back.
    private static let correctionMarkers: Set<String> = [
        "actually", "no", "wait", "scratch", "sorry", "meant", "mean", "rather", "instead",
        "correction", "oops", "nevermind", "never",
    ]

    private static func isContent(_ word: String) -> Bool {
        !ignorable.contains(word) && !word.allSatisfy(\.isNumber)
    }

    /// True when the output leaves out a stretch of the input that carried meaning, and nothing
    /// the speaker said explains its removal. This is how a model loses "Translate this into
    /// Spanish:" from the front of a dictated instruction.
    static func droppedContent(input: [String], output: [String]) -> Bool {
        guard input.count * output.count <= maxComparisonCells else { return false }
        let matched = WordComparison.matchedFlags(input, output)
        var start = 0
        while start < input.count {
            if matched[start] {
                start += 1
                continue
            }
            var end = start
            while end < input.count, !matched[end] { end += 1 }
            if isUnexplained(start..<end, in: input, outputWords: Set(output)) { return true }
            start = end
        }
        return false
    }

    private static func isUnexplained(_ run: Range<Int>, in input: [String], outputWords: Set<String>) -> Bool {
        let removed = Array(input[run])
        // Two words the model wrote as one, such as "git hub" as "GitHub", were kept, not dropped.
        var joined = Set<Int>()
        for index in removed.indices.dropLast() where outputWords.contains(removed[index] + removed[index + 1]) {
            joined.insert(index)
            joined.insert(index + 1)
        }
        let content = removed.indices.filter { !joined.contains($0) }.map { removed[$0] }.filter(isContent)
        guard content.count >= 2 else { return false }

        // A correction explains it: the speaker took those words back.
        let justAfter = input[run.upperBound..<min(input.count, run.upperBound + 2)]
        if removed.contains(where: correctionMarkers.contains) || justAfter.contains(where: correctionMarkers.contains) {
            return false
        }

        // So does a restart: the same words were said again next to the removed ones.
        let reach = run.count + 4
        let before = input[max(0, run.lowerBound - reach)..<run.lowerBound]
        let after = input[run.upperBound..<min(input.count, run.upperBound + reach)]
        let nearby = Set(before).union(after)
        return !content.allSatisfy(nearby.contains)
    }

    private static let thinking = TextUtil.regex(#"<think>[\s\S]*?</think>"#)
    private static let fence = TextUtil.regex(#"\A```[a-z]*[ \t]*\n?([\s\S]*?)\n?```\z"#)
    private static let delimiterTags = TextUtil.regex(#"</?(?:transcript|settings)>"#)
    private static let label = TextUtil.regex(
        #"\A(?:(?:sure|okay|ok|certainly)[,!.]?\s+)?(?:here(?:'s| is)\b[^:\n]{0,60}:|(?:cleaned(?:[- ]up)?|edited|corrected|final) (?:text|transcript|version|output):|output:|result:)\s*"#
    )

    /// Removes the wrappers models tend to add: reasoning blocks, code fences, echoed
    /// delimiters, "Here is the cleaned text:" labels and enclosing quotation marks.
    /// A label is kept when most of its words open `input`, because then the speaker said it.
    public static func unwrap(_ output: String, input: String = "") -> String {
        var text = TextUtil.replace(thinking, in: output, with: "")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = TextUtil.replace(fence, in: text, with: "$1")
        text = TextUtil.replace(delimiterTags, in: text, with: "")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if let match = label.firstMatch(in: text, range: TextUtil.fullRange(text)) {
            let labelWords = WordComparison.words((text as NSString).substring(with: match.range))
            // The speaker's own opening, such as "Okay, here is the plan:", looks like a label too.
            // It is theirs when at least half of its words are among the first words they said.
            let opening = Set(WordComparison.words(input).prefix(labelWords.count + 4))
            let spoken = labelWords.filter(opening.contains).count
            if spoken * 2 < labelWords.count {
                text = (text as NSString).replacingCharacters(in: match.range, with: "")
            }
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        for (open, close) in [("\"", "\""), ("“", "”")]
        where text.count >= 2 && text.hasPrefix(open) && text.hasSuffix(close) {
            let inner = String(text.dropFirst().dropLast())
            if !inner.contains(open) && !inner.contains(close) {
                text = inner
                break
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
