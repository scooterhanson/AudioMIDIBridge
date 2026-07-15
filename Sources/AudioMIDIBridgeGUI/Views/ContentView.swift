import SwiftUI
import AudioMIDIBridgeCore

struct ContentView: View {
    @ObservedObject var controller: AppController
    @State private var selectedTab = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            metersRow

            HStack(alignment: .top, spacing: 20) {
                leftPane
                    .frame(width: 280, alignment: .leading)

                Divider()

                // Each tab's real content is only constructed while its own
                // tag is selected — `.tabItem`/`.tag` stay on the outer
                // `ScrollView` (present unconditionally) so the tab bar
                // itself never changes shape, but the expensive inner panel
                // (esp. MidiMappingPanel's ~40 text fields) isn't built,
                // diffed, or laid out at all while its tab isn't showing.
                // Without this, every `@Published` change anywhere —
                // including ones only relevant to the other tab — forced
                // SwiftUI to reconstruct and re-diff both panels every time.
                TabView(selection: $selectedTab) {
                    ScrollView {
                        if selectedTab == 0 {
                            ThresholdsPanel(controller: controller)
                                .padding(.trailing)
                        }
                    }
                    .tabItem { Text("Levels") }
                    .tag(0)

                    ScrollView {
                        if selectedTab == 1 {
                            MidiMappingPanel(controller: controller)
                                .padding(.trailing)
                        }
                    }
                    .tabItem { Text("Advanced") }
                    .tag(1)
                }
                .onChange(of: selectedTab) { tab in
                    if tab == 1 {
                        controller.pauseProcessing()
                    } else {
                        controller.resumeProcessing()
                    }
                }
            }
        }
        .padding()
        .frame(minWidth: 760, minHeight: 640)
        .font(AppFont.body)
        .background(Color.black.opacity(0.06))
    }

    /// Both meters side by side, spanning the full window width. Disabled
    /// and dimmed while listening/processing is paused (Advanced tab) since
    /// they'd otherwise just be frozen on their last live reading.
    private var metersRow: some View {
        HStack(spacing: 24) {
            MeterGaugeView(title: "Realtime", value: controller.realtimeEnergy,
                           baseline: controller.liveConfig.energy.baselineThreshold,
                           peak: controller.liveConfig.energy.peakThreshold)
            MeterGaugeView(title: "Buffered", value: controller.bufferedEnergy,
                           baseline: controller.liveConfig.energy.baselineThreshold,
                           peak: controller.liveConfig.energy.peakThreshold)
        }
        .disabled(controller.isPaused)
        .opacity(controller.isPaused ? 0.4 : 1.0)
    }

    /// Status/history up top; the tuning banner (when present) is pinned to
    /// the bottom via the Spacer above it, out of the way of the meters.
    private var leftPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(controller.currentLevelName.uppercased())
                .font(AppFont.title2).bold()

            StatusPanel(controller: controller)

            Divider()
            HistoryPanel(entries: controller.history)

            Spacer()

            if !controller.tuningRecommendations.isEmpty {
                TuningRecommendationsBanner(controller: controller)
            }
        }
    }
}
