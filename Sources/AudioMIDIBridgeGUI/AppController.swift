import Foundation
import QuartzCore
import AudioMIDIBridgeCore

/// One completed energy-level period, for the history panel.
struct LevelHistoryEntry: Identifiable {
    let id = UUID()
    let levelName: String
    let midiNote: Int
    let duration: Double   // seconds
}

/// Result of a calibration run, ready for display in an alert/sheet.
struct CalibrationOutcome: Identifiable {
    let id = UUID()
    let reportText: String
    let recommendedSilence: Double?
    let recommendedBaseline: Double?
    let recommendedPeak: Double?
    let errorMessage: String?
}

/// Orchestrates the same audio → MIDI pipeline as the CLI (AudioEngine,
/// EnergyTracker, TempoDetector, BandTriggerTracker, MIDIOutput), but
/// publishes state for SwiftUI instead of writing to a terminal, and
/// exposes live-adjustable thresholds + save/revert/calibrate actions.
final class AppController: ObservableObject {

    let configPath: String

    // Config snapshots. `savedConfig` mirrors what's on disk (as of last
    // load/save/revert); `liveConfig` mirrors the current slider positions
    // and is what gets written out on Save.
    @Published private(set) var savedConfig: AppConfig
    @Published private(set) var liveConfig: AppConfig
    @Published private(set) var hasUnsavedChanges = false

    // Live meters / status. Plain (not @Published) since they're all
    // written together, once per audio frame (~86Hz at the default
    // hop_size/sample_rate), from the single batched `objectWillChange.send()`
    // in `audio.onFrame` below — as separate `@Published` properties each
    // would fire its own `objectWillChange`, quadrupling the number of
    // full-tree SwiftUI re-renders per frame for no benefit, since they
    // always change together anyway.
    private(set) var realtimeEnergy: Double = 0
    private(set) var bufferedEnergy: Double = 0
    @Published private(set) var currentLevelName: String = "—"
    private(set) var isSilent = true
    @Published private(set) var bpm: Double = 0
    // Decays from 1 toward 0 after each beat — drives the active energy
    // level's threshold slider pulsing red. Deliberately NOT event-driven
    // (no "pulse now" trigger + per-row local animation state to reset):
    // a `pulseTimer` recomputes this continuously from elapsed wall-clock
    // time, so every view reading it always gets a fresh, correct value
    // straight from this one source of truth. There is nothing here that
    // an individual slider row could fail to reset — the row has no state
    // of its own to get stuck.
    @Published private(set) var pulseIntensity: Double = 0
    private(set) var playTime: Double = 0
    private(set) var silenceTime: Double = 0
    // Beats remaining until the next auto-cycle note within the current
    // stable energy level; nil while silent / no level is active. Counts
    // down continuously and snaps back to cycle_beats the instant a cycle
    // note fires — see the onFrame closure below.
    private(set) var cycleBeatsRemaining: Int?
    @Published private(set) var lastNoteDescription: String = "None"
    @Published private(set) var history: [LevelHistoryEntry] = []
    @Published private(set) var startupError: String?
    @Published private(set) var tuningRecommendations: [String] = []

    // True while the Advanced tab is showing — listening/processing is
    // paused so edits there land on a value that can't be yanked out from
    // under them mid-edit by a live audio callback, and so Save always
    // writes down exactly what the user is looking at.
    @Published private(set) var isPaused = false

    // Calibration
    @Published var isCalibrating = false
    @Published var calibrationOutcome: CalibrationOutcome?

    private var audio: AudioEngine?
    private var midi: MIDIOutput?
    private var tempo: TempoDetector?
    private var energy: EnergyTracker?
    private var bandTriggers: BandTriggerTracker?

