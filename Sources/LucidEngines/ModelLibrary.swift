import Foundation
import LucidCore

/// What a model is used for.
public enum ModelKind: String, Codable, CaseIterable, Sendable {
    /// Speech to text, run by whisper.cpp.
    case speech
    /// Transcript cleanup, run by llama.cpp.
    case cleanup
}

/// A model file in Lucid's models folder.
public struct InstalledModel: Equatable, Identifiable, Sendable {
    public var fileName: String
    public var kind: ModelKind
    /// What to call the model. For a model the user added, its file name without the extension.
    public var name: String
    /// The prompt format. Cleanup models only.
    public var style: PromptStyle?
    /// True for the models `scripts/setup.sh` downloads.
    public var isBuiltIn: Bool
    public var bytes: Int64

    public var id: String { fileName }

    public init(fileName: String, kind: ModelKind, name: String, style: PromptStyle?, isBuiltIn: Bool, bytes: Int64) {
        self.fileName = fileName
        self.kind = kind
        self.name = name
        self.style = style
        self.isBuiltIn = isBuiltIn
        self.bytes = bytes
    }

    /// The model as the cleanup engine needs it. Nil for a speech model.
    public var cleanupModel: CleanupModel? {
        kind == .cleanup ? CleanupModel(fileName: fileName, style: style ?? .general) : nil
    }
}

/// The models the user chose, by file name. Nil means Lucid's own model.
public struct ModelChoices: Codable, Equatable, Sendable {
    public var speech: String?
    /// The cleanup model for the Light level.
    public var light: String?
    /// The cleanup model for the Medium level.
    public var medium: String?

    public init(speech: String? = nil, light: String? = nil, medium: String? = nil) {
        self.speech = speech
        self.light = light
        self.medium = medium
    }

    /// Forgets any choice of this file, so the built-in model takes its place.
    public mutating func forget(_ fileName: String) {
        if speech == fileName { speech = nil }
        if light == fileName { light = nil }
        if medium == fileName { medium = nil }
    }
}

/// The model files the engines will load.
public struct ModelPlan: Equatable, Sendable {
    public var speech: String
    public var light: CleanupModel
    /// Nil when no model able to do the Medium level is installed.
    public var medium: CleanupModel?

    public init(speech: String, light: CleanupModel, medium: CleanupModel?) {
        self.speech = speech
        self.light = light
        self.medium = medium
    }

    /// Medium falls back to the Light model when there is nothing better. Off still loads the
    /// Light model, so switching back to Light is instant.
    public func cleanup(for level: CleanupLevel) -> CleanupModel {
        level == .medium ? (medium ?? light) : light
    }
}

/// What deleting a model changes. Each use the model had says what takes its place.
public struct RemovalEffects: Equatable, Sendable {
    public enum Change: Equatable, Sendable {
        /// Another installed model, by file name, takes over.
        case switches(to: String)
        /// No other installed model can.
        case nothingLeft
    }

    public var speech: Change?
    public var light: Change?
    public var medium: Change?

    public init(speech: Change? = nil, light: Change? = nil, medium: Change? = nil) {
        self.speech = speech
        self.light = light
        self.medium = medium
    }

    /// True when the model was not in use.
    public var isEmpty: Bool { speech == nil && light == nil && medium == nil }
}

/// What an unfinished download left in the models folder.
public struct PartialDownload: Equatable, Identifiable, Sendable {
    /// The name the model will have when it is complete.
    public var fileName: String
    public var bytes: Int64

    public var id: String { fileName }

    public init(fileName: String, bytes: Int64) {
        self.fileName = fileName
        self.bytes = bytes
    }
}

/// A model that comes with Lucid.
public struct BuiltInModel: Sendable {
    public let fileName: String
    public let name: String
    public let kind: ModelKind
    public let style: PromptStyle?
}

