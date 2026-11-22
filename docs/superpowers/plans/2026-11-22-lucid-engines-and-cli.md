# Lucid Engines and CLI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run speech recognition and cleanup on-device through whisper.cpp and llama.cpp, expose the whole pipeline as a command-line tool, and choose the models by measurement.

**Architecture:** A new library target, `LucidEngines`, starts `whisper-server` and `llama-server` as child processes bound to `127.0.0.1` and talks to them over HTTP. Its two clients conform to the `Transcriber` and `TextCleaner` protocols from plan 1, so `Pipeline` is unchanged. A new executable, `lucid-cli`, drives the pipeline from text or WAV files and runs the cleanup test set.

**Tech Stack:** Swift 5.9, Foundation (`Process`, `URLSession`), whisper.cpp 1.9.5 and llama.cpp 1.0.0 from Homebrew.

This is plan 2 of 3. Plan 1 built the cleanup core. Plan 3 builds the menu-bar app.

Spec: [`docs/superpowers/specs/2026-11-22-lucid-dictation-design.md`](../specs/2026-11-22-lucid-dictation-design.md)

## Global Constraints

- Swift tools version 5.9, macOS 14 minimum, no Swift package dependencies.
- `LucidCore` imports Foundation only. `LucidEngines` may also use `Process`, `URLSession` and Darwin.
- Engines listen on `127.0.0.1` only. Requests to them never go through a system proxy.
- Tests run with `scripts/test.sh`, which must pass without the engines or models installed. Anything that needs a real engine is checked with `lucid-cli`, not the unit tests.
- Every task ends with a commit pushed to `main` on `origin`.
- Every commit message ends with the line `Co-Authored-By: Claude Fable 5.2 <noreply@anthropic.com>`.
- The cleanup model is named in full, "S1-mini by Superwhisper", wherever it is mentioned to a user. Its licence requires that.

## Facts measured on the build machine

These were measured before writing this plan (Apple M4, 16 GB) and the code relies on them.

| Fact | Detail |
|---|---|
| Binaries | Homebrew installs `/opt/homebrew/bin/whisper-server` and `/opt/homebrew/bin/llama-server`. |
| whisper-server | `POST /inference`, multipart form: `file`, `response_format=json`, `temperature`, `audio_ctx`, `prompt`. Reply: `{"text": "..."}`. `GET /` returns 200 once the model is loaded. |
| whisper windows | The reply puts a line break between 30-second windows. These are not paragraph breaks. |
| `audio_ctx` | Half the window (768) transcribes a 2 s clip in 0.5 s instead of 1.1 s, and a 14 s clip in 0.75 s instead of 1.2 s, with the same text. Values of 122 and 218 produced garbage. |
| llama-server | Default port is 9931, so the port is always passed. `GET /health` returns 200 once loaded. `POST /v1/chat/completions` takes `messages`, `temperature`, `max_tokens`, `cache_prompt`. Reply: `choices[0].message.content` and `choices[0].finish_reason`. |
| S1-mini by Superwhisper | A 0.6B model trained to clean speech transcripts. Needs its exact system prompt, a control line, and `--jinja --chat-template-kwargs '{"enable_thinking":false}'`. Cleans 40 words in 0.27 s and 90 words in 0.8 s. |
| Llama 3.2 3B | With Lucid's own prompt: 40 words in 0.8 s, 90 words in 1.6 s, and it dropped more of the speaker's content. |

## File Structure

```
Package.swift                              adds LucidEngines and lucid-cli
scripts/setup.sh                           installs engines and downloads models
scripts/integration.sh                     end-to-end run on synthesised speech
evals/cases.json                           the cleanup test set
docs/benchmarks.md                         measured results and the model choice
Sources/LucidCore/
  S1Prompt.swift                           PromptStyle, and the S1-mini input format
  StyleRules.swift                         adds the mid-sentence rule
  Pipeline.swift                           applies the mid-sentence rule
  Audio.swift                              adds WAV.seconds and WhisperWindow
  Evaluation.swift                         EvalCase and its checks
Sources/LucidEngines/
  EngineConfig.swift                       paths, model names, what is missing
  EngineError.swift                        errors shared by the engine code
  LocalHTTP.swift                          a URLSession that never uses a proxy
  ServerProcess.swift                      one helper process and its readiness check
  PidFile.swift                            remembers engine PIDs to clean up after a crash
  WhisperClient.swift                      Transcriber over HTTP
  LlamaClient.swift                        TextCleaner over HTTP
  EngineSupervisor.swift                   starts, restarts and stops both engines
Sources/lucid-cli/
  main.swift                               argument parsing and the commands
Tests/LucidCoreTests/
  Harness.swift                            adds expectThrows
  PromptStyleTests.swift
  ContinuationTests.swift
  WhisperWindowTests.swift
  EvalCaseTests.swift
  EngineTests.swift
  ClientTests.swift
```

Each code block below that is preceded by a `**File:**` line is the complete content of that file at the end of that step.

---

### Task 1: Prompt styles and the S1-mini format

**Files:**
- Create: `Sources/LucidCore/S1Prompt.swift`
- Create: `Tests/LucidCoreTests/PromptStyleTests.swift`
- Modify: `Tests/LucidCoreTests/main.swift`

**Interfaces:**
- Consumes: `CleanupRequest`, `ChatMessage`, `AppCategory`, `PromptBuilder.messages(for:)` from plan 1.
- Produces:
  - `public enum PromptStyle: String, Codable, CaseIterable { case s1, general }`
  - `public func PromptStyle.messages(for request: CleanupRequest) -> [ChatMessage]`
  - `public static let S1Prompt.systemPrompt: String`
  - `public static func S1Prompt.controlLine(for category: AppCategory) -> String`
  - `public static func S1Prompt.messages(for request: CleanupRequest) -> [ChatMessage]`

S1-mini is steered by a control line with three settings. Lucid maps app categories to them:

| Category | Styling | Structure | Context |
|---|---|---|---|
| email | semi-formal | lists | email |
| chat | semi-formal | prose | general |
| code | semi-formal | prose | general |
| other | semi-formal | lists | general |

S1-mini has no input for dictionary terms, the mid-sentence flag or the Medium level. Dictionary terms are handled by stage 4, mid-sentence by Task 2, and Medium by the general model (Task 9 records how the two are routed).

- [ ] **Step 1: Write the failing tests**

