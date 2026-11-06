// swift-tools-version: 6.0
import PackageDescription

// IvyCore holds the app's logic that needs no UI and no macOS permissions, so it can be
// tested with `swift test`. IvyOverlay draws marks. The two labs are developer tools that
// exercise them against real audio and real screens, and aren't part of the app.
let package = Package(
    name: "IvyCore",
    platforms: [.macOS("14.2")],
    products: [
        .library(name: "IvyCore", targets: ["IvyCore"]),
        .library(name: "IvyOverlay", targets: ["IvyOverlay"]),
        .executable(name: "voice-sync-lab", targets: ["VoiceSyncLab"]),
        .executable(name: "mark-overlay-lab", targets: ["MarkOverlayLab"]),
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
        // Draws marks on screen. Kept apart from IvyCore, which stays free of UI.
        .target(
            name: "IvyOverlay",
            dependencies: ["IvyCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "MarkOverlayLab",
            dependencies: ["IvyCore", "IvyOverlay"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "IvyCoreTests", dependencies: ["IvyCore"]),
        .testTarget(name: "IvyOverlayTests", dependencies: ["IvyOverlay", "IvyCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
