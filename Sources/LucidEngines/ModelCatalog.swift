import Foundation

/// A model Lucid suggests downloading, and what it is good for.
public struct SuggestedModel: Identifiable, Sendable {
    public let name: String
    public let summary: String
    public let remote: RemoteModel

    public var id: String { remote.fileName }
}

/// The models offered for download in Settings. Lucid's own come first. The notes on speed and
/// accuracy come from `docs/benchmarks.md` where Lucid measured them.
public enum ModelCatalog {
    static let whisper = "ggerganov/whisper.cpp"

    public static let suggested: [SuggestedModel] = [
        SuggestedModel(
            name: "Whisper large-v3-turbo",
            summary: "Lucid's speech model.",
            remote: RemoteModel(repo: whisper, path: EngineConfig.defaultSpeechModel, bytes: 574_041_195, kind: .speech)
        ),
        SuggestedModel(
            name: "S1-mini by Superwhisper",
            summary: "Lucid's cleanup model for Light. Small and quick.",
            remote: RemoteModel(
                repo: "superwhisper/s1-mini-GGUF", path: EngineConfig.s1Mini.fileName, bytes: 484_219_808, kind: .cleanup
            )
        ),
        SuggestedModel(
            name: "Qwen 3.5 4B",
            summary: "Lucid's cleanup model for Medium. About twice as slow as S1-mini.",
            remote: RemoteModel(
                repo: "unsloth/Qwen3.5-4B-GGUF", path: EngineConfig.general.fileName, bytes: 2_740_937_888, kind: .cleanup
            )
        ),
        SuggestedModel(
            name: "Whisper small.en",
            summary: "English only. Faster than Lucid's speech model, and less accurate.",
            remote: RemoteModel(repo: whisper, path: "ggml-small.en.bin", bytes: 487_614_201, kind: .speech)
        ),
        SuggestedModel(
            name: "Whisper base.en",
            summary: "English only. Measured 5 to 12 times faster than Lucid's speech model, but it mishears more.",
            remote: RemoteModel(repo: whisper, path: "ggml-base.en.bin", bytes: 147_964_211, kind: .speech)
        ),
    ]

    /// The suggested download for a model file, if Lucid suggests one.
    public static func suggestion(for fileName: String) -> SuggestedModel? {
        suggested.first { $0.remote.fileName == fileName }
    }
}
