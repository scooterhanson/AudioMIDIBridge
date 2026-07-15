import Foundation

// ---------------------------------------------------------------------------
// Config model
// ---------------------------------------------------------------------------

/// Every note-on this app sends uses this fixed velocity — there is no
/// per-note/per-level/per-trigger velocity concept anymore (previously
/// configurable per level/tap/peak/trough/silence, and dynamically scaled
/// from measured energy for band triggers).
public let defaultNoteVelocity: Int = 100

public struct AudioConfig {
    public var inputDevice: String = ""
    public var sampleRate: Double  = 44100
    public var fftSize: Int        = 2048
    public var hopSize: Int        = 512
    public var silenceThreshold: Double       = 0.01
    public var silenceHoldoffFrames: Int      = 200

    // Manual input gain (linear multiplier, 1.0 = unity). Raise this if the
    // microphone is insensitive and levels never leave "low".
    public var inputGain: Double = 1.0

    // Auto-gain: measures ambient noise for a short window right after
    // startup and boosts input so that ambient level normalizes to just
    // under silenceThreshold, regardless of microphone sensitivity.
    public var autoGainEnabled: Bool          = true
    public var autoGainCalibrationMs: Int     = 1500
    public var autoGainMaxMultiplier: Double  = 25.0
}

public struct FrequencyBand {
    public let name: String
    public let lowHz: Double
    public let highHz: Double

    public init(name: String, lowHz: Double, highHz: Double) {
        self.name = name
        self.lowHz = lowHz
        self.highHz = highHz
    }
}

public struct TempoConfig {
    public var bpmMin: Double       = 60
    public var bpmMax: Double       = 180
    public var onsetSensitivity: Double = 0.5
    public var bpmSmoothingBeats: Int   = 8
    public var tapNote: Int         = 60
    public var tapChannel: Int      = 1
    public var tapDurationMs: Int   = 20
}

/// A named energy level, identified by its own lower boundary (`minRMS`)
/// only. Levels are checked in ascending order; a level's effective upper
/// bound is always the *next* level's `minRMS` (or unbounded, for the last
/// level) — there is deliberately no independent `maxRMS` to configure, so
/// adjacent levels can never gap or overlap. The first level ("silent" by
/// convention) has no meaningful `minRMS` of its own; it's simply
/// "everything below the second level's minRMS."
public struct EnergyLevel {
    public let name: String
    public let minRMS: Double
    /// Always non-empty — the sole source of which note(s) this level
    /// sends. A level with just one note is simply a one-element array;
    /// there is no separate singular "midiNote" concept anymore.
    public let midiNotes: [Int]
    public let channel: Int

    public init(name: String,
                 minRMS: Double,
                 midiNotes: [Int],
                 channel: Int) {
        self.name = name
        self.minRMS = minRMS
        self.midiNotes = midiNotes.isEmpty ? [0] : midiNotes
        self.channel = channel
    }

    public func note(at index: Int) -> Int {
        midiNotes[index % midiNotes.count]
    }

    public var noteListDescription: String {
        midiNotes.map(String.init).joined(separator: "/")
    }

    /// Returns a copy with a new lower boundary — used by the GUI's
    /// threshold sliders, which replace level entries rather than mutate
    /// them in place (minRMS is immutable so a level's identity/note/channel
    /// can't drift accidentally while dragging a slider).
    public func withMinRMS(_ newMinRMS: Double) -> EnergyLevel {
        EnergyLevel(name: name, minRMS: newMinRMS, midiNotes: midiNotes, channel: channel)
    }
}

public struct EnergyConfig {
    public var levels: [EnergyLevel]      = []
    public var attackFrames: Int          = 3
    public var releaseFrames: Int         = 30
    public var hysteresis: Double         = 0.02
    public var bufferDurationMs: Int      = 500
    public var baselineThreshold: Double  = 0.05
    public var peakThreshold: Double      = 0.25
    public var peakNote: Int              = -1
    public var peakChannel: Int           = 2
    public var troughNote: Int            = -1
    public var troughChannel: Int         = 2
    public var cycleBeats: Int            = 16
    public var cycleNotes: [Int]          = []
}

public struct CalibrationSection {
    public let name: String
    public let startTime: Double

    public init(name: String, startTime: Double) {
        self.name = name
        self.startTime = startTime
    }
}

