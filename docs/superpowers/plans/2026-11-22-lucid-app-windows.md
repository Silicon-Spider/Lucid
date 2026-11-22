# Lucid Settings, History and Setup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Lucid its windows: settings with a dictionary editor and a history of dictations, a setup checklist for first run, and a README that gets a new user from clone to first dictation.

**Architecture:** SwiftUI views hosted in ordinary AppKit windows, opened from the menu. Each view reads a small observable model. The models wrap things that already exist and are tested: `PersonalDictionary`, `HistoryStore`, `AppSettings`, `EngineManager` and `Permissions`.

**Tech Stack:** Swift 5.9, SwiftUI, AppKit, ServiceManagement (launch at login).

This is plan 3c, the last one. Plans 3a and 3b built the logic and the app it sits on.

Spec: [`docs/superpowers/specs/2026-11-22-lucid-dictation-design.md`](../specs/2026-11-22-lucid-dictation-design.md)

## Global Constraints

- Swift tools version 5.9, macOS 14 minimum, no Swift package dependencies.
- The app builds with `swift build` alone.
- The cleanup model is named in full, "S1-mini by Superwhisper", wherever a user sees it.
- Wording shown to the user is plain and says what to do next. No error codes.
- Every task ends with a commit pushed to `main` on `origin`.
- Every commit message ends with the line `Co-Authored-By: Claude Fable 5.2 <noreply@anthropic.com>`.

## How this plan is checked

| Checked by | What |
|---|---|
| `scripts/test.sh` | The dictionary editing rules. |
| `swift build` | Every view compiles. |
| `Lucid --render-ui <folder>` | Each settings tab and the setup checklist is drawn to a PNG with sample data, and looked at. |
| `Lucid --dump-menu` | The new menu items are present. |
| **A person, by hand** | Clicking through the windows. The checklist is in Task 4. |

## File Structure

```
README.md                                 what Lucid is and how to install and use it
Sources/LucidCore/
  PersonalDictionary.swift                adds editing helpers
Sources/Lucid/
  ViewModels.swift                        DictionaryModel, HistoryModel, SetupModel, LoginItem
  SettingsViews.swift                     the four settings tabs
  SetupView.swift                         the first-run checklist
  Windows.swift                           opens and reuses the two windows
  EngineManager.swift                     adds a preview constructor
  DictationController.swift               adds retry
  AppDelegate.swift                       adds the menu items and wires the windows
  UIRenderer.swift                        renders the new views
Tests/LucidCoreTests/
  DictionaryEditingTests.swift
```

Each code block below that is preceded by a `**File:**` line is the complete content of that file at the end of that step.

---

### Task 1: Dictionary editing rules

**Files:**
- Modify: `Sources/LucidCore/PersonalDictionary.swift` (add an extension at the end)
- Create: `Tests/LucidCoreTests/DictionaryEditingTests.swift`
- Modify: `Tests/LucidCoreTests/main.swift`

**Interfaces:**
- Consumes: `PersonalDictionary`, `Replacement` from plan 1.
- Produces, all on `PersonalDictionary`:
  - `@discardableResult public mutating func addTerm(_ term: String) -> Bool`
  - `public mutating func removeTerm(_ term: String)`
  - `@discardableResult public mutating func addReplacement(from: String, to: String) -> Bool`
  - `public mutating func removeReplacement(from: String)`

Rules:

- Entries are trimmed. A blank entry is refused, and the function returns false.
- A term that is already present, in any capitalisation, is refused.
- Adding a replacement for a phrase that already has one replaces it, so there is never more than one correction for the same misheard phrase.

- [ ] **Step 1: Write the failing tests**

**File:** `Tests/LucidCoreTests/DictionaryEditingTests.swift`

```swift
import LucidCore

func dictionaryEditingTests() {
    suite("DictionaryEditing") {
        test("adds a trimmed term once") {
            var dictionary = PersonalDictionary()
            expectTrue(dictionary.addTerm("  GitHub "))
            expectFalse(dictionary.addTerm("github"))
            expectFalse(dictionary.addTerm("   "))
            expectEqual(dictionary.terms, ["GitHub"])
        }

        test("removes a term") {
            var dictionary = PersonalDictionary(terms: ["GitHub", "Lucid"])
            dictionary.removeTerm("GitHub")
            expectEqual(dictionary.terms, ["Lucid"])
        }

        test("adds a replacement and refuses blanks") {
            var dictionary = PersonalDictionary()
            expectTrue(dictionary.addReplacement(from: " jon ", to: " John "))
            expectFalse(dictionary.addReplacement(from: "", to: "John"))
            expectFalse(dictionary.addReplacement(from: "jon", to: "  "))
            expectEqual(dictionary.replacements, [Replacement(from: "jon", to: "John")])
        }

        test("a new replacement for the same phrase replaces the old one") {
            var dictionary = PersonalDictionary(replacements: [
                Replacement(from: "jon", to: "John"),
                Replacement(from: "cube control", to: "kubectl"),
            ])
            expectTrue(dictionary.addReplacement(from: "Jon", to: "Jonathan"))
            expectEqual(dictionary.replacements, [
                Replacement(from: "cube control", to: "kubectl"),
                Replacement(from: "Jon", to: "Jonathan"),
            ])
        }

        test("removes a replacement") {
            var dictionary = PersonalDictionary(replacements: [Replacement(from: "jon", to: "John")])
            dictionary.removeReplacement(from: "jon")
            expectEqual(dictionary.replacements, [])
        }
    }
}
```

In `Tests/LucidCoreTests/main.swift`, add one line after `historyTests()`:

```swift
historyTests()
dictionaryEditingTests()
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `scripts/test.sh DictionaryEditing`
Expected: the build fails with `value of type 'PersonalDictionary' has no member 'addTerm'`.

- [ ] **Step 3: Add the editing helpers**

Append to `Sources/LucidCore/PersonalDictionary.swift`:

```swift

// MARK: Editing

