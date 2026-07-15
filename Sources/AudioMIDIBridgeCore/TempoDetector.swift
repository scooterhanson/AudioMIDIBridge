import Foundation

// ---------------------------------------------------------------------------
// Tempo Detector
//
// Detects kick-drum hits (from the onset signal AudioEngine already
// restricts to the "kick" frequency band) and induces a tempo from the
// pattern of hit timestamps, refining the estimate as more hits arrive.
//
// Consecutive hits are NOT assumed to be exactly one beat apart — a kick
// that syncopates (hits off the downbeat, skips beats, doubles up) would
// make that assumption wrong on any given pair of hits. Instead, every new
// hit is compared against each recent hit still in history, and each of
// those raw intervals is folded down by small integer divisors (1–4) to
// find whatever underlying beat period it's consistent with. A syncopated
// interval that doesn't match any hypothesis on its own will still tend to
// agree with SOME other pairing from the same history window, so the true
// period keeps accumulating support even while individual consecutive
// intervals look inconsistent.
//
// Those candidate periods vote into a small set of running hypotheses,
// clustered by proximity rather than exact matching (so ordinary timing
// jitter doesn't fragment the vote across near-duplicates). The
// heaviest-weighted hypothesis is the current tempo. Two hits already give
// a rough initial estimate; more hits refine it — and since a song almost
// always holds one tempo throughout, the estimate settles and stays put
// rather than continuing to wander.
// ---------------------------------------------------------------------------

public final class TempoDetector {

    private let cfg: TempoConfig

    // Live-adjustable — mutable stored properties so the GUI's sliders take
    // effect on the very next frame, same pattern as EnergyTracker.
    public var onsetSensitivity: Double
    // How many recent kick hits the tempo estimate is built from — both how
    // far back new hits are compared against, and (via the derived decay
    // rate below) how quickly old evidence fades. Larger = slower to react
    // but steadier; since a song is almost always one tempo throughout, a
    // generous value just means it converges once and stays there.
    public var bpmSmoothingBeats: Int

    // MARK: - Onset (kick hit) detection

    private var onsetHistory: [Double] = []
    private let onsetWindowSize = 20    // local average window (frames)
    private var lastHitTime: Double = 0
    private let minHitInterval: Double  // seconds, derived from bpmMax — two hits closer than this can't both be genuine beats

    // MARK: - Hit history + tempo hypotheses

    private var hitTimestamps: [Double] = []

    private struct TempoHypothesis {
        var period: Double   // seconds
        var weight: Double
    }
    private var hypotheses: [TempoHypothesis] = []
    private static let maxHypotheses = 64

    // Selection hysteresis: the reported tempo tracks a "selected" period
    // rather than whichever hypothesis momentarily has the most weight.
    // Without this, a single syncopated hit's own freshly-added votes can
    // — for that one hit — edge out a long-established hypothesis before
    // decaying back next hit, producing a one-frame wrong-BPM blip. A
    // challenger must beat the selected period's weight by a clear margin
    // AND do so on two consecutive hits before it takes over; a genuine
    // tempo change clears that in a beat or two, but a momentary artifact
    // from one syncopated hit does not.
    private var selectedPeriod: Double?
    private var challengerPeriod: Double?
    private var challengerStreak: Int = 0
    private static let challengerMargin = 1.1
    private static let challengerStreakToSwitch = 2
    private static let hypothesisTolerance = 0.04

    private var currentBPM: Double = 0

    // Callback: fires on each detected kick hit with the current BPM estimate
    public var onBeat: ((Double) -> Void)?

    public init(cfg: TempoConfig, sampleRate: Double, hopSize: Int) {
        self.cfg = cfg
        self.minHitInterval = 60.0 / cfg.bpmMax
        self.onsetSensitivity = cfg.onsetSensitivity
        self.bpmSmoothingBeats = cfg.bpmSmoothingBeats
    }

    // MARK: - Feed

    public func feed(frame: AudioFrame) {
        let strength = frame.onsetStrength
        let now      = frame.timestamp

        onsetHistory.append(strength)
        if onsetHistory.count > onsetWindowSize * 3 {
            onsetHistory.removeFirst()
        }

        guard onsetHistory.count >= onsetWindowSize else { return }

        // Local mean and peak threshold
        let recent    = onsetHistory.suffix(onsetWindowSize)
        let localMean = recent.reduce(0, +) / Double(recent.count)
        let threshold = localMean * (1.0 + (1.0 - onsetSensitivity) * 2.0)

        // Is this a peak?
        let n = onsetHistory.count
        guard n >= 3 else { return }
        let prev = onsetHistory[n - 3]
        let curr = onsetHistory[n - 2]   // one frame behind (peak candidate)
        let next = onsetHistory[n - 1]

        let isPeak = curr > threshold && curr >= prev && curr >= next
        guard isPeak, now - lastHitTime >= minHitInterval else { return }

        lastHitTime = now
        registerHit(at: now)
    }

    public var bpm: Double { currentBPM }

    // MARK: - Tempo induction

