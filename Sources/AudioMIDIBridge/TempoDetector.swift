import Foundation

// ---------------------------------------------------------------------------
// Tempo Detector
// Tracks beats via onset strength peaks, maintains a rolling BPM estimate,
// and fires a callback on each detected beat.
// ---------------------------------------------------------------------------

final class TempoDetector {

    private let cfg: TempoConfig
    private let sr:  Double     // sample rate
    private let hop: Int        // hop size in samples

    // Beat history for BPM estimation
    private var beatTimestamps: [Double] = []
    private var currentBPM: Double = 0

    // Onset peak-picking state
    private var onsetHistory: [Double] = []
    private let onsetWindowSize = 20    // local average window (frames)
    private var lastBeatTime: Double    = 0
    private let minBeatInterval: Double  // seconds, derived from bpmMax

    // Smoothed BPM output
    private var bpmHistory: [Double] = []
    private var beatsSinceTempoUpdate: Int = 0

    // Callback: fires on each detected beat with current BPM estimate
    var onBeat: ((Double) -> Void)?     // BPM at time of beat

    init(cfg: TempoConfig, sampleRate: Double, hopSize: Int) {
        self.cfg = cfg
        self.sr  = sampleRate
        self.hop = hopSize
        self.minBeatInterval = 60.0 / cfg.bpmMax
    }

    // MARK: - Feed

    func feed(frame: AudioFrame) {
        let strength = frame.onsetStrength
        let now      = frame.timestamp

        onsetHistory.append(strength)
        if onsetHistory.count > onsetWindowSize * 3 {
            onsetHistory.removeFirst()
        }

        guard onsetHistory.count >= onsetWindowSize else { return }

        // Local mean and peak threshold
        let recent   = onsetHistory.suffix(onsetWindowSize)
        let localMean = recent.reduce(0, +) / Double(recent.count)
        let threshold = localMean * (1.0 + (1.0 - cfg.onsetSensitivity) * 2.0)

        // Is this a peak?
        let n = onsetHistory.count
        guard n >= 3 else { return }
        let prev  = onsetHistory[n - 3]
        let curr  = onsetHistory[n - 2]   // one frame behind (peak candidate)
        let next  = onsetHistory[n - 1]

        let isPeak = curr > threshold && curr >= prev && curr >= next

        if isPeak && (now - lastBeatTime) >= minBeatInterval {
            lastBeatTime = now
            beatTimestamps.append(now)

            // Keep only the last N beats for BPM calculation
            let maxBeats = max(cfg.bpmSmoothingBeats, cfg.tempoChangeBeats) + 1
            if beatTimestamps.count > maxBeats {
                beatTimestamps.removeFirst(beatTimestamps.count - maxBeats)
            }

            let bpm = estimateBPM()
            if bpm > 0 {
                bpmHistory.append(bpm)
                if bpmHistory.count > cfg.bpmSmoothingBeats {
                    bpmHistory.removeFirst()
                }
                let smoothedBPM = bpmHistory.reduce(0, +) / Double(bpmHistory.count)
                beatsSinceTempoUpdate += 1

                if currentBPM <= 0 || beatsSinceTempoUpdate >= cfg.tempoChangeBeats {
                    currentBPM = smoothedBPM
                    beatsSinceTempoUpdate = 0
                }

                onBeat?(currentBPM)
            }
        }
    }

    var bpm: Double { currentBPM }
    var lastBeatTimestamp: Double { lastBeatTime }

    // MARK: - BPM Estimation

    private func estimateBPM() -> Double {
        guard beatTimestamps.count >= 2 else { return 0 }
        var intervals: [Double] = []
        for i in 1..<beatTimestamps.count {
            intervals.append(beatTimestamps[i] - beatTimestamps[i-1])
        }

        // Filter plausible intervals
        let minIv = 60.0 / cfg.bpmMax
        let maxIv = 60.0 / cfg.bpmMin
        let valid  = intervals.filter { $0 >= minIv && $0 <= maxIv }

        // Also check half/double-time intervals
        var candidates: [Double] = []
        for iv in valid {
            let bpm = 60.0 / iv
            candidates.append(bpm)
            // Consider half-time
            if bpm / 2 >= cfg.bpmMin { candidates.append(bpm / 2) }
            // Consider double-time
            if bpm * 2 <= cfg.bpmMax { candidates.append(bpm * 2) }
        }

        guard !candidates.isEmpty else { return currentBPM }

        // Prefer candidates close to the current tempo to avoid half/double-time jitter
        if currentBPM > 0 {
            let nearby = candidates.filter { abs($0 - currentBPM) <= 15 }
            if !nearby.isEmpty {
                candidates = nearby
            }
        }

        // Median
        let sorted = candidates.sorted()
        let median = sorted[sorted.count / 2]
        return median
    }

    // MARK: - Crossfade duration

    /// Returns the duration in seconds for one bar (4 beats) at current BPM.
    /// Used to compute crossfade timing. Falls back to a fixed value if BPM unknown.
    func crossfadeDuration(beats: Int) -> Double {
        guard currentBPM > 0 else {
            return Double(beats) * (60.0 / 120.0)   // assume 120 BPM
        }
        return Double(beats) * (60.0 / currentBPM)
    }

    /// CC value (0–127) representing crossfade duration in seconds, scaled.
    /// Clamps 0–8 seconds → 0–127.
    func crossfadeCCValue(beats: Int) -> Int {
        let seconds = crossfadeDuration(beats: beats)
        return min(127, max(0, Int((seconds / 8.0) * 127)))
    }

    func reset() {
        beatTimestamps.removeAll()
        bpmHistory.removeAll()
        onsetHistory.removeAll()
        currentBPM   = 0
        lastBeatTime = 0
    }
}
