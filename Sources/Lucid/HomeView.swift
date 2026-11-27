import AVFoundation
import LucidCore
import LucidEngines
import SwiftUI

/// The first part of Lucid's window: whether it is ready, what it still needs, which models
/// and settings are in use, and the latest dictation.
struct HomeView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var engines: EngineManager
    @ObservedObject var setup: SetupModel
    @ObservedObject var models: ModelLibraryModel
    @ObservedObject var history: HistoryModel
    let onUseRightOption: () -> Void
    let onRestart: () -> Void
    /// Shows another part of the window.
    let onOpen: (MainSection) -> Void

    private var enginesReady: Bool { engines.status == .ready }
    private var keyReady: Bool { setup.accessibility && setup.listening }
    private var fnReady: Bool { settings.hotkey != .fn || !setup.fnConflict }
    private var everythingReady: Bool { setup.microphone && keyReady && enginesReady && fnReady }

    /// The cleanup level in one word, and the model that does it.
    private var cleanupSummary: String {
        let level = settings.level.rawValue.capitalized
        guard settings.level != .off else { return level }
        let plan = models.plan(for: settings.models)
        return level + ", with " + models.displayName(of: plan.cleanup(for: settings.level).fileName)
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: everythingReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(everythingReady ? Color.green : Color.orange)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(everythingReady ? "Lucid is ready" : "Lucid needs a few things first")
                            .font(.title2.weight(.semibold))
                        Text(
                            everythingReady
                                ? "Hold \(settings.hotkey.title) and speak, then let go. Tap it twice to keep recording hands-free."
                                : "It will work once every item under Setup is ticked."
                        )
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Setup") {
                microphoneRow
                accessibilityRow
                enginesRow
                fnRow
            }

            Section("In use") {
                SummaryRow(label: "Dictation key", value: settings.hotkey.title) { onOpen(.settings) }
                SummaryRow(label: "Cleanup", value: cleanupSummary) { onOpen(.settings) }
                SummaryRow(
                    label: "Speech model",
                    value: models.displayName(of: models.plan(for: settings.models).speech)
                ) { onOpen(.models) }
            }

            Section("Latest dictation") {
                latestDictation
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var latestDictation: some View {
        if let entry = history.entries.first {
            if let result = entry.result {
                Text(result.finalText)
                    .textSelection(.enabled)
                HStack(spacing: 14) {
                    Button("Copy") { TextInserter.copy(result.finalText) }
                    Button("Copy Original") { TextInserter.copy(result.raw) }
                    Spacer()
                    Button("Show History") { onOpen(.history) }
                }
                .buttonStyle(.borderless)
                .font(.callout)
            } else {
                Text("The latest dictation failed. \(entry.failure ?? "")")
                    .foregroundStyle(.orange)
                Button("Show History") { onOpen(.history) }
                    .buttonStyle(.borderless)
                    .font(.callout)
            }
        } else {
            Text("Nothing yet. Hold \(settings.hotkey.title) and speak.")
                .foregroundStyle(.secondary)
        }
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

    /// Missing model files that Lucid can download for itself.
    private var downloadable: [String] {
        engines.missingModelFiles.filter { ModelCatalog.suggestion(for: $0) != nil }
    }

    /// The downloads of missing models that are under way.
    private var downloads: [ModelLibraryModel.Download] {
        engines.missingModelFiles.compactMap { models.downloads[$0] }
    }

    private static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private var downloadSize: String {
        Self.size(downloadable.compactMap { ModelCatalog.suggestion(for: $0)?.remote.bytes }.reduce(0, +))
    }

    private var downloadFraction: Double? {
        let total = downloads.compactMap(\.total).reduce(0, +)
        guard total > 0 else { return nil }
        return min(1, Double(downloads.map(\.received).reduce(0, +)) / Double(total))
    }

    private var enginesRow: some View {
        SetupRow(done: enginesReady, title: "Speech engines and models", detail: enginesDetail) {
            if case .starting = engines.status {
                ProgressView().controlSize(.small)
            } else if !downloads.isEmpty {
                ProgressView(value: downloadFraction)
                    .frame(width: 180)
                Button("Stop") {
                    for download in downloads { models.cancelDownload(download.remote.fileName) }
                }
            } else if !downloadable.isEmpty {
                Button("Download Models (\(downloadSize))") { models.downloadSuggested(downloadable) }
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
            var detail: String
            if !downloads.isEmpty {
                let received = downloads.map(\.received).reduce(0, +)
                let total = downloads.compactMap(\.total).reduce(0, +)
                detail = "Downloading the models from Hugging Face: \(Self.size(received)) of \(Self.size(total))."
            } else if engines.enginesMissing {
                detail = "In Terminal, from the Lucid folder, run:  scripts/setup.sh\nThen quit and reopen Lucid. Missing: "
                    + missing.joined(separator: "; ") + "."
            } else {
                detail = "Lucid needs its speech and cleanup models, downloaded once from Hugging Face. Missing: "
                    + missing.joined(separator: "; ") + "."
            }
            if let notice = models.notice, notice.isProblem { detail += "\n" + notice.text }
            return detail
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

/// One setting on the Home page: what it is, its value, and a button that goes to where it is changed.
private struct SummaryRow: View {
    let label: String
    let value: String
    let onChange: () -> Void

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Button("Change…", action: onChange)
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
