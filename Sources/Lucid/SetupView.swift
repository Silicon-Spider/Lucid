import AVFoundation
import LucidCore
import LucidEngines
import SwiftUI

/// The first-run checklist: what Lucid needs, and the one action that provides each thing.
struct SetupView: View {
    @ObservedObject var setup: SetupModel
    @ObservedObject var engines: EngineManager
    @ObservedObject var settings: AppSettings
    let onUseRightOption: () -> Void
    let onRestart: () -> Void
    let onDone: () -> Void

    private var enginesReady: Bool { engines.status == .ready }
    private var keyReady: Bool { setup.accessibility && setup.listening }
    private var fnReady: Bool { settings.hotkey != .fn || !setup.fnConflict }
    private var everythingReady: Bool { setup.microphone && keyReady && enginesReady && fnReady }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Set up Lucid")
                    .font(.title2.weight(.semibold))
                Text("Four things, then you can dictate into any app.")
                    .foregroundStyle(.secondary)
            }
            .padding(20)

            Divider()

            VStack(alignment: .leading, spacing: 18) {
                microphoneRow
                accessibilityRow
                enginesRow
                fnRow
            }
            .padding(20)

            Divider()

            HStack {
                Text(everythingReady ? "Ready. Hold \(settings.hotkey.title) and speak." : "Lucid will work once every item is ticked.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done", action: onDone)
            }
            .padding(20)
        }
        .frame(width: 540)
    }

    private var microphoneRow: some View {
        SetupRow(
            done: setup.microphone,
            title: "Microphone",
            detail: "So Lucid can hear you while you hold the dictation key."
        ) {
            if Permissions.microphone == .notDetermined {
                Button("Allow…") {
                    Task {
                        _ = await Permissions.requestMicrophone()
                        setup.refresh()
                    }
                }
            } else {
                Button("Open Microphone Settings…") { Permissions.openMicrophoneSettings() }
            }
        }
    }

    private var accessibilityRow: some View {
        SetupRow(
            done: keyReady,
            title: "Accessibility",
            detail: accessibilityDetail
        ) {
            if setup.accessibility {
                Button("Restart Lucid", action: onRestart)
            } else {
                Button("Open Accessibility Settings…") { Permissions.openAccessibilitySettings() }
            }
        }
    }

    private var accessibilityDetail: String {
        if keyReady { return "Lucid can see the dictation key and type the text for you." }
        if setup.accessibility {
            return "Access is granted, but macOS needs Lucid to restart before the key will work."
        }
        return "So Lucid can see the dictation key and type the text for you. Switch Lucid on in the list."
    }

    private var enginesRow: some View {
        SetupRow(done: enginesReady, title: "Speech engines and models", detail: enginesDetail) {
            if case .starting = engines.status {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var enginesDetail: String {
        switch engines.status {
        case .ready:
            return "Running on this Mac."
        case .starting:
            return "Starting. The first start can take a few seconds."
        case .setupNeeded(let missing):
            return "In Terminal, from the Lucid folder, run:  scripts/setup.sh\nThen quit and reopen Lucid. Missing: "
                + missing.joined(separator: "; ") + "."
        case .failed(let reason):
            return "The engines did not start. \(reason)"
        }
    }

    private var fnRow: some View {
        SetupRow(
            done: fnReady,
            title: "Dictation key: \(settings.hotkey.title)",
            detail: fnReady
                ? "Hold it and speak. Tap it twice for hands-free."
                : "macOS also does something when Fn is pressed. In Keyboard settings, set “Press 🌐 key to” to “Do Nothing”. Or use a different key."
        ) {
            if !fnReady {
                Button("Open Keyboard Settings…") { Permissions.openKeyboardSettings() }
                Button("Use Right Option Instead", action: onUseRightOption)
            }
        }
    }
}

/// One line of the checklist: a tick or an empty circle, what it is, and how to fix it.
private struct SetupRow<Actions: View>: View {
    let done: Bool
    let title: String
    let detail: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.title2)
                .foregroundStyle(done ? Color.green : Color.secondary)
                .accessibilityLabel(done ? "Done" : "Not done")
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !done {
                    HStack(spacing: 8) { actions() }
                }
            }
            Spacer(minLength: 0)
        }
    }
}
