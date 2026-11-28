// swift-tools-version: 5.9
import PackageDescription

// The dictation pipeline, the engines, the command-line tool and the tests build on macOS,
// Windows and Linux.
var targets: [Target] = [
    .target(name: "LucidCore"),
    .target(name: "LucidEngines", dependencies: ["LucidCore"]),
    // The app without a screen: dictation, settings, models, and the local page that is its window.
    .target(name: "LucidApp", dependencies: ["LucidCore", "LucidEngines"]),
    .executableTarget(name: "lucid-cli", dependencies: ["LucidCore", "LucidEngines", "LucidApp"]),
    .executableTarget(
        name: "LucidCoreTests",
        dependencies: ["LucidCore", "LucidEngines", "LucidApp"],
        path: "Tests/LucidCoreTests"
    ),
]

// The menu-bar app is built on AppKit and SwiftUI, which exist only on a Mac.
#if os(macOS)
targets.append(.executableTarget(name: "Lucid", dependencies: ["LucidCore", "LucidEngines"]))
#else

// The Windows app: the tray icon, the dictation key, the microphone, the pill and typing are
// a layer of C over Windows itself, and the app on top of it is Swift.
//
// Setting LUCID_WINDOWS_SHELL lets another system check that Swift:
//     LUCID_WINDOWS_SHELL=1 swift build --target Lucid
// The C compiles to nothing there, so it cannot be linked or run.
#if os(Windows)
let buildsWindowsApp = true
#else
let buildsWindowsApp = Context.environment["LUCID_WINDOWS_SHELL"] != nil
#endif
if buildsWindowsApp {
    targets.append(.target(
        name: "CLucidWin",
        linkerSettings: ["user32", "gdi32", "shell32", "winmm", "comdlg32", "advapi32", "version"].map {
            .linkedLibrary($0, .when(platforms: [.windows]))
        }
    ))
    targets.append(.executableTarget(
        name: "Lucid",
        dependencies: ["LucidCore", "LucidEngines", "LucidApp", "CLucidWin"],
        path: "Sources/LucidWindows",
        linkerSettings: [
            // An app, not a console program: without this, Windows opens a black console
            // window beside it.
            .unsafeFlags(
                ["-Xlinker", "/SUBSYSTEM:WINDOWS", "-Xlinker", "/ENTRY:mainCRTStartup"],
                .when(platforms: [.windows])
            ),
        ]
    ))
}
#endif

let package = Package(
    name: "Lucid",
    platforms: [.macOS(.v14)],
    targets: targets
)
