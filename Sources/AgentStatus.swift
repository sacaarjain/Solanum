import AppKit

// How the Mac draws coding agents on its tabs and in the sidebar: each agent's mark, and its status's dot. Which agent is
// running and what it's doing are worked out in Core/AgentState.swift, which Windows shares.

extension AgentKind {
    /// The mark as an image, for menus and Settings.
    var markImage: NSImage {
        let image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { r in
            drawMark(in: r)
            return true
        }
        image.accessibilityDescription = name
        return image
    }

    /// The agent's mark, filling `r`.
    func drawMark(in r: NSRect, alpha: CGFloat = 1) {
        func place(_ img: NSImage?, _ box: NSRect) {
            img?.draw(in: box, from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
        }
        switch self {
        case .claude:
            Self.drawGlyph("✳", color: NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: alpha), in: r)
        case .antigravity:
            Self.drawGlyph("✦", color: NSColor(srgbRed: 0.30, green: 0.55, blue: 0.97, alpha: alpha), in: r)
        case .codex, .other("astra"):
            place(AgentLogos.openAI(Config.shared.theme.foreground), r)
        case .other:
            let config = NSImage.SymbolConfiguration(pointSize: r.height, weight: .semibold).applying(.init(paletteColors: [Config.shared.theme.accent]))
            guard let img = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return }
            let scale = min(r.width / img.size.width, r.height / img.size.height)
            let w = img.size.width * scale, h = img.size.height * scale
            place(img, NSRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h))
        }
    }

    /// A character sized and centered by its ink, not its line (which would leave it small and high).
    private static func drawGlyph(_ glyph: String, color: NSColor, in r: NSRect) {
        func text(_ size: CGFloat) -> NSAttributedString {
            NSAttributedString(string: glyph, attributes: [.font: NSFont.systemFont(ofSize: size, weight: .bold), .foregroundColor: color])
        }
        func ink(_ t: NSAttributedString) -> NSRect { t.boundingRect(with: NSSize(width: 200, height: 200), options: .usesDeviceMetrics) }
        let probe = ink(text(r.height))
        let fitted = text(r.height * min(r.width / max(probe.width, 1), r.height / max(probe.height, 1)))
        let box = ink(fitted)
        // Without a line fragment, y is the baseline.
        let flipped = NSGraphicsContext.current?.isFlipped == true
        fitted.draw(with: NSRect(x: r.midX - box.midX, y: flipped ? r.midY + box.midY : r.midY - box.midY, width: 200, height: 200), options: [])
    }
}

extension AgentStatus {
    var color: NSColor {
        switch self {
        case .working: return .systemOrange
        case .waiting: return .systemPurple
        case .done: return .systemGreen
        case .failed: return .systemRed
        }
    }
}

extension AgentInfo {
    /// The mark's size, as with a tab's file icon.
    static let markSide: CGFloat = 14

    /// Mark plus a status dot, `height` tall, starting at `x`; returns the width used.
    @discardableResult
    func draw(at x: CGFloat, midY: CGFloat, height: CGFloat = markSide) -> CGFloat {
        kind.drawMark(in: NSRect(x: x, y: midY - height / 2, width: height, height: height))
        let d: CGFloat = 6
        status.color.setFill()
        NSBezierPath(ovalIn: NSRect(x: x + height + 3, y: midY - d / 2, width: d, height: d)).fill()
        return height + 3 + d
    }
}
