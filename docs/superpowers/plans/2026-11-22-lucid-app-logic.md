# Lucid App Logic Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the parts of the menu-bar app that can be unit-tested without a screen, a keyboard or a microphone: the dictation state machine, the rules for joining dictated text to a document, the hotkey choices, and the history store.

**Architecture:** Four additions to `LucidCore`, each pure logic or plain file storage. The app in the next plan is then a thin layer that feeds these real key events, audio and windows.

**Tech Stack:** Swift 5.9, Foundation only.

This is plan 3a. Plan 3b builds the app on top of it. Plan 3c adds settings, history and onboarding screens.

Spec: [`docs/superpowers/specs/2026-11-22-lucid-dictation-design.md`](../specs/2026-11-22-lucid-dictation-design.md)

## Global Constraints

- Swift tools version 5.9, macOS 14 minimum, no Swift package dependencies.
- `LucidCore` imports Foundation only.
- Tests run with `scripts/test.sh`. Pass a suite name to run one suite.
- Every task ends with a commit pushed to `main` on `origin`.
- Every commit message ends with the line `Co-Authored-By: Claude Fable 5.2 <noreply@anthropic.com>`.

## File Structure

```
Sources/LucidCore/
  DictationMachine.swift       key events in, recording actions out
  Insertion.swift              how dictated text joins what is already there
  Hotkey.swift                 the hotkey choices and their key codes
  History.swift                HistoryEntry and HistoryStore
Tests/LucidCoreTests/
  DictationMachineTests.swift
  InsertionTests.swift
  HistoryTests.swift
```

Each code block below that is preceded by a `**File:**` line is the complete content of that file at the end of that step.

---

### Task 1: Dictation state machine

**Files:**
- Create: `Sources/LucidCore/DictationMachine.swift`
- Create: `Tests/LucidCoreTests/DictationMachineTests.swift`
- Modify: `Tests/LucidCoreTests/main.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `public struct DictationMachine` with `init(timing: Timing = Timing())`
  - `public enum DictationMachine.State { case idle, holding(startedAt:), tapPending(startedAt:releasedAt:), handsFree(startedAt:), processing }`
  - `public enum DictationMachine.Event { case hotkeyDown, hotkeyUp, otherKeyDown, escape, tick, finished }`
  - `public enum DictationMachine.Action { case startRecording, stopAndProcess, discard, enterHandsFree, busy }`
  - `public struct DictationMachine.Timing { var holdThreshold = 0.3; var doubleTapWindow = 0.4; var maxDuration = 600.0 }`
  - `public private(set) var state: State`
  - `public var isRecording: Bool`
  - `public mutating func handle(_ event: Event, at time: TimeInterval) -> [Action]`

The machine holds no timers and reads no clock. The caller passes the time of each event, and sends `tick` regularly while the machine is not idle. That makes every rule testable with made-up times.

Rules, from section 6 of the spec:

| State | Event | New state | Actions |
|---|---|---|---|
| idle | hotkey down | holding | start recording |
| holding | hotkey up, held 0.3 s or more | processing | stop and process |
| holding | hotkey up, held under 0.3 s | tapPending | none: keep recording |
| holding | another key, or Escape | idle | discard |
| tapPending | hotkey down | handsFree | enter hands-free |
| tapPending | 0.4 s pass, another key, or Escape | idle | discard |
| handsFree | hotkey down | processing | stop and process |
| handsFree | Escape | idle | discard |
| holding, handsFree | 600 s since recording began | processing | stop and process |
| processing | hotkey down | processing | busy |
| processing | finished | idle | none |

Anything not listed changes nothing. In particular, releasing the hotkey in hands-free mode does nothing, because that release belongs to the second tap.

- [ ] **Step 1: Write the failing tests**

**File:** `Tests/LucidCoreTests/DictationMachineTests.swift`

```swift
import LucidCore

