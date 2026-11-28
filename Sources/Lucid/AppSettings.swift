import Foundation
import LucidCore
import LucidEngines

/// The user's choices. Each change is saved straight away.
@MainActor
final class AppSettings: ObservableObject {
    private enum Key {
        static let hotkey = "hotkey"
        static let level = "cleanupLevel"
        static let keepRecordings = "keepRecordings"
        static let onboardingDone = "onboardingDone"
        static let models = "models"
        static let livePreview = "livePreview"
    }

    private let defaults: UserDefaults

    @Published var hotkey: HotkeyChoice {
        didSet { defaults.set(hotkey.rawValue, forKey: Key.hotkey) }
    }

    @Published var level: CleanupLevel {
        didSet { defaults.set(level.rawValue, forKey: Key.level) }
    }

    /// Whether the audio of recent dictations is kept, so a failed one can be retried.
    @Published var keepRecordings: Bool {
        didSet { defaults.set(keepRecordings, forKey: Key.keepRecordings) }
    }

    @Published var onboardingDone: Bool {
        didSet { defaults.set(onboardingDone, forKey: Key.onboardingDone) }
    }

    /// Whether the pill shows the last few words heard while the user is still speaking.
    @Published var livePreview: Bool {
        didSet { defaults.set(livePreview, forKey: Key.livePreview) }
    }

    /// The speech and cleanup models the user chose. Empty choices mean Lucid's own models.
    @Published var models: ModelChoices {
        didSet { defaults.set(try? JSONEncoder().encode(models), forKey: Key.models) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hotkey = defaults.string(forKey: Key.hotkey).flatMap(HotkeyChoice.init(rawValue:)) ?? SystemInfo.defaultHotkey
        level = defaults.string(forKey: Key.level).flatMap(CleanupLevel.init(rawValue:)) ?? .light
        keepRecordings = defaults.object(forKey: Key.keepRecordings) as? Bool ?? true
        onboardingDone = defaults.bool(forKey: Key.onboardingDone)
        livePreview = defaults.object(forKey: Key.livePreview) as? Bool ?? true
        models = defaults.data(forKey: Key.models).flatMap { try? JSONDecoder().decode(ModelChoices.self, from: $0) }
            ?? ModelChoices()
    }

    /// Not tied to the main actor, so it can be a default argument anywhere.
    nonisolated static var dictionaryURL: URL {
        EngineConfig.supportDirectory.appendingPathComponent("dictionary.json")
    }
}
