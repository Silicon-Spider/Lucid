import Foundation
import LucidCore

/// A cleanup model file and the prompt format it expects.
public struct CleanupModel: Equatable, Sendable {
    public var fileName: String
    public var style: PromptStyle

    public init(fileName: String, style: PromptStyle) {
        self.fileName = fileName
        self.style = style
    }
}

/// Where the engines and models are, and which models to use.
public struct EngineConfig: Equatable, Sendable {
    public var whisperServer: URL
    public var llamaServer: URL
    public var modelsDirectory: URL
    public var logsDirectory: URL
    public var supportDirectory: URL
    public var speechModel: String
    public var cleanupModel: CleanupModel

    public static let defaultSpeechModel = "ggml-large-v3-turbo-q5_0.bin"
    /// S1-mini by Superwhisper.
    public static let s1Mini = CleanupModel(fileName: "s1-mini-q4_k_m.gguf", style: .s1)
    /// Qwen 3.5 4B, driven by Lucid's own prompt. Slower and larger, and able to do the Medium level.
    public static let general = CleanupModel(fileName: "Qwen3.5-4B-Q4_K_M.gguf", style: .general)

    /// `~/Library/Application Support/Lucid`
    public static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lucid")
    }

    /// `~/Library/Application Support/Lucid/models`, where the model files are kept.
    public static var modelsDirectory: URL {
        supportDirectory.appendingPathComponent("models")
    }

    /// Where an engine can be put by hand: an `engines` folder beside the models. On Windows
    /// and Linux, where there is no Homebrew, this is where Lucid expects them, each in a
    /// folder of its own. They cannot share one: both come with files of the same names.
    public static var enginesDirectory: URL {
        supportDirectory.appendingPathComponent("engines")
    }

    /// Looks for a program anywhere in the `engines` folder, up to three folders deep, so an
    /// engine's download can be unzipped there as it comes.
    public static func findInEngines(_ file: String, under folder: URL = enginesDirectory) -> URL? {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return nil }
        var found: [URL] = []
        for case let url as URL in walker {
            if walker.level > 3 {
                walker.skipDescendants()
            } else if url.lastPathComponent == file, isProgram(url) {
                found.append(url)
            }
        }
        // The same answer every time, whatever order the system lists folders in.
        return found.min { $0.path < $1.path }
    }

    /// True for a file that can be run. A folder counts as "executable" to the system, and
    /// an engine's folder often has the engine's own name.
    private static func isProgram(_ url: URL) -> Bool {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), !isFolder.boolValue else { return false }
        return FileManager.default.isExecutableFile(atPath: url.path)
    }

    /// Where engine logs are written: `~/Library/Logs/Lucid` on a Mac, and a `logs` folder
    /// beside the models elsewhere.
    public static var logsDirectory: URL {
        #if os(macOS)
        return FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Lucid")
        #else
        return supportDirectory.appendingPathComponent("logs")
        #endif
    }

    /// Where engines that came with the app are: an `engines` folder beside its program, and
    /// in a Mac app, `Contents/Resources/engines`. A copy of Lucid that was downloaded has
    /// its engines there, so that nothing else needs installing.
    public static var bundledEnginesDirectories: [URL] {
        guard let program = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return [] }
        let folder = program.deletingLastPathComponent()
        var folders = [folder.appendingPathComponent("engines")]
        #if os(macOS)
        folders.append(folder.deletingLastPathComponent().appendingPathComponent("Resources/engines"))
        #endif
        return folders
    }

    /// Finds an engine's program. The engines that came with the app come first. Then, on a
    /// Mac, Homebrew's folder, on Apple Silicon then on Intel. Then Lucid's own `engines`
    /// folder, and the PATH. When the engine is nowhere, the answer is where Lucid expects
    /// it, for the message that says so.
    public static func findBinary(_ name: String, bundled: [URL] = bundledEnginesDirectories) -> URL {
        let file = Platform.programFile(name)
        for folder in bundled {
            if let found = findInEngines(file, under: folder) { return found }
        }
        var candidates: [URL] = []
        #if os(macOS)
        candidates += ["/opt/homebrew/bin", "/usr/local/bin"].map { URL(fileURLWithPath: $0).appendingPathComponent(file) }
        #endif
        // Where Lucid says to put an engine that is nowhere to be found.
        candidates.append(enginesDirectory.appendingPathComponent(name).appendingPathComponent(file))
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
            return found
        }
        return findInEngines(file) ?? Platform.findOnPath(name) ?? candidates[0]
    }

    /// The engines from Homebrew and the models in Lucid's models folder. `speech` is the file
    /// name of the speech model.
    public static func standard(speech: String = defaultSpeechModel, cleanup: CleanupModel = s1Mini) -> EngineConfig {
        let support = supportDirectory
        return EngineConfig(
            whisperServer: findBinary("whisper-server"),
            llamaServer: findBinary("llama-server"),
            modelsDirectory: modelsDirectory,
            logsDirectory: logsDirectory,
            supportDirectory: support,
            speechModel: speech,
            cleanupModel: cleanup
        )
    }

    /// The engines and models for a plan made from the user's choices.
    public static func standard(plan: ModelPlan, level: CleanupLevel) -> EngineConfig {
        standard(speech: plan.speech, cleanup: plan.cleanup(for: level))
    }

    public var speechModelURL: URL { modelsDirectory.appendingPathComponent(speechModel) }
    public var cleanupModelURL: URL { modelsDirectory.appendingPathComponent(cleanupModel.fileName) }

    /// What is not installed, in words a person can act on. Empty when everything needed is present.
    public func missing(speech: Bool = true, cleanup: Bool = true) -> [String] {
        let files = FileManager.default
        var problems: [String] = []
        if speech {
            if !files.isExecutableFile(atPath: whisperServer.path) {
                problems.append("the speech engine, expected at \(whisperServer.path)")
            }
            if !files.fileExists(atPath: speechModelURL.path) {
                problems.append("the speech model, expected at \(speechModelURL.path)")
            }
        }
        if cleanup {
            if !files.isExecutableFile(atPath: llamaServer.path) {
                problems.append("the cleanup engine, expected at \(llamaServer.path)")
            }
            if !files.fileExists(atPath: cleanupModelURL.path) {
                problems.append("the cleanup model, expected at \(cleanupModelURL.path)")
            }
        }
        return problems
    }
}