    private func registerHit(at now: Double) {
        for previous in hitTimestamps {
            considerInterval(now - previous)
        }

        hitTimestamps.append(now)
        let maxHits = max(2, bpmSmoothingBeats)
        if hitTimestamps.count > maxHits {
            hitTimestamps.removeFirst(hitTimestamps.count - maxHits)
        }

        if updateSelection() {
            onBeat?(currentBPM)
        }
    }

    /// Re-evaluates which hypothesis is selected, applying the confidence-
    /// margin + consecutive-hit confirmation described above. Returns
    /// whether there is now a valid selection to report (false only when no
    /// hypothesis has ever been established yet, e.g. on the very first hit).
    @discardableResult
    private func updateSelection() -> Bool {
        guard let best = hypotheses.max(by: { $0.weight < $1.weight }) else { return false }

        guard let selected = selectedPeriod else {
            selectedPeriod = best.period
            currentBPM = 60.0 / best.period
            return true
        }

        if abs(best.period - selected) / selected < Self.hypothesisTolerance {
            // The incumbent is still on top — just refine its tracked
            // period from the (weighted-average-updated) hypothesis.
            selectedPeriod = best.period
            challengerPeriod = nil
            challengerStreak = 0
        } else {
            let incumbentWeight = hypotheses.first(where: { abs($0.period - selected) / selected < Self.hypothesisTolerance })?.weight ?? 0
            if best.weight > incumbentWeight * Self.challengerMargin {
                if let challenger = challengerPeriod, abs(challenger - best.period) / best.period < Self.hypothesisTolerance {
                    challengerStreak += 1
                } else {
                    challengerPeriod = best.period
                    challengerStreak = 1
                }
                if challengerStreak >= Self.challengerStreakToSwitch {
                    selectedPeriod = best.period
                    challengerPeriod = nil
                    challengerStreak = 0
                }
            } else {
                challengerPeriod = nil
                challengerStreak = 0
            }
        }

        currentBPM = 60.0 / selectedPeriod!
        return true
    }

    /// Folds one raw hit-to-hit interval down by small integer divisors to
    /// find the beat period(s) it's consistent with, and casts a weighted
    /// vote for each that falls in the configured BPM range.
    private func considerInterval(_ interval: Double) {
        let minPeriod = 60.0 / cfg.bpmMax
        let maxPeriod = cfg.bpmMin > 0 ? 60.0 / cfg.bpmMin : Double.infinity

        for divisor in 1...4 {
            let period = interval / Double(divisor)
            guard period >= minPeriod && period <= maxPeriod else { continue }
            // Prefer simpler explanations slightly: a hit-to-hit interval is
            // more likely to just BE the beat than some deep subdivision of
            // it, but subdivisions still accumulate support if reinforced.
            addVote(period: period, weight: 1.0 / Double(divisor))
        }

        // Slow decay lets the estimate adapt if the tempo genuinely
        // changes, while a steady tempo — the overwhelmingly common case —
        // just keeps reinforcing the same hypothesis faster than this
        // decays it, so it settles and stays put.
        let decay = 1.0 - 1.0 / Double(max(2, bpmSmoothingBeats))
        for i in hypotheses.indices { hypotheses[i].weight *= decay }
        hypotheses.removeAll { $0.weight < 0.01 }

        // Defensive cap: keep only the strongest hypotheses, so a stretch
        // of arrhythmic input can't grow this without bound.
        if hypotheses.count > Self.maxHypotheses {
            hypotheses.sort { $0.weight > $1.weight }
            hypotheses.removeLast(hypotheses.count - Self.maxHypotheses)
        }
    }

    /// Clusters a candidate period into whichever existing hypothesis is
    /// within ~4% of it (ordinary tempo jitter), merging as a weighted
    /// running average — so close-but-not-identical candidates reinforce
    /// one shared hypothesis instead of splitting their vote across many
    /// near-duplicate buckets.
    private func addVote(period: Double, weight: Double) {
        if let i = hypotheses.firstIndex(where: { abs($0.period - period) / period < Self.hypothesisTolerance }) {
            let total = hypotheses[i].weight + weight
            hypotheses[i].period = (hypotheses[i].period * hypotheses[i].weight + period * weight) / total
            hypotheses[i].weight = total
        } else {
            hypotheses.append(TempoHypothesis(period: period, weight: weight))
        }
    }

    // MARK: - Crossfade duration

    /// Returns the duration in seconds for the given number of beats at the
    /// current tempo. Used to compute crossfade timing. Falls back to a
    /// fixed value if BPM unknown.
    public func crossfadeDuration(beats: Int) -> Double {
        guard currentBPM > 0 else {
            return Double(beats) * (60.0 / 120.0)   // assume 120 BPM
        }
        return Double(beats) * (60.0 / currentBPM)
    }

    /// CC value (0–127) representing crossfade duration in seconds, scaled.
    /// Clamps 0–8 seconds → 0–127.
    public func crossfadeCCValue(beats: Int) -> Int {
        let seconds = crossfadeDuration(beats: beats)
        return clampedInt((seconds / 8.0) * 127)
    }

    public func reset() {
        hitTimestamps.removeAll()
        hypotheses.removeAll()
        onsetHistory.removeAll()
        currentBPM   = 0
        lastHitTime  = 0
        selectedPeriod = nil
        challengerPeriod = nil
        challengerStreak = 0
    }
}
