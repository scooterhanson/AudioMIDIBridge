import Foundation

/// Single source of truth for the app's version (MAJOR.MINOR). Bumped on
/// each release build: increment MINOR unless explicitly told to bump
/// MAJOR (which resets MINOR to 0). Not tied to any build-time codegen —
/// when cutting a release (e.g. building the DMG), update this value and
/// keep dist/AudioMIDIBridgeGUI.app/Contents/Info.plist's
/// CFBundleShortVersionString/CFBundleVersion in sync with it by hand.
public let appVersion = "1.0"
