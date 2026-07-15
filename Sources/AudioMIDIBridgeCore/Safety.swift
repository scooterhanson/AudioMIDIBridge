import Foundation

// ---------------------------------------------------------------------------
// Safety helpers
// Audio hardware occasionally delivers non-finite samples (NaN/Infinity)
// during clipping, overload, or device glitches. Swift traps (illegal
// instruction) on Int(NaN) / Int(.infinity) / UInt8(out-of-range), and those
// values can reach many call sites (MIDI velocity, display percentages,
// crossfade CC). These helpers give every conversion site the same failsafe
// instead of relying on one upstream check.
// ---------------------------------------------------------------------------

@inline(__always)
public func safeDouble(_ value: Double, fallback: Double = 0) -> Double {
    value.isFinite ? value : fallback
}

@inline(__always)
public func safeFloat(_ value: Float, fallback: Float = 0) -> Float {
    value.isFinite ? value : fallback
}

/// Converts a Double to Int, clamping to [lo, hi] and never trapping on
/// NaN/Infinity.
@inline(__always)
public func clampedInt(_ value: Double, min lo: Int = 0, max hi: Int = 127) -> Int {
    guard value.isFinite else { return lo }
    if value <= Double(lo) { return lo }
    if value >= Double(hi) { return hi }
    return Int(value)
}

/// Converts an Int to UInt8-range byte, clamping instead of trapping.
@inline(__always)
public func clampedByte(_ value: Int, min lo: Int = 0, max hi: Int = 127) -> UInt8 {
    UInt8(Swift.max(lo, Swift.min(hi, value)))
}
