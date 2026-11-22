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
