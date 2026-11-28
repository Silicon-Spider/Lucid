import CLucidDesk
import Foundation
import LucidApp
import LucidCore
import LucidEngines

extension CleanupLevel {
    var menuTitle: String {
        switch self {
        case .off: return "Off: exactly what you said"
        case .light: return "Light: remove fillers, fix punctuation"
        case .medium: return "Medium: also tighten wording"
        }
    }
}

/// What the items of the tray menu do. The desktop reports the number of the one chosen.
private enum Command {
    static let open: Int32 = 1
    static let models: Int32 = 2
    static let settings: Int32 = 3
    static let quit: Int32 = 4
    static let copyLastOriginal: Int32 = 5
    static let fixMicrophone: Int32 = 6
    static let firstLevel: Int32 = 10
    static let firstHotkey: Int32 = 20
    static let firstRecent: Int32 = 100
}

/// One line of the tray menu.
struct MenuLine: Equatable {
    var command: Int32 = 0
    var title = ""
    var flags: Int32 = 0

    static let separator = MenuLine(flags: Int32(LUCID_MENU_SEPARATOR))
    static let closeSubmenu = MenuLine(flags: Int32(LUCID_MENU_CLOSES))

    static func note(_ title: String) -> MenuLine {
        MenuLine(title: title, flags: Int32(LUCID_MENU_DISABLED))
    }

    static func submenu(_ title: String) -> MenuLine {
        MenuLine(title: title, flags: Int32(LUCID_MENU_OPENS))
    }

    static func action(_ command: Int32, _ title: String, checked: Bool = false, enabled: Bool = true) -> MenuLine {
        var flags: Int32 = 0
        if checked { flags |= Int32(LUCID_MENU_CHECKED) }
        if !enabled { flags |= Int32(LUCID_MENU_DISABLED) }
        return MenuLine(command: command, title: title, flags: flags)
    }
}

/// The app on Windows and on Linux: the icon beside the clock, its menu, and Lucid's window.
/// Dictation itself is `Desk`'s work, which is the same on every system.
///
/// Everything here runs on the main thread, where the desktop delivers what happens.
final class DesktopApp {
    /// The one app, for what the desktop calls back with. Plain C functions cannot carry it.
    static var shared: DesktopApp?

    let shell = DesktopShell()
    let desk: Desk
    private var recentIDs: [UUID] = []
    private var pill: PillStatus = .hidden

    /// The title of the page, which is how its window is found again.
    static let windowTitle = "Lucid"

    init(folder: URL = EngineConfig.supportDirectory, library: ModelLibrary = .standard, tracksProcesses: Bool = true) throws {
        desk = try Desk(shell: shell, folder: folder, library: library, tracksProcesses: tracksProcesses)
    }

    /// Starts everything that needs the desktop. False when it would not give Lucid a window.
    func start() -> Bool {
        DesktopApp.shared = self
        var callbacks = LucidCallbacks(
            key: { signal in DesktopApp.shared?.key(signal) },
            wants_escape: { DesktopApp.shared?.desk.driver.isRecording ?? false },
            wake: { DesktopApp.shared?.shell.mailbox.deliver() },
            menu_opening: { DesktopApp.shared?.fillMenu() },
            menu_chosen: { command in DesktopApp.shared?.choose(command) },
            activated: { DesktopApp.shared?.openWindow("home") }
        )
        guard lucid_start(&callbacks) else { return false }
        shell.useHotkey(desk.hotkey)
        shell.onPill = { [weak self] status in
            self?.pill = status
            self?.refreshTray()
        }
        let mailbox = shell.mailbox
        desk.engines.onStatus { _ in
            mailbox.post { DesktopApp.shared?.refreshTray() }
        }
        refreshTray()
        return true
    }

