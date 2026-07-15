import Foundation

/// Chooses which MIDI note to play from an energy level's `midiNotes` list.
///
/// Both "a level was just entered" and "the level has stayed stable long
/// enough to auto-cycle" go through the same `advance(for:)` call — there
/// is exactly one rule: always move to the note *after* whichever one this
/// level last played, remembered per level name for as long as this cycler
/// lives (i.e. the whole running session; entering other levels or passing
/// through silence in between does not reset it).
///
/// A level's first-ever visit naturally lands on note index 0: there is no
/// remembered previous index yet, so advancing from -1 wraps to 0. Every
/// later call for that same level — whether from re-entering it after
/// visiting other levels, or from remaining in it long enough to
/// auto-cycle — continues from wherever its sequence last left off.
///
/// Example: level "medium" has midiNotes [1, 2, 3], "high" has [4, 5].
/// Enter medium → note 1 (index -1+1=0). Stay long enough to auto-cycle →
/// note 2 (index 1). Switch to high (first visit) → note 4 (index 0).
/// Switch back to medium → note 3 (index 1+1=2, continuing from where
/// medium left off, not restarting at note 1). Stay long enough to
/// auto-cycle → note 1 again (index 2+1=3, wraps to 0).
public final class EnergyNoteCycler {
    private var lastIndexByLevelName: [String: Int] = [:]

    public init() {}

    @discardableResult
    public func advance(for level: EnergyLevel) -> Int {
        let count = max(1, level.midiNotes.count)
        let next = ((lastIndexByLevelName[level.name] ?? -1) + 1) % count
        lastIndexByLevelName[level.name] = next
        return level.note(at: next)
    }
}
