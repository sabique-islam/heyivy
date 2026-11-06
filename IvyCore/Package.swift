// swift-tools-version: 6.0
import PackageDescription

// IvyCore holds the app's logic that needs no UI and no macOS permissions, so it can be
// tested with `swift test`. VoiceSyncLab is a developer tool that exercises it against
// real audio, and isn't part of the app.
let package = Package(
    name: "IvyCore",
    platforms: [.macOS("14.2")],
    products: [
        .library(name: "IvyCore", targets: ["IvyCore"]),
        .executable(name: "voice-sync-lab", targets: ["VoiceSyncLab"]),
    ],
    targets: [
        .target(name: "IvyCore"),
        .executableTarget(
            name: "VoiceSyncLab",
            dependencies: ["IvyCore"],
            // AVFoundation and AppKit callbacks don't fit Swift 6's checks yet, and this
            // is a test tool, so it uses the Swift 5 language mode.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "IvyCoreTests", dependencies: ["IvyCore"]),
    ]
)