extension PersonalDictionary {
    /// Adds a word to spell exactly. Returns false when it is blank or already present.
    @discardableResult
    public mutating func addTerm(_ term: String) -> Bool {
        let cleaned = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return false }
        guard !terms.contains(where: { $0.lowercased() == cleaned.lowercased() }) else { return false }
        terms.append(cleaned)
        return true
    }

    public mutating func removeTerm(_ term: String) {
        terms.removeAll { $0 == term }
    }

    /// Adds a "misheard → correct" pair. A pair for the same misheard phrase is replaced.
    /// Returns false when either side is blank.
    @discardableResult
    public mutating func addReplacement(from: String, to: String) -> Bool {
        let heard = from.trimmingCharacters(in: .whitespacesAndNewlines)
        let correct = to.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !heard.isEmpty, !correct.isEmpty else { return false }
        replacements.removeAll { $0.from.lowercased() == heard.lowercased() }
        replacements.append(Replacement(from: heard, to: correct))
        return true
    }

    public mutating func removeReplacement(from: String) {
        replacements.removeAll { $0.from == from }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `scripts/test.sh DictionaryEditing`
Expected: the last line is `PASSED  5 tests, 12 checks`.

- [ ] **Step 5: Commit**

```bash
git add Sources/LucidCore/PersonalDictionary.swift Tests/LucidCoreTests
git commit -m "Add dictionary editing rules"
git push origin main
```

---

### Task 2: View models, retry and the settings window

**Files:**
- Create: `Sources/Lucid/ViewModels.swift`, `Sources/Lucid/SettingsViews.swift`
- Modify: `Sources/Lucid/EngineManager.swift` (add a preview constructor)
- Modify: `Sources/Lucid/DictationController.swift` (add `retry`)

**Interfaces:**
- Consumes: `AppSettings`, `EngineManager`, `Permissions`, `TextInserter`, `PillController` from plan 3b; `PersonalDictionary` editing from Task 1; `HistoryStore`, `HistoryEntry` from plan 3a.
- Produces:
  - `@MainActor final class DictionaryModel: ObservableObject` with `init(url: URL = AppSettings.dictionaryURL)`, `@Published private(set) var dictionary`, `@Published private(set) var problem: String?`, `addTerm`, `removeTerm`, `addReplacement(from:to:)`, `removeReplacement(from:)`
  - `@MainActor final class HistoryModel: ObservableObject` with `init(store: HistoryStore)`, `@Published private(set) var entries`, `reload()`, `hasAudio(_:)`, `remove(_:)`, `clear()`
  - `@MainActor final class SetupModel: ObservableObject` with `@Published var microphone`, `accessibility`, `listening`, `fnConflict: Bool`, `var isListening: () -> Bool`, `start()`, `stop()`, `refresh()`
  - `enum LoginItem` with `static var isEnabled: Bool`, `static func set(_ enabled: Bool) throws`
  - `static func EngineManager.preview(_ status: Status) -> EngineManager`
  - `func DictationController.retry(_ entry: HistoryEntry) async`
  - `struct SettingsView: View` with `init(settings:engines:dictionary:history:onHotkey:onLevel:onRetry:)`
  - `struct GeneralTab`, `DictionaryTab`, `HistoryTab`, `AboutTab`, each a `View`

Design notes:

- **Dictionary.** If `dictionary.json` exists but cannot be read, the model loads nothing and refuses to save. Saving an empty dictionary over a file the user may have edited by hand would destroy it.
- **Medium.** Choosing Medium without the optional model installed leaves the level where it was and explains what to run.
- **Retry.** Runs the kept recording through the engines again and copies the result to the clipboard. It does not paste, because the user is in the history window, not in their document.
- **Launch at login** uses `SMAppService`. It only works when Lucid runs as an app bundle. If macOS refuses, the reason is shown under the switch.

- [ ] **Step 1: Write the view models**

**File:** `Sources/Lucid/ViewModels.swift`

```swift
import AVFoundation
import Foundation
import LucidCore
import LucidEngines
import ServiceManagement

/// The personal dictionary as the settings window sees it. Every change is saved at once.
@MainActor
final class DictionaryModel: ObservableObject {
    @Published private(set) var dictionary: PersonalDictionary
    /// A message for the user when the dictionary cannot be read or saved.
    @Published private(set) var problem: String?

    private let url: URL
    private let loadFailed: Bool

    init(url: URL = AppSettings.dictionaryURL) {
        self.url = url
        do {
            dictionary = try PersonalDictionary.load(from: url)
            problem = nil
            loadFailed = false
        } catch {
            dictionary = .empty
            problem = "The dictionary file could not be read, so it is not being used. "
                + "Fix or delete dictionary.json in Lucid's support folder, then reopen this window."
            loadFailed = true
        }
    }

    func addTerm(_ term: String) {
        if dictionary.addTerm(term) { save() }
    }

    func removeTerm(_ term: String) {
        dictionary.removeTerm(term)
        save()
    }

    func addReplacement(from: String, to: String) {
        if dictionary.addReplacement(from: from, to: to) { save() }
    }

    func removeReplacement(from: String) {
        dictionary.removeReplacement(from: from)
        save()
    }

    private func save() {
        // Never write over a file that could not be read: it may hold the user's own edits.
        guard !loadFailed else { return }
        do {
            try dictionary.save(to: url)
            problem = nil
        } catch {
            problem = "The dictionary could not be saved."
        }
    }
}

/// Past dictations as the settings window sees them.
@MainActor
final class HistoryModel: ObservableObject {
    @Published private(set) var entries: [HistoryEntry]
    private let store: HistoryStore

    init(store: HistoryStore) {
        self.store = store
        entries = store.entries
    }

    func reload() {
        entries = store.entries
    }

    func hasAudio(_ entry: HistoryEntry) -> Bool {
        store.audioURL(for: entry) != nil
    }

    func remove(_ entry: HistoryEntry) {
        store.remove(entry.id)
        reload()
    }

    func clear() {
        store.clear()
        reload()
    }
}

/// What Lucid still needs before it can work. Checked once a second while a window shows it.
@MainActor
final class SetupModel: ObservableObject {
    @Published var microphone = false
    @Published var accessibility = false
    /// True once the event tap is running, which is what makes the dictation key work.
    @Published var listening = false
    @Published var fnConflict = false

    /// Supplied by the app: whether the hotkey monitor is running.
    var isListening: () -> Bool = { false }
    private var timer: Timer?

    func start() {
        refresh()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        microphone = Permissions.microphone == .authorized
        accessibility = Permissions.accessibility
        listening = isListening()
        fnConflict = Permissions.fnKeyConflicts
    }
}

/// Whether Lucid opens when the user logs in.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
```

- [ ] **Step 2: Add a preview constructor to the engine manager**

In `Sources/Lucid/EngineManager.swift`, add this inside `final class EngineManager`, after `init`:

```swift

    /// A manager frozen in one state, for drawing views without starting any engine.
    static func preview(_ status: Status) -> EngineManager {
        let manager = EngineManager(level: .light, tracksProcesses: false)
        manager.status = status
        return manager
    }
```

- [ ] **Step 3: Add retry to the controller**

In `Sources/Lucid/DictationController.swift`, add this inside `final class DictationController`, after `process(samples:target:)`:

```swift

    /// Runs a kept recording through the engines again and copies the result. It does not
    /// paste, because the user is looking at their history, not at their document.
    func retry(_ entry: HistoryEntry) async {
        guard machine.state == .idle else { return }
        guard let url = history.audioURL(for: entry), let wav = try? Data(contentsOf: url) else {
            pill.flash("That recording is no longer kept")
            return
        }
        pill.show(.processing)
        let dictionary = (try? PersonalDictionary.load(from: AppSettings.dictionaryURL)) ?? .empty
        let context = PipelineContext(
            level: settings.level,
            category: AppCategory.forBundleID(entry.bundleID),
            dictionary: dictionary
        )
        do {
            let outcome = try await engines.dictate(wav: wav, context: context)
            history.remove(entry.id)
            history.add(
                HistoryEntry(
                    date: Date(),
                    appName: entry.appName,
                    bundleID: entry.bundleID,
                    audioSeconds: entry.audioSeconds,
                    speechMillis: outcome.speechMillis,
                    result: outcome.result,
                    failure: nil
                ),
                wav: wav
            )
            TextInserter.copy(outcome.result.finalText)
            pill.flash("Copied. Press ⌘V")
        } catch {
            pill.flash("Still couldn't transcribe that", seconds: 3)
        }
        onHistoryChange?()
    }
```

- [ ] **Step 4: Write the settings views**

**File:** `Sources/Lucid/SettingsViews.swift`

```swift
import LucidCore
import LucidEngines
import SwiftUI

/// The settings window: four tabs.
struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var engines: EngineManager
    @ObservedObject var dictionary: DictionaryModel
    @ObservedObject var history: HistoryModel
    let onHotkey: (HotkeyChoice) -> Void
    let onLevel: (CleanupLevel) -> Void
    let onRetry: (HistoryEntry) -> Void

    var body: some View {
        TabView {
            GeneralTab(settings: settings, engines: engines, onHotkey: onHotkey, onLevel: onLevel)
                .tabItem { Label("General", systemImage: "gearshape") }
            DictionaryTab(model: dictionary)
                .tabItem { Label("Dictionary", systemImage: "character.book.closed") }
            HistoryTab(model: history, onRetry: onRetry)
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
            AboutTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 560, height: 660)
    }
}

struct GeneralTab: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var engines: EngineManager
    let onHotkey: (HotkeyChoice) -> Void
    let onLevel: (CleanupLevel) -> Void

    @State private var opensAtLogin = LoginItem.isEnabled
    @State private var loginProblem: String?
    @State private var mediumRefused = false

    private var hotkey: Binding<HotkeyChoice> {
        Binding(
            get: { settings.hotkey },
            set: { choice in
                settings.hotkey = choice
                onHotkey(choice)
            }
        )
    }

    private var level: Binding<CleanupLevel> {
        Binding(
            get: { settings.level },
            set: { choice in
                if choice == .medium, !EngineManager.generalModelInstalled {
                    mediumRefused = true
                    return
                }
                mediumRefused = false
                settings.level = choice
                onLevel(choice)
            }
        )
    }

    private var loginSwitch: Binding<Bool> {
        Binding(
            get: { opensAtLogin },
            set: { wanted in
                do {
                    try LoginItem.set(wanted)
                    loginProblem = nil
                } catch {
                    loginProblem = "macOS would not change this: \(error.localizedDescription)"
                }
                opensAtLogin = LoginItem.isEnabled
            }
        )
    }

    private var levelNote: String {
        switch settings.level {
        case .off: return "Text is inserted exactly as you said it."
        case .light: return "Removes fillers such as “um”, false starts and corrections, and fixes punctuation. Every other word is kept."
        case .medium: return "Also tightens wordy phrasing. Slower, and uses a larger model."
        }
    }

    private var engineNote: String {
        switch engines.status {
        case .starting: return "Starting the engines…"
        case .ready: return "The engines are running on this Mac."
        case .setupNeeded: return "Setup is not finished. Open Setup Checklist from the menu."
        case .failed: return "The engines did not start. Open Setup Checklist from the menu."
        }
    }

    var body: some View {
        Form {
            Section("Dictation key") {
                Picker("Hold to dictate", selection: hotkey) {
                    ForEach(HotkeyChoice.allCases, id: \.self) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                Text("Hold the key and speak, then let go. Tap it twice to keep recording hands-free. Press Escape to cancel.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Cleanup") {
                Picker("Level", selection: level) {
                    Text("Off").tag(CleanupLevel.off)
                    Text("Light").tag(CleanupLevel.light)
                    Text("Medium").tag(CleanupLevel.medium)
                }
                .pickerStyle(.segmented)
                Text(levelNote)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if mediumRefused {
                    Text("Medium needs an optional 2.6 GB model. In Terminal, run scripts/setup.sh --with-general, then choose Medium again.")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }

            Section("Privacy") {
                Toggle("Keep recordings of recent dictations", isOn: $settings.keepRecordings)
                Text("The last 20 recordings stay on this Mac for 7 days, so a failed dictation can be retried. Nothing you say leaves your Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Startup") {
                Toggle("Open Lucid at login", isOn: loginSwitch)
                if let loginProblem {
                    Text(loginProblem)
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                Text(engineNote)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct DictionaryTab: View {
    @ObservedObject var model: DictionaryModel
    @State private var newTerm = ""
    @State private var heard = ""
    @State private var correct = ""

    private func addTerm() {
        model.addTerm(newTerm)
        newTerm = ""
    }

    private func addReplacement() {
        model.addReplacement(from: heard, to: correct)
        heard = ""
        correct = ""
    }

    private func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        Form {
            if let problem = model.problem {
                Section {
                    Text(problem).foregroundStyle(.orange)
                }
            }

            Section {
                ForEach(model.dictionary.terms, id: \.self) { term in
                    HStack {
                        Text(term)
                        Spacer()
                        Button {
                            model.removeTerm(term)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove \(term)")
                    }
                }
                HStack {
                    TextField("Word or name", text: $newTerm, prompt: Text("Add a word or name"))
                        .labelsHidden()
                        .onSubmit(addTerm)
                    Button("Add", action: addTerm)
                        .disabled(isBlank(newTerm))
                }
            } header: {
                Text("Words to spell exactly")
            } footer: {
                Text("Names, products and jargon, written the way you want them. For example: GitHub.")
            }

            Section {
                ForEach(model.dictionary.replacements, id: \.from) { pair in
                    HStack {
                        Text(pair.from)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        Text(pair.to)
                        Spacer()
                        Button {
                            model.removeReplacement(from: pair.from)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove this correction")
                    }
                }
                HStack {
                    TextField("Heard", text: $heard, prompt: Text("Lucid hears"))
                        .labelsHidden()
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    TextField("Write", text: $correct, prompt: Text("Write instead"))
                        .labelsHidden()
                        .onSubmit(addReplacement)
                    Button("Add", action: addReplacement)
                        .disabled(isBlank(heard) || isBlank(correct))
                }
            } header: {
                Text("Corrections")
            } footer: {
                Text("When Lucid keeps mishearing something, say what to write instead.")
            }
        }
        .formStyle(.grouped)
    }
}

struct HistoryTab: View {
    @ObservedObject var model: HistoryModel
    let onRetry: (HistoryEntry) -> Void
    @State private var confirmingClear = false

    var body: some View {
        VStack(spacing: 0) {
            if model.entries.isEmpty {
                ContentUnavailableView(
                    "No dictations yet",
                    systemImage: "waveform",
                    description: Text("Hold the dictation key and speak.")
                )
                .frame(maxHeight: .infinity)
            } else {
                List(model.entries) { entry in
                    HistoryRow(
                        entry: entry,
                        hasAudio: model.hasAudio(entry),
                        onRetry: { onRetry(entry) },
                        onDelete: { model.remove(entry) }
                    )
                    .padding(.vertical, 4)
                }
            }
            Divider()
            HStack {
                Text("Every dictation keeps its original wording.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear History…") { confirmingClear = true }
                    .disabled(model.entries.isEmpty)
            }
            .padding(10)
        }
        .confirmationDialog("Delete all history and recordings?", isPresented: $confirmingClear) {
            Button("Delete All", role: .destructive) { model.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry
    let hasAudio: Bool
    let onRetry: () -> Void
    let onDelete: () -> Void

    private var timing: String {
        guard let result = entry.result else { return "" }
        let total = Double(entry.speechMillis + result.cleanMillis) / 1000
        return String(format: "%.1f s", total)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(entry.date, format: .dateTime.day().month().hour().minute())
                Text("·")
                Text(entry.appName)
                Spacer()
                Text(timing)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let result = entry.result {
                Text(result.finalText)
                    .textSelection(.enabled)
                if result.raw != result.finalText {
                    Text("Original: \(result.raw)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            } else {
                Text("This dictation failed. \(entry.failure ?? "")")
                    .foregroundStyle(.orange)
            }

            HStack(spacing: 14) {
                if let result = entry.result {
                    Button("Copy") { TextInserter.copy(result.finalText) }
                    Button("Copy Original") { TextInserter.copy(result.raw) }
                }
                if hasAudio {
                    Button("Retry", action: onRetry)
                }
                Spacer()
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .help("Delete this dictation")
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
    }
}

struct AboutTab: View {
    var body: some View {
        Form {
            Section {
                LabeledContent("Version", value: SystemInfo.appVersion)
                Text("Lucid turns speech into clean text in any app. Everything runs on this Mac: no audio and no text is sent anywhere.")
                    .font(.callout)
            } header: {
                Text("Lucid")
            }

            Section {
                LabeledContent("Speech recognition", value: "Whisper large-v3-turbo")
                LabeledContent("Cleanup", value: "S1-mini by Superwhisper")
                LabeledContent("Cleanup at Medium", value: "Qwen 3.5 4B")
                LabeledContent("Engines", value: "whisper.cpp and llama.cpp")
            } header: {
                Text("Built with")
            } footer: {
                Text("Lucid is free software under the GNU General Public License, version 3.")
            }
        }
        .formStyle(.grouped)
    }
}
```

- [ ] **Step 5: Build**

Run: `swift build 2>&1 | grep -E "error|Build complete"`
Expected: `Build complete!` and no errors.

- [ ] **Step 6: Commit**

```bash
git add Sources/Lucid
git commit -m "Add settings views, their models and retry"
git push origin main
```

---

### Task 3: Setup checklist, windows and menu wiring

**Files:**
- Create: `Sources/Lucid/SetupView.swift`, `Sources/Lucid/Windows.swift`
- Modify: `Sources/Lucid/AppDelegate.swift`, `Sources/Lucid/UIRenderer.swift`

**Interfaces:**
- Consumes: everything from Task 2.
- Produces:
  - `struct SetupView: View` with `init(setup:engines:settings:onUseRightOption:onRestart:onDone:)`
  - `@MainActor final class Windows` with `show(_ kind: Kind, content: () -> AnyView)` and `enum Kind { case settings, setup }`
  - Menu items "Settings…" and "Setup Checklist…"
  - The setup checklist opens by itself on first launch, and stops doing so once the user presses Done.

The checklist has one row per thing Lucid needs. Each row says whether it is done, and if not, offers the one action that fixes it.

| Row | Done when | Action offered |
|---|---|---|
| Microphone | access is granted | Allow, or open Microphone settings if it was refused before |
| Accessibility | access is granted and the key is being listened for | Open Accessibility settings, or Restart Lucid |
| Engines and models | the engines are running | the command to run in Terminal |
| Fn key | Fn is not the dictation key, or macOS does nothing else with it | Open Keyboard settings, or use Right Option instead |

- [ ] **Step 1: Write the checklist**

**File:** `Sources/Lucid/SetupView.swift`

```swift
import AVFoundation
import LucidCore
import LucidEngines
import SwiftUI

/// The first-run checklist: what Lucid needs, and the one action that provides each thing.
struct SetupView: View {
    @ObservedObject var setup: SetupModel
    @ObservedObject var engines: EngineManager
    @ObservedObject var settings: AppSettings
    let onUseRightOption: () -> Void
    let onRestart: () -> Void
    let onDone: () -> Void

    private var enginesReady: Bool { engines.status == .ready }
    private var keyReady: Bool { setup.accessibility && setup.listening }
    private var fnReady: Bool { settings.hotkey != .fn || !setup.fnConflict }
    private var everythingReady: Bool { setup.microphone && keyReady && enginesReady && fnReady }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Set up Lucid")
                    .font(.title2.weight(.semibold))
                Text("Four things, then you can dictate into any app.")
                    .foregroundStyle(.secondary)
            }
            .padding(20)

            Divider()

            VStack(alignment: .leading, spacing: 18) {
                microphoneRow
                accessibilityRow
                enginesRow
                fnRow
            }
            .padding(20)

            Divider()

            HStack {
                Text(everythingReady ? "Ready. Hold \(settings.hotkey.title) and speak." : "Lucid will work once every item is ticked.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done", action: onDone)
            }
            .padding(20)
        }
        .frame(width: 540)
    }

    private var microphoneRow: some View {
        SetupRow(
            done: setup.microphone,
            title: "Microphone",
            detail: "So Lucid can hear you while you hold the dictation key."
        ) {
            if Permissions.microphone == .notDetermined {
                Button("Allow…") {
                    Task {
                        _ = await Permissions.requestMicrophone()
                        setup.refresh()
                    }
                }
            } else {
                Button("Open Microphone Settings…") { Permissions.openMicrophoneSettings() }
            }
        }
    }

    private var accessibilityRow: some View {
        SetupRow(
            done: keyReady,
            title: "Accessibility",
            detail: accessibilityDetail
        ) {
            if setup.accessibility {
                Button("Restart Lucid", action: onRestart)
            } else {
                Button("Open Accessibility Settings…") { Permissions.openAccessibilitySettings() }
            }
        }
    }

    private var accessibilityDetail: String {
        if keyReady { return "Lucid can see the dictation key and type the text for you." }
        if setup.accessibility {
            return "Access is granted, but macOS needs Lucid to restart before the key will work."
        }
        return "So Lucid can see the dictation key and type the text for you. Switch Lucid on in the list."
    }

    private var enginesRow: some View {
        SetupRow(done: enginesReady, title: "Speech engines and models", detail: enginesDetail) {
            if case .starting = engines.status {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var enginesDetail: String {
        switch engines.status {
        case .ready:
            return "Running on this Mac."
        case .starting:
            return "Starting. The first start can take a few seconds."
        case .setupNeeded(let missing):
            return "In Terminal, from the Lucid folder, run:  scripts/setup.sh\nThen quit and reopen Lucid. Missing: "
                + missing.joined(separator: "; ") + "."
        case .failed(let reason):
            return "The engines did not start. \(reason)"
        }
    }

    private var fnRow: some View {
        SetupRow(
            done: fnReady,
            title: "Dictation key: \(settings.hotkey.title)",
            detail: fnReady
                ? "Hold it and speak. Tap it twice for hands-free."
                : "macOS also does something when Fn is pressed. In Keyboard settings, set “Press 🌐 key to” to “Do Nothing”. Or use a different key."
        ) {
            if !fnReady {
                Button("Open Keyboard Settings…") { Permissions.openKeyboardSettings() }
                Button("Use Right Option Instead", action: onUseRightOption)
            }
        }
    }
}

/// One line of the checklist: a tick or an empty circle, what it is, and how to fix it.
private struct SetupRow<Actions: View>: View {
    let done: Bool
    let title: String
    let detail: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.title2)
                .foregroundStyle(done ? Color.green : Color.secondary)
                .accessibilityLabel(done ? "Done" : "Not done")
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !done {
                    HStack(spacing: 8) { actions() }
                }
            }
            Spacer(minLength: 0)
        }
    }
}
```

- [ ] **Step 2: Write the window manager**

**File:** `Sources/Lucid/Windows.swift`

```swift
import AppKit
import SwiftUI

/// Opens Lucid's windows, and brings an open one forward instead of making a second.
@MainActor
final class Windows: NSObject, NSWindowDelegate {
    enum Kind {
        case settings
        case setup

        var title: String {
            switch self {
            case .settings: return "Lucid Settings"
            case .setup: return "Set Up Lucid"
            }
        }
    }

    private var open: [Kind: NSWindow] = [:]
    /// Called when a window closes, so its owner can stop any polling it started.
    var onClose: ((Kind) -> Void)?

    func show(_ kind: Kind, content: () -> AnyView) {
        if let window = open[kind] {
            bringForward(window)
            return
        }
        let hosting = NSHostingController(rootView: content())
        let window = NSWindow(contentViewController: hosting)
        window.title = kind.title
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        open[kind] = window
        bringForward(window)
    }

    func close(_ kind: Kind) {
        open[kind]?.close()
    }

    private func bringForward(_ window: NSWindow) {
        // Lucid has no Dock icon, so it must be made active before its window can take focus.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let kind = open.first(where: { $0.value === window })?.key else { return }
        open[kind] = nil
        onClose?(kind)
    }
}
```

- [ ] **Step 3: Wire the windows into the app delegate**

In `Sources/Lucid/AppDelegate.swift`, make these four changes.

Add four properties after `private let quiet = ...`:

```swift
    private let windows = Windows()
    private let setup = SetupModel()
    private lazy var dictionaryModel = DictionaryModel()
    private lazy var historyModel = HistoryModel(store: history)
```

In `applicationDidFinishLaunching`, replace the line `startHotkeysWhenAllowed()` with:

```swift
        startHotkeysWhenAllowed()

        controller.onHistoryChange = { [weak self] in self?.historyModel.reload() }
        setup.isListening = { [weak self] in self?.hotkeys.isRunning ?? false }
        windows.onClose = { [weak self] kind in
            if kind == .setup { self?.setup.stop() }
        }
        if !quiet, !settings.onboardingDone { showSetup() }
```

In `menuNeedsUpdate`, replace the two lines that add the final separator and Quit item:

```swift
        menu.addItem(.separator())
        menu.addItem(actionItem("Quit Lucid", #selector(quit), key: "q"))
```

with:

```swift
        menu.addItem(.separator())
        menu.addItem(actionItem("Settings…", #selector(showSettings), key: ","))
        menu.addItem(actionItem("Setup Checklist…", #selector(showSetup)))
        menu.addItem(.separator())
        menu.addItem(actionItem("Quit Lucid", #selector(quit), key: "q"))
```

Add these methods after `copyLastOriginal()`:

```swift

    private func applyLevel(_ level: CleanupLevel) {
        Task { await engines.setLevel(level) }
    }

    private func applyHotkey(_ choice: HotkeyChoice) {
        hotkeys.hotkey = choice
    }

    @objc private func showSettings() {
        // The dictionary may have been edited by hand since the window was last open.
        dictionaryModel = DictionaryModel()
        historyModel.reload()
        windows.show(.settings) {
            AnyView(SettingsView(
                settings: settings,
                engines: engines,
                dictionary: dictionaryModel,
                history: historyModel,
                onHotkey: { [weak self] choice in self?.applyHotkey(choice) },
                onLevel: { [weak self] level in self?.applyLevel(level) },
                onRetry: { [weak self] entry in
                    Task { await self?.controller.retry(entry) }
                }
            ))
        }
    }

    @objc private func showSetup() {
        setup.start()
        windows.show(.setup) {
            AnyView(SetupView(
                setup: setup,
                engines: engines,
                settings: settings,
                onUseRightOption: { [weak self] in
                    self?.settings.hotkey = .rightOption
                    self?.applyHotkey(.rightOption)
                },
                onRestart: { [weak self] in self?.restart() },
                onDone: { [weak self] in
                    self?.settings.onboardingDone = true
                    self?.windows.close(.setup)
                }
            ))
        }
    }
```

Then simplify the two existing menu actions so there is one place that applies each setting. Replace the bodies of `chooseLevel` and `chooseHotkey`:

```swift
    @objc private func chooseLevel(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let level = CleanupLevel(rawValue: raw) else { return }
        settings.level = level
        applyLevel(level)
    }

    @objc private func chooseHotkey(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let choice = HotkeyChoice(rawValue: raw) else { return }
        settings.hotkey = choice
        applyHotkey(choice)
    }
```

- [ ] **Step 4: Render the new views**

In `Sources/Lucid/UIRenderer.swift`, replace the `for` loop in `render(into:)`:

```swift
            for (name, view) in pillViews() {
```

with:

```swift
            for (name, view) in pillViews() + windowViews() {
```

and add this method after `pillViews()`:

```swift

    /// The settings tabs and the setup checklist, filled with sample data.
    @MainActor
    private static func windowViews() -> [(String, AnyView)] {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lucid-render-\(UUID().uuidString)")
        let settings = AppSettings(defaults: UserDefaults(suiteName: "lucid-render-\(UUID().uuidString)") ?? .standard)

        var sample = PersonalDictionary()
        sample.addTerm("GitHub")
        sample.addTerm("Kubernetes")
        sample.addReplacement(from: "jon", to: "John")
        let dictionaryURL = folder.appendingPathComponent("dictionary.json")
        try? sample.save(to: dictionaryURL)

        let store = HistoryStore(directory: folder)
        store.add(
            HistoryEntry(
                date: Date(timeIntervalSince1970: 1_795_000_000),
                appName: "Mail",
                bundleID: "com.apple.mail",
                audioSeconds: 4,
                speechMillis: 0,
                result: nil,
                failure: "The speech engine was not running."
            ),
            wav: Data([0])
        )
        store.add(
            HistoryEntry(
                date: Date(timeIntervalSince1970: 1_795_000_600),
                appName: "Notes",
                bundleID: "com.apple.Notes",
                audioSeconds: 7.2,
                speechMillis: 580,
                result: PipelineResult(
                    raw: "Um, so I was thinking we could, uh, meet at 2. Actually no, make that 3, at the usual place.",
                    rulesText: "So I was thinking we could meet at 2. Actually no, make that 3, at the usual place.",
                    finalText: "So I was thinking we could meet at 3 at the usual place.",
                    llmAttempted: true,
                    llmUsed: true,
                    fallback: nil,
                    rejectedReply: nil,
                    cleanMillis: 170
                ),
                failure: nil
            ),
            wav: nil
        )

        func setup(done: Bool) -> SetupModel {
            let model = SetupModel()
            model.microphone = done
            model.accessibility = done
            model.listening = done
            model.fnConflict = !done
            return model
        }
        func checklist(done: Bool) -> AnyView {
            AnyView(SetupView(
                setup: setup(done: done),
                engines: EngineManager.preview(done ? .ready : .setupNeeded(["the cleanup model, expected at ~/Library/Application Support/Lucid/models/s1-mini-q4_k_m.gguf"])),
                settings: settings,
                onUseRightOption: {},
                onRestart: {},
                onDone: {}
            ))
        }
        func tab(_ view: some View) -> AnyView {
            AnyView(view.frame(width: 560, height: 620))
        }

        let engines = EngineManager.preview(.ready)
        return [
            ("settings-general", tab(GeneralTab(settings: settings, engines: engines, onHotkey: { _ in }, onLevel: { _ in }))),
            ("settings-dictionary", tab(DictionaryTab(model: DictionaryModel(url: dictionaryURL)))),
            ("settings-history", tab(HistoryTab(model: HistoryModel(store: store), onRetry: { _ in }))),
            ("settings-about", tab(AboutTab())),
            ("setup-to-do", checklist(done: false)),
            ("setup-done", checklist(done: true)),
        ]
    }
```

Add `import LucidCore` and `import LucidEngines` at the top of `UIRenderer.swift`, after `import AppKit`.

- [ ] **Step 5: Build and render**

Run: `swift build 2>&1 | grep -E "error|Build complete" && swift run Lucid --render-ui /tmp/lucid-ui`
Expected: `Build complete!`, then eleven `wrote ....png` lines.

Open each new PNG and check that:

- nothing is clipped or overlapping, and all text is readable;
- the General tab shows the key picker, the three cleanup levels, the two switches and their notes;
- the Dictionary tab shows GitHub and Kubernetes, the jon to John correction, and the two add rows;
- the History tab shows the cleaned sentence with its original underneath, and the failed dictation with a Retry button;
- the unfinished checklist has four empty circles, each with an action;
- the finished checklist has four green ticks and no action buttons.

- [ ] **Step 6: Check the menu and that nothing regressed**

Run: `swift run Lucid --dump-menu | tail -5 && scripts/test.sh 2>&1 | tail -1`
Expected: the last five menu lines are a separator, `Settings…`, `Setup Checklist…`, a separator and `Quit Lucid`. Then `PASSED  134 tests, 392 checks`.

- [ ] **Step 7: Commit**

```bash
git add Sources/Lucid
git commit -m "Add the setup checklist, the settings window and their menu items"
git push origin main
```

---

### Task 4: README and final check

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: everything.
- Produces: the README, and a rebuilt `dist/Lucid.app` checked one last time.

- [ ] **Step 1: Write the README**

**File:** `README.md`

````markdown
# Lucid

Hold a key, speak, let go. Clean text appears where your cursor is, in any Mac app.

Lucid removes the "um"s, the false starts and the "no wait, I meant…" before the text
lands, so what you get reads as if you had typed it. Everything runs on your Mac. No
audio and no text is sent anywhere.

| You say | Lucid writes |
|---|---|
| "Um, so I was thinking we could, uh, meet at two, actually no, make that three, at the usual place." | So I was thinking we could meet at 3 at the usual place. |
| "What is the capital of France, and, um, what is its population?" | What is the capital of France, and what is its population? |

The second row matters: Lucid cleans a dictated question. It never answers it.

## Status

This is a first version. The speech and cleanup pipeline is tested and measured, with
results in [`docs/benchmarks.md`](docs/benchmarks.md). The parts that need a person at
the keyboard (the dictation key, the microphone, pasting) were built carefully but have
only been checked by hand-run steps, listed under [Check it works](#check-it-works).

## Requirements

- A Mac with Apple Silicon, running macOS 14 or later.
- [Homebrew](https://brew.sh).
- The Swift compiler. `xcode-select --install` provides it. Xcode is not needed.
- About 1.1 GB of disk for the models, and about 2.5 GB of memory while Lucid runs.

## Install

```bash
git clone https://github.com/Silicon-Spider/Lucid.git
cd Lucid
scripts/setup.sh        # installs the engines, downloads the models (about 1 GB)
scripts/build-app.sh    # builds dist/Lucid.app
open dist/Lucid.app
```

A waveform icon appears in the menu bar, and a setup checklist opens. It walks you through
four things:

1. **Microphone.** Allow it when asked.
2. **Accessibility.** Switch Lucid on in System Settings, Privacy & Security,
   Accessibility. Lucid needs this to see the dictation key and to type for you. If the
   checklist then offers Restart Lucid, press it.
3. **Speech engines and models.** Ticked once `scripts/setup.sh` has run.
4. **The dictation key.** On a MacBook this is Fn. macOS also uses Fn for its own
   shortcut, so set "Press 🌐 key to" to "Do Nothing" in Keyboard settings, or choose
   Right Option in the checklist.

To keep Lucid, move `dist/Lucid.app` to your Applications folder.

**After rebuilding.** The app is signed locally, and macOS ties the Accessibility grant
to the exact build. After running `scripts/build-app.sh` again, switch Lucid off and on
in the Accessibility list.

## Use

| Do this | To |
|---|---|
| Hold the dictation key, speak, let go | Dictate |
| Tap the key twice | Keep recording hands-free. Press the key once to finish. |
| Press Escape while recording | Cancel |
| Say "new line" or "new paragraph" as its own phrase | Start a new line or paragraph |

A small pill at the bottom of the screen shows bars while it listens and dots while it
works. If there is nowhere to type, the text is left on the clipboard and the pill says so.

### Cleanup levels

Choose one from the menu or in Settings.

| Level | What it does |
|---|---|
| Off | Inserts exactly what you said. |
| Light (default) | Removes fillers, false starts and corrections. Fixes punctuation. Formats spoken lists. Keeps every other word. |
| Medium | Also tightens wordy phrasing. Slower. Needs an extra 2.6 GB model: `scripts/setup.sh --with-general`. |

Lucid also adapts to where you are typing. In chat apps a short message loses its closing
full stop. In terminals, editors and AI chat apps it does not format lists.

### Your words

In Settings, Dictionary:

- **Words to spell exactly**: names, products and jargon, such as GitHub.
- **Corrections**: when Lucid keeps mishearing something, say what to write instead.

### History

Settings, History lists your dictations. Each one keeps its original wording, so you can
always get back what you actually said. A dictation that failed can be retried from its
recording. The last 20 recordings are kept for 7 days. You can switch that off in
Settings.

## How it works

```
hold key ─▶ record ─▶ Whisper (speech to text) ─▶ rules ─▶ S1-mini (cleanup)
                                                              │
                         paste at cursor ◀─ your dictionary ◀─ guardrails
```

1. **Speech to text.** Whisper large-v3-turbo, run by whisper.cpp.
2. **Rules.** Instant, exact edits: plain fillers, stutters, spoken line breaks.
3. **Cleanup.** S1-mini by Superwhisper, a small model trained for exactly this job, run
   by llama.cpp.
4. **Guardrails.** Lucid checks the model's work. If it added words, answered a question,
   or dropped part of what you said, its reply is thrown away and the rules output is
   used instead. A dictation is never lost.

Measured on an M4 MacBook Air: about 0.6 s for a short phrase and about 1 s for a
14-second dictation, from letting go of the key to seeing the text. Dictations longer
than about 30 seconds take over 3 s.

The design draws on how Wispr Flow and Google's Rambler work. The research is in
[`docs/research.md`](docs/research.md) and the full design in
[`docs/superpowers/specs`](docs/superpowers/specs).

## Command line

`lucid-cli` runs the same pipeline without the app:

```bash
swift run lucid-cli doctor                         # are the engines and models installed?
swift run lucid-cli clean "um, so, like, hello"    # clean up some text
swift run lucid-cli dictate recording.wav          # audio to clean text, with timings
swift run lucid-cli eval                           # run the cleanup test set
```

Audio files must be 16 kHz mono 16-bit WAV.

## Check it works

```bash
scripts/test.sh           # unit tests
scripts/integration.sh    # the whole pipeline on synthesised speech
```

Then by hand, with Lucid running:

1. Open Notes. Hold the key and say "Um, so let's meet at two, actually three". Let go.
   "So let's meet at 3." appears.
2. Type a word with no space after it, then dictate. A space is added first.
3. Hold the key and press Escape. Nothing is inserted.
4. Tap the key twice, speak, then press it once. The text appears.
5. Hold the key and say nothing. The pill says "Didn't catch that".
6. Click the Desktop, then dictate. The pill says "Copied. Press ⌘V".
7. Quit Lucid. `pgrep -f "whisper-server|llama-server"` prints nothing.

## Troubleshooting

| Problem | Try |
|---|---|
| The key does nothing | Open Setup Checklist from the menu. Accessibility is the usual cause, especially after a rebuild. |
| Holding Fn opens the emoji picker or changes keyboard | Set "Press 🌐 key to" to "Do Nothing" in Keyboard settings, or switch to Right Option. |
| The menu says "Setup needed" | Run `scripts/setup.sh`, then quit and reopen Lucid. |
| The first word is cut off | The microphone takes a moment to start. Pause briefly after pressing the key. |
| Text goes to the clipboard instead of being typed | The focused control is not a text field, or it is a password field. Press ⌘V where you want it. |
| Something else | Engine logs are in `~/Library/Logs/Lucid/`. They never contain what you said. |

## Limits

- English only.
- Lucid uses the Mac's default microphone. Change it in System Settings, Sound.
- Pasting uses ⌘V, so it assumes a keyboard layout where that works.
- Speech recognition was measured with synthesised speech, not a range of real voices and
  rooms. See [`docs/benchmarks.md`](docs/benchmarks.md) for what was and was not tested.

## Credits and licence

Lucid is free software under the [GNU General Public License, version 3](LICENSE).

It is built on:

- [whisper.cpp](https://github.com/ggml-org/whisper.cpp) and OpenAI's Whisper large-v3-turbo, for speech recognition.
- [llama.cpp](https://github.com/ggml-org/llama.cpp), for running the cleanup models.
- [S1-mini by Superwhisper](https://huggingface.co/superwhisper/s1-mini-GGUF), the cleanup model.
- [Qwen 3.5 4B](https://huggingface.co/unsloth/Qwen3.5-4B-GGUF), the optional model for the Medium level.

The models are downloaded by `scripts/setup.sh` and are not part of this repository. Each
has its own licence.
````

- [ ] **Step 2: Run every check**

```bash
scripts/test.sh 2>&1 | tail -1
swift build -c release 2>&1 | grep -E "error|Build complete"
scripts/integration.sh 2>&1 | grep -E "cleaned|timing"
scripts/build-app.sh | tail -1
```

Expected: `PASSED  134 tests, 392 checks`, `Build complete!`, four `cleaned` lines with four `timing` lines, and `Built dist/Lucid.app (version 0.1.0)`.

- [ ] **Step 3: Launch the bundle once more**

```bash
open dist/Lucid.app --args --no-prompts
sleep 8
pgrep -x Lucid && pgrep -f "whisper-server|llama-server" | wc -l
kill "$(pgrep -x Lucid)"; sleep 4
pgrep -f "whisper-server|llama-server"; echo "exit $?"
```

Expected: a process ID, then `2`, then nothing and `exit 1`.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "Write the README"
git push origin main
```

- [ ] **Step 5: Manual check, by the person at the Mac**

1. `open dist/Lucid.app`. The setup checklist opens by itself.
2. Work down the checklist until all four rows are ticked, then press Done. It does not open again on the next launch.
3. Menu, Settings…. The window opens in front of other apps.
4. General: change the dictation key. The new key starts a dictation and the old one does not.
5. Dictionary: add a correction, such as "jon" to "John". Dictate "ask jon". "John" is written.
6. History: the dictations are listed, with the original under each cleaned one. Copy Original puts the uncleaned text on the clipboard.
7. Switch on "Open Lucid at login". Either it stays on, or a reason appears under it.

---

## Spec coverage

| Spec section | Where it is implemented |
|---|---|
| 5, Menu and Settings: the settings window and its tabs | Task 2 |
| 2, personal dictionary editor | Tasks 1 and 2 |
| 2, history that keeps the original transcript; retry of a failed dictation | Task 2 |
| 2, first-run permissions onboarding | Task 3 |
| 9, missing permissions, missing engines, Fn bound to a system action | Task 3, the checklist |
| 12, build step 6: onboarding, launch at login, README | Tasks 2, 3 and 4 |

Difference from the spec: the General tab has no microphone picker. Lucid records the system's default input, and the README says where to change it.
