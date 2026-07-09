import Foundation
import QuartzCore

// ---------------------------------------------------------------------------
// Terminal display — updates in-place using ANSI escape codes.
// No external dependencies.
// ---------------------------------------------------------------------------

final class TerminalDisplay {

    private let cfg: AppConfig
    private var lastBPM:         Double  = 0
    private var lastEnergy:      Double  = 0
    private var lastLevel:       String  = "—"
    private var lastSilent:      Bool    = true
    private var lastBandStrings: [String: Double] = [:]
    private var playTime:        Double  = 0
    private var silenceTime:     Double  = 0
    private var lastNoteSent:    String  = "None"
    private var lastBufferedEnergy: Double = 0
    private var startTime:       Double  = CACurrentMediaTime()
    private var beatFlash:       Bool    = false
    private var beatFlashExpiry: Double  = 0
    private var frameCount:      Int     = 0
    private let bandNames: [String]

    init(cfg: AppConfig) {
        self.cfg = cfg
        bandNames = cfg.frequencyBands.map { $0.name }

        // Move cursor to start, clear screen
        print(ansi("2J") + ansi("H"), terminator: "")
        fflush(stdout)
    }

    // MARK: - Update

    func update(frame: AudioFrame, bpm: Double, level: String,
                isSilent: Bool, levelChanged: Bool,
                playTime: Double, silenceTime: Double, lastNote: String,
                bufferedEnergy: Double) {
        frameCount += 1
        lastBPM     = bpm
        lastEnergy  = frame.rms
        lastLevel   = level
        lastSilent  = isSilent
        lastBandStrings = frame.bandEnergies
        self.playTime = playTime
        self.silenceTime = silenceTime
        self.lastNoteSent = lastNote
        self.lastBufferedEnergy = bufferedEnergy

        if beatFlash && CACurrentMediaTime() > beatFlashExpiry {
            beatFlash = false
        }

        // Redraw at ~15 fps (every 3 frames at 44100/512 ≈ 43fps analysis rate)
        if frameCount % 3 == 0 { redraw() }
    }

    func signalBeat() {
        beatFlash       = true
        beatFlashExpiry = CACurrentMediaTime() + 0.08
    }

    // MARK: - Rendering

