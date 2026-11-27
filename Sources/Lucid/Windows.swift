import AppKit
import SwiftUI

/// Opens Lucid's windows, and brings an open one forward instead of making a second.
@MainActor
final class Windows: NSObject, NSWindowDelegate {
    enum Kind {
        /// The one window with everything in it.
        case main

        var title: String {
            switch self {
            case .main: return "Lucid"
            }
        }

        /// The name its size and position are remembered under.
        var autosaveName: String {
            switch self {
            case .main: return "LucidMainWindow"
            }
        }
    }

    private var open: [Kind: NSWindow] = [:]
    /// Called when a window closes, so its owner can stop any polling it started.
    var onClose: ((Kind) -> Void)?

    func isOpen(_ kind: Kind) -> Bool {
        open[kind] != nil
    }

    /// Opens the window, sized `size` unless the user has resized it before, and never
    /// smaller than `minimumSize`.
    func show(_ kind: Kind, size: CGSize, minimumSize: CGSize, content: () -> AnyView) {
        if let window = open[kind] {
            bringForward(window)
            return
        }
        let hosting = NSHostingController(rootView: content())
        // The window keeps the size the user gives it. The content only sets the smallest.
        hosting.sizingOptions = [.minSize]
        let window = NSWindow(contentViewController: hosting)
        window.title = kind.title
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentMinSize = minimumSize
        window.setContentSize(size)
        window.center()
        // Restores the size and position from last time, if there was one.
        window.setFrameAutosaveName(kind.autosaveName)
        open[kind] = window
        bringForward(window)
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
