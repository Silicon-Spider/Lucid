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

    /// Looks in Homebrew's folder on Apple Silicon, then on Intel.
    static func findBinary(_ name: String) -> URL {
        let folders = ["/opt/homebrew/bin", "/usr/local/bin"]
        for folder in folders {
            let url = URL(fileURLWithPath: folder).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return URL(fileURLWithPath: folders[0]).appendingPathComponent(name)
    }

    public static func standard(cleanup: CleanupModel = s1Mini) -> EngineConfig {
        let support = supportDirectory
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Lucid")
        return EngineConfig(
            whisperServer: findBinary("whisper-server"),
            llamaServer: findBinary("llama-server"),
            modelsDirectory: support.appendingPathComponent("models"),
            logsDirectory: logs,
            supportDirectory: support,
            speechModel: defaultSpeechModel,
            cleanupModel: cleanup
        )
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
