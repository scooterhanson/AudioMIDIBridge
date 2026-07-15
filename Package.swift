// swift-tools-version:5.6
import PackageDescription

let package = Package(
    name: "AudioMIDIBridge",
    platforms: [
        .macOS(.v12)    // Monterey
    ],
    targets: [
        .target(
            name: "AudioMIDIBridgeCore",
            path: "Sources/AudioMIDIBridgeCore",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMIDI"),
                .linkedFramework("QuartzCore")
            ]
        ),
        .executableTarget(
            name: "AudioMIDIBridge",
            dependencies: ["AudioMIDIBridgeCore"],
            path: "Sources/AudioMIDIBridge",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMIDI"),
                .linkedFramework("QuartzCore")
            ]
        ),
        .executableTarget(
            name: "AudioMIDIBridgeGUI",
            dependencies: ["AudioMIDIBridgeCore"],
            path: "Sources/AudioMIDIBridgeGUI",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMIDI"),
                .linkedFramework("QuartzCore")
            ]
        )
    ]
)
