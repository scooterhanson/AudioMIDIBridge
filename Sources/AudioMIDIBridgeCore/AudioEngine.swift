import Foundation
import AVFoundation
import CoreAudio
import Accelerate

// ---------------------------------------------------------------------------
// Analysis results published each hop
// ---------------------------------------------------------------------------

public struct AudioFrame {
    public let rms: Double                        // 0–1 overall level
    public let bandEnergies: [String: Double]     // per-band RMS, 0–1
    public let onsetStrength: Double              // 0–1 onset detection value
    public let timestamp: Double                  // seconds (CACurrentMediaTime)
}

// ---------------------------------------------------------------------------
// Audio Engine
// ---------------------------------------------------------------------------

public final class AudioEngine {

    private let cfg: AppConfig
    private let engine     = AVAudioEngine()
    private var fftSetup: FFTSetup?
    private let log2n: vDSP_Length
    private let fftSize: Int
    private let hopSize: Int

    // Ring buffer to accumulate samples between hops. Size is always a
    // power of two (fftSize * 4, and fftSize itself must be a power of two
    // for the FFT below), so index wraps use a bitmask instead of `%` —
    // this loop runs once per audio sample (44100+ times/sec), the hottest
    // code path in the app, where a real modulo (the compiler can't reduce
    // it to a mask itself, since `ringBuffer.count` is a runtime value) is
    // meaningfully more expensive than a mask.
    private var ringBuffer: [Float]
    private var ringMask: Int
    private var ringWrite   = 0
    private var hopCount    = 0

    // FFT buffers
    private var window:   [Float]
    private var realBuf:  [Float]
    private var imagBuf:  [Float]
    private var magBuf:   [Float]

    // Scratch buffer for the windowed analysis frame — reused every hop
    // instead of allocating a fresh array, since this is filled fully
    // before use either way.
    private var frameSamples: [Float]

    // Onset detection — previous magnitude spectrum for flux. Ping-ponged
    // with magBuf via `swap()` each frame (see analyzeFrame) rather than
    // copied, since a full-array assignment here would otherwise force a
    // copy-on-write duplication of the whole buffer right before magBuf
    // gets completely overwritten anyway.
    private var prevMag: [Float]

    // Callback invoked on each analysis hop (background thread)
    public var onFrame: ((AudioFrame) -> Void)?

    // Precomputed bin ranges for each frequency band
    private var bandBinRanges: [(String, Int, Int)] = []

    // MARK: - Gain / auto-calibration state (tap thread only)

    // Combined gain applied to raw samples: manual input_gain * auto-gain.
    private var gain: Float
    private var autoGainDone: Bool
    private var calibrationSumSq: Double = 0
    private var calibrationSampleCount: Int = 0
    private let calibrationSampleTarget: Int

    // Hard ceiling on post-gain sample magnitude. Real PCM audio lives in
    // roughly [-1, 1]; this generous headroom absorbs gain overshoot on
    // transients without letting a runaway multiplier blow up the FFT input.
    private let maxSampleMagnitude: Float = 8.0

    public init(cfg: AppConfig) {
        self.cfg     = cfg
        fftSize      = cfg.audio.fftSize
        hopSize      = cfg.audio.hopSize
        log2n        = vDSP_Length(log2(Double(fftSize)))
        ringBuffer   = [Float](repeating: 0, count: fftSize * 4)
        ringMask     = fftSize * 4 - 1
        window       = [Float](repeating: 0, count: fftSize)
        realBuf      = [Float](repeating: 0, count: fftSize / 2)
        imagBuf      = [Float](repeating: 0, count: fftSize / 2)
        magBuf       = [Float](repeating: 0, count: fftSize / 2)
        frameSamples = [Float](repeating: 0, count: fftSize)
        prevMag      = [Float](repeating: 0, count: fftSize / 2)

        gain = Float(cfg.audio.inputGain)
        autoGainDone = !cfg.audio.autoGainEnabled
        calibrationSampleTarget = max(1, Int(cfg.audio.sampleRate * Double(cfg.audio.autoGainCalibrationMs) / 1000.0))

        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(FFT_RADIX2))

