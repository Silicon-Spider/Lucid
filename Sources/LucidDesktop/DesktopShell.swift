import CLucidWin
import Foundation
import LucidApp
import LucidCore
import LucidEngines

/// Work for the main thread, from any thread. Windows wakes the main thread to do it.
final class Mailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [() -> Void] = []

    func post(_ work: @escaping () -> Void) {
        lock.lock()
        waiting.append(work)
        lock.unlock()
        lucid_wake()
    }

    /// Does everything posted so far. Main thread.
    func deliver() {
        lock.lock()
        let due = waiting
        waiting = []
        lock.unlock()
        for work in due { work() }
    }
}

/// The text in a buffer the C layer filled, up to its ending zero.
func text(in buffer: [CChar]) -> String {
    String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

/// Reads text that the C layer writes into a buffer.
func text(capacity: Int = 1024, _ fill: (UnsafeMutablePointer<CChar>, Int) -> Int) -> String {
    var buffer = [CChar](repeating: 0, count: capacity)
    _ = buffer.withUnsafeMutableBufferPointer { fill($0.baseAddress!, capacity) }
    return text(in: buffer)
}

/// The keys that can start a dictation, with Windows' own numbers for them.
enum WindowsHotkey: String, CaseIterable {
    case rightControl
    case rightAlt
    case rightShift

    var title: String {
        switch self {
        case .rightControl: return "Right Ctrl"
        case .rightAlt: return "Right Alt"
        case .rightShift: return "Right Shift"
        }
    }

    var virtualKey: Int32 {
        switch self {
        case .rightControl: return 0xA3
        case .rightAlt: return 0xA5
        case .rightShift: return 0xA1
        }
    }
}

/// Lucid on Windows: the microphone, the pill, the dictation key and typing, by way of the
/// C layer. The app's logic is in `Desk`, which is the same on every system.
final class WindowsShell: DeskShell {
    let mailbox = Mailbox()
    /// Called on the main thread when the pill changes, so the tray icon can follow.
    var onPill: ((PillStatus) -> Void)?

    // MARK: The microphone

    struct NoMicrophone: Error {}

    func startRecording() throws {
        guard lucid_mic_start() else { throw NoMicrophone() }
    }

    func stopRecording() -> [Int16] {
        let count = lucid_mic_stop()
        guard count > 0 else {
            _ = lucid_mic_take(nil, 0)
            return []
        }
        var samples = [Int16](repeating: 0, count: count)
        let taken = samples.withUnsafeMutableBufferPointer { lucid_mic_take($0.baseAddress, count) }
        return Array(samples.prefix(taken))
    }

    var recordedSeconds: Double { Double(lucid_mic_count()) / 16_000 }

    func latestAudio(seconds: Double) -> [Int16] {
        let wanted = max(0, Int(seconds * 16_000))
        guard wanted > 0 else { return [] }
        var samples = [Int16](repeating: 0, count: wanted)
        let taken = samples.withUnsafeMutableBufferPointer { lucid_mic_latest($0.baseAddress, wanted) }
        return Array(samples.prefix(taken))
    }

    var microphoneProblem: String? {
        if lucid_mic_devices() == 0 { return "No microphone found" }
        if !lucid_mic_allowed() { return "Windows is keeping apps from the microphone" }
        return nil
    }

    // MARK: The pill

    func showPill(_ status: PillStatus) {
        switch status {
        case .hidden: lucid_pill_show(Int32(LUCID_PILL_HIDDEN), nil)
        case .recording: lucid_pill_show(Int32(LUCID_PILL_RECORDING), nil)
        case .handsFree: lucid_pill_show(Int32(LUCID_PILL_HANDS_FREE), nil)
        case .processing: lucid_pill_show(Int32(LUCID_PILL_PROCESSING), nil)
        case .message(let text): lucid_pill_show(Int32(LUCID_PILL_MESSAGE), text)
        }
        onPill?(status)
    }

    func flashPill(_ text: String, seconds: Double) {
        lucid_pill_flash(text, Int32(seconds * 1000))
        onPill?(.message(text))
    }

    func pulsePill() {
        lucid_pill_pulse()
    }

    func setPreview(_ text: String) {
        lucid_pill_preview(text)
    }

    // MARK: The app in front

    func captureTarget() -> DeskTarget {
        var program = [CChar](repeating: 0, count: 260)
        var name = [CChar](repeating: 0, count: 260)
        var secure = false
        var notText = false
        let window = program.withUnsafeMutableBufferPointer { program in
            name.withUnsafeMutableBufferPointer { name in
                lucid_front_window(program.baseAddress, program.count, name.baseAddress, name.count, &secure, &notText)
            }
        }
        let programName = text(in: program)
        let appName = text(in: name)
        return DeskTarget(
            appName: appName.isEmpty ? "Unknown app" : appName,
            appID: programName.isEmpty ? nil : programName,
            // Windows does not say what is before the cursor, so the text goes in as it is.
            before: nil,
            isSecure: secure,
            isClearlyNotText: notText || window == 0,
            window: UInt(window)
        )
    }

    func insert(_ text: String, into target: DeskTarget) -> Bool {
        if target.isSecure || target.isClearlyNotText {
            lucid_copy(text)
            return false
        }
        return lucid_paste(text)
    }

    func copy(_ text: String) {
        lucid_copy(text)
    }

    var pasteKeys: String { "Ctrl+V" }

    func onMain(_ work: @escaping () -> Void) {
        mailbox.post(work)
    }

    // MARK: What the window shows and asks

    var systemName: String { "Windows" }
    var canDictate: Bool { true }

    var hotkeys: [HotkeyOption] {
        WindowsHotkey.allCases.map { HotkeyOption(id: $0.rawValue, title: $0.title) }
    }

    var defaultHotkey: String { WindowsHotkey.rightControl.rawValue }

    func useHotkey(_ id: String) {
        lucid_set_hotkey((WindowsHotkey(rawValue: id) ?? .rightControl).virtualKey)
    }

    func setupChecks() -> [SetupCheck] {
        let watched = lucid_keyboard_watched()
        let key = SetupCheck(
            id: "keyboard",
            title: "Dictation key",
            detail: watched
                ? "Lucid is listening for the key."
                : "Windows did not let Lucid listen for the key. Quit Lucid from its icon beside the clock, then open it again.",
            done: watched
        )
        let microphone: SetupCheck
        if lucid_mic_devices() == 0 {
            microphone = SetupCheck(
                id: "sound", title: "Microphone",
                detail: "Windows has no microphone to record from. Connect one, or choose one in Sound settings.",
                done: false, action: "Open Sound Settings…"
            )
        } else if !lucid_mic_allowed() {
            microphone = SetupCheck(
                id: "microphone", title: "Microphone",
                detail: "Windows is set to keep apps from the microphone. Turn on microphone access, and “Let desktop apps access your microphone”.",
                done: false, action: "Open Microphone Settings…"
            )
        } else {
            microphone = SetupCheck(id: "microphone", title: "Microphone", detail: "Lucid can record from it.", done: true)
        }
        return [key, microphone]
    }

    func performSetupAction(_ id: String) {
        switch id {
        case "sound": lucid_open("ms-settings:sound")
        case "microphone": lucid_open("ms-settings:privacy-microphone")
        default: break
        }
    }

    var opensAtLogin: Bool? { lucid_opens_at_login() }

    func setOpensAtLogin(_ on: Bool) -> String? {
        lucid_set_opens_at_login(on) ? nil : "Windows did not let Lucid change that."
    }

    var canChooseFiles: Bool { true }

    func chooseModelFile(kind: ModelKind) -> URL? {
        let title = kind == .speech ? "Add a speech model" : "Add a cleanup model"
        let patterns = kind == .speech ? "*.bin" : "*.gguf"
        let path = text(capacity: 4096) { lucid_choose_file(title, "Models", patterns, $0, $1) }
        return path.isEmpty ? nil : URL(fileURLWithPath: path)
    }

    func showFolder(_ url: URL) {
        lucid_open(url.path)
    }
}
