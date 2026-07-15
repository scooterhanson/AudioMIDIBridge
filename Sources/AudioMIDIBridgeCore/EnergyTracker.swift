import Foundation

// ---------------------------------------------------------------------------
// Energy Tracker
// Maintains a smoothed RMS envelope and fires callbacks when the energy
// level crosses a configured threshold boundary.
// ---------------------------------------------------------------------------

public final class EnergyTracker {

    private let cfg: EnergyConfig
    private let silenceCfg: SilenceConfig
    private let silenceHoldoff: Int

    // Live-adjustable thresholds. Exposed as mutable stored properties
    // (rather than buried in an immutable `cfg`) so a UI can drag a slider
    // and have it take effect on the very next audio frame — no restart,
    // no engine rebuild.
    public var levels: [EnergyLevel]
    public var baselineThreshold: Double
    public var peakThreshold: Double
    public var silenceThreshold: Double
    public var hysteresis: Double
    public var attackFrames: Int
    public var releaseFrames: Int

    // The note/channel sent on peak/trough triggers — previously baked into
    // the immutable `cfg` below, so editing them had no effect until a
    // restart. Live now, same pattern as everything else here.
    public var peakNote: Int
    public var peakChannel: Int
    public var troughNote: Int
    public var troughChannel: Int

    // Also live-adjustable, but resizing the averaging window means
    // reallocating the ring buffer below — unlike the plain scalars above,
    // that can't just be written from any thread. `feed()` (always on the
    // audio thread) notices when this differs from what the buffer was
    // last sized for and does the actual reallocation itself, so the array
    // is only ever touched from the one thread that owns it.
    public var bufferDurationMs: Int
    private var appliedBufferDurationMs: Int
    private let sampleRateHz: Double
    private let hopSizeSamples: Int

    // Smoothed envelope value (realtime energy)
    private var envelope: Double = 0

    // Buffered energy average used for level decisions
    private var bufferLength: Int = 1
    private var buffer: [Double] = []
    private var bufferWrite = 0
    private var bufferCount = 0
    private var bufferSum: Double = 0
    private var bufferedEnergy: Double = 0

    // Current level index (-1 = unset)
    private var currentLevelIndex: Int = -1

    // Silence tracking
    private var silentFrameCount: Int = 0
    private var isSilent: Bool        = false

    private enum PeakState {
        case belowBaseline, between, abovePeak
    }

    private var peakState: PeakState = .between

    // Callbacks
    public var onLevelChange: ((EnergyLevel, Int) -> Void)?   // level, level index
    public var onSilenceBegin: (() -> Void)?
    public var onSilenceEnd:   (() -> Void)?
    public var onPeakTrigger: ((Int, Int) -> Void)?      // note, channel
    public var onTroughTrigger: ((Int, Int) -> Void)?

    public init(cfg: EnergyConfig, silenceCfg: SilenceConfig,
                silenceThreshold: Double, silenceHoldoff: Int,
                sampleRate: Double, hopSize: Int) {
        self.cfg              = cfg
        self.silenceCfg       = silenceCfg
        self.silenceHoldoff   = silenceHoldoff

        self.levels            = cfg.levels
        self.baselineThreshold = cfg.baselineThreshold
        self.peakThreshold     = cfg.peakThreshold
        self.silenceThreshold  = silenceThreshold
        self.hysteresis        = cfg.hysteresis
        self.attackFrames      = cfg.attackFrames
        self.releaseFrames     = cfg.releaseFrames

        self.peakNote        = cfg.peakNote
        self.peakChannel     = cfg.peakChannel
        self.troughNote      = cfg.troughNote
        self.troughChannel   = cfg.troughChannel

        self.sampleRateHz   = sampleRate
        self.hopSizeSamples = hopSize
        self.bufferDurationMs        = cfg.bufferDurationMs
        self.appliedBufferDurationMs = cfg.bufferDurationMs

        let frameMs = (Double(hopSize) / sampleRate) * 1000.0
        bufferLength = max(1, Int(Double(cfg.bufferDurationMs) / frameMs))
        buffer = [Double](repeating: 0, count: bufferLength)
    }

    // MARK: - Feed

