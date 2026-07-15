import SwiftUI
import AudioMIDIBridgeCore

struct CalibratePanel: View {
    @ObservedObject var controller: AppController
    @State private var showConfirm = false

    var body: some View {
        Button {
            showConfirm = true
        } label: {
            HStack {
                if controller.isCalibrating {
                    ProgressView().controlSize(.small)
                }
                Text(controller.isCalibrating ? "Calibrating…" : "Calibrate…")
            }
        }
        .disabled(controller.isCalibrating)
        .confirmationDialog("Run calibration?", isPresented: $showConfirm, titleVisibility: .visible) {
            Button("Calibrate", role: .destructive) {
                controller.runCalibration()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("""
            This will analyze the calibration audio file:
            \(controller.liveConfig.calibration.audioFile)

            Applying the recommendations will overwrite your current threshold \
            adjustments (until you Save or Revert, this only affects the live \
            session — config.toml is untouched).
            """)
        }
        .sheet(item: $controller.calibrationOutcome) { outcome in
            CalibrationResultSheet(
                outcome: outcome,
                onApply: {
                    controller.applyCalibrationRecommendations(outcome)
                    controller.calibrationOutcome = nil
                },
                onDismiss: { controller.calibrationOutcome = nil }
            )
        }
    }
}

private struct CalibrationResultSheet: View {
    let outcome: CalibrationOutcome
    let onApply: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(outcome.errorMessage == nil ? "Calibration Complete" : "Calibration Failed")
                .font(AppFont.title3).bold()

            ScrollView {
                Text(outcome.errorMessage ?? outcome.reportText)
                    .font(AppFont.bodyMonospaced)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minWidth: 420, minHeight: 260)

            HStack {
                Spacer()
                Button("Dismiss", action: onDismiss)
                if outcome.errorMessage == nil {
                    Button("Apply Recommendations", action: onApply)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding()
    }
}