**File:** `Tests/LucidCoreTests/PromptStyleTests.swift`

```swift
import LucidCore

func promptStyleTests() {
    suite("PromptStyle") {
        test("S1 uses its fixed system prompt") {
            let messages = S1Prompt.messages(for: CleanupRequest(transcript: "hello there"))
            expectEqual(messages.count, 2)
            expectEqual(messages[0], ChatMessage(role: "system", content: S1Prompt.systemPrompt))
            expectTrue(S1Prompt.systemPrompt.hasPrefix("You are a text normalizer for speech-to-text transcripts."))
            expectTrue(S1Prompt.systemPrompt.hasSuffix("output only the cleaned text."))
        }

        test("S1 puts a control line above the transcript") {
            let message = S1Prompt.messages(for: CleanupRequest(transcript: "hello there")).last
            expectEqual(message?.role, "user")
            expectEqual(
                message?.content,
                "[Styling: semi-formal] [Structure: lists] [Context: general]\nhello there"
            )
        }

        test("S1 control line follows the app category") {
            expectEqual(S1Prompt.controlLine(for: .email), "[Styling: semi-formal] [Structure: lists] [Context: email]")
            expectEqual(S1Prompt.controlLine(for: .chat), "[Styling: semi-formal] [Structure: prose] [Context: general]")
            expectEqual(S1Prompt.controlLine(for: .code), "[Styling: semi-formal] [Structure: prose] [Context: general]")
            expectEqual(S1Prompt.controlLine(for: .other), "[Styling: semi-formal] [Structure: lists] [Context: general]")
        }

        test("each style builds its own messages") {
            let request = CleanupRequest(transcript: "hello there", category: .chat)
            expectEqual(PromptStyle.s1.messages(for: request), S1Prompt.messages(for: request))
            expectEqual(PromptStyle.general.messages(for: request), PromptBuilder.messages(for: request))
        }
    }
}
```

**File:** `Tests/LucidCoreTests/main.swift`

```swift
import Foundation

TestRun.shared.filter = CommandLine.arguments.dropFirst().first

harnessTests()
rulesCleanerTests()
guardrailsTests()
dictionaryTests()
styleRulesTests()
promptBuilderTests()
audioTests()
await pipelineTests()
promptStyleTests()

TestRun.shared.finish()
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `scripts/test.sh PromptStyle`
Expected: the build fails with `cannot find 'S1Prompt' in scope`.

- [ ] **Step 3: Write the prompt styles**

**File:** `Sources/LucidCore/S1Prompt.swift`

```swift
import Foundation

/// Which prompt format a cleanup model expects.
public enum PromptStyle: String, Codable, CaseIterable, Sendable {
    /// S1-mini by Superwhisper: a fixed system prompt and a control line.
    case s1
    /// Any general instruction-following model: Lucid's own prompt from `PromptBuilder`.
    case general

    public func messages(for request: CleanupRequest) -> [ChatMessage] {
        switch self {
        case .s1: return S1Prompt.messages(for: request)
        case .general: return PromptBuilder.messages(for: request)
        }
    }
}

/// The input format for S1-mini by Superwhisper, a small model trained to clean speech transcripts.
///
/// The system prompt and the control line are part of what the model was trained on.
/// Changing their wording, or sending values outside the trained sets, makes it produce garbage.
public enum S1Prompt {
    public static let systemPrompt = "You are a text normalizer for speech-to-text transcripts. "
        + "The input begins with a control line specifying the styling, structure, and context settings; "
        + "clean the transcript to match those settings and output only the cleaned text."

    /// The trained values are: Styling casual, semi-casual, semi-formal or formal;
    /// Structure prose or lists; Context general or email.
    public static func controlLine(for category: AppCategory) -> String {
        switch category {
        case .email: return "[Styling: semi-formal] [Structure: lists] [Context: email]"
        case .chat, .code: return "[Styling: semi-formal] [Structure: prose] [Context: general]"
        case .other: return "[Styling: semi-formal] [Structure: lists] [Context: general]"
        }
    }

