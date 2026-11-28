import CLucidDesk
import Foundation
import LucidApp
import LucidCore
import LucidEngines

/// Work for the main thread, from any thread. The desktop wakes the main thread to do it.
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

/// The keys that can start a dictation, with each system's own numbers for them.
enum DesktopHotkey: String, CaseIterable {
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

    /// A virtual-key code on Windows. On Linux, a key code as in <linux/input-event-codes.h>.
    var virtualKey: Int32 {
        #if os(Windows)
        switch self {
        case .rightControl: return 0xA3
        case .rightAlt: return 0xA5
        case .rightShift: return 0xA1
        }
        #else
        switch self {
        case .rightControl: return 97
        case .rightAlt: return 100
        case .rightShift: return 54
        }
        #endif
    }

    /// Escape, in the same numbering.
    static var escapeKey: Int32 {
        #if os(Windows)
        return 0x1B
        #else
        return 1
        #endif
    }
}

/// Lucid on Windows and on Linux: the microphone, the pill, the dictation key and typing, by
/// way of the C layer, which has a half for each. The app's logic is in `Desk`, which is the
/// same on every system.
final class DesktopShell: DeskShell {
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
        #if os(Linux)
        if recorder.isEmpty { return "Nothing to record with is installed" }
        #endif
        if lucid_mic_devices() == 0 { return "No microphone found" }
        if !lucid_mic_allowed() { return "Windows is keeping apps from the microphone" }
        return nil
    }

    /// The program Lucid records with on Linux, or nothing when none is installed.
    var recorder: String { text(capacity: 64) { lucid_mic_recorder($0, $1) } }

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
            // Neither system says what is before the cursor, so the text goes in as it is.
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

    var systemName: String {
        #if os(Windows)
        return "Windows"
        #else
        return "Linux"
        #endif
    }

    var canDictate: Bool { true }

    var hotkeys: [HotkeyOption] {
        DesktopHotkey.allCases.map { HotkeyOption(id: $0.rawValue, title: $0.title) }
    }

    var defaultHotkey: String { DesktopHotkey.rightControl.rawValue }

    func useHotkey(_ id: String) {
        lucid_set_hotkey((DesktopHotkey(rawValue: id) ?? .rightControl).virtualKey)
    }

    func setupChecks() -> [SetupCheck] {
        #if os(Windows)
        return windowsChecks()
        #else
        return linuxChecks()
        #endif
    }

    #if os(Windows)
    private func windowsChecks() -> [SetupCheck] {
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
    #else
    /// How to let Lucid work in a Wayland session, which keeps apps from the keyboard.
    static let waylandAdvice = "Allowing it lets the programs you run read the keys you type and press keys, as any program can in an X11 session. You are asked for your password. Or sign in with an X11 (“Xorg”) session, where none of this is needed."
    static let waylandAction = "Allow Lucid to Use the Keyboard…"

    private func linuxChecks() -> [SetupCheck] {
        let wayland = lucid_is_wayland()
        let watched = lucid_keyboard_watched()
        let key = SetupCheck(
            id: "keyboard",
            title: "Dictation key",
            detail: watched
                ? "Lucid is listening for the key."
                : wayland
                    ? "This is a Wayland session, which does not show apps the keys you press elsewhere. Lucid can read the keyboard itself if you allow it. " + Self.waylandAdvice
                    : "The display did not let Lucid listen for the key. Quit Lucid from its icon in the panel, then open it again.",
            done: watched,
            action: !watched && wayland ? Self.waylandAction : nil
        )

        let microphone: SetupCheck
        if recorder.isEmpty {
            microphone = SetupCheck(
                id: "microphone", title: "Microphone",
                detail: "Lucid records with parec, pw-record or arecord, and none of them is installed. Install pulseaudio-utils, pipewire or alsa-utils.",
                done: false
            )
        } else if lucid_mic_devices() == 0 {
            microphone = SetupCheck(
                id: "microphone", title: "Microphone",
                detail: "The sound system has no microphone to record from. Connect one, or choose one in the sound settings.",
                done: false
            )
        } else {
            microphone = SetupCheck(id: "microphone", title: "Microphone", detail: "Lucid can record from it, with \(recorder).", done: true)
        }

        var checks = [key, microphone]
        if !lucid_can_type() {
            checks.append(SetupCheck(
                id: "typing", title: "Typing into other apps",
                detail: wayland
                    ? "A Wayland session does not let one app press keys in another, so Lucid leaves the text on the clipboard for you to paste. It can type for you if you allow it. " + Self.waylandAdvice
                    : "The display does not let Lucid press keys in other apps, so it leaves the text on the clipboard for you to paste.",
                done: false,
                // One permission covers both, so the button is only on the first of the two.
                action: wayland && watched ? Self.waylandAction : nil
            ))
        }
        return checks
    }
    #endif

    func performSetupAction(_ id: String) {
        #if os(Windows)
        switch id {
        case "sound": lucid_open("ms-settings:sound")
        case "microphone": lucid_open("ms-settings:privacy-microphone")
        default: break
        }
        #else
        if id == "keyboard" || id == "typing", !lucid_allow_keys() {
            lucid_alert("Lucid", "Lucid could not ask for permission: this desktop has no pkexec. Run scripts/setup-linux.sh --allow-keys instead, or sign in with an X11 session.")
        }
        #endif
    }

    var opensAtLogin: Bool? { lucid_opens_at_login() }

    func setOpensAtLogin(_ on: Bool) -> String? {
        lucid_set_opens_at_login(on) ? nil : "Lucid could not change that."
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
