import Foundation
import LucidCore
import LucidEngines

// What the window asks of the app. The page reads one snapshot of everything, about once a
// second, and sends one small request for each thing the user does.

/// Everything the window shows.
struct DeskSnapshot: Encodable {
    struct App: Encodable {
        var version: String
        var system: String
        var canDictate: Bool
        var canChooseFiles: Bool
        var pasteKeys: String
    }

    struct Status: Encodable {
        /// "ready", "starting" or "setup".
        var state: String
        var headline: String
        var hint: String
        var checks: [SetupCheck]
        /// What the engines are doing, for the Models and Settings pages.
        var engineNote: String
        var engineFailed: Bool
    }

    struct Settings: Encodable {
        var hotkey: String
        var hotkeyTitle: String
        var hotkeys: [HotkeyOption]
        var level: String
        var levelNote: String
        var mediumAvailable: Bool
        var livePreview: Bool
        var keepRecordings: Bool
        /// Nil where opening at sign-in cannot be set.
        var opensAtLogin: Bool?
    }

    struct Model: Encodable {
        var fileName: String
        var name: String
        var originalName: String
        var kind: String
        /// The prompt format, for a cleanup model.
        var style: String?
        /// True when the user may change the prompt format: a cleanup model they added.
        var canChangeStyle: Bool
        var isBuiltIn: Bool
        var size: String
        var detail: String
        var canDownloadAgain: Bool
    }

    struct Offer: Encodable {
        var fileName: String
        var title: String
        var detail: String
        var repo: String
        var path: String
        var kind: String
        var bytes: Int64?
        /// "available", "installed", "partial" or "downloading".
        var state: String
        var progress: Double?
        var progressText: String?
    }

    struct Models: Encodable {
        var speech: String
        var light: String
        var medium: String
        var installed: [Model]
        var totalSize: String
        var offers: [Offer]
        var folder: String
        var notice: ModelDesk.Notice?
    }

    struct Dictionary: Encodable {
        var terms: [String]
        var replacements: [Replacement]
        var problem: String?
    }

    struct Dictation: Encodable {
        var id: String
        var date: Double
        var app: String
        var text: String?
        var original: String?
        var failure: String?
        var seconds: String
        var hasAudio: Bool
    }

    var app: App
    var status: Status
    var settings: Settings
    var models: Models
    var dictionary: Dictionary
    /// Which part of the window the app last asked for, from its menu. The number goes up each time.
    struct GoTo: Encodable {
        var section: String
        var serial: Int
    }

    var history: [Dictation]
    /// What is in use, for the Home page.
    var inUse: [[String]]
    var goTo: GoTo
}

extension Desk {
    private static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: The snapshot

