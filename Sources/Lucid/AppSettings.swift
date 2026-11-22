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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hotkey = defaults.string(forKey: Key.hotkey).flatMap(HotkeyChoice.init(rawValue:)) ?? SystemInfo.defaultHotkey
        level = defaults.string(forKey: Key.level).flatMap(CleanupLevel.init(rawValue:)) ?? .light
        keepRecordings = defaults.object(forKey: Key.keepRecordings) as? Bool ?? true
        onboardingDone = defaults.bool(forKey: Key.onboardingDone)
    }

    static var dictionaryURL: URL {
        EngineConfig.supportDirectory.appendingPathComponent("dictionary.json")
    }
}
