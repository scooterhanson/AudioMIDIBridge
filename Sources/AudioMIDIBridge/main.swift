import Foundation
import AVFoundation
import CoreMIDI
import AudioMIDIBridgeCore

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
      --gain <value>      Manual input gain multiplier (overrides config.toml input_gain)
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

private func runCalibration(cfg: AppConfig) throws {
    let result = try runCalibrationAnalysis(cfg: cfg)
    let report = formatCalibrationReport(result)

    let summaryPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("calibration_summary.txt")
    try report.write(to: summaryPath, atomically: true, encoding: .utf8)
    print(report)
    print("Calibration summary saved to: \(summaryPath.path)")
}

// MARK: - Main

var configPath  = "./config.toml"
var showDisplay = true
var calibrationMode = false
var deviceID    = ""
var gainOverride: Double? = nil
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
    case "--gain":
        if let next = args.first {
            args = args.dropFirst()
            guard let g = Double(next), g.isFinite, g > 0 else {
                fputs("Invalid --gain value: \(next) (must be a positive number)\n", stderr)
                exit(1)
            }
            gainOverride = g
        }
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

if let gainOverride {
    cfg.audio.inputGain = gainOverride
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
let energyNoteCycler = EnergyNoteCycler()
// Beats remaining until the next auto-cycle note within the current stable
// energy level; nil while silent / no level is active (cycling doesn't
// apply). Recomputed every frame in maybeSendEnergyCycleNote so it counts
// down continuously and snaps back to cycle_beats the instant a cycle note
// fires.
var cycleBeatsRemaining: Int? = nil

func sendNoteOn(channel: Int, note: Int, durationMs: Int) {
    midi.noteOnTimed(channel: channel, note: note, velocity: defaultNoteVelocity, durationMs: durationMs)
    lastSentNoteDesc = "ch\(channel) note\(note)"
}

func stableCycleThreshold(beats: Int, bpm: Double) -> Double {
    let effectiveBpm = bpm > 0 ? bpm : 120.0
    return Double(beats) * (60.0 / effectiveBpm)
}

func maybeSendEnergyCycleNote(now: Double) {
    guard !energy.silent, let level = energy.currentLevel else {
        cycleBeatsRemaining = nil
        return
    }

    let effectiveBpm   = tempo.bpm > 0 ? tempo.bpm : 120.0
    let secondsPerBeat = 60.0 / effectiveBpm
    let threshold      = Double(cfg.energy.cycleBeats) * secondsPerBeat
    if now - stableLevelSince >= threshold {
        let nextNote = energyNoteCycler.advance(for: level)
        sendNoteOn(channel: level.channel, note: nextNote, durationMs: 50)
        let msg = "[CYCLE] Stable energy level '\(level.name)' for \(cfg.energy.cycleBeats) beats — sent note \(nextNote)"
        if showDisplay {
            fputs(msg + "\n", stderr)
        } else {
            print(msg)
        }
        stableLevelSince = now
    }

    let elapsedBeats = Int((now - stableLevelSince) / secondsPerBeat)
    cycleBeatsRemaining = max(0, cfg.energy.cycleBeats - elapsedBeats)
}

// MARK: - Wire callbacks

// Beat → MIDI tap + display flash
tempo.onBeat = { bpm in
    sendNoteOn(channel: cfg.tempo.tapChannel,
               note: cfg.tempo.tapNote,
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

    // Note-on for scene change. Exactly one key-on message per entry: the
    // first-ever visit to this level plays its first configured note; a
    // level re-entered later continues from wherever its own sequence
    // last left off (see EnergyNoteCycler).
    let note = energyNoteCycler.advance(for: level)
    sendNoteOn(channel: level.channel,
               note: note,
               durationMs: 50)

    // Crossfade CC — value encodes duration hint
    let cfVal = tempo.crossfadeCCValue(beats: cfg.crossfade.defaultBeats)
    midi.cc(channel: cfg.crossfade.channel,
            number: cfg.crossfade.ccNumber,
            value: cfVal)

    let msg = "[ENERGY] \(level.name.uppercased())  note=\(note)  crossfade CC\(cfg.crossfade.ccNumber)=\(cfVal)"
    if showDisplay {
        fputs(msg + "\n", stderr)
    } else {
        print(msg)
    }
}

energy.onPeakTrigger = { note, channel in
    sendNoteOn(channel: channel, note: note, durationMs: 50)
    let msg = "[PEAK] Realtime jump to peak threshold — note=\(note)"
    if showDisplay {
        fputs(msg + "\n", stderr)
    } else {
        print(msg)
    }
}

energy.onTroughTrigger = { note, channel in
    sendNoteOn(channel: channel, note: note, durationMs: 50)
    let msg = "[TROUGH] Realtime drop to baseline threshold — note=\(note)"
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
               durationMs: 50)

    let msg = "[RESUME] Music detected — resume note \(cfg.silence.resumeNote) sent"
    if showDisplay {
        fputs(msg + "\n", stderr)
    } else {
        print(msg)
    }
}

// Band triggers → MIDI
bands.onTrigger = { trigger in
    sendNoteOn(channel: trigger.channel,
               note: trigger.midiNote,
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
                    bufferedEnergy: energy.currentBufferedEnvelope,
                    cycleBeatsRemaining: cycleBeatsRemaining)
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
