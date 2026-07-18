import Foundation
import QuartzCore
import CoreMIDI

// ---------------------------------------------------------------------------
// MIDI Output
// Creates a CoreMIDI virtual source named "AudioMIDIBridge".
// Any DAW or MIDI-routing app (e.g. Ableton, QLab, MainStage) can
// subscribe to this virtual port as a MIDI input.
// ---------------------------------------------------------------------------

public final class MIDIOutput {

    /// Name of the virtual CoreMIDI source this app creates. There's no
    /// config option to pick a different one — every UI (CLI, GUI) should
    /// reference this constant rather than a hardcoded string.
    public static let virtualSourceName = "AudioMIDIBridge"

    private var client: MIDIClientRef  = 0
    private var outPort: MIDIPortRef   = 0
    private var endpoint: MIDIEndpointRef = 0

    // Pending note-offs: (time to fire, channel, note)
    private var pendingNoteOffs: [(fireAt: Double, channel: Int, note: Int)] = []
    private var noteOffTimer: DispatchSourceTimer?
    private let noteOffQueue = DispatchQueue(label: "midi.noteoffs", qos: .userInteractive)

    /// Fires after the virtual endpoint has been transparently recreated
    /// following a CoreMIDI setup change that actually invalidated it (e.g.
    /// the system `midiserver` daemon restarting) — never for ordinary
    /// setup changes like some unrelated MIDI device being plugged in,
    /// which also generate a setup-changed notification but leave this
    /// endpoint perfectly valid. Recovery itself is automatic either way;
    /// this exists purely so the app can surface a "MIDI reconnected"
    /// notice, since a DAW/lighting console on the other end may need to
    /// re-select the port.
    public var onReconnect: (() -> Void)?

    public init() throws {
        // MIDINotifyProc is a C function pointer (`@convention(c)`), so it
        // can't capture `self` — instead, `self` is smuggled through as the
        // opaque refCon and reconstructed inside the callback via
        // Unmanaged. Safe to take here: every stored property above already
        // has a default value, so `self` is fully initialized the moment
        // this initializer's body starts running.
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        var status = MIDIClientCreate(Self.virtualSourceName as CFString, { notification, refCon in
            guard let refCon, notification.pointee.messageID == .msgSetupChanged else { return }
            Unmanaged<MIDIOutput>.fromOpaque(refCon).takeUnretainedValue().handleSetupChanged()
        }, selfPtr, &client)
        guard status == noErr else { throw MIDIError.clientFailed(status) }

        status = MIDISourceCreate(client, Self.virtualSourceName as CFString, &endpoint)
        guard status == noErr else { throw MIDIError.sourceFailed(status) }

        startNoteOffTimer()
    }

    deinit {
        noteOffTimer?.cancel()
        if endpoint != 0 { MIDIEndpointDispose(endpoint) }
        if client   != 0 { MIDIClientDispose(client) }
    }

    // MARK: - Setup-change recovery

    /// A `kMIDIMsgSetupChanged` notification fires for almost any MIDI
    /// system change (plugging in an unrelated USB MIDI keyboard triggers
    /// one too), so this only actually recreates the endpoint if it's
    /// genuinely gone stale — a cheap property read distinguishes "some
    /// other device changed" from "midiserver restarted and dropped our
    /// virtual source." Blindly recreating on every notification would
    /// needlessly disconnect anything already subscribed to this port.
    private func handleSetupChanged() {
        guard client != 0, !isEndpointValid() else { return }

        if endpoint != 0 { MIDIEndpointDispose(endpoint) }
        endpoint = 0
        guard MIDISourceCreate(client, Self.virtualSourceName as CFString, &endpoint) == noErr else { return }

        let callback = onReconnect
        DispatchQueue.main.async { callback?() }
    }

    private func isEndpointValid() -> Bool {
        guard endpoint != 0 else { return false }
        var name: Unmanaged<CFString>?
        return MIDIObjectGetStringProperty(endpoint, kMIDIPropertyName, &name) == noErr
    }

    // MARK: - Note On/Off

    // Failsafe: whatever produced these values (config, live energy/velocity
    // calculations upstream) may still hand us something out of MIDI's 0–127
    // range. Clamp here as the last line of defense — this is the point
    // where an out-of-range value would otherwise trap on UInt8 conversion.
    public func noteOn(channel: Int, note: Int, velocity: Int) {
        send(status: 0x90 | clampedByte(channel - 1, min: 0, max: 15),
             d1: clampedByte(note), d2: clampedByte(velocity))
    }

    public func noteOff(channel: Int, note: Int) {
        send(status: 0x80 | clampedByte(channel - 1, min: 0, max: 15),
             d1: clampedByte(note), d2: 0)
    }

    /// Send a note-on and schedule automatic note-off after `durationMs`
    public func noteOnTimed(channel: Int, note: Int, velocity: Int, durationMs: Int) {
        noteOn(channel: channel, note: note, velocity: velocity)
        let fireAt = CACurrentMediaTime() + Double(durationMs) / 1000.0
        noteOffQueue.async { [weak self] in
            self?.pendingNoteOffs.append((fireAt: fireAt, channel: channel, note: note))
        }
    }

    // MARK: - Control Change

    public func cc(channel: Int, number: Int, value: Int) {
        send(status: 0xB0 | clampedByte(channel - 1, min: 0, max: 15),
             d1: clampedByte(number), d2: clampedByte(value))
    }

    // MARK: - Raw send

    private func send(status: UInt8, d1: UInt8, d2: UInt8) {
        var packet  = MIDIPacket()
        packet.timeStamp = 0   // immediate
        packet.length    = 3
        packet.data.0    = status
        packet.data.1    = d1
        packet.data.2    = d2

        var packetList      = MIDIPacketList()
        packetList.numPackets = 1
        packetList.packet     = packet

        MIDIReceived(endpoint, &packetList)
    }

    // MARK: - Note-off timer

    private func startNoteOffTimer() {
        let timer = DispatchSource.makeTimerSource(queue: noteOffQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(5))
        timer.setEventHandler { [weak self] in
            self?.processPendingNoteOffs()
        }
        timer.resume()
        noteOffTimer = timer
    }

    private func processPendingNoteOffs() {
        let now = CACurrentMediaTime()
        var remaining: [(fireAt: Double, channel: Int, note: Int)] = []
        for entry in pendingNoteOffs {
            if now >= entry.fireAt {
                noteOff(channel: entry.channel, note: entry.note)
            } else {
                remaining.append(entry)
            }
        }
        pendingNoteOffs = remaining
    }
}

public enum MIDIError: Error, LocalizedError {
    case clientFailed(OSStatus)
    case sourceFailed(OSStatus)
    public var errorDescription: String? {
        switch self {
        case .clientFailed(let s): return "MIDI client creation failed (OSStatus \(s))"
        case .sourceFailed(let s): return "MIDI source creation failed (OSStatus \(s))"
        }
    }
}

// MARK: - Device Listing

public func listMIDIDestinations() {
    let count = MIDIGetNumberOfDestinations()
    print("Available MIDI destinations (\(count) total):")
    for i in 0..<count {
        let dest = MIDIGetDestination(i)
        var name: Unmanaged<CFString>?
        MIDIObjectGetStringProperty(dest, kMIDIPropertyName, &name)
        let n = name?.takeRetainedValue() as String? ?? "Unknown"
        print("  [\(i)] \(n)")
    }
}
