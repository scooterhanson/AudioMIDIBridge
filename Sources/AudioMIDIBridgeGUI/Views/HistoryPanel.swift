import SwiftUI

struct HistoryPanel: View {
    let entries: [LevelHistoryEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent Energy Levels").font(AppFont.headline)
            if entries.isEmpty {
                Text("No level changes yet").font(AppFont.caption).foregroundStyle(.secondary)
            } else {
                ForEach(entries) { entry in
                    HStack {
                        Text(entry.levelName.capitalized)
                            .frame(width: 90, alignment: .leading)
                        Text("note \(entry.midiNote)")
                            .font(AppFont.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 70, alignment: .leading)
                        Spacer()
                        Text(formatDuration(entry.duration))
                            .font(AppFont.captionMonospaced)
                    }
                }
            }
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let s = Int(max(0, seconds.rounded()))
        if s >= 60 { return String(format: "%dm %02ds", s / 60, s % 60) }
        return String(format: "%ds", s)
    }
}
