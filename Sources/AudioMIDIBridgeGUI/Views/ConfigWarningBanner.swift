import SwiftUI

/// Shown when config.toml had a value ConfigValidator had to replace with a
/// safe default at load (e.g. an invalid sample_rate/fft_size) — the kind
/// of thing that would otherwise crash AudioEngine at launch. Dismissible;
/// reappears on the next load/revert if the underlying config.toml is still
/// invalid.
struct ConfigWarningBanner: View {
    @ObservedObject var controller: AppController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Config Values Auto-Corrected")
                    .font(AppFont.subheadline).bold()
                Spacer()
                Button {
                    controller.dismissConfigWarnings()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            ForEach(Array(controller.configWarnings.enumerated()), id: \.offset) { _, warning in
                Text("• \(warning)")
                    .font(AppFont.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.4), lineWidth: 1))
    }
}
