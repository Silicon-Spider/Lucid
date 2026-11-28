import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One helper process: a server binary listening on a local port.
///
/// A `Process` can only run once, so restarting an engine means creating a new `ServerProcess`.
public final class ServerProcess: @unchecked Sendable {
    public let name: String
    public let port: Int
    private let executable: URL
    private let arguments: [String]
    private let healthPath: String
    private let logURL: URL
    private let process = Process()
    private var launched = false

    /// `healthPath` is a path such as "/health" that answers 200 once the server is ready.
    public init(name: String, executable: URL, arguments: [String], port: Int, healthPath: String, logURL: URL) {
        self.name = name
        self.executable = executable
        self.arguments = arguments
        self.port = port
        self.healthPath = healthPath
        self.logURL = logURL
    }

    public var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }
    public var isRunning: Bool { launched && process.isRunning }
    public var processIdentifier: Int32 { process.processIdentifier }

    /// Launches the process. Its output goes to the log file, replacing any earlier log.
    public func start() throws {
        let files = FileManager.default
        try files.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = files.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)

        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = log
        process.standardError = log
        do {
            try process.run()
            launched = true
        } catch {
            throw EngineError.launchFailed("\(name): \(error.localizedDescription)")
        }
    }

    /// Waits until the server answers its health check with 200.
    public func waitUntilReady(timeout: TimeInterval) async throws {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(healthPath)")!)
        request.timeoutInterval = 2
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard isRunning else {
                throw EngineError.launchFailed("\(name) stopped during start-up. See \(logURL.path)")
            }
            if let (_, response) = try? await LocalHTTP.session.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                return
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        throw EngineError.notReady("\(name) did not answer within \(Int(timeout)) seconds. See \(logURL.path)")
    }

    /// Stops the process, forcefully if it has not exited within two seconds.
    public func stop() {
        Self.stop([self])
    }

    /// Stops several processes at once. Each is asked to stop, and any that has not within
    /// two seconds of being asked is stopped by force. Together, so that the wait is two
    /// seconds at most however many there are: some engines do not stop when asked.
    public static func stop(_ servers: [ServerProcess], patience: TimeInterval = 2) {
        let running = servers.filter(\.isRunning)
        guard !running.isEmpty else { return }
        for server in running { server.process.terminate() }
        let deadline = Date().addingTimeInterval(patience)
        while Date() < deadline, running.contains(where: { $0.process.isRunning }) { Platform.pause() }
        for server in running where server.process.isRunning {
            Platform.forceStop(server.process)
            server.process.waitUntilExit()
        }
    }

    /// Asks the system for a free local port.
    public static func freePort() throws -> Int {
        try Platform.freePort()
    }
}
