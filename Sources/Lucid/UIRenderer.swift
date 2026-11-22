import AppKit
import SwiftUI

/// Draws the app's views to PNG files, so they can be looked at without running the app.
enum UIRenderer {
    @MainActor
    static func render(into folder: URL) -> Int32 {
        _ = NSApplication.shared
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (name, view) in pillViews() {
                try write(view, to: folder.appendingPathComponent("\(name).png"))
                print("wrote \(name).png")
            }
            return 0
        } catch {
            print("error: \(error)")
            return 1
        }
    }

    @MainActor
    private static func pillViews() -> [(String, AnyView)] {
        func pill(_ state: PillState, level: Float = 0) -> AnyView {
            let model = PillModel()
            model.state = state
            model.level = level
            // A mid-grey backdrop shows the pill's edge the way a real desktop would.
            return AnyView(
                PillView(model: model)
                    .padding(20)
                    .background(Color(white: 0.55))
            )
        }
        return [
            ("pill-recording-quiet", pill(.recording, level: 0.01)),
            ("pill-recording-loud", pill(.recording, level: 0.12)),
            ("pill-hands-free", pill(.handsFree, level: 0.06)),
            ("pill-processing", pill(.processing)),
            ("pill-message", pill(.message("Copied. Press ⌘V"))),
        ]
    }

    @MainActor
    static func write(_ view: AnyView, to url: URL) throws {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw CocoaError(.fileWriteUnknown)
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try png.write(to: url)
    }
}
