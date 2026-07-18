import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

// ---------------------------------------------------------------------------
// Chart Renderer
// Draws a MIDI note-on timeline (x = time, y = note number) to a PNG file,
// using CoreGraphics/CoreText/ImageIO directly — no SwiftUI dependency, so
// both the CLI and GUI targets can call this identically. Meant to be
// invoked once, manually, after (or during a pause in) a session — never on
// a redraw loop, and never from the audio thread.
// ---------------------------------------------------------------------------

public enum ChartRenderer {
    public enum RenderError: Error, LocalizedError {
        case noEvents
        case contextCreationFailed
        case imageCreationFailed
        case writeFailed

        public var errorDescription: String? {
            switch self {
            case .noEvents:             return "No MIDI events were recorded this session."
            case .contextCreationFailed: return "Could not create the chart's drawing context."
            case .imageCreationFailed:   return "Could not finalize the chart image."
            case .writeFailed:           return "Could not write the chart PNG to disk."
            }
        }
    }

    // Fallback palette for any source not covered by triggerColor(for:)
    // below (peak/trough/resume/band:*/energy:silent) — cycled by index so
    // each still gets its own distinct, stable color.
    private static let palette: [CGColor] = [
        CGColor(red: 0.20, green: 0.47, blue: 0.85, alpha: 1),
        CGColor(red: 0.85, green: 0.33, blue: 0.20, alpha: 1),
        CGColor(red: 0.20, green: 0.70, blue: 0.35, alpha: 1),
        CGColor(red: 0.80, green: 0.60, blue: 0.10, alpha: 1),
        CGColor(red: 0.55, green: 0.30, blue: 0.80, alpha: 1),
        CGColor(red: 0.20, green: 0.70, blue: 0.75, alpha: 1),
        CGColor(red: 0.85, green: 0.35, blue: 0.60, alpha: 1),
        CGColor(red: 0.45, green: 0.45, blue: 0.45, alpha: 1),
    ]

    /// Fixed color for the trigger types that have a conventional meaning
    /// (tap tempo, silence, and the four named energy levels); nil for
    /// anything else, which falls back to the cycling `palette` above.
    /// Matched case-insensitively against `source`, consistent with how the
    /// rest of the app already matches level names (e.g. the tempo cap).
    private static func triggerColor(for source: String) -> CGColor? {
        switch source.lowercased() {
        case "tap":               return CGColor(red: 0.20, green: 0.40, blue: 0.90, alpha: 1)  // blue
        case "silence":           return CGColor(red: 0.55, green: 0.25, blue: 0.75, alpha: 1)  // purple
        case "energy:low":        return CGColor(red: 0.20, green: 0.70, blue: 0.30, alpha: 1)  // green
        case "energy:medium":     return CGColor(red: 0.90, green: 0.75, blue: 0.10, alpha: 1)  // yellow
        case "energy:high":       return CGColor(red: 0.90, green: 0.55, blue: 0.10, alpha: 1)  // orange
        case "energy:very_high":  return CGColor(red: 0.85, green: 0.15, blue: 0.15, alpha: 1)  // red
        default:                  return nil
        }
    }

