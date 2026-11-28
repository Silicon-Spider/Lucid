import LucidCore
import LucidEngines
import SwiftUI

/// The parts of Lucid's window, listed down its left side.
enum MainSection: String, CaseIterable, Identifiable {
    case home, models, dictionary, history, settings, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .models: return "Models"
        case .dictionary: return "Dictionary"
        case .history: return "History"
        case .settings: return "Settings"
        case .about: return "About"
        }
    }

    var icon: String {
        switch self {
        case .home: return "house"
        case .models: return "cpu"
        case .dictionary: return "character.book.closed"
        case .history: return "clock.arrow.circlepath"
        case .settings: return "gearshape"
        case .about: return "info.circle"
        }
    }
}

/// Which part of the window is showing. The app sets it to open the window at a given part.
@MainActor
final class MainWindowModel: ObservableObject {
    @Published var section: MainSection = .home
}

/// What the window asks the app to do when the user changes something.
struct MainActions {
    var onHotkey: (HotkeyChoice) -> Void = { _ in }
    var onLevel: (CleanupLevel) -> Void = { _ in }
    var onModels: (ModelChoices) -> Void = { _ in }
    var onRetry: (HistoryEntry) -> Void = { _ in }
    var onUseRightOption: () -> Void = {}
    var onRestart: () -> Void = {}
}

/// How big Lucid's window is.
enum MainWindowSize {
    /// Small enough for a 13-inch screen, and wide enough for the Models page.
    static let minimum = CGSize(width: 820, height: 560)
    /// The size the window opens at the first time.
    static let starting = CGSize(width: 920, height: 660)
}

/// Lucid's window: everything the app can do in one place, a part at a time.
struct MainView: View {
    @ObservedObject var window: MainWindowModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var engines: EngineManager
    @ObservedObject var setup: SetupModel
    @ObservedObject var models: ModelLibraryModel
    @ObservedObject var dictionary: DictionaryModel
    @ObservedObject var history: HistoryModel
    let actions: MainActions

    /// The list wants an optional selection. Clicking empty space must not leave no part showing.
    private var selection: Binding<MainSection?> {
        Binding(
            get: { window.section },
            set: { section in
                if let section { window.section = section }
            }
        )
    }

    private var ready: Bool {
        setup.microphone && setup.accessibility && setup.listening && engines.status == .ready
    }

    private var statusText: String {
        if ready { return "Ready" }
        if engines.status == .starting { return "Starting…" }
        return "Needs setup"
    }

    private var statusColor: Color {
        if ready { return Color.green }
        if engines.status == .starting { return Color.gray }
        return Color.orange
    }

    private var sidebar: some View {
        List(MainSection.allCases, id: \.self, selection: selection) { section in
            Label(section.title, systemImage: section.icon)
        }
        .listStyle(.sidebar)
        // Inside the list's own area, so the status sits on the sidebar's background.
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 7) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .accessibilityElement(children: .combine)
        }
        .frame(width: 190)
    }

    @ViewBuilder
    private var detail: some View {
        switch window.section {
        case .home:
            HomeView(
                settings: settings,
                engines: engines,
                setup: setup,
                models: models,
                history: history,
                onUseRightOption: actions.onUseRightOption,
                onRestart: actions.onRestart,
                onOpen: { section in window.section = section }
            )
        case .models:
            ModelsTab(settings: settings, engines: engines, library: models, onModels: actions.onModels)
        case .dictionary:
            DictionaryTab(model: dictionary)
        case .history:
            HistoryTab(model: history, onRetry: actions.onRetry)
        case .settings:
            GeneralTab(settings: settings, engines: engines, onHotkey: actions.onHotkey, onLevel: actions.onLevel)
        case .about:
            AboutTab()
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: MainWindowSize.minimum.width, minHeight: MainWindowSize.minimum.height)
    }
}
