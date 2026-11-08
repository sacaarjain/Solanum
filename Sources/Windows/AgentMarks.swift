import CCanvas
import Foundation

/// What a tab shows before its title, as on the Mac: a coding agent's mark and status, a file tab's file icon, or else
/// Solanum's prompt.
enum TabIcon {
    case prompt
    case agent(AgentInfo)
    /// A file tab's icon (Segoe Fluent Icons), as its sub-tab shows, and its file's name for the icon pack's.
    case file(UInt16, name: String?)
}

/// Coding agents' marks, drawn as the Mac draws them (AgentKind.drawMark there): Claude Code's coral ✳, Antigravity's
/// blue ✦, OpenAI's mark for Codex in the theme's text color, and sparkles in the accent for the rest.
enum AgentMarks {
    /// The mark's side at 100% scale, as the Mac's (AgentInfo.markSide).
    static let side: Float = 14

    static let claude: UInt32 = 0xD97857
    static let antigravity: UInt32 = 0x4D8CF7

    /// A four-pointed star, on a 24-unit square: ✦.
    private static let star = "M12 0L14.6 9.4L24 12L14.6 14.6L12 24L9.4 14.6L0 12L9.4 9.4Z"
    /// A large four-pointed star and a small one, on a 24-unit square, as SF Symbols' "sparkles" has.
    private static let sparkles = "M9 3L10.9 10.1L18 12L10.9 13.9L9 21L7.1 13.9L0 12L7.1 10.1Z M19 0L20.1 2.9L23 4L20.1 5.1L19 8L17.9 5.1L15 4L17.9 2.9Z"

    static func draw(_ kind: AgentKind, on canvas: Canvas, in r: UIRect, scale: Float, alpha: Float = 1) {
        switch kind {
        case .claude:
            drawAsterisk(on: canvas, in: r, color: claude, alpha: alpha)
        case .antigravity:
            fill(star, on: canvas, in: r, color: antigravity, alpha: alpha)
        case .codex, .other("astra"):
            fill(AgentKind.openAIPath, on: canvas, in: r, color: TerminalPalette.foreground, alpha: alpha)
        case .other:
            fill(sparkles, on: canvas, in: r, color: TerminalPalette.accent, alpha: alpha)
        }
    }

    /// SVG path data on a 24-unit square, filling `r`.
    private static func fill(_ path: String, on canvas: Canvas, in r: UIRect, color: UInt32, alpha: Float) {
        path.withCString { sol_canvas_fill_svg_path(canvas.raw, $0, r.x, r.y, min(r.width, r.height) / 24, color, alpha) }
    }

    /// ✳, the eight-spoked asterisk Claude Code shows: four bold strokes through the middle, with round ends, filling
    /// the square as the Mac's glyph does (sized by its ink).
    private static func drawAsterisk(on canvas: Canvas, in r: UIRect, color: UInt32, alpha: Float) {
        let c = canvas.raw, cx = r.x + r.width / 2, cy = r.y + r.height / 2
        let thickness = r.width * 0.2, reach = r.width / 2 - thickness / 2
        for k in 0..<4 {
            let angle = Float(k) * .pi / 4, dx = cos(angle) * reach, dy = sin(angle) * reach
            sol_canvas_line(c, cx - dx, cy - dy, cx + dx, cy + dy, color, alpha, thickness)
            sol_canvas_fill_ellipse(c, cx - dx, cy - dy, thickness / 2, thickness / 2, color, alpha)
            sol_canvas_fill_ellipse(c, cx + dx, cy + dy, thickness / 2, thickness / 2, color, alpha)
        }
    }
}