    public static func messages(for request: CleanupRequest) -> [ChatMessage] {
        [
            ChatMessage(role: "system", content: systemPrompt),
            ChatMessage(role: "user", content: controlLine(for: request.category) + "\n" + request.transcript),
        ]
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `scripts/test.sh PromptStyle`
Expected: the last line is `PASSED  4 tests, 12 checks`.

- [ ] **Step 5: Commit**

```bash
git add Sources/LucidCore/S1Prompt.swift Tests/LucidCoreTests
git commit -m "Add prompt styles and the S1-mini input format"
git push origin main
```

---

### Task 2: Mid-sentence rule

When text is inserted in the middle of a sentence, its first word should not be capitalised. S1-mini cannot be told this, so it is a deterministic rule applied last.

**Files:**
- Modify: `Sources/LucidCore/StyleRules.swift` (add one method and one constant)
- Modify: `Sources/LucidCore/Pipeline.swift` (one line)
- Modify: `Tests/LucidCoreTests/PipelineTests.swift` (one expectation)
- Create: `Tests/LucidCoreTests/ContinuationTests.swift`
- Modify: `Tests/LucidCoreTests/main.swift`

**Interfaces:**
- Consumes: `Pipeline`, `PipelineContext` from plan 1.
- Produces: `public static func StyleRules.continuingSentence(_ text: String) -> String`

The rule only lower-cases a first word from a fixed list of common words. A name is never in that list, so "John agreed" keeps its capital. Missing a lower-case is a smaller error than lower-casing a name.

- [ ] **Step 1: Write the failing tests**

**File:** `Tests/LucidCoreTests/ContinuationTests.swift`

```swift
import LucidCore

func continuationTests() async {
    await asyncSuite("Continuation") {
        test("lower-cases a safe first word") {
            expectEqual(StyleRules.continuingSentence("And then we can go."), "and then we can go.")
            expectEqual(StyleRules.continuingSentence("The report is ready."), "the report is ready.")
            expectEqual(StyleRules.continuingSentence("Let's go."), "let's go.")
        }

        test("keeps names, I and acronyms") {
            expectEqual(StyleRules.continuingSentence("John agreed."), "John agreed.")
            expectEqual(StyleRules.continuingSentence("I think so."), "I think so.")
            expectEqual(StyleRules.continuingSentence("I'm not sure."), "I'm not sure.")
            expectEqual(StyleRules.continuingSentence("API keys rotate weekly."), "API keys rotate weekly.")
            expectEqual(StyleRules.continuingSentence("already lower."), "already lower.")
            expectEqual(StyleRules.continuingSentence(""), "")
        }

        await asyncTest("the pipeline applies it when the cursor is mid-sentence") {
            let pipeline = Pipeline(cleaner: nil)
            let mid = await pipeline.process("And then we can review it.", context: PipelineContext(midSentence: true))
            expectEqual(mid.finalText, "and then we can review it.")
            let start = await pipeline.process("And then we can review it.", context: PipelineContext(midSentence: false))
            expectEqual(start.finalText, "And then we can review it.")
        }
    }
}
```

**File:** `Tests/LucidCoreTests/main.swift`

```swift
import Foundation

TestRun.shared.filter = CommandLine.arguments.dropFirst().first

harnessTests()
rulesCleanerTests()
guardrailsTests()
dictionaryTests()
styleRulesTests()
promptBuilderTests()
audioTests()
await pipelineTests()
promptStyleTests()
await continuationTests()

TestRun.shared.finish()
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `scripts/test.sh Continuation`
Expected: the build fails with `type 'StyleRules' has no member 'continuingSentence'`.

- [ ] **Step 3: Add the rule**

In `Sources/LucidCore/StyleRules.swift`, add this inside `enum StyleRules`, after `droppingFinalStop`:

```swift
    /// Words that are safe to lower-case at the start of a continuation. No name is in
    /// this list, so "John agreed" keeps its capital.
    private static let continuationWords: Set<String> = [
        "a", "an", "the", "and", "but", "or", "so", "then", "also", "because", "which", "that",
        "when", "while", "if", "as", "to", "of", "in", "on", "at", "for", "with", "from", "by",
        "about", "we", "you", "they", "he", "she", "it", "this", "these", "those", "there", "here",
        "my", "your", "our", "their", "is", "are", "was", "were", "will", "can", "should", "would",
        "could", "do", "does", "did", "have", "has", "had", "not", "just", "please", "let's",
        "what", "where", "how", "why", "who", "however", "maybe",
    ]

    /// When text is inserted in the middle of a sentence, its first word should not be capitalised.
    public static func continuingSentence(_ text: String) -> String {
        guard let first = text.first, first.isUppercase else { return text }
        let word = text.prefix(while: { $0.isLetter || $0 == "'" || $0 == "’" })
            .lowercased()
            .replacingOccurrences(of: "’", with: "'")
        guard continuationWords.contains(word) else { return text }
        return first.lowercased() + text.dropFirst()
    }
```

In `Sources/LucidCore/Pipeline.swift`, find:

```swift
        text = StyleRules.apply(text, category: context.category)
```

and add one line after it:

```swift
        text = StyleRules.apply(text, category: context.category)
        if context.midSentence { text = StyleRules.continuingSentence(text) }
```

- [ ] **Step 4: Update the one pipeline test this changes**

The test "an accepted reply is used, then dictionary and style are applied" runs with `midSentence: true`, and its text starts with "So". In `Tests/LucidCoreTests/PipelineTests.swift`, change:

```swift
            expectEqual(result.finalText, "So let's meet John at the cafe tomorrow morning, okay")
```

to:

```swift
            expectEqual(result.finalText, "so let's meet John at the cafe tomorrow morning, okay")
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `scripts/test.sh Continuation && scripts/test.sh Pipeline`
Expected: `PASSED  3 tests, 11 checks`, then `PASSED  11 tests, 39 checks`.

- [ ] **Step 6: Commit**

```bash
git add Sources/LucidCore/StyleRules.swift Sources/LucidCore/Pipeline.swift Tests/LucidCoreTests
git commit -m "Lower-case the first word when text continues a sentence"
git push origin main
```

---

### Task 3: WAV duration and the Whisper window

**Files:**
- Modify: `Sources/LucidCore/Audio.swift` (add one method and one enum)
- Create: `Tests/LucidCoreTests/WhisperWindowTests.swift`
- Modify: `Tests/LucidCoreTests/main.swift`

**Interfaces:**
- Consumes: `WAV.encode` from plan 1.
- Produces:
  - `public static func WAV.seconds(of data: Data) -> Double?` (nil when the data is not a WAV)
  - `public static func WhisperWindow.audioContext(forSeconds seconds: Double) -> Int`

Whisper's encoder always processes a fixed window: 1500 frames, which is 30 seconds, at 50 frames per second. The server accepts a smaller window per request. The policy is: use a half window (768) when the clip fits in it with a margin of 64 frames, which is clips up to 14 seconds; otherwise send 0, which means the full window. Never go below half.

- [ ] **Step 1: Write the failing tests**

**File:** `Tests/LucidCoreTests/WhisperWindowTests.swift`

```swift
import Foundation
import LucidCore

func whisperWindowTests() {
    suite("WhisperWindow") {
        test("reads the duration of an encoded WAV") {
            let data = WAV.encode(samples: [Int16](repeating: 0, count: 24_000))
            expectEqual(WAV.seconds(of: data), 1.5)
        }

        test("rejects data that is not a WAV") {
            expectEqual(WAV.seconds(of: Data("hello".utf8)), nil)
            expectEqual(WAV.seconds(of: Data()), nil)
            expectEqual(WAV.seconds(of: Data(repeating: 0, count: 100)), nil)
        }

        test("short clips use the half window") {
            expectEqual(WhisperWindow.audioContext(forSeconds: 0.5), 768)
            expectEqual(WhisperWindow.audioContext(forSeconds: 14.0), 768)
        }

        test("longer clips use the full window") {
            expectEqual(WhisperWindow.audioContext(forSeconds: 14.5), 0)
            expectEqual(WhisperWindow.audioContext(forSeconds: 120), 0)
        }
    }
}
```

**File:** `Tests/LucidCoreTests/main.swift`

```swift
import Foundation

TestRun.shared.filter = CommandLine.arguments.dropFirst().first

harnessTests()
rulesCleanerTests()
guardrailsTests()
dictionaryTests()
styleRulesTests()
promptBuilderTests()
audioTests()
await pipelineTests()
promptStyleTests()
await continuationTests()
whisperWindowTests()

TestRun.shared.finish()
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `scripts/test.sh WhisperWindow`
Expected: the build fails with `type 'WAV' has no member 'seconds'`.

- [ ] **Step 3: Add the duration reader and the window policy**

In `Sources/LucidCore/Audio.swift`, add this method inside `enum WAV`, after `encode`:

```swift
    /// The duration of a PCM WAV file, read from its header. Nil when the data is not a WAV.
    public static func seconds(of data: Data) -> Double? {
        guard data.count >= 44 else { return nil }
        let bytes = [UInt8](data.prefix(44))
        guard String(decoding: bytes[0..<4], as: UTF8.self) == "RIFF",
              String(decoding: bytes[8..<12], as: UTF8.self) == "WAVE" else { return nil }

        func uint16(_ offset: Int) -> Int { Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 }
        func uint32(_ offset: Int) -> Int { uint16(offset) | uint16(offset + 2) << 16 }

        let bytesPerSecond = uint32(24) * uint16(22) * uint16(34) / 8
        guard bytesPerSecond > 0 else { return nil }
        return Double(data.count - 44) / Double(bytesPerSecond)
    }
```

Then add this at the end of the same file:

```swift

/// Whisper's encoder always processes a fixed window of audio: 1500 frames, which is 30 seconds.
/// A smaller window is faster, but the turbo model produces garbage below half size.
public enum WhisperWindow {
    /// What the server takes to mean "the full window".
    public static let full = 0
    public static let half = 768
    private static let framesPerSecond = 50.0
    private static let margin = 64.0

    /// The `audio_ctx` value to send for a clip of this length.
    public static func audioContext(forSeconds seconds: Double) -> Int {
        seconds * framesPerSecond + margin <= Double(half) ? half : full
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `scripts/test.sh WhisperWindow`
Expected: the last line is `PASSED  4 tests, 8 checks`.

- [ ] **Step 5: Commit**

```bash
git add Sources/LucidCore/Audio.swift Tests/LucidCoreTests
git commit -m "Add WAV duration and the Whisper window policy"
git push origin main
```

---

### Task 4: Test-set cases

The type behind `evals/cases.json`: one transcript and the checks its cleaned text must pass.

**Files:**
- Create: `Sources/LucidCore/Evaluation.swift`
- Create: `Tests/LucidCoreTests/EvalCaseTests.swift`
- Modify: `Tests/LucidCoreTests/main.swift`

**Interfaces:**
- Consumes: `CleanupLevel`, `AppCategory`, `Replacement`, `PersonalDictionary`, `PipelineContext`, `WordComparison.words`, `TextUtil.fullRange` from plan 1.
- Produces:
  - `public struct EvalCase: Codable, Equatable` with fields `id`, `group`, `input` (required) and `level`, `category`, `midSentence`, `terms`, `replacements`, `exact`, `mustContain`, `mustContainCased`, `mustContainAny`, `mustNotContain`, `mustMatch`, `mustNotMatch`, `maxWords` (all optional)
  - A memberwise `init` taking those fields in that order, with every optional defaulting to `nil`
  - `public var context: PipelineContext`
  - `public func failures(in output: String) -> [String]` (empty means the case passed)
  - `public static func load(from url: URL) throws -> [EvalCase]`

Checks:

| Field | Meaning |
|---|---|
| `exact` | The output, with surrounding whitespace removed, equals this. |
| `mustContain` | Each phrase appears as whole words, in any capitalisation. |
| `mustContainCased` | Each phrase appears with exactly this capitalisation. |
| `mustContainAny` | For each inner list, at least one phrase appears as whole words. |
| `mustNotContain` | No phrase appears as whole words. |
| `mustMatch`, `mustNotMatch` | Regular expressions, case-insensitive. |
| `maxWords` | The output has at most this many words. |

- [ ] **Step 1: Write the failing tests**

**File:** `Tests/LucidCoreTests/EvalCaseTests.swift`

```swift
import Foundation
import LucidCore

func evalCaseTests() {
    suite("EvalCase") {
        test("passes when every check is met") {
            let testCase = EvalCase(
                id: "a", group: "g", input: "x",
                mustContain: ["meet at"],
                mustContainAny: [["three", "3"]],
                mustNotContain: ["um", "two"]
            )
            expectEqual(testCase.failures(in: "Let's meet at 3."), [])
        }

        test("matches whole words in any capitalisation") {
            let testCase = EvalCase(id: "a", group: "g", input: "x", mustContain: ["friday"], mustNotContain: ["um"])
            expectEqual(testCase.failures(in: "The umbrella is due Friday."), [])
            expectEqual(
                testCase.failures(in: "Um, due Fridays."),
                ["missing \"friday\"", "should not contain \"um\""]
            )
        }

        test("checks exact output, capitals, patterns and length") {
            let testCase = EvalCase(
                id: "a", group: "g", input: "x",
                exact: "Do you want lunch?",
                mustContainCased: ["Do you"],
                mustMatch: ["\\?\\s*$"],
                mustNotMatch: ["(?m)^\\s*[-•*]\\s"],
                maxWords: 4
            )
            expectEqual(testCase.failures(in: "  Do you want lunch?\n"), [])
            expectEqual(testCase.failures(in: "- do you want some lunch.").count, 5)
        }

        test("reports a missing alternative") {
            let testCase = EvalCase(id: "a", group: "g", input: "x", mustContainAny: [["three", "3"]])
            expectEqual(testCase.failures(in: "At two."), ["missing one of [\"three\", \"3\"]"])
        }

        test("builds a pipeline context with defaults") {
            expectEqual(EvalCase(id: "a", group: "g", input: "x").context, PipelineContext())
            let custom = EvalCase(
                id: "a", group: "g", input: "x",
                level: .off, category: .chat, midSentence: true,
                terms: ["Lucid"], replacements: [Replacement(from: "jon", to: "John")]
            )
            let expected = PipelineContext(
                level: .off,
                category: .chat,
                dictionary: PersonalDictionary(terms: ["Lucid"], replacements: [Replacement(from: "jon", to: "John")]),
                midSentence: true
            )
            expectEqual(custom.context, expected)
        }

        test("decodes from JSON with optional fields missing") {
            let json = #"[{"id": "a", "group": "g", "input": "hello", "mustContain": ["hello"]}]"#
            let cases = try JSONDecoder().decode([EvalCase].self, from: Data(json.utf8))
            expectEqual(cases, [EvalCase(id: "a", group: "g", input: "hello", mustContain: ["hello"])])
        }
    }
}
```

**File:** `Tests/LucidCoreTests/main.swift`

```swift
import Foundation

TestRun.shared.filter = CommandLine.arguments.dropFirst().first

harnessTests()
rulesCleanerTests()
guardrailsTests()
dictionaryTests()
styleRulesTests()
promptBuilderTests()
audioTests()
await pipelineTests()
promptStyleTests()
await continuationTests()
whisperWindowTests()
evalCaseTests()

TestRun.shared.finish()
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `scripts/test.sh EvalCase`
Expected: the build fails with `cannot find 'EvalCase' in scope`.

- [ ] **Step 3: Write the case type**

**File:** `Sources/LucidCore/Evaluation.swift`

```swift
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `scripts/test.sh EvalCase`
Expected: the last line is `PASSED  6 tests, 9 checks`.

- [ ] **Step 5: Commit**

```bash
git add Sources/LucidCore/Evaluation.swift Tests/LucidCoreTests
git commit -m "Add the test-set case type and its checks"
git push origin main
```

---

### Task 5: Engine processes

The `LucidEngines` target, and the pieces that start and stop a helper process.

**Files:**
- Modify: `Package.swift`
- Create: `Sources/LucidEngines/EngineError.swift`, `Sources/LucidEngines/LocalHTTP.swift`, `Sources/LucidEngines/EngineConfig.swift`, `Sources/LucidEngines/ServerProcess.swift`, `Sources/LucidEngines/PidFile.swift`
- Modify: `Tests/LucidCoreTests/Harness.swift` (add `expectThrows`)
- Create: `Tests/LucidCoreTests/EngineTests.swift`
- Modify: `Tests/LucidCoreTests/main.swift`

**Interfaces:**
- Consumes: `PromptStyle` from Task 1.
- Produces:
  - `public enum EngineError: Error, Equatable, CustomStringConvertible { case missing(String), launchFailed(String), notReady(String), badResponse(String) }`
  - `public struct CleanupModel: Equatable { var fileName: String; var style: PromptStyle; init(fileName:style:) }`
  - `public struct EngineConfig: Equatable` with public vars `whisperServer`, `llamaServer`, `modelsDirectory`, `logsDirectory`, `supportDirectory` (all `URL`), `speechModel: String`, `cleanupModel: CleanupModel`
  - `public static let EngineConfig.s1Mini`, `EngineConfig.general: CleanupModel`
  - `public static var EngineConfig.supportDirectory: URL`
  - `public static func EngineConfig.standard(cleanup: CleanupModel = s1Mini) -> EngineConfig`
  - `public var speechModelURL: URL`, `public var cleanupModelURL: URL`
  - `public func missing(speech: Bool = true, cleanup: Bool = true) -> [String]`
  - `public final class ServerProcess` with `init(name:executable:arguments:port:healthPath:logURL:)`, `start() throws`, `waitUntilReady(timeout:) async throws`, `stop()`, `isRunning`, `baseURL`, `processIdentifier`, and `static func freePort() throws -> Int`
  - `public enum PidFile` with `write(_:to:)`, `read(at:)`, `remove(at:)`, `killStale(at:names:)`
  - Internal: `LocalHTTP.session: URLSession`
  - Test helper: `expectThrows(_:)`

`ServerProcess` is tested against a real process without needing the engines: Python's built-in web server stands in for a healthy engine, and `/usr/bin/false` for one that dies at launch.

- [ ] **Step 1: Add the target**

**File:** `Package.swift`

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Lucid",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "LucidCore"),
        .target(name: "LucidEngines", dependencies: ["LucidCore"]),
        .executableTarget(
            name: "LucidCoreTests",
            dependencies: ["LucidCore", "LucidEngines"],
            path: "Tests/LucidCoreTests"
        ),
    ]
)
```

- [ ] **Step 2: Add `expectThrows` to the harness**

Append to `Tests/LucidCoreTests/Harness.swift`:

```swift

func expectThrows<T>(_ body: () throws -> T, file: String = #fileID, line: Int = #line) {
    TestRun.shared.check()
    do {
        _ = try body()
        TestRun.shared.fail("expected an error to be thrown", file: file, line: line)
    } catch {
        // An error is what the test wanted.
    }
}
```

- [ ] **Step 3: Write the failing tests**

**File:** `Tests/LucidCoreTests/EngineTests.swift`

```swift
import Foundation
import LucidCore
import LucidEngines

private func temporaryFile(_ suffix: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("lucid-test-\(UUID().uuidString)\(suffix)")
}

func engineTests() async {
    await asyncSuite("Engines") {
        test("finds a free port") {
            let port = try ServerProcess.freePort()
            expectTrue(port > 1024 && port < 65536, "port \(port)")
        }

        test("standard config points at the models folder") {
            let config = EngineConfig.standard()
            expectEqual(config.speechModelURL.lastPathComponent, "ggml-large-v3-turbo-q5_0.bin")
            expectEqual(config.cleanupModelURL.lastPathComponent, "s1-mini-q4_k_m.gguf")
            expectEqual(config.cleanupModel.style, .s1)
            expectTrue(config.modelsDirectory.path.hasSuffix("Library/Application Support/Lucid/models"))
        }

        test("reports what is missing") {
            var config = EngineConfig.standard()
            config.whisperServer = URL(fileURLWithPath: "/nonexistent/whisper-server")
            config.speechModel = "no-such-model.bin"
            let missing = config.missing(speech: true, cleanup: false)
            expectEqual(missing.count, 2)
            expectTrue(missing.contains { $0.contains("/nonexistent/whisper-server") }, "\(missing)")
            expectTrue(missing.contains { $0.contains("no-such-model.bin") }, "\(missing)")
        }

        await asyncTest("starts a server, waits for it and stops it") {
            let port = try ServerProcess.freePort()
            let log = temporaryFile(".log")
            defer { try? FileManager.default.removeItem(at: log) }
            let server = ServerProcess(
                name: "test server",
                executable: URL(fileURLWithPath: "/usr/bin/python3"),
                arguments: ["-m", "http.server", String(port), "--bind", "127.0.0.1"],
                port: port,
                healthPath: "/",
                logURL: log
            )
            try server.start()
            try await server.waitUntilReady(timeout: 30)
            expectTrue(server.isRunning)
            expectEqual(server.baseURL.absoluteString, "http://127.0.0.1:\(port)")
            server.stop()
            expectFalse(server.isRunning)
        }

        await asyncTest("reports a server that exits straight away") {
            let log = temporaryFile(".log")
            defer { try? FileManager.default.removeItem(at: log) }
            let server = ServerProcess(
                name: "broken server",
                executable: URL(fileURLWithPath: "/usr/bin/false"),
                arguments: [],
                port: try ServerProcess.freePort(),
                healthPath: "/",
                logURL: log
            )
            try server.start()
            do {
                try await server.waitUntilReady(timeout: 5)
                expectTrue(false, "expected an error")
            } catch let error as EngineError {
                if case .launchFailed = error {
                    expectTrue(true)
                } else {
                    expectTrue(false, "unexpected error \(error)")
                }
            }
        }

        test("pid file cleanup leaves unrelated processes alone") {
            let url = temporaryFile(".pid")
            PidFile.write([getpid()], to: url)
            expectEqual(PidFile.read(at: url), [getpid()])
            // This test process is not an engine, so it must survive the cleanup.
            PidFile.killStale(at: url, names: ["whisper-server", "llama-server"])
            expectFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }
}
```

**File:** `Tests/LucidCoreTests/main.swift`

```swift
import Foundation

TestRun.shared.filter = CommandLine.arguments.dropFirst().first

harnessTests()
rulesCleanerTests()
guardrailsTests()
dictionaryTests()
styleRulesTests()
promptBuilderTests()
audioTests()
await pipelineTests()
promptStyleTests()
await continuationTests()
whisperWindowTests()
evalCaseTests()
await engineTests()

TestRun.shared.finish()
```

- [ ] **Step 4: Run the tests to verify they fail**

Run: `scripts/test.sh Engines`
Expected: the build fails. With no files in `Sources/LucidEngines` yet, the error is `Source files for target LucidEngines should be located under 'Sources/LucidEngines'`.

- [ ] **Step 5: Write the engine basics**

**File:** `Sources/LucidEngines/EngineError.swift`

```swift
import Foundation

public enum EngineError: Error, Equatable, CustomStringConvertible {
    /// A binary or a model file is not installed.
    case missing(String)
    case launchFailed(String)
    case notReady(String)
    case badResponse(String)

    public var description: String {
        switch self {
        case .missing(let detail): return "Missing: \(detail)"
        case .launchFailed(let detail): return "Could not start: \(detail)"
        case .notReady(let detail): return "Not ready: \(detail)"
        case .badResponse(let detail): return "Unexpected reply: \(detail)"
        }
    }
}
```

**File:** `Sources/LucidEngines/LocalHTTP.swift`

```swift
import Foundation

/// HTTP to the engines on this machine.
enum LocalHTTP {
    /// A session that never uses a system proxy, so local requests stay local.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForResource = 900
        return URLSession(configuration: configuration)
    }()
}
```

**File:** `Sources/LucidEngines/EngineConfig.swift`

```swift
import Foundation
import LucidCore

/// A cleanup model file and the prompt format it expects.
public struct CleanupModel: Equatable, Sendable {
    public var fileName: String
    public var style: PromptStyle

    public init(fileName: String, style: PromptStyle) {
        self.fileName = fileName
        self.style = style
    }
}

/// Where the engines and models are, and which models to use.
public struct EngineConfig: Equatable, Sendable {
    public var whisperServer: URL
    public var llamaServer: URL
    public var modelsDirectory: URL
    public var logsDirectory: URL
    public var supportDirectory: URL
    public var speechModel: String
    public var cleanupModel: CleanupModel

    public static let defaultSpeechModel = "ggml-large-v3-turbo-q5_0.bin"
    /// S1-mini by Superwhisper.
    public static let s1Mini = CleanupModel(fileName: "s1-mini-q4_k_m.gguf", style: .s1)
    public static let general = CleanupModel(fileName: "Llama-3.2-3B-Instruct-Q4_K_M.gguf", style: .general)

    /// `~/Library/Application Support/Lucid`
    public static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lucid")
    }

    /// Looks in Homebrew's folder on Apple Silicon, then on Intel.
    static func findBinary(_ name: String) -> URL {
        let folders = ["/opt/homebrew/bin", "/usr/local/bin"]
        for folder in folders {
            let url = URL(fileURLWithPath: folder).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return URL(fileURLWithPath: folders[0]).appendingPathComponent(name)
    }

    public static func standard(cleanup: CleanupModel = s1Mini) -> EngineConfig {
        let support = supportDirectory
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Lucid")
        return EngineConfig(
            whisperServer: findBinary("whisper-server"),
            llamaServer: findBinary("llama-server"),
            modelsDirectory: support.appendingPathComponent("models"),
            logsDirectory: logs,
            supportDirectory: support,
            speechModel: defaultSpeechModel,
            cleanupModel: cleanup
        )
    }

    public var speechModelURL: URL { modelsDirectory.appendingPathComponent(speechModel) }
    public var cleanupModelURL: URL { modelsDirectory.appendingPathComponent(cleanupModel.fileName) }

    /// What is not installed, in words a person can act on. Empty when everything needed is present.
    public func missing(speech: Bool = true, cleanup: Bool = true) -> [String] {
        let files = FileManager.default
        var problems: [String] = []
        if speech {
            if !files.isExecutableFile(atPath: whisperServer.path) {
                problems.append("the speech engine, expected at \(whisperServer.path)")
            }
            if !files.fileExists(atPath: speechModelURL.path) {
                problems.append("the speech model, expected at \(speechModelURL.path)")
            }
        }
        if cleanup {
            if !files.isExecutableFile(atPath: llamaServer.path) {
                problems.append("the cleanup engine, expected at \(llamaServer.path)")
            }
            if !files.fileExists(atPath: cleanupModelURL.path) {
                problems.append("the cleanup model, expected at \(cleanupModelURL.path)")
            }
        }
        return problems
    }
}
```

**File:** `Sources/LucidEngines/ServerProcess.swift`

```swift
import Foundation

/// One helper process: a server binary listening on a local port.
///
/// A `Process` can only run once, so restarting an engine means creating a new `ServerProcess`.
public final class ServerProcess: @unchecked Sendable {
    public let name: String
    public let port: Int
    private let executable: URL
    private let arguments: [String]
    private let healthPath: String
    private let logURL: URL
    private let process = Process()
    private var launched = false

    /// `healthPath` is a path such as "/health" that answers 200 once the server is ready.
    public init(name: String, executable: URL, arguments: [String], port: Int, healthPath: String, logURL: URL) {
        self.name = name
        self.executable = executable
        self.arguments = arguments
        self.port = port
        self.healthPath = healthPath
        self.logURL = logURL
    }

    public var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }
    public var isRunning: Bool { launched && process.isRunning }
    public var processIdentifier: Int32 { process.processIdentifier }

    /// Launches the process. Its output goes to the log file, replacing any earlier log.
    public func start() throws {
        let files = FileManager.default
        try files.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        files.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)

        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = log
        process.standardError = log
        do {
            try process.run()
            launched = true
        } catch {
            throw EngineError.launchFailed("\(name): \(error.localizedDescription)")
        }
    }

