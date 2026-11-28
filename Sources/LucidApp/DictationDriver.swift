import Foundation
import LucidCore
import LucidEngines

/// What the keyboard tells Lucid.
public enum KeySignal: Equatable, Sendable {
    case hotkeyDown
    case hotkeyUp
    /// Any key other than the dictation key and Escape, pressed while the dictation key is held.
    case otherKeyDown
    case escape
}

/// What the on-screen pill shows.
public enum PillStatus: Equatable, Sendable {
    case hidden
    case recording
    case handsFree
    case processing
    case message(String)
}

/// Where the dictated text is going, captured when the user stops speaking.
public struct DeskTarget: Equatable, Sendable {
    public var appName: String
    /// What identifies the app: a bundle identifier on a Mac, a program's file name on Windows.
    public var appID: String?
    /// The few characters just before the cursor. Nil when the app does not reveal them.
    public var before: String?
    /// True in a password field. Lucid never pastes there.
    public var isSecure: Bool
    /// True when the focused control is clearly not somewhere text can go.
    public var isClearlyNotText: Bool
    /// Whatever the shell needs to find the window again.
    public var window: UInt

    public init(
        appName: String, appID: String? = nil, before: String? = nil,
        isSecure: Bool = false, isClearlyNotText: Bool = false, window: UInt = 0
    ) {
        self.appName = appName
        self.appID = appID
        self.before = before
        self.isSecure = isSecure
        self.isClearlyNotText = isClearlyNotText
        self.window = window
    }
}

/// The part of the app that touches the system: the microphone, the pill, and the document
/// the user is typing in. Each system has its own. Tests use a stand-in.
///
/// The driver calls everything here on the shell's main thread, except the two audio
/// readings, which it may call from any thread.
public protocol DictationShell: AnyObject {
    /// Starts recording the microphone at 16 kHz, one channel.
    func startRecording() throws
    /// Stops recording and returns everything captured.
    func stopRecording() -> [Int16]
    /// How much has been recorded so far, in seconds. Any thread.
    var recordedSeconds: Double { get }
    /// The most recent audio, at most `seconds` of it. Any thread.
    func latestAudio(seconds: Double) -> [Int16]
    /// Why the microphone cannot be used, in words for the pill. Nil when it can.
    var microphoneProblem: String? { get }

    func showPill(_ status: PillStatus)
    /// Shows a short message, then hides the pill.
    func flashPill(_ text: String, seconds: Double)
    /// A brief bump, to acknowledge a key press that cannot be acted on yet.
    func pulsePill()
    /// Shows the last few words heard so far, beside the level bars.
    func setPreview(_ text: String)

    func captureTarget() -> DeskTarget
    /// Types the text at the cursor. Returns false when it was left on the clipboard instead.
    func insert(_ text: String, into target: DeskTarget) -> Bool
    func copy(_ text: String)
    /// What to press to paste, for the pill: "Ctrl+V" on Windows.
    var pasteKeys: String { get }

    /// Runs work on the shell's main thread, soon. Any thread.
    func onMain(_ work: @escaping () -> Void)
}

/// Connects the keyboard, the microphone, the engines and the document.
///
/// This is the Mac app's `DictationController` without anything that only a Mac has. Use it
/// from the shell's main thread, except where a member says otherwise.
public final class DictationDriver {
    private let shell: DictationShell
    private let engines: DictationEngine
    private let settings: SettingsStore
    private let history: HistoryDesk
    private let dictionaryURL: URL
    private var machine = DictationMachine()
    private var ticker: DispatchSourceTimer?
    private var previews: Task<Void, Never>?
    private let recording = Flag()

    /// Called on the main thread after a dictation has been added to history.
    public var onHistoryChange: (() -> Void)?

    public init(
        shell: DictationShell,
        engines: DictationEngine,
        settings: SettingsStore,
        history: HistoryDesk,
        dictionaryURL: URL = EngineConfig.supportDirectory.appendingPathComponent("dictionary.json")
    ) {
        self.shell = shell
        self.engines = engines
        self.settings = settings
        self.history = history
        self.dictionaryURL = dictionaryURL
    }

    /// True while audio is being recorded. This is when Escape belongs to Lucid. Any thread.
    public var isRecording: Bool { recording.value }

    /// For tests: the timings of taps and holds.
    public var timing: DictationMachine.Timing {
        get { machine.timing }
        set { machine.timing = newValue }
    }

