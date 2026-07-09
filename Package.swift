// swift-tools-version:5.6
import PackageDescription

let package = Package(
    name: "AudioMIDIBridge",
    platforms: [
        .macOS(.v12)    // Monterey
    ],
    targets: [
        .executableTarget(
            name: "AudioMIDIBridge",
            path: "Sources/AudioMIDIBridge",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMIDI"),
                .linkedFramework("QuartzCore")
            ]
        )
    ]
)
