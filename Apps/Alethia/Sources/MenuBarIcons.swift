import AppKit
import Foundation

/// Menu-bar visual states for Alethia (template images, light/dark adaptive).
enum AlethiaMenuBarIconState: Equatable, Sendable {
    case idle
    case dictating
    case meetingRecording
    case processing
}

/// Draws Alethia-branded template icons (black + alpha) for the status item.
enum AlethiaMenuBarIcon {
    /// Point size in the menu bar (retina is handled by NSImage).
    static let pointSize: CGFloat = 18

    static func image(state: AlethiaMenuBarIconState, frame: Int) -> NSImage {
        let size = NSSize(width: pointSize, height: pointSize)
        let image = NSImage(size: size, flipped: false) { rect in
            draw(in: rect, state: state, frame: max(0, frame))
            return true
        }
        image.isTemplate = true
        image.size = size
        return image
    }

    private static func draw(in rect: NSRect, state: AlethiaMenuBarIconState, frame: Int) {
        let inset = rect.insetBy(dx: 1.2, dy: 1.2)
        switch state {
        case .idle:
            drawIdle(in: inset)
        case .dictating:
            drawDictating(in: inset, frame: frame)
        case .meetingRecording:
            drawMeeting(in: inset, frame: frame)
        case .processing:
            drawProcessing(in: inset, frame: frame)
        }
    }

    // MARK: - Idle — listening arcs + speech bars (logo language)

    private static func drawIdle(in rect: NSRect) {
        let cx = rect.midX
        let cy = rect.midY + 1.2

        strokeArc(center: CGPoint(x: cx, y: cy), radius: rect.width * 0.28, lineWidth: 1.35, alpha: 0.95)
        strokeArc(center: CGPoint(x: cx, y: cy), radius: rect.width * 0.42, lineWidth: 1.2, alpha: 0.45)

        let barW = rect.width * 0.11
        let heights: [CGFloat] = [0.38, 0.58, 0.78, 0.50]
        let totalW = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * 1.15
        var x = cx - totalW / 2
        let baseY = rect.minY + rect.height * 0.18
        for h in heights {
            let hPx = rect.height * h * 0.72
            let r = NSRect(x: x, y: baseY, width: barW, height: hPx)
            NSBezierPath(roundedRect: r, xRadius: barW / 2, yRadius: barW / 2).fill()
            x += barW + 1.15
        }

        // Unveil dot
        let dot = NSBezierPath(ovalIn: NSRect(x: cx + rect.width * 0.22, y: cy + rect.height * 0.12, width: 2.4, height: 2.4))
        NSColor.black.withAlphaComponent(0.95).setFill()
        dot.fill()
    }

    // MARK: - Dictating — mic body + animated voice bars

    private static func drawDictating(in rect: NSRect, frame: Int) {
        let t = CGFloat(frame % 8) / 8
        let pulse = 0.55 + 0.45 * abs(sin(t * .pi * 2))

        // Mic capsule
        let micW = rect.width * 0.30
        let micH = rect.height * 0.42
        let mic = NSRect(
            x: rect.midX - micW / 2,
            y: rect.midY - micH * 0.15,
            width: micW,
            height: micH
        )
        NSColor.black.withAlphaComponent(0.95).setFill()
        NSBezierPath(roundedRect: mic, xRadius: micW / 2, yRadius: micW / 2).fill()

        // Stem + base
        let stem = NSBezierPath()
        stem.move(to: CGPoint(x: rect.midX, y: mic.minY))
        stem.line(to: CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.16))
        stem.lineWidth = 1.4
        stem.lineCapStyle = .round
        NSColor.black.setStroke()
        stem.stroke()

        let base = NSBezierPath()
        base.move(to: CGPoint(x: rect.midX - 3.2, y: rect.minY + rect.height * 0.16))
        base.line(to: CGPoint(x: rect.midX + 3.2, y: rect.minY + rect.height * 0.16))
        base.lineWidth = 1.4
        base.lineCapStyle = .round
        base.stroke()

        // Soft listening ring that breathes
        strokeArc(
            center: CGPoint(x: rect.midX, y: mic.midY),
            radius: rect.width * (0.34 + 0.06 * pulse),
            lineWidth: 1.25,
            alpha: 0.35 + 0.45 * pulse
        )