    /// Renders `entries` as a scatter chart to `path`. Throws rather than
    /// silently no-oping so a manual "Generate Chart" action can report a
    /// clear failure — unlike `MidiEventLog.record`, this is never on any
    /// path that could affect live MIDI output.
    public static func renderTimelinePNG(entries: [MidiEventLogEntry], to path: String,
                                          width: Int = 1600, height: Int = 900) throws {
        guard !entries.isEmpty else { throw RenderError.noEvents }

        let marginLeft: CGFloat = 50
        let marginRight: CGFloat = 20
        let marginTop: CGFloat = 40
        let legendRows = Set(entries.map(\.source)).count
        let marginBottom: CGFloat = 50 + CGFloat(legendRows) * 16
        let plotWidth  = CGFloat(width) - marginLeft - marginRight
        let plotHeight = CGFloat(height) - marginTop - marginBottom

        guard let ctx = CGContext(data: nil, width: width, height: height,
                                   bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw RenderError.contextCreationFailed }

        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let minTime = entries.map(\.timestamp).min() ?? 0
        let maxTime = max(entries.map(\.timestamp).max() ?? 1, minTime + 1)
        let timeRange = maxTime - minTime

        func x(for t: Double) -> CGFloat {
            marginLeft + CGFloat((t - minTime) / timeRange) * plotWidth
        }
        func y(for note: Int) -> CGFloat {
            marginBottom + CGFloat(Double(note) / 127.0) * plotHeight
        }

        ctx.setStrokeColor(CGColor(red: 0.6, green: 0.6, blue: 0.6, alpha: 1))
        ctx.setLineWidth(1)
        ctx.stroke(CGRect(x: marginLeft, y: marginBottom, width: plotWidth, height: plotHeight))

        // Horizontal gridlines every octave (12 notes), labeled with the
        // MIDI note number.
        ctx.setStrokeColor(CGColor(red: 0.88, green: 0.88, blue: 0.88, alpha: 1))
        var noteGrid = 0
        while noteGrid <= 127 {
            let yy = y(for: noteGrid)
            ctx.move(to: CGPoint(x: marginLeft, y: yy))
            ctx.addLine(to: CGPoint(x: marginLeft + plotWidth, y: yy))
            ctx.strokePath()
            drawText("\(noteGrid)", at: CGPoint(x: marginLeft - 32, y: yy - 5), in: ctx, size: 10,
                      color: CGColor(gray: 0.4, alpha: 1))
            noteGrid += 12
        }

        // Vertical gridlines across the time range, labeled mm:ss.
        let divisions = 10
        let timeStep = timeRange / Double(divisions)
        for i in 0...divisions {
            let t = minTime + Double(i) * timeStep
            let xx = x(for: t)
            ctx.move(to: CGPoint(x: xx, y: marginBottom))
            ctx.addLine(to: CGPoint(x: xx, y: marginBottom + plotHeight))
            ctx.strokePath()
            let mins = Int(t) / 60, secs = Int(t) % 60
            drawText(String(format: "%d:%02d", mins, secs), at: CGPoint(x: xx - 14, y: marginBottom - 18),
                      in: ctx, size: 10, color: CGColor(gray: 0.4, alpha: 1))
        }

        let sources = Array(Set(entries.map(\.source))).sorted()
        func color(for source: String) -> CGColor {
            if let fixed = triggerColor(for: source) { return fixed }
            return palette[(sources.firstIndex(of: source) ?? 0) % palette.count]
        }

        for entry in entries {
            ctx.setFillColor(color(for: entry.source))
            let px = x(for: entry.timestamp)
            let py = y(for: entry.note)
            ctx.fillEllipse(in: CGRect(x: px - 2.5, y: py - 2.5, width: 5, height: 5))
        }

        // Legend, bottom-left, one row per distinct source.
        var legendY: CGFloat = 14
        for source in sources {
            ctx.setFillColor(color(for: source))
            ctx.fillEllipse(in: CGRect(x: marginLeft, y: legendY, width: 8, height: 8))
            drawText(source, at: CGPoint(x: marginLeft + 14, y: legendY - 2), in: ctx, size: 11,
                      color: CGColor(gray: 0, alpha: 1))
            legendY += 16
        }

        drawText("MIDI Note Timeline — \(entries.count) events over \(String(format: "%.0f", timeRange))s",
                  at: CGPoint(x: marginLeft, y: CGFloat(height) - 24), in: ctx, size: 14,
                  color: CGColor(gray: 0, alpha: 1))

        guard let image = ctx.makeImage() else { throw RenderError.imageCreationFailed }

        let url = URL(fileURLWithPath: path)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw RenderError.writeFailed
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw RenderError.writeFailed }
    }

    private static func drawText(_ text: String, at point: CGPoint, in ctx: CGContext, size: CGFloat, color: CGColor) {
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: color,
        ]
        // A label that fails to construct is a cosmetic loss (one missing
        // axis tick or legend entry) — not worth losing the whole chart
        // render over, so skip it rather than force-unwrap.
        guard let attrString = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary) else {
            return
        }
        let line = CTLineCreateWithAttributedString(attrString)
        ctx.textPosition = point
        CTLineDraw(line, ctx)
    }
}
