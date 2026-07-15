import SwiftUI

/// A labeled dropdown for choosing an Int from a fixed set of options —
/// every remaining field on the Advanced tab (MIDI note, channel, CC number)
/// is one of these bounded, enumerable choices rather than free-form text,
/// so a picker is both a more honest UI (you can't type an invalid value)
/// and structurally immune to the free-text-entry bugs a `TextField` had
/// here.
func pickerRow(title: String, value: Int, options: [Int],
                label: @escaping (Int) -> String = { String($0) },
                onChange: @escaping (Int) -> Void) -> some View {
    HStack {
        Text(title)
            .frame(width: 130, alignment: .leading)
            .font(AppFont.caption)
        Picker("", selection: Binding(get: { value }, set: onChange)) {
            ForEach(options, id: \.self) { option in
                Text(label(option)).tag(option)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(maxWidth: 160)
    }
}

enum PickerOptions {
    static let midiNotes = Array(0...127)
    static let midiChannels = Array(1...16)
    static let ccNumbers = Array(0...127)
    /// Peak/trough notes support -1 as "disabled" (no realtime jump note).
    static let optionalMidiNotes = [-1] + Array(0...127)

    static func noteLabel(_ note: Int) -> String {
        note == -1 ? "Disabled" : String(note)
    }
}
