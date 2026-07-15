import SwiftUI
import AudioMIDIBridgeCore

struct ThresholdsPanel: View {
    @ObservedObject var controller: AppController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            coreThresholdsSection
            energyLevelsSection
            energySmoothingSection
            tempoSection
            crossfadeSection
            if !controller.liveConfig.bandTriggers.bands.isEmpty {
                bandTriggersSection
            }
            footer
        }
    }

    private var header: some View {
        HStack {
            Text("Thresholds").font(AppFont.headline)
            Spacer()
            if controller.hasUnsavedChanges {
                Text("Unsaved changes").font(AppFont.caption).foregroundStyle(.orange)
            }
        }
    }

    private var coreThresholdsSection: some View {
        Group {
            sliderRow(title: "Silence", value: controller.liveConfig.audio.silenceThreshold, range: 0...0.1) {
                controller.setSilenceThreshold($0)
            }
            sliderRow(title: "Baseline", value: controller.liveConfig.energy.baselineThreshold, range: 0...0.5) {
                controller.setBaselineThreshold($0)
            }
            sliderRow(title: "Peak", value: controller.liveConfig.energy.peakThreshold, range: 0...1.0) {
                controller.setPeakThreshold($0)
            }
        }
    }

    private var energyLevelsSection: some View {
        Group {
            Divider()
            Text("Energy Levels").font(AppFont.subheadline).foregroundStyle(.secondary)
            Text("Each level's upper bound is the next level's threshold — Silent is implicit below Low, and Very High has no upper bound. The slider for whichever level is currently playing pulses red on the beat.")
                .font(AppFont.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(controller.liveConfig.energy.levels.enumerated()), id: \.offset) { index, level in
                if index > 0 {
                    PulsingThresholdSliderRow(
                        title: level.name.replacingOccurrences(of: "_", with: " ").capitalized,
                        value: level.minRMS,
                        range: 0...1.0,
                        isActive: controller.currentLevelName.lowercased() == level.name.lowercased(),
                        pulseIntensity: controller.pulseIntensity,
                        onChange: { controller.setLevelThreshold(index: index, value: $0) }
                    )
                }
            }
        }
    }

    private var energySmoothingSection: some View {
        Group {
            Divider()
            Text("Energy Smoothing").font(AppFont.subheadline).foregroundStyle(.secondary)
            sliderRow(title: "Hysteresis", value: controller.liveConfig.energy.hysteresis, range: 0...0.1) {
                controller.setHysteresis($0)
            }
            intSliderRow(title: "Attack (frames)", value: controller.liveConfig.energy.attackFrames, range: 1...30) {
                controller.setAttackFrames($0)
            }
            intSliderRow(title: "Release (frames)", value: controller.liveConfig.energy.releaseFrames, range: 1...120) {
                controller.setReleaseFrames($0)
            }
            intSliderRow(title: "Buffer Duration (ms)", value: controller.liveConfig.energy.bufferDurationMs, range: 100...3000) {
                controller.setBufferDurationMs($0)
            }
        }
    }

    private var tempoSection: some View {
        Group {
            Divider()
            Text("Tempo").font(AppFont.subheadline).foregroundStyle(.secondary)
            intSliderRow(title: "Hit History", value: controller.liveConfig.tempo.bpmSmoothingBeats, range: 1...32) {
                controller.setBpmSmoothingBeats($0)
            }
            sliderRow(title: "Onset Sensitivity", value: controller.liveConfig.tempo.onsetSensitivity, range: 0...1.0) {
                controller.setOnsetSensitivity($0)
            }
        }
    }

    private var crossfadeSection: some View {
        Group {
            Divider()
            Text("Crossfade").font(AppFont.subheadline).foregroundStyle(.secondary)
            intSliderRow(title: "Default (beats)", value: controller.liveConfig.crossfade.defaultBeats, range: 1...32) {
                controller.setCrossfadeDefaultBeats($0)
            }
        }
    }

    private var bandTriggersSection: some View {
        Group {
            Divider()
            HStack {
                Text("Band Triggers").font(AppFont.subheadline).foregroundStyle(.secondary)
                Spacer()
                Toggle("Enabled", isOn: Binding(
                    get: { controller.liveConfig.bandTriggers.enabled },
                    set: { controller.setBandTriggersEnabled($0) }
                ))
                .toggleStyle(.switch)
                .font(AppFont.caption)
            }
            ForEach(Array(controller.liveConfig.bandTriggers.bands.enumerated()), id: \.offset) { index, band in
                sliderRow(title: band.name.capitalized, value: band.threshold, range: 0...1.0) {
                    controller.setBandTriggerThreshold(index: index, value: $0)
                }
                .disabled(!controller.liveConfig.bandTriggers.enabled)
                .opacity(controller.liveConfig.bandTriggers.enabled ? 1.0 : 0.4)
            }
        }
    }

    private var footer: some View {
        Group {
            Divider()
            HStack {
                Button("Revert") { controller.revert() }
                    .disabled(!controller.hasUnsavedChanges)
                Button("Save") { controller.save() }
                    .disabled(!controller.hasUnsavedChanges)
                    .keyboardShortcut("s", modifiers: .command)
                Spacer()
                CalibratePanel(controller: controller)
            }
        }
    }
}
