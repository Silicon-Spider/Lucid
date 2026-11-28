import Foundation
import LucidCore
import LucidEngines

// MARK: - Settings

/// The user's choices, kept in `settings.json` beside the models.
///
/// The Mac app keeps its settings in the system's preferences. This file is for the app on
/// other systems.
public struct DeskSettings: Codable, Equatable, Sendable {
    /// The key that starts a dictation, by the name the system's shell gives it. Nil means its usual key.
    public var hotkey: String?
    public var level: CleanupLevel
    /// Whether the pill shows the last few words heard while the user is still speaking.
    public var livePreview: Bool
    /// Whether the audio of recent dictations is kept, so a failed one can be retried.
    public var keepRecordings: Bool
    public var models: ModelChoices
    /// True once the window has opened by itself, the first time Lucid ran.
    public var welcomed: Bool

    public init(
        hotkey: String? = nil,
        level: CleanupLevel = .light,
        livePreview: Bool = true,
        keepRecordings: Bool = true,
        models: ModelChoices = ModelChoices(),
        welcomed: Bool = false
    ) {
        self.hotkey = hotkey
        self.level = level
        self.livePreview = livePreview
        self.keepRecordings = keepRecordings
        self.models = models
        self.welcomed = welcomed
    }

    /// A file from an older or newer Lucid may lack some settings. Each falls back to its usual value.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let usual = DeskSettings()
        hotkey = try container.decodeIfPresent(String.self, forKey: .hotkey)
        level = (try? container.decodeIfPresent(CleanupLevel.self, forKey: .level)) ?? usual.level
        livePreview = try container.decodeIfPresent(Bool.self, forKey: .livePreview) ?? usual.livePreview
        keepRecordings = try container.decodeIfPresent(Bool.self, forKey: .keepRecordings) ?? usual.keepRecordings
        models = try container.decodeIfPresent(ModelChoices.self, forKey: .models) ?? usual.models
        welcomed = try container.decodeIfPresent(Bool.self, forKey: .welcomed) ?? usual.welcomed
    }
}

/// Reads and saves the settings. Safe to use from any thread.
public final class SettingsStore: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var settings: DeskSettings

    public init(url: URL = EngineConfig.supportDirectory.appendingPathComponent("settings.json")) {
        self.url = url
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(DeskSettings.self, from: data) {
            settings = saved
        } else {
            settings = DeskSettings()
        }
    }

    public var current: DeskSettings {
        lock.lock()
        defer { lock.unlock() }
        return settings
    }

    /// Changes the settings and saves them. Returns the settings as they now are.
    @discardableResult
    public func update(_ change: (inout DeskSettings) -> Void) -> DeskSettings {
        lock.lock()
        defer { lock.unlock() }
        let before = settings
        change(&settings)
        if settings != before {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? encoder.encode(settings).write(to: url, options: .atomic)
        }
        return settings
    }
}

// MARK: - History

/// Past dictations, safe to use from any thread. `HistoryStore` itself is not.
public final class HistoryDesk: @unchecked Sendable {
    private let lock = NSLock()
    private let store: HistoryStore

    public init(directory: URL = EngineConfig.supportDirectory) {
        store = HistoryStore(directory: directory)
    }

    private func locked<Value>(_ body: (HistoryStore) -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body(store)
    }

    /// Newest first.
    public var entries: [HistoryEntry] { locked { $0.entries } }

    public func entry(_ id: UUID) -> HistoryEntry? {
        locked { store in store.entries.first { $0.id == id } }
    }

    @discardableResult
    public func add(_ entry: HistoryEntry, wav: Data?) -> HistoryEntry {
        locked { $0.add(entry, wav: wav) }
    }

    public func remove(_ id: UUID) {
        locked { $0.remove(id) }
    }

    public func clear() {
        locked { $0.clear() }
    }

    public func hasAudio(_ entry: HistoryEntry) -> Bool {
        locked { $0.audioURL(for: entry) != nil }
    }

    /// The kept recording of a dictation, if there is one.
    public func audio(for entry: HistoryEntry) -> Data? {
        locked { store in store.audioURL(for: entry).flatMap { try? Data(contentsOf: $0) } }
    }
}

// MARK: - Engines

/// What one dictation produced.
public struct DictationOutcome: Sendable {
    /// The transcript exactly as the speech engine heard it.
    public let heard: String
    public let speechMillis: Int
    public let result: PipelineResult

    public init(heard: String, speechMillis: Int, result: PipelineResult) {
        self.heard = heard
        self.speechMillis = speechMillis
        self.result = result
    }
}

/// Turns recordings into text. The real one runs the engines. Tests use a stand-in.
public protocol DictationEngine: AnyObject, Sendable {
    func dictate(wav: Data, context: PipelineContext) async throws -> DictationOutcome
    /// What has been heard so far, to show while the user is still speaking. Nil when it cannot say.
    func preview(wav: Data, prompt: String) async -> String?
}

/// Owns the speech and cleanup engines, and runs recordings through them.
///
/// Safe to use from any thread. This is the Mac app's `EngineManager` without anything that
/// only a Mac has.
public final class DeskEngines: DictationEngine, @unchecked Sendable {
    public enum Status: Equatable, Sendable {
        case starting
        case ready
        /// Engines or models are not installed. The strings say what is missing.
        case setupNeeded([String])
        case failed(String)
    }