    public func feed(rms rawRms: Double) {
        if bufferDurationMs != appliedBufferDurationMs {
            resizeBuffer(toDurationMs: bufferDurationMs)
        }

        // Failsafe: don't let a non-finite input poison the envelope, which
        // would otherwise stay NaN forever (NaN propagates through every
        // subsequent attack/release update).
        let rms = safeDouble(rawRms)

        // Attack/release envelope follower
        // (clamped to >=1: these are live-adjustable from the GUI, and a
        // 0-frame value would otherwise divide by zero into Infinity/NaN)
        if rms > envelope {
            // Attack
            let alpha = 1.0 / Double(max(1, attackFrames))
            envelope = envelope + alpha * (rms - envelope)
        } else {
            // Release
            let alpha = 1.0 / Double(max(1, releaseFrames))
            envelope = envelope + alpha * (rms - envelope)
        }

        // Maintain buffered energy average for level decisions
        if bufferCount < bufferLength {
            bufferCount += 1
        } else {
            bufferSum -= buffer[bufferWrite]
        }
        buffer[bufferWrite] = envelope
        bufferSum += envelope
        bufferWrite = (bufferWrite + 1) % bufferLength
        bufferedEnergy = bufferSum / Double(bufferCount)

        // Realtime peak/trough detection on raw envelope transitions
        let currentPeakState: PeakState
        if envelope >= peakThreshold {
            currentPeakState = .abovePeak
        } else if envelope <= baselineThreshold {
            currentPeakState = .belowBaseline
        } else {
            currentPeakState = .between
        }

        if peakState == .belowBaseline && currentPeakState == .abovePeak {
            if peakNote >= 0 {
                onPeakTrigger?(peakNote, peakChannel)
            }
        }
        if peakState == .abovePeak && currentPeakState == .belowBaseline {
            if troughNote >= 0 {
                onTroughTrigger?(troughNote, troughChannel)
            }
        }
        peakState = currentPeakState

        // Silence detection
        if envelope < silenceThreshold {
            silentFrameCount += 1
            if silentFrameCount >= silenceHoldoff && !isSilent {
                isSilent = true
                onSilenceBegin?()
            }
        } else {
            if isSilent {
                isSilent         = false
                silentFrameCount = 0
                onSilenceEnd?()
            } else {
                silentFrameCount = 0
            }
        }

        guard !isSilent else { return }

        // Find matching energy level from buffered energy
        let newIndex = levelIndex(for: bufferedEnergy)
        guard newIndex != currentLevelIndex else { return }

        // Hysteresis: require bufferedEnergy — the same value that decided
        // newIndex above, not the faster raw envelope — to clear the
        // current level's boundary by a margin before committing to a
        // change, in EITHER direction.
        if currentLevelIndex >= 0 {
            let currentMin = levels[currentLevelIndex].minRMS
            let currentMax = effectiveMaxRMS(at: currentLevelIndex)
            if newIndex < currentLevelIndex {
                guard bufferedEnergy < currentMin - hysteresis else { return }
            } else if newIndex > currentLevelIndex {
                guard bufferedEnergy >= currentMax + hysteresis else { return }
            }
        }

        currentLevelIndex = newIndex
        if newIndex >= 0 && newIndex < levels.count {
            onLevelChange?(levels[newIndex], newIndex)
        }
    }

    /// A level's effective upper bound is always the next level's minRMS —
    /// there's no independently-configured maxRMS — so levels tile [0, ∞)
    /// contiguously by construction; gaps/overlaps between adjacent levels
    /// are structurally impossible. The last level is unbounded above.
    private func effectiveMaxRMS(at index: Int) -> Double {
        index + 1 < levels.count ? levels[index + 1].minRMS : Double.infinity
    }

    private func levelIndex(for rms: Double) -> Int {
        guard !levels.isEmpty else { return -1 }
        // Levels are ordered ascending by minRMS; the matching level is the
        // last one whose minRMS the value has reached (level 0, "silent" by
        // convention, catches everything below level 1's minRMS).
        var index = 0
        for i in 1..<levels.count where rms >= levels[i].minRMS {
            index = i
        }
        return index
    }

    /// Reallocates the averaging ring buffer for a new window length.
    /// Only ever called from inside `feed()`, i.e. only from the audio
    /// thread — the buffer array itself is never touched from anywhere
    /// else, so this never races a concurrent read/write of it.
    private func resizeBuffer(toDurationMs durationMs: Int) {
        appliedBufferDurationMs = durationMs
        let frameMs = (Double(hopSizeSamples) / sampleRateHz) * 1000.0
        bufferLength = max(1, Int(Double(durationMs) / frameMs))
        buffer = [Double](repeating: 0, count: bufferLength)
        bufferWrite = 0
        bufferCount = 0
        bufferSum = 0
        bufferedEnergy = 0
    }

    public var currentEnvelope: Double { envelope }
    public var currentBufferedEnvelope: Double { bufferedEnergy }
    public var currentLevel: EnergyLevel? {
        guard currentLevelIndex >= 0 && currentLevelIndex < levels.count else { return nil }
        return levels[currentLevelIndex]
    }
    public var silent: Bool { isSilent }

    public func reset() {
        envelope          = 0
        bufferWrite       = 0
        bufferCount       = 0
        bufferSum         = 0
        bufferedEnergy    = 0
        currentLevelIndex = -1
        silentFrameCount  = 0
        isSilent          = false
        peakState         = .between
    }
}

// ---------------------------------------------------------------------------
// Band Trigger State
// Tracks per-band onset triggering with holdoff to avoid re-triggering
// ---------------------------------------------------------------------------

public final class BandTriggerTracker {

    // Live-adjustable — mutable so the GUI's per-band threshold sliders
    // take effect on the very next frame, same pattern as EnergyTracker.
    public var bands: [BandTrigger]

    // Master on/off switch — when false, no band ever fires regardless of
    // threshold, so only the energy-level triggers remain active. Also a
    // plain scalar, so it's safe to flip live from the GUI thread the same
    // way as every other live-adjustable property here.
    public var enabled: Bool

    // Maps band name → frame count since last trigger (0 = not triggered)
    private var holdoff: [String: Int] = [:]
    private let holdoffFrames: Int

    public var onTrigger: ((BandTrigger) -> Void)?

    public init(cfg: BandTriggersConfig, sampleRate: Double, hopSize: Int) {
        self.bands = cfg.bands
        self.enabled = cfg.enabled
        // Convert ms holdoff to frames
        let frameMs = (Double(hopSize) / sampleRate) * 1000.0
        holdoffFrames = max(1, Int(Double(cfg.triggerDurationMs) / frameMs))
        for band in cfg.bands { holdoff[band.name] = 0 }
    }

    public func feed(bandEnergies: [String: Double]) {
        guard enabled else { return }
        for trigger in bands {
            let energy = bandEnergies[trigger.name] ?? 0
            var ho     = holdoff[trigger.name] ?? 0

            if ho > 0 {
                ho -= 1
                holdoff[trigger.name] = ho
                continue
            }

            if energy >= trigger.threshold {
                onTrigger?(trigger)
                holdoff[trigger.name] = holdoffFrames
            }
        }
    }

    public func reset() {
        for key in holdoff.keys { holdoff[key] = 0 }
    }
}
