import Foundation

/// Why the model's output was not used.
public enum FallbackReason: String, Codable, Equatable, Sendable {
    case empty, grew, inventedWords, overDeleted, timeout, engineError
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
        return .accepted(text)
    }

    private static let thinking = TextUtil.regex(#"<think>[\s\S]*?</think>"#)
    private static let fence = TextUtil.regex(#"\A```[a-z]*[ \t]*\n?([\s\S]*?)\n?```\z"#)
    private static let delimiterTags = TextUtil.regex(#"</?(?:transcript|settings)>"#)
    private static let label = TextUtil.regex(
        #"\A(?:(?:sure|okay|ok|certainly)[,!.]?\s+)?(?:here(?:'s| is)\b[^:\n]{0,60}:|(?:cleaned(?:[- ]up)?|edited|corrected|final) (?:text|transcript|version|output):|output:|result:)\s*"#
    )

    /// Removes the wrappers models tend to add: reasoning blocks, code fences, echoed
    /// delimiters, "Here is the cleaned text:" labels and enclosing quotation marks.
    /// A label is kept when `input` starts with the same words, because then the speaker said it.
    public static func unwrap(_ output: String, input: String = "") -> String {
        var text = TextUtil.replace(thinking, in: output, with: "")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = TextUtil.replace(fence, in: text, with: "$1")
        text = TextUtil.replace(delimiterTags, in: text, with: "")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if let match = label.firstMatch(in: text, range: TextUtil.fullRange(text)) {
            let found = (text as NSString).substring(with: match.range)
            let labelStart = Array(WordComparison.words(found).prefix(2))
            let inputStart = Array(WordComparison.words(input).prefix(2))
            if labelStart != inputStart {
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
