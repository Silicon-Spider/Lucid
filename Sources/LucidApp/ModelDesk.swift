import Foundation
import LucidCore
import LucidEngines

/// The models folder as the window sees it: what is installed, what is downloading, and the
/// last thing that happened. Safe to use from any thread.
///
/// This is the Mac app's `ModelLibraryModel` without anything that only a Mac has.
public final class ModelDesk: @unchecked Sendable {
    /// What happened after the user added, removed or changed a model.
    public struct Notice: Codable, Equatable, Sendable {
        public var text: String
        public var isProblem: Bool
    }

    /// A download in progress.
    public struct Download: Equatable, Sendable {
        public var remote: RemoteModel
        public var received: Int64
        public var total: Int64?
    }

    public let library: ModelLibrary
    public let hub: HuggingFace

    private let lock = NSLock()
    private var downloads: [String: Download] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var currentNotice: Notice?
    private var changeHandler: (@Sendable () -> Void)?

    public init(library: ModelLibrary = .standard, hub: HuggingFace = HuggingFace()) {
        self.library = library
        self.hub = hub
    }

    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Called from any thread after a model is added, removed or changed, so the engines can follow.
    public func onChange(_ handler: @escaping @Sendable () -> Void) {
        locked { changeHandler = handler }
    }

    private func changed() {
        locked { changeHandler }?()
    }

    private func note(_ text: String, isProblem: Bool = false) {
        locked { currentNotice = Notice(text: text, isProblem: isProblem) }
    }

    private static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: Reading

    public var notice: Notice? { locked { currentNotice } }
    public var installed: [InstalledModel] { library.models() }
    public var partials: [PartialDownload] { library.partialDownloads() }

    /// Downloads in progress, by file name.
    public var activeDownloads: [Download] {
        locked { downloads.values.sorted { $0.remote.fileName < $1.remote.fileName } }
    }

    public func isDownloading(_ fileName: String) -> Bool {
        locked { downloads[fileName] != nil }
    }

    /// What a model file is called: the user's name for it, or its original one.
    public func displayName(of fileName: String, among installed: [InstalledModel]) -> String {
        installed.first { $0.fileName == fileName }?.name ?? ModelLibrary.defaultName(for: fileName)
    }

    /// What deleting a model would do, in sentences for the confirmation.
    public func removalMessage(for fileName: String, choices: ModelChoices) -> String? {
        let installed = installed
        guard let model = installed.first(where: { $0.fileName == fileName }) else { return nil }
        let effects = ModelLibrary.effectsOfRemoving(fileName, choices: choices, installed: installed)
        let stops = "so dictation stops working until you download one again."
        var lines = ["This deletes \(model.fileName) from Lucid's models folder, freeing \(Self.size(model.bytes))."]
        switch effects.speech {
        case .switches(let next): lines.append("Lucid will use \(displayName(of: next, among: installed)) for speech instead.")
        case .nothingLeft: lines.append("Lucid has no other speech model, " + stops)
        case nil: break
        }
        switch effects.light {
        case .switches(let next): lines.append("Light will use \(displayName(of: next, among: installed)) instead.")
        case .nothingLeft: lines.append("Lucid has no other cleanup model, " + stops)
        case nil: break
        }
        switch effects.medium {
        case .switches(let next): lines.append("Medium will use \(displayName(of: next, among: installed)) instead.")
        case .nothingLeft: lines.append("Medium will use the Light model until you download one that can tighten wording.")
        case nil: break
        }
        lines.append(
            ModelCatalog.suggestion(for: fileName) != nil
                ? "You can download it again here."
                : "A copy you keep elsewhere is not touched."
        )
        return lines.joined(separator: " ")
    }

    // MARK: Changing

    /// Deletes a model, Lucid's own included. Returns false, with the reason in `notice`, if it could not.
    @discardableResult
    public func remove(_ fileName: String) -> Bool {
        let name = displayName(of: fileName, among: installed)
        defer { changed() }
        do {
            let freed = try library.remove(fileName)
            note("Deleted \(name), freeing \(Self.size(freed)).")
            return true
        } catch {
            note("\(error)", isProblem: true)
            return false
        }
    }

    /// Gives a model the user's own name. An empty name puts the original back.
    @discardableResult
    public func rename(_ fileName: String, to name: String) -> Bool {
        let before = displayName(of: fileName, among: installed)
        do {
            let now = try library.rename(fileName, to: name)
            if now != before { note("\(before) is now called \(now).") }
            return true
        } catch {
            note("\(error)", isProblem: true)
            return false
        }
    }

