import Foundation

// ---------------------------------------------------------------------------
// Config model
// ---------------------------------------------------------------------------

struct AudioConfig {
    var inputDevice: String = ""
    var sampleRate: Double  = 44100
    var fftSize: Int        = 2048
    var hopSize: Int        = 512
    var silenceThreshold: Double       = 0.01
    var silenceHoldoffFrames: Int      = 200
}

struct FrequencyBand {
    let name: String
    let lowHz: Double
    let highHz: Double
}

struct TempoConfig {
    var bpmMin: Double       = 60
    var bpmMax: Double       = 180
    var onsetSensitivity: Double = 0.5
    var bpmSmoothingBeats: Int   = 8
    var tempoChangeBeats: Int   = 16
    var tapNote: Int         = 60
    var tapChannel: Int      = 1
    var tapVelocity: Int     = 100
    var tapDurationMs: Int   = 20
}

struct EnergyLevel {
    let name: String
    let minRMS: Double
    let maxRMS: Double
    let midiNote: Int
    let midiNotes: [Int]
    let channel: Int
    let velocity: Int

    init(name: String,
         minRMS: Double,
         maxRMS: Double,
         midiNote: Int,
         midiNotes: [Int] = [],
         channel: Int,
         velocity: Int) {
        self.name = name
        self.minRMS = minRMS
        self.maxRMS = maxRMS
        self.midiNote = midiNote
        self.midiNotes = midiNotes.isEmpty ? [midiNote] : midiNotes
        self.channel = channel
        self.velocity = velocity
    }

    func note(at index: Int) -> Int {
        guard !midiNotes.isEmpty else { return midiNote }
        return midiNotes[index % midiNotes.count]
    }

    var noteListDescription: String {
        midiNotes.map(String.init).joined(separator: "/")
    }
}

struct EnergyConfig {
    var levels: [EnergyLevel]      = []
    var attackFrames: Int          = 3
    var releaseFrames: Int         = 30
    var hysteresis: Double         = 0.02
    var bufferDurationMs: Int      = 500
    var baselineThreshold: Double  = 0.05
    var peakThreshold: Double      = 0.25
    var peakNote: Int              = -1
    var peakChannel: Int           = 2
    var peakVelocity: Int          = 100
    var troughNote: Int            = -1
    var troughChannel: Int         = 2
    var troughVelocity: Int        = 100
    var cycleBeats: Int            = 16
    var cycleNotes: [Int]          = []
}

struct CalibrationSection {
    let name: String
    let startTime: Double
}

struct CalibrationConfig {
    var audioFile: String = ""
    var sections: [CalibrationSection] = []
}

struct SilenceConfig {
    var midiNote: Int        = 127
    var channel: Int         = 2
    var velocity: Int        = 0
    var resumeNote: Int      = 126
    var resumeChannel: Int   = 2
    var resumeVelocity: Int  = 64
}

struct BandTrigger {
    let name: String
    let threshold: Double
    let midiNote: Int
    let channel: Int
    let velocityScale: Double
}

struct BandTriggersConfig {
    var triggerDurationMs: Int = 30
    var bands: [BandTrigger]   = []
}

struct CrossfadeConfig {
    var ccNumber: Int     = 20
    var channel: Int      = 2
    var defaultBeats: Int = 4
}

struct AppConfig {
    var audio: AudioConfig               = AudioConfig()
    var frequencyBands: [FrequencyBand]  = []
    var tempo: TempoConfig               = TempoConfig()
    var energy: EnergyConfig             = EnergyConfig()
    var silence: SilenceConfig           = SilenceConfig()
    var bandTriggers: BandTriggersConfig = BandTriggersConfig()
    var crossfade: CrossfadeConfig       = CrossfadeConfig()
    var calibration: CalibrationConfig   = CalibrationConfig()
}

// ---------------------------------------------------------------------------
// Minimal TOML-like parser
// (Handles the subset used in config.toml — no external dependencies)
// ---------------------------------------------------------------------------

struct ConfigParser {

    static func load(from path: String) throws -> AppConfig {
        let contents = try String(contentsOfFile: path, encoding: .utf8)
        return try parse(contents)
    }

