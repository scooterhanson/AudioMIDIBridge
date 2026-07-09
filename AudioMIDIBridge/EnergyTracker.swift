import Foundation

// ---------------------------------------------------------------------------
// Energy Tracker
// Maintains a smoothed RMS envelope and fires callbacks when the energy
// level crosses a configured threshold boundary.
// ---------------------------------------------------------------------------

final class EnergyTracker {

    private let cfg: EnergyConfig
    private let silenceCfg: SilenceConfig
    private let silenceThreshold: Double
    private let silenceHoldoff: Int

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
    var onLevelChange: ((EnergyLevel, Int) -> Void)?   // level, level index
    var onSilenceBegin: (() -> Void)?
    var onSilenceEnd:   (() -> Void)?
    var onPeakTrigger: ((Int, Int, Int) -> Void)?      // note, channel, velocity
    var onTroughTrigger: ((Int, Int, Int) -> Void)?

    init(cfg: EnergyConfig, silenceCfg: SilenceConfig,
         silenceThreshold: Double, silenceHoldoff: Int,
         sampleRate: Double, hopSize: Int) {
        self.cfg              = cfg
        self.silenceCfg       = silenceCfg
        self.silenceThreshold = silenceThreshold
        self.silenceHoldoff   = silenceHoldoff

        let frameMs = (Double(hopSize) / sampleRate) * 1000.0
        bufferLength = max(1, Int(Double(cfg.bufferDurationMs) / frameMs))
        buffer = [Double](repeating: 0, count: bufferLength)
    }

    // MARK: - Feed

    func feed(rms: Double) {
        // Attack/release envelope follower
        if rms > envelope {
            // Attack
            let alpha = 1.0 / Double(cfg.attackFrames)
            envelope = envelope + alpha * (rms - envelope)
        } else {
            // Release
            let alpha = 1.0 / Double(cfg.releaseFrames)
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
        if envelope >= cfg.peakThreshold {
            currentPeakState = .abovePeak
        } else if envelope <= cfg.baselineThreshold {
            currentPeakState = .belowBaseline
        } else {
            currentPeakState = .between
        }

        if peakState == .belowBaseline && currentPeakState == .abovePeak {
            if cfg.peakNote >= 0 {
                onPeakTrigger?(cfg.peakNote, cfg.peakChannel, cfg.peakVelocity)
            }
        }
        if peakState == .abovePeak && currentPeakState == .belowBaseline {
            if cfg.troughNote >= 0 {
                onTroughTrigger?(cfg.troughNote, cfg.troughChannel, cfg.troughVelocity)
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

        // Hysteresis: if moving down, require envelope to be below
        // the level's min by hysteresis margin
        if newIndex < currentLevelIndex && currentLevelIndex >= 0 {
            let currentLevel = cfg.levels[currentLevelIndex]
            if envelope > currentLevel.minRMS - cfg.hysteresis { return }
        }

        currentLevelIndex = newIndex
        if newIndex >= 0 && newIndex < cfg.levels.count {
            onLevelChange?(cfg.levels[newIndex], newIndex)
        }
    }

    private func levelIndex(for rms: Double) -> Int {
        for (i, level) in cfg.levels.enumerated() {
            if rms >= level.minRMS && rms < level.maxRMS {
                return i
            }
        }
        // Clamp to last level if above all thresholds
        return cfg.levels.isEmpty ? -1 : cfg.levels.count - 1
    }

    var currentEnvelope: Double { envelope }
    var currentBufferedEnvelope: Double { bufferedEnergy }
    var currentLevel: EnergyLevel? {
        guard currentLevelIndex >= 0 && currentLevelIndex < cfg.levels.count else { return nil }
        return cfg.levels[currentLevelIndex]
    }
    var silent: Bool { isSilent }

    func reset() {
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

final class BandTriggerTracker {

    private let cfg: BandTriggersConfig
    // Maps band name → frame count since last trigger (0 = not triggered)
    private var holdoff: [String: Int] = [:]
    private let holdoffFrames: Int

    var onTrigger: ((BandTrigger, Int) -> Void)?   // trigger, velocity 0–127

    init(cfg: BandTriggersConfig, sampleRate: Double, hopSize: Int) {
        self.cfg = cfg
        // Convert ms holdoff to frames
        let frameMs = (Double(hopSize) / sampleRate) * 1000.0
        holdoffFrames = max(1, Int(Double(cfg.triggerDurationMs) / frameMs))
        for band in cfg.bands { holdoff[band.name] = 0 }
    }

    func feed(bandEnergies: [String: Double]) {
        for trigger in cfg.bands {
            let energy = bandEnergies[trigger.name] ?? 0
            var ho     = holdoff[trigger.name] ?? 0

            if ho > 0 {
                ho -= 1
                holdoff[trigger.name] = ho
                continue
            }

            if energy >= trigger.threshold {
                let velocity = min(127, max(0, Int(energy * trigger.velocityScale * 127)))
                onTrigger?(trigger, velocity)
                holdoff[trigger.name] = holdoffFrames
            }
        }
    }

    func reset() {
        for key in holdoff.keys { holdoff[key] = 0 }
    }
}
