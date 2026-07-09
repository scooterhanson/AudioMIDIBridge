import Foundation
import AVFoundation
import CoreMIDI

// ---------------------------------------------------------------------------
// AudioMIDIBridge — entry point
// ---------------------------------------------------------------------------

// MARK: - CLI argument parsing

func printHelp() {
    print("""
    AudioMIDIBridge — Audio-reactive MIDI controller for macOS

    USAGE:
      AudioMIDIBridge [OPTIONS]

    OPTIONS:
      --config <path>     Path to config.toml  (default: ./config.toml)
      --list-audio        List available audio input devices and exit
      --list-midi         List available MIDI destinations and exit
      --device-id <uid>   Select audio input device by unique ID
      --calibrate          Run calibration mode using the audio file referenced in config.toml
      --no-display        Suppress the live terminal dashboard
      -h, --help          Show this help

    DESCRIPTION:
      Listens to audio input, analyses tempo, energy, and per-band levels,
      then emits MIDI notes/CCs on a virtual CoreMIDI port named
      "AudioMIDIBridge".  Connect to this port from any MIDI-compatible
      application (Ableton, QLab, Touch Designer, etc.).

    MIDI OUTPUT SUMMARY (configurable in config.toml):
      Ch 1  Note 60 — Beat tap (short note-on per detected beat)
      Ch 2  Notes 36–39 — Energy level (low/medium/high/very high)
      Ch 2  Note 127 — Silence begin
      Ch 2  Note 126 — Silence end / music resume
      Ch 2  CC 20  — Crossfade duration hint (0–127 = 0–8 seconds)
      Ch 3  Notes 48–51 — Band triggers (kick/snare/hihat/bass)

    SIGNAL CHAIN:
      Microphone / Line-In
        → FFT (configurable window size)
          → RMS + spectral flux onset detection
            → TempoDetector (beat tap MIDI)
            → EnergyTracker (scene change MIDI + crossfade CC)
            → BandTriggerTracker (per-band MIDI triggers)
    """)
}

enum CalibrationError: LocalizedError {
    case missingAudioFile
    case audioFileNotFound(String)
    case noCalibrationSections
    case invalidAudioData(String)
    case sectionOutOfRange(String)

    var errorDescription: String? {
        switch self {
        case .missingAudioFile:
            return "Calibration mode requires `calibration.audio_file` in config.toml."
        case .audioFileNotFound(let path):
            return "Calibration audio file not found: \(path)"
        case .noCalibrationSections:
            return "Calibration mode requires at least one [[calibration.sections]] entry in config.toml."
        case .invalidAudioData(let msg):
            return "Invalid calibration audio data: \(msg)"
        case .sectionOutOfRange(let name):
            return "Calibration section start time out of range: \(name)"
        }
    }
}

private func secondsToTime(_ value: Double) -> String {
    let total = Int(value + 0.5)
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    if h > 0 {
        return String(format: "%d:%02d:%02d", h, m, s)
    }
    return String(format: "%02d:%02d", m, s)
}