    /// Handles one keyboard signal. Returns true when the key press should not reach other apps.
    @discardableResult
    public func handle(_ signal: KeySignal) -> Bool {
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
        recording.value = machine.isRecording
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
            stopPreviews()
            _ = shell.stopRecording()
            shell.showPill(.hidden)
        case .enterHandsFree:
            shell.showPill(.handsFree)
        case .busy:
            shell.pulsePill()
        }
    }

    /// The machine needs regular ticks while recording, to time out a tap and to cap the length.
    private func updateTicker() {
        if machine.isRecording {
            guard ticker == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                self.shell.onMain { [weak self] in
                    guard let self, self.machine.isRecording else { return }
                    self.send(.tick)
                }
            }
            timer.resume()
            ticker = timer
        } else {
            ticker?.cancel()
            ticker = nil
        }
    }

    private func startRecording() {
        if let problem = shell.microphoneProblem {
            send(.escape)
            shell.flashPill(problem, seconds: 2.2)
            return
        }
        do {
            try shell.startRecording()
            shell.showPill(.recording)
            startPreviews()
        } catch {
            send(.escape)
            shell.flashPill("No microphone found", seconds: 2.2)
        }
    }

    // MARK: Words while speaking

    /// Shows the last few words heard, about once a second, until the recording ends.
    ///
    /// Each preview transcribes the end of the recording so far. It is only shown. The text
    /// that is inserted comes from the whole recording, once the user stops.
    private func startPreviews() {
        stopPreviews()
        guard settings.current.livePreview else { return }
        let prompt = ((try? PersonalDictionary.load(from: dictionaryURL)) ?? .empty).recognitionPrompt()
        let shell = shell
        let engines = engines
        let recording = recording
        previews = Task {
            var atLastRequest: Double?
            var lastTook = 0.0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled, recording.value else { return }
                let recorded = shell.recordedSeconds
                guard LivePreview.shouldRequest(recordedSeconds: recorded, atLastRequest: atLastRequest, lastTook: lastTook)
                else { continue }
                atLastRequest = recorded
                let window = shell.latestAudio(seconds: LivePreview.windowSeconds)
                // The speech engine invents words when given silence.
                guard AudioGate.hasSpeech(samples: window) else { continue }
                let began = Date()
                let heard = await engines.preview(wav: WAV.encode(samples: window), prompt: prompt)
                lastTook = Date().timeIntervalSince(began)
                guard !Task.isCancelled, let heard else { continue }
                let text = LivePreview.text(for: heard)
                guard !text.isEmpty else { continue }
                shell.onMain {
                    if recording.value { shell.setPreview(text) }
                }
            }
        }
    }

    private func stopPreviews() {
        previews?.cancel()
        previews = nil
    }

    // MARK: After speaking

    private func stopAndProcess() {
        stopPreviews()
        let samples = shell.stopRecording()
        // Read the cursor's surroundings now, while the user's app still has focus.
        let target = shell.captureTarget()
        guard AudioGate.hasSpeech(samples: samples) else {
            shell.flashPill("Didn't catch that", seconds: 2.2)
            send(.finished)
            return
        }
        shell.showPill(.processing)

        let wav = WAV.encode(samples: samples)
        let context = context(for: target.appID, before: target.before)
        let engines = engines
        Task { [weak self] in
            let outcome: Result<DictationOutcome, Error>
            do {
                outcome = .success(try await engines.dictate(wav: wav, context: context))
            } catch {
                outcome = .failure(error)
            }
            guard let self else { return }
            self.shell.onMain { [weak self] in
                guard let self else { return }
                self.finish(outcome, wav: wav, seconds: Double(samples.count) / 16_000, target: target)
                self.send(.finished)
            }
        }
    }

    private func context(for appID: String?, before: String?) -> PipelineContext {
        PipelineContext(
            level: settings.current.level,
            category: AppCategory.forApp(appID),
            dictionary: (try? PersonalDictionary.load(from: dictionaryURL)) ?? .empty,
            midSentence: InsertionPlanner.isMidSentence(before: before)
        )
    }

    /// Types the result where the user was, and records the dictation.
    private func finish(_ outcome: Result<DictationOutcome, Error>, wav: Data, seconds: Double, target: DeskTarget) {
        let kept = settings.current.keepRecordings ? wav : nil
        var entry = HistoryEntry(
            date: Date(), appName: target.appName, bundleID: target.appID,
            audioSeconds: seconds, speechMillis: 0, result: nil, failure: nil
        )
        switch outcome {
        case .success(let done):
            let text = done.result.finalText
            guard !text.isEmpty else {
                shell.flashPill("Didn't catch that", seconds: 2.2)
                return
            }
            let typed = shell.insert(InsertionPlanner.textToInsert(text, before: target.before), into: target)
            entry.speechMillis = done.speechMillis
            entry.result = done.result
            history.add(entry, wav: kept)
            if typed {
                shell.showPill(.hidden)
            } else {
                shell.flashPill("Copied. Press \(shell.pasteKeys)", seconds: 2.2)
            }
        case .failure(let error):
            entry.failure = "\(error)"
            history.add(entry, wav: kept)
            shell.flashPill(kept == nil ? "Couldn't transcribe that" : "Couldn't transcribe. Recording kept.", seconds: 3)
        }
        onHistoryChange?()
    }

    /// Runs a kept recording through the engines again and copies the result. It does not
    /// type it, because the user is looking at their history, not at their document.
    /// Returns what happened, in words for the window.
    @discardableResult
    public func retry(_ id: UUID) async -> String {
        guard !recording.value else { return "Finish the dictation in progress first." }
        guard let entry = history.entry(id), let wav = history.audio(for: entry) else {
            return "That recording is no longer kept."
        }
        let shell = shell
        shell.onMain { shell.showPill(.processing) }
        do {
            let outcome = try await engines.dictate(wav: wav, context: context(for: entry.bundleID, before: nil))
            history.remove(entry.id)
            history.add(
                HistoryEntry(
                    date: Date(), appName: entry.appName, bundleID: entry.bundleID,
                    audioSeconds: entry.audioSeconds, speechMillis: outcome.speechMillis,
                    result: outcome.result, failure: nil
                ),
                wav: wav
            )
            let text = outcome.result.finalText
            shell.onMain { [weak self] in
                shell.copy(text)
                shell.flashPill("Copied. Press \(shell.pasteKeys)", seconds: 2.2)
                self?.onHistoryChange?()
            }
            return "Transcribed and copied."
        } catch {
            shell.onMain { shell.flashPill("Still couldn't transcribe that", seconds: 3) }
            return "Still couldn't transcribe that. \(error)"
        }
    }
}

/// A yes or no that any thread can read and set.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false

    var value: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }
}
