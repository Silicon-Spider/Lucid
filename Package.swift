// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Lucid",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "LucidCore"),
        .executableTarget(
            name: "LucidCoreTests",
            dependencies: ["LucidCore"],
            path: "Tests/LucidCoreTests"
        ),
    ]
)