    private let lock = NSLock()
    private let library: ModelLibrary
    private let tracksProcesses: Bool
    private var choices: ModelChoices
    private var level: CleanupLevel
    private var currentConfig: EngineConfig
    private var currentStatus: Status = .starting
    private var supervisor: EngineSupervisor
    /// Called from any thread when the status changes.
    private var statusHandler: (@Sendable (Status) -> Void)?

    /// `tracksProcesses` is false where engines started by another copy of Lucid must be left alone.
    public init(choices: ModelChoices, level: CleanupLevel, library: ModelLibrary = .standard, tracksProcesses: Bool = true) {
        self.library = library
        self.tracksProcesses = tracksProcesses
        self.choices = choices
        self.level = level
        currentConfig = .standard(plan: library.plan(for: choices), level: level)
        supervisor = EngineSupervisor(config: currentConfig, tracksProcesses: tracksProcesses)
    }

    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    public var status: Status { locked { currentStatus } }
    /// The engines and model files in use.
    public var config: EngineConfig { locked { currentConfig } }

    public func onStatus(_ handler: @escaping @Sendable (Status) -> Void) {
        locked { statusHandler = handler }
    }

    /// Records a status, unless the engines it describes have since been replaced.
    private func set(_ status: Status, for owner: EngineSupervisor) {
        let handler: (@Sendable (Status) -> Void)? = locked {
            guard owner === supervisor, currentStatus != status else { return nil }
            currentStatus = status
            return statusHandler
        }
        handler?(status)
    }

    /// The model files the engines need that are not in the models folder yet.
    public var missingModelFiles: [String] {
        let config = config
        return [config.speechModelURL, config.cleanupModelURL]
            .filter { !FileManager.default.fileExists(atPath: $0.path) }
            .map(\.lastPathComponent)
    }

    /// True when whisper.cpp or llama.cpp is not installed.
    public var enginesMissing: Bool {
        let config = config
        return !FileManager.default.isExecutableFile(atPath: config.whisperServer.path)
            || !FileManager.default.isExecutableFile(atPath: config.llamaServer.path)
    }

    public func start() async {
        let (starting, config) = locked { (supervisor, currentConfig) }
        set(.starting, for: starting)
        let missing = config.missing()
        guard missing.isEmpty else {
            set(.setupNeeded(missing), for: starting)
            return
        }
        do {
            try await starting.start()
            set(.ready, for: starting)
        } catch {
            set(.failed("\(error)"), for: starting)
        }
    }

    /// Restarts the engines if the level, the user's model choices or the models folder now
    /// call for different files. Starts them if the files they were missing have arrived.
    public func update(choices newChoices: ModelChoices? = nil, level newLevel: CleanupLevel? = nil) async {
        enum Next {
            case nothing
            case start
            case replace(EngineSupervisor)
        }
        let next: Next = locked {
            if let newChoices { choices = newChoices }
            if let newLevel { level = newLevel }
            // The engines are found afresh: one may have been installed since Lucid started.
            let wanted = EngineConfig.standard(plan: library.plan(for: choices), level: level)
            if wanted == currentConfig {
                if case .setupNeeded = currentStatus, wanted.missing().isEmpty { return .start }
                return .nothing
            }
            // Swap before waiting, so an update that arrives meanwhile sees the new engines.
            let old = supervisor
            currentConfig = wanted
            supervisor = EngineSupervisor(config: wanted, tracksProcesses: tracksProcesses)
            return .replace(old)
        }
        switch next {
        case .nothing:
            return
        case .start:
            await start()
        case .replace(let old):
            await old.stop()
            await start()
        }
    }

    public func stop() async {
        await locked { supervisor }.stop()
    }

    /// Stops the engines and waits, for use while the app is quitting.
    public func stopNow() {
        let supervisor = locked { self.supervisor }
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await supervisor.stop()
            done.signal()
        }
        _ = done.wait(timeout: .now() + 4)
    }

    public func preview(wav: Data, prompt: String) async -> String? {
        let (status, supervisor) = locked { (currentStatus, self.supervisor) }
        guard status == .ready, let transcriber = try? await supervisor.transcriber() else { return nil }
        return try? await transcriber.transcribe(wav: wav, prompt: prompt)
    }

    /// Turns a recording into cleaned text. Restarts an engine first if one has stopped.
    public func dictate(wav: Data, context: PipelineContext) async throws -> DictationOutcome {
        let supervisor = locked { self.supervisor }
        try await supervisor.recover()
        let transcriber = try await supervisor.transcriber()
        let began = Date()
        let heard = try await transcriber.transcribe(wav: wav, prompt: context.dictionary.recognitionPrompt())
        let speechMillis = Int(Date().timeIntervalSince(began) * 1000)

        // A missing cleanup engine is not fatal: the rules stage still runs.
        let cleaner: LlamaClient? = context.level == .off ? nil : try? await supervisor.cleaner()
        let result = await Pipeline(cleaner: cleaner).process(heard, context: context)
        return DictationOutcome(heard: heard, speechMillis: speechMillis, result: result)
    }
}
