import Foundation

/// What the pipeline needs to know about where the text is going.
public struct PipelineContext: Equatable, Sendable {
    public var level: CleanupLevel
    public var category: AppCategory
    public var dictionary: PersonalDictionary
    /// True when the cursor is in the middle of an existing sentence.
    public var midSentence: Bool

    public init(
        level: CleanupLevel = .light,
        category: AppCategory = .other,
        dictionary: PersonalDictionary = .empty,
        midSentence: Bool = false
    ) {
        self.level = level
        self.category = category
        self.dictionary = dictionary
        self.midSentence = midSentence
    }
}

/// The outcome of one dictation, with a record of what each stage did.
public struct PipelineResult: Codable, Equatable, Sendable {
    /// The transcript exactly as the speech model produced it.
    public var raw: String
    /// The text after the rules stage. This is what is used when the model's reply is not.
    public var rulesText: String
    /// The text to insert.
    public var finalText: String
    public var llmAttempted: Bool
    /// True when the model's reply passed the guardrails and was used.
    public var llmUsed: Bool
    public var fallback: FallbackReason?
    /// Time spent in cleanup, in milliseconds. Transcription is not included.
    public var cleanMillis: Int
}

/// Runs the cleanup stages in order: rules, model, guardrails, dictionary, style.
public struct Pipeline: Sendable {
    private let cleaner: (any TextCleaner)?
    private let config: GuardrailConfig

    /// Pass `nil` for `cleaner` to run the rules stage only.
    public init(cleaner: (any TextCleaner)?, config: GuardrailConfig = .standard) {
        self.cleaner = cleaner
        self.config = config
    }

    /// Words that suggest a self-correction or a filler the rules stage cannot judge.
    private static let markers = [
        "actually", "scratch that", "no wait", "i mean", "sorry", "never mind", "nevermind",
        "rather", "make that", "like", "you know", "sort of", "kind of", "basically",
    ]

    /// Whether the model is worth calling. Short, clean phrases skip it and land almost instantly.
    public static func needsLLM(_ rulesText: String, level: CleanupLevel) -> Bool {
        guard level != .off else { return false }
        let words = WordComparison.words(rulesText)
        if words.isEmpty { return false }
        if words.count > 5 { return true }
        let padded = " " + words.joined(separator: " ") + " "
        return markers.contains { padded.contains(" \($0) ") }
    }

    /// Cleans a transcript. Never throws: if a later stage fails, the output of the last
    /// stage that worked is used.
    public func process(_ transcript: String, context: PipelineContext = PipelineContext()) async -> PipelineResult {
        let started = Date()
        let rulesText = RulesCleaner.clean(transcript, level: context.level)

        // Line breaks at the edges come from spoken commands. Models tend to drop them,
        // so they are set aside here and put back at the end.
        let leading = String(rulesText.prefix(while: { $0 == "\n" }))
        let trailing = String(rulesText.reversed().prefix(while: { $0 == "\n" }))
        let body = rulesText.trimmingCharacters(in: .newlines)

        var text = body
        var attempted = false
        var used = false
        var fallback: FallbackReason?

        if let cleaner, Pipeline.needsLLM(body, level: context.level) {
            attempted = true
            let request = CleanupRequest(
                transcript: body,
                level: context.level,
                category: context.category,
                terms: context.dictionary.terms,
                midSentence: context.midSentence
            )
            let wordCount = WordComparison.words(body).count
            do {
                let reply = try await cleaner.clean(
                    request,
                    timeout: Guardrails.timeout(forWordCount: wordCount, config: config)
                )
                switch Guardrails.check(input: body, output: reply, level: context.level, config: config) {
                case .accepted(let cleaned):
                    text = cleaned
                    used = true
                case .rejected(let reason):
                    fallback = reason
                }
            } catch CleanerError.timeout {
                fallback = .timeout
            } catch {
                fallback = .engineError
            }
        }

        text = context.dictionary.apply(to: text)
        text = StyleRules.apply(text, category: context.category)

        return PipelineResult(
            raw: transcript,
            rulesText: rulesText,
            finalText: text.isEmpty ? "" : leading + text + trailing,
            llmAttempted: attempted,
            llmUsed: used,
            fallback: fallback,
            cleanMillis: Int(Date().timeIntervalSince(started) * 1000)
        )
    }
}