    static func loadDefault() -> AppConfig {
        var cfg = AppConfig()
        // Sensible defaults already in structs; add default energy levels
        cfg.energy.levels = [
            EnergyLevel(name:"silent",    minRMS:0.00, maxRMS:0.01, midiNote:0,   channel:2, velocity:0),
            EnergyLevel(name:"low",       minRMS:0.01, maxRMS:0.08, midiNote:36,  channel:2, velocity:40),
            EnergyLevel(name:"medium",    minRMS:0.08, maxRMS:0.20, midiNote:37,  channel:2, velocity:80),
            EnergyLevel(name:"high",      minRMS:0.20, maxRMS:0.50, midiNote:38,  channel:2, velocity:110),
            EnergyLevel(name:"very_high", minRMS:0.50, maxRMS:1.00, midiNote:39,  channel:2, velocity:127),
        ]
        cfg.frequencyBands = [
            FrequencyBand(name:"kick",  lowHz:40,   highHz:120),
            FrequencyBand(name:"snare", lowHz:150,  highHz:400),
            FrequencyBand(name:"hihat", lowHz:6000, highHz:14000),
            FrequencyBand(name:"bass",  lowHz:80,   highHz:250),
        ]
        cfg.bandTriggers.bands = [
            BandTrigger(name:"kick",  threshold:0.15, midiNote:48, channel:3, velocityScale:1.0),
            BandTrigger(name:"snare", threshold:0.12, midiNote:49, channel:3, velocityScale:1.0),
            BandTrigger(name:"hihat", threshold:0.08, midiNote:50, channel:3, velocityScale:0.8),
            BandTrigger(name:"bass",  threshold:0.10, midiNote:51, channel:3, velocityScale:1.0),
        ]
        cfg.energy.bufferDurationMs = 500
        cfg.energy.baselineThreshold = 0.05
        cfg.energy.peakThreshold = 0.25
        cfg.energy.peakNote = -1
        cfg.energy.peakChannel = 2
        cfg.energy.peakVelocity = 100
        cfg.energy.troughNote = -1
        cfg.energy.troughChannel = 2
        cfg.energy.troughVelocity = 100
        cfg.energy.cycleBeats = 16
        cfg.energy.cycleNotes = [60, 62, 64, 65, 67, 69, 71, 72]
        cfg.tempo.tempoChangeBeats = 16
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
                if let name    = curBlock["name"],
                   let minRMS  = curBlock["min_rms"].flatMap(Double.init),
                   let maxRMS  = curBlock["max_rms"].flatMap(Double.init),
                   let ch      = curBlock["channel"].flatMap(Int.init),
                   let vel     = curBlock["velocity"].flatMap(Int.init) {
                    let notes = parseEnergyNotes(from: curBlock)
                    let note = curBlock["midi_note"].flatMap(Int.init) ?? notes.first ?? -1
                    energyLevels.append(EnergyLevel(name: name.trimmingCharacters(in: .init(charactersIn: "\"")),
                                                    minRMS: minRMS, maxRMS: maxRMS,
                                                    midiNote: note, midiNotes: notes,
                                                    channel: ch, velocity: vel))
                }
            case "band_triggers.bands":
                if let name  = curBlock["name"],
                   let thr   = curBlock["threshold"].flatMap(Double.init),
                   let note  = curBlock["midi_note"].flatMap(Int.init),
                   let ch    = curBlock["channel"].flatMap(Int.init),
                   let scale = curBlock["velocity_scale"].flatMap(Double.init) {
                    bandTriggerList.append(BandTrigger(
                        name: name.trimmingCharacters(in: .init(charactersIn: "\"")),
                        threshold: thr, midiNote: note, channel: ch, velocityScale: scale))
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
                case "tempo_change_beats":    cfg.tempo.tempoChangeBeats = Int(value) ?? 16
                case "tap_note":              cfg.tempo.tapNote = Int(value) ?? 60
                case "tap_channel":           cfg.tempo.tapChannel = Int(value) ?? 1
                case "tap_velocity":          cfg.tempo.tapVelocity = Int(value) ?? 100
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
                case "peak_velocity":       cfg.energy.peakVelocity = Int(value) ?? 100
                case "trough_note":         cfg.energy.troughNote = Int(value) ?? -1
                case "trough_channel":       cfg.energy.troughChannel = Int(value) ?? 2
                case "trough_velocity":      cfg.energy.troughVelocity = Int(value) ?? 100
                case "cycle_beats":         cfg.energy.cycleBeats = Int(value) ?? 16
                case "cycle_notes":         cfg.energy.cycleNotes = parseIntArray(value)
                default: break
                }
            case "energy.smoothing":
                switch key {
                case "attack_frames":   cfg.energy.attackFrames  = Int(value) ?? 3
                case "release_frames":  cfg.energy.releaseFrames = Int(value) ?? 30
                case "hysteresis":      cfg.energy.hysteresis    = Double(value) ?? 0.02
                default: break
                }
            case "silence":
                switch key {
                case "midi_note":         cfg.silence.midiNote       = Int(value) ?? 127
                case "channel":           cfg.silence.channel        = Int(value) ?? 2
                case "velocity":          cfg.silence.velocity       = Int(value) ?? 0
                case "resume_note":       cfg.silence.resumeNote     = Int(value) ?? 126
                case "resume_channel":    cfg.silence.resumeChannel  = Int(value) ?? 2
                case "resume_velocity":   cfg.silence.resumeVelocity = Int(value) ?? 64
                default: break
                }
            case "band_triggers":
                if key == "trigger_duration_ms" { cfg.bandTriggers.triggerDurationMs = Int(value) ?? 30 }
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
