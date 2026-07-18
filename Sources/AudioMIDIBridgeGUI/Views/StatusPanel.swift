import SwiftUI
import AudioMIDIBridgeCore

struct StatusPanel: View {
    @ObservedObject var controller: AppController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Status").font(AppFont.headline)
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                Text(statusLabel).bold()
            }
            if let notice = controller.transientNotice {
                Text(notice)
                    .font(AppFont.caption)
                    .foregroundStyle(.blue)
                    .fixedSize(horizontal: false, vertical: true)
            }
            row("Tempo", controller.bpm > 0 ? String(format: "%.1f BPM", controller.bpm) : "—")
            row("Next Cycle", controller.cycleBeatsRemaining.map { "\($0) beat\($0 == 1 ? "" : "s")" } ?? "—")
            row("Play Time", formatHMS(controller.playTime))
            row("Silence Time", formatHMS(controller.silenceTime))
            row("Last MIDI", controller.lastNoteDescription)
            Group {
                Divider()
                row("Version", appVersion, font: AppFont.captionMonospaced)
                row("Config", controller.configPath, font: AppFont.captionMonospaced)
                if let err = controller.startupError {
                    Text(err)
                        .font(AppFont.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // Stalled audio takes priority over every other state — it's the one
    // condition that means MIDI has actually stopped going out, so it
    // should be impossible to miss at a glance.
    private var statusColor: Color {
        if controller.isAudioStalled { return .red }
        if controller.isPaused { return .gray }
        return controller.isSilent ? .yellow : .green
    }

    private var statusLabel: String {
        if controller.isAudioStalled { return "AUDIO STALLED" }
        if controller.isPaused { return "PAUSED" }
        return controller.isSilent ? "SILENT" : "ACTIVE"
    }

    private func row(_ label: String, _ value: String, font: Font = AppFont.bodyMonospaced) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)
            Text(value)
                .font(font)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }

    private func formatHMS(_ seconds: Double) -> String {
        let total = clampedInt(seconds, min: 0, max: 359_999)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}