    /// Waits until the server answers its health check with 200.
    public func waitUntilReady(timeout: TimeInterval) async throws {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(healthPath)")!)
        request.timeoutInterval = 2
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard isRunning else {
                throw EngineError.launchFailed("\(name) stopped during start-up. See \(logURL.path)")
            }
            if let (_, response) = try? await LocalHTTP.session.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                return
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        throw EngineError.notReady("\(name) did not answer within \(Int(timeout)) seconds. See \(logURL.path)")
    }

    /// Stops the process, forcefully if it has not exited within two seconds.
    public func stop() {
        guard isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning, Date() < deadline { usleep(50_000) }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
    }

    /// Asks the system for a free local port.
    public static func freePort() throws -> Int {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw EngineError.launchFailed("could not open a socket") }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)

        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, length) }
        }
        guard bound == 0 else { throw EngineError.launchFailed("could not reserve a local port") }

        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard named == 0 else { throw EngineError.launchFailed("could not read the reserved port") }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}
```

**File:** `Sources/LucidEngines/PidFile.swift`

```swift
import Foundation

/// Remembers the engine process IDs, so a later launch can stop engines left behind by a crash.
public enum PidFile {
    public static func write(_ pids: [Int32], to url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? JSONEncoder().encode(pids).write(to: url, options: .atomic)
    }

