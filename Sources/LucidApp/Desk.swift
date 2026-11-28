import Foundation
import LucidCore
import LucidEngines

/// A key the user can hold to dictate.
public struct HotkeyOption: Codable, Equatable, Sendable {
    public var id: String
    public var title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

/// One thing Lucid needs before it can work, for the Setup list.
public struct SetupCheck: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var detail: String
    public var done: Bool
    /// A button that helps, such as "Open Microphone Settings…". Nil for none.
    public var action: String?
    /// Shown instead of a button while the action is under way: from 0 to 1.
    public var progress: Double?

    public init(id: String, title: String, detail: String, done: Bool, action: String? = nil, progress: Double? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.done = done
        self.action = action
        self.progress = progress
    }
}

/// Everything the app needs from the system it runs on. `DictationShell` is the part that
/// dictation uses. This adds what the window uses.
public protocol DeskShell: DictationShell {
    /// "Windows", for the About page.
    var systemName: String { get }
    /// False where there is no dictation key, microphone or typing, only the window.
    var canDictate: Bool { get }
    var hotkeys: [HotkeyOption] { get }
    var defaultHotkey: String { get }
    func useHotkey(_ id: String)
    /// What the system must provide before dictation works, such as a microphone.
    func setupChecks() -> [SetupCheck]
    /// Carries out the action of one of those checks.
    func performSetupAction(_ id: String)
    /// Whether Lucid opens when the user signs in. Nil where that cannot be set.
    var opensAtLogin: Bool? { get }
    /// Returns what went wrong, or nil.
    func setOpensAtLogin(_ on: Bool) -> String?
    /// True when `chooseModelFile` can show the system's own file chooser.
    var canChooseFiles: Bool { get }
    func chooseModelFile(kind: ModelKind) -> URL?
    func showFolder(_ url: URL)
}

/// Work on its way to another thread. Whoever makes one promises the work is safe there.
public struct Carried: @unchecked Sendable {
    public let work: () -> Void

    public init(_ work: @escaping () -> Void) {
        self.work = work
    }
}

/// A shell with no microphone, pill or keyboard. The window still works: models, dictionary,
/// history and settings. Used by `lucid-cli window`, and as a base for tests.
open class HeadlessShell: DeskShell {
    public init() {}

    open func startRecording() throws {}
    open func stopRecording() -> [Int16] { [] }
    open var recordedSeconds: Double { 0 }
    open func latestAudio(seconds: Double) -> [Int16] { [] }
    open var microphoneProblem: String? { "This copy of Lucid cannot record" }
    open func showPill(_ status: PillStatus) {}
    open func flashPill(_ text: String, seconds: Double) {}
    open func pulsePill() {}
    open func setPreview(_ text: String) {}
    open func captureTarget() -> DeskTarget { DeskTarget(appName: "Unknown app") }
    open func insert(_ text: String, into target: DeskTarget) -> Bool { false }
    open func copy(_ text: String) {}
    open var pasteKeys: String { "Ctrl+V" }
    open func onMain(_ work: @escaping () -> Void) {
        let carried = Carried(work)
        DispatchQueue.main.async { carried.work() }
    }

    open var systemName: String {
        #if os(Windows)
        return "Windows"
        #elseif os(macOS)
        return "macOS"
        #else
        return "Linux"
        #endif
    }

    open var canDictate: Bool { false }
    open var hotkeys: [HotkeyOption] { [] }
    open var defaultHotkey: String { "" }
    open func useHotkey(_ id: String) {}
    open func setupChecks() -> [SetupCheck] { [] }
    open func performSetupAction(_ id: String) {}
    open var opensAtLogin: Bool? { nil }
    open func setOpensAtLogin(_ on: Bool) -> String? { "Not available here." }
    open var canChooseFiles: Bool { false }
    open func chooseModelFile(kind: ModelKind) -> URL? { nil }
    open func showFolder(_ url: URL) {}
}

/// The app without a screen: its settings, engines, models, history and dictation, and the
/// local page that is its window. A shell for the system it runs on does the rest.
public final class Desk: @unchecked Sendable {
    public static let version = "0.1.0"

    public let shell: DeskShell
    public let settings: SettingsStore
    public let engines: DeskEngines
    public let models: ModelDesk
    public let history: HistoryDesk
    public let driver: DictationDriver
    public let dictionaryURL: URL
    /// The secret every request from the window must carry.
    public let key: String
    public private(set) var server: LocalServer!

    /// `folder` is where settings, history and the dictionary are kept. Tests pass their own.
    public init(
        shell: DeskShell,
        folder: URL = EngineConfig.supportDirectory,
        library: ModelLibrary = .standard,
        hub: HuggingFace = HuggingFace(),
        tracksProcesses: Bool = true
    ) throws {
        self.shell = shell
        settings = SettingsStore(url: folder.appendingPathComponent("settings.json"))
        history = HistoryDesk(directory: folder)
        dictionaryURL = folder.appendingPathComponent("dictionary.json")
        models = ModelDesk(library: library, hub: hub)
        let current = settings.current
        engines = DeskEngines(choices: current.models, level: current.level, library: library, tracksProcesses: tracksProcesses)
        driver = DictationDriver(shell: shell, engines: engines, settings: settings, history: history, dictionaryURL: dictionaryURL)
        key = Self.newKey()
        server = try LocalServer { [weak self] request in
            await self?.respond(to: request) ?? .failure("Lucid is closing.", status: 500)
        }
        models.onChange { [weak self] in
            guard let self else { return }
            Task { await self.engines.update(choices: self.settings.current.models) }
        }
    }

    /// 128 random bits, as text.
    private static func newKey() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<2).map { _ in String(generator.next() as UInt64, radix: 16) }.joined()
    }

    /// Starts the engines and the local page.
    public func start() {
        server.start()
        Task { await engines.start() }
    }

    /// Stops the engines and the page, and waits for the engines.
    public func stop() {
        server.stop()
        engines.stopNow()
    }

    /// The window's address, with the key the page needs. The key is after the `#`, which a
    /// browser keeps to itself: it is never sent anywhere or written to a log.
    public func windowAddress(section: String = "home") -> String {
        "\(server.address)/#\(section)&key=\(key)"
    }

    /// The key the dictation key is set to, among those this system offers.
    public var hotkey: String {
        let wanted = settings.current.hotkey
        return shell.hotkeys.contains { $0.id == wanted } ? (wanted ?? shell.defaultHotkey) : shell.defaultHotkey
    }

    func personalDictionary() -> (dictionary: PersonalDictionary, problem: String?) {
        do {
            return (try PersonalDictionary.load(from: dictionaryURL), nil)
        } catch {
            return (.empty, "The dictionary file could not be read, so it is not being used. "
                + "Fix or delete dictionary.json in Lucid's folder, then reload this page.")
        }
    }
}
