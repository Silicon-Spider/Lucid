import Foundation
import LucidApp
import LucidCore
import LucidEngines

/// A shell that records what the driver asks of it, and plays back a recording.
private final class FakeShell: HeadlessShell {
    let main = DispatchQueue(label: "fake main thread")
    var audio: [Int16] = []
    var microphone: String?
    var typed: [String] = []
    var copied: [String] = []
    var pill: [String] = []
    var previews: [String] = []
    var canType = true
    var target = DeskTarget(appName: "notepad", appID: "notepad.exe")
    private var isRecording = false

    override func startRecording() throws { isRecording = true }
    override func stopRecording() -> [Int16] {
        defer { isRecording = false }
        return isRecording ? audio : []
    }
    override var recordedSeconds: Double { isRecording ? Double(audio.count) / 16_000 : 0 }
    override func latestAudio(seconds: Double) -> [Int16] { Array(audio.suffix(Int(seconds * 16_000))) }
    override var microphoneProblem: String? { microphone }
    override func showPill(_ status: PillStatus) { pill.append("\(status)") }
    override func flashPill(_ text: String, seconds: Double) { pill.append("flash: \(text)") }
    override func pulsePill() { pill.append("pulse") }
    override func setPreview(_ text: String) { previews.append(text) }
    override func captureTarget() -> DeskTarget { target }
    override func insert(_ text: String, into target: DeskTarget) -> Bool {
        if canType { typed.append(text) } else { copied.append(text) }
        return canType
    }
    override func copy(_ text: String) { copied.append(text) }
    override func onMain(_ work: @escaping () -> Void) {
        let carried = Carried(work)
        main.async { carried.work() }
    }
    override var canDictate: Bool { true }
    override var hotkeys: [HotkeyOption] { [HotkeyOption(id: "rightControl", title: "Right Ctrl"), HotkeyOption(id: "rightAlt", title: "Right Alt")] }
    override var defaultHotkey: String { "rightControl" }
    override func setupChecks() -> [SetupCheck] { [SetupCheck(id: "microphone", title: "Microphone", detail: "Found.", done: true)] }

    /// Runs something on the stand-in main thread and waits for it.
    @discardableResult
    func run<Value>(_ body: () -> Value) -> Value { main.sync(execute: body) }
}

/// Stands in for the speech and cleanup engines.
private final class FakeEngine: DictationEngine, @unchecked Sendable {
    var heard = "um so let's meet at three"
    var cleaned = "So let's meet at three."
    var fails = false
    var contexts: [PipelineContext] = []
    var previewCount = 0

    func dictate(wav: Data, context: PipelineContext) async throws -> DictationOutcome {
        contexts.append(context)
        if fails { throw EngineError.notReady("the speech engine is not running") }
        let result = PipelineResult(
            raw: heard, rulesText: heard, finalText: cleaned, llmAttempted: true, llmUsed: true,
            fallback: nil, rejectedReply: nil, cleanMillis: 5
        )
        return DictationOutcome(heard: heard, speechMillis: 7, result: result)
    }

    func preview(wav: Data, prompt: String) async -> String? {
        previewCount += 1
        return "so let's meet"
    }
}