    func snapshot() -> DeskSnapshot {
        let current = settings.current
        let installed = models.installed
        let plan = ModelLibrary.plan(for: current.models, installed: installed)
        let downloads = models.activeDownloads
        let partials = models.partials
        let checks = shell.setupChecks() + [enginesCheck(downloads: downloads)]
        let allDone = checks.allSatisfy(\.done)
        let starting = engines.status == .starting
        let hotkeyTitle = shell.hotkeys.first { $0.id == hotkey }?.title ?? "the dictation key"

        let status = DeskSnapshot.Status(
            state: allDone ? "ready" : (starting ? "starting" : "setup"),
            headline: allDone ? "Lucid is ready" : "Lucid needs a few things first",
            hint: allDone
                ? (shell.canDictate
                    ? "Hold \(hotkeyTitle) and speak, then let go. Tap it twice to keep recording hands-free."
                    : "The engines and models are in place.")
                : "It will work once every item under Setup is ticked.",
            checks: checks,
            engineNote: engineNote,
            engineFailed: { if case .failed = engines.status { return true } else { return false } }()
        )

        func name(_ fileName: String) -> String { models.displayName(of: fileName, among: installed) }
        let cleanupInUse = current.level == .off
            ? "Off"
            : current.level.rawValue.capitalized + ", with " + name(plan.cleanup(for: current.level).fileName)
        var inUse = [["Cleanup", cleanupInUse, "settings"], ["Speech model", name(plan.speech), "models"]]
        if shell.canDictate { inUse.insert(["Dictation key", hotkeyTitle, "settings"], at: 0) }

        return DeskSnapshot(
            app: .init(
                version: Self.version, system: shell.systemName, canDictate: shell.canDictate,
                canChooseFiles: shell.canChooseFiles, pasteKeys: shell.pasteKeys
            ),
            status: status,
            settings: .init(
                hotkey: hotkey,
                hotkeyTitle: hotkeyTitle,
                hotkeys: shell.hotkeys,
                level: current.level.rawValue,
                levelNote: Self.levelNote(current.level),
                mediumAvailable: plan.medium != nil,
                livePreview: current.livePreview,
                keepRecordings: current.keepRecordings,
                opensAtLogin: shell.opensAtLogin
            ),
            models: .init(
                speech: plan.speech,
                light: plan.light.fileName,
                medium: plan.medium?.fileName ?? "",
                installed: installed.map { model(for: $0, plan: plan) },
                totalSize: Self.size(installed.map(\.bytes).reduce(0, +)),
                offers: offers(installed: installed, downloads: downloads, partials: partials),
                folder: models.library.directory.path,
                notice: models.notice
            ),
            dictionary: {
                let (dictionary, problem) = personalDictionary()
                return .init(terms: dictionary.terms, replacements: dictionary.replacements, problem: problem)
            }(),
            history: history.entries.prefix(200).map { entry in
                let total = Double(entry.speechMillis + (entry.result?.cleanMillis ?? 0)) / 1000
                return .init(
                    id: entry.id.uuidString,
                    date: entry.date.timeIntervalSince1970,
                    app: entry.appName,
                    text: entry.result?.finalText,
                    original: entry.result.flatMap { $0.raw == $0.finalText ? nil : $0.raw },
                    failure: entry.result == nil ? (entry.failure ?? "") : nil,
                    seconds: entry.result == nil ? "" : String(format: "%.1f s", total),
                    hasAudio: history.hasAudio(entry)
                )
            },
            inUse: inUse,
            goTo: { let wanted = wantedSection; return .init(section: wanted.section, serial: wanted.serial) }()
        )
    }

    private static func levelNote(_ level: CleanupLevel) -> String {
        switch level {
        case .off: return "Text is inserted exactly as you said it."
        case .light: return "Removes fillers such as “um”, false starts and corrections, and fixes punctuation. Every other word is kept."
        case .medium: return "Also tightens wordy phrasing. Slower, and uses a larger model."
        }
    }

    private var engineNote: String {
        switch engines.status {
        case .starting: return "Loading the models. A large model can take a minute."
        case .ready: return "The engines are running with these models."
        case .setupNeeded(let missing): return "Setup is not finished. Missing: " + missing.joined(separator: "; ") + "."
        case .failed(let reason):
            return "The engines did not start with these models. Choose another model, or go back to Lucid's own. \(reason)"
        }
    }

    /// The Setup list's line about the engines and models, with a way to download the models.
    private func enginesCheck(downloads: [ModelDesk.Download]) -> SetupCheck {
        let title = "Speech engines and models"
        switch engines.status {
        case .ready:
            return SetupCheck(id: "engines", title: title, detail: "Running on this computer.", done: true)
        case .starting:
            return SetupCheck(id: "engines", title: title, detail: "Starting. The first start can take a minute.", done: false)
        case .failed(let reason):
            return SetupCheck(id: "engines", title: title, detail: "The engines did not start. \(reason)", done: false)
        case .setupNeeded(let missing):
            let missingFiles = engines.missingModelFiles
            let wanted = missingFiles.compactMap { ModelCatalog.suggestion(for: $0) }
            let active = downloads.filter { missingFiles.contains($0.remote.fileName) }
            let list = "Missing: " + missing.joined(separator: "; ") + "."
            if !active.isEmpty {
                let received = active.map(\.received).reduce(0, +)
                let total = active.compactMap(\.total).reduce(0, +)
                return SetupCheck(
                    id: "engines", title: title,
                    detail: "Downloading the models from Hugging Face: \(Self.size(received)) of \(Self.size(total)).",
                    done: false, progress: total > 0 ? min(1, Double(received) / Double(total)) : 0
                )
            }
            if engines.enginesMissing {
                return SetupCheck(id: "engines", title: title, detail: "The speech engines are not installed. " + Self.setupAdvice + " " + list, done: false)
            }
            var detail = "Lucid needs its speech and cleanup models, downloaded once from Hugging Face. " + list
            if let notice = models.notice, notice.isProblem { detail += " " + notice.text }
            let bytes = wanted.compactMap(\.remote.bytes).reduce(0, +)
            return SetupCheck(
                id: "engines", title: title, detail: detail, done: false,
                action: wanted.isEmpty ? nil : "Download Models (\(Self.size(bytes)))"
            )
        }
    }

