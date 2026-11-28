import Foundation
import LucidCore
import LucidEngines

/// A local stand-in for Hugging Face. It serves files from a folder, honours byte ranges, and
/// misbehaves on request: a side file next to a served file changes how it is served.
///   .status    answer with this HTTP status instead
///   .redirect  send the client to this path instead
///   .link      add a Link header pointing at this address as the next page
///   .norange   ignore Range headers and always send the whole file
///   .cut       on a request from the start, send only this many bytes, wait a moment, then hang up
///   .slow      pause this many seconds after every 64 KB
/// Every Range header received for a file is appended to its .ranges file, or "none".
private let fakeHubScript = #"""
import http.server, os, socketserver, sys, time

ROOT, PORT = sys.argv[1], int(sys.argv[2])

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, code, body=b""):
        self.send_response(code)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/":
            return self.reply(200, b"ok")
        file = os.path.join(ROOT, path.lstrip("/"))
        def side(name):
            p = file + "." + name
            return open(p).read().strip() if os.path.exists(p) else None
        if side("status"):
            return self.reply(int(side("status")))
        if side("redirect"):
            self.send_response(302)
            self.send_header("Location", side("redirect"))
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if not os.path.isfile(file):
            return self.reply(404)
        data = open(file, "rb").read()
        wanted = self.headers.get("Range")
        with open(file + ".ranges", "a") as log:
            log.write((wanted or "none") + "\n")
        start = 0
        if wanted and side("norange") is None:
            start = int(wanted.split("=")[1].split("-")[0])
            if start >= len(data):
                return self.reply(416)
            self.send_response(206)
            self.send_header("Content-Range", "bytes %d-%d/%d" % (start, len(data) - 1, len(data)))
        else:
            self.send_response(200)
        body = data[start:]
        self.send_header("Content-Length", str(len(body)))
        if side("link"):
            self.send_header("Link", '<%s>; rel="next"' % side("link"))
        self.end_headers()
        if side("cut") is not None and start == 0:
            self.wfile.write(body[:int(side("cut"))])
            self.wfile.flush()
            # Give the client time to take in what was sent. When a connection drops at once, a
            # client may report the loss before it hands over the last bytes it received.
            time.sleep(0.5)
            return
        pause = float(side("slow") or 0)
        for i in range(0, len(body), 65536):
            self.wfile.write(body[i:i + 65536])
            if pause:
                self.wfile.flush()
                time.sleep(pause)

class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True

