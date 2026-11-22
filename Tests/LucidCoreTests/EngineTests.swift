import Foundation
import LucidCore
import LucidEngines

private func temporaryFile(_ suffix: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("lucid-test-\(UUID().uuidString)\(suffix)")
}

func engineTests() async {
    await asyncSuite("Engines") {
        test("finds a free port") {
            let port = try ServerProcess.freePort()
            expectTrue(port > 1024 && port < 65536, "port \(port)")
        }

        test("standard config points at the models folder") {
            let config = EngineConfig.standard()
            expectEqual(config.speechModelURL.lastPathComponent, "ggml-large-v3-turbo-q5_0.bin")
            expectEqual(config.cleanupModelURL.lastPathComponent, "s1-mini-q4_k_m.gguf")
            expectEqual(config.cleanupModel.style, .s1)
            expectTrue(config.modelsDirectory.path.hasSuffix("Library/Application Support/Lucid/models"))
        }

        test("reports what is missing") {
            var config = EngineConfig.standard()
            config.whisperServer = URL(fileURLWithPath: "/nonexistent/whisper-server")
            config.speechModel = "no-such-model.bin"
            let missing = config.missing(speech: true, cleanup: false)
            expectEqual(missing.count, 2)
            expectTrue(missing.contains { $0.contains("/nonexistent/whisper-server") }, "\(missing)")
            expectTrue(missing.contains { $0.contains("no-such-model.bin") }, "\(missing)")
        }

        await asyncTest("starts a server, waits for it and stops it") {
            let port = try ServerProcess.freePort()
            let log = temporaryFile(".log")
            defer { try? FileManager.default.removeItem(at: log) }
            let server = ServerProcess(
                name: "test server",
                executable: URL(fileURLWithPath: "/usr/bin/python3"),
                arguments: ["-m", "http.server", String(port), "--bind", "127.0.0.1"],
                port: port,
                healthPath: "/",
                logURL: log
            )
            try server.start()
            try await server.waitUntilReady(timeout: 30)
            expectTrue(server.isRunning)
            expectEqual(server.baseURL.absoluteString, "http://127.0.0.1:\(port)")
            server.stop()
            expectFalse(server.isRunning)
        }

        await asyncTest("reports a server that exits straight away") {
            let log = temporaryFile(".log")
            defer { try? FileManager.default.removeItem(at: log) }
            let server = ServerProcess(
                name: "broken server",
                executable: URL(fileURLWithPath: "/usr/bin/false"),
                arguments: [],
                port: try ServerProcess.freePort(),
                healthPath: "/",
                logURL: log
            )
            try server.start()
            do {
                try await server.waitUntilReady(timeout: 5)
                expectTrue(false, "expected an error")
            } catch let error as EngineError {
                if case .launchFailed = error {
                    expectTrue(true)
                } else {
                    expectTrue(false, "unexpected error \(error)")
                }
            }
        }

        test("pid file cleanup leaves unrelated processes alone") {
            let url = temporaryFile(".pid")
            PidFile.write([getpid()], to: url)
            expectEqual(PidFile.read(at: url), [getpid()])
            // This test process is not an engine, so it must survive the cleanup.
            PidFile.killStale(at: url, names: ["whisper-server", "llama-server"])
            expectFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }
}