    /// How to install the engines, which differs by system.
    static var setupAdvice: String {
        #if os(Windows)
        return "In PowerShell, from the Lucid folder, run scripts\\setup.ps1. It installs them and downloads the models. Then quit and reopen Lucid."
        #elseif os(macOS)
        return "In Terminal, from the Lucid folder, run scripts/setup.sh. It installs them and downloads the models. Then quit and reopen Lucid."
        #else
        return "Put whisper-server and llama-server on the PATH, or in folders of their own inside Lucid's engines folder. Then quit and reopen Lucid."
        #endif
    }

    private func model(for installed: InstalledModel, plan: ModelPlan) -> DeskSnapshot.Model {
        let original = ModelLibrary.defaultName(for: installed.fileName)
        var parts = [installed.kind == .speech ? "Speech" : "Cleanup", Self.size(installed.bytes)]
        if installed.isBuiltIn { parts.append("built in") }
        if installed.kind == .speech, installed.fileName == plan.speech { parts.append("in use") }
        var levels: [String] = []
        if installed.fileName == plan.light.fileName { levels.append("Light") }
        if installed.fileName == plan.medium?.fileName { levels.append("Medium") }
        if !levels.isEmpty { parts.append("used for " + levels.joined(separator: " and ")) }
        // A renamed model still has to be findable in the models folder.
        if installed.name != original { parts.append(installed.fileName) }
        return .init(
            fileName: installed.fileName,
            name: installed.name,
            originalName: original,
            kind: installed.kind.rawValue,
            style: installed.style?.rawValue,
            canChangeStyle: !installed.isBuiltIn && installed.kind == .cleanup,
            isBuiltIn: installed.isBuiltIn,
            size: Self.size(installed.bytes),
            detail: parts.joined(separator: " · "),
            canDownloadAgain: ModelCatalog.suggestion(for: installed.fileName) != nil
        )
    }

    /// The suggested models, then any other download under way or left unfinished.
    private func offers(installed: [InstalledModel], downloads: [ModelDesk.Download], partials: [PartialDownload]) -> [DeskSnapshot.Offer] {
        func offer(title: String, detail: String, remote: RemoteModel) -> DeskSnapshot.Offer {
            var state = "available"
            var progress: Double?
            var text: String?
            if let download = downloads.first(where: { $0.remote.fileName == remote.fileName }) {
                state = "downloading"
                if let total = download.total, total > 0 {
                    progress = min(1, Double(download.received) / Double(total))
                    text = "\(Self.size(download.received)) of \(Self.size(total))"
                } else {
                    text = "\(Self.size(download.received)) so far"
                }
            } else if installed.contains(where: { $0.fileName == remote.fileName }) {
                state = "installed"
            } else if let partial = partials.first(where: { $0.fileName == remote.fileName }) {
                state = "partial"
                text = "Unfinished: \(Self.size(partial.bytes)) so far."
            }
            return .init(
                fileName: remote.fileName, title: title, detail: detail, repo: remote.repo, path: remote.path,
                kind: remote.kind.rawValue, bytes: remote.bytes, state: state, progress: progress, progressText: text
            )
        }

        var offers = ModelCatalog.suggested.map { suggestion in
            offer(
                title: suggestion.name,
                detail: (suggestion.remote.bytes.map(Self.size) ?? "Size unknown") + " · " + suggestion.summary,
                remote: suggestion.remote
            )
        }
        // Downloads the user started by looking a model up.
        for download in downloads where ModelCatalog.suggestion(for: download.remote.fileName) == nil {
            offers.append(offer(title: download.remote.fileName, detail: "From \(download.remote.repo)", remote: download.remote))
        }
        // What stopped ones left behind. The page offers to discard these.
        for partial in partials where ModelCatalog.suggestion(for: partial.fileName) == nil
            && !downloads.contains(where: { $0.remote.fileName == partial.fileName }) {
            offers.append(.init(
                fileName: partial.fileName, title: partial.fileName,
                detail: "Look it up again to continue it.", repo: "", path: "", kind: "", bytes: nil,
                state: "partial", progress: nil, progressText: "Unfinished: \(Self.size(partial.bytes)) so far."
            ))
        }
        return offers
    }

