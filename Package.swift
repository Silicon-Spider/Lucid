// swift-tools-version: 5.9
import PackageDescription

// The dictation pipeline, the engines, the command-line tool and the tests build on macOS,
// Windows and Linux.
var targets: [Target] = [
    .target(name: "LucidCore"),
    .target(name: "LucidEngines", dependencies: ["LucidCore"]),
    .executableTarget(name: "lucid-cli", dependencies: ["LucidCore", "LucidEngines"]),
    .executableTarget(
        name: "LucidCoreTests",
        dependencies: ["LucidCore", "LucidEngines"],
        path: "Tests/LucidCoreTests"
    ),
]

// The menu-bar app is built on AppKit and SwiftUI, which exist only on a Mac.
#if os(macOS)
targets.append(.executableTarget(name: "Lucid", dependencies: ["LucidCore", "LucidEngines"]))
#endif

let package = Package(
    name: "Lucid",
    platforms: [.macOS(.v14)],
    targets: targets
)