public struct CalibrationConfig {
    public var audioFile: String = ""
    public var sections: [CalibrationSection] = []
}

public struct SilenceConfig {
    public var midiNote: Int        = 127
    public var channel: Int         = 2
    public var resumeNote: Int      = 126
    public var resumeChannel: Int   = 2
}

public struct BandTrigger {
    public let name: String
    public let threshold: Double
    public let midiNote: Int
    public let channel: Int

    public init(name: String, threshold: Double, midiNote: Int, channel: Int) {
        self.name = name
        self.threshold = threshold
        self.midiNote = midiNote
        self.channel = channel
    }

    /// Returns a copy with a new threshold — used by the GUI's threshold
    /// sliders, which replace array entries rather than mutate them in
    /// place (fields are immutable so a band's identity/note/channel can't
    /// drift accidentally while dragging a slider).
    public func withThreshold(_ newThreshold: Double) -> BandTrigger {
        BandTrigger(name: name, threshold: newThreshold, midiNote: midiNote, channel: channel)
    }
}

public struct BandTriggersConfig {
    public var enabled: Bool          = true
    public var triggerDurationMs: Int = 30
    public var bands: [BandTrigger]   = []
}

public struct CrossfadeConfig {
    public var ccNumber: Int     = 20
    public var channel: Int      = 2
    public var defaultBeats: Int = 4
}

public struct AppConfig {
    public var audio: AudioConfig               = AudioConfig()
    public var frequencyBands: [FrequencyBand]  = []
    public var tempo: TempoConfig               = TempoConfig()
    public var energy: EnergyConfig             = EnergyConfig()
    public var silence: SilenceConfig           = SilenceConfig()
    public var bandTriggers: BandTriggersConfig = BandTriggersConfig()
    public var crossfade: CrossfadeConfig       = CrossfadeConfig()
    public var calibration: CalibrationConfig   = CalibrationConfig()

    public init() {}
}

// ---------------------------------------------------------------------------
// Minimal TOML-like parser
// (Handles the subset used in config.toml — no external dependencies)
// ---------------------------------------------------------------------------

public struct ConfigParser {

    public static func load(from path: String) throws -> AppConfig {
        let contents = try String(contentsOfFile: path, encoding: .utf8)
        return try parse(contents)
    }

    public static func loadDefault() -> AppConfig {
        var cfg = AppConfig()
        // Sensible defaults already in structs; add default energy levels
        cfg.energy.levels = [
            EnergyLevel(name:"silent",    minRMS:0.00, midiNotes:[0],  channel:2),
            EnergyLevel(name:"low",       minRMS:0.01, midiNotes:[36], channel:2),
            EnergyLevel(name:"medium",    minRMS:0.08, midiNotes:[37], channel:2),
            EnergyLevel(name:"high",      minRMS:0.20, midiNotes:[38], channel:2),
            EnergyLevel(name:"very_high", minRMS:0.50, midiNotes:[39], channel:2),
        ]
        cfg.frequencyBands = [
            FrequencyBand(name:"kick",  lowHz:40,   highHz:120),
            FrequencyBand(name:"snare", lowHz:150,  highHz:400),
            FrequencyBand(name:"hihat", lowHz:6000, highHz:14000),
            FrequencyBand(name:"bass",  lowHz:80,   highHz:250),
        ]
        cfg.bandTriggers.bands = [
            BandTrigger(name:"kick",  threshold:0.15, midiNote:48, channel:3),
            BandTrigger(name:"snare", threshold:0.12, midiNote:49, channel:3),
            BandTrigger(name:"hihat", threshold:0.08, midiNote:50, channel:3),
            BandTrigger(name:"bass",  threshold:0.10, midiNote:51, channel:3),
        ]
        cfg.energy.bufferDurationMs = 500
        cfg.energy.baselineThreshold = 0.05
        cfg.energy.peakThreshold = 0.25
        cfg.energy.peakNote = -1
        cfg.energy.peakChannel = 2
        cfg.energy.troughNote = -1
        cfg.energy.troughChannel = 2
        cfg.energy.cycleBeats = 16
        cfg.energy.cycleNotes = [60, 62, 64, 65, 67, 69, 71, 72]
        return cfg
    }

    // MARK: - Parser

