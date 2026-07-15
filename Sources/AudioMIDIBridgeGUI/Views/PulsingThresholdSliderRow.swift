import SwiftUI

/// A labeled threshold slider whose handle glows red while `isActive` (the
/// buffered energy level currently sitting at/above this threshold),
/// brightening in a pulse on each beat via `pulseIntensity`.
///
/// Deliberately stateless: the tint is a pure function of `isActive` and
/// `pulseIntensity`, both passed in fresh on every render. There is no
/// local @State and no onChange-triggered reset here — a previous version
/// tracked its own pulse animation locally and relied on an `onChange(of:
/// isActive)` handler to snap it back to default when the level changed,
/// which could (and did) end up stuck red if that handler's timing ever
/// raced a level change. Being a pure function of always-current inputs
/// means there is nothing to get stuck: an inactive row can never render
/// red, full stop, regardless of animation timing.
struct PulsingThresholdSliderRow: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let isActive: Bool
    let pulseIntensity: Double
    let onChange: (Double) -> Void

    private var tintColor: Color? {
        guard isActive else { return nil }
        return Color.red.opacity(0.5 + 0.5 * pulseIntensity)
    }

    var body: some View {
        HStack {
            Text(title)
                .frame(width: 130, alignment: .leading)
                .font(AppFont.caption)
            Slider(value: Binding(get: { value }, set: onChange), in: range)
                .tint(tintColor)
            Text(String(format: "%.4f", value))
                .font(AppFont.captionMonospaced)
                .frame(width: 60, alignment: .trailing)
        }
    }
}