private func runCalibration(cfg: AppConfig) throws {
    guard !cfg.calibration.audioFile.isEmpty else { throw CalibrationError.missingAudioFile }
    guard !cfg.calibration.sections.isEmpty else { throw CalibrationError.noCalibrationSections }

    let audioURL = URL(fileURLWithPath: cfg.calibration.audioFile)
    guard FileManager.default.fileExists(atPath: audioURL.path) else {
        throw CalibrationError.audioFileNotFound(audioURL.path)
    }

    let file = try AVAudioFile(forReading: audioURL)
    let format = file.processingFormat
    let frameCount = Int(file.length)
    guard frameCount > 0 else {
        throw CalibrationError.invalidAudioData("empty audio file")
    }

    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
        throw CalibrationError.invalidAudioData("could not create buffer for audio file format")
    }

    try file.read(into: buffer)

    func monoSamples(from buffer: AVAudioPCMBuffer) -> [Float]? {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        var out = [Float](repeating: 0, count: frames)

        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            guard let data = buffer.floatChannelData else { return nil }
            for i in 0..<frames {
                var sum: Float = 0
                for ch in 0..<channels { sum += data[ch][i] }
                out[i] = sum / Float(channels)
            }
            return out
        case .pcmFormatFloat64:
            let audioBufferList = buffer.audioBufferList
            let bufferCount = Int(audioBufferList.pointee.mNumberBuffers)
            guard bufferCount == channels else { return nil }
            let channelData: [UnsafePointer<Float64>] = withUnsafePointer(to: audioBufferList.pointee.mBuffers) { bufferPtr in
                let buffers = UnsafeBufferPointer(start: bufferPtr, count: bufferCount)
                return buffers.compactMap { audioBuffer in
                    if let mutablePtr = audioBuffer.mData?.assumingMemoryBound(to: Float64.self) {
                        return UnsafePointer(mutablePtr)
                    }
                    return nil
                }
            }
            guard channelData.count == channels else { return nil }
            for i in 0..<frames {
                var sum: Double = 0
                for ch in 0..<channels { sum += channelData[ch][i] }
                out[i] = Float(sum / Double(channels))
            }
            return out
        case .pcmFormatInt16:
            guard let data = buffer.int16ChannelData else { return nil }
            for i in 0..<frames {
                var sum: Float = 0
                for ch in 0..<channels { sum += Float(data[ch][i]) / 32768.0 }
                out[i] = sum / Float(channels)
            }
            return out
        case .pcmFormatInt32:
            guard let data = buffer.int32ChannelData else { return nil }
            for i in 0..<frames {
                var sum: Float = 0
                for ch in 0..<channels { sum += Float(data[ch][i]) / Float(Int32.max) }
                out[i] = sum / Float(channels)
            }
            return out
        default:
            return nil
        }
    }

    guard let samples = monoSamples(from: buffer) else {
        throw CalibrationError.invalidAudioData("unsupported audio sample format")
    }

    let fileDuration = Double(frameCount) / format.sampleRate
    let sections = cfg.calibration.sections.sorted { $0.startTime < $1.startTime }
    var sectionSummaries: [(section: CalibrationSection, startSample: Int, endSample: Int, averageRMS: Double, peak: Double)] = []

    for (index, section) in sections.enumerated() {
        guard section.startTime >= 0 && section.startTime <= fileDuration else {
            throw CalibrationError.sectionOutOfRange(section.name)
        }
        let startSample = min(frameCount - 1, Int(section.startTime * format.sampleRate))
        let endSample = index + 1 < sections.count
            ? min(frameCount, Int(sections[index + 1].startTime * format.sampleRate))
            : frameCount
        guard endSample > startSample else {
            throw CalibrationError.invalidAudioData("section \(section.name) has non-positive duration")
        }

        var sumSq: Float = 0
        var peak: Float = 0
        for i in startSample..<endSample {
            let value = abs(samples[i])
            sumSq += value * value
            peak = max(peak, value)
        }
        let count = Float(endSample - startSample)
        let rms = sqrt(sumSq / count)
        sectionSummaries.append((section, startSample, endSample, Double(rms), Double(peak)))
    }

    func category(for name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("silence") || lower.contains("drop") { return "silence" }
        if lower.contains("tempo") { return "tempo" }
        if lower.contains("high") { return "high" }
        if lower.contains("moderate") { return "moderate" }
        if lower.contains("low") || lower.contains("drums") { return "low" }
        return "unknown"
    }

    var categoryRMS: [String: [Double]] = [:]
    for summary in sectionSummaries {
        let cat = category(for: summary.section.name)
        categoryRMS[cat, default: []].append(summary.averageRMS)
    }

    func mean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    let silenceMean = mean(categoryRMS["silence"] ?? [])
    let lowMean = mean(categoryRMS["low"] ?? []) ?? mean(categoryRMS["unknown"] ?? [])
    let moderateMean = mean(categoryRMS["moderate"] ?? []) ?? lowMean
    let highMean = mean(categoryRMS["high"] ?? []) ?? moderateMean

    let recommendedSilence = silenceMean.map { max(0.001, min($0 * 1.6, max($0 + 0.002, 0.02))) }
    let recommendedBaseline: Double?
    if let silence = silenceMean, let low = lowMean {
        recommendedBaseline = min(max((silence + low) / 2.0, silence + 0.01), low - 0.01)
    } else {
        recommendedBaseline = nil
    }
    let recommendedPeak: Double?
    if let high = highMean, let moderate = moderateMean {
        recommendedPeak = min(max((high + moderate) / 2.0, moderate + 0.02), high - 0.01)
    } else {
        recommendedPeak = nil
    }

    var issues: [String] = []
    if categoryRMS["silence"]?.isEmpty ?? true {
        issues.append("No silence/drop section found in calibration sections.")
    }
    if categoryRMS["high"]?.isEmpty ?? true {
        issues.append("No high energy section was classified; peak threshold recommendation may be imprecise.")
    }
    if let low = lowMean, let high = highMean, low >= high * 0.75 {
        issues.append("Low, moderate, and high energy sections have similar RMS levels; energy thresholds may be hard to distinguish.")
    }
    if let silence = silenceMean, let baseline = recommendedBaseline, silence >= baseline {
        issues.append("Silence RMS is not meaningfully below the baseline energy recommendation.")
    }
    let tempoSections = sectionSummaries.filter { category(for: $0.section.name) == "tempo" }
    if let tempoSection = tempoSections.first {
        let duration = Double(tempoSection.endSample - tempoSection.startSample) / format.sampleRate
        if duration < 8 {
            issues.append("Tempo change section '\(tempoSection.section.name)' is shorter than 8 seconds, which may make tempo tracking less reliable.")
        }
    }

    var output = "Calibration Summary\n"
    output += "Audio file: \(audioURL.path)\n"
    output += String(format: "Duration: %.2fs\n", fileDuration)
    output += "\nSections:\n"

    for summary in sectionSummaries {
        let startSec = Double(summary.startSample) / format.sampleRate
        let endSec = Double(summary.endSample) / format.sampleRate
        output += String(format: " - %-20s %5s → %5s  RMS=%.4f peak=%.4f\n",
                         (summary.section.name as NSString).utf8String!,
                         secondsToTime(startSec),
                         secondsToTime(endSec),
                         summary.averageRMS,
                         summary.peak)
    }

    output += "\nRecommended Settings:\n"
    if let silence = recommendedSilence {
        output += String(format: " - audio.silence_threshold = %.4f\n", silence)
    }
    if let baseline = recommendedBaseline {
        output += String(format: " - energy.baseline_threshold = %.4f\n", baseline)
    }
    if let peak = recommendedPeak {
        output += String(format: " - energy.peak_threshold = %.4f\n", peak)
    }
    output += "\nPotential Issues:\n"
    if issues.isEmpty {
        output += " - None detected. Calibration audio appears well-structured for this application.\n"
    } else {
        for issue in issues {
            output += " - \(issue)\n"
        }
    }

    let summaryPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("calibration_summary.txt")
    try output.write(to: summaryPath, atomically: true, encoding: .utf8)
    print(output)
    print("Calibration summary saved to: \(summaryPath.path)")
}

