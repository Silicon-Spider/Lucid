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
            expectEqual(Array(config.modelsDirectory.pathComponents.suffix(2)), ["Lucid", "models"])
            #if os(macOS)
            expectTrue(config.modelsDirectory.path.hasSuffix("Library/Application Support/Lucid/models"))
            expectTrue(config.logsDirectory.path.hasSuffix("Library/Logs/Lucid"))
            #else
            // Off the Mac there is no Library folder, so the logs sit beside the models.
            expectEqual(Array(config.logsDirectory.pathComponents.suffix(2)), ["Lucid", "logs"])
            #endif
        }

        test("looks for the engines where each system keeps them") {
            let config = EngineConfig.standard()
            #if os(Windows)
            expectEqual(config.whisperServer.lastPathComponent, "whisper-server.exe")
            expectEqual(config.llamaServer.lastPathComponent, "llama-server.exe")
            #else
            expectEqual(config.whisperServer.lastPathComponent, "whisper-server")
            expectEqual(config.llamaServer.lastPathComponent, "llama-server")
            #endif
            expectEqual(Array(EngineConfig.enginesDirectory.pathComponents.suffix(2)), ["Lucid", "engines"])
            #if !os(macOS)
            // With no engine installed, Lucid says to put each in a folder of its own.
            if !FileManager.default.isExecutableFile(atPath: config.whisperServer.path) {
                expectEqual(
                    Array(config.whisperServer.pathComponents.suffix(3).prefix(2)), ["engines", "whisper-server"]
                )
            }
            #endif
        }

        test("finds an engine unzipped anywhere in the engines folder") {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lucid-engines-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: folder) }
            let files = FileManager.default
            // Any program will do as a stand-in: what matters is where it is and what it is called.
            let program = TestTools.failing.executable
            let name = "stand-in-engine" + (program.pathExtension.isEmpty ? "" : "." + program.pathExtension)
            for place in ["whisper/Release", "llama", "too/deep/for/lucid/to/look"] {
                let home = folder.appendingPathComponent(place)
                try files.createDirectory(at: home, withIntermediateDirectories: true)
            }
            expectEqual(EngineConfig.findInEngines(name, under: folder), nil)
            try files.copyItem(at: program, to: folder.appendingPathComponent("too/deep/for/lucid/to/look").appendingPathComponent(name))
            expectEqual(EngineConfig.findInEngines(name, under: folder), nil)
            try files.copyItem(at: program, to: folder.appendingPathComponent("whisper/Release").appendingPathComponent(name))
            expectEqual(
                EngineConfig.findInEngines(name, under: folder)?.pathComponents.suffix(3).joined(separator: "/"),
                "whisper/Release/" + name
            )
            expectEqual(EngineConfig.findInEngines("something-else", under: folder), nil)
            expectEqual(EngineConfig.findInEngines(name, under: folder.appendingPathComponent("missing")), nil)
        }

        test("prefers the engines that came with the app") {
            let files = FileManager.default
            let folder = files.temporaryDirectory.appendingPathComponent("lucid-bundled-\(UUID().uuidString)")
            defer { try? files.removeItem(at: folder) }
            // Any program will do as a stand-in: what matters is where it is and what it is called.
            let program = TestTools.failing.executable
            let name = "whisper-server" + (program.pathExtension.isEmpty ? "" : "." + program.pathExtension)
            let home = folder.appendingPathComponent("engines/whisper-server")
            try files.createDirectory(at: home, withIntermediateDirectories: true)
            try files.copyItem(at: program, to: home.appendingPathComponent(name))
            let found = EngineConfig.findBinary("whisper-server", bundled: [folder.appendingPathComponent("engines")])
            expectEqual(found.pathComponents.suffix(3).joined(separator: "/"), "engines/whisper-server/" + name)
            // Without any, the answer is wherever else it is, or where Lucid expects it.
            let elsewhere = EngineConfig.findBinary("whisper-server", bundled: [folder.appendingPathComponent("none")])
            expectFalse(elsewhere.path.hasPrefix(folder.path))
            expectTrue(EngineConfig.bundledEnginesDirectories.first?.lastPathComponent == "engines", "\(EngineConfig.bundledEnginesDirectories)")
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
                executable: TestTools.python,
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

        await asyncTest("stops two servers that will not stop when asked, in the time allowed for one") {
            // Each takes no notice of being asked to stop, as one of the real engines does.
            // Windows has no asking: a process there is always stopped outright.
            let stubborn = "import signal, time\nsignal.signal(signal.SIGTERM, signal.SIG_IGN)\nwhile True: time.sleep(1)"
            let servers = try (0..<2).map { index -> ServerProcess in
                let server = ServerProcess(
                    name: "stubborn \(index)", executable: TestTools.python, arguments: ["-c", stubborn],
                    port: try ServerProcess.freePort(), healthPath: "/", logURL: temporaryFile(".log")
                )
                try server.start()
                return server
            }
            // Long enough for each to have told the system it will not stop.
            try await Task.sleep(nanoseconds: 700_000_000)
            expectTrue(servers.allSatisfy(\.isRunning), "the servers did not start")
            let began = Date()
            ServerProcess.stop(servers, patience: 1)
            let took = Date().timeIntervalSince(began)
            expectFalse(servers.contains(where: \.isRunning))
            // One after the other, they would take a second each.
            expectTrue(took < 1.8, "took \(took) s")
        }

        await asyncTest("reports a server that exits straight away") {
            let log = temporaryFile(".log")
            defer { try? FileManager.default.removeItem(at: log) }
            let server = ServerProcess(
                name: "broken server",
                executable: TestTools.failing.executable,
                arguments: TestTools.failing.arguments,
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

        #if !os(Windows)
        await asyncTest("says so when a server was built for a different processor") {
            // What the system does to such a program: it stops it with this signal, before
            // the program can write anything in its log.
            let log = temporaryFile(".log")
            defer { try? FileManager.default.removeItem(at: log) }
            let server = ServerProcess(
                name: "wrong server",
                executable: TestTools.python,
                arguments: ["-c", "import os, signal, time\ntime.sleep(0.2)\nos.kill(os.getpid(), signal.SIGILL)"],
                port: try ServerProcess.freePort(),
                healthPath: "/",
                logURL: log
            )
            try server.start()
            do {
                try await server.waitUntilReady(timeout: 10)
                expectTrue(false, "expected an error")
            } catch let error as EngineError {
                let said = error.description
                expectTrue(said.contains("built for a different processor"), said)
                expectTrue(said.contains(log.path), said)
            }
        }
        #endif

        test("pid file cleanup leaves unrelated processes alone") {
            let url = temporaryFile(".pid")
            let own = ProcessInfo.processInfo.processIdentifier
            PidFile.write([own], to: url)
            expectEqual(PidFile.read(at: url), [own])
            // This test process is not an engine, so it must survive the cleanup.
            PidFile.killStale(at: url, names: ["whisper-server", "llama-server"])
            expectFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }
}
