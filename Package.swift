// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Lucid",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "LucidCore"),
        .target(name: "LucidEngines", dependencies: ["LucidCore"]),
        .executableTarget(name: "Lucid", dependencies: ["LucidCore", "LucidEngines"]),
        .executableTarget(name: "lucid-cli", dependencies: ["LucidCore", "LucidEngines"]),
        .executableTarget(
            name: "LucidCoreTests",
            dependencies: ["LucidCore", "LucidEngines"],
            path: "Tests/LucidCoreTests"
        ),
    ]
)