    private func redraw() {
        let uptime = CACurrentMediaTime() - startTime
        let h = Int(uptime) / 3600
        let m = (Int(uptime) % 3600) / 60
        let s = Int(uptime) % 60

        var out = ansi("H")   // cursor home, no clear (flicker-free)

        // ── Header ─────────────────────────────────────────────────────────
        out += bold("AudioMIDIBridge") + "  "
        out += dim(String(format: "uptime %02d:%02d:%02d", h, m, s))
        out += "\n" + String(repeating: "─", count: 60) + "\n"

        // ── Status ──────────────────────────────────────────────────────────
        let statusIcon = lastSilent ? yellow("◌ SILENT") : green("● ACTIVE")
        out += "Status  : \(statusIcon)\n"

        // ── Play / Silence ───────────────────────────────────────────────────
        let playH = Int(playTime) / 3600
        let playM = (Int(playTime) % 3600) / 60
        let playS = Int(playTime) % 60
        let silenceH = Int(silenceTime) / 3600
        let silenceM = (Int(silenceTime) % 3600) / 60
        let silenceS = Int(silenceTime) % 60
        out += String(format: "Play    : %02d:%02d:%02d\n", playH, playM, playS)
        out += String(format: "Silence : %02d:%02d:%02d\n", silenceH, silenceM, silenceS)

        // ── BPM ─────────────────────────────────────────────────────────────
        let bpmStr  = lastBPM > 0 ? String(format: "%.1f BPM", lastBPM) : "—"
        let beat    = beatFlash ? yellow(" ♩") : "  "
        out += "Tempo   : \(cyan(bpmStr))\(beat)\n"

        // ── Energy ──────────────────────────────────────────────────────────
        let rmsPercent = min(100, Int(lastEnergy * 1000))
        let bar = energyBar(value: lastEnergy, width: 30)
        out += String(format: "Energy  : %@ %3d%%  %@\n",
                      bar, rmsPercent, bold(lastLevel))
        let bufferedPercent = min(100, Int(lastBufferedEnergy * 1000))
        let bufferedBar = energyBar(value: lastBufferedEnergy, width: 30)
        out += String(format: "Buffered: %@ %3d%%\n",
                      bufferedBar, bufferedPercent)

        // ── Frequency Bands ─────────────────────────────────────────────────
        out += "\n" + dim("Frequency Bands:") + "\n"
        for name in bandNames {
            let e   = lastBandStrings[name] ?? 0
            let bar = miniBar(value: min(1.0, e * 4), width: 20)
            let pct = min(100, Int(e * 400))
            out += String(format: "  %-8s %@ %3d%%\n",
                          (name as NSString).utf8String!, bar, pct)
        }

        // ── MIDI summary ────────────────────────────────────────────────────
        out += "\n" + dim("MIDI (virtual source: AudioMIDIBridge):") + "\n"
        out += "  Tap    ch\(cfg.tempo.tapChannel) note\(cfg.tempo.tapNote)\n"
        out += "  Energy ch\(cfg.energy.levels.first?.channel ?? 2) "
        let energyNotes = cfg.energy.levels.map { $0.noteListDescription }.joined(separator: " | ")
        out += "notes \(energyNotes)\n"
        out += "  Silence ch\(cfg.silence.channel) note\(cfg.silence.midiNote)\n"
        out += "  Last note: \(lastNoteSent)\n"

        // ── Footer ──────────────────────────────────────────────────────────
        out += "\n" + dim("Press Ctrl-C to quit")

        // Pad to screen width to erase leftover chars
        let lines = out.components(separatedBy: "\n")
        let padded = lines.map { line -> String in
            // Strip ANSI for length calculation
            let plain = line.replacingOccurrences(of: "\\e\\[[^m]*m",
                                                   with: "",
                                                   options: .regularExpression)
            let pad = max(0, 80 - plain.count)
            return line + String(repeating: " ", count: pad)
        }
        out = padded.joined(separator: "\n")

        print(out, terminator: "")
        fflush(stdout)
    }

    // MARK: - Bars

    private func energyBar(value: Double, width: Int) -> String {
        let filled = min(width, Int(value * Double(width) * 8))
        let chars  = filled / 8
        let remainder = filled % 8
        let blocks = ["▏","▎","▍","▌","▋","▊","▉","█"]
        var bar = String(repeating: "█", count: chars)
        if remainder > 0 && chars < width { bar += blocks[remainder - 1] }
        bar += String(repeating: "░", count: max(0, width - chars - (remainder > 0 ? 1 : 0)))

        // Colour: green → yellow → red
        if value < 0.08 { return green(bar) }
        if value < 0.20 { return yellow(bar) }
        return red(bar)
    }

    private func miniBar(value: Double, width: Int) -> String {
        let filled = min(width, Int(value * Double(width)))
        let bar    = String(repeating: "▪", count: filled) +
                     String(repeating: "·", count: max(0, width - filled))
        return value > 0.5 ? yellow(bar) : dim(bar)
    }

    // MARK: - ANSI helpers

    private func ansi(_ code: String) -> String { "\u{1B}[\(code)" }
    private func bold(_ s: String)   -> String { "\u{1B}[1m\(s)\u{1B}[0m" }
    private func dim(_ s: String)    -> String { "\u{1B}[2m\(s)\u{1B}[0m" }
    private func green(_ s: String)  -> String { "\u{1B}[32m\(s)\u{1B}[0m" }
    private func yellow(_ s: String) -> String { "\u{1B}[33m\(s)\u{1B}[0m" }
    private func red(_ s: String)    -> String { "\u{1B}[31m\(s)\u{1B}[0m" }
    private func cyan(_ s: String)   -> String { "\u{1B}[36m\(s)\u{1B}[0m" }
}
