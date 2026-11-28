import AppKit
import SwiftUI

enum PillState: Equatable {
    case hidden
    case recording
    case handsFree
    case processing
    case message(String)
}

@MainActor
final class PillModel: ObservableObject {
    @Published var state: PillState = .hidden
    /// The microphone level, where speech is roughly 0.02 to 0.2.
    @Published var level: Float = 0
    @Published var pulsing = false
    /// The last few words heard so far, shown while recording. Empty until there are some.
    @Published var preview = ""
}

/// The on-screen indicator: a small dark capsule.
struct PillView: View {
    @ObservedObject var model: PillModel

    var body: some View {
        HStack(spacing: 9) {
            content
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 15)
        .frame(height: 34)
        .background(Capsule().fill(Color.black.opacity(0.84)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
        .scaleEffect(model.pulsing ? 1.08 : 1)
        .animation(.easeOut(duration: 0.15), value: model.pulsing)
        .fixedSize()
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .hidden:
            EmptyView()
        case .recording:
            LevelBars(level: model.level)
            if !model.preview.isEmpty {
                PreviewText(text: model.preview)
            }
        case .handsFree:
            LevelBars(level: model.level)
            if model.preview.isEmpty {
                Text("Hands-free. Press the key again to finish.")
            } else {
                PreviewText(text: model.preview)
            }
        case .processing:
            ProcessingDots()
        case .message(let text):
            Text(text)
        }
    }
}

/// The last few words heard, on one line. If they are too long for the pill, the start is cut.
private struct PreviewText: View {
    let text: String

    var body: some View {
        Text(text)
            .lineLimit(1)
            .truncationMode(.head)
            .frame(maxWidth: 330)
    }
}

/// Five bars that grow with the microphone level. The middle bar is the tallest.
private struct LevelBars: View {
    let level: Float
    private let weights: [CGFloat] = [0.45, 0.75, 1.0, 0.75, 0.45]

    var body: some View {
        let strength = min(1, CGFloat(level) * 9)
        HStack(spacing: 3) {
            ForEach(weights.indices, id: \.self) { index in
                Capsule()
                    .fill(Color.white)
                    .frame(width: 3, height: 4 + 16 * strength * weights[index])
            }
        }
        .frame(height: 22)
        .animation(.linear(duration: 0.08), value: level)
    }
}

/// Three dots that brighten in turn.
private struct ProcessingDots: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { timeline in
            let step = Int(timeline.date.timeIntervalSinceReferenceDate / 0.25) % 3
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(Color.white.opacity(index == step ? 1 : 0.35))
                        .frame(width: 6, height: 6)
                }
            }
        }
        .frame(height: 22)
    }
}

/// Owns the pill's window and decides where and when it shows.
@MainActor
final class PillController {
    let model = PillModel()
    private let panel: NSPanel
    private var pendingHide: DispatchWorkItem?
    private static let size = NSSize(width: 420, height: 60)

    init() {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        // The pill must never take focus or a click, or the paste would go to the wrong place.
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(
            rootView: PillView(model: model).frame(width: Self.size.width, height: Self.size.height)
        )
    }

    func show(_ state: PillState) {
        pendingHide?.cancel()
        // Words heard belong to one recording. Hands-free carries on the same one.
        if state != .handsFree { model.preview = "" }
        model.state = state
        if state == .hidden {
            panel.orderOut(nil)
            return
        }
        position()
        panel.orderFrontRegardless()
    }

    func hide() {
        show(.hidden)
    }

    /// Shows a short message, then hides.
    func flash(_ text: String, seconds: TimeInterval = 2.2) {
        show(.message(text))
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        pendingHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// A brief bump, to acknowledge a key press that cannot be acted on yet.
    func pulse() {
        model.pulsing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.model.pulsing = false
        }
    }

    func setLevel(_ level: Float) {
        model.level = level
    }

    /// Shows the last few words heard so far, beside the level bars.
    func setPreview(_ text: String) {
        model.preview = text
    }

    /// Bottom centre of the screen that holds the mouse pointer, clear of the Dock.
    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: visible.midX - Self.size.width / 2, y: visible.minY + 24))
    }
}
