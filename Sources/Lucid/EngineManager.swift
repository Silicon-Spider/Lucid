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

    private let tracksProcesses: Bool
    private var cleanupModel: CleanupModel
    private var supervisor: EngineSupervisor

    /// `tracksProcesses` is false for the self-test, so it never stops a running app's engines.
    init(level: CleanupLevel, tracksProcesses: Bool = true) {
        self.tracksProcesses = tracksProcesses
        cleanupModel = Self.model(for: level)
        supervisor = EngineSupervisor(config: .standard(cleanup: cleanupModel), tracksProcesses: tracksProcesses)
    }

    /// True when the optional general model, used for the Medium level, has been downloaded.
    static var generalModelInstalled: Bool {
        FileManager.default.fileExists(atPath: EngineConfig.standard(cleanup: EngineConfig.general).cleanupModelURL.path)
    }

    /// Medium needs the general model. Everything else uses S1-mini by Superwhisper.
    static func model(for level: CleanupLevel) -> CleanupModel {
        level == .medium && generalModelInstalled ? EngineConfig.general : EngineConfig.s1Mini
    }

    func start() async {
        status = .starting
        let missing = EngineConfig.standard(cleanup: cleanupModel).missing()
        guard missing.isEmpty else {
            status = .setupNeeded(missing)
            return
        }
        do {
            try await supervisor.start()
            status = .ready
        } catch {
            status = .failed("\(error)")
        }
    }

    /// Swaps the cleanup model if the new level needs a different one.
    func setLevel(_ level: CleanupLevel) async {
        let wanted = Self.model(for: level)
        guard wanted != cleanupModel else { return }
        cleanupModel = wanted
        await supervisor.stop()
        supervisor = EngineSupervisor(config: .standard(cleanup: wanted), tracksProcesses: tracksProcesses)
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
