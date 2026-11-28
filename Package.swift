// swift-tools-version: 5.9
import Foundation
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

// The app for Windows and for Linux. What each desktop provides (the tray icon, the dictation
// key, the microphone, the pill and typing) is a layer of C, CLucidDesk, with a half for
// each system. The app on top of it, in Sources/LucidDesktop, is the same Swift for both.
var desktopLayer: Target?

#if os(Windows)
desktopLayer = .target(
    name: "CLucidDesk",
    linkerSettings: ["user32", "gdi32", "shell32", "winmm", "comdlg32", "advapi32", "version"].map { .linkedLibrary($0) }
)
#elseif os(Linux)
// The Linux half is built on GTK, which a computer without a desktop does not have. There,
// only lucid-cli and the tests are built. scripts/setup-linux.sh installs what is needed.
// LUCID_LINUX_APP=0 leaves the app out, and LUCID_LINUX_APP=1 insists on it.
let gtkHeaders = [
    "/usr/include/gtk-3.0/gtk/gtk.h",
    "/usr/include/libayatana-appindicator3-0.1/libayatana-appindicator/app-indicator.h",
    "/usr/include/X11/extensions/XInput2.h",
    "/usr/include/X11/extensions/XTest.h",
]
let wanted = Context.environment["LUCID_LINUX_APP"]
if wanted == "1" || (wanted != "0" && gtkHeaders.allSatisfy { FileManager.default.fileExists(atPath: $0) }) {
    targets.append(.systemLibrary(
        name: "CLucidGtk",
        pkgConfig: "ayatana-appindicator3-0.1",
        providers: [
            .apt(["libgtk-3-dev", "libayatana-appindicator3-dev", "libxi-dev", "libxtst-dev"]),
            .yum(["gtk3-devel", "libayatana-appindicator-gtk3-devel", "libXi-devel", "libXtst-devel"]),
        ]
    ))
    desktopLayer = .target(
        name: "CLucidDesk",
        dependencies: ["CLucidGtk"],
        linkerSettings: ["X11", "Xi", "Xtst", "m"].map { .linkedLibrary($0) }
    )
}
#endif

if let desktopLayer {
    targets.append(desktopLayer)
    var linking: [LinkerSetting] = []
    #if os(Windows)
    // An app, not a console program: without this, Windows opens a black console window
    // beside it.
    linking.append(.unsafeFlags(["-Xlinker", "/SUBSYSTEM:WINDOWS", "-Xlinker", "/ENTRY:mainCRTStartup"]))
    #endif
    targets.append(.executableTarget(
        name: "Lucid",
        dependencies: ["LucidCore", "LucidEngines", "LucidApp", "CLucidDesk"],
        path: "Sources/LucidDesktop",
        linkerSettings: linking
    ))
}
#endif

let package = Package(
    name: "Lucid",
    platforms: [.macOS(.v14)],
    targets: targets
)
