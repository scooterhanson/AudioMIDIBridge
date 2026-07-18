import Foundation
import AudioMIDIBridgeCore

/// Writes the GUI's editable values (silence/baseline/peak thresholds,
/// per-level min_rms, hysteresis/attack/release, tempo smoothing/onset
/// sensitivity, crossfade beats, per-band trigger thresholds) back into an
/// existing config.toml in place — only touching the specific value tokens
/// on matching lines, so the rest of the file (comments, ordering, unrelated
/// sections) survives untouched. This mirrors ConfigParser's own
/// line-scanning state machine so reader and writer never disagree about
/// which line a value belongs to.
enum ConfigFileWriter {

    enum WriteError: LocalizedError {
        case fileNotReadable(String)
        var errorDescription: String? {
            switch self {
            case .fileNotReadable(let path): return "Could not read config file at \(path)"
            }
        }
    }

    static func save(_ cfg: AppConfig, to path: String) throws {
        guard let original = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw WriteError.fileNotReadable(path)
        }

        var levelMins: [String: Double] = [:]
        var levelNotes: [String: [Int]] = [:]
        var levelChannels: [String: Int] = [:]
        for level in cfg.energy.levels {
            levelMins[level.name] = level.minRMS
            levelNotes[level.name] = level.midiNotes
            levelChannels[level.name] = level.channel
        }
        var bandThresholds: [String: Double] = [:]
        var bandNotes: [String: Int] = [:]
        var bandChannels: [String: Int] = [:]
        for band in cfg.bandTriggers.bands {
            bandThresholds[band.name] = band.threshold
            bandNotes[band.name] = band.midiNote
            bandChannels[band.name] = band.channel
        }

        // Preserve the file's original line terminator style as best we can;
        // components(separatedBy:) on "\n" handles both "\n" and "\r\n" (the
        // trailing "\r" just rides along as part of each line's content).
        var lines = original.components(separatedBy: "\n")

        var section = ""
        var arraySection = ""
        var currentLevelName: String?
        var currentBandName: String?

