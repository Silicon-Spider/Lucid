import LucidCore
import LucidEngines
import SwiftUI
import UniformTypeIdentifiers

/// The settings window: five tabs.
struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var engines: EngineManager
    @ObservedObject var models: ModelLibraryModel
    @ObservedObject var dictionary: DictionaryModel
    @ObservedObject var history: HistoryModel
    let onHotkey: (HotkeyChoice) -> Void
    let onLevel: (CleanupLevel) -> Void
    let onModels: (ModelChoices) -> Void
    let onRetry: (HistoryEntry) -> Void

    var body: some View {
        TabView {
            GeneralTab(settings: settings, engines: engines, onHotkey: onHotkey, onLevel: onLevel)
                .tabItem { Label("General", systemImage: "gearshape") }
            ModelsTab(settings: settings, engines: engines, library: models, onModels: onModels)
                .tabItem { Label("Models", systemImage: "cpu") }
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
                if choice == .medium, !EngineManager.mediumAvailable(for: settings.models) {
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
                    Text("Medium needs a larger model. Download Qwen 3.5 4B (2.6 GB) or add your own in the Models tab, then choose Medium again.")
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

struct ModelsTab: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var engines: EngineManager
    @ObservedObject var library: ModelLibraryModel
    let onModels: (ModelChoices) -> Void

    @State private var importing = false
    @State private var importKind = ModelKind.speech
    @State private var removing: InstalledModel?
    @State private var browsing = false

    private func choose(_ change: (inout ModelChoices) -> Void) {
        var choices = settings.models
        change(&choices)
        guard choices != settings.models else { return }
        settings.models = choices
        onModels(choices)
    }

    /// A picker's selection: shows `current`, and saves a new choice with `save`.
    private func selection(_ current: String, save: @escaping (inout ModelChoices, String) -> Void) -> Binding<String> {
        Binding(
            get: { current },
            set: { name in choose { save(&$0, name) } }
        )
    }

    private func startImport(_ kind: ModelKind) {
        importKind = kind
        importing = true
    }

    private func remove(_ model: InstalledModel) {
        guard library.remove(model) else { return }
        choose { $0.forget(model.fileName) }
    }

    /// What each model is used for, for its row in the list.
    private func uses(of model: InstalledModel, in plan: ModelPlan) -> [String] {
        var uses: [String] = []
        if model.fileName == plan.light.fileName { uses.append("Light") }
        if model.fileName == plan.medium?.fileName { uses.append("Medium") }
        return uses
    }

    private var engineNote: String {
        switch engines.status {
        case .starting: return "Loading the models. A large model can take a minute."
        case .ready: return "The engines are running with these models."
        case .setupNeeded(let missing):
            return "Setup is not finished. Missing: " + missing.joined(separator: "; ") + "."
        case .failed(let reason):
            return "The engines did not start with these models. Choose another model, or go back to Lucid's own. \(reason)"
        }
    }

    private var engineFailed: Bool {
        if case .failed = engines.status { return true }
        return false
    }

    var body: some View {
        let plan = library.plan(for: settings.models)
        let speechModels = library.models(.speech)
        let cleanupModels = library.models(.cleanup)
        let mediumModels = cleanupModels.filter { $0.style == .general }
        // Downloads started from the sheet, for models Lucid does not suggest.
        let otherDownloads = library.downloads.values
            .filter { ModelCatalog.suggestion(for: $0.remote.fileName) == nil }
            .sorted { $0.remote.fileName < $1.remote.fileName }

        Form {
            Section {
                Picker("Model", selection: selection(plan.speech) { $0.speech = $1 }) {
                    if !speechModels.contains(where: { $0.fileName == plan.speech }) {
                        Text("Not installed").tag(plan.speech)
                    }
                    ForEach(speechModels) { model in
                        Text(model.name).tag(model.fileName)
                    }
                }
            } header: {
                Text("Speech recognition")
            } footer: {
                Text("Whisper models for whisper.cpp, named like ggml-small.en.bin. Smaller models are faster but mishear more. Lucid listens for English.")
            }

            Section {
                Picker("Light", selection: selection(plan.light.fileName) { $0.light = $1 }) {
                    if !cleanupModels.contains(where: { $0.fileName == plan.light.fileName }) {
                        Text("Not installed").tag(plan.light.fileName)
                    }
                    ForEach(cleanupModels) { model in
                        Text(model.name).tag(model.fileName)
                    }
                }
                Picker("Medium", selection: selection(plan.medium?.fileName ?? "") { $0.medium = $1 }) {
                    if plan.medium == nil {
                        Text("None installed").tag("")
                    }
                    ForEach(mediumModels) { model in
                        Text(model.name).tag(model.fileName)
                    }
                }
                .disabled(mediumModels.isEmpty)
            } header: {
                Text("Cleanup")
            } footer: {
                Text("Medium needs a model that uses Lucid's prompt. If a model adds words, answers a question or drops part of what you said, Lucid uses its rules instead, so a dictation is never lost.")
            }

            Section {
                ForEach(library.installed) { model in
                    ModelRow(
                        model: model,
                        inUse: model.kind == .speech && model.fileName == plan.speech,
                        uses: uses(of: model, in: plan),
                        onStyle: { style in library.setStyle(style, for: model) },
                        onRemove: { removing = model }
                    )
                }
                HStack {
                    Button("Add Speech Model…") { startImport(.speech) }
                        .disabled(library.adding != nil)
                    Button("Add Cleanup Model…") { startImport(.cleanup) }
                        .disabled(library.adding != nil)
                    Spacer()
                    Button("Show in Finder") { library.showInFinder() }
                }
                if let adding = library.adding {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Adding \(adding)…").foregroundStyle(.secondary)
                    }
                }
                if let notice = library.notice {
                    Text(notice.text)
                        .font(.callout)
                        .foregroundStyle(notice.isProblem ? Color.orange : Color.secondary)
                }
            } header: {
                Text("Models on this Mac")
            } footer: {
                Text("Lucid keeps its own copy of each model you add, in its models folder. Speech models come from huggingface.co/ggerganov/whisper.cpp. A cleanup model must be a single .gguf file.")
            }

            Section {
                ForEach(ModelCatalog.suggested) { suggestion in
                    DownloadRow(
                        title: suggestion.name,
                        detail: DownloadRow.size(suggestion.remote.bytes) + " · " + suggestion.summary,
                        remote: suggestion.remote,
                        library: library
                    )
                }
                ForEach(otherDownloads, id: \.remote.id) { download in
                    DownloadRow(
                        title: download.remote.fileName,
                        detail: "From \(download.remote.repo)",
                        remote: download.remote,
                        library: library
                    )
                }
                Button("Download Another Model…") { browsing = true }
            } header: {
                Text("Download from Hugging Face")
            } footer: {
                Text("Downloads come straight from huggingface.co, and Lucid sends nothing else. A download that stops continues where it left off.")
            }

            Section {
                Text(engineNote)
                    .font(.callout)
                    .foregroundStyle(engineFailed ? Color.orange : Color.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $browsing) {
            HubBrowser(library: library, search: library.search, onDone: { browsing = false })
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
            if case .success(let url) = result {
                library.add(url, as: importKind)
            }
        }
        .confirmationDialog(
            "Remove \(removing?.name ?? "this model")?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            presenting: removing
        ) { model in
            Button("Remove", role: .destructive) { remove(model) }
            Button("Cancel", role: .cancel) {}
        } message: { model in
            Text("Lucid deletes its copy, \(model.fileName). A copy you keep elsewhere is not touched.")
        }
    }
}

/// One model in the list: its name, what it is, and for a model the user added, its prompt
/// format and a remove button.
private struct ModelRow: View {
    let model: InstalledModel
    /// For a speech model: whether it is the one in use.
    let inUse: Bool
    /// For a cleanup model: the levels it is used for.
    let uses: [String]
    let onStyle: (PromptStyle) -> Void
    let onRemove: () -> Void

    private var detail: String {
        var parts = [
            model.kind == .speech ? "Speech" : "Cleanup",
            ByteCountFormatter.string(fromByteCount: model.bytes, countStyle: .file),
        ]
        if model.isBuiltIn { parts.append("built in") }
        if inUse { parts.append("in use") }
        if !uses.isEmpty { parts.append("used for " + uses.joined(separator: " and ")) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.name)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !model.isBuiltIn {
                if model.kind == .cleanup {
                    Picker("Prompt", selection: Binding(get: { model.style ?? .general }, set: onStyle)) {
                        Text("Lucid's prompt").tag(PromptStyle.general)
                        Text("S1-mini format").tag(PromptStyle.s1)
                    }
                    .labelsHidden()
                    .fixedSize()
                    .help("The input the model expects. S1-mini and other copies of it need the S1-mini format. Every other model takes Lucid's prompt.")
                }
                Button(role: .destructive, action: onRemove) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove \(model.name)")
            }
        }
    }
}

/// A model that can be downloaded: what it is, then a button, or its progress while it downloads.
private struct DownloadRow: View {
    let title: String
    let detail: String
    let remote: RemoteModel
    @ObservedObject var library: ModelLibraryModel

    static func size(_ bytes: Int64?) -> String {
        guard let bytes else { return "Size unknown" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func progressText(_ download: ModelLibraryModel.Download) -> String {
        guard let total = download.total else { return "\(Self.size(download.received)) so far" }
        return "\(Self.size(download.received)) of \(Self.size(total))"
    }

    var body: some View {
        let download = library.downloads[remote.fileName]
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let download {
                    ProgressView(value: download.fraction)
                    Text(progressText(download))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if download != nil {
                Button("Stop") { library.cancelDownload(remote.fileName) }
            } else if library.isInstalled(remote.fileName) {
                Text("Downloaded")
                    .foregroundStyle(.secondary)
            } else {
                let title: String = library.partialBytes(of: remote.fileName) == nil ? "Download" : "Resume"
                Button(title) { library.download(remote) }
            }
        }
    }
}

/// A sheet for downloading any public model on Hugging Face: look it up by name or link, then
/// download one of the files Lucid can use.
struct HubBrowser: View {
    @ObservedObject var library: ModelLibraryModel
    @ObservedObject var search: HubSearchModel
    let onDone: () -> Void
    @State private var text = ""

    private var blank: Bool {
        text.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Download from Hugging Face")
                .font(.title3.weight(.semibold))
            Text("Type a model's name, such as ggerganov/whisper.cpp, or paste a link to it or to one of its files. Lucid lists the files it can use.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("Model", text: $text, prompt: Text("owner/name, or a link"))
                    .labelsHidden()
                    .onSubmit {
                        if !blank { search.lookUp(text) }
                    }
                Button("Look Up") { search.lookUp(text) }
                    .disabled(blank)
            }
            results
                .frame(maxHeight: .infinity, alignment: .top)
            if let notice = library.notice {
                Text(notice.text)
                    .font(.callout)
                    .foregroundStyle(notice.isProblem ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text("Each model has its own licence, shown on its page.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done", action: onDone)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 540, height: 480)
    }

    @ViewBuilder
    private var results: some View {
        switch search.state {
        case .idle:
            EmptyView()
        case .searching:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Looking up…").foregroundStyle(.secondary)
            }
        case .failed(let message):
            Text(message)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        case .found(let repo, let files):
            VStack(alignment: .leading, spacing: 8) {
                List(files) { file in
                    DownloadRow(
                        title: file.path,
                        detail: (file.kind == .speech ? "Speech" : "Cleanup") + " · " + DownloadRow.size(file.bytes),
                        remote: file,
                        library: library
                    )
                }
                Link("Open \(repo) on Hugging Face", destination: library.hub.pageURL(repo: repo))
                    .font(.callout)
            }
        }
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