// MARK: - Main

var configPath  = "./config.toml"
var showDisplay = true
var calibrationMode = false
var deviceID    = ""
var args        = CommandLine.arguments.dropFirst()

while let arg = args.first {
    args = args.dropFirst()
    switch arg {
    case "--help", "-h":
        printHelp(); exit(0)
    case "--list-audio":
        listAudioInputDevices(); exit(0)
    case "--list-midi":
        listMIDIDestinations(); exit(0)
    case "--no-display":
        showDisplay = false
    case "--calibrate":
        calibrationMode = true
    case "--device-id":
        if let next = args.first { deviceID = next; args = args.dropFirst() }
    case "--config":
        if let next = args.first { configPath = next; args = args.dropFirst() }
    default:
        fputs("Unknown option: \(arg)\n", stderr)
        exit(1)
    }
}

// Load config
var cfg: AppConfig
do {
    cfg = try ConfigParser.load(from: configPath)
    if showDisplay {
        print("Loaded config: \(configPath)")
    }
} catch {
    fputs("Could not load \(configPath): \(error.localizedDescription)\n", stderr)
    fputs("Using built-in defaults.\n", stderr)
    cfg = ConfigParser.loadDefault()
}

if !deviceID.isEmpty {
    cfg.audio.inputDevice = deviceID
}

