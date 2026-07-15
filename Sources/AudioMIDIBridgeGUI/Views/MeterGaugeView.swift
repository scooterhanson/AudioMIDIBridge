import SwiftUI

/// A horizontal level-meter bar: fills left-to-right proportional to
/// `value`, colored green/yellow/red by the `baseline`/`peak` zones, with
/// thin markers at the baseline/peak threshold positions for reference.
struct MeterGaugeView: View {
    let title: String
    let value: Double        // 0...1
    let baseline: Double     // 0...1
    let peak: Double         // 0...1

    private var clamped: Double { min(1.0, max(0.0, value)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(AppFont.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.3f", value))
                    .font(AppFont.captionMonospaced)
                    .foregroundStyle(zoneColor(for: clamped))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.secondary.opacity(0.15))
                    RoundedRectangle(cornerRadius: 5)
                        .fill(zoneColor(for: clamped))
                        .frame(width: max(0, geo.size.width * clamped))
                    thresholdMark(at: baseline, width: geo.size.width)
                    thresholdMark(at: peak, width: geo.size.width)
                }
            }
            .frame(height: 20)
        }
        .frame(maxWidth: .infinity)
    }

    private func zoneColor(for v: Double) -> Color {
        if v >= peak { return .red }
        if v >= baseline { return .yellow }
        return .green
    }

    private func thresholdMark(at fraction: Double, width: Double) -> some View {
        let clampedFraction = min(1, max(0, fraction))
        return Rectangle()
            .fill(Color.primary.opacity(0.45))
            .frame(width: 1.5)
            .offset(x: width * clampedFraction - 0.75)
    }
}
