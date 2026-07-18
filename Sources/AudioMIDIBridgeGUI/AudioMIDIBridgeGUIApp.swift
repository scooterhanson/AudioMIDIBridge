import SwiftUI
import AppKit
import AudioMIDIBridgeCore

/// Ensures the audio engine stops and any lingering MIDI note (e.g. the
/// silence indicator) is turned off on quit — mirrors the CLI's SIGINT
/// handler, since a plain `.onDisappear` isn't reliably called on Cmd-Q.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: AppController?

    func applicationWillTerminate(_ notification: Notification) {
        controller?.stop()
    }
}

@main
struct AudioMIDIBridgeGUIApp: App {
    @StateObject private var controller = AppController()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("AudioMIDIBridge \(appVersion)") {
            ContentView(controller: controller)
                .onAppear {
                    appDelegate.controller = controller
                    controller.start()
                }
        }
    }
}