    // MARK: Requests

    private struct Body: Decodable {
        var id: String?
        var text: String?
        var name: String?
        var fileName: String?
        var kind: String?
        var style: String?
        var repo: String?
        var path: String?
        var bytes: Int64?
        var from: String?
        var to: String?
        var hotkey: String?
        var level: String?
        var livePreview: Bool?
        var keepRecordings: Bool?
        var opensAtLogin: Bool?
        var speech: String?
        var light: String?
        var medium: String?
    }

    private struct Done: Encodable {
        var ok = true
        var message: String?
    }

    /// Answers one request from the window.
    public func respond(to request: HTTPRequest) async -> HTTPResponse {
        // Only this computer's own page may ask. A page from elsewhere that found the port
        // would be sending another site's name.
        let host = request.headers["host"] ?? ""
        guard host == "127.0.0.1:\(server.port)" || host == "localhost:\(server.port)" else {
            return .failure("Lucid's window can only be opened on this computer.", status: 403)
        }

        if request.path == "/" || request.path == "/index.html" {
            guard request.method == "GET" else { return .failure("Not allowed.", status: 405) }
            return .text(WebUI.page, contentType: "text/html; charset=utf-8")
        }
        guard request.path.hasPrefix("/api/") else { return .failure("There is nothing here.", status: 404) }
        // Everything the app can do needs the key the window was opened with.
        guard request.headers["x-lucid-key"] == key else {
            return .failure("This page has lost touch with Lucid. Open the window again from Lucid.", status: 403)
        }

        if request.method == "GET" {
            switch request.path {
            case "/api/state":
                noteWindowAsked()
                return .json(snapshot())
            case "/api/models/removal":
                guard let message = models.removalMessage(for: request.query["file"] ?? "", choices: settings.current.models) else {
                    return .failure("That model is no longer there.", status: 404)
                }
                return .json(Done(message: message))
            default:
                return .failure("There is nothing here.", status: 404)
            }
        }
        guard request.method == "POST" else { return .failure("Not allowed.", status: 405) }
        let body = request.decode(Body.self) ?? Body()
        return await act(request.path, body)
    }

    private func followModels() {
        Task { await engines.update(choices: settings.current.models, level: settings.current.level) }
    }

