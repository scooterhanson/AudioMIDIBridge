import Foundation
import AVFoundation

// ---------------------------------------------------------------------------
// Calibration analysis
// Analyzes a reference audio file (with labeled [[calibration.sections]])
// and recommends silence/baseline/peak thresholds. Shared by the CLI
// (--calibrate) and the GUI's Calibrate button so the analysis logic only
// lives in one place.
// ---------------------------------------------------------------------------

public enum CalibrationError: LocalizedError {
    case missingAudioFile
    case audioFileNotFound(String)
    case noCalibrationSections
    case invalidAudioData(String)
    case sectionOutOfRange(String)

    public var errorDescription: String? {
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

public struct CalibrationSectionSummary {
    public let section: CalibrationSection
    public let startSample: Int
    public let endSample: Int
    public let sampleRate: Double
    public let averageRMS: Double
    public let peak: Double

    public var startSeconds: Double { Double(startSample) / sampleRate }
    public var endSeconds: Double { Double(endSample) / sampleRate }
}

public struct CalibrationResult {
    public let audioFilePath: String
    public let fileDuration: Double
    public let sections: [CalibrationSectionSummary]
    public let recommendedSilenceThreshold: Double?
    public let recommendedBaselineThreshold: Double?
    public let recommendedPeakThreshold: Double?
    public let issues: [String]
}

public func runCalibrationAnalysis(cfg: AppConfig) throws -> CalibrationResult {
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
    var sectionSummaries: [CalibrationSectionSummary] = []

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
        sectionSummaries.append(CalibrationSectionSummary(
            section: section, startSample: startSample, endSample: endSample,
            sampleRate: format.sampleRate, averageRMS: Double(rms), peak: Double(peak)))
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

    return CalibrationResult(
        audioFilePath: audioURL.path,
        fileDuration: fileDuration,
        sections: sectionSummaries,
        recommendedSilenceThreshold: recommendedSilence,
        recommendedBaselineThreshold: recommendedBaseline,
        recommendedPeakThreshold: recommendedPeak,
        issues: issues
    )
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

/// Renders a CalibrationResult as the same human-readable report text the
/// CLI has always printed/saved. Built with string interpolation rather than
/// String(format:)'s `%s` — `%s` requires a raw C string pointer, and Swift
/// Strings (e.g. from secondsToTime) passed into it are undefined behavior.
public func formatCalibrationReport(_ result: CalibrationResult) -> String {
    var output = "Calibration Summary\n"
    output += "Audio file: \(result.audioFilePath)\n"
    output += String(format: "Duration: %.2fs\n", result.fileDuration)
    output += "\nSections:\n"

    for summary in result.sections {
        let name  = summary.section.name.padding(toLength: 20, withPad: " ", startingAt: 0)
        let start = secondsToTime(summary.startSeconds).padding(toLength: 5, withPad: " ", startingAt: 0)
        let end   = secondsToTime(summary.endSeconds).padding(toLength: 5, withPad: " ", startingAt: 0)
        let rmsPeak = String(format: "RMS=%.4f peak=%.4f", summary.averageRMS, summary.peak)
        output += " - \(name) \(start) → \(end)  \(rmsPeak)\n"
    }

    output += "\nRecommended Settings:\n"
    if let silence = result.recommendedSilenceThreshold {
        output += String(format: " - audio.silence_threshold = %.4f\n", silence)
    }
    if let baseline = result.recommendedBaselineThreshold {
        output += String(format: " - energy.baseline_threshold = %.4f\n", baseline)
    }
    if let peak = result.recommendedPeakThreshold {
        output += String(format: " - energy.peak_threshold = %.4f\n", peak)
    }
    output += "\nPotential Issues:\n"
    if result.issues.isEmpty {
        output += " - None detected. Calibration audio appears well-structured for this application.\n"
    } else {
        for issue in result.issues {
            output += " - \(issue)\n"
        }
    }
    return output
}
