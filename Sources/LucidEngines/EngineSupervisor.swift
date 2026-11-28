import Foundation
import LucidCore

/// Starts, watches and stops the two engine processes.
public actor EngineSupervisor {
    public static let maxRestarts = 3
    private static let engineNames: Set<String> = ["whisper-server", "llama-server"]

    public let config: EngineConfig
    private let tracksProcesses: Bool
    private var speech: ServerProcess?
    private var cleanup: ServerProcess?
    private var restarts = 0
    private var clearedStale = false

    /// With `tracksProcesses`, engine PIDs are recorded so that a later launch can stop engines
    /// left behind by a crash. Only one long-lived owner, the app, should track.
    public init(config: EngineConfig = .standard(), tracksProcesses: Bool = true) {
        self.config = config
        self.tracksProcesses = tracksProcesses
    }

    private var pidFile: URL { config.supportDirectory.appendingPathComponent("engines.pid") }

    public var speechRunning: Bool { speech?.isRunning == true }
    public var cleanupRunning: Bool { cleanup?.isRunning == true }

    /// Starts whichever engines are wanted and not already running, then waits for their
    /// models to load.
    public func start(speech wantSpeech: Bool = true, cleanup wantCleanup: Bool = true) async throws {
        let missing = config.missing(speech: wantSpeech, cleanup: wantCleanup)
        guard missing.isEmpty else { throw EngineError.missing(missing.joined(separator: "; ")) }

        if tracksProcesses, !clearedStale {
            PidFile.killStale(at: pidFile, names: Self.engineNames)
            clearedStale = true
        }
        let launchingSpeech = wantSpeech && speech?.isRunning != true
        let launchingCleanup = wantCleanup && cleanup?.isRunning != true
        if launchingSpeech { speech = try launchSpeech() }
        if launchingCleanup { cleanup = try launchCleanup() }
        if tracksProcesses {
            let running = [speech, cleanup].compactMap { $0 }.filter(\.isRunning).map(\.processIdentifier)
            PidFile.write(running, to: pidFile)
        }

        do {
            if wantSpeech, let speech { try await speech.waitUntilReady(timeout: 60) }
            if wantCleanup, let cleanup { try await cleanup.waitUntilReady(timeout: 180) }
        } catch {
            stop()
            throw error
        }
        await warmUp(speech: launchingSpeech, cleanup: launchingCleanup)
    }

    /// The first request to each engine is slow: the speech engine builds its compute graph,
    /// and the cleanup engine reads its fixed prompt. Doing both now means the first dictation
    /// is not the one that pays, or that times out.
    private func warmUp(speech warmSpeech: Bool, cleanup warmCleanup: Bool) async {
        if warmSpeech, let client = try? transcriber() {
            let silence = WAV.encode(samples: [Int16](repeating: 0, count: 16_000))
            _ = try? await client.transcribe(wav: silence, prompt: "")
        }
        if warmCleanup, let client = try? cleaner() {
            let request = CleanupRequest(transcript: "this is a warm up sentence for the cleanup model")
            _ = try? await client.clean(request, timeout: 60)
        }
    }

    public func stop() {
        ServerProcess.stop([speech, cleanup].compactMap { $0 })
        speech = nil
        cleanup = nil
        if tracksProcesses { PidFile.remove(at: pidFile) }
    }

    /// Restarts any engine that has exited. Gives up after `maxRestarts`, so a broken
    /// install does not loop for ever.
    public func recover() async throws {
        let wantSpeech = speech != nil
        let wantCleanup = cleanup != nil
        let speechDown = wantSpeech && speech?.isRunning != true
        let cleanupDown = wantCleanup && cleanup?.isRunning != true
        guard speechDown || cleanupDown else { return }
        guard restarts < Self.maxRestarts else {
            throw EngineError.launchFailed("an engine keeps stopping. See the logs in \(config.logsDirectory.path)")
        }
        restarts += 1
        try await Task.sleep(nanoseconds: UInt64(restarts) * 500_000_000)
        try await start(speech: wantSpeech, cleanup: wantCleanup)
    }

    public func transcriber() throws -> WhisperClient {
        guard let speech, speech.isRunning else {
            throw EngineError.notReady("the speech engine is not running")
        }
        return WhisperClient(baseURL: speech.baseURL)
    }

    public func cleaner() throws -> LlamaClient {
        guard let cleanup, cleanup.isRunning else {
            throw EngineError.notReady("the cleanup engine is not running")
        }
        return LlamaClient(baseURL: cleanup.baseURL, style: config.cleanupModel.style)
    }

    private func launchSpeech() throws -> ServerProcess {
        let port = try ServerProcess.freePort()
        let server = ServerProcess(
            name: "speech engine",
            executable: config.whisperServer,
            arguments: [
                "-m", config.speechModelURL.path,
                "--host", "127.0.0.1",
                "--port", String(port),
                "-l", "en",
                "-nt",
            ],
            port: port,
            healthPath: "/",
            logURL: config.logsDirectory.appendingPathComponent("whisper-server.log")
        )
        try server.start()
        return server
    }

    private func launchCleanup() throws -> ServerProcess {
        let port = try ServerProcess.freePort()
        let server = ServerProcess(
            name: "cleanup engine",
            executable: config.llamaServer,
            arguments: [
                "-m", config.cleanupModelURL.path,
                "--host", "127.0.0.1",
                "--port", String(port),
                "-c", "8192",
                "-ngl", "99",
                "-np", "1",
                "--no-ui",
                "--jinja",
                "--temp", "0",
                // S1-mini was trained with thinking off, and needs it switched off this way.
                // Models whose template has no thinking mode ignore the setting.
                "--chat-template-kwargs", "{\"enable_thinking\":false}",
            ],
            port: port,
            healthPath: "/health",
            logURL: config.logsDirectory.appendingPathComponent("llama-server.log")
        )
        try server.start()
        return server
    }
}