    // Plain scalar copies of values the wireCallbacks closures below read on
    // every firing, read from the audio thread. Deliberately NOT read from
    // `liveConfig` there — liveConfig is an AppConfig value type with
    // arrays (energy.levels, frequencyBands, ...), and mutating one part of
    // it from the main thread (a text-field edit) while another thread
    // reads a different part isn't just a torn scalar read, it can race the
    // arrays' copy-on-write refcounting. Plain scalars have no such hazard,
    // matching how EnergyTracker/TempoDetector expose their own
    // live-adjustable scalars instead of a shared config struct. Without
    // these, editing e.g. the silence note in the GUI would silently do
    // nothing until a restart, since the closures below originally read
    // straight from the `cfg` snapshot captured once at `start()`.
    private var crossfadeDefaultBeats: Int = 4
    private var crossfadeCcNumber: Int = 20
    private var crossfadeChannel: Int = 2
    private var tapNote: Int = 60
    private var tapChannel: Int = 1
    private var silenceMidiNote: Int = 127
    private var silenceChannel: Int = 2
    private var silenceResumeNote: Int = 126
    private var silenceResumeChannel: Int = 2

    private var lastFrameTimestamp: Double = CACurrentMediaTime()
    private var currentLevelStartedAt: Double = CACurrentMediaTime()
    private var currentHistoryLevelName: String?
    private var currentHistoryLevelNote: Int = -1

    // Pulse timing: `lastBeatTime` is written from the audio thread's beat
    // callback (main-thread-dispatched, like everything else there);
    // `pulseTimer` runs on the main run loop and only ever reads it there,
    // so no synchronization beyond the existing main-thread dispatch needed.
    private var lastBeatTime: Double = 0
    private var pulseTimer: Timer?
    private static let pulseDecayDuration: Double = 0.4

    // Rapid-cycling detection: audio-thread-only, touched exclusively from
    // recordLevelChange (itself only ever called from the audio thread via
    // the energy/silence callbacks below) — no cross-thread access, unlike
    // the @Published state it occasionally triggers an update of.
    private var recentLevelChangeTimestamps: [Double] = []
    private static let rapidCyclingWindow: Double = 2.0
    private static let rapidCyclingThreshold = 2

    // Energy-level note sequencing: `energyNoteCycler` remembers each
    // level's last-played note index for the life of the session (see
    // EnergyNoteCycler); `stableLevelSince` times how long the level has
    // been unchanged, so audio.onFrame can auto-cycle to the next note
    // after cfg.energy.cycleBeats, exactly like entering the level does.
    private let energyNoteCycler = EnergyNoteCycler()
    private var stableLevelSince: Double = CACurrentMediaTime()

    init() {
        // Optional positional config path, e.g. `AudioMIDIBridgeGUI /path/to/config.toml`.
        // Always resolved to an absolute path — a GUI app's working
        // directory isn't reliably the project directory (Finder launches,
        // double-clicking the binary, etc. don't set it the way a Terminal
        // session does), and Save/Revert need a path that stays correct
        // regardless of how the app was launched.
        let args = CommandLine.arguments.dropFirst()
        configPath = Self.resolveConfigPath(argument: args.first)

        let cfg: AppConfig
        do {
            cfg = try ConfigParser.load(from: configPath)
        } catch {
            cfg = ConfigParser.loadDefault()
        }
        savedConfig = cfg
        liveConfig  = cfg
    }

    /// Resolves the config path to use, always as an absolute path:
    /// 1. An explicit argument, expanded/standardized to absolute.
    /// 2. `config.toml` in the current working directory, if it exists
    ///    there (preserves the familiar `swift run` / Terminal workflow).
    /// 3. `config.toml` next to the running executable, if it exists there
    ///    (covers Finder launches and the `dist/` folder convention, where
    ///    the binary and config.toml are shipped side by side).
    /// 4. Falls back to the current-working-directory form even if absent,
    ///    so the existing "couldn't load, using defaults" messaging still
    ///    names a sensible path — just an absolute one.
    private static func resolveConfigPath(argument: String?) -> String {
        let fm = FileManager.default

        if let argument {
            let expanded = (argument as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded).standardizedFileURL.path
        }

        let cwdCandidate = URL(fileURLWithPath: "config.toml").standardizedFileURL
        if fm.fileExists(atPath: cwdCandidate.path) {
            return cwdCandidate.path
        }

        let exeURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let exeDir = exeURL.deletingLastPathComponent()
        let sideBySideCandidate = exeDir.appendingPathComponent("config.toml").standardizedFileURL
        if fm.fileExists(atPath: sideBySideCandidate.path) {
            return sideBySideCandidate.path
        }

        // Running from inside a proper .app bundle, the executable lives at
        // AudioMIDIBridgeGUI.app/Contents/MacOS/AudioMIDIBridgeGUI — the
        // sideBySideCandidate check above looks inside Contents/MacOS/,
        // which isn't where a user would keep a live-edited config.toml.
        // Also check next to the .app bundle itself (writing into the
        // signed bundle wouldn't be appropriate for a file Save rewrites).
        if let bundleDir = enclosingAppBundleDirectory(for: exeURL) {
            let bundleSideBySide = bundleDir.appendingPathComponent("config.toml").standardizedFileURL
            if fm.fileExists(atPath: bundleSideBySide.path) {
                return bundleSideBySide.path
            }
        }

        return cwdCandidate.path
    }