func dictationMachineTests() {
    suite("DictationMachine") {
        test("hold and release dictates") {
            var machine = DictationMachine()
            expectEqual(machine.handle(.hotkeyDown, at: 10.0), [.startRecording])
            expectEqual(machine.state, .holding(startedAt: 10.0))
            expectTrue(machine.isRecording)
            expectEqual(machine.handle(.hotkeyUp, at: 12.0), [.stopAndProcess])
            expectEqual(machine.state, .processing)
            expectFalse(machine.isRecording)
            expectEqual(machine.handle(.finished, at: 13.0), [])
            expectEqual(machine.state, .idle)
        }

        test("a quick tap is discarded if no second press follows") {
            var machine = DictationMachine()
            _ = machine.handle(.hotkeyDown, at: 10.0)
            expectEqual(machine.handle(.hotkeyUp, at: 10.1), [])
            expectEqual(machine.state, .tapPending(startedAt: 10.0, releasedAt: 10.1))
            expectTrue(machine.isRecording)
            expectEqual(machine.handle(.tick, at: 10.3), [])
            expectEqual(machine.handle(.tick, at: 10.5), [.discard])
            expectEqual(machine.state, .idle)
        }

        test("a double tap enters hands-free, and the next press ends it") {
            var machine = DictationMachine()
            _ = machine.handle(.hotkeyDown, at: 10.0)
            _ = machine.handle(.hotkeyUp, at: 10.1)
            expectEqual(machine.handle(.hotkeyDown, at: 10.3), [.enterHandsFree])
            expectEqual(machine.state, .handsFree(startedAt: 10.0))
            expectEqual(machine.handle(.hotkeyUp, at: 10.4), [])
            expectEqual(machine.handle(.otherKeyDown, at: 12.0), [])
            expectEqual(machine.state, .handsFree(startedAt: 10.0))
            expectEqual(machine.handle(.hotkeyDown, at: 30.0), [.stopAndProcess])
            expectEqual(machine.state, .processing)
        }

        test("another key while holding means the hotkey was a modifier") {
            var machine = DictationMachine()
            _ = machine.handle(.hotkeyDown, at: 10.0)
            expectEqual(machine.handle(.otherKeyDown, at: 10.5), [.discard])
            expectEqual(machine.state, .idle)
            expectEqual(machine.handle(.hotkeyUp, at: 11.0), [])
            expectEqual(machine.state, .idle)
        }

        test("escape discards in every recording state") {
            var holding = DictationMachine()
            _ = holding.handle(.hotkeyDown, at: 1.0)
            expectEqual(holding.handle(.escape, at: 2.0), [.discard])
            expectEqual(holding.state, .idle)

            var pending = DictationMachine()
            _ = pending.handle(.hotkeyDown, at: 1.0)
            _ = pending.handle(.hotkeyUp, at: 1.1)
            expectEqual(pending.handle(.escape, at: 1.2), [.discard])

            var handsFree = DictationMachine()
            _ = handsFree.handle(.hotkeyDown, at: 1.0)
            _ = handsFree.handle(.hotkeyUp, at: 1.1)
            _ = handsFree.handle(.hotkeyDown, at: 1.2)
            expectEqual(handsFree.handle(.escape, at: 5.0), [.discard])
            expectEqual(handsFree.state, .idle)
        }

        test("escape and other keys do nothing when idle") {
            var machine = DictationMachine()
            expectEqual(machine.handle(.escape, at: 1.0), [])
            expectEqual(machine.handle(.otherKeyDown, at: 1.0), [])
            expectEqual(machine.handle(.hotkeyUp, at: 1.0), [])
            expectEqual(machine.handle(.tick, at: 1.0), [])
            expectFalse(machine.isRecording)
        }

        test("a recording stops itself at the maximum length") {
            var holding = DictationMachine()
            _ = holding.handle(.hotkeyDown, at: 0)
            expectEqual(holding.handle(.tick, at: 599), [])
            expectEqual(holding.handle(.tick, at: 600), [.stopAndProcess])
            expectEqual(holding.state, .processing)

            var handsFree = DictationMachine()
            _ = handsFree.handle(.hotkeyDown, at: 0)
            _ = handsFree.handle(.hotkeyUp, at: 0.1)
            _ = handsFree.handle(.hotkeyDown, at: 0.2)
            expectEqual(handsFree.handle(.tick, at: 600), [.stopAndProcess])
        }

        test("the hotkey is ignored while processing") {
            var machine = DictationMachine()
            _ = machine.handle(.hotkeyDown, at: 0)
            _ = machine.handle(.hotkeyUp, at: 1)
            expectEqual(machine.handle(.hotkeyDown, at: 1.5), [.busy])
            expectEqual(machine.handle(.hotkeyUp, at: 1.6), [])
            expectEqual(machine.state, .processing)
            _ = machine.handle(.finished, at: 2)
            expectEqual(machine.handle(.hotkeyDown, at: 3), [.startRecording])
        }

        test("timing can be changed") {
            var timing = DictationMachine.Timing()
            timing.holdThreshold = 1.0
            var machine = DictationMachine(timing: timing)
            _ = machine.handle(.hotkeyDown, at: 0)
            expectEqual(machine.handle(.hotkeyUp, at: 0.5), [])
            expectEqual(machine.state, .tapPending(startedAt: 0, releasedAt: 0.5))
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
dictationMachineTests()

TestRun.shared.finish()
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `scripts/test.sh DictationMachine`
Expected: the build fails with `cannot find 'DictationMachine' in scope`.

- [ ] **Step 3: Write the state machine**

**File:** `Sources/LucidCore/DictationMachine.swift`

```swift
import Foundation

/// The dictation state machine: key events in, recording actions out.
///
/// It holds no timers and reads no clock. The caller passes the time of each event, and
/// sends `tick` regularly while the machine is not idle.
public struct DictationMachine: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case idle
        /// The hotkey is down and has not been released.
        case holding(startedAt: TimeInterval)
        /// The hotkey was tapped. A second press inside the window means hands-free.
        case tapPending(startedAt: TimeInterval, releasedAt: TimeInterval)
        /// Recording continues with no key held, until the hotkey is pressed again.
        case handsFree(startedAt: TimeInterval)
        case processing
    }

    public enum Event: Equatable, Sendable {
        case hotkeyDown
        case hotkeyUp
        /// Any key other than the hotkey and Escape.
        case otherKeyDown
        case escape
        case tick
        /// The dictation that was being processed has been inserted or abandoned.
        case finished
    }

    public enum Action: Equatable, Sendable {
        case startRecording
        case stopAndProcess
        /// Stop recording and throw the audio away.
        case discard
        case enterHandsFree
        /// The hotkey was pressed while the last dictation is still being processed.
        case busy
    }

    public struct Timing: Equatable, Sendable {
        /// A press shorter than this is a tap, not a dictation.
        public var holdThreshold: TimeInterval = 0.3
        /// How long after a tap a second press still counts as a double tap.
        public var doubleTapWindow: TimeInterval = 0.4
        /// A recording stops by itself after this long.
        public var maxDuration: TimeInterval = 600

        public init() {}
    }

    public private(set) var state: State = .idle
    public var timing: Timing

    public init(timing: Timing = Timing()) {
        self.timing = timing
    }

    /// True while audio is being recorded. This is when Escape belongs to Lucid.
    public var isRecording: Bool {
        switch state {
        case .holding, .tapPending, .handsFree: return true
        case .idle, .processing: return false
        }
    }

    /// Applies one event and returns what the caller should now do.
    public mutating func handle(_ event: Event, at time: TimeInterval) -> [Action] {
        switch (state, event) {
        case (.idle, .hotkeyDown):
            state = .holding(startedAt: time)
            return [.startRecording]

        case (.holding(let startedAt), .hotkeyUp):
            if time - startedAt >= timing.holdThreshold {
                state = .processing
                return [.stopAndProcess]
            }
            // Recording carries on, so nothing is lost if this turns out to be a double tap.
            state = .tapPending(startedAt: startedAt, releasedAt: time)
            return []

        case (.holding, .otherKeyDown), (.holding, .escape),
             (.tapPending, .otherKeyDown), (.tapPending, .escape),
             (.handsFree, .escape):
            state = .idle
            return [.discard]

        case (.tapPending(let startedAt, _), .hotkeyDown):
            state = .handsFree(startedAt: startedAt)
            return [.enterHandsFree]

        case (.tapPending(_, let releasedAt), .tick):
            if time - releasedAt >= timing.doubleTapWindow {
                state = .idle
                return [.discard]
            }
            return []

        case (.handsFree, .hotkeyDown):
            state = .processing
            return [.stopAndProcess]

        case (.holding(let startedAt), .tick), (.handsFree(let startedAt), .tick):
            if time - startedAt >= timing.maxDuration {
                state = .processing
                return [.stopAndProcess]
            }
            return []

        case (.processing, .hotkeyDown):
            return [.busy]

        case (.processing, .finished):
            state = .idle
            return []

        default:
            return []
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `scripts/test.sh DictationMachine`
Expected: the last line is `PASSED  9 tests, 45 checks`.

- [ ] **Step 5: Commit**

```bash
git add Sources/LucidCore/DictationMachine.swift Tests/LucidCoreTests
git commit -m "Add the dictation state machine"
git push origin main
```

---

### Task 2: Insertion rules and hotkey choices

**Files:**
- Create: `Sources/LucidCore/Insertion.swift`, `Sources/LucidCore/Hotkey.swift`
- Create: `Tests/LucidCoreTests/InsertionTests.swift`
- Modify: `Tests/LucidCoreTests/main.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `public static func InsertionPlanner.isMidSentence(before: String?) -> Bool`
  - `public static func InsertionPlanner.textToInsert(_ text: String, before: String?) -> String`
  - `public enum HotkeyChoice: String, Codable, CaseIterable { case fn, rightOption, rightCommand }`
  - `public var HotkeyChoice.keyCode: Int`, `public var HotkeyChoice.title: String`
  - `public static func HotkeyChoice.standard(forModelName name: String) -> HotkeyChoice`

`before` is the few characters just before the cursor in the app being dictated into, or `nil` when the app does not reveal them. An empty string means the cursor is at the very start.

| Before the cursor | Mid-sentence | Text inserted |
|---|---|---|
| unknown (`nil`) | no | unchanged |
| nothing (start of document) | no | unchanged |
| `"Hello world"` | yes | space added in front |
| `"Hello world "` | yes | unchanged |
| `"Done. "` | no | unchanged |
| `"Done."` | no | space added in front |
| `"Done.\n"` | no | unchanged |
| `"("` or an opening quote | yes | unchanged |

No space is added when the text itself starts with a line break or with closing punctuation.

The hotkey codes are the macOS virtual key codes for the modifier keys: 63 for Fn, 61 for Right Option, 54 for Right Command. Fn is the default on a MacBook, where the key is built in. Right Option is the default elsewhere, because many external keyboards do not report Fn to macOS.

- [ ] **Step 1: Write the failing tests**

**File:** `Tests/LucidCoreTests/InsertionTests.swift`

```swift
import LucidCore

func insertionTests() {
    suite("Insertion") {
        test("detects the middle of a sentence") {
            expectTrue(InsertionPlanner.isMidSentence(before: "Hello world"))
            expectTrue(InsertionPlanner.isMidSentence(before: "Hello world "))
            expectTrue(InsertionPlanner.isMidSentence(before: "first,"))
            expectTrue(InsertionPlanner.isMidSentence(before: "("))
        }

        test("detects the start of a sentence") {
            expectFalse(InsertionPlanner.isMidSentence(before: nil))
            expectFalse(InsertionPlanner.isMidSentence(before: ""))
            expectFalse(InsertionPlanner.isMidSentence(before: "Done. "))
            expectFalse(InsertionPlanner.isMidSentence(before: "Done."))
            expectFalse(InsertionPlanner.isMidSentence(before: "Really? "))
            expectFalse(InsertionPlanner.isMidSentence(before: "Done.\n"))
            expectFalse(InsertionPlanner.isMidSentence(before: "word\n"))
            expectFalse(InsertionPlanner.isMidSentence(before: "   "))
        }

        test("adds a space after a word or punctuation") {
            expectEqual(InsertionPlanner.textToInsert("and more", before: "Hello world"), " and more")
            expectEqual(InsertionPlanner.textToInsert("Next one.", before: "Done."), " Next one.")
        }

        test("adds no space where one is not wanted") {
            expectEqual(InsertionPlanner.textToInsert("Hello.", before: nil), "Hello.")
            expectEqual(InsertionPlanner.textToInsert("Hello.", before: ""), "Hello.")
            expectEqual(InsertionPlanner.textToInsert("and more", before: "Hello world "), "and more")
            expectEqual(InsertionPlanner.textToInsert("Hello.", before: "Done.\n"), "Hello.")
            expectEqual(InsertionPlanner.textToInsert("quoted", before: "("), "quoted")
            expectEqual(InsertionPlanner.textToInsert("quoted", before: "“"), "quoted")
            expectEqual(InsertionPlanner.textToInsert("\nNew line.", before: "Done."), "\nNew line.")
            expectEqual(InsertionPlanner.textToInsert(", and so on", before: "word"), ", and so on")
            expectEqual(InsertionPlanner.textToInsert("", before: "word"), "")
        }

        test("hotkey choices have key codes and titles") {
            expectEqual(HotkeyChoice.fn.keyCode, 63)
            expectEqual(HotkeyChoice.rightOption.keyCode, 61)
            expectEqual(HotkeyChoice.rightCommand.keyCode, 54)
            expectEqual(HotkeyChoice.allCases.map(\.title), ["Fn (Globe)", "Right Option", "Right Command"])
        }

        test("the default hotkey depends on the kind of Mac") {
            expectEqual(HotkeyChoice.standard(forModelName: "MacBook Air"), .fn)
            expectEqual(HotkeyChoice.standard(forModelName: "MacBook Pro"), .fn)
            expectEqual(HotkeyChoice.standard(forModelName: "Mac mini"), .rightOption)
            expectEqual(HotkeyChoice.standard(forModelName: ""), .rightOption)
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
dictationMachineTests()
insertionTests()

TestRun.shared.finish()
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `scripts/test.sh Insertion`
Expected: the build fails with `cannot find 'InsertionPlanner' in scope`.

- [ ] **Step 3: Write the insertion rules**

**File:** `Sources/LucidCore/Insertion.swift`

```swift
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
```

- [ ] **Step 4: Write the hotkey choices**

**File:** `Sources/LucidCore/Hotkey.swift`

```swift
import Foundation

/// The keys that can start a dictation. All are modifier keys, so holding one types nothing.
public enum HotkeyChoice: String, Codable, CaseIterable, Sendable {
    case fn
    case rightOption
    case rightCommand

    /// The macOS virtual key code reported when this key goes down or up.
    public var keyCode: Int {
        switch self {
        case .fn: return 63
        case .rightOption: return 61
        case .rightCommand: return 54
        }
    }

    public var title: String {
        switch self {
        case .fn: return "Fn (Globe)"
        case .rightOption: return "Right Option"
        case .rightCommand: return "Right Command"
        }
    }

    /// Fn on a MacBook, where the key is built in. Right Option elsewhere, because many
    /// external keyboards do not report Fn to macOS.
    public static func standard(forModelName name: String) -> HotkeyChoice {
        name.contains("MacBook") ? .fn : .rightOption
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `scripts/test.sh Insertion`
Expected: the last line is `PASSED  6 tests, 31 checks`.

- [ ] **Step 6: Commit**

```bash
git add Sources/LucidCore/Insertion.swift Sources/LucidCore/Hotkey.swift Tests/LucidCoreTests
git commit -m "Add insertion rules and hotkey choices"
git push origin main
```

---

### Task 3: History store

**Files:**
- Create: `Sources/LucidCore/History.swift`
- Create: `Tests/LucidCoreTests/HistoryTests.swift`
- Modify: `Tests/LucidCoreTests/main.swift`

**Interfaces:**
- Consumes: `PipelineResult` from plan 1.
- Produces:
  - `public struct HistoryEntry: Codable, Equatable, Identifiable` with `id: UUID`, `date: Date`, `appName: String`, `bundleID: String?`, `audioSeconds: Double`, `speechMillis: Int`, `result: PipelineResult?`, `failure: String?`, `audioFile: String?`, and a memberwise `init` in that order where `id` defaults to a new UUID and `audioFile` to `nil`
  - `public final class HistoryStore` with `init(directory: URL)`
  - `public private(set) var entries: [HistoryEntry]` (newest first)
  - `public var limit = 200`, `public var audioLimit = 20`, `public var audioMaxAge: TimeInterval` (7 days)
  - `@discardableResult public func add(_ entry: HistoryEntry, wav: Data?, now: Date = Date()) -> HistoryEntry`
  - `public func audioURL(for entry: HistoryEntry) -> URL?`
  - `public func remove(_ id: UUID)`
  - `public func clear()`

Storage, from section 8 of the spec:

- `history.json` in the store's directory holds the newest 200 entries.
- `recordings/` holds the audio of the newest 20, and none older than 7 days. Passing `wav: nil` to `add` stores no audio, which is how the "keep recordings" setting is honoured.
- A failed dictation is recorded with `result` empty and `failure` set, and keeps its audio so it can be retried.
- The store is not thread-safe. The app uses it from the main thread only.

- [ ] **Step 1: Write the failing tests**

**File:** `Tests/LucidCoreTests/HistoryTests.swift`

```swift
import Foundation
import LucidCore

private func temporaryFolder() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("lucid-history-\(UUID().uuidString)")
}

private func result(_ text: String) -> PipelineResult {
    PipelineResult(
        raw: "um " + text,
        rulesText: text,
        finalText: text,
        llmAttempted: false,
        llmUsed: false,
        fallback: nil,
        rejectedReply: nil,
        cleanMillis: 5
    )
}

private func entry(_ text: String, at seconds: TimeInterval) -> HistoryEntry {
    HistoryEntry(
        date: Date(timeIntervalSince1970: seconds),
        appName: "Notes",
        bundleID: "com.apple.Notes",
        audioSeconds: 2.5,
        speechMillis: 500,
        result: result(text),
        failure: nil
    )
}

func historyTests() {
    suite("History") {
        test("keeps entries newest first and reloads them") {
            let folder = temporaryFolder()
            defer { try? FileManager.default.removeItem(at: folder) }

            let store = HistoryStore(directory: folder)
            expectEqual(store.entries, [])
            let first = store.add(entry("first", at: 1_000), wav: nil)
            let second = store.add(entry("second", at: 2_000), wav: nil)
            expectEqual(store.entries.map(\.id), [second.id, first.id])

            let reloaded = HistoryStore(directory: folder)
            expectEqual(reloaded.entries, store.entries)
            expectEqual(reloaded.entries.first?.result?.finalText, "second")
            expectEqual(reloaded.entries.first?.result?.raw, "um second")
        }

        test("trims to the limit") {
            let folder = temporaryFolder()
            defer { try? FileManager.default.removeItem(at: folder) }

            let store = HistoryStore(directory: folder)
            store.limit = 3
            for index in 0..<5 { store.add(entry("item \(index)", at: Double(index)), wav: nil) }
            expectEqual(store.entries.compactMap { $0.result?.finalText }, ["item 4", "item 3", "item 2"])
        }

        test("keeps audio only for the newest recordings") {
            let folder = temporaryFolder()
            defer { try? FileManager.default.removeItem(at: folder) }

            let store = HistoryStore(directory: folder)
            store.audioLimit = 2
            let now = Date(timeIntervalSince1970: 10_000)
            for index in 0..<4 {
                store.add(entry("item \(index)", at: 10_000 + Double(index)), wav: Data([UInt8(index)]), now: now)
            }
            let withAudio = store.entries.filter { store.audioURL(for: $0) != nil }
            expectEqual(withAudio.compactMap { $0.result?.finalText }, ["item 3", "item 2"])
            let files = try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("recordings").path)
            expectEqual(files.count, 2)
            if let url = store.audioURL(for: store.entries[0]) {
                expectEqual(try Data(contentsOf: url), Data([3]))
            } else {
                expectTrue(false, "the newest entry should have audio")
            }
        }

        test("drops audio older than the maximum age") {
            let folder = temporaryFolder()
            defer { try? FileManager.default.removeItem(at: folder) }

            let store = HistoryStore(directory: folder)
            let day: TimeInterval = 86_400
            let old = store.add(entry("old", at: 0), wav: Data([1]), now: Date(timeIntervalSince1970: 0))
            expectTrue(store.audioURL(for: old) != nil)
            store.add(entry("new", at: 8 * day), wav: Data([2]), now: Date(timeIntervalSince1970: 8 * day))
            let oldEntry = store.entries.first { $0.id == old.id }
            expectEqual(oldEntry?.audioFile, nil)
            expectEqual(store.entries.count, 2)
        }

        test("stores no audio when none is given") {
            let folder = temporaryFolder()
            defer { try? FileManager.default.removeItem(at: folder) }

            let store = HistoryStore(directory: folder)
            let saved = store.add(entry("quiet", at: 1), wav: nil)
            expectEqual(saved.audioFile, nil)
            expectEqual(store.audioURL(for: saved), nil)
        }

        test("records a failed dictation with its audio") {
            let folder = temporaryFolder()
            defer { try? FileManager.default.removeItem(at: folder) }

            let store = HistoryStore(directory: folder)
            let failed = HistoryEntry(
                date: Date(timeIntervalSince1970: 5),
                appName: "Mail",
                bundleID: "com.apple.mail",
                audioSeconds: 4,
                speechMillis: 0,
                result: nil,
                failure: "The speech engine is not running."
            )
            let saved = store.add(failed, wav: Data([9]), now: Date(timeIntervalSince1970: 5))
            expectTrue(store.audioURL(for: saved) != nil)
            let reloaded = HistoryStore(directory: folder)
            expectEqual(reloaded.entries.first?.failure, "The speech engine is not running.")
            expectEqual(reloaded.entries.first?.result, nil)
        }

        test("remove and clear delete audio too") {
            let folder = temporaryFolder()
            defer { try? FileManager.default.removeItem(at: folder) }

            let store = HistoryStore(directory: folder)
            let now = Date(timeIntervalSince1970: 100)
            let first = store.add(entry("first", at: 100), wav: Data([1]), now: now)
            store.add(entry("second", at: 101), wav: Data([2]), now: now)
            let recordings = folder.appendingPathComponent("recordings").path

            store.remove(first.id)
            expectEqual(store.entries.count, 1)
            expectEqual(try FileManager.default.contentsOfDirectory(atPath: recordings).count, 1)

            store.clear()
            expectEqual(store.entries, [])
            expectEqual(try FileManager.default.contentsOfDirectory(atPath: recordings).count, 0)
            expectEqual(HistoryStore(directory: folder).entries, [])
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
dictationMachineTests()
insertionTests()
historyTests()

TestRun.shared.finish()
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `scripts/test.sh History`
Expected: the build fails with `cannot find 'HistoryStore' in scope`.

- [ ] **Step 3: Make `PipelineResult` constructible outside its module**

`PipelineResult` has no public initialiser, and the tests above build one. In `Sources/LucidCore/Pipeline.swift`, add this inside `struct PipelineResult`, after the `cleanMillis` property:

```swift

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
```

- [ ] **Step 4: Write the history store**

**File:** `Sources/LucidCore/History.swift`

```swift
import Foundation

/// One past dictation. It keeps the original transcript, so nothing is ever lost to cleanup.
public struct HistoryEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var date: Date
    /// The app the text was dictated into.
    public var appName: String
    public var bundleID: String?
    public var audioSeconds: Double
    /// Time spent on speech recognition, in milliseconds.
    public var speechMillis: Int
    /// Nil when the dictation failed before any text was produced.
    public var result: PipelineResult?
    /// Why the dictation failed, in words for the user.
    public var failure: String?
    /// The file name of the kept recording, inside the store's `recordings` folder.
    public var audioFile: String?

    public init(
        id: UUID = UUID(),
        date: Date,
        appName: String,
        bundleID: String?,
        audioSeconds: Double,
        speechMillis: Int,
        result: PipelineResult?,
        failure: String?,
        audioFile: String? = nil
    ) {
        self.id = id
        self.date = date
        self.appName = appName
        self.bundleID = bundleID
        self.audioSeconds = audioSeconds
        self.speechMillis = speechMillis
        self.result = result
        self.failure = failure
        self.audioFile = audioFile
    }
}

/// The record of past dictations, stored as `history.json` with a `recordings` folder beside it.
///
/// Not thread-safe. Use it from one thread.
public final class HistoryStore {
    /// Newest first.
    public private(set) var entries: [HistoryEntry] = []
    public var limit = 200
    /// How many of the newest entries keep their audio.
    public var audioLimit = 20
    public var audioMaxAge: TimeInterval = 7 * 86_400

    private let directory: URL
    private var fileURL: URL { directory.appendingPathComponent("history.json") }
    private var recordingsURL: URL { directory.appendingPathComponent("recordings") }

    public init(directory: URL) {
        self.directory = directory
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        entries = (try? decoder.decode([HistoryEntry].self, from: data)) ?? []
    }

    /// Adds an entry at the front. Pass the recording as `wav` to keep it for a retry, or
    /// nil to keep no audio.
    @discardableResult
    public func add(_ entry: HistoryEntry, wav: Data?, now: Date = Date()) -> HistoryEntry {
        var saved = entry
        if let wav {
            let name = "\(entry.id.uuidString).wav"
            do {
                try FileManager.default.createDirectory(at: recordingsURL, withIntermediateDirectories: true)
                try wav.write(to: recordingsURL.appendingPathComponent(name), options: .atomic)
                saved.audioFile = name
            } catch {
                saved.audioFile = nil
            }
        }
        entries.insert(saved, at: 0)
        prune(now: now)
        save()
        return entries.first { $0.id == saved.id } ?? saved
    }

    public func audioURL(for entry: HistoryEntry) -> URL? {
        guard let name = entry.audioFile else { return nil }
        let url = recordingsURL.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public func remove(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        deleteAudio(of: entries[index])
        entries.remove(at: index)
        save()
    }

    public func clear() {
        for entry in entries { deleteAudio(of: entry) }
        entries = []
        save()
    }

    /// Applies the limits: at most `limit` entries, audio for at most `audioLimit` of the
    /// newest, and no audio older than `audioMaxAge`.
    private func prune(now: Date) {
        if entries.count > limit {
            for entry in entries[limit...] { deleteAudio(of: entry) }
            entries.removeSubrange(limit...)
        }
        var kept = 0
        for index in entries.indices where entries[index].audioFile != nil {
            let tooOld = now.timeIntervalSince(entries[index].date) > audioMaxAge
            if kept >= audioLimit || tooOld {
                deleteAudio(of: entries[index])
                entries[index].audioFile = nil
            } else {
                kept += 1
            }
        }
    }

    private func deleteAudio(of entry: HistoryEntry) {
        guard let name = entry.audioFile else { return }
        try? FileManager.default.removeItem(at: recordingsURL.appendingPathComponent(name))
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try encoder.encode(entries).write(to: fileURL, options: .atomic)
        } catch {
            // History is a convenience. Failing to save it must never interrupt a dictation.
        }
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `scripts/test.sh History`
Expected: the last line is `PASSED  7 tests, 22 checks`.

- [ ] **Step 6: Run the whole suite**

Run: `scripts/test.sh 2>&1 | tail -1 && swift build -c release 2>&1 | tail -1`
Expected: `PASSED  129 tests, 380 checks` and `Build complete!`.

- [ ] **Step 7: Commit**

```bash
git add Sources/LucidCore/History.swift Sources/LucidCore/Pipeline.swift Tests/LucidCoreTests
git commit -m "Add the history store"
git push origin main
```

---

## Spec coverage

| Spec section | Where it is implemented |
|---|---|
| 5, DictationController's state machine; 6, dictation flow | Task 1 |
| 5, HotkeyMonitor's key choices | Task 2 |
| 5, TextInserter's leading-space rule; 7, the mid-sentence flag | Task 2 |
| 5, HistoryStore; 8, `history.json` and `recordings/` | Task 3 |

Not in this plan, by design: everything that needs a screen, a keyboard or a microphone (plan 3b), and the settings, history and onboarding screens (plan 3c).