    /// Runs until the user quits. Returns the exit code.
    func run() -> Int32 {
        // Before the engines start: they are console programs, and would each open a window.
        lucid_hide_consoles()
        #if !os(Windows)
        // A plain `kill`, or signing out, would otherwise leave the engines running.
        let signals = [SIGTERM, SIGINT].map { number -> DispatchSourceSignal in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { lucid_quit() }
            source.resume()
            return source
        }
        defer { signals.forEach { $0.cancel() } }
        #endif
        desk.start()
        if !desk.settings.current.welcomed {
            // The window opens by itself only the first time, to show how Lucid works.
            desk.settings.update { $0.welcomed = true }
            openWindow("home")
        }
        let code = lucid_run()
        lucid_close_window(Self.windowTitle)
        desk.stop()
        lucid_stop()
        DesktopApp.shared = nil
        return code
    }

    // MARK: The keyboard

    private func key(_ signal: Int32) {
        switch signal {
        case Int32(LUCID_KEY_DOWN): desk.driver.handle(.hotkeyDown)
        case Int32(LUCID_KEY_UP): desk.driver.handle(.hotkeyUp)
        case Int32(LUCID_KEY_OTHER): desk.driver.handle(.otherKeyDown)
        case Int32(LUCID_KEY_ESCAPE): desk.driver.handle(.escape)
        default: break
        }
    }

    // MARK: The tray icon

    /// One line on how Lucid is doing, for the menu and for the icon's tooltip.
    var statusLine: String {
        if !lucid_keyboard_watched() { return "Lucid cannot listen for the dictation key" }
        if let problem = shell.microphoneProblem { return problem }
        switch desk.engines.status {
        case .starting: return "Starting the engines…"
        case .setupNeeded:
            return desk.engines.enginesMissing
                ? "Setup needed: run \(Self.setupScript)"
                : "Setup needed: open Lucid to download the models"
        case .failed: return "The engines did not start"
        case .ready: return "Ready. Hold \(hotkeyTitle) and speak."
        }
    }

    /// The script that installs the engines, as the user would type it.
    static var setupScript: String {
        #if os(Windows)
        return "scripts\\setup.ps1"
        #else
        return "scripts/setup-linux.sh"
        #endif
    }

    private var hotkeyTitle: String {
        DesktopHotkey(rawValue: desk.hotkey)?.title ?? DesktopHotkey.rightControl.title
    }

    private var needsAttention: Bool {
        if !lucid_keyboard_watched() || shell.microphoneProblem != nil { return true }
        switch desk.engines.status {
        case .ready, .starting: return false
        case .setupNeeded, .failed: return true
        }
    }

    func refreshTray() {
        let look: Int32
        switch pill {
        case .recording, .handsFree: look = Int32(LUCID_TRAY_RECORDING)
        default: look = needsAttention ? Int32(LUCID_TRAY_ATTENTION) : Int32(LUCID_TRAY_IDLE)
        }
        lucid_tray_update(look, "Lucid: \(statusLine)")
    }

    /// The menu, as it should be now.
    func menuLines() -> [MenuLine] {
        let settings = desk.settings.current
        var lines = [MenuLine.note(statusLine)]
        if shell.microphoneProblem != nil, lucid_mic_devices() > 0 {
            lines.append(.action(Command.fixMicrophone, "Open Microphone Settings…"))
        }
        lines.append(.separator)

        let mediumAvailable = desk.models.library.plan(for: settings.models).medium != nil
        lines.append(.submenu("Cleanup"))
        for (index, level) in CleanupLevel.allCases.enumerated() {
            let unavailable = level == .medium && !mediumAvailable
            lines.append(.action(
                Command.firstLevel + Int32(index),
                unavailable ? "Medium: needs a larger model (see Models in Lucid's window)" : level.menuTitle,
                checked: settings.level == level,
                enabled: !unavailable
            ))
        }
        lines.append(.closeSubmenu)

        lines.append(.submenu("Dictation Key"))
        for (index, hotkey) in DesktopHotkey.allCases.enumerated() {
            lines.append(.action(Command.firstHotkey + Int32(index), hotkey.title, checked: desk.hotkey == hotkey.rawValue))
        }
        lines.append(.closeSubmenu)
        lines.append(.separator)

        let recent = Array(desk.history.entries.prefix(8))
        recentIDs = recent.map(\.id)
        if recent.isEmpty {
            lines.append(.note("No dictations yet"))
        } else {
            lines.append(.note("Recent (choose one to copy it)"))
            for (index, entry) in recent.enumerated() {
                lines.append(.action(
                    Command.firstRecent + Int32(index), Self.menuTitle(for: entry), enabled: entry.result != nil
                ))
            }
            lines.append(.action(Command.copyLastOriginal, "Copy Last Original"))
        }
        lines.append(.separator)
        lines.append(.action(Command.open, "Open Lucid…"))
        lines.append(.action(Command.models, "Models…"))
        lines.append(.action(Command.settings, "Settings…"))
        lines.append(.separator)
        lines.append(.action(Command.quit, "Quit Lucid"))
        return lines
    }

