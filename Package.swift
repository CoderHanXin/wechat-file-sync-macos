// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WeChatFileSync",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "SyncCore", path: "Sources/Core", linkerSettings: [.linkedLibrary("sqlite3")]),
        .testTarget(name: "SyncCoreTests", dependencies: ["SyncCore"], path: "Tests/SyncCoreTests")
    ]
)
