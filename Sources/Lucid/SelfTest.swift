import Foundation
import LucidCore
import LucidEngines

/// Runs the app's own settings, engines and pipeline on audio files, with no UI.
/// Used to check a build without a keyboard or a microphone.
enum SelfTest {
    @MainActor
    static func run(files: [String]) async -> Int32 {
        guard !files.isEmpty else {
            print("usage: Lucid --self-test <file.wav>...")
            return 2
        }
        let settings = AppSettings()
        let engines = EngineManager(choices: settings.models, level: settings.level, tracksProcesses: false)
        await engines.start()
        guard engines.status == .ready else {
            print("engines are not ready: \(engines.status)")
            return 1
        }
        print("engines ready. level: \(settings.level.rawValue). dictation key: \(settings.hotkey.title).")
        print("speech model: \(engines.config.speechModel). cleanup model: \(engines.config.cleanupModel.fileName).")

        let dictionary = (try? PersonalDictionary.load(from: AppSettings.dictionaryURL)) ?? .empty
        let context = PipelineContext(level: settings.level, dictionary: dictionary)
        var status: Int32 = 0
        for path in files {
            do {
                let wav = try Data(contentsOf: URL(fileURLWithPath: path))
                let outcome = try await engines.dictate(wav: wav, context: context)
                let total = outcome.speechMillis + outcome.result.cleanMillis
                print("\(URL(fileURLWithPath: path).lastPathComponent): \(total) ms")
                print("  heard:   \(outcome.heard)")
                print("  cleaned: \(outcome.result.finalText)")
            } catch {
                print("error: \(path): \(error)")
                status = 1
            }
        }
        await engines.stop()
        return status
    }
}