    /// One line for the menu: the start of the text, or the reason it failed.
    static func menuTitle(for entry: HistoryEntry) -> String {
        guard let result = entry.result else { return "Failed: \(entry.failure ?? "unknown reason")" }
        var line = result.finalText.replacingOccurrences(of: "\n", with: " ")
        #if os(Windows)
        // Windows reads "&" in a menu as "underline the next letter".
        line = line.replacingOccurrences(of: "&", with: "&&")
        #endif
        return line.count > 60 ? String(line.prefix(57)) + "…" : line
    }

    private func fillMenu() {
        lucid_menu_clear()
        for line in menuLines() { lucid_menu_add(line.command, line.title, line.flags) }
    }

    func choose(_ command: Int32) {
        switch command {
        case Command.open: openWindow("home")
        case Command.models: openWindow("models")
        case Command.settings: openWindow("settings")
        case Command.quit: lucid_quit()
        case Command.fixMicrophone: shell.performSetupAction("microphone")
        case Command.copyLastOriginal:
            guard let original = desk.history.entries.compactMap({ $0.result?.raw }).first else { return }
            shell.copy(original)
            shell.flashPill("Original copied", seconds: 2.2)
        case Command.firstLevel..<(Command.firstLevel + Int32(CleanupLevel.allCases.count)):
            let level = CleanupLevel.allCases[Int(command - Command.firstLevel)]
            desk.settings.update { $0.level = level }
            let engines = desk.engines
            Task { await engines.update(level: level) }
        case Command.firstHotkey..<(Command.firstHotkey + Int32(DesktopHotkey.allCases.count)):
            let hotkey = DesktopHotkey.allCases[Int(command - Command.firstHotkey)]
            desk.settings.update { $0.hotkey = hotkey.rawValue }
            shell.useHotkey(hotkey.rawValue)
            refreshTray()
        case Command.firstRecent..<(Command.firstRecent + 8):
            let index = Int(command - Command.firstRecent)
            guard index < recentIDs.count, let text = desk.history.entry(recentIDs[index])?.result?.finalText else { return }
            shell.copy(text)
            shell.flashPill("Copied", seconds: 2.2)
        default:
            break
        }
    }

    // MARK: Lucid's window

    /// Opens Lucid's window at one of its parts, or brings it forward and turns it to that part.
    func openWindow(_ section: String) {
        if desk.windowIsOpen {
            if lucid_focus_window(Self.windowTitle) {
                desk.turn(to: section)
                return
            }
            if lucid_is_wayland() {
                // Wayland does not let Lucid bring its window forward. Opening another
                // would leave two, so the one that is open is turned to the right part.
                desk.turn(to: section)
                lucid_tray_notify("Lucid", "Lucid's window is already open.")
                return
            }
        }
        // The browser keeps the window's size and place here, apart from the user's own browsing.
        let profile = EngineConfig.supportDirectory.appendingPathComponent("window").path
        if !lucid_open_window(desk.windowAddress(section: section), profile) {
            lucid_alert("Lucid", "Lucid could not open its window. It needs a web browser.")
        }
    }
}