    private static func parse(_ text: String) throws -> AppConfig {
        var cfg = AppConfig()
        var energyLevels: [EnergyLevel]   = []
        var bandTriggerList: [BandTrigger] = []
        var freqBands: [FrequencyBand]     = []

        // State machine: track current [section] and [[array_section]]
        var section      = ""
        var arraySection = ""

        // Accumulator for current [[]] block
        var curBlock: [String: String] = [:]

        func flushBlock() {
            guard !arraySection.isEmpty else { return }
            switch arraySection {
            case "energy.levels":
                // min_rms defaults to 0.0 when absent — meaningful for the
                // bottom level ("silent" by convention), whose own lower
                // bound is unused: its effective range is always
                // "everything below the next level's minRMS."
                if let name = curBlock["name"],
                   let ch   = curBlock["channel"].flatMap(Int.init) {
                    let minRMS = curBlock["min_rms"].flatMap(Double.init) ?? 0.0
                    let notes = parseEnergyNotes(from: curBlock)
                    energyLevels.append(EnergyLevel(name: name.trimmingCharacters(in: .init(charactersIn: "\"")),
                                                    minRMS: minRMS, midiNotes: notes, channel: ch))
                }
            case "band_triggers.bands":
                if let name  = curBlock["name"],
                   let thr   = curBlock["threshold"].flatMap(Double.init),
                   let note  = curBlock["midi_note"].flatMap(Int.init),
                   let ch    = curBlock["channel"].flatMap(Int.init) {
                    bandTriggerList.append(BandTrigger(
                        name: name.trimmingCharacters(in: .init(charactersIn: "\"")),
                        threshold: thr, midiNote: note, channel: ch))
                }
            case "calibration.sections":
                if let name = curBlock["name"],
                   let start = curBlock["start_time"].flatMap(Double.init) {
                    let section = CalibrationSection(name: name.trimmingCharacters(in: .init(charactersIn: "\"")),
                                                     startTime: start)
                    cfg.calibration.sections.append(section)
                }
            default: break
            }
            curBlock = [:]
        }

        let lines = text.components(separatedBy: .newlines)
        for rawLine in lines {
            // Strip comments and whitespace
            var line = rawLine
            if let ci = line.firstIndex(of: "#") { line = String(line[..<ci]) }
            line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            // [[array table]]
            if line.hasPrefix("[[") && line.hasSuffix("]]") {
                flushBlock()
                arraySection = String(line.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
                section      = arraySection
                continue
            }

            // [section]
            if line.hasPrefix("[") && line.hasSuffix("]") {
                flushBlock()
                arraySection = ""
                section = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                continue
            }

            // key = value
            guard let eqIdx = line.firstIndex(of: "=") else { continue }
            let key   = String(line[..<eqIdx]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: eqIdx)...]).trimmingCharacters(in: .whitespaces)
            // Strip inline string quotes
            if value.hasPrefix("\"") && value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }

            if !arraySection.isEmpty {
                curBlock[key] = value
                continue
            }

