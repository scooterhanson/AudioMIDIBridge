import SwiftUI
import AppKit
import AudioMIDIBridgeCore

/// A strictly manual, on-demand action — pressing the button is the only
/// way a chart ever gets generated. There is no automatic or continuously
/// redrawing chart anywhere in the app; see AppController.generateChart().
struct ChartPanel: View {
    @ObservedObject var controller: AppController

    private var showResult: Binding<Bool> {
        Binding(
            get: { controller.chartResultPath != nil || controller.chartError != nil },
            set: { isPresented in
                if !isPresented {
                    controller.chartResultPath = nil
                    controller.chartError = nil
                }
            }
        )
    }

    var body: some View {
        Button {
            controller.generateChart()
        } label: {
            HStack {
                if controller.isGeneratingChart {
                    ProgressView().controlSize(.small)
                }
                Text(controller.isGeneratingChart ? "Generating…" : "Generate Chart…")
            }
        }
        .disabled(controller.isGeneratingChart)
        .sheet(isPresented: showResult) {
            ChartResultSheet(
                path: controller.chartResultPath,
                error: controller.chartError,
                onDismiss: { controller.chartResultPath = nil; controller.chartError = nil }
            )
        }
    }
}

private struct ChartResultSheet: View {
    let path: String?
    let error: String?
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(error == nil ? "Chart Generated" : "Chart Generation Failed")
                .font(AppFont.title3).bold()

            if let error {
                Text(error)
                    .font(AppFont.body)
                    .foregroundStyle(.red)
            } else if let path, let nsImage = NSImage(contentsOfFile: path) {
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 800, height: 450)
                }
                Text(path)
                    .font(AppFont.captionMonospaced)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            HStack {
                Spacer()
                if let path {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    }
                }
                Button("Dismiss", action: onDismiss)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
    }
}
