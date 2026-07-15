import SwiftUI
import AudioMIDIBridgeCore

/// The "Advanced" tab: MIDI notes and channels for energy levels, tempo
/// tap, band triggers, peak & trough, and the crossfade CC number/channel —
/// every one of these is a bounded, enumerable choice, so each is a dropdown
/// rather than free text. Everything else lives exactly once, as a slider on
/// the Levels tab (min_rms) or nowhere at all (every note now sends a fixed
/// velocity of 100 — see `defaultNoteVelocity` — so there's no velocity
/// field left to edit here).
struct MidiMappingPanel: View {
    @ObservedObject var controller: AppController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Advanced").font(AppFont.headline)
            energyLevelsSection
            tempoTapSection
            peakTroughSection
            if !controller.liveConfig.bandTriggers.bands.isEmpty {
                bandTriggersSection
            }
            crossfadeSection
            footer
        }
    }

    private var energyLevelsSection: some View {
        Group {
            Divider()
            Text("Energy Levels").font(AppFont.subheadline).foregroundStyle(.secondary)
            ForEach(Array(controller.liveConfig.energy.levels.enumerated()), id: \.offset) { index, level in
                EnergyLevelMappingRow(controller: controller, index: index, level: level)
            }
        }
    }

    private var tempoTapSection: some View {
        Group {
            Divider()
            Text("Tempo Tap").font(AppFont.subheadline).foregroundStyle(.secondary)
            pickerRow(title: "Note", value: controller.liveConfig.tempo.tapNote, options: PickerOptions.midiNotes) {
                controller.setTapNote($0)
            }
            pickerRow(title: "Channel", value: controller.liveConfig.tempo.tapChannel, options: PickerOptions.midiChannels) {
                controller.setTapChannel($0)
            }
        }
    }

    private var peakTroughSection: some View {
        Group {
            Divider()
            Text("Peak / Trough").font(AppFont.subheadline).foregroundStyle(.secondary)
            peakFields
            troughFields
        }
    }

    private var peakFields: some View {
        Group {
            Text("Peak").font(AppFont.caption).bold()
            pickerRow(title: "Note", value: controller.liveConfig.energy.peakNote,
                      options: PickerOptions.optionalMidiNotes, label: PickerOptions.noteLabel) {
                controller.setPeakNote($0)
            }
            pickerRow(title: "Channel", value: controller.liveConfig.energy.peakChannel, options: PickerOptions.midiChannels) {
                controller.setPeakChannel($0)
            }
        }
    }

    private var troughFields: some View {
        Group {
            Text("Trough").font(AppFont.caption).bold()
            pickerRow(title: "Note", value: controller.liveConfig.energy.troughNote,
                      options: PickerOptions.optionalMidiNotes, label: PickerOptions.noteLabel) {
                controller.setTroughNote($0)
            }
            pickerRow(title: "Channel", value: controller.liveConfig.energy.troughChannel, options: PickerOptions.midiChannels) {
                controller.setTroughChannel($0)
            }
        }
    }

    private var bandTriggersSection: some View {
        Group {
            Divider()
            Text("Band Triggers").font(AppFont.subheadline).foregroundStyle(.secondary)
            ForEach(Array(controller.liveConfig.bandTriggers.bands.enumerated()), id: \.offset) { index, band in
                BandTriggerMappingRow(controller: controller, index: index, band: band)
            }
        }
    }

    private var crossfadeSection: some View {
        Group {
            Divider()
            Text("Crossfade").font(AppFont.subheadline).foregroundStyle(.secondary)
            pickerRow(title: "CC Number", value: controller.liveConfig.crossfade.ccNumber, options: PickerOptions.ccNumbers) {
                controller.setCrossfadeCcNumber($0)
            }
            pickerRow(title: "Channel", value: controller.liveConfig.crossfade.channel, options: PickerOptions.midiChannels) {
                controller.setCrossfadeChannel($0)
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
            }
        }
    }
}

private struct EnergyLevelMappingRow: View {
    @ObservedObject var controller: AppController
    let index: Int
    let level: EnergyLevel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(level.name.replacingOccurrences(of: "_", with: " ").capitalized)
                .font(AppFont.caption).bold()
            ForEach(Array(level.midiNotes.enumerated()), id: \.offset) { noteIndex, note in
                pickerRow(title: "Note \(noteIndex + 1)", value: note, options: PickerOptions.midiNotes) {
                    controller.setLevelNote(index: index, noteIndex: noteIndex, note: $0)
                }
            }
            pickerRow(title: "Channel", value: level.channel, options: PickerOptions.midiChannels) {
                controller.setLevelChannel(index: index, channel: $0)
            }
        }
    }
}

private struct BandTriggerMappingRow: View {
    @ObservedObject var controller: AppController
    let index: Int
    let band: BandTrigger

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(band.name.capitalized).font(AppFont.caption).bold()
            pickerRow(title: "Note", value: band.midiNote, options: PickerOptions.midiNotes) {
                controller.setBandTriggerMidiNote(index: index, note: $0)
            }
            pickerRow(title: "Channel", value: band.channel, options: PickerOptions.midiChannels) {
                controller.setBandTriggerChannel(index: index, channel: $0)
            }
        }
    }
}
