import Foundation

// ---------------------------------------------------------------------------
// Config Validator
// A hand-edited config.toml can contain values that are syntactically valid
// (parse fine as a number) but semantically unusable — e.g. a zero or
// negative sample_rate, or an fft_size that isn't a power of two. Several of
// those get force-unwrapped or used in trapping integer conversions deep in
// AudioEngine (AVAudioFormat's failable initializer, the FFT buffers'
// baseAddress!), so a bad value there crashes the app at launch instead of
// producing a normal, catchable error. Running everything loaded through
// ConfigParser back through here lets those get caught and replaced with a
// safe default — with a warning — instead of taking the whole app down.
// ---------------------------------------------------------------------------

public struct ConfigValidationResult {
    public let config: AppConfig
    public let warnings: [String]
}

public enum ConfigValidator {
    public static func validate(_ input: AppConfig) -> ConfigValidationResult {
        var cfg = input
        var warnings: [String] = []

        if cfg.audio.sampleRate <= 0 {
            warnings.append("audio.sample_rate (\(cfg.audio.sampleRate)) must be positive — using 44100.")
            cfg.audio.sampleRate = 44100
        }

        if cfg.audio.hopSize <= 0 {
            warnings.append("audio.hop_size (\(cfg.audio.hopSize)) must be positive — using 512.")
            cfg.audio.hopSize = 512
        }

        if cfg.audio.fftSize <= 0 || !isPowerOfTwo(cfg.audio.fftSize) {
            warnings.append("audio.fft_size (\(cfg.audio.fftSize)) must be a positive power of two — using 2048.")
            cfg.audio.fftSize = 2048
        }

        return ConfigValidationResult(config: cfg, warnings: warnings)
    }

    private static func isPowerOfTwo(_ n: Int) -> Bool {
        n > 0 && (n & (n - 1)) == 0
    }
}