    /// If `executableURL` is inside a `.app` bundle, returns the directory
    /// *containing* that bundle; otherwise nil.
    private static func enclosingAppBundleDirectory(for executableURL: URL) -> URL? {
        var url = executableURL.deletingLastPathComponent()
        while url.pathComponents.count > 1 {
            if url.pathExtension == "app" {
                return url.deletingLastPathComponent()
            }
            url = url.deletingLastPathComponent()
        }
        return nil
    }

    // MARK: - Lifecycle

    func start() {
        let cfg = liveConfig
        crossfadeDefaultBeats = cfg.crossfade.defaultBeats
        crossfadeCcNumber = cfg.crossfade.ccNumber
        crossfadeChannel = cfg.crossfade.channel
        tapNote = cfg.tempo.tapNote
        tapChannel = cfg.tempo.tapChannel
        silenceMidiNote = cfg.silence.midiNote
        silenceChannel = cfg.silence.channel
        silenceResumeNote = cfg.silence.resumeNote
        silenceResumeChannel = cfg.silence.resumeChannel

        do {
            midi = try MIDIOutput()
        } catch {
            startupError = "MIDI init failed: \(error.localizedDescription)"
            return
        }

        let tempo   = TempoDetector(cfg: cfg.tempo, sampleRate: cfg.audio.sampleRate, hopSize: cfg.audio.hopSize)
        let energy  = EnergyTracker(cfg: cfg.energy, silenceCfg: cfg.silence,
                                     silenceThreshold: cfg.audio.silenceThreshold,
                                     silenceHoldoff: cfg.audio.silenceHoldoffFrames,
                                     sampleRate: cfg.audio.sampleRate, hopSize: cfg.audio.hopSize)
        let bands   = BandTriggerTracker(cfg: cfg.bandTriggers, sampleRate: cfg.audio.sampleRate, hopSize: cfg.audio.hopSize)
        let audio   = AudioEngine(cfg: cfg)

        self.tempo = tempo
        self.energy = energy
        self.bandTriggers = bands
        self.audio = audio

        wireCallbacks(cfg: cfg)
        startPulseTimer()

        do {
            try audio.start()
        } catch {
            startupError = "Audio engine failed to start: \(error.localizedDescription). Grant Microphone access in System Settings → Privacy & Security."
        }
    }