        // Side voice bars
        let levels: [CGFloat] = [
            0.35 + 0.55 * abs(sin((t + 0.00) * .pi * 2)),
            0.45 + 0.50 * abs(sin((t + 0.25) * .pi * 2)),
            0.30 + 0.60 * abs(sin((t + 0.50) * .pi * 2))
        ]
        let barW: CGFloat = 1.6
        let xs: [CGFloat] = [rect.minX + 1.5, rect.maxX - 3.1]
        for x in xs {
            var y = rect.midY - 5
            for (i, level) in levels.enumerated() {
                let h = 2.2 + 5.5 * level * (i == 1 ? 1.0 : 0.85)
                let r = NSRect(x: x, y: y, width: barW, height: h)
                NSColor.black.withAlphaComponent(0.55 + 0.4 * level).setFill()
                NSBezierPath(roundedRect: r, xRadius: 0.8, yRadius: 0.8).fill()
                y += h + 1.1
            }
        }
    }

    // MARK: - Meeting — record pulse + meeting waveform

    private static func drawMeeting(in rect: NSRect, frame: Int) {
        let t = CGFloat(frame % 10) / 10
        let blink = t < 0.55 ? 1.0 : 0.25

        // Outer soft ring
        let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 1.0, dy: 1.0))
        ring.lineWidth = 1.3
        NSColor.black.withAlphaComponent(0.35).setStroke()
        ring.stroke()

        // Record disc
        let discSize = rect.width * 0.34
        let disc = NSRect(
            x: rect.midX - discSize / 2,
            y: rect.midY - discSize / 2 + 0.5,
            width: discSize,
            height: discSize
        )
        NSColor.black.withAlphaComponent(0.25 + 0.75 * blink).setFill()
        NSBezierPath(ovalIn: disc).fill()

        // Mini waveform under / beside
        let barW = rect.width * 0.09
        let heights: [CGFloat] = [
            0.25 + 0.35 * abs(sin((t + 0.0) * .pi * 2)),
            0.40 + 0.45 * abs(sin((t + 0.2) * .pi * 2)),
            0.55 + 0.40 * abs(sin((t + 0.4) * .pi * 2)),
            0.35 + 0.40 * abs(sin((t + 0.6) * .pi * 2))
        ]
        let totalW = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * 1.0
        var x = rect.midX - totalW / 2
        let baseY = rect.minY + 1.2
        for h in heights {
            let hPx = max(2, rect.height * 0.28 * h)
            let r = NSRect(x: x, y: baseY, width: barW, height: hPx)
            NSColor.black.withAlphaComponent(0.75).setFill()
            NSBezierPath(roundedRect: r, xRadius: barW / 2, yRadius: barW / 2).fill()
            x += barW + 1.0
        }
    }

    // MARK: - Processing — chasing bars (transcribe)

    private static func drawProcessing(in rect: NSRect, frame: Int) {
        let phase = frame % 6
        let barW = rect.width * 0.12
        let count = 5
        let gap: CGFloat = 1.2
        let totalW = CGFloat(count) * barW + CGFloat(count - 1) * gap
        var x = rect.midX - totalW / 2
        let baseY = rect.minY + rect.height * 0.18

        for i in 0..<count {
            let dist = min((i - phase + count) % count, (phase - i + count) % count)
            let level: CGFloat
            switch dist {
            case 0: level = 0.92
            case 1: level = 0.62
            default: level = 0.32
            }
            let hPx = rect.height * (0.28 + 0.55 * level)
            let r = NSRect(x: x, y: baseY, width: barW, height: hPx)
            NSColor.black.withAlphaComponent(0.35 + 0.65 * level).setFill()
            NSBezierPath(roundedRect: r, xRadius: barW / 2, yRadius: barW / 2).fill()
            x += barW + gap
        }

        // Listening arc hint so it still reads as Alethia
        strokeArc(
            center: CGPoint(x: rect.midX, y: rect.midY + 2),
            radius: rect.width * 0.40,
            lineWidth: 1.15,
            alpha: 0.30
        )
    }

    // MARK: - Helpers

    private static func strokeArc(center: CGPoint, radius: CGFloat, lineWidth: CGFloat, alpha: CGFloat) {
        let path = NSBezierPath()
        path.appendArc(
            withCenter: center,
            radius: radius,
            startAngle: 210,
            endAngle: 330,
            clockwise: false
        )
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        NSColor.black.withAlphaComponent(alpha).setStroke()
        path.stroke()
    }
}
