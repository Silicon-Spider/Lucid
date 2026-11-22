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
