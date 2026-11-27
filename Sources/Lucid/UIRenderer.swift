import AppKit
import LucidCore
import LucidEngines
import SwiftUI

/// Draws the app's views to PNG files, so they can be looked at without running the app.
enum UIRenderer {
    @MainActor
    static func render(into folder: URL) -> Int32 {
        _ = NSApplication.shared
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (name, view) in pillViews() + windowViews() {
                try write(view, to: folder.appendingPathComponent("\(name).png"))
                print("wrote \(name).png")
            }
            return 0
        } catch {
            print("error: \(error)")
            return 1
        }
    }

    @MainActor
    private static func pillViews() -> [(String, AnyView)] {
        func pill(_ state: PillState, level: Float = 0) -> AnyView {
            let model = PillModel()
            model.state = state
            model.level = level
            // A mid-grey backdrop shows the pill's edge the way a real desktop would.
            return AnyView(
                PillView(model: model)
                    .padding(20)
                    .background(Color(white: 0.55))
            )
        }
        return [
            ("pill-recording-quiet", pill(.recording, level: 0.01)),
            ("pill-recording-loud", pill(.recording, level: 0.12)),
            ("pill-hands-free", pill(.handsFree, level: 0.06)),
            ("pill-processing", pill(.processing)),
            ("pill-message", pill(.message("Copied. Press ⌘V"))),
        ]
    }

    /// Lucid's window at each of its parts, filled with sample data.
    @MainActor
    private static func windowViews() -> [(String, AnyView)] {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lucid-render-\(UUID().uuidString)")
        var sample = PersonalDictionary()
        sample.addTerm("GitHub")
        sample.addTerm("Kubernetes")
        sample.addReplacement(from: "jon", to: "John")
        let dictionaryURL = folder.appendingPathComponent("dictionary.json")
        try? sample.save(to: dictionaryURL)

        let store = HistoryStore(directory: folder)
        store.add(
            HistoryEntry(
                date: Date(timeIntervalSince1970: 1_795_000_000),
                appName: "Mail",
                bundleID: "com.apple.mail",
                audioSeconds: 4,
                speechMillis: 0,
                result: nil,
                failure: "The speech engine was not running."
            ),
            wav: Data([0])
        )
        store.add(
            HistoryEntry(
                date: Date(timeIntervalSince1970: 1_795_000_600),
                appName: "Notes",
                bundleID: "com.apple.Notes",
                audioSeconds: 7.2,
                speechMillis: 580,
                result: PipelineResult(
                    raw: "Um, so I was thinking we could, uh, meet at 2. Actually no, make that 3, at the usual place.",
                    rulesText: "So I was thinking we could meet at 2. Actually no, make that 3, at the usual place.",
                    finalText: "So I was thinking we could meet at 3 at the usual place.",
                    llmAttempted: true,
                    llmUsed: true,
                    fallback: nil,
                    rejectedReply: nil,
                    cleanMillis: 170
                ),
                failure: nil
            ),
            wav: nil
        )

        // Model files only need their first bytes for the library to recognise them.
        let modelsFolder = folder.appendingPathComponent("models")
        try? FileManager.default.createDirectory(at: modelsFolder, withIntermediateDirectories: true)
        var whisper = Data("lmgg".utf8)
        for value: UInt32 in [51866, 1500, 1280, 20, 32, 448, 1280, 20, 4, 128, 8] {
            withUnsafeBytes(of: value.littleEndian) { whisper.append(contentsOf: $0) }
        }
        let gguf = Data("GGUF".utf8) + Data(repeating: 0, count: 64)
        for name in [EngineConfig.defaultSpeechModel, "ggml-small.en.bin"] {
            try? whisper.write(to: modelsFolder.appendingPathComponent(name))
        }
        for name in [EngineConfig.s1Mini.fileName, "Llama-3.2-3B-Instruct-Q4_K_M.gguf"] {
            try? gguf.write(to: modelsFolder.appendingPathComponent(name))
        }
        // An unfinished download, so the Resume and Discard buttons show.
        try? Data(repeating: 0, count: 4096).write(to: modelsFolder.appendingPathComponent("ggml-base.en.bin.part"))
        let library = ModelLibraryModel(library: ModelLibrary(directory: modelsFolder))
        let settings = AppSettings(defaults: UserDefaults(suiteName: "lucid-render-\(UUID().uuidString)") ?? .standard)
        settings.models = ModelChoices(medium: "Llama-3.2-3B-Instruct-Q4_K_M.gguf")

        // One sample model has been renamed, so the renamed look is drawn too.
        if let small = library.installed.first(where: { $0.fileName == "ggml-small.en.bin" }) {
            library.rename(small, to: "Quick and rough")
        }

        func setup(done: Bool) -> SetupModel {
            let model = SetupModel()
            model.microphone = done
            model.accessibility = done
            model.listening = done
            model.fnConflict = !done
            return model
        }
        let dictionary = DictionaryModel(url: dictionaryURL)
        let history = HistoryModel(store: store)
        let missing = ["the cleanup model, expected at ~/Library/Application Support/Lucid/models/s1-mini-q4_k_m.gguf"]

        /// The whole window at one of its parts. `height` can be taller than a real window, to show a long part in full.
        func window(_ section: MainSection, done: Bool = true, height: CGFloat = MainWindowSize.starting.height) -> AnyView {
            let model = MainWindowModel()
            model.section = section
            return AnyView(
                MainView(
                    window: model,
                    settings: settings,
                    engines: EngineManager.preview(done ? .ready : .setupNeeded(missing)),
                    setup: setup(done: done),
                    models: library,
                    dictionary: dictionary,
                    history: history,
                    actions: MainActions()
                )
                .frame(width: MainWindowSize.starting.width, height: height)
            )
        }

        return [
            ("window-home", window(.home, height: 900)),
            ("window-home-to-do", window(.home, done: false, height: 900)),
            // Tall enough to show the download section below the list of models.
            ("window-models", window(.models, height: 1400)),
            ("window-dictionary", window(.dictionary)),
            ("window-history", window(.history)),
            ("window-settings", window(.settings)),
            ("window-about", window(.about)),
        ]
    }

    @MainActor
    static func write(_ view: AnyView, to url: URL) throws {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw CocoaError(.fileWriteUnknown)
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try png.write(to: url)
    }
}