/// The models in Lucid's models folder: the built-in ones that `scripts/setup.sh` downloads,
/// and any the user added.
///
/// The prompt format of each added cleanup model is kept in `models.json` in the same folder.
public struct ModelLibrary: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `~/Library/Application Support/Lucid/models`, where the engines look.
    public static var standard: ModelLibrary {
        ModelLibrary(directory: EngineConfig.modelsDirectory)
    }

    public static let builtIn: [BuiltInModel] = [
        BuiltInModel(fileName: EngineConfig.defaultSpeechModel, name: "Whisper large-v3-turbo", kind: .speech, style: nil),
        BuiltInModel(fileName: EngineConfig.s1Mini.fileName, name: "S1-mini by Superwhisper", kind: .cleanup, style: .s1),
        BuiltInModel(fileName: EngineConfig.general.fileName, name: "Qwen 3.5 4B", kind: .cleanup, style: .general),
    ]

    private var registryURL: URL { directory.appendingPathComponent("models.json") }

    // MARK: Listing

    /// Every usable model in the folder: built-in ones first, then the user's own by name.
    /// A file counts as a model when its first bytes say so, whatever its name.
    public func models() -> [InstalledModel] {
        let files = FileManager.default
        guard let names = try? files.contentsOfDirectory(atPath: directory.path) else { return [] }
        let styles = registry().styles
        var builtIn: [InstalledModel] = []
        var added: [InstalledModel] = []
        for name in names where Self.mayBeModel(name) {
            // Follow a link, so a model kept elsewhere can be linked into the folder by hand.
            let url = directory.appendingPathComponent(name).resolvingSymlinksInPath()
            guard let attributes = try? files.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeRegular else { continue }
            let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            if let known = Self.builtIn.first(where: { $0.fileName == name }) {
                builtIn.append(InstalledModel(
                    fileName: name, kind: known.kind, name: known.name, style: known.style, isBuiltIn: true, bytes: bytes
                ))
            } else if let kind = ModelFile.kind(of: url) {
                added.append(InstalledModel(
                    fileName: name,
                    kind: kind,
                    name: Self.displayName(name),
                    style: kind == .cleanup ? styles[name] ?? Self.suggestedStyle(name) : nil,
                    isBuiltIn: false,
                    bytes: bytes
                ))
            }
        }
        let order = Self.builtIn.map(\.fileName)
        builtIn.sort { (order.firstIndex(of: $0.fileName) ?? 0) < (order.firstIndex(of: $1.fileName) ?? 0) }
        added.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return builtIn + added
    }

    /// The prompt format to use for a cleanup model given by file name, or nil when Lucid does
    /// not know the file.
    public func style(of fileName: String) -> PromptStyle? {
        if let known = Self.builtIn.first(where: { $0.fileName == fileName }) { return known.style }
        if let saved = registry().styles[fileName] { return saved }
        return FileManager.default.fileExists(atPath: directory.appendingPathComponent(fileName).path)
            ? Self.suggestedStyle(fileName) : nil
    }

    // MARK: Choosing

    /// The files the engines should load for the user's choices. A choice that names a model
    /// that is not installed falls back to the built-in model, and if that is gone too, to any
    /// installed model of the same kind, so dictation keeps working.
    public func plan(for choices: ModelChoices) -> ModelPlan {
        Self.plan(for: choices, installed: models())
    }

    public static func plan(for choices: ModelChoices, installed: [InstalledModel]) -> ModelPlan {
        func find(_ fileName: String?, _ kind: ModelKind) -> InstalledModel? {
            guard let fileName else { return nil }
            return installed.first { $0.fileName == fileName && $0.kind == kind }
        }
        let speech = find(choices.speech, .speech)?.fileName
            ?? find(EngineConfig.defaultSpeechModel, .speech)?.fileName
            ?? installed.first { $0.kind == .speech }?.fileName
            ?? EngineConfig.defaultSpeechModel
        let light = find(choices.light, .cleanup)?.cleanupModel
            ?? find(EngineConfig.s1Mini.fileName, .cleanup)?.cleanupModel
            ?? installed.first { $0.kind == .cleanup }?.cleanupModel
            ?? EngineConfig.s1Mini
        // Only Lucid's own prompt has a Medium setting. The S1-mini format cannot tighten wording.
        let medium = [choices.medium, EngineConfig.general.fileName]
            .compactMap { find($0, .cleanup) }
            .first { $0.style == .general }?
            .cleanupModel
        return ModelPlan(speech: speech, light: light, medium: medium)
    }

    /// What deleting a model would change, so the user can be told before they confirm.
    public static func effectsOfRemoving(
        _ fileName: String, choices: ModelChoices, installed: [InstalledModel]
    ) -> RemovalEffects {
        let before = plan(for: choices, installed: installed)
        let rest = installed.filter { $0.fileName != fileName }
        var remaining = choices
        remaining.forget(fileName)
        let after = plan(for: remaining, installed: rest)
        func change(to next: String?) -> RemovalEffects.Change {
            guard let next, rest.contains(where: { $0.fileName == next }) else { return .nothingLeft }
            return .switches(to: next)
        }
        var effects = RemovalEffects()
        if before.speech == fileName { effects.speech = change(to: after.speech) }
        if before.light.fileName == fileName { effects.light = change(to: after.light.fileName) }
        if before.medium?.fileName == fileName { effects.medium = change(to: after.medium?.fileName) }
        return effects
    }

    // MARK: Changing

    /// A model the user just added, and anything they should know about it.
    public struct Added: Equatable, Sendable {
        public var model: InstalledModel
        /// Set when the model was added but may not work well.
        public var warning: String?
    }

    /// Checks a model file and copies it into the models folder. `kind` is what the user
    /// meant to add; nil accepts either kind. `style` defaults to Lucid's own prompt, or the
    /// S1-mini format for a file whose name says it is S1-mini.
    ///
    /// The copy is made under a temporary name and renamed when complete, so a half-copied
    /// file is never taken for a model. On APFS, a copy within one disk is a clone that takes
    /// no extra space.
    public func add(from picked: URL, as kind: ModelKind? = nil, style: PromptStyle? = nil) throws -> Added {
        let name = picked.lastPathComponent
        let checked = try check(picked.resolvingSymlinksInPath(), name: name, kind: kind)

        let files = FileManager.default
        let destination = directory.appendingPathComponent(name)
        if files.fileExists(atPath: destination.path) { throw ModelError.alreadyInstalled(name) }
        // Not the `.part` name downloads use, so a download of the same file is left alone.
        let partial = directory.appendingPathComponent(name + ".copy.part")
        do {
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
            try? files.removeItem(at: partial)
            try files.copyItem(at: picked.resolvingSymlinksInPath(), to: partial)
            try files.moveItem(at: partial, to: destination)
        } catch {
            try? files.removeItem(at: partial)
            throw ModelError.copyFailed(error.localizedDescription)
        }
        return installed(name, checked, style: style)
    }

    /// Downloads a model from Hugging Face, checks it as `add` does, and puts it in the models
    /// folder. A download that stops early is kept as a `.part` file, and the next download of
    /// the same file continues from it. `progress` gets the bytes so far and the full size.
    public func download(
        _ remote: RemoteModel,
        from hub: HuggingFace = HuggingFace(),
        style: PromptStyle? = nil,
        progress: @escaping @Sendable (Int64, Int64?) -> Void = { _, _ in }
    ) async throws -> Added {
        let name = remote.fileName
        guard Self.mayBeModel(name), !name.hasSuffix(".part") else { throw ModelError.notAModel }
        let files = FileManager.default
        let destination = directory.appendingPathComponent(name)
        if files.fileExists(atPath: destination.path) { throw ModelError.alreadyInstalled(name) }
        do {
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw DownloadError.cannotSave
        }
        let partial = partialURL(for: name)
        try checkSpace(for: remote, partial: partial)

        let download = FileDownload(
            url: hub.downloadURL(for: remote), partial: partial, expectedBytes: remote.bytes, progress: progress
        )
        do {
            try await download.run()
        } catch {
            // Keep what arrived, to continue from next time, but not an empty file.
            if partialBytes(of: name) == nil { try? files.removeItem(at: partial) }
            if let failure = error as? DownloadError, case .http(let code) = failure {
                if code == 401 || code == 403 { throw DownloadError.needsAccess(remote.repo) }
                if code == 404 { throw DownloadError.fileNotFound(remote.path) }
            }
            throw error
        }

        // The whole file is here. Check it like one the user added, then put it in place.
        do {
            let checked = try check(partial, name: name, kind: remote.kind)
            if files.fileExists(atPath: destination.path) { throw ModelError.alreadyInstalled(name) }
            do {
                try files.moveItem(at: partial, to: destination)
            } catch {
                throw ModelError.copyFailed(error.localizedDescription)
            }
            return installed(name, checked, style: style)
        } catch {
            try? files.removeItem(at: partial)
            throw error
        }
    }

    /// How much of a file an earlier download left behind, if any.
    public func partialBytes(of fileName: String) -> Int64? {
        let path = partialURL(for: fileName).path
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber,
              size.int64Value > 0 else { return nil }
        return size.int64Value
    }

    private func partialURL(for fileName: String) -> URL {
        directory.appendingPathComponent(fileName + ".part")
    }

    /// Refuses to start a download that cannot fit, leaving room for the system.
    private func checkSpace(for remote: RemoteModel, partial: URL) throws {
        #if os(macOS)
        guard let size = remote.bytes,
              let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let free = values.volumeAvailableCapacityForImportantUsage else { return }
        let needed = size - (partialBytes(of: remote.fileName) ?? 0)
        if needed + 200_000_000 > free { throw DownloadError.notEnoughSpace(needed: needed, free: free) }
        #endif
    }

    /// The result of checking a model file before it is put in the models folder.
    private struct Checked {
        let format: ModelFormat
        /// Set when the file is one of Lucid's own models.
        let known: BuiltInModel?
        let warning: String?
    }

    /// Checks that a file is a usable model of the right kind, to be called `name`.
    private func check(_ source: URL, name: String, kind: ModelKind?) throws -> Checked {
        if name.hasSuffix(".part") { throw ModelError.damaged }
        guard Self.mayBeModel(name) else { throw ModelError.notAModel }

        let format = try ModelFile.inspect(source)
        if let kind, kind != format.kind { throw ModelError.wrongKind(format.kind) }
        // A built-in model downloaded by hand can be added, as long as it is what its name says.
        let known = Self.builtIn.first { $0.fileName == name }
        if let known, known.kind != format.kind { throw ModelError.wrongKind(format.kind) }

        var warning: String?
        if case .gguf(let info) = format {
            if info.architecture == "clip" || info.type == "mmproj" {
                throw ModelError.notStandalone("a vision add-on (mmproj)")
            }
            if info.type == "adapter" {
                throw ModelError.notStandalone("an adapter (LoRA)")
            }
            if info.splitCount > 1 { throw ModelError.split(info.splitCount) }
            if info.hasChatTemplate == false {
                warning = "This model has no chat template, so it may not follow instructions. "
                    + "If its replies are unusable, Lucid falls back to its rules."
            }
        }
        return Checked(format: format, known: known, warning: warning)
    }

    /// Describes a model just put in the folder, and saves its prompt format.
    private func installed(_ name: String, _ checked: Checked, style: PromptStyle?) -> Added {
        let destination = directory.appendingPathComponent(name)
        let bytes = ((try? FileManager.default.attributesOfItem(atPath: destination.path))?[.size] as? NSNumber)?
            .int64Value ?? 0
        if let known = checked.known {
            let model = InstalledModel(
                fileName: name, kind: known.kind, name: known.name, style: known.style, isBuiltIn: true, bytes: bytes
            )
            return Added(model: model, warning: checked.warning)
        }
        let kind = checked.format.kind
        let chosenStyle = kind == .cleanup ? style ?? Self.suggestedStyle(name) : nil
        if let chosenStyle {
            var saved = registry()
            saved.styles[name] = chosenStyle
            try? save(saved)
        }
        let model = InstalledModel(
            fileName: name,
            kind: kind,
            name: Self.displayName(name),
            style: chosenStyle,
            isBuiltIn: false,
            bytes: bytes
        )
        return Added(model: model, warning: checked.warning)
    }

    /// Sets the prompt format of a cleanup model the user added.
    public func setStyle(_ style: PromptStyle, for fileName: String) throws {
        guard Self.builtIn.allSatisfy({ $0.fileName != fileName }) else {
            throw ModelError.builtIn(Self.builtIn.first { $0.fileName == fileName }?.name ?? fileName)
        }
        var saved = registry()
        saved.styles[fileName] = style
        try save(saved)
    }

    /// Deletes a model from the models folder, Lucid's own included, and returns the bytes freed.
    /// A built-in model can be downloaded again in Settings or with `scripts/setup.sh`.
    @discardableResult
    public func remove(_ fileName: String) throws -> Int64 {
        let url = directory.appendingPathComponent(fileName)
        // A link is removed, never the file it points to. `fileExists` would follow the link,
        // so ask for the link's own attributes.
        guard Self.mayBeModel(fileName), let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            throw ModelError.notFound(fileName)
        }
        let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw ModelError.removeFailed(error.localizedDescription)
        }
        var saved = registry()
        if saved.styles.removeValue(forKey: fileName) != nil { try? save(saved) }
        return bytes
    }

    /// Downloads that stopped part way, with how much of each arrived.
    public func partialDownloads() -> [PartialDownload] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names
            .filter { $0.hasSuffix(".part") && !$0.hasSuffix(".copy.part") }
            .map { String($0.dropLast(".part".count)) }
            .filter(Self.mayBeModel)
            .compactMap { name in partialBytes(of: name).map { PartialDownload(fileName: name, bytes: $0) } }
            .sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
    }

    /// Deletes what an unfinished download left behind.
    public func discardPartial(of fileName: String) throws {
        let url = partialURL(for: fileName)
        guard Self.mayBeModel(fileName), FileManager.default.fileExists(atPath: url.path) else {
            throw ModelError.notFound(fileName)
        }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw ModelError.removeFailed(error.localizedDescription)
        }
    }

    // MARK: Helpers

    private struct Registry: Codable {
        var styles: [String: PromptStyle] = [:]
    }

    private func registry() -> Registry {
        guard let data = try? Data(contentsOf: registryURL),
              let saved = try? JSONDecoder().decode(Registry.self, from: data) else { return Registry() }
        return saved
    }

    private func save(_ registry: Registry) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(registry).write(to: registryURL, options: .atomic)
    }

    /// Leaves out hidden files, downloads in progress and Lucid's own notes.
    private static func mayBeModel(_ name: String) -> Bool {
        !name.hasPrefix(".") && !name.hasSuffix(".part") && name != "models.json" && !name.contains("/")
    }

    private static func displayName(_ fileName: String) -> String {
        let stem = (fileName as NSString).deletingPathExtension
        return stem.isEmpty ? fileName : stem
    }

    /// S1-mini needs its own input format. Every other model gets Lucid's prompt.
    private static func suggestedStyle(_ fileName: String) -> PromptStyle {
        fileName.lowercased().contains("s1-mini") ? .s1 : .general
    }
}
