import Foundation
import QuartzCore

// ---------------------------------------------------------------------------
// MIDI Event Log
// Records every note-on sent during a session, for later manual chart
// generation (see ChartRenderer) — never for live/continuous display. This
// is an event log (one entry per MIDI send, at most a few dozen/sec even in
// a busy passage), not a per-audio-frame recorder, so its cost is
// negligible next to the FFT work already running at ~86Hz regardless.
// ---------------------------------------------------------------------------

/// One recorded MIDI note-on. `timestamp` is seconds since the log was
/// created (session start), not wall-clock time, so charts don't need
/// timezone/date handling.
public struct MidiEventLogEntry {
    public let timestamp: Double
    public let note: Int
    public let channel: Int
    public let velocity: Int
    public let source: String

    public init(timestamp: Double, note: Int, channel: Int, velocity: Int, source: String) {
        self.timestamp = timestamp
        self.note = note
        self.channel = channel
        self.velocity = velocity
        self.source = source
    }
}

/// Recording is fire-and-forget from the caller's perspective: `record`
/// returns immediately, with the actual append (and optional CSV write)
/// happening asynchronously on a dedicated background queue — it can never
/// block the audio thread that's sending the actual MIDI. If the CSV file
/// can't be opened or written, recording silently continues in-memory only;
/// a failed log must never be allowed to affect anything upstream of it,
/// least of all the live MIDI signal.
public final class MidiEventLog {
    private let queue = DispatchQueue(label: "com.audiomidibridge.eventlog", qos: .utility)
    private let startTime: Double
    private var storedEntries: [MidiEventLogEntry] = []
    private var fileHandle: FileHandle?
    // Once a write fails (disk full, permissions revoked, log volume
    // ejected mid-set), stop trying — recording continues in-memory only.
    // Retrying every subsequent event would just repeat the same failure
    // for no benefit.
    private var fileWriteFailed = false

    /// - Parameter csvPath: if provided, every recorded event is also
    ///   appended to this file immediately, so the file is a complete,
    ///   crash-safe record of the session as it happens — not something
    ///   that only gets written on a clean "export" action.
    public init(csvPath: String? = nil) {
        startTime = CACurrentMediaTime()
        if let csvPath {
            FileManager.default.createFile(atPath: csvPath, contents: nil)
            fileHandle = FileHandle(forWritingAtPath: csvPath)
            writeToFile(Data("timestamp_sec,note,channel,velocity,source\n".utf8))
        }
    }

    public func record(note: Int, channel: Int, velocity: Int, source: String) {
        let entry = MidiEventLogEntry(timestamp: CACurrentMediaTime() - startTime,
                                       note: note, channel: channel, velocity: velocity, source: source)
        queue.async { [weak self] in
            guard let self else { return }
            self.storedEntries.append(entry)
            let line = "\(entry.timestamp),\(entry.note),\(entry.channel),\(entry.velocity),\(entry.source)\n"
            self.writeToFile(Data(line.utf8))
        }
    }

    /// `FileHandle.write(_:)` (the non-throwing overload) can raise an
    /// uncaught Objective-C exception on I/O failure — Swift's try/catch
    /// can't catch that, so it would crash the whole process, taking live
    /// MIDI output down with it. The throwing `write(contentsOf:)` overload
    /// avoids that entirely; any failure here degrades to "logging stops,"
    /// never "the app dies." Always called on `queue`.
    private func writeToFile(_ data: Data) {
        guard !fileWriteFailed, let fileHandle else { return }
        do {
            try fileHandle.write(contentsOf: data)
        } catch {
            fileWriteFailed = true
        }
    }

    /// A snapshot of everything recorded so far. Safe to call from any
    /// thread; briefly blocks on the recording queue for a consistent read,
    /// so avoid calling this from the audio thread itself.
    public var entries: [MidiEventLogEntry] {
        queue.sync { storedEntries }
    }

    public func close() {
        queue.sync {
            try? fileHandle?.close()
            fileHandle = nil
        }
    }
}