    private func act(_ path: String, _ body: Body) async -> HTTPResponse {
        switch path {
        case "/api/settings":
            return changeSettings(body)

        case "/api/setup/action":
            if body.id == "engines" {
                models.downloadSuggested(engines.missingModelFiles)
            } else if let id = body.id {
                let shell = shell
                shell.onMain { shell.performSetupAction(id) }
            }
            return .json(Done())

        case "/api/models/choose":
            settings.update { settings in
                if let speech = body.speech { settings.models.speech = speech }
                if let light = body.light { settings.models.light = light }
                if let medium = body.medium { settings.models.medium = medium }
            }
            followModels()
            return .json(Done())

        case "/api/models/rename":
            guard let fileName = body.fileName else { return .failure("Which model?") }
            return models.rename(fileName, to: body.name ?? "") ? .json(Done()) : .failure(models.notice?.text ?? "That name cannot be used.")

        case "/api/models/style":
            guard let fileName = body.fileName, let style = body.style.flatMap(PromptStyle.init(rawValue:)) else {
                return .failure("Which model, and which prompt?")
            }
            return models.setStyle(style, for: fileName) ? .json(Done()) : .failure(models.notice?.text ?? "That could not be changed.")

        case "/api/models/remove":
            guard let fileName = body.fileName else { return .failure("Which model?") }
            guard models.remove(fileName) else { return .failure(models.notice?.text ?? "That model could not be deleted.") }
            settings.update { $0.models.forget(fileName) }
            followModels()
            return .json(Done())

        case "/api/models/download":
            if let fileName = body.fileName, let suggestion = ModelCatalog.suggestion(for: fileName) {
                models.download(suggestion.remote)
                return .json(Done())
            }
            guard let repo = body.repo, let path = body.path, HuggingFace.parse(repo)?.repo == repo,
                  let kind = HuggingFace.kind(ofPath: path) else {
                return .failure("That is not a model file Lucid can download.")
            }
            models.download(RemoteModel(repo: repo, path: path, bytes: body.bytes, kind: kind))
            return .json(Done())

        case "/api/models/cancel":
            if let fileName = body.fileName { models.cancelDownload(fileName) }
            return .json(Done())

        case "/api/models/discard":
            if let fileName = body.fileName { models.discardPartial(fileName) }
            return .json(Done())

        case "/api/models/lookup":
            struct Found: Encodable {
                struct File: Encodable {
                    var path: String
                    var fileName: String
                    var kind: String
                    var size: String
                    var bytes: Int64?
                }

                var repo: String
                var page: String
                var files: [File]
            }
            do {
                let (repo, files) = try await models.lookUp(body.text ?? "")
                return .json(Found(
                    repo: repo,
                    page: models.hub.pageURL(repo: repo).absoluteString,
                    files: files.map {
                        .init(
                            path: $0.path, fileName: $0.fileName, kind: $0.kind.rawValue,
                            size: $0.bytes.map(Self.size) ?? "Size unknown", bytes: $0.bytes
                        )
                    }
                ))
            } catch {
                return .failure("\(error)")
            }

        case "/api/models/add":
            let kind = body.kind.flatMap(ModelKind.init(rawValue:))
            var file: URL?
            if let path = body.path?.trimmingCharacters(in: .whitespaces), !path.isEmpty {
                file = URL(fileURLWithPath: path)
            } else if shell.canChooseFiles, let kind {
                file = await chooseFile(kind: kind)
            }
            guard let file else { return .json(Done(ok: false)) }
            return await models.add(file, as: kind) ? .json(Done()) : .failure(models.notice?.text ?? "That file could not be added.")

        case "/api/models/folder":
            let shell = shell
            let folder = models.library.directory
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            shell.onMain { shell.showFolder(folder) }
            return .json(Done())

        case "/api/dictionary":
            return changeDictionary(body)

        case "/api/history/remove":
            if let id = body.id.flatMap(UUID.init(uuidString:)) { history.remove(id) }
            return .json(Done())

        case "/api/history/clear":
            history.clear()
            return .json(Done())

        case "/api/history/retry":
            guard let id = body.id.flatMap(UUID.init(uuidString:)) else { return .failure("Which dictation?") }
            return .json(Done(message: await driver.retry(id)))

        default:
            return .failure("There is nothing here.", status: 404)
        }
    }

    /// Shows the system's file chooser, which must run on the shell's main thread.
    private func chooseFile(kind: ModelKind) async -> URL? {
        let shell = shell
        return await withCheckedContinuation { continuation in
            shell.onMain { continuation.resume(returning: shell.chooseModelFile(kind: kind)) }
        }
    }

    private func changeSettings(_ body: Body) -> HTTPResponse {
        if let level = body.level.flatMap(CleanupLevel.init(rawValue:)) {
            if level == .medium, models.library.plan(for: settings.current.models).medium == nil {
                return .failure("Medium needs a larger model. Download Qwen 3.5 4B (2.6 GB) or add your own under Models, then choose Medium again.")
            }
            settings.update { $0.level = level }
            followModels()
        }
        if let hotkey = body.hotkey, shell.hotkeys.contains(where: { $0.id == hotkey }) {
            settings.update { $0.hotkey = hotkey }
            let shell = shell
            shell.onMain { shell.useHotkey(hotkey) }
        }
        if let livePreview = body.livePreview { settings.update { $0.livePreview = livePreview } }
        if let keepRecordings = body.keepRecordings { settings.update { $0.keepRecordings = keepRecordings } }
        if let opensAtLogin = body.opensAtLogin, let problem = shell.setOpensAtLogin(opensAtLogin) {
            return .failure(problem)
        }
        return .json(Done())
    }

    private func changeDictionary(_ body: Body) -> HTTPResponse {
        var (dictionary, problem) = personalDictionary()
        // Never write over a file that could not be read: it may hold the user's own edits.
        if let problem { return .failure(problem) }
        switch body.kind {
        case "addTerm": dictionary.addTerm(body.text ?? "")
        case "removeTerm": dictionary.removeTerm(body.text ?? "")
        case "addReplacement": dictionary.addReplacement(from: body.from ?? "", to: body.to ?? "")
        case "removeReplacement": dictionary.removeReplacement(from: body.from ?? "")
        default: return .failure("What should change?")
        }
        do {
            try dictionary.save(to: dictionaryURL)
            return .json(Done())
        } catch {
            return .failure("The dictionary could not be saved.")
        }
    }
}
