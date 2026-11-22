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
    /// The model's reply, kept only when the guardrails rejected it, so the reason can be seen.
    public var rejectedReply: String?
    /// Time spent in cleanup, in milliseconds. Transcription is not included.
    public var cleanMillis: Int

    public init(
        raw: String,
        rulesText: String,
        finalText: String,
        llmAttempted: Bool,
        llmUsed: Bool,
        fallback: FallbackReason?,
        rejectedReply: String?,
        cleanMillis: Int
    ) {
        self.raw = raw
        self.rulesText = rulesText
        self.finalText = finalText
        self.llmAttempted = llmAttempted
        self.llmUsed = llmUsed
        self.fallback = fallback
        self.rejectedReply = rejectedReply
        self.cleanMillis = cleanMillis
    }
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

        // Spoken "new line" and "new paragraph" commands split the text into parts. Models
        // tend to drop line breaks, so each part is cleaned by itself and the breaks the
        // speaker asked for are put back exactly where they were.
        var joined = ""
        var attempted = false
        var used = false
        var fallback: FallbackReason?
        var rejectedReply: String?
        var isFirstPart = true

        for piece in Self.pieces(of: rulesText) {
            switch piece {
            case .breaks(let breaks):
                joined += breaks
            case .text(let part):
                // Only the first part can be carrying on a sentence that is already there.
                let outcome = await clean(part, context: context, midSentence: context.midSentence && isFirstPart)
                isFirstPart = false
                joined += outcome.text
                attempted = attempted || outcome.attempted
                used = used || outcome.used
                fallback = fallback ?? outcome.fallback
                rejectedReply = rejectedReply ?? outcome.rejectedReply
            }
        }

        // The dictionary and style rules look at the text without its edge line breaks.
        let leading = String(joined.prefix(while: { $0 == "\n" }))
        let trailing = String(joined.reversed().prefix(while: { $0 == "\n" }))
        var text = joined.trimmingCharacters(in: .newlines)
        text = context.dictionary.apply(to: text)
        text = StyleRules.apply(text, category: context.category)
        if context.midSentence { text = StyleRules.continuingSentence(text) }

        return PipelineResult(
            raw: transcript,
            rulesText: rulesText,
            finalText: text.isEmpty ? "" : leading + text + trailing,
            llmAttempted: attempted,
            llmUsed: used,
            fallback: fallback,
            rejectedReply: rejectedReply,
            cleanMillis: Int(Date().timeIntervalSince(started) * 1000)
        )
    }

    /// A stretch of text, or the line breaks between two stretches.
    private enum Piece {
        case text(String)
        case breaks(String)
    }

    private static func pieces(of text: String) -> [Piece] {
        var pieces: [Piece] = []
        var words = ""
        var breaks = ""
        for character in text {
            if character == "\n" {
                if !words.isEmpty {
                    pieces.append(.text(words))
                    words = ""
                }
                breaks.append(character)
            } else {
                if !breaks.isEmpty {
                    pieces.append(.breaks(breaks))
                    breaks = ""
                }
                words.append(character)
            }
        }
        if !words.isEmpty { pieces.append(.text(words)) }
        if !breaks.isEmpty { pieces.append(.breaks(breaks)) }
        return pieces
    }

    private struct PartOutcome {
        var text: String
        var attempted = false
        var used = false
        var fallback: FallbackReason?
        var rejectedReply: String?
    }

    /// Runs one part through the model and the guardrails. Falls back to the part as the
    /// rules stage left it.
    private func clean(_ part: String, context: PipelineContext, midSentence: Bool) async -> PartOutcome {
        var outcome = PartOutcome(text: part)
        guard let cleaner, Pipeline.needsLLM(part, level: context.level) else { return outcome }

        outcome.attempted = true
        let request = CleanupRequest(
            transcript: part,
            level: context.level,
            category: context.category,
            terms: context.dictionary.terms,
            midSentence: midSentence
        )
        let wordCount = WordComparison.words(part).count
        do {
            let reply = try await cleaner.clean(
                request,
                timeout: Guardrails.timeout(forWordCount: wordCount, config: config)
            )
            switch Guardrails.check(input: part, output: reply, level: context.level, config: config) {
            case .accepted(let cleaned):
                outcome.text = cleaned
                outcome.used = true
            case .rejected(let reason):
                outcome.fallback = reason
                outcome.rejectedReply = reply
            }
        } catch CleanerError.timeout {
            outcome.fallback = .timeout
        } catch {
            outcome.fallback = .engineError
        }
        return outcome
    }
}