        for i in 0..<lines.count {
            let rawLine = lines[i]
            var stripped = rawLine
            if let ci = stripped.firstIndex(of: "#") { stripped = String(stripped[..<ci]) }
            let trimmed = stripped.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            if trimmed.hasPrefix("[[") && trimmed.hasSuffix("]]") {
                arraySection = String(trimmed.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
                section = arraySection
                currentLevelName = nil
                currentBandName = nil
                continue
            }
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                arraySection = ""
                section = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                continue
            }

            guard let eqIdx = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<eqIdx]).trimmingCharacters(in: .whitespaces)

            if arraySection == "energy.levels" {
                if key == "name" {
                    currentLevelName = quotedValue(trimmed, eqIdx: eqIdx)
                } else if key == "min_rms", let name = currentLevelName, let minRMS = levelMins[name] {
                    lines[i] = replacingValue(in: rawLine, newValue: formatNumber(minRMS))
                } else if key == "midi_notes", let name = currentLevelName, let notes = levelNotes[name] {
                    // Deliberately only matches the "midi_notes" array key,
                    // not the legacy singular "midi_note" — writing an
                    // array literal onto a scalar-keyed line would produce
                    // invalid TOML for that key. Every level in this
                    // project's config.toml already uses midi_notes.
                    lines[i] = replacingValue(in: rawLine, newValue: formatIntArray(notes))
                } else if key == "channel", let name = currentLevelName, let channel = levelChannels[name] {
                    lines[i] = replacingValue(in: rawLine, newValue: String(channel))
                }
                continue
            }

            if arraySection == "band_triggers.bands" {
                if key == "name" {
                    currentBandName = quotedValue(trimmed, eqIdx: eqIdx)
                } else if key == "threshold", let name = currentBandName, let threshold = bandThresholds[name] {
                    lines[i] = replacingValue(in: rawLine, newValue: formatNumber(threshold))
                } else if key == "midi_note", let name = currentBandName, let note = bandNotes[name] {
                    lines[i] = replacingValue(in: rawLine, newValue: String(note))
                } else if key == "channel", let name = currentBandName, let channel = bandChannels[name] {
                    lines[i] = replacingValue(in: rawLine, newValue: String(channel))
                }
                continue
            }

            guard arraySection.isEmpty else { continue }
            switch (section, key) {
            case ("audio", "silence_threshold"):
                lines[i] = replacingValue(in: rawLine, newValue: formatNumber(cfg.audio.silenceThreshold))
            case ("energy", "baseline_threshold"):
                lines[i] = replacingValue(in: rawLine, newValue: formatNumber(cfg.energy.baselineThreshold))
            case ("energy", "peak_threshold"):
                lines[i] = replacingValue(in: rawLine, newValue: formatNumber(cfg.energy.peakThreshold))
            case ("energy", "hysteresis"), ("energy.smoothing", "hysteresis"):
                lines[i] = replacingValue(in: rawLine, newValue: formatNumber(cfg.energy.hysteresis))
            case ("energy", "attack_frames"), ("energy.smoothing", "attack_frames"):
                lines[i] = replacingValue(in: rawLine, newValue: String(cfg.energy.attackFrames))
            case ("energy", "release_frames"), ("energy.smoothing", "release_frames"):
                lines[i] = replacingValue(in: rawLine, newValue: String(cfg.energy.releaseFrames))
            case ("energy", "buffer_duration_ms"), ("energy.smoothing", "buffer_duration_ms"):
                lines[i] = replacingValue(in: rawLine, newValue: String(cfg.energy.bufferDurationMs))
            case ("tempo", "bpm_smoothing_beats"):
                lines[i] = replacingValue(in: rawLine, newValue: String(cfg.tempo.bpmSmoothingBeats))
            case ("tempo", "onset_sensitivity"):
                lines[i] = replacingValue(in: rawLine, newValue: formatNumber(cfg.tempo.onsetSensitivity))
            case ("tempo", "tap_note"):
                lines[i] = replacingValue(in: rawLine, newValue: String(cfg.tempo.tapNote))
            case ("tempo", "tap_channel"):
                lines[i] = replacingValue(in: rawLine, newValue: String(cfg.tempo.tapChannel))
            case ("energy", "peak_note"):
                lines[i] = replacingValue(in: rawLine, newValue: String(cfg.energy.peakNote))
            case ("energy", "peak_channel"):
                lines[i] = replacingValue(in: rawLine, newValue: String(cfg.energy.peakChannel))
            case ("energy", "trough_note"):
                lines[i] = replacingValue(in: rawLine, newValue: String(cfg.energy.troughNote))
            case ("energy", "trough_channel"):
                lines[i] = replacingValue(in: rawLine, newValue: String(cfg.energy.troughChannel))
            case ("energy", "low_bpm_cap_threshold"):
                lines[i] = replacingValue(in: rawLine, newValue: formatNumber(cfg.energy.lowBpmCapThreshold))
            case ("energy", "medium_bpm_cap_threshold"):
                lines[i] = replacingValue(in: rawLine, newValue: formatNumber(cfg.energy.mediumBpmCapThreshold))
            case ("energy", "bpm_cap_hysteresis"):
                lines[i] = replacingValue(in: rawLine, newValue: formatNumber(cfg.energy.bpmCapHysteresis))
            case ("energy", "band_activity_boost_band_count"):
                lines[i] = replacingValue(in: rawLine, newValue: String(cfg.energy.bandActivityBoostBandCount))
            case ("energy", "band_activity_boost_levels"):
                lines[i] = replacingValue(in: rawLine, newValue: String(cfg.energy.bandActivityBoostLevels))
            case ("silence", "midi_note"):
                lines[i] = replacingValue(in: rawLine, newValue: String(cfg.silence.midiNote))
            case ("silence", "channel"):
                lines[i] = replacingValue(in: rawLine, newValue: String(cfg.silence.channel))
            case ("silence", "resume_note"):
                lines[i] = replacingValue(in: rawLine, newValue: String(cfg.silence.resumeNote))
            case ("silence", "resume_channel"):
                lines[i] = replacingValue(in: rawLine, newValue: String(cfg.silence.resumeChannel))
            case ("crossfade", "default_beats"):
                lines[i] = replacingValue(in: rawLine, newValue: String(cfg.crossfade.defaultBeats))
            case ("crossfade", "cc_number"):
                lines[i] = replacingValue(in: rawLine, newValue: String(cfg.crossfade.ccNumber))
            case ("crossfade", "channel"):
                lines[i] = replacingValue(in: rawLine, newValue: String(cfg.crossfade.channel))
            case ("band_triggers", "enabled"):
                lines[i] = replacingValue(in: rawLine, newValue: cfg.bandTriggers.enabled ? "true" : "false")
            default:
                break
            }
        }

        let updated = lines.joined(separator: "\n")
        try updated.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Extracts a `name = "value"` line's value with surrounding quotes
    /// stripped, given the line already trimmed and its `=` index.
    private static func quotedValue(_ trimmedLine: String, eqIdx: String.Index) -> String {
        let raw = String(trimmedLine[trimmedLine.index(after: eqIdx)...]).trimmingCharacters(in: .whitespaces)
        return raw.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    /// Replaces just the value token on a `key = value  # comment` line,
    /// keeping the key, its original spacing before `=`, and any trailing
    /// comment intact.
    private static func replacingValue(in line: String, newValue: String) -> String {
        guard let eqIdx = line.firstIndex(of: "=") else { return line }
        let before = String(line[..<eqIdx])
        var after = String(line[line.index(after: eqIdx)...])
        var comment = ""
        if let hashIdx = after.firstIndex(of: "#") {
            comment = String(after[hashIdx...])
            after = String(after[..<hashIdx])
        }
        return comment.isEmpty ? "\(before)= \(newValue)" : "\(before)= \(newValue)  \(comment)"
    }

    private static func formatNumber(_ value: Double) -> String {
        var s = String(format: "%.6f", value)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s += "0" }
        return s
    }

    private static func formatIntArray(_ values: [Int]) -> String {
        "[" + values.map(String.init).joined(separator: ", ") + "]"
    }
}
