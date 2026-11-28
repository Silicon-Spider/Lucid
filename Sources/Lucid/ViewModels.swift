import AppKit
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

/// The models folder as the settings window sees it.
@MainActor
final class ModelLibraryModel: ObservableObject {
    /// What happened after the user added, removed or changed a model.
    struct Notice: Equatable {
        let text: String
        let isProblem: Bool
    }

    /// A download in progress.
    struct Download: Equatable {
        let remote: RemoteModel
        var received: Int64
        var total: Int64?

        /// From 0 to 1, or nil when the size is not known.
        var fraction: Double? {
            guard let total, total > 0 else { return nil }
            return min(1, Double(received) / Double(total))
        }
    }

    @Published private(set) var installed: [InstalledModel] = []
    /// The name of the file being copied in, while it is copied.
    @Published private(set) var adding: String?
    @Published private(set) var notice: Notice?
    /// Downloads in progress, by file name.
    @Published private(set) var downloads: [String: Download] = [:]
    /// Downloads that stopped part way, kept so they can continue.
    @Published private(set) var partials: [PartialDownload] = []

    /// Called after a model is added, removed or changed, so the engines can follow.
    var onChange: (() -> Void)?

    let library: ModelLibrary
    let hub: HuggingFace
    /// Looking up a model on Hugging Face, for the "Download Another Model" sheet.
    let search: HubSearchModel
    private var downloadTasks: [String: Task<Void, Never>] = [:]

    init(library: ModelLibrary = .standard, hub: HuggingFace = HuggingFace()) {
        self.library = library
        self.hub = hub
        search = HubSearchModel(hub: hub)
        reload()
    }

    func reload() {
        installed = library.models()
        partials = library.partialDownloads()
    }

    /// The space all the models take up.
    var totalBytes: Int64 {
        installed.map(\.bytes).reduce(0, +)
    }

    private static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// What a model file is called: the user's name for it, or its original one.
    func displayName(of fileName: String) -> String {
        installed.first { $0.fileName == fileName }?.name ?? ModelLibrary.defaultName(for: fileName)
    }

    /// What deleting a model would change, in sentences for the confirmation. Empty when the
    /// model is not in use.
    func effectsOfRemoving(_ model: InstalledModel, choices: ModelChoices) -> [String] {
        let effects = ModelLibrary.effectsOfRemoving(model.fileName, choices: choices, installed: installed)
        let stops = "so dictation stops working until you download one again."
        var lines: [String] = []
        switch effects.speech {
        case .switches(let next): lines.append("Lucid will use \(displayName(of: next)) for speech instead.")
        case .nothingLeft: lines.append("Lucid has no other speech model, " + stops)
        case nil: break
        }
        switch effects.light {
        case .switches(let next): lines.append("Light will use \(displayName(of: next)) instead.")
        case .nothingLeft: lines.append("Lucid has no other cleanup model, " + stops)
        case nil: break
        }
        switch effects.medium {
        case .switches(let next): lines.append("Medium will use \(displayName(of: next)) instead.")
        case .nothingLeft: lines.append("Medium will use the Light model until you download one that can tighten wording.")
        case nil: break
        }
        return lines
    }

    func models(_ kind: ModelKind) -> [InstalledModel] {
        installed.filter { $0.kind == kind }
    }

    func plan(for choices: ModelChoices) -> ModelPlan {
        ModelLibrary.plan(for: choices, installed: installed)
    }

