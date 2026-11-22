import AppKit
import LucidCore

extension HotkeyChoice {
    /// The modifier flag that is set while this key is down.
    var flag: CGEventFlags {
        switch self {
        case .fn: return .maskSecondaryFn
        case .rightOption: return .maskAlternate
        case .rightCommand: return .maskCommand
        }
    }
}

/// Watches the keyboard through an event tap and reports what the dictation machine needs.
final class HotkeyMonitor {
    enum Signal {
        case hotkeyDown
        case hotkeyUp
        /// Any key other than the hotkey and Escape went down.
        case otherKeyDown
        case escape
    }

    var hotkey: HotkeyChoice {
        didSet { isDown = false }
    }

    /// Called on the main thread. Return true to keep an Escape press from other apps.
    var onSignal: ((Signal) -> Bool)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var isDown = false
    private static let escapeKey = 53

    init(hotkey: HotkeyChoice) {
        self.hotkey = hotkey
    }

    var isRunning: Bool { tap != nil }

    /// Starts watching. Returns false when macOS has not granted Accessibility access.
    func start() -> Bool {
        if tap != nil { return true }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: hotkeyTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        isDown = false
    }

    /// Looks at one event. Returns nil to swallow it, or the event to let it through.
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS switches a tap off if it is slow to answer. Switch it back on.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }

        case .flagsChanged:
            let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
            guard keyCode == hotkey.keyCode else { break }
            let pressed = event.flags.contains(hotkey.flag)
            if pressed != isDown {
                isDown = pressed
                _ = onSignal?(pressed ? .hotkeyDown : .hotkeyUp)
            }

        case .keyDown:
            // A held key repeats. Only the first press matters.
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { break }
            let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
            if keyCode == Self.escapeKey {
                if onSignal?(.escape) == true { return nil }
            } else {
                _ = onSignal?(.otherKeyDown)
            }

        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }
}

/// The event tap's entry point. The tap's source is on the main run loop, so this runs on
/// the main thread.
private func hotkeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    return monitor.handle(type: type, event: event)
}