    public static func read(at url: URL) -> [Int32] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Int32].self, from: data)) ?? []
    }

    public static func remove(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Stops every recorded process that is still running one of the named programs, then
    /// removes the file. The name check matters: the system may have reused a PID for
    /// something unrelated.
    public static func killStale(at url: URL, names: Set<String>) {
        for pid in read(at: url) where pid > 0 {
            if let name = executableName(of: pid), names.contains(name) {
                kill(pid, SIGTERM)
            }
        }
        remove(at: url)
    }

    static func executableName(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buffer)).lastPathComponent
    }
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `scripts/test.sh Engines`
Expected: the last line is `PASSED  6 tests, 14 checks`.

- [ ] **Step 7: Commit**

```bash
git add Package.swift Sources/LucidEngines Tests/LucidCoreTests
git commit -m "Add LucidEngines: engine config, server processes and PID file"
git push origin main
```

---

### Task 6: Engine clients

**Files:**
- Create: `Sources/LucidEngines/WhisperClient.swift`, `Sources/LucidEngines/LlamaClient.swift`
- Create: `Tests/LucidCoreTests/ClientTests.swift`
- Modify: `Tests/LucidCoreTests/main.swift`

**Interfaces:**
- Consumes: `Transcriber`, `TextCleaner`, `CleanupRequest`, `CleanerError`, `ChatMessage`, `PromptBuilder.maxOutputTokens` from plan 1; `PromptStyle` from Task 1; `WAV.seconds`, `WhisperWindow.audioContext` from Task 3; `EngineError`, `LocalHTTP.session` from Task 5.
- Produces:
  - `public struct WhisperClient: Transcriber` with `init(baseURL: URL)`
  - `public static func WhisperClient.multipartBody(fields: [(String, String)], fileName: String, file: Data, boundary: String) -> Data`
  - `public static func WhisperClient.parseTranscript(_ data: Data) throws -> String`
  - `public struct LlamaClient: TextCleaner` with `init(baseURL: URL, style: PromptStyle)`
  - `public static func LlamaClient.requestBody(for request: CleanupRequest, style: PromptStyle) throws -> Data`
  - `public static func LlamaClient.parseReply(_ data: Data) throws -> String`

