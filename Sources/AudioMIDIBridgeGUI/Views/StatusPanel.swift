import SwiftUI
import AudioMIDIBridgeCore

struct StatusPanel: View {
    @ObservedObject var controller: AppController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Status").font(AppFont.headline)
            HStack {
                Circle()
                    .fill(controller.isPaused ? Color.gray : (controller.isSilent ? Color.yellow : Color.green))
                    .frame(width: 10, height: 10)
                Text(controller.isPaused ? "PAUSED" : (controller.isSilent ? "SILENT" : "ACTIVE")).bold()
            }
            row("Tempo", controller.bpm > 0 ? String(format: "%.1f BPM", controller.bpm) : "—")
            row("Next Cycle", controller.cycleBeatsRemaining.map { "\($0) beat\($0 == 1 ? "" : "s")" } ?? "—")
            row("Play Time", formatHMS(controller.playTime))
            row("Silence Time", formatHMS(controller.silenceTime))
            row("Last MIDI", controller.lastNoteDescription)
            Group {
                Divider()
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
