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
    AudioMIDIBridge \(appVersion) — Audio-reactive MIDI controller for macOS

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
      -v, --version       Print the version and exit
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
    case "--version", "-v":
        print("AudioMIDIBridge \(appVersion)"); exit(0)
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

let configValidation = ConfigValidator.validate(cfg)
cfg = configValidation.config
for warning in configValidation.warnings {
    fputs("[CONFIG WARNING] \(warning)\n", stderr)
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
midi.onReconnect = {
    let msg = "[MIDI] Reconnected after a system reset"
    if showDisplay { fputs(msg + "\n", stderr) } else { print(msg) }
}

/// A timestamped path next to config.toml, e.g.
/// ".../midi_events_20260718_213045.csv" — used for both the
/// continuously-written event log and the on-demand chart PNG, so every
/// session's artifacts sort together and never collide with another
/// session's.
func sessionFilePath(nextTo configPath: String, prefix: String, suffix: String) -> String {
    let dir = URL(fileURLWithPath: configPath).deletingLastPathComponent()
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd_HHmmss"
    let stamp = formatter.string(from: Date())
    return dir.appendingPathComponent("\(prefix)_\(stamp).\(suffix)").path
}

// Records every MIDI note-on for later manual chart generation (see
// ChartRenderer, invoked on graceful shutdown below) — never for live
// display. Recording is fire-and-forget and runs on its own background
// queue, so it can never affect MIDI delivery even if the CSV write fails.
let eventLog = MidiEventLog(csvPath: sessionFilePath(nextTo: configPath, prefix: "midi_events", suffix: "csv"))

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

func sendNoteOn(channel: Int, note: Int, durationMs: Int, source: String) {
    midi.noteOnTimed(channel: channel, note: note, velocity: defaultNoteVelocity, durationMs: durationMs)
    eventLog.record(note: note, channel: channel, velocity: defaultNoteVelocity, source: source)
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
        sendNoteOn(channel: level.channel, note: nextNote, durationMs: 50, source: "energy:\(level.name)")
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
               durationMs: cfg.tempo.tapDurationMs, source: "tap")
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
               durationMs: 50, source: "energy:\(level.name)")

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
    sendNoteOn(channel: channel, note: note, durationMs: 50, source: "peak")
    let msg = "[PEAK] Realtime jump to peak threshold — note=\(note)"
    if showDisplay {
        fputs(msg + "\n", stderr)
    } else {
        print(msg)
    }
}

energy.onTroughTrigger = { note, channel in
    sendNoteOn(channel: channel, note: note, durationMs: 50, source: "trough")
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
               durationMs: 100, source: "silence")

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
               durationMs: 50, source: "resume")

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
               durationMs: cfg.bandTriggers.triggerDurationMs, source: "band:\(trigger.name)")
}

// Audio frame → all subsystems
audio.onFrame = { frame in
    // Give energy the current tempo estimate and band-trigger activity
    // before feeding it, so its tempo cap and band-activity boost (see
    // EnergyConfig) both see up-to-date values — one frame stale at most,
    // same as bpm below, since bands hasn't fed this frame's bandEnergies
    // yet either. energy.feed() itself runs before tempo.feed() below so
    // its silence state is current-frame-fresh, rather than a frame stale,
    // when we decide whether to feed tempo.
    energy.bpm = tempo.bpm
    energy.bandActiveCount = bands.activeBandCount
    energy.feed(rms: frame.rms)
    // Suspend tempo tracking entirely during silence — not just a one-time
    // reset() on silence begin (see energy.onSilenceBegin above). Without
    // this, any residual noise (room hum, HVAC, reverb tail, mic
    // self-noise) can still register as a fresh onset and have
    // TempoDetector re-establish a bogus tempo and start firing onBeat
    // again, i.e. "tempo keeps tapping after the music stops."
    if !energy.silent {
        tempo.feed(frame: frame)
    }
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

// MARK: - Audio pipeline watchdog

// Checks once/sec whether onFrame has gone quiet for longer than makes
// sense while running — onFrame fires continuously regardless of musical
// silence (silence only changes what EnergyTracker does with the RMS, not
// whether frames arrive), so this only fires on a genuine pipeline failure:
// a disconnected interface, a route change AVAudioEngine didn't recover
// from, etc. Recovery attempts are cooled down separately from the 1s check
// interval so a persistent stall doesn't hammer stop()/start().
var isAudioStalled = false
var lastWatchdogRecoveryAttempt: Double = 0
let watchdogStallThreshold: Double = 3.0
let watchdogRecoveryCooldown: Double = 5.0

let watchdogSource = DispatchSource.makeTimerSource(queue: .main)
watchdogSource.schedule(deadline: .now() + 1, repeating: 1.0)
watchdogSource.setEventHandler {
    let now = CACurrentMediaTime()
    guard now - lastFrameTimestamp > watchdogStallThreshold else {
        isAudioStalled = false
        return
    }
    if !isAudioStalled {
        isAudioStalled = true
        let msg = "[WATCHDOG] No audio frames received for \(Int(watchdogStallThreshold))s — attempting recovery"
        if showDisplay { fputs(msg + "\n", stderr) } else { print(msg) }
    }
    guard now - lastWatchdogRecoveryAttempt > watchdogRecoveryCooldown else { return }
    lastWatchdogRecoveryAttempt = now
    audio.stop()
    do {
        try audio.start()
        let msg = "[WATCHDOG] Audio engine restarted"
        if showDisplay { fputs(msg + "\n", stderr) } else { print(msg) }
    } catch {
        fputs("[WATCHDOG] Recovery failed: \(error.localizedDescription)\n", stderr)
    }
}
watchdogSource.resume()

if showDisplay {
    // Header already printed by TerminalDisplay init
} else {
    print("AudioMIDIBridge running. Virtual MIDI port: AudioMIDIBridge")
    print("Press Ctrl-C to quit.")
}

// MARK: - Graceful shutdown on Ctrl-C or termination

// Handles both SIGINT (Ctrl-C, the interactive case) and SIGTERM (what a
// process supervisor or a plain `kill` sends by default) identically —
// without a SIGTERM handler, running this under any kind of supervisor
// (launchd, a show-control script, etc.) would skip this whole path
// entirely: no silence note-off, no session chart, and the event log left
// without an explicit close.
func gracefulShutdown() -> Never {
    print("\nShutting down…")
    audio.stop()
    midi.noteOff(channel: cfg.silence.channel, note: cfg.silence.midiNote)
    eventLog.close()

    // Chart generation only ever happens here, once, after the session has
    // genuinely ended (audio is already stopped) — never during the
    // performance itself. A generation failure is reported but never
    // treated as fatal; the CSV log (written continuously throughout the
    // session, independent of this) is what actually matters for failsafe
    // record-keeping.
    let entries = eventLog.entries
    if !entries.isEmpty {
        let chartPath = sessionFilePath(nextTo: configPath, prefix: "midi_timeline", suffix: "png")
        do {
            try ChartRenderer.renderTimelinePNG(entries: entries, to: chartPath)
            print("Session timeline chart saved to: \(chartPath)")
        } catch {
            fputs("Could not generate session timeline chart: \(error.localizedDescription)\n", stderr)
        }
    }
    exit(0)
}

let sigIntSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
signal(SIGINT, SIG_IGN)
sigIntSource.setEventHandler { gracefulShutdown() }
sigIntSource.resume()

let sigTermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
signal(SIGTERM, SIG_IGN)
sigTermSource.setEventHandler { gracefulShutdown() }
sigTermSource.resume()

// MARK: - Run loop

dispatchMain()
