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
    /// that is not installed falls back to the built-in model, so dictation keeps working.
    public func plan(for choices: ModelChoices) -> ModelPlan {
        Self.plan(for: choices, installed: models())
    }

    public static func plan(for choices: ModelChoices, installed: [InstalledModel]) -> ModelPlan {
        func find(_ fileName: String?, _ kind: ModelKind) -> InstalledModel? {
            guard let fileName else { return nil }
            return installed.first { $0.fileName == fileName && $0.kind == kind }
        }
        let speech = find(choices.speech, .speech)?.fileName ?? EngineConfig.defaultSpeechModel
        let light = find(choices.light, .cleanup)?.cleanupModel ?? EngineConfig.s1Mini
        // Only Lucid's own prompt has a Medium setting. The S1-mini format cannot tighten wording.
        let medium = [choices.medium, EngineConfig.general.fileName]
            .compactMap { find($0, .cleanup) }
            .first { $0.style == .general }?
            .cleanupModel
        return ModelPlan(speech: speech, light: light, medium: medium)
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
        let source = picked.resolvingSymlinksInPath()
        let name = picked.lastPathComponent
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

        let files = FileManager.default
        let destination = directory.appendingPathComponent(name)
        if files.fileExists(atPath: destination.path) { throw ModelError.alreadyInstalled(name) }

        let partial = directory.appendingPathComponent(name + ".part")
        do {
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
            try? files.removeItem(at: partial)
            try files.copyItem(at: source, to: partial)
            try files.moveItem(at: partial, to: destination)
        } catch {
            try? files.removeItem(at: partial)
            throw ModelError.copyFailed(error.localizedDescription)
        }

        let bytes = ((try? files.attributesOfItem(atPath: destination.path))?[.size] as? NSNumber)?.int64Value ?? 0
        if let known {
            let model = InstalledModel(
                fileName: name, kind: known.kind, name: known.name, style: known.style, isBuiltIn: true, bytes: bytes
            )
            return Added(model: model, warning: warning)
        }
        let chosenStyle = format.kind == .cleanup ? style ?? Self.suggestedStyle(name) : nil
        if let chosenStyle {
            var saved = registry()
            saved.styles[name] = chosenStyle
            try? save(saved)
        }
        let model = InstalledModel(
            fileName: name,
            kind: format.kind,
            name: Self.displayName(name),
            style: chosenStyle,
            isBuiltIn: false,
            bytes: bytes
        )
        return Added(model: model, warning: warning)
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

    /// Deletes a model the user added. Built-in models are left alone.
    public func remove(_ fileName: String) throws {
        if let known = Self.builtIn.first(where: { $0.fileName == fileName }) {
            throw ModelError.builtIn(known.name)
        }
        let url = directory.appendingPathComponent(fileName)
        // A link is removed, never the file it points to. `fileExists` would follow the link,
        // so ask for the link's own attributes.
        guard Self.mayBeModel(fileName), (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil else {
            throw ModelError.notFound(fileName)
        }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw ModelError.removeFailed(error.localizedDescription)
        }
        var saved = registry()
        if saved.styles.removeValue(forKey: fileName) != nil { try? save(saved) }
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
