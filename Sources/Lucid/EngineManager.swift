import Foundation
import LucidCore
import LucidEngines

/// What one dictation produced.
struct DictationOutcome {
    /// The transcript exactly as the speech engine heard it.
    let heard: String
    let speechMillis: Int
    let result: PipelineResult
}

/// Owns the engines for the app, and runs a recording through them.
@MainActor
final class EngineManager: ObservableObject {
    enum Status: Equatable {
        case starting
        case ready
        /// Engines or models are not installed. The strings say what is missing.
        case setupNeeded([String])
        case failed(String)
    }

    @Published private(set) var status: Status = .starting
    /// The engines and model files in use.
    private(set) var config: EngineConfig

    private let tracksProcesses: Bool
    private let library: ModelLibrary
    private var choices: ModelChoices
    private var level: CleanupLevel
    private var supervisor: EngineSupervisor

    /// `tracksProcesses` is false for the self-test, so it never stops a running app's engines.
    init(choices: ModelChoices, level: CleanupLevel, library: ModelLibrary = .standard, tracksProcesses: Bool = true) {
        self.tracksProcesses = tracksProcesses
        self.library = library
        self.choices = choices
        self.level = level
        config = .standard(plan: library.plan(for: choices), level: level)
        supervisor = EngineSupervisor(config: config, tracksProcesses: tracksProcesses)
    }

    /// A manager frozen in one state, for drawing views without starting any engine.
    static func preview(_ status: Status) -> EngineManager {
        let manager = EngineManager(choices: ModelChoices(), level: .light, tracksProcesses: false)
        manager.status = status
        return manager
    }

    /// True when a model that can do the Medium level is installed: the optional general
    /// model, or one the user added that uses Lucid's own prompt.
    static func mediumAvailable(for choices: ModelChoices) -> Bool {
        ModelLibrary.standard.plan(for: choices).medium != nil
    }

    /// The model files the engines need that are not in the models folder yet.
    var missingModelFiles: [String] {
        [config.speechModelURL, config.cleanupModelURL]
            .filter { !FileManager.default.fileExists(atPath: $0.path) }
            .map(\.lastPathComponent)
    }

    /// True when whisper.cpp or llama.cpp is not installed, which only `scripts/setup.sh` can fix.
    var enginesMissing: Bool {
        !FileManager.default.isExecutableFile(atPath: config.whisperServer.path)
            || !FileManager.default.isExecutableFile(atPath: config.llamaServer.path)
    }

    func start() async {
        let starting = supervisor
        status = .starting
        let missing = config.missing()
        guard missing.isEmpty else {
            status = .setupNeeded(missing)
            return
        }
        do {
            try await starting.start()
            // The models may have changed while these engines loaded. Then the newer start reports.
            guard starting === supervisor else { return }
            status = .ready
        } catch {
            guard starting === supervisor else { return }
            status = .failed("\(error)")
        }
    }

    /// Restarts the engines if the level, the user's model choices or the models folder now
    /// call for different model files. Starts them if the files they were missing have arrived.
    func update(choices newChoices: ModelChoices? = nil, level newLevel: CleanupLevel? = nil) async {
        if let newChoices { choices = newChoices }
        if let newLevel { level = newLevel }
        let wanted = EngineConfig.standard(plan: library.plan(for: choices), level: level)
        guard wanted != config else {
            // The same files, but one that was missing may just have been downloaded.
            if case .setupNeeded = status, wanted.missing().isEmpty { await start() }
            return
        }
        // Swap before waiting, so an update that arrives meanwhile sees the new engines.
        config = wanted
        let old = supervisor
        supervisor = EngineSupervisor(config: wanted, tracksProcesses: tracksProcesses)
        status = .starting
        await old.stop()
        await start()
    }

    func stop() async {
        await supervisor.stop()
    }

    /// Stops the engines and waits, for use while the app is quitting.
    func stopNow() {
        let supervisor = supervisor
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await supervisor.stop()
            done.signal()
        }
        _ = done.wait(timeout: .now() + 4)
    }

    /// Turns a recording into cleaned text. Restarts an engine first if one has stopped.
    func dictate(wav: Data, context: PipelineContext) async throws -> DictationOutcome {
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
