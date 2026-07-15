import SwiftUI

/// Shown when the buffered energy level has been cycling too fast for the
/// configured levels/hysteresis to keep up with (see
/// AppController.checkForRapidCycling). Lists concrete, actionable tips and
/// can be dismissed until the next burst of rapid switching.
struct TuningRecommendationsBanner: View {
    @ObservedObject var controller: AppController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text("Tuning Recommendations")
                    .font(AppFont.subheadline).bold()
                Spacer()
                Button {
                    controller.dismissTuningRecommendations()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            ForEach(Array(controller.tuningRecommendations.enumerated()), id: \.offset) { _, tip in
                Text("• \(tip)")
                    .font(AppFont.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.yellow.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.yellow.opacity(0.4), lineWidth: 1))
    }
}
