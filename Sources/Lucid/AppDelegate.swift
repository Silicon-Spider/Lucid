import AppKit
import LucidCore
import LucidEngines

extension CleanupLevel {
    var title: String {
        switch self {
        case .off: return "Off: exactly what you said"
        case .light: return "Light: remove fillers, fix punctuation"
        case .medium: return "Medium: also tighten wording"
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = AppSettings()
    private let pill = PillController()
    private let history = HistoryStore(directory: EngineConfig.supportDirectory)
    private lazy var engines = EngineManager(level: settings.level)
    private lazy var controller = DictationController(settings: settings, engines: engines, history: history, pill: pill)
    private lazy var hotkeys = HotkeyMonitor(hotkey: settings.hotkey)

    private var statusItem: NSStatusItem?
    private var permissionTimer: Timer?
    private var signalSources: [DispatchSourceSignal] = []
    /// Set when the app is started by a script, so no system dialogs are left on screen.
    private let quiet = CommandLine.arguments.contains("--no-prompts")

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let identifier = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: identifier).count > 1 {
            // Lucid is already running. Two copies would both answer the hotkey.
            NSApp.terminate(nil)
            return
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Lucid")
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
        statusItem = item

        hotkeys.onSignal = { [weak self] signal in
            self?.controller.handle(signal) ?? false
        }
        stopEnginesOnSignals()
        Task { await engines.start() }

        if !quiet {
            Task {
                if Permissions.microphone == .notDetermined { _ = await Permissions.requestMicrophone() }
            }
            if !Permissions.accessibility { Permissions.promptForAccessibility() }
        }
        startHotkeysWhenAllowed()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeys.stop()
        engines.stopNow()
    }

    /// A plain `kill` would skip `applicationWillTerminate` and leave the engines running.
    private func stopEnginesOnSignals() {
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
    }

    /// The event tap can only be created once Accessibility access is granted, so keep trying.
    private func startHotkeysWhenAllowed() {
        if Permissions.accessibility, hotkeys.start() {
            permissionTimer?.invalidate()
            permissionTimer = nil
            return
        }
        guard permissionTimer == nil else { return }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.startHotkeysWhenAllowed() }
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let status = NSMenuItem(title: statusLine, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        for item in fixItems() { menu.addItem(item) }
        menu.addItem(.separator())

        let levels = CleanupLevel.allCases.map { level -> NSMenuItem in
            let unavailable = level == .medium && !EngineManager.generalModelInstalled
            let item = actionItem(
                unavailable ? "Medium: needs the optional model (see README)" : level.title,
                #selector(chooseLevel(_:))
            )
            item.representedObject = level.rawValue
            item.state = settings.level == level ? .on : .off
            item.isEnabled = !unavailable
            return item
        }
        menu.addItem(submenu("Cleanup", levels))

        let keys = HotkeyChoice.allCases.map { choice -> NSMenuItem in
            let item = actionItem(choice.title, #selector(chooseHotkey(_:)))
            item.representedObject = choice.rawValue
            item.state = settings.hotkey == choice ? .on : .off
            return item
        }
        menu.addItem(submenu("Dictation Key", keys))
        menu.addItem(.separator())

        let recent = history.entries.prefix(8)
        if recent.isEmpty {
            let empty = NSMenuItem(title: "No dictations yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            let heading = NSMenuItem(title: "Recent (choose one to copy it)", action: nil, keyEquivalent: "")
            heading.isEnabled = false
            menu.addItem(heading)
            for entry in recent {
                let item = actionItem(Self.menuTitle(for: entry), #selector(copyEntry(_:)))
                item.representedObject = entry.id.uuidString
                item.isEnabled = entry.result != nil
                menu.addItem(item)
            }
            menu.addItem(actionItem("Copy Last Original", #selector(copyLastOriginal)))
        }
        menu.addItem(.separator())
        menu.addItem(actionItem("Quit Lucid", #selector(quit), key: "q"))
    }

    private var statusLine: String {
        if !Permissions.accessibility { return "Lucid needs Accessibility access" }
        if !hotkeys.isRunning { return "Restart Lucid to finish setting up" }
        if Permissions.microphone != .authorized { return "Lucid needs microphone access" }
        switch engines.status {
        case .starting: return "Starting the engines…"
        case .setupNeeded: return "Setup needed: run scripts/setup.sh"
        case .failed: return "The engines did not start"
        case .ready: return "Ready. Hold \(settings.hotkey.title) and speak."
        }
    }

    /// Menu items that take the user to whatever is stopping Lucid from working.
    private func fixItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        if !Permissions.accessibility {
            items.append(actionItem("Open Accessibility Settings…", #selector(openAccessibility)))
        } else if !hotkeys.isRunning {
            items.append(actionItem("Restart Lucid", #selector(restart)))
        }
        if Permissions.microphone != .authorized {
            items.append(actionItem("Open Microphone Settings…", #selector(openMicrophone)))
        }
        if settings.hotkey == .fn, Permissions.fnKeyConflicts {
            items.append(actionItem("Fn also triggers a macOS shortcut. Open Keyboard Settings…", #selector(openKeyboard)))
        }
        return items
    }

    private func actionItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        menu.autoenablesItems = false
        for item in items { menu.addItem(item) }
        parent.submenu = menu
        return parent
    }

    /// One line for the menu: the start of the text, or the reason it failed.
    private static func menuTitle(for entry: HistoryEntry) -> String {
        guard let result = entry.result else { return "Failed: \(entry.failure ?? "unknown reason")" }
        let line = result.finalText.replacingOccurrences(of: "\n", with: " ")
        return line.count > 60 ? String(line.prefix(57)) + "…" : line
    }

    // MARK: Actions

    @objc private func chooseLevel(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let level = CleanupLevel(rawValue: raw) else { return }
        settings.level = level
        Task { await engines.setLevel(level) }
    }

    @objc private func chooseHotkey(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let choice = HotkeyChoice(rawValue: raw) else { return }
        settings.hotkey = choice
        hotkeys.hotkey = choice
    }

    @objc private func copyEntry(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let entry = history.entries.first(where: { $0.id.uuidString == raw }),
              let text = entry.result?.finalText else { return }
        TextInserter.copy(text)
        pill.flash("Copied")
    }

    @objc private func copyLastOriginal() {
        guard let original = history.entries.compactMap({ $0.result?.raw }).first else { return }
        TextInserter.copy(original)
        pill.flash("Original copied")
    }

    @objc private func openAccessibility() { Permissions.openAccessibilitySettings() }
    @objc private func openMicrophone() { Permissions.openMicrophoneSettings() }
    @objc private func openKeyboard() { Permissions.openKeyboardSettings() }

    /// macOS sometimes only lets a newly trusted app create its event tap after a restart.
    @objc private func restart() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Wait for this copy to quit first, or the new one would see it and quit instead.
        task.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