private func temporaryFolder() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("lucid-desk-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Two seconds of a loud tone, which counts as speech.
private func speech(seconds: Double = 2) -> [Int16] {
    (0..<Int(seconds * 16_000)).map { Int16(6000 * sin(Double($0) * 0.2)) }
}

private func waitUntil(_ condition: @escaping () -> Bool) async {
    for _ in 0..<200 where !condition() { try? await Task.sleep(nanoseconds: 20_000_000) }
}

private struct Rig {
    let folder = temporaryFolder()
    let shell = FakeShell()
    let engine = FakeEngine()
    let settings: SettingsStore
    let history: HistoryDesk
    let driver: DictationDriver

    init() {
        settings = SettingsStore(url: folder.appendingPathComponent("settings.json"))
        history = HistoryDesk(directory: folder)
        driver = DictationDriver(
            shell: shell, engines: engine, settings: settings, history: history,
            dictionaryURL: folder.appendingPathComponent("dictionary.json")
        )
        // A press counts as a hold straight away, so the tests need not wait.
        driver.timing.holdThreshold = 0
        shell.audio = speech()
    }

    /// Holds the dictation key, lets go, and waits for the dictation to be dealt with.
    func dictate() async {
        shell.run { driver.handle(.hotkeyDown) }
        shell.run { driver.handle(.hotkeyUp) }
        let shell = shell
        await waitUntil { shell.run { shell.pill.last.map { $0 == "hidden" || $0.hasPrefix("flash") } ?? false } }
    }

    func cleanUp() { try? FileManager.default.removeItem(at: folder) }
}

func deskTests() async {
    await asyncSuite("Dictation driver") {
        await asyncTest("hold, speak, let go: the cleaned text is typed and remembered") {
            let rig = Rig()
            defer { rig.cleanUp() }
            await rig.dictate()
            expectEqual(rig.shell.run { rig.shell.typed }, ["So let's meet at three."])
            expectEqual(rig.shell.run { rig.shell.pill }, ["recording", "processing", "hidden"])
            let entry = rig.history.entries.first
            expectEqual(entry?.result?.finalText, "So let's meet at three.")
            expectEqual(entry?.result?.raw, "um so let's meet at three")
            expectEqual(entry?.appName, "notepad")
            expectTrue(entry.map { rig.history.hasAudio($0) } ?? false, "the recording was not kept")
            expectFalse(rig.driver.isRecording)
        }

        await asyncTest("the app being typed into decides the style") {
            let rig = Rig()
            defer { rig.cleanUp() }
            rig.shell.target = DeskTarget(appName: "Slack", appID: "slack.exe", before: "see you")
            rig.settings.update { $0.level = .medium }
            await rig.dictate()
            expectEqual(rig.engine.contexts.first?.category, .chat)
            expectEqual(rig.engine.contexts.first?.level, .medium)
            expectEqual(rig.engine.contexts.first?.midSentence, true)
            // The cursor sat straight after a word, so a space goes in first.
            expectEqual(rig.shell.run { rig.shell.typed }, [" So let's meet at three."])
        }

        await asyncTest("where nothing can be typed, the text is left on the clipboard") {
            let rig = Rig()
            defer { rig.cleanUp() }
            rig.shell.canType = false
            await rig.dictate()
            expectEqual(rig.shell.run { rig.shell.copied }, ["So let's meet at three."])
            expectEqual(rig.shell.run { rig.shell.pill.last }, "flash: Copied. Press Ctrl+V")
        }

        await asyncTest("silence is not sent to the engines") {
            let rig = Rig()
            defer { rig.cleanUp() }
            rig.shell.audio = [Int16](repeating: 0, count: 32_000)
            await rig.dictate()
            expectEqual(rig.shell.run { rig.shell.pill.last }, "flash: Didn't catch that")
            expectEqual(rig.engine.contexts.count, 0)
            expectEqual(rig.history.entries.count, 0)
        }

        await asyncTest("a dictation that fails is kept, with its recording, and can be retried") {
            let rig = Rig()
            defer { rig.cleanUp() }
            rig.engine.fails = true
            await rig.dictate()
            expectEqual(rig.shell.run { rig.shell.pill.last }, "flash: Couldn't transcribe. Recording kept.")
            let failed = rig.history.entries.first
            expectTrue(failed?.result == nil && failed?.failure?.contains("not running") == true, "\(String(describing: failed))")

            rig.engine.fails = false
            let said = await rig.driver.retry(failed?.id ?? UUID())
            expectEqual(said, "Transcribed and copied.")
            expectEqual(rig.history.entries.count, 1)
            expectEqual(rig.history.entries.first?.result?.finalText, "So let's meet at three.")
            let shell = rig.shell
            await waitUntil { shell.run { !shell.copied.isEmpty } }
            expectEqual(shell.run { shell.copied }, ["So let's meet at three."])
            expectEqual(shell.run { shell.typed }, [])
        }

        await asyncTest("with recordings switched off, none is kept") {
            let rig = Rig()
            defer { rig.cleanUp() }
            rig.settings.update { $0.keepRecordings = false }
            rig.engine.fails = true
            await rig.dictate()
            expectEqual(rig.shell.run { rig.shell.pill.last }, "flash: Couldn't transcribe that")
            expectFalse(rig.history.entries.first.map { rig.history.hasAudio($0) } ?? true)
        }

        await asyncTest("a microphone that cannot be used says so, and nothing is recorded") {
            let rig = Rig()
            defer { rig.cleanUp() }
            rig.shell.microphone = "Lucid cannot use the microphone"
            rig.shell.run { rig.driver.handle(.hotkeyDown) }
            expectEqual(rig.shell.run { rig.shell.pill }, ["hidden", "flash: Lucid cannot use the microphone"])
            expectFalse(rig.driver.isRecording)
        }

        await asyncTest("Escape cancels a recording, and only then is it kept from other apps") {
            let rig = Rig()
            defer { rig.cleanUp() }
            expectFalse(rig.shell.run { rig.driver.handle(.escape) })
            rig.shell.run { rig.driver.handle(.hotkeyDown) }
            expectTrue(rig.driver.isRecording)
            expectTrue(rig.shell.run { rig.driver.handle(.escape) })
            expectFalse(rig.driver.isRecording)
            expectEqual(rig.shell.run { rig.shell.pill }, ["recording", "hidden"])
            expectEqual(rig.engine.contexts.count, 0)
        }

        await asyncTest("the words heard so far are shown while still speaking") {
            let rig = Rig()
            defer { rig.cleanUp() }
            rig.shell.run { rig.driver.handle(.hotkeyDown) }
            let shell = rig.shell
            await waitUntil { shell.run { !shell.previews.isEmpty } }
            expectEqual(shell.run { shell.previews.first }, "so let's meet")
            shell.run { rig.driver.handle(.hotkeyUp) }
            await waitUntil { shell.run { shell.pill.last == "hidden" } }
            let shown = rig.engine.previewCount
            try await Task.sleep(nanoseconds: 600_000_000)
            expectEqual(rig.engine.previewCount, shown)
        }

        await asyncTest("with the preview switched off, the engine is not asked") {
            let rig = Rig()
            defer { rig.cleanUp() }
            rig.settings.update { $0.livePreview = false }
            rig.shell.run { rig.driver.handle(.hotkeyDown) }
            try await Task.sleep(nanoseconds: 700_000_000)
            expectEqual(rig.engine.previewCount, 0)
            rig.shell.run { rig.driver.handle(.escape) }
        }
    }

    await asyncSuite("Lucid's window") {
        /// A desk with a stand-in shell, its own folder, and a few stand-in models.
        func makeDesk() throws -> (Desk, URL) {
            let folder = temporaryFolder()
            let models = folder.appendingPathComponent("models")
            try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
            try whisperHeader().write(to: models.appendingPathComponent(EngineConfig.defaultSpeechModel))
            try whisperHeader().write(to: models.appendingPathComponent("ggml-small.en.bin"))
            try chatModel().write(to: models.appendingPathComponent(EngineConfig.s1Mini.fileName))
            try chatModel().write(to: models.appendingPathComponent("llama.gguf"))
            let desk = try Desk(shell: FakeShell(), folder: folder, library: ModelLibrary(directory: models), tracksProcesses: false)
            return (desk, folder)
        }

        func ask(_ desk: Desk, _ path: String, _ body: [String: Any]? = nil, key: String? = nil, host: String? = nil) async -> (Int, [String: Any]) {
            var headers = ["host": host ?? "127.0.0.1:\(desk.server.port)"]
            headers["x-lucid-key"] = key ?? desk.key
            let pieces = path.split(separator: "?", maxSplits: 1).map(String.init)
            var query: [String: String] = [:]
            if pieces.count == 2 {
                for pair in pieces[1].split(separator: "&") {
                    let sides = pair.split(separator: "=", maxSplits: 1).map(String.init)
                    query[sides[0]] = sides.count == 2 ? sides[1] : ""
                }
            }
            let data = body.flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data()
            let request = HTTPRequest(method: body == nil ? "GET" : "POST", path: pieces[0], query: query, headers: headers, body: data)
            let response = await desk.respond(to: request)
            let object = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any]
            return (response.status, object ?? ["text": String(decoding: response.body, as: UTF8.self)])
        }

        func part(_ state: [String: Any], _ name: String) -> [String: Any] { state[name] as? [String: Any] ?? [:] }

        await asyncTest("serves the page to this computer only, and its requests only with the key") {
            let (desk, folder) = try makeDesk()
            defer { try? FileManager.default.removeItem(at: folder) }
            let (pageStatus, page) = await ask(desk, "/", key: "")
            expectEqual(pageStatus, 200)
            expectTrue((page["text"] as? String)?.contains("<title>Lucid</title>") == true, "the page was not served")
            expectEqual(await ask(desk, "/api/state").0, 200)
            expectEqual(await ask(desk, "/api/state", key: "").0, 403)
            expectEqual(await ask(desk, "/api/state", key: "0123456789abcdef").0, 403)
            expectEqual(await ask(desk, "/api/state", host: "evil.example").0, 403)
            expectEqual(await ask(desk, "/", key: "", host: "evil.example:80").0, 403)
            expectEqual(await ask(desk, "/api/nothing").0, 404)
            expectEqual(await ask(desk, "/secrets.txt").0, 404)
            expectTrue(desk.key.count >= 24, "the key is too short: \(desk.key)")
            expectTrue(desk.windowAddress(section: "models").hasSuffix("/#models&key=\(desk.key)"), desk.windowAddress())
        }

        await asyncTest("the page really is reachable over the network on this computer") {
            let (desk, folder) = try makeDesk()
            defer { try? FileManager.default.removeItem(at: folder) }
            desk.server.start()
            defer { desk.server.stop() }
            let (status, body) = try await fetch(desk.server.address + "/api/state", headers: ["X-Lucid-Key": desk.key])
            expectEqual(status, 200)
            expectTrue(String(decoding: body, as: UTF8.self).contains("\"Lucid needs a few things first\""), "unexpected state")
            let (refused, _) = try await fetch(desk.server.address + "/api/state")
            expectEqual(refused, 403)
        }

        await asyncTest("describes the app: setup, what is in use, and the models") {
            let (desk, folder) = try makeDesk()
            defer { try? FileManager.default.removeItem(at: folder) }
            let (_, state) = await ask(desk, "/api/state")
            let status = part(state, "status")
            expectEqual(status["headline"] as? String, "Lucid needs a few things first")
            let checks = status["checks"] as? [[String: Any]] ?? []
            expectEqual(checks.map { $0["id"] as? String }, ["microphone", "engines"])
            expectEqual(checks.map { $0["done"] as? Bool }, [true, false])
            let settings = part(state, "settings")
            expectEqual(settings["hotkey"] as? String, "rightControl")
            expectEqual(settings["hotkeyTitle"] as? String, "Right Ctrl")
            expectEqual(settings["level"] as? String, "light")
            // Medium needs a model the user has chosen for it, or Lucid's own larger one.
            expectEqual(settings["mediumAvailable"] as? Bool, false)
            let models = part(state, "models")
            expectEqual(models["speech"] as? String, EngineConfig.defaultSpeechModel)
            expectEqual(models["light"] as? String, EngineConfig.s1Mini.fileName)
            let installed = models["installed"] as? [[String: Any]] ?? []
            expectEqual(installed.map { $0["name"] as? String }, ["Whisper large-v3-turbo", "S1-mini by Superwhisper", "ggml-small.en", "llama"])
            expectEqual(installed.map { $0["canChangeStyle"] as? Bool }, [false, false, false, true])
            let inUse = state["inUse"] as? [[String]] ?? []
            expectEqual(inUse.map { $0[0] }, ["Dictation key", "Cleanup", "Speech model"])
            expectEqual(inUse[1][1], "Light, with S1-mini by Superwhisper")

            expectEqual(await ask(desk, "/api/models/choose", ["medium": "llama.gguf"]).0, 200)
            let (_, after) = await ask(desk, "/api/state")
            expectEqual(part(after, "settings")["mediumAvailable"] as? Bool, true)
            expectEqual(part(after, "models")["medium"] as? String, "llama.gguf")
        }

        await asyncTest("changes and saves the settings") {
            let (desk, folder) = try makeDesk()
            defer { try? FileManager.default.removeItem(at: folder) }
            _ = await ask(desk, "/api/models/choose", ["medium": "llama.gguf"])
            expectEqual(await ask(desk, "/api/settings", ["level": "medium", "livePreview": false, "hotkey": "rightAlt"]).0, 200)
            expectEqual(desk.settings.current.level, .medium)
            expectEqual(desk.settings.current.livePreview, false)
            expectEqual(desk.hotkey, "rightAlt")
            // A key this system does not have is ignored.
            _ = await ask(desk, "/api/settings", ["hotkey": "fn"])
            expectEqual(desk.hotkey, "rightAlt")
            let reopened = SettingsStore(url: folder.appendingPathComponent("settings.json"))
            expectEqual(reopened.current.level, .medium)
            expectEqual(reopened.current.hotkey, "rightAlt")
        }

        await asyncTest("refuses Medium when no model can do it") {
            let (desk, folder) = try makeDesk()
            defer { try? FileManager.default.removeItem(at: folder) }
            let (status, reply) = await ask(desk, "/api/settings", ["level": "medium"])
            expectEqual(status, 400)
            expectTrue((reply["error"] as? String)?.contains("Medium needs a larger model") == true, "\(reply)")
            expectEqual(desk.settings.current.level, .light)
        }

        await asyncTest("chooses, renames and deletes models") {
            let (desk, folder) = try makeDesk()
            defer { try? FileManager.default.removeItem(at: folder) }
            _ = await ask(desk, "/api/models/choose", ["speech": "ggml-small.en.bin"])
            expectEqual(desk.settings.current.models.speech, "ggml-small.en.bin")
            expectEqual(await ask(desk, "/api/models/rename", ["fileName": "ggml-small.en.bin", "name": "Quick"]).0, 200)
            let (taken, why) = await ask(desk, "/api/models/rename", ["fileName": "llama.gguf", "name": "quick"])
            expectEqual(taken, 400)
            expectTrue((why["error"] as? String)?.contains("already called quick") == true, "\(why)")

            let (_, warning) = await ask(desk, "/api/models/removal?file=ggml-small.en.bin")
            let message = warning["message"] as? String ?? ""
            expectTrue(message.contains("Lucid will use Whisper large-v3-turbo for speech instead."), message)
            expectTrue(message.contains("You can download it again here."), message)

            expectEqual(await ask(desk, "/api/models/remove", ["fileName": "ggml-small.en.bin"]).0, 200)
            expectEqual(desk.settings.current.models.speech, nil)
            let (_, state) = await ask(desk, "/api/state")
            expectEqual(part(state, "models")["speech"] as? String, EngineConfig.defaultSpeechModel)
            expectEqual(await ask(desk, "/api/models/removal?file=gone.gguf").0, 404)
        }

        await asyncTest("only downloads what is a model on Hugging Face") {
            let (desk, folder) = try makeDesk()
            defer { try? FileManager.default.removeItem(at: folder) }
            expectEqual(await ask(desk, "/api/models/download", ["repo": "owner/repo", "path": "README.md"]).0, 400)
            expectEqual(await ask(desk, "/api/models/download", ["repo": "https://evil.example/x", "path": "model.gguf"]).0, 400)
            expectEqual(await ask(desk, "/api/models/download", ["repo": "../..", "path": "model.gguf"]).0, 400)
            expectEqual(desk.models.activeDownloads.count, 0)
            let (status, reply) = await ask(desk, "/api/models/lookup", ["text": "not a model"])
            expectEqual(status, 400)
            expectTrue((reply["error"] as? String)?.contains("not a model on Hugging Face") == true, "\(reply)")
        }

        await asyncTest("edits the dictionary, and leaves a broken one alone") {
            let (desk, folder) = try makeDesk()
            defer { try? FileManager.default.removeItem(at: folder) }
            _ = await ask(desk, "/api/dictionary", ["kind": "addTerm", "text": " GitHub "])
            _ = await ask(desk, "/api/dictionary", ["kind": "addReplacement", "from": "jon", "to": "John"])
            let (_, state) = await ask(desk, "/api/state")
            expectEqual(part(state, "dictionary")["terms"] as? [String], ["GitHub"])
            _ = await ask(desk, "/api/dictionary", ["kind": "removeTerm", "text": "GitHub"])
            expectEqual(try PersonalDictionary.load(from: desk.dictionaryURL).terms, [])
            expectEqual(try PersonalDictionary.load(from: desk.dictionaryURL).replacements.count, 1)

            try Data("{ this is not a dictionary".utf8).write(to: desk.dictionaryURL)
            expectEqual(await ask(desk, "/api/dictionary", ["kind": "addTerm", "text": "Lucid"]).0, 400)
            expectEqual(try String(contentsOf: desk.dictionaryURL, encoding: .utf8), "{ this is not a dictionary")
            let (_, broken) = await ask(desk, "/api/state")
            expectTrue((part(broken, "dictionary")["problem"] as? String)?.contains("could not be read") == true, "no problem reported")
        }

        await asyncTest("lists, deletes and clears history") {
            let (desk, folder) = try makeDesk()
            defer { try? FileManager.default.removeItem(at: folder) }
            let result = PipelineResult(
                raw: "um hello", rulesText: "hello", finalText: "Hello.", llmAttempted: false, llmUsed: false,
                fallback: nil, rejectedReply: nil, cleanMillis: 100
            )
            let kept = desk.history.add(
                HistoryEntry(date: Date(), appName: "notepad", bundleID: "notepad.exe", audioSeconds: 1, speechMillis: 400, result: result, failure: nil),
                wav: Data([1, 2, 3])
            )
            desk.history.add(
                HistoryEntry(date: Date(), appName: "slack", bundleID: nil, audioSeconds: 1, speechMillis: 0, result: nil, failure: "It broke."),
                wav: nil
            )
            let (_, state) = await ask(desk, "/api/state")
            let list = state["history"] as? [[String: Any]] ?? []
            expectEqual(list.map { $0["app"] as? String }, ["slack", "notepad"])
            expectEqual(list.last?["text"] as? String, "Hello.")
            expectEqual(list.last?["original"] as? String, "um hello")
            expectEqual(list.last?["seconds"] as? String, "0.5 s")
            expectEqual(list.last?["hasAudio"] as? Bool, true)
            expectEqual(list.first?["failure"] as? String, "It broke.")

            _ = await ask(desk, "/api/history/remove", ["id": kept.id.uuidString])
            expectEqual(desk.history.entries.map(\.appName), ["slack"])
            _ = await ask(desk, "/api/history/clear", [:])
            expectEqual(desk.history.entries.count, 0)
        }
    }

    suite("Apps on Windows") {
        test("knows the kind of app from its program name") {
            expectEqual(AppCategory.forProgram("OUTLOOK.EXE"), .email)
            expectEqual(AppCategory.forProgram("slack.exe"), .chat)
            expectEqual(AppCategory.forProgram("Code.exe"), .code)
            expectEqual(AppCategory.forProgram("WindowsTerminal"), .code)
            expectEqual(AppCategory.forProgram("notepad.exe"), .other)
            expectEqual(AppCategory.forProgram(nil), .other)
            expectEqual(AppCategory.forApp("com.apple.mail"), .email)
            expectEqual(AppCategory.forApp("ms-teams.exe"), .chat)
            expectEqual(AppCategory.forApp("something.else"), .other)
        }

        test("settings from another version of Lucid still load") {
            let old = Data(#"{"level":"medium","somethingNew":true}"#.utf8)
            let settings = try JSONDecoder().decode(DeskSettings.self, from: old)
            expectEqual(settings.level, .medium)
            expectEqual(settings.livePreview, true)
            expectEqual(settings.keepRecordings, true)
            expectEqual(settings.hotkey, nil)
            expectEqual(try JSONDecoder().decode(DeskSettings.self, from: Data("{}".utf8)), DeskSettings())
        }
    }
}
