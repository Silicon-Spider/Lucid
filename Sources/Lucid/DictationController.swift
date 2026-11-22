import AppKit
import LucidCore
import LucidEngines

/// Connects the keyboard, the microphone, the engines and the document.
@MainActor
final class DictationController {
    private let settings: AppSettings
    private let engines: EngineManager
    private let history: HistoryStore
    private let pill: PillController
    private let recorder = AudioRecorder()
    private var machine = DictationMachine()
    private var ticker: Timer?

    /// Called after a dictation has been added to history.
    var onHistoryChange: (() -> Void)?

    init(settings: AppSettings, engines: EngineManager, history: HistoryStore, pill: PillController) {
        self.settings = settings
        self.engines = engines
        self.history = history
        self.pill = pill
        recorder.onLevel = { [weak self] level in
            self?.pill.setLevel(level)
        }
    }

    /// Handles one keyboard signal. Returns true when the key press should not reach other apps.
    func handle(_ signal: HotkeyMonitor.Signal) -> Bool {
        let wasRecording = machine.isRecording
        switch signal {
        case .hotkeyDown: send(.hotkeyDown)
        case .hotkeyUp: send(.hotkeyUp)
        case .otherKeyDown: send(.otherKeyDown)
        case .escape: send(.escape)
        }
        // Escape cancels a recording, and only then is it kept from the app underneath.
        return signal == .escape && wasRecording
    }

    private func send(_ event: DictationMachine.Event) {
        let actions = machine.handle(event, at: ProcessInfo.processInfo.systemUptime)
        for action in actions { perform(action) }
        updateTicker()
    }

    private func perform(_ action: DictationMachine.Action) {
        switch action {
        case .startRecording:
            startRecording()
        case .stopAndProcess:
            stopAndProcess()
        case .discard:
            recorder.stop()
            pill.hide()
        case .enterHandsFree:
            pill.show(.handsFree)
        case .busy:
            pill.pulse()
        }
    }

    /// The machine needs regular ticks while recording, to time out a tap and to cap the length.
    private func updateTicker() {
        if machine.isRecording {
            guard ticker == nil else { return }
            ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.send(.tick) }
            }
        } else {
            ticker?.invalidate()
            ticker = nil
        }
    }

    private func startRecording() {
        guard Permissions.microphone == .authorized else {
            send(.escape)
            pill.flash("Lucid needs microphone access")
            return
        }
        do {
            try recorder.start()
            pill.setLevel(0)
            pill.show(.recording)
        } catch {
            send(.escape)
            pill.flash("No microphone found")
        }
    }

    private func stopAndProcess() {
        let samples = recorder.stop()
        // Read the cursor's surroundings now, while the user's app still has focus.
        let target = TextInserter.captureTarget()
        guard AudioGate.hasSpeech(samples: samples) else {
            pill.flash("Didn't catch that")
            send(.finished)
            return
        }
        pill.show(.processing)
        Task { [weak self] in
            await self?.process(samples: samples, target: target)
            self?.send(.finished)
        }
    }

    private func process(samples: [Int16], target: InsertionTarget) async {
        let wav = WAV.encode(samples: samples)
        let audioSeconds = Double(samples.count) / 16_000
        let dictionary = (try? PersonalDictionary.load(from: AppSettings.dictionaryURL)) ?? .empty
        let context = PipelineContext(
            level: settings.level,
            category: AppCategory.forBundleID(target.bundleID),
            dictionary: dictionary,
            midSentence: InsertionPlanner.isMidSentence(before: target.before)
        )
        let recording = settings.keepRecordings ? wav : nil

        do {
            let outcome = try await engines.dictate(wav: wav, context: context)
            let text = outcome.result.finalText
            guard !text.isEmpty else {
                pill.flash("Didn't catch that")
                return
            }
            let pasted = TextInserter.insert(InsertionPlanner.textToInsert(text, before: target.before), into: target)
            history.add(
                HistoryEntry(
                    date: Date(),
                    appName: target.appName,
                    bundleID: target.bundleID,
                    audioSeconds: audioSeconds,
                    speechMillis: outcome.speechMillis,
                    result: outcome.result,
                    failure: nil
                ),
                wav: recording
            )
            if pasted {
                pill.hide()
            } else {
                pill.flash("Copied. Press ⌘V")
            }
        } catch {
            history.add(
                HistoryEntry(
                    date: Date(),
                    appName: target.appName,
                    bundleID: target.bundleID,
                    audioSeconds: audioSeconds,
                    speechMillis: 0,
                    result: nil,
                    failure: "\(error)"
                ),
                wav: recording
            )
            pill.flash(recording == nil ? "Couldn't transcribe that" : "Couldn't transcribe. Recording kept.", seconds: 3)
        }
        onHistoryChange?()
    }
}