if calibrationMode {
    do {
        try runCalibration(cfg: cfg)
        exit(0)
    } catch {
        fputs("Calibration failed: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

// MIDI output
let midi: MIDIOutput
do {
    midi = try MIDIOutput()
} catch {
    fputs("MIDI init failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}

// Subsystems
let tempo    = TempoDetector(cfg: cfg.tempo,
                              sampleRate: cfg.audio.sampleRate,
                              hopSize: cfg.audio.hopSize)
let energy   = EnergyTracker(cfg: cfg.energy,
                              silenceCfg: cfg.silence,
                              silenceThreshold: cfg.audio.silenceThreshold,
                              silenceHoldoff: cfg.audio.silenceHoldoffFrames,
                              sampleRate: cfg.audio.sampleRate,
                              hopSize: cfg.audio.hopSize)
let bands    = BandTriggerTracker(cfg: cfg.bandTriggers,
                                   sampleRate: cfg.audio.sampleRate,
                                   hopSize: cfg.audio.hopSize)
let display  = showDisplay ? TerminalDisplay(cfg: cfg) : nil
let audio    = AudioEngine(cfg: cfg)

// State for display
var currentLevelName = "—"
var levelChanged     = false
var lastSentNoteDesc = "None"
var totalPlayTime: Double = 0
var totalSilenceTime: Double = 0
var lastFrameTimestamp: Double = CACurrentMediaTime()
var stableLevelSince: Double = CACurrentMediaTime()
var currentEnergyLevelIndex = -1
var energyCycleIndexes = [Int](repeating: 0, count: cfg.energy.levels.count)

func sendNoteOn(channel: Int, note: Int, velocity: Int, durationMs: Int) {
    midi.noteOnTimed(channel: channel, note: note, velocity: velocity, durationMs: durationMs)
    lastSentNoteDesc = "ch\(channel) note\(note) vel\(velocity)"
}

func stableCycleThreshold(beats: Int, bpm: Double) -> Double {
    let effectiveBpm = bpm > 0 ? bpm : 120.0
    return Double(beats) * (60.0 / effectiveBpm)
}

func maybeSendEnergyCycleNote(now: Double) {
    guard !energy.silent else { return }
    guard let level = energy.currentLevel else { return }

    let levelIndex = currentEnergyLevelIndex >= 0 ? currentEnergyLevelIndex
                     : cfg.energy.levels.firstIndex(where: { $0.name == level.name }) ?? -1
    guard levelIndex >= 0 else { return }
    guard !level.midiNotes.isEmpty else { return }

    let threshold = stableCycleThreshold(beats: cfg.energy.cycleBeats, bpm: tempo.bpm)
    if now - stableLevelSince >= threshold {
        let nextIndex = (energyCycleIndexes[levelIndex] + 1) % level.midiNotes.count
        energyCycleIndexes[levelIndex] = nextIndex
        let nextNote = level.note(at: nextIndex)
        sendNoteOn(channel: level.channel, note: nextNote, velocity: level.velocity, durationMs: 50)
        let msg = "[CYCLE] Stable energy level '\(level.name)' for \(cfg.energy.cycleBeats) beats — sent note \(nextNote)"
        if showDisplay {
            fputs(msg + "\n", stderr)
        } else {
            print(msg)
        }
        stableLevelSince = now
    }
}

// MARK: - Wire callbacks

// Beat → MIDI tap + display flash
tempo.onBeat = { bpm in
    sendNoteOn(channel: cfg.tempo.tapChannel,
               note: cfg.tempo.tapNote,
               velocity: cfg.tempo.tapVelocity,
               durationMs: cfg.tempo.tapDurationMs)
    display?.signalBeat()

    if showDisplay {
        // Log to stderr so it doesn't pollute stdout (display uses stdout)
        fputs(String(format: "[BEAT] %.1f BPM\n", bpm), stderr)
    } else {
        print(String(format: "[BEAT] %.1f BPM", bpm))
    }
}

// Energy level change → MIDI note + crossfade CC
energy.onLevelChange = { level, index in
    currentLevelName = level.name
    currentEnergyLevelIndex = index
    levelChanged     = true
    stableLevelSince = CACurrentMediaTime()

    // Note-on for scene change
    sendNoteOn(channel: level.channel,
               note: level.midiNote,
               velocity: level.velocity,
               durationMs: 50)

    // Crossfade CC — value encodes duration hint
    let cfVal = tempo.crossfadeCCValue(beats: cfg.crossfade.defaultBeats)
    midi.cc(channel: cfg.crossfade.channel,
            number: cfg.crossfade.ccNumber,
            value: cfVal)

    let msg = "[ENERGY] \(level.name.uppercased())  note=\(level.midiNote) vel=\(level.velocity)  crossfade CC\(cfg.crossfade.ccNumber)=\(cfVal)"
    if showDisplay {
        fputs(msg + "\n", stderr)
    } else {
        print(msg)
    }
}

energy.onPeakTrigger = { note, channel, velocity in
    sendNoteOn(channel: channel, note: note, velocity: velocity, durationMs: 50)
    let msg = "[PEAK] Realtime jump to peak threshold — note=\(note) vel=\(velocity)"
    if showDisplay {
        fputs(msg + "\n", stderr)
    } else {
        print(msg)
    }
}

energy.onTroughTrigger = { note, channel, velocity in
    sendNoteOn(channel: channel, note: note, velocity: velocity, durationMs: 50)
    let msg = "[TROUGH] Realtime drop to baseline threshold — note=\(note) vel=\(velocity)"
    if showDisplay {
        fputs(msg + "\n", stderr)
    } else {
        print(msg)
    }
}

// Silence begin
energy.onSilenceBegin = {
    currentLevelName = "SILENT"
    tempo.reset()
    stableLevelSince = CACurrentMediaTime()
    currentEnergyLevelIndex = -1

    sendNoteOn(channel: cfg.silence.channel,
               note: cfg.silence.midiNote,
               velocity: cfg.silence.velocity,
               durationMs: 100)

    let msg = "[SILENCE] Music stopped — reset note \(cfg.silence.midiNote) sent"
    if showDisplay {
        fputs(msg + "\n", stderr)
    } else {
        print(msg)
    }
}

// Silence end / music resumes
energy.onSilenceEnd = {
    currentLevelName = "—"
    stableLevelSince = CACurrentMediaTime()
    currentEnergyLevelIndex = -1

    sendNoteOn(channel: cfg.silence.resumeChannel,
               note: cfg.silence.resumeNote,
               velocity: cfg.silence.resumeVelocity,
               durationMs: 50)

    let msg = "[RESUME] Music detected — resume note \(cfg.silence.resumeNote) sent"
    if showDisplay {
        fputs(msg + "\n", stderr)
    } else {
        print(msg)
    }
}

// Band triggers → MIDI
bands.onTrigger = { trigger, velocity in
    sendNoteOn(channel: trigger.channel,
               note: trigger.midiNote,
               velocity: velocity,
               durationMs: cfg.bandTriggers.triggerDurationMs)
}

// Audio frame → all subsystems
audio.onFrame = { frame in
    tempo.feed(frame: frame)
    energy.feed(rms: frame.rms)
    bands.feed(bandEnergies: frame.bandEnergies)

    let now = frame.timestamp
    let dt  = max(0, now - lastFrameTimestamp)
    lastFrameTimestamp = now
    if energy.silent {
        totalSilenceTime += dt
    } else {
        totalPlayTime += dt
    }

    maybeSendEnergyCycleNote(now: now)

    display?.update(frame: frame,
                    bpm: tempo.bpm,
                    level: currentLevelName,
                    isSilent: energy.silent,
                    levelChanged: levelChanged,
                    playTime: totalPlayTime,
                    silenceTime: totalSilenceTime,
                    lastNote: lastSentNoteDesc,
                    bufferedEnergy: energy.currentBufferedEnvelope)
    levelChanged = false
}

// MARK: - Start audio

do {
    try audio.start()
} catch {
    fputs("Audio engine failed to start: \(error.localizedDescription)\n", stderr)
    fputs("Tip: grant Microphone permission in System Preferences → Security & Privacy.\n", stderr)
    exit(1)
}

if showDisplay {
    // Header already printed by TerminalDisplay init
} else {
    print("AudioMIDIBridge running. Virtual MIDI port: AudioMIDIBridge")
    print("Press Ctrl-C to quit.")
}

// MARK: - Graceful shutdown on Ctrl-C

let sigSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
signal(SIGINT, SIG_IGN)
sigSource.setEventHandler {
    print("\nShutting down…")
    audio.stop()
    midi.noteOff(channel: cfg.silence.channel, note: cfg.silence.midiNote)
    exit(0)
}
sigSource.resume()

// MARK: - Run loop

dispatchMain()