            // Dispatch to config struct
            switch section {
            case "audio":
                switch key {
                case "input_device":              cfg.audio.inputDevice = value
                case "sample_rate":               cfg.audio.sampleRate  = Double(value) ?? 44100
                case "fft_size":                  cfg.audio.fftSize     = Int(value) ?? 2048
                case "hop_size":                  cfg.audio.hopSize     = Int(value) ?? 512
                case "silence_threshold":         cfg.audio.silenceThreshold = Double(value) ?? 0.01
                case "silence_holdoff_frames":    cfg.audio.silenceHoldoffFrames = Int(value) ?? 200
                case "input_gain":                cfg.audio.inputGain = Double(value) ?? 1.0
                case "auto_gain_enabled":         cfg.audio.autoGainEnabled = (value as NSString).boolValue
                case "auto_gain_calibration_ms":  cfg.audio.autoGainCalibrationMs = Int(value) ?? 1500
                case "auto_gain_max":             cfg.audio.autoGainMaxMultiplier = Double(value) ?? 25.0
                default: break
                }
            case "calibration":
                switch key {
                case "audio_file":               cfg.calibration.audioFile = value
                default: break
                }
            case "frequency_bands":
                // kick = [40, 120]
                if let arrStr = value.components(separatedBy: "[").last?.components(separatedBy: "]").first {
                    let parts = arrStr.components(separatedBy: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                    if parts.count == 2 {
                        freqBands.append(FrequencyBand(name: key, lowHz: parts[0], highHz: parts[1]))
                    }
                }
            case "tempo":
                switch key {
                case "bpm_min":               cfg.tempo.bpmMin = Double(value) ?? 60
                case "bpm_max":               cfg.tempo.bpmMax = Double(value) ?? 180
                case "onset_sensitivity":     cfg.tempo.onsetSensitivity = Double(value) ?? 0.5
                case "bpm_smoothing_beats":   cfg.tempo.bpmSmoothingBeats = Int(value) ?? 8
                case "tap_note":              cfg.tempo.tapNote = Int(value) ?? 60
                case "tap_channel":           cfg.tempo.tapChannel = Int(value) ?? 1
                case "tap_note_duration_ms":  cfg.tempo.tapDurationMs = Int(value) ?? 20
                default: break
                }
            case "energy":
                switch key {
                case "attack_frames":       cfg.energy.attackFrames  = Int(value) ?? 3
                case "release_frames":      cfg.energy.releaseFrames = Int(value) ?? 30
                case "hysteresis":          cfg.energy.hysteresis    = Double(value) ?? 0.02
                case "buffer_duration_ms":  cfg.energy.bufferDurationMs = Int(value) ?? 500
                case "baseline_threshold":  cfg.energy.baselineThreshold = Double(value) ?? 0.05
                case "peak_threshold":      cfg.energy.peakThreshold = Double(value) ?? 0.25
                case "peak_note":           cfg.energy.peakNote = Int(value) ?? -1
                case "peak_channel":        cfg.energy.peakChannel = Int(value) ?? 2
                case "trough_note":         cfg.energy.troughNote = Int(value) ?? -1
                case "trough_channel":       cfg.energy.troughChannel = Int(value) ?? 2
                case "cycle_beats":         cfg.energy.cycleBeats = Int(value) ?? 16
                case "cycle_notes":         cfg.energy.cycleNotes = parseIntArray(value)
                default: break
                }
            case "energy.smoothing":
                switch key {
                case "attack_frames":       cfg.energy.attackFrames  = Int(value) ?? 3
                case "release_frames":      cfg.energy.releaseFrames = Int(value) ?? 30
                case "hysteresis":          cfg.energy.hysteresis    = Double(value) ?? 0.02
                case "buffer_duration_ms":  cfg.energy.bufferDurationMs = Int(value) ?? 500
                default: break
                }
            case "silence":
                switch key {
                case "midi_note":         cfg.silence.midiNote       = Int(value) ?? 127
                case "channel":           cfg.silence.channel        = Int(value) ?? 2
                case "resume_note":       cfg.silence.resumeNote     = Int(value) ?? 126
                case "resume_channel":    cfg.silence.resumeChannel  = Int(value) ?? 2
                default: break
                }
            case "band_triggers":
                switch key {
                case "enabled":              cfg.bandTriggers.enabled = (value as NSString).boolValue
                case "trigger_duration_ms":  cfg.bandTriggers.triggerDurationMs = Int(value) ?? 30
                default: break
                }
            case "crossfade":
                switch key {
                case "cc_number":       cfg.crossfade.ccNumber     = Int(value) ?? 20
                case "channel":         cfg.crossfade.channel      = Int(value) ?? 2
                case "default_beats":   cfg.crossfade.defaultBeats = Int(value) ?? 4
                default: break
                }
            default: break
            }
        }
        flushBlock()

        if !energyLevels.isEmpty   { cfg.energy.levels         = energyLevels }
        if !bandTriggerList.isEmpty { cfg.bandTriggers.bands   = bandTriggerList }
        if !freqBands.isEmpty       { cfg.frequencyBands       = freqBands }

        // Apply defaults if nothing was parsed
        if cfg.energy.levels.isEmpty  { cfg = loadDefault(); return cfg }

        return cfg
    }

    private static func parseIntArray(_ text: String) -> [Int] {
        let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
        let parts = trimmed.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        return parts.compactMap { Int($0) }
    }

    private static func parseEnergyNotes(from block: [String: String]) -> [Int] {
        if let multiNotes = block["midi_notes"] {
            return parseIntArray(multiNotes)
        }
        if let singleNote = block["midi_note"], let value = Int(singleNote) {
            return [value]
        }
        return []
    }
}