        // Precompute bin indices for each band
        let sr = cfg.audio.sampleRate
        for band in cfg.frequencyBands {
            let lowBin  = max(0, Int(band.lowHz  / sr * Double(fftSize)))
            let highBin = min(fftSize / 2 - 1, Int(band.highHz / sr * Double(fftSize)))
            if lowBin <= highBin {
                bandBinRanges.append((band.name, lowBin, highBin))
            }
        }
    }

    deinit {
        if let s = fftSetup { vDSP_destroy_fftsetup(s) }
    }

    // MARK: - Start / Stop

    public func start() throws {
        // macOS uses AVAudioEngine directly; select the requested input device first.
        if !cfg.audio.inputDevice.isEmpty {
            selectInputDevice(nameOrID: cfg.audio.inputDevice)
        }

        let input = engine.inputNode

        // Install tap — AVFoundation delivers buffers on a real-time thread
        let tapFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: cfg.audio.sampleRate,
                                   channels: 1,
                                   interleaved: false)!
        input.installTap(onBus: 0, bufferSize: UInt32(hopSize * 4),
                         format: tapFmt) { [weak self] buffer, _ in
            self?.processTap(buffer: buffer)
        }

        try engine.start()
    }

    public func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    // MARK: - Device selection

    private func selectInputDevice(nameOrID: String) {
        #if os(macOS)
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInMicrophone, .externalUnknown],
            mediaType: .audio,
            position: .unspecified)
        let devices = discoverySession.devices

        if let exactMatch = devices.first(where: { $0.uniqueID == nameOrID }) {
            if setDefaultInputDevice(uniqueID: exactMatch.uniqueID) {
                return
            }
        }

        if let partialMatch = devices.first(where: { $0.localizedName.contains(nameOrID) }) {
            if setDefaultInputDevice(uniqueID: partialMatch.uniqueID) {
                return
            }
        }

        fputs("Audio input device not found: \(nameOrID). Using default input.\n", stderr)
        #else
        let session = AVAudioSession.sharedInstance()
        guard let inputs = session.availableInputs else { return }
        if let match = inputs.first(where: { $0.portName.contains(nameOrID) }) {
            try? session.setPreferredInput(match)
        }
        #endif
    }

    #if os(macOS)
    private func setDefaultInputDevice(uniqueID: String) -> Bool {
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &dataSize) == noErr else { return false }
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var deviceIDs = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &dataSize, &deviceIDs) == noErr else { return false }

        for deviceID in deviceIDs {
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var uidSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(deviceID, &uidAddress, 0, nil, &uidSize) == noErr else { continue }

            var uidBuffer = [CChar](repeating: 0, count: Int(uidSize))
            guard AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, &uidBuffer) == noErr else { continue }
            let uid = String(cString: uidBuffer)

            if uid == uniqueID {
                var selectedDevice = deviceID
                var defaultAddress = AudioObjectPropertyAddress(
                    mSelector: kAudioHardwarePropertyDefaultInputDevice,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain)
                return AudioObjectSetPropertyData(systemObject, &defaultAddress, 0, nil,
                                                  UInt32(MemoryLayout<AudioObjectID>.size), &selectedDevice) == noErr
            }
        }

        return false
    }
    #endif

    // MARK: - Tap callback (real-time thread)

    private func processTap(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameCount = Int(buffer.frameLength)

        // Feed samples into ring buffer, fire analysis every hopSize samples
        for i in 0..<frameCount {
            // Failsafe 1: hardware/driver glitches can occasionally deliver
            // non-finite samples (NaN/Infinity), especially around clipping.
            // Scrub those at the point of entry before anything downstream
            // (FFT, RMS, MIDI conversions) can be poisoned by them.
            var sample = channelData[i]
            if !sample.isFinite { sample = 0 }

            if !autoGainDone {
                accumulateAmbientCalibration(rawSample: sample)
            }

            sample *= gain
            if !sample.isFinite { sample = 0 }
            sample = max(-maxSampleMagnitude, min(maxSampleMagnitude, sample))

            ringBuffer[ringWrite] = sample
            ringWrite = (ringWrite + 1) & ringMask
            hopCount += 1

            if hopCount >= hopSize {
                hopCount = 0
                analyzeFrame()
            }
        }
    }

    // MARK: - Auto-gain calibration

    /// Measures ambient (pre-gain) noise for a short window at startup, then
    /// derives an auto-gain multiplier that normalizes that ambient level to
    /// just under the configured silence threshold. This lets a quiet or
    /// insensitive microphone behave like a properly gain-staged input
    /// without the user having to hand-tune input_gain first.
    private func accumulateAmbientCalibration(rawSample: Float) {
        calibrationSumSq += Double(rawSample * rawSample)
        calibrationSampleCount += 1
        guard calibrationSampleCount >= calibrationSampleTarget else { return }

        autoGainDone = true
        let ambientRMS = sqrt(calibrationSumSq / Double(calibrationSampleCount))
        let target = max(0.0005, cfg.audio.silenceThreshold * 0.5)

        var autoMultiplier = 1.0
        if ambientRMS > 1e-6 {
            autoMultiplier = target / ambientRMS
        } else {
            autoMultiplier = cfg.audio.autoGainMaxMultiplier
        }
        autoMultiplier = max(1.0, min(cfg.audio.autoGainMaxMultiplier, autoMultiplier))

        gain = Float(cfg.audio.inputGain * autoMultiplier)
        fputs(String(format: "[GAIN] Ambient RMS=%.5f  auto-gain=%.2fx  manual-gain=%.2fx  combined-gain=%.2fx\n",
                     ambientRMS, autoMultiplier, cfg.audio.inputGain, Double(gain)), stderr)
    }

    // MARK: - Frame analysis

    private func analyzeFrame() {
        guard let setup = fftSetup else { return }

        // Read the last `fftSize` samples from ring buffer into the reused
        // scratch buffer (every element gets overwritten below, so there's
        // no need to allocate a fresh array each hop).
        let bufLen = ringBuffer.count
        let readStart = (ringWrite - fftSize + bufLen) & ringMask
        for i in 0..<fftSize {
            frameSamples[i] = ringBuffer[(readStart + i) & ringMask]
        }

        // Compute RMS before windowing distorts it
        var rmsVal: Float = 0
        vDSP_rmsqv(frameSamples, 1, &rmsVal, vDSP_Length(fftSize))
        rmsVal = safeFloat(rmsVal)

        // Apply Hann window
        vDSP_vmul(frameSamples, 1, window, 1, &frameSamples, 1, vDSP_Length(fftSize))

        // Pack into split complex and run FFT
        frameSamples.withUnsafeBytes { rawPtr in
            realBuf.withUnsafeMutableBufferPointer { rp in
                imagBuf.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    rawPtr.withMemoryRebound(to: DSPComplex.self) { cxPtr in
                        vDSP_ctoz(cxPtr.baseAddress!, 2, &split, 1, vDSP_Length(fftSize / 2))
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                }
            }
        }

        // Ping-pong magBuf/prevMag by reference instead of copying: swap
        // first, so magBuf (now holding the two-frames-ago buffer, about to
        // be fully overwritten below anyway) becomes this frame's write
        // target, while prevMag picks up exactly last frame's magnitudes —
        // with no array copy at all, versus the `prevMag = magBuf`
        // assignment this replaced, which forced a full copy-on-write
        // duplication of the whole buffer right before it got overwritten.
        swap(&magBuf, &prevMag)

        // Magnitudes (failsafe: scrub any non-finite bin so a single bad
        // value can't propagate NaN through flux/band-energy/onward)
        for i in 0..<fftSize / 2 {
            magBuf[i] = safeFloat(sqrtf(realBuf[i] * realBuf[i] + imagBuf[i] * imagBuf[i]))
        }

        // Spectral flux onset detection (positive half-wave rectified
        // difference), restricted to the "kick" frequency band when one is
        // configured — tempo/beat tracking locks onto the kick drum
        // specifically, since it's a far more reliable four-on-the-floor
        // reference than broadband onset (which hi-hats, vocals, and other
        // transients can just as easily trigger). Falls back to the full
        // spectrum if no "kick" band is configured.
        let kickBinRange = bandBinRanges.first(where: { $0.0 == "kick" }).map { ($0.1, $0.2) }
        let loBin = kickBinRange?.0 ?? 0
        let hiBin = kickBinRange?.1 ?? (fftSize / 2 - 1)
        var flux: Float = 0
        for i in loBin...hiBin {
            let diff = magBuf[i] - prevMag[i]
            if diff > 0 { flux += diff }
        }
        // Normalise flux by bin count (of whichever range was used)
        flux = safeFloat(flux / Float(hiBin - loBin + 1))

        // Per-band RMS — read directly out of magBuf by pointer+offset
        // rather than copying each band's slice into a new temporary array.
        var bandEnergies: [String: Double] = [:]
        magBuf.withUnsafeBufferPointer { magPtr in
            for (name, lo, hi) in bandBinRanges {
                let count = hi - lo + 1
                var bandRMS: Float = 0
                vDSP_rmsqv(magPtr.baseAddress! + lo, 1, &bandRMS, vDSP_Length(count))
                // Normalise by average magnitude to get 0–1-ish value
                bandEnergies[name] = safeDouble(Double(bandRMS) / Double(fftSize / 4))
            }
        }

        // Failsafe 2: sanitize the whole frame at the analysis/consumer
        // boundary. Even if something upstream slipped through, nothing
        // downstream (EnergyTracker, TempoDetector, MIDI, display) should
        // ever see a NaN/Infinity — those are exactly the values that trap
        // Swift's Double→Int conversions used for MIDI velocities/CCs.
        let frame = AudioFrame(
            rms:           safeDouble(Double(rmsVal)),
            bandEnergies:  bandEnergies,
            onsetStrength: safeDouble(Double(flux)),
            timestamp:     CACurrentMediaTime()
        )

        onFrame?(frame)
    }
}

// MARK: - Device Listing Helper

public func listAudioInputDevices() {
    #if os(macOS)
    let defaultInput = AVCaptureDevice.default(for: .audio)
    let discoverySession = AVCaptureDevice.DiscoverySession(
        deviceTypes: [.builtInMicrophone, .externalUnknown],
        mediaType: .audio,
        position: .unspecified)
    let devices = discoverySession.devices
    print("Available audio input devices (\(devices.count) total):")
    for (i, device) in devices.enumerated() {
        let defaultMarker = device.uniqueID == defaultInput?.uniqueID ? " [default]" : ""
        print("  [\(i)] \(device.localizedName)\(defaultMarker)")
        print("       id: \(device.uniqueID)")
    }
    #else
    let session = AVAudioSession.sharedInstance()
    try? session.setCategory(.record)
    try? session.setActive(true)
    print("Available audio input devices (\(session.availableInputs?.count ?? 0) total):")
    for (i, port) in (session.availableInputs ?? []).enumerated() {
        print("  [\(i)] \(port.portName)  (\(port.portType.rawValue))")
    }
    #endif
}