    @discardableResult
    public func setStyle(_ style: PromptStyle, for fileName: String) -> Bool {
        defer { changed() }
        do {
            try library.setStyle(style, for: fileName)
            return true
        } catch {
            note("\(error)", isProblem: true)
            return false
        }
    }

    /// Checks a model file and copies it in. A large model on another disk takes a while.
    @discardableResult
    public func add(_ url: URL, as kind: ModelKind?) async -> Bool {
        let library = library
        let outcome = await Task.detached(priority: .userInitiated) { () -> Result<ModelLibrary.Added, Error> in
            Result { try library.add(from: url, as: kind) }
        }.value
        switch outcome {
        case .success(let added):
            let place = added.model.kind == .speech ? "Speech recognition" : "Cleanup"
            let text = "Added \(added.model.name). Choose it under \(place) to use it."
            note([text, added.warning].compactMap { $0 }.joined(separator: " "))
            changed()
            return true
        case .failure(let error):
            note("\(error)", isProblem: true)
            return false
        }
    }

    /// Deletes what an unfinished download left behind. Not while it is downloading.
    public func discardPartial(_ fileName: String) {
        guard !isDownloading(fileName) else { return }
        let bytes = library.partialBytes(of: fileName) ?? 0
        do {
            try library.discardPartial(of: fileName)
            note("Deleted the unfinished download of \(fileName), freeing \(Self.size(bytes)).")
        } catch {
            note("\(error)", isProblem: true)
        }
    }

    // MARK: Downloading

    /// Downloads a model in the background. It carries on when the window closes.
    public func download(_ remote: RemoteModel) {
        let name = remote.fileName
        let library = library
        let hub = hub
        let alreadyThere = FileManager.default.fileExists(atPath: library.directory.appendingPathComponent(name).path)
        let soFar = library.partialBytes(of: name) ?? 0
        let begun: Bool = locked {
            guard downloads[name] == nil, !alreadyThere else { return false }
            downloads[name] = Download(remote: remote, received: soFar, total: remote.bytes)
            currentNotice = nil
            return true
        }
        guard begun else { return }

        let task = Task { [weak self] in
            let outcome: Result<ModelLibrary.Added, Error>
            do {
                outcome = .success(try await library.download(remote, from: hub) { [weak self] received, total in
                    self?.progress(name, remote: remote, received: received, total: total)
                })
            } catch {
                outcome = .failure(error)
            }
            self?.finish(name, outcome)
        }
        locked { tasks[name] = task }
    }

    /// Downloads whichever of these files Lucid suggests, such as its own models during setup.
    public func downloadSuggested(_ fileNames: [String]) {
        for name in fileNames {
            if let suggestion = ModelCatalog.suggestion(for: name) { download(suggestion.remote) }
        }
    }

    /// Stops a download. What has arrived is kept, and downloading again continues from there.
    public func cancelDownload(_ fileName: String) {
        locked { tasks[fileName] }?.cancel()
    }

    private func progress(_ name: String, remote: RemoteModel, received: Int64, total: Int64?) {
        locked {
            // A late report must not bring back a download that has finished.
            guard downloads[name] != nil else { return }
            downloads[name] = Download(remote: remote, received: received, total: total)
        }
    }

    private func finish(_ name: String, _ outcome: Result<ModelLibrary.Added, Error>) {
        locked {
            downloads[name] = nil
            tasks[name] = nil
        }
        switch outcome {
        case .success(let added):
            var text = "Downloaded \(added.model.name)."
            if !added.model.isBuiltIn {
                text += " Choose it under \(added.model.kind == .speech ? "Speech recognition" : "Cleanup") to use it."
            }
            note([text, added.warning].compactMap { $0 }.joined(separator: " "))
            changed()
        case .failure(let error) where error is CancellationError:
            note("Stopped downloading \(name). Downloading it again continues where it stopped.")
        case .failure(let error):
            note("\(error)", isProblem: true)
        }
    }

    /// The files Lucid could use in a model on Hugging Face, given its name or a link to it.
    public func lookUp(_ text: String) async throws -> (repo: String, files: [RemoteModel]) {
        guard let reference = HuggingFace.parse(text) else {
            throw LookupError.notAModel
        }
        return (reference.repo, try await hub.modelFiles(in: reference))
    }

    public enum LookupError: Error, CustomStringConvertible {
        case notAModel

        public var description: String {
            "That is not a model on Hugging Face. Type a name such as ggerganov/whisper.cpp, or paste a link."
        }
    }
}