    /// Recomputes `pulseIntensity` from elapsed time since the last beat,
    /// ~30 times/sec. Runs continuously (not just while a level is active)
    /// — cheap, and simpler than starting/stopping in sync with silence.
    private func startPulseTimer() {
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let elapsed = CACurrentMediaTime() - self.lastBeatTime
            self.pulseIntensity = max(0, 1.0 - elapsed / Self.pulseDecayDuration)
        }
        RunLoop.main.add(timer, forMode: .common)
        pulseTimer = timer
    }

    func stop() {
        pulseTimer?.invalidate()
        pulseTimer = nil
        audio?.stop()
        midi?.noteOff(channel: liveConfig.silence.channel, note: liveConfig.silence.midiNote)
    }

    /// Stops audio capture (and thus all downstream energy/tempo/band
    /// processing) while the Advanced tab is open — edits there should
    /// land on a config the audio thread isn't concurrently reading. Also
    /// stops the pulse timer: its 30Hz `@Published` write otherwise forces
    /// the *entire* view tree (both tabs, since `ContentView`'s `TabView`
    /// always constructs both branches) to re-render continuously even
    /// while sitting idle on Advanced, which is what was pegging the CPU
    /// and making typing/focus/scrolling on that tab feel laggy.
    func pauseProcessing() {
        guard !isPaused else { return }
        isPaused = true
        audio?.stop()
        midi?.noteOff(channel: liveConfig.silence.channel, note: liveConfig.silence.midiNote)
        pulseTimer?.invalidate()
        pulseTimer = nil
        pulseIntensity = 0
    }

    /// Resumes audio capture and the pulse timer when navigating back to
    /// the Levels tab.
    func resumeProcessing() {
        guard isPaused else { return }
        isPaused = false
        do {
            try audio?.start()
        } catch {
            startupError = "Audio engine failed to resume: \(error.localizedDescription)"
        }
        startPulseTimer()
    }

    private func sendNoteOn(channel: Int, note: Int, durationMs: Int) {
        midi?.noteOnTimed(channel: channel, note: note, velocity: defaultNoteVelocity, durationMs: durationMs)
        let desc = "ch\(channel) note\(note)"
        DispatchQueue.main.async { [weak self] in self?.lastNoteDescription = desc }
    }

    private func wireCallbacks(cfg: AppConfig) {
        guard let tempo, let energy, let bandTriggers, let audio else { return }

        tempo.onBeat = { [weak self] bpm in
            guard let self else { return }
            self.sendNoteOn(channel: self.tapChannel, note: self.tapNote, durationMs: cfg.tempo.tapDurationMs)
            DispatchQueue.main.async {
                self.bpm = bpm
                self.lastBeatTime = CACurrentMediaTime()
            }
        }

        energy.onLevelChange = { [weak self] level, _ in
            guard let self else { return }
            // Exactly one key-on message per entry: a level's first-ever
            // visit this session plays its first configured note; a level
            // re-entered later continues from wherever its own sequence
            // last left off (see EnergyNoteCycler).
            let note = self.energyNoteCycler.advance(for: level)
            self.stableLevelSince = CACurrentMediaTime()
            self.sendNoteOn(channel: level.channel, note: note, durationMs: 50)
            // Read the live scalar copy (not the captured `cfg` snapshot,
            // and not `liveConfig` directly — see crossfadeDefaultBeats'
            // declaration) so its slider takes effect without a restart.
            let cfVal = tempo.crossfadeCCValue(beats: self.crossfadeDefaultBeats)
            self.midi?.cc(channel: self.crossfadeChannel, number: self.crossfadeCcNumber, value: cfVal)
            self.recordLevelChange(newName: level.name, newNote: note)
            DispatchQueue.main.async { self.currentLevelName = level.name }
        }

        energy.onPeakTrigger = { [weak self] note, channel in
            self?.sendNoteOn(channel: channel, note: note, durationMs: 50)
        }
        energy.onTroughTrigger = { [weak self] note, channel in
            self?.sendNoteOn(channel: channel, note: note, durationMs: 50)
        }

        energy.onSilenceBegin = { [weak self] in
            guard let self else { return }
            tempo.reset()
            self.stableLevelSince = CACurrentMediaTime()
            self.sendNoteOn(channel: self.silenceChannel, note: self.silenceMidiNote, durationMs: 100)
            self.recordLevelChange(newName: nil, newNote: -1)
            DispatchQueue.main.async { self.currentLevelName = "SILENT"; self.isSilent = true }
        }
        energy.onSilenceEnd = { [weak self] in
            guard let self else { return }
            self.stableLevelSince = CACurrentMediaTime()
            self.sendNoteOn(channel: self.silenceResumeChannel, note: self.silenceResumeNote, durationMs: 50)
            DispatchQueue.main.async { self.currentLevelName = "—"; self.isSilent = false }
        }

        bandTriggers.onTrigger = { [weak self] trigger in
            self?.sendNoteOn(channel: trigger.channel, note: trigger.midiNote,
                              durationMs: cfg.bandTriggers.triggerDurationMs)
        }

        audio.onFrame = { [weak self] frame in
            guard let self else { return }
            tempo.feed(frame: frame)
            energy.feed(rms: frame.rms)
            bandTriggers.feed(bandEnergies: frame.bandEnergies)

            let now = frame.timestamp
            let dt = max(0, now - self.lastFrameTimestamp)
            self.lastFrameTimestamp = now
            let silent = energy.silent
            let re = energy.currentEnvelope
            let be = energy.currentBufferedEnvelope

            // Auto-cycle: once this level has stayed stable for
            // cfg.energy.cycleBeats (tempo-derived), advance to its next
            // note the same way entering it did.
            var newCycleBeatsRemaining: Int? = nil
            if !silent, let level = energy.currentLevel {
                let effectiveBpm = tempo.bpm > 0 ? tempo.bpm : 120.0
                let secondsPerBeat = 60.0 / effectiveBpm
                let threshold = Double(cfg.energy.cycleBeats) * secondsPerBeat
                if now - self.stableLevelSince >= threshold {
                    let note = self.energyNoteCycler.advance(for: level)
                    self.sendNoteOn(channel: level.channel, note: note, durationMs: 50)
                    self.stableLevelSince = now
                }
                let elapsedBeats = Int((now - self.stableLevelSince) / secondsPerBeat)
                newCycleBeatsRemaining = max(0, cfg.energy.cycleBeats - elapsedBeats)
            }

            DispatchQueue.main.async {
                // One `objectWillChange.send()` for all five — see the
                // property declarations for why these aren't `@Published`.
                self.objectWillChange.send()
                self.realtimeEnergy = re
                self.bufferedEnergy = be
                self.isSilent = silent
                self.cycleBeatsRemaining = newCycleBeatsRemaining
                if silent { self.silenceTime += dt } else { self.playTime += dt }
            }
        }
    }

    /// Pushes a completed history entry for whatever level was active
    /// before this transition, then starts timing the new one. Passing
    /// `newName: nil` marks entry into silence (no new level to time yet).
    private func recordLevelChange(newName: String?, newNote: Int) {
        let now = CACurrentMediaTime()
        if let previousName = currentHistoryLevelName {
            let entry = LevelHistoryEntry(levelName: previousName, midiNote: currentHistoryLevelNote,
                                           duration: now - currentLevelStartedAt)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.history.insert(entry, at: 0)
                if self.history.count > 5 { self.history.removeLast() }
            }
        }
        currentLevelStartedAt = now
        currentHistoryLevelName = newName
        currentHistoryLevelNote = newNote

        checkForRapidCycling(at: now)
    }

    /// If buffered energy has changed level more than
    /// `rapidCyclingThreshold` times within the trailing
    /// `rapidCyclingWindow` seconds, the configured levels/hysteresis
    /// aren't accommodating the input — surface concrete tuning tips
    /// rather than just letting it keep flickering silently.
    private func checkForRapidCycling(at now: Double) {
        recentLevelChangeTimestamps.append(now)
        recentLevelChangeTimestamps.removeAll { now - $0 > Self.rapidCyclingWindow }
        guard recentLevelChangeTimestamps.count > Self.rapidCyclingThreshold else { return }

        // Reset the window so we don't re-fire on every single subsequent
        // transition while still cycling — wait for a fresh burst instead.
        recentLevelChangeTimestamps.removeAll()

        let tips = buildTuningRecommendations()
        DispatchQueue.main.async { [weak self] in
            self?.tuningRecommendations = tips
        }
    }

    /// Reads live tracker state (audio-thread-safe: same access pattern as
    /// `feed()` itself — see `crossfadeDefaultBeats`'s note on why this
    /// reads `energy`'s own properties rather than `liveConfig`).
    private func buildTuningRecommendations() -> [String] {
        var tips: [String] = [
            "Buffered energy is switching levels more than \(Self.rapidCyclingThreshold) times in \(Int(Self.rapidCyclingWindow))s — the configured levels may not fit how this input actually moves."
        ]

        if let hysteresis = energy?.hysteresis {
            tips.append(String(format: "Increase Hysteresis (currently %.4f) so a level must be cleared by a bigger margin before switching.", hysteresis))
        }
        if let release = energy?.releaseFrames {
            tips.append("Increase Release (frames) (currently \(release)) so the energy envelope decays more slowly instead of dipping back across a boundary.")
        }

        // Gaps/overlaps are structurally impossible under the current model
        // (each level's max is always the next level's min), so the
        // relevant thing to flag now is a level that's too NARROW — if its
        // width is smaller than hysteresis can work with, buffered energy
        // will pass straight through it without hysteresis ever getting a
        // chance to hold it in place.
        if let levels = energy?.levels, let hysteresis = energy?.hysteresis, levels.count >= 2 {
            for i in 0..<(levels.count - 1) {
                let current = levels[i]
                let next = levels[i + 1]
                let width = next.minRMS - current.minRMS
                guard width < hysteresis * 2 else { continue }
                let widthText = String(format: "%.4f", width)
                let rangeText = String(format: "%.4f–%.4f", current.minRMS, next.minRMS)
                tips.append("'\(current.name.capitalized)' is only \(widthText) wide (\(rangeText)) — narrower than 2× Hysteresis, so buffered energy passing through it barely registers before switching again. Consider spacing '\(current.name.capitalized)' and '\(next.name.capitalized)' thresholds further apart, or lowering Hysteresis.")
            }
        }

        if let bufferMs = energy?.bufferDurationMs {
            tips.append("Increase Buffer Duration (currently \(bufferMs)ms) to average out short transient spikes before they reach the level decision.")
        }
        return tips
    }

    func dismissTuningRecommendations() {
        tuningRecommendations = []
    }

    // MARK: - Live threshold edits (called from slider bindings)

    func setSilenceThreshold(_ value: Double) {
        liveConfig.audio.silenceThreshold = value
        energy?.silenceThreshold = value
        hasUnsavedChanges = true
    }

    func setBaselineThreshold(_ value: Double) {
        liveConfig.energy.baselineThreshold = value
        energy?.baselineThreshold = value
        hasUnsavedChanges = true
    }

    func setPeakThreshold(_ value: Double) {
        liveConfig.energy.peakThreshold = value
        energy?.peakThreshold = value
        hasUnsavedChanges = true
    }

    /// Sets a level's lower boundary, clamped so it can never cross its
    /// neighbors' thresholds — this is what makes gaps/overlaps impossible
    /// to create from the slider, not just from the underlying model.
    /// `index` 0 ("silent") has no slider and is never called with this.
    func setLevelThreshold(index: Int, value: Double) {
        guard liveConfig.energy.levels.indices.contains(index) else { return }
        var clamped = value
        if index > 0 {
            clamped = max(clamped, liveConfig.energy.levels[index - 1].minRMS)
        }
        if index + 1 < liveConfig.energy.levels.count {
            clamped = min(clamped, liveConfig.energy.levels[index + 1].minRMS)
        }
        liveConfig.energy.levels[index] = liveConfig.energy.levels[index].withMinRMS(clamped)
        energy?.levels = liveConfig.energy.levels
        hasUnsavedChanges = true
    }

    // MARK: - Energy level MIDI mapping (Advanced tab)

    /// Sets one note within a level's existing `midiNotes` list — dropdowns
    /// only retune the notes a level already has, they don't add/remove
    /// slots (changing how many notes a level cycles through is a rarer,
    /// structural edit better made by hand in config.toml).
    func setLevelNote(index: Int, noteIndex: Int, note: Int) {
        guard liveConfig.energy.levels.indices.contains(index) else { return }
        var notes = liveConfig.energy.levels[index].midiNotes
        guard notes.indices.contains(noteIndex) else { return }
        notes[noteIndex] = note
        let level = liveConfig.energy.levels[index]
        liveConfig.energy.levels[index] = EnergyLevel(name: level.name, minRMS: level.minRMS, midiNotes: notes,
                                                       channel: level.channel)
        energy?.levels = liveConfig.energy.levels
        hasUnsavedChanges = true
    }

    func setLevelChannel(index: Int, channel: Int) {
        guard liveConfig.energy.levels.indices.contains(index) else { return }
        let level = liveConfig.energy.levels[index]
        liveConfig.energy.levels[index] = EnergyLevel(name: level.name, minRMS: level.minRMS, midiNotes: level.midiNotes,
                                                       channel: channel)
        energy?.levels = liveConfig.energy.levels
        hasUnsavedChanges = true
    }

    func setHysteresis(_ value: Double) {
        liveConfig.energy.hysteresis = value
        energy?.hysteresis = value
        hasUnsavedChanges = true
    }

    func setAttackFrames(_ value: Int) {
        liveConfig.energy.attackFrames = value
        energy?.attackFrames = value
        hasUnsavedChanges = true
    }

    func setReleaseFrames(_ value: Int) {
        liveConfig.energy.releaseFrames = value
        energy?.releaseFrames = value
        hasUnsavedChanges = true
    }

    func setBufferDurationMs(_ value: Int) {
        liveConfig.energy.bufferDurationMs = value
        energy?.bufferDurationMs = value
        hasUnsavedChanges = true
    }

    func setBpmSmoothingBeats(_ value: Int) {
        liveConfig.tempo.bpmSmoothingBeats = value
        tempo?.bpmSmoothingBeats = value
        hasUnsavedChanges = true
    }

    func setOnsetSensitivity(_ value: Double) {
        liveConfig.tempo.onsetSensitivity = value
        tempo?.onsetSensitivity = value
        hasUnsavedChanges = true
    }

    func setCrossfadeDefaultBeats(_ value: Int) {
        liveConfig.crossfade.defaultBeats = value
        crossfadeDefaultBeats = value
        hasUnsavedChanges = true
    }

    func setCrossfadeCcNumber(_ value: Int) {
        liveConfig.crossfade.ccNumber = value
        crossfadeCcNumber = value
        hasUnsavedChanges = true
    }

    func setCrossfadeChannel(_ value: Int) {
        liveConfig.crossfade.channel = value
        crossfadeChannel = value
        hasUnsavedChanges = true
    }

    func setBandTriggerThreshold(index: Int, value: Double) {
        guard liveConfig.bandTriggers.bands.indices.contains(index) else { return }
        liveConfig.bandTriggers.bands[index] = liveConfig.bandTriggers.bands[index].withThreshold(value)
        bandTriggers?.bands = liveConfig.bandTriggers.bands
        hasUnsavedChanges = true
    }

    func setBandTriggerMidiNote(index: Int, note: Int) {
        guard liveConfig.bandTriggers.bands.indices.contains(index) else { return }
        let band = liveConfig.bandTriggers.bands[index]
        liveConfig.bandTriggers.bands[index] = BandTrigger(name: band.name, threshold: band.threshold, midiNote: note,
                                                            channel: band.channel)
        bandTriggers?.bands = liveConfig.bandTriggers.bands
        hasUnsavedChanges = true
    }

    func setBandTriggerChannel(index: Int, channel: Int) {
        guard liveConfig.bandTriggers.bands.indices.contains(index) else { return }
        let band = liveConfig.bandTriggers.bands[index]
        liveConfig.bandTriggers.bands[index] = BandTrigger(name: band.name, threshold: band.threshold, midiNote: band.midiNote,
                                                            channel: channel)
        bandTriggers?.bands = liveConfig.bandTriggers.bands
        hasUnsavedChanges = true
    }

    func setBandTriggersEnabled(_ value: Bool) {
        liveConfig.bandTriggers.enabled = value
        bandTriggers?.enabled = value
        hasUnsavedChanges = true
    }

    // MARK: - Tempo tap / peak / trough / silence MIDI mapping (text-field tab)

    func setTapNote(_ value: Int) {
        liveConfig.tempo.tapNote = value
        tapNote = value
        hasUnsavedChanges = true
    }

    func setTapChannel(_ value: Int) {
        liveConfig.tempo.tapChannel = value
        tapChannel = value
        hasUnsavedChanges = true
    }

    func setPeakNote(_ value: Int) {
        liveConfig.energy.peakNote = value
        energy?.peakNote = value
        hasUnsavedChanges = true
    }

    func setPeakChannel(_ value: Int) {
        liveConfig.energy.peakChannel = value
        energy?.peakChannel = value
        hasUnsavedChanges = true
    }

    func setTroughNote(_ value: Int) {
        liveConfig.energy.troughNote = value
        energy?.troughNote = value
        hasUnsavedChanges = true
    }

    func setTroughChannel(_ value: Int) {
        liveConfig.energy.troughChannel = value
        energy?.troughChannel = value
        hasUnsavedChanges = true
    }

    // MARK: - Save / Revert

    func save() {
        do {
            try ConfigFileWriter.save(liveConfig, to: configPath)
            savedConfig = liveConfig
            hasUnsavedChanges = false
        } catch {
            startupError = "Save failed: \(error.localizedDescription)"
        }
    }

    func revert() {
        let cfg: AppConfig
        do {
            cfg = try ConfigParser.load(from: configPath)
        } catch {
            cfg = savedConfig
        }
        liveConfig = cfg
        savedConfig = cfg
        energy?.silenceThreshold = cfg.audio.silenceThreshold
        energy?.baselineThreshold = cfg.energy.baselineThreshold
        energy?.peakThreshold = cfg.energy.peakThreshold
        energy?.levels = cfg.energy.levels
        energy?.hysteresis = cfg.energy.hysteresis
        energy?.attackFrames = cfg.energy.attackFrames
        energy?.releaseFrames = cfg.energy.releaseFrames
        energy?.bufferDurationMs = cfg.energy.bufferDurationMs
        energy?.peakNote = cfg.energy.peakNote
        energy?.peakChannel = cfg.energy.peakChannel
        energy?.troughNote = cfg.energy.troughNote
        energy?.troughChannel = cfg.energy.troughChannel
        tempo?.bpmSmoothingBeats = cfg.tempo.bpmSmoothingBeats
        tempo?.onsetSensitivity = cfg.tempo.onsetSensitivity
        tapNote = cfg.tempo.tapNote
        tapChannel = cfg.tempo.tapChannel
        crossfadeDefaultBeats = cfg.crossfade.defaultBeats
        crossfadeCcNumber = cfg.crossfade.ccNumber
        crossfadeChannel = cfg.crossfade.channel
        silenceMidiNote = cfg.silence.midiNote
        silenceChannel = cfg.silence.channel
        silenceResumeNote = cfg.silence.resumeNote
        silenceResumeChannel = cfg.silence.resumeChannel
        bandTriggers?.bands = cfg.bandTriggers.bands
        bandTriggers?.enabled = cfg.bandTriggers.enabled
        hasUnsavedChanges = false
    }

    // MARK: - Calibration

    func runCalibration() {
        isCalibrating = true
        let cfg = liveConfig
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let outcome: CalibrationOutcome
            do {
                let result = try runCalibrationAnalysis(cfg: cfg)
                let report = formatCalibrationReport(result)
                outcome = CalibrationOutcome(reportText: report,
                                              recommendedSilence: result.recommendedSilenceThreshold,
                                              recommendedBaseline: result.recommendedBaselineThreshold,
                                              recommendedPeak: result.recommendedPeakThreshold,
                                              errorMessage: nil)
            } catch {
                outcome = CalibrationOutcome(reportText: "", recommendedSilence: nil,
                                              recommendedBaseline: nil, recommendedPeak: nil,
                                              errorMessage: error.localizedDescription)
            }
            DispatchQueue.main.async {
                self.isCalibrating = false
                self.calibrationOutcome = outcome
            }
        }
    }

    /// Applies the recommended thresholds from a calibration run — this is
    /// the "current settings may be lost" step the confirmation dialog warns
    /// about. Values still need Save to persist to config.toml.
    func applyCalibrationRecommendations(_ outcome: CalibrationOutcome) {
        if let silence = outcome.recommendedSilence { setSilenceThreshold(silence) }
        if let baseline = outcome.recommendedBaseline { setBaselineThreshold(baseline) }
        if let peak = outcome.recommendedPeak { setPeakThreshold(peak) }
    }
}
