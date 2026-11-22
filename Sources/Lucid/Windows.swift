import AppKit
import SwiftUI

/// Opens Lucid's windows, and brings an open one forward instead of making a second.
@MainActor
final class Windows: NSObject, NSWindowDelegate {
    enum Kind {
        case settings
        case setup

        var title: String {
            switch self {
            case .settings: return "Lucid Settings"
            case .setup: return "Set Up Lucid"
            }
        }
    }

    private var open: [Kind: NSWindow] = [:]
    /// Called when a window closes, so its owner can stop any polling it started.
    var onClose: ((Kind) -> Void)?

    func show(_ kind: Kind, content: () -> AnyView) {
        if let window = open[kind] {
            bringForward(window)
            return
        }
        let hosting = NSHostingController(rootView: content())
        let window = NSWindow(contentViewController: hosting)
        window.title = kind.title
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        open[kind] = window
        bringForward(window)
    }

    func close(_ kind: Kind) {
        open[kind]?.close()
    }

    private func bringForward(_ window: NSWindow) {
        // Lucid has no Dock icon, so it must be made active before its window can take focus.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let kind = open.first(where: { $0.value === window })?.key else { return }
        open[kind] = nil
        onClose?(kind)
    }
}