    /// Checks a model file and copies it in. A large model on another disk takes a while to
    /// copy, so it is done in the background.
    func add(_ url: URL, as kind: ModelKind) {
        guard adding == nil else { return }
        adding = url.lastPathComponent
        notice = nil
        let library = library
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<ModelLibrary.Added, Error> in
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                return Result { try library.add(from: url, as: kind) }
            }.value
            adding = nil
            switch outcome {
            case .success(let added):
                let place = kind == .speech ? "Speech recognition" : "Cleanup"
                let text = "Added \(added.model.name). Choose it under \(place) to use it."
                notice = Notice(text: [text, added.warning].compactMap { $0 }.joined(separator: " "), isProblem: false)
                reload()
                onChange?()
            case .failure(let error):
                notice = Notice(text: "\(error)", isProblem: true)
            }
        }
    }

    /// Deletes a model, Lucid's own included. Returns false if it could not be deleted.
    @discardableResult
    func remove(_ model: InstalledModel) -> Bool {
        defer {
            reload()
            onChange?()
        }
        do {
            let freed = try library.remove(model.fileName)
            notice = Notice(text: "Deleted \(model.name), freeing \(Self.size(freed)).", isProblem: false)
            return true
        } catch {
            notice = Notice(text: "\(error)", isProblem: true)
            return false
        }
    }

    /// Deletes what an unfinished download left behind. Not while it is downloading.
    func discardPartial(_ fileName: String) {
        guard downloads[fileName] == nil else { return }
        let bytes = library.partialBytes(of: fileName) ?? 0
        do {
            try library.discardPartial(of: fileName)
            notice = Notice(text: "Deleted the unfinished download of \(fileName), freeing \(Self.size(bytes)).", isProblem: false)
        } catch {
            notice = Notice(text: "\(error)", isProblem: true)
        }
        reload()
    }

    /// Gives a model the user's own name. An empty name puts the original back. Returns false,
    /// with the reason in `notice`, when the name cannot be used.
    @discardableResult
    func rename(_ model: InstalledModel, to name: String) -> Bool {
        do {
            let now = try library.rename(model.fileName, to: name)
            notice = now == model.name ? nil : Notice(text: "\(model.name) is now called \(now).", isProblem: false)
            reload()
            return true
        } catch {
            notice = Notice(text: "\(error)", isProblem: true)
            return false
        }
    }

    func setStyle(_ style: PromptStyle, for model: InstalledModel) {
        do {
            try library.setStyle(style, for: model.fileName)
            notice = nil
        } catch {
            notice = Notice(text: "\(error)", isProblem: true)
        }
        reload()
        onChange?()
    }

    func isInstalled(_ fileName: String) -> Bool {
        installed.contains { $0.fileName == fileName }
    }

    /// How much of a file an earlier download left behind.
    func partialBytes(of fileName: String) -> Int64? {
        library.partialBytes(of: fileName)
    }

    /// Downloads a model in the background. It carries on when the settings window closes.
    func download(_ remote: RemoteModel) {
        let name = remote.fileName
        guard downloads[name] == nil, !isInstalled(name) else { return }
        downloads[name] = Download(remote: remote, received: library.partialBytes(of: name) ?? 0, total: remote.bytes)
        notice = nil
        let library = library
        let hub = hub
        let report: @Sendable (Int64, Int64?) -> Void = { [weak self] received, total in
            guard let model = self else { return }
            Task { @MainActor in
                // A late report must not bring back a download that has finished.
                guard model.downloads[name] != nil else { return }
                model.downloads[name] = Download(remote: remote, received: received, total: total)
            }
        }
        downloadTasks[name] = Task { [weak self] in
            let outcome: Result<ModelLibrary.Added, Error>
            do {
                outcome = .success(try await library.download(remote, from: hub, progress: report))
            } catch {
                outcome = .failure(error)
            }
            self?.finishDownload(name, outcome)
        }
    }

    /// Downloads whichever of these files Lucid suggests, such as its own models during setup.
    func downloadSuggested(_ fileNames: [String]) {
        for name in fileNames {
            if let suggestion = ModelCatalog.suggestion(for: name) { download(suggestion.remote) }
        }
    }

    /// Stops a download. What has arrived is kept, and downloading again continues from there.
    func cancelDownload(_ fileName: String) {
        downloadTasks[fileName]?.cancel()
    }

    private func finishDownload(_ name: String, _ outcome: Result<ModelLibrary.Added, Error>) {
        downloads[name] = nil
        downloadTasks[name] = nil
        switch outcome {
        case .success(let added):
            var text = "Downloaded \(added.model.name)."
            if !added.model.isBuiltIn {
                text += " Choose it under \(added.model.kind == .speech ? "Speech recognition" : "Cleanup") to use it."
            }
            notice = Notice(text: [text, added.warning].compactMap { $0 }.joined(separator: " "), isProblem: false)
            reload()
            onChange?()
        case .failure(let error) where error is CancellationError:
            notice = Notice(text: "Stopped downloading \(name). Downloading it again continues where it stopped.", isProblem: false)
            reload()
        case .failure(let error):
            notice = Notice(text: "\(error)", isProblem: true)
            reload()
        }
    }

    func showInFinder() {
        try? FileManager.default.createDirectory(at: library.directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(library.directory)
    }
}

/// Looks up a model on Hugging Face and lists the files in it that Lucid can use.
@MainActor
final class HubSearchModel: ObservableObject {
    enum State: Equatable {
        case idle
        case searching
        case found(repo: String, files: [RemoteModel])
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    let hub: HuggingFace
    /// Counts lookups, so an answer to an older one is ignored.
    private var latest = 0

    init(hub: HuggingFace = HuggingFace()) {
        self.hub = hub
    }

    /// `text` is a model name such as "ggerganov/whisper.cpp", or a link to a model or one of its files.
    func lookUp(_ text: String) {
        latest += 1
        let lookup = latest
        guard let reference = HuggingFace.parse(text) else {
            state = .failed("That is not a model on Hugging Face. Type a name such as ggerganov/whisper.cpp, or paste a link.")
            return
        }
        state = .searching
        let hub = hub
        Task { [weak self] in
            let next: State
            do {
                next = .found(repo: reference.repo, files: try await hub.modelFiles(in: reference))
            } catch {
                next = .failed("\(error)")
            }
            guard let self, self.latest == lookup else { return }
            self.state = next
        }
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
        update(\.microphone, to: Permissions.microphone == .authorized)
        update(\.accessibility, to: Permissions.accessibility)
        update(\.listening, to: isListening())
        update(\.fnConflict, to: Permissions.fnKeyConflicts)
    }

    /// Publishes only a real change. The whole window watches this model, and a value set
    /// every second would redraw all of it every second.
    private func update(_ keyPath: ReferenceWritableKeyPath<SetupModel, Bool>, to value: Bool) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
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