Server(("127.0.0.1", PORT), Handler).serve_forever()
"""#

private final class FakeHub {
    let root: URL
    let server: ServerProcess

    var hub: HuggingFace { HuggingFace(baseURL: server.baseURL) }

    private init(root: URL, server: ServerProcess) {
        self.root = root
        self.server = server
    }

    static func start() async throws -> FakeHub {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lucid-hub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = root.appendingPathComponent("server.py")
        try Data(fakeHubScript.utf8).write(to: script)
        let port = try ServerProcess.freePort()
        let server = ServerProcess(
            name: "fake Hugging Face",
            executable: TestTools.python,
            arguments: [script.path, root.appendingPathComponent("site").path, String(port)],
            port: port,
            healthPath: "/",
            logURL: root.appendingPathComponent("server.log")
        )
        try server.start()
        try await server.waitUntilReady(timeout: 30)
        return FakeHub(root: root, server: server)
    }

    func stop() {
        server.stop()
        try? FileManager.default.removeItem(at: root)
    }

    private func url(_ path: String) -> URL {
        root.appendingPathComponent("site").appendingPathComponent(path)
    }

    func put(_ data: Data, at path: String) {
        let file = url(path)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file)
    }

    func side(_ path: String, _ name: String, _ value: String) {
        put(Data(value.utf8), at: path + "." + name)
    }

    /// The Range headers the server received for a file, oldest first.
    func ranges(_ path: String) -> [String] {
        let text = (try? String(contentsOf: url(path + ".ranges"), encoding: .utf8)) ?? ""
        // On Windows the server ends each line with a carriage return and a line feed, which
        // Swift reads as one character. Any kind of line break separates the entries.
        return text.split(whereSeparator: { $0.isNewline }).map(String.init)
    }

    /// The answer Hugging Face gives for a repository's files.
    func tree(_ repo: String, page: String = "main", _ files: [(path: String, size: Int)], next: String? = nil) {
        let entries = files.map { file -> [String: Any] in
            var entry: [String: Any] = ["type": "file", "path": file.path, "size": file.size, "oid": "0"]
            if file.path.hasSuffix(".gguf") || file.path.hasSuffix(".bin") {
                entry["lfs"] = ["oid": "0", "size": file.size, "pointerSize": 134]
            }
            return entry
        } + [["type": "directory", "path": "docs", "oid": "0", "size": 0]]
        let path = "api/models/\(repo)/tree/\(page)"
        put((try? JSONSerialization.data(withJSONObject: entries)) ?? Data(), at: path)
        if let next { side(path, "link", next) }
    }
}

/// Set from a download's progress callback, read by the test.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64 = 0

    func record(_ bytes: Int64) {
        lock.lock()
        value = max(value, bytes)
        lock.unlock()
    }

    var bytes: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private func temporaryFolder() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("lucid-downloads-\(UUID().uuidString)")
}

private func expectDownloadError(
    _ expected: DownloadError, file: String = #fileID, line: Int = #line, _ body: () async throws -> Void
) async {
    do {
        try await body()
        expectTrue(false, "expected \(expected)", file: file, line: line)
    } catch let error as DownloadError {
        expectEqual(error, expected, file: file, line: line)
    } catch {
        expectTrue(false, "unexpected error \(error)", file: file, line: line)
    }
}

func downloadTests() async {
    suite("Hugging Face names") {
        typealias Reference = HuggingFace.Reference

        test("reads model names and links") {
            expectEqual(HuggingFace.parse("ggerganov/whisper.cpp"), Reference(repo: "ggerganov/whisper.cpp"))
            expectEqual(
                HuggingFace.parse("  https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/ "),
                Reference(repo: "unsloth/Qwen3.5-4B-GGUF")
            )
            expectEqual(
                HuggingFace.parse("https://huggingface.co/superwhisper/s1-mini-GGUF/blob/main/s1-mini-q4_k_m.gguf"),
                Reference(repo: "superwhisper/s1-mini-GGUF", path: "s1-mini-q4_k_m.gguf")
            )
            expectEqual(
                HuggingFace.parse("hf.co/owner/repo/resolve/v1.0/Q4/model.gguf?download=true"),
                Reference(repo: "owner/repo", revision: "v1.0", path: "Q4/model.gguf")
            )
            expectEqual(HuggingFace.parse("huggingface.co/owner/repo/tree/dev"), Reference(repo: "owner/repo", revision: "dev"))
        }

        test("refuses what is not a model on Hugging Face") {
            let texts = [
                "", "whisper", "a/b/c", "owner/re po", "../x", "https://github.com/ggerganov/whisper.cpp",
                "https://huggingface.co/datasets/owner/repo", "https://huggingface.co/owner", "ftp://huggingface.co/a/b",
            ]
            for text in texts {
                expectTrue(HuggingFace.parse(text) == nil, "accepted \(text)")
            }
        }

        test("tells model files from other files by their names") {
            expectEqual(HuggingFace.kind(ofPath: "ggml-base.en.bin"), .speech)
            expectEqual(HuggingFace.kind(ofPath: "Qwen3.5-4B-Q4_K_M.gguf"), .cleanup)
            expectEqual(HuggingFace.kind(ofPath: "Q4_K_M/Model-Q4_K_M.GGUF"), .cleanup)
            expectEqual(HuggingFace.kind(ofPath: "mmproj-F16.gguf"), nil)
            expectEqual(HuggingFace.kind(ofPath: "big-Q8_0-00001-of-00003.gguf"), nil)
            expectEqual(HuggingFace.kind(ofPath: "pytorch_model.bin"), nil)
            expectEqual(HuggingFace.kind(ofPath: "ggml-large-v3-turbo-encoder.mlmodelc.zip"), nil)
            expectEqual(HuggingFace.kind(ofPath: "README.md"), nil)
        }

        test("finds the next page in a Link header") {
            let header = #"<https://huggingface.co/api/models/a/b/tree/main?cursor=abc>; rel="next""#
            expectEqual(HuggingFace.nextPage(header)?.absoluteString, "https://huggingface.co/api/models/a/b/tree/main?cursor=abc")
            expectEqual(HuggingFace.nextPage(#"<https://x.co/1>; rel="prev""#), nil)
            expectEqual(HuggingFace.nextPage(nil), nil)
        }

        test("builds download and page links") {
            let model = RemoteModel(repo: "owner/repo", path: "Q4/model one.gguf", bytes: 1, kind: .cleanup)
            expectEqual(
                HuggingFace().downloadURL(for: model).absoluteString,
                "https://huggingface.co/owner/repo/resolve/main/Q4/model%20one.gguf"
            )
            expectEqual(model.fileName, "model one.gguf")
            expectEqual(HuggingFace().pageURL(repo: "owner/repo").absoluteString, "https://huggingface.co/owner/repo")
        }

        test("suggests Lucid's own models first, with names Lucid can use") {
            let first = ModelCatalog.suggested.prefix(3).map(\.remote.fileName)
            expectEqual(first, [EngineConfig.defaultSpeechModel, EngineConfig.s1Mini.fileName, EngineConfig.general.fileName])
            for model in ModelCatalog.suggested {
                expectEqual(HuggingFace.kind(ofPath: model.remote.path), model.remote.kind)
                expectTrue((model.remote.bytes ?? 0) > 100_000_000, "\(model.name) has no size")
            }
            expectEqual(ModelCatalog.suggestion(for: EngineConfig.s1Mini.fileName)?.name, "S1-mini by Superwhisper")
        }
    }

    await asyncSuite("Downloads") {
        let fake: FakeHub
        do {
            fake = try await FakeHub.start()
        } catch {
            test("starts the stand-in for Hugging Face") { throw error }
            return
        }
        defer { fake.stop() }

        await asyncTest("lists a repository's model files, page by page") {
            fake.tree("owner/models", [("README.md", 100), ("ggml-base.en.bin", 147_964_211), ("mmproj-F16.gguf", 9)],
                      next: "\(fake.server.baseURL.absoluteString)/api/models/owner/models/tree/page2")
            fake.tree("owner/models", page: "page2", [("sub/Model-Q4_K_M.gguf", 2_000_000_000), ("pytorch_model.bin", 5)])
            let files = try await fake.hub.modelFiles(in: HuggingFace.Reference(repo: "owner/models"))
            expectEqual(files.map(\.path), ["ggml-base.en.bin", "sub/Model-Q4_K_M.gguf"])
            expectEqual(files.map(\.kind), [.speech, .cleanup])
            expectEqual(files.map(\.bytes), [147_964_211, 2_000_000_000])
            expectEqual(files.last?.fileName, "Model-Q4_K_M.gguf")
        }

        await asyncTest("finds one file from a link to it") {
            fake.tree("owner/pick", [("a.gguf", 10), ("b.gguf", 20)])
            let files = try await fake.hub.modelFiles(in: HuggingFace.Reference(repo: "owner/pick", path: "b.gguf"))
            expectEqual(files.map(\.path), ["b.gguf"])
            await expectDownloadError(.fileNotFound("c.gguf")) {
                _ = try await fake.hub.modelFiles(in: HuggingFace.Reference(repo: "owner/pick", path: "c.gguf"))
            }
        }

        await asyncTest("explains a repository that is missing or has nothing usable") {
            fake.side("api/models/owner/secret/tree/main", "status", "401")
            await expectDownloadError(.unavailable("owner/secret")) {
                _ = try await fake.hub.modelFiles(in: HuggingFace.Reference(repo: "owner/secret"))
            }
            fake.tree("owner/weights", [("pytorch_model.bin", 5), ("config.json", 1)])
            await expectDownloadError(.noModelFiles("owner/weights")) {
                _ = try await fake.hub.modelFiles(in: HuggingFace.Reference(repo: "owner/weights"))
            }
        }

        await asyncTest("downloads a model through a redirect, checks it and puts it in place") {
            let folder = temporaryFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let model = chatModel()
            fake.put(model, at: "storage/abc123")
            fake.side("owner/repo/resolve/main/Phi-4-mini-Q4_K_M.gguf", "redirect", "/storage/abc123")
            let remote = RemoteModel(repo: "owner/repo", path: "Phi-4-mini-Q4_K_M.gguf", bytes: Int64(model.count), kind: .cleanup)
            let counter = Counter()

            let added = try await ModelLibrary(directory: folder).download(remote, from: fake.hub) { received, _ in
                counter.record(received)
            }
            expectEqual(added.model.fileName, "Phi-4-mini-Q4_K_M.gguf")
            expectEqual(added.model.style, .general)
            expectEqual(try Data(contentsOf: folder.appendingPathComponent("Phi-4-mini-Q4_K_M.gguf")), model)
            expectEqual(counter.bytes, Int64(model.count))
            expectEqual(ModelLibrary(directory: folder).partialBytes(of: "Phi-4-mini-Q4_K_M.gguf"), nil)
            await expectModelError(.alreadyInstalled("Phi-4-mini-Q4_K_M.gguf")) {
                _ = try await ModelLibrary(directory: folder).download(remote, from: fake.hub)
            }
        }

        await asyncTest("continues a download that stopped, asking only for the rest") {
            let folder = temporaryFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let model = chatModel()
            // Hugging Face sends downloads on to its storage, so the range has to survive the redirect.
            let path = "storage/resumed"
            fake.put(model, at: path)
            fake.side(path, "cut", "20000")
            fake.side("owner/repo/resolve/main/resumed.gguf", "redirect", "/" + path)
            let remote = RemoteModel(repo: "owner/repo", path: "resumed.gguf", bytes: Int64(model.count), kind: .cleanup)
            let library = ModelLibrary(directory: folder)

            do {
                _ = try await library.download(remote, from: fake.hub)
                expectTrue(false, "the first download should have stopped")
            } catch let error as DownloadError {
                if case .interrupted = error {} else if case .incomplete = error {} else {
                    expectTrue(false, "unexpected error \(error)")
                }
            }
            // How much was kept is up to the system: all of what was sent, or a little less if
            // the connection dropped before the last of it was handed over.
            let kept = library.partialBytes(of: "resumed.gguf") ?? 0
            expectTrue(kept > 0 && kept <= 20000, "kept \(kept) bytes of the 20000 sent")

            _ = try await library.download(remote, from: fake.hub)
            expectEqual(try Data(contentsOf: folder.appendingPathComponent("resumed.gguf")), model)
            expectEqual(fake.ranges(path), ["none", "bytes=\(kept)-"])
        }

        await asyncTest("starts again when the server ignores the range") {
            let folder = temporaryFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let model = chatModel()
            let path = "owner/repo/resolve/main/whole.gguf"
            fake.put(model, at: path)
            fake.side(path, "norange", "yes")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(repeating: 7, count: 5000).write(to: folder.appendingPathComponent("whole.gguf.part"))
            let remote = RemoteModel(repo: "owner/repo", path: "whole.gguf", bytes: Int64(model.count), kind: .cleanup)

            _ = try await ModelLibrary(directory: folder).download(remote, from: fake.hub)
            expectEqual(try Data(contentsOf: folder.appendingPathComponent("whole.gguf")), model)
        }

        await asyncTest("refuses a file that is not the size Hugging Face gave") {
            let folder = temporaryFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let model = chatModel()
            fake.put(model, at: "owner/repo/resolve/main/short.gguf")
            let remote = RemoteModel(repo: "owner/repo", path: "short.gguf", bytes: Int64(model.count) + 10, kind: .cleanup)
            await expectDownloadError(.incomplete) {
                _ = try await ModelLibrary(directory: folder).download(remote, from: fake.hub)
            }
            expectFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("short.gguf").path))
        }

        await asyncTest("deletes a download that turns out not to be a usable model") {
            let folder = temporaryFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let addOn = chatModel(architecture: "clip")
            fake.put(addOn, at: "owner/repo/resolve/main/vision.gguf")
            let remote = RemoteModel(repo: "owner/repo", path: "vision.gguf", bytes: Int64(addOn.count), kind: .cleanup)
            do {
                _ = try await ModelLibrary(directory: folder).download(remote, from: fake.hub)
                expectTrue(false, "expected the add-on to be refused")
            } catch let error as ModelError {
                expectEqual(error, .notStandalone("a vision add-on (mmproj)"))
            }
            expectEqual(ModelLibrary(directory: folder).models(), [])
            expectEqual(ModelLibrary(directory: folder).partialBytes(of: "vision.gguf"), nil)
        }

        await asyncTest("explains a model that needs an account") {
            let folder = temporaryFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            fake.side("gated/model/resolve/main/model.gguf", "status", "403")
            let remote = RemoteModel(repo: "gated/model", path: "model.gguf", bytes: 100, kind: .cleanup)
            await expectDownloadError(.needsAccess("gated/model")) {
                _ = try await ModelLibrary(directory: folder).download(remote, from: fake.hub)
            }
            expectFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("model.gguf.part").path))
            let missing = RemoteModel(repo: "owner/repo", path: "gone.gguf", bytes: 100, kind: .cleanup)
            await expectDownloadError(.fileNotFound("gone.gguf")) {
                _ = try await ModelLibrary(directory: folder).download(missing, from: fake.hub)
            }
        }

        await asyncTest("stops when cancelled, and keeps what arrived") {
            let folder = temporaryFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let model = chatModel() + Data(repeating: 0, count: 2_000_000)
            let path = "owner/repo/resolve/main/slow.gguf"
            fake.put(model, at: path)
            fake.side(path, "slow", "0.05")
            let remote = RemoteModel(repo: "owner/repo", path: "slow.gguf", bytes: Int64(model.count), kind: .cleanup)
            let library = ModelLibrary(directory: folder)
            let counter = Counter()

            let task = Task {
                try await library.download(remote, from: fake.hub) { received, _ in counter.record(received) }
            }
            let deadline = Date().addingTimeInterval(10)
            while counter.bytes == 0, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
            task.cancel()
            do {
                _ = try await task.value
                expectTrue(false, "expected the download to stop")
            } catch is CancellationError {
                expectTrue(true)
            } catch {
                expectTrue(false, "unexpected error \(error)")
            }
            let kept = library.partialBytes(of: "slow.gguf") ?? 0
            expectTrue(kept > 0 && kept < Int64(model.count), "kept \(kept) of \(model.count) bytes")
            expectFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("slow.gguf").path))
        }
    }
}

private func expectModelError(
    _ expected: ModelError, file: String = #fileID, line: Int = #line, _ body: () async throws -> Void
) async {
    do {
        try await body()
        expectTrue(false, "expected \(expected)", file: file, line: line)
    } catch let error as ModelError {
        expectEqual(error, expected, file: file, line: line)
    } catch {
        expectTrue(false, "unexpected error \(error)", file: file, line: line)
    }
}
