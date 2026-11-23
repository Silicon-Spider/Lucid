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

    @Published private(set) var installed: [InstalledModel] = []
    /// The name of the file being copied in, while it is copied.
    @Published private(set) var adding: String?
    @Published private(set) var notice: Notice?

    /// Called after a model is added, removed or changed, so the engines can follow.
    var onChange: (() -> Void)?

    let library: ModelLibrary

    init(library: ModelLibrary = .standard) {
        self.library = library
        reload()
    }

    func reload() {
        installed = library.models()
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

    /// Deletes a model the user added. Returns false if it could not be removed.
    @discardableResult
    func remove(_ model: InstalledModel) -> Bool {
        defer {
            reload()
            onChange?()
        }
        do {
            try library.remove(model.fileName)
            notice = Notice(text: "Removed \(model.name).", isProblem: false)
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

    func showInFinder() {
        try? FileManager.default.createDirectory(at: library.directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(library.directory)
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
