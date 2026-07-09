import Foundation
import AVFoundation
import CoreAudio
import Accelerate

// ---------------------------------------------------------------------------
// Analysis results published each hop
// ---------------------------------------------------------------------------

struct AudioFrame {
    let rms: Double                        // 0–1 overall level
    let bandEnergies: [String: Double]     // per-band RMS, 0–1
    let onsetStrength: Double              // 0–1 onset detection value
    let timestamp: Double                  // seconds (CACurrentMediaTime)
}

// ---------------------------------------------------------------------------
// Audio Engine
// ---------------------------------------------------------------------------

final class AudioEngine {

    private let cfg: AppConfig
    private let engine     = AVAudioEngine()
    private var fftSetup: FFTSetup?
    private let log2n: vDSP_Length
    private let fftSize: Int
    private let hopSize: Int

    // Ring buffer to accumulate samples between hops
    private var ringBuffer: [Float]
    private var ringWrite   = 0
    private var hopCount    = 0

    // FFT buffers
    private var window:   [Float]
    private var realBuf:  [Float]
    private var imagBuf:  [Float]
    private var magBuf:   [Float]

    // Onset detection — previous magnitude spectrum for flux
    private var prevMag: [Float]

    // Callback invoked on each analysis hop (background thread)
    var onFrame: ((AudioFrame) -> Void)?

    // Precomputed bin ranges for each frequency band
    private var bandBinRanges: [(String, Int, Int)] = []

    init(cfg: AppConfig) {
        self.cfg     = cfg
        fftSize      = cfg.audio.fftSize
        hopSize      = cfg.audio.hopSize
        log2n        = vDSP_Length(log2(Double(fftSize)))
        ringBuffer   = [Float](repeating: 0, count: fftSize * 4)
        window       = [Float](repeating: 0, count: fftSize)
        realBuf      = [Float](repeating: 0, count: fftSize / 2)
        imagBuf      = [Float](repeating: 0, count: fftSize / 2)
        magBuf       = [Float](repeating: 0, count: fftSize / 2)
        prevMag      = [Float](repeating: 0, count: fftSize / 2)

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

    func start() throws {
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

    func stop() {
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
            ringBuffer[ringWrite] = channelData[i]
            ringWrite = (ringWrite + 1) % ringBuffer.count
            hopCount += 1

            if hopCount >= hopSize {
                hopCount = 0
                analyzeFrame()
            }
        }
    }

    // MARK: - Frame analysis

    private func analyzeFrame() {
        guard let setup = fftSetup else { return }

        // Read the last `fftSize` samples from ring buffer
        var samples = [Float](repeating: 0, count: fftSize)
        let bufLen = ringBuffer.count
        let readStart = (ringWrite - fftSize + bufLen) % bufLen
        for i in 0..<fftSize {
            samples[i] = ringBuffer[(readStart + i) % bufLen]
        }

        // Apply Hann window
        vDSP_vmul(samples, 1, window, 1, &samples, 1, vDSP_Length(fftSize))

        // Compute RMS before windowing distorts it
        var rmsVal: Float = 0
        vDSP_rmsqv(samples, 1, &rmsVal, vDSP_Length(fftSize))

        // Pack into split complex and run FFT
        samples.withUnsafeBytes { rawPtr in
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

        // Magnitudes
        for i in 0..<fftSize / 2 {
            magBuf[i] = sqrtf(realBuf[i] * realBuf[i] + imagBuf[i] * imagBuf[i])
        }

        // Spectral flux onset detection (positive half-wave rectified difference)
        var flux: Float = 0
        for i in 0..<fftSize / 2 {
            let diff = magBuf[i] - prevMag[i]
            if diff > 0 { flux += diff }
        }
        // Normalise flux by bin count
        flux /= Float(fftSize / 2)

        prevMag = magBuf   // copy for next frame

        // Per-band RMS
        var bandEnergies: [String: Double] = [:]
        for (name, lo, hi) in bandBinRanges {
            let count = hi - lo + 1
            var bandRMS: Float = 0
            vDSP_rmsqv(Array(magBuf[lo...hi]), 1, &bandRMS, vDSP_Length(count))
            // Normalise by average magnitude to get 0–1-ish value
            bandEnergies[name] = Double(bandRMS) / Double(fftSize / 4)
        }

        let frame = AudioFrame(
            rms:           Double(rmsVal),
            bandEnergies:  bandEnergies,
            onsetStrength: Double(flux),
            timestamp:     CACurrentMediaTime()
        )

        onFrame?(frame)
    }
}

// MARK: - Device Listing Helper

func listAudioInputDevices() {
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