Behaviour:

- `WhisperClient` joins the line breaks the server puts between 30-second windows into spaces.
- `LlamaClient` throws `CleanerError.timeout` when the request times out, so the pipeline records the right fallback reason.
- `LlamaClient` treats a reply cut off by the token limit (`finish_reason` of `length`) as a failure. Otherwise half a sentence could be inserted.

- [ ] **Step 1: Write the failing tests**

**File:** `Tests/LucidCoreTests/ClientTests.swift`

```swift
import Foundation
import LucidCore
import LucidEngines

func clientTests() {
    suite("Clients") {
        test("builds a multipart body") {
            let body = WhisperClient.multipartBody(
                fields: [("temperature", "0.0"), ("prompt", "Glossary: Lucid.")],
                fileName: "audio.wav",
                file: Data([1, 2, 3]),
                boundary: "B"
            )
            let head = "--B\r\nContent-Disposition: form-data; name=\"temperature\"\r\n\r\n0.0\r\n"
                + "--B\r\nContent-Disposition: form-data; name=\"prompt\"\r\n\r\nGlossary: Lucid.\r\n"
                + "--B\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n"
                + "Content-Type: audio/wav\r\n\r\n"
            expectEqual(body, Data(head.utf8) + Data([1, 2, 3]) + Data("\r\n--B--\r\n".utf8))
        }

        test("reads a transcript and joins window breaks") {
            let reply = Data(#"{"text": " First part.\n Second part.\n"}"#.utf8)
            expectEqual(try WhisperClient.parseTranscript(reply), "First part. Second part.")
        }

        test("rejects a speech reply with no text") {
            expectThrows { try WhisperClient.parseTranscript(Data(#"{"error": "bad audio"}"#.utf8)) }
        }

        test("builds a chat request") {
            let request = CleanupRequest(transcript: "one two three", category: .chat)
            let data = try LlamaClient.requestBody(for: request, style: .s1)
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            expectEqual(object?["temperature"] as? Int, 0)
            expectEqual(object?["max_tokens"] as? Int, 54)
            expectEqual(object?["cache_prompt"] as? Bool, true)
            let messages = object?["messages"] as? [[String: String]]
            expectEqual(messages?.count, 2)
            expectEqual(
                messages?.last?["content"],
                "[Styling: semi-formal] [Structure: prose] [Context: general]\none two three"
            )
        }

        test("reads a chat reply") {
            let reply = Data(
                #"{"choices": [{"finish_reason": "stop", "message": {"role": "assistant", "content": "At 3."}}]}"#.utf8
            )
            expectEqual(try LlamaClient.parseReply(reply), "At 3.")
        }

        test("rejects a cut-off or unreadable chat reply") {
            let cutOff = #"{"choices": [{"finish_reason": "length", "message": {"role": "assistant", "content": "At"}}]}"#
            expectThrows { try LlamaClient.parseReply(Data(cutOff.utf8)) }
            expectThrows { try LlamaClient.parseReply(Data(#"{"choices": []}"#.utf8)) }
            expectThrows { try LlamaClient.parseReply(Data("not json".utf8)) }
        }
    }
}
```

**File:** `Tests/LucidCoreTests/main.swift`

```swift
import Foundation

TestRun.shared.filter = CommandLine.arguments.dropFirst().first

harnessTests()
rulesCleanerTests()
guardrailsTests()
dictionaryTests()
styleRulesTests()
promptBuilderTests()
audioTests()
await pipelineTests()
promptStyleTests()
await continuationTests()
whisperWindowTests()
evalCaseTests()
await engineTests()
clientTests()

TestRun.shared.finish()
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `scripts/test.sh Clients`
Expected: the build fails with `cannot find 'WhisperClient' in scope`.

- [ ] **Step 3: Write the speech client**

**File:** `Sources/LucidEngines/WhisperClient.swift`

```swift
import Foundation
import LucidCore

/// Speech recognition through a local `whisper-server`.
public struct WhisperClient: Transcriber {
    public let baseURL: URL

    public init(baseURL: URL) {
        self.baseURL = baseURL
    }

    public func transcribe(wav: Data, prompt: String) async throws -> String {
        // An unreadable header is treated as a long clip, which selects the safe full window.
        let seconds = WAV.seconds(of: wav) ?? 30
        var fields = [
            ("response_format", "json"),
            ("temperature", "0.0"),
            ("audio_ctx", String(WhisperWindow.audioContext(forSeconds: seconds))),
        ]
        if !prompt.isEmpty { fields.append(("prompt", prompt)) }

        let boundary = "lucid-\(UUID().uuidString)"
        var request = URLRequest(url: baseURL.appendingPathComponent("inference"))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.multipartBody(fields: fields, fileName: "audio.wav", file: wav, boundary: boundary)

        let (data, response) = try await LocalHTTP.session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw EngineError.badResponse("the speech engine answered with HTTP \(code)")
        }
        return try Self.parseTranscript(data)
    }

    public static func multipartBody(
        fields: [(String, String)],
        fileName: String,
        file: Data,
        boundary: String
    ) -> Data {
        var body = Data()
        for (name, value) in fields {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        body.append(Data((
            "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n"
            + "Content-Type: audio/wav\r\n\r\n"
        ).utf8))
        body.append(file)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }

    private struct Reply: Decodable {
        let text: String?
    }

    /// Reads the transcript from the server's JSON reply. The server puts a line break between
    /// 30-second windows; those are not paragraph breaks, so they become spaces.
    public static func parseTranscript(_ data: Data) throws -> String {
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data), let text = reply.text else {
            throw EngineError.badResponse("the speech engine sent a reply with no text")
        }
        return text
            .split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
```

- [ ] **Step 4: Write the cleanup client**

**File:** `Sources/LucidEngines/LlamaClient.swift`

```swift
import Foundation
import LucidCore

/// Transcript cleanup through a local `llama-server`.
public struct LlamaClient: TextCleaner {
    public let baseURL: URL
    public let style: PromptStyle

    public init(baseURL: URL, style: PromptStyle) {
        self.baseURL = baseURL
        self.style = style
    }

    public func clean(_ request: CleanupRequest, timeout: TimeInterval) async throws -> String {
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("v1/chat/completions"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = timeout
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try Self.requestBody(for: request, style: style)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await LocalHTTP.session.data(for: urlRequest)
        } catch let error as URLError where error.code == .timedOut {
            throw CleanerError.timeout
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw CleanerError.failed("the cleanup engine answered with HTTP \(code)")
        }
        return try Self.parseReply(data)
    }

    private struct ChatRequest: Encodable {
        let messages: [ChatMessage]
        let temperature: Double
        let max_tokens: Int
        let cache_prompt: Bool
    }

    private struct ChatReply: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String?
            }

            let message: Message
            let finish_reason: String?
        }

        let choices: [Choice]
    }

    public static func requestBody(for request: CleanupRequest, style: PromptStyle) throws -> Data {
        let words = request.transcript.split(whereSeparator: { $0 == " " || $0.isNewline }).count
        let body = ChatRequest(
            messages: style.messages(for: request),
            temperature: 0,
            max_tokens: PromptBuilder.maxOutputTokens(forWordCount: words),
            cache_prompt: true
        )
        return try JSONEncoder().encode(body)
    }

    public static func parseReply(_ data: Data) throws -> String {
        guard let reply = try? JSONDecoder().decode(ChatReply.self, from: data),
              let choice = reply.choices.first else {
            throw CleanerError.failed("the cleanup engine sent a reply that could not be read")
        }
        // A reply cut off by the token limit would be inserted half-finished.
        if choice.finish_reason == "length" {
            throw CleanerError.failed("the cleanup engine's reply was cut off")
        }
        return choice.message.content ?? ""
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `scripts/test.sh Clients`
Expected: the last line is `PASSED  6 tests, 12 checks`.

- [ ] **Step 6: Commit**

```bash
git add Sources/LucidEngines/WhisperClient.swift Sources/LucidEngines/LlamaClient.swift Tests/LucidCoreTests
git commit -m "Add whisper.cpp and llama.cpp HTTP clients"
git push origin main
```

---

## Tasks 7 to 9

Tasks 7 (engine supervisor, `lucid-cli` and the setup script), 8 (the cleanup test set) and 9 (the benchmark and model choice) are written into this plan once Tasks 1 to 6 are built, so that their code can rely on what the first six tasks confirmed.

