import AppKit

// Coding agents (Claude Code, Codex, Gemini CLI, …) running in a pane: which one, and whether it's working,
// waiting on you, done, or failed. Shown on the tab and in the file sidebar's header.
//
// Agents don't report their state to the terminal, so it's read from what they draw: each prints a
// "esc to interrupt"-style hint while working and a numbered "1. Yes" menu when asking for approval.

enum AgentKind: Equatable {
    case claude, codex, gemini
    case other(String)

    /// Command names of other terminal agents, as they appear in argv.
    private static let others = ["aider", "opencode", "cursor-agent", "amp", "goose", "crush", "qwen", "copilot", "droid", "kiro-cli", "auggie"]

    var name: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .gemini: return "Gemini"
        case .other(let n): return n.prefix(1).uppercased() + n.dropFirst()
        }
    }

    /// Identifies an agent from the foreground process: its name, executable path and arguments. Native
    /// Claude Code runs as a file named after its version (…/claude/versions/2.1.312); npm-installed agents run
    /// under node with the agent's script in argv.
    static func detect(name: String, path: String, args: [String]) -> AgentKind? {
        let words = ([name, path] + args.prefix(3)).map { ($0 as NSString).lastPathComponent.lowercased() }
        let all = ([path] + args.prefix(3)).joined(separator: " ").lowercased()
        if words.contains("claude") || path.contains("/claude/versions/") || all.contains("claude-code") { return .claude }
        if words.contains(where: { $0 == "codex" || $0.hasPrefix("codex-") }) || all.contains("@openai/codex") { return .codex }
        if words.contains("gemini") || all.contains("gemini-cli") { return .gemini }
        if let o = others.first(where: { words.contains($0) }) { return .other(o) }
        return nil
    }

    /// Claude Code sets the window title to "✳ …" when idle and a braille spinner while working, also over ssh.
    static func fromTitle(_ title: String?) -> AgentKind? {
        guard let first = title?.unicodeScalars.first else { return nil }
        return first == "✳" || (0x2800...0x28FF).contains(first.value) ? .claude : nil
    }

    /// The agent's mark, drawn centered in `r`.
    func drawMark(in r: NSRect, alpha: CGFloat = 1) {
        let color: NSColor
        let glyph: String?
        let symbol: String?
        switch self {
        case .claude: color = NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1); glyph = "✳"; symbol = nil
        case .gemini: color = NSColor(srgbRed: 0.30, green: 0.55, blue: 0.97, alpha: 1); glyph = "✦"; symbol = nil
        case .codex: color = Config.shared.theme.foreground; glyph = nil; symbol = "hexagon"
        case .other: color = Config.shared.theme.accent; glyph = nil; symbol = "sparkles"
        }
        if let glyph {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: r.height * 0.95, weight: .bold),
                                                        .foregroundColor: color.withAlphaComponent(alpha)]
            let s = (glyph as NSString).size(withAttributes: attrs)
            (glyph as NSString).draw(at: NSPoint(x: r.midX - s.width / 2, y: r.midY - s.height / 2), withAttributes: attrs)
        } else if let symbol {
            let config = NSImage.SymbolConfiguration(pointSize: r.height * 0.72, weight: .semibold)
                .applying(.init(paletteColors: [color.withAlphaComponent(alpha)]))
            if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                img.draw(in: NSRect(x: r.midX - img.size.width / 2, y: r.midY - img.size.height / 2, width: img.size.width, height: img.size.height))
            }
        }
    }
}

enum AgentStatus: Equatable {
    case working, waiting, done, failed

    var color: NSColor {
        switch self {
        case .working: return .systemOrange
        case .waiting: return .systemPurple
        case .done: return .systemGreen
        case .failed: return .systemRed
        }
    }

    var label: String {
        switch self {
        case .working: return "Working…"
        case .waiting: return "Waiting for you"
        case .done: return "Done"
        case .failed: return "Failed"
        }
    }

    /// Which pane a tab reports when several run agents: the one that most needs attention.
    var urgency: Int {
        switch self {
        case .waiting: return 3
        case .failed: return 2
        case .working: return 1
        case .done: return 0
        }
    }
}

struct AgentInfo: Equatable {
    let kind: AgentKind
    let status: AgentStatus

    var summary: String { "\(kind.name) — \(status.label)" }

    /// Mark plus a status dot, `height` tall, starting at `x`; returns the width used.
    @discardableResult
    func draw(at x: CGFloat, midY: CGFloat, height: CGFloat = 13) -> CGFloat {
        kind.drawMark(in: NSRect(x: x, y: midY - height / 2, width: height, height: height))
        let d: CGFloat = 6
        status.color.setFill()
        NSBezierPath(ovalIn: NSRect(x: x + height + 3, y: midY - d / 2, width: d, height: d)).fill()
        return height + 3 + d
    }
}

extension Terminal {
    /// Claude Code's busy line: a spinner glyph, a gerund ending in "…", then a timer, e.g.
    /// "✻ Sublimating… (1m 1s · ↓ 1.5k tokens)" or "✢ Scurrying… (43s · thought for 1s)".
    private static let spinnerLine = try? NSRegularExpression(pattern: #"^\s*[·✢✳✶✻✽*+]\s+\S.*…\s+\((\d+[hm]\s+)?\d+s\b"#)
    /// Other agents' busy hints with a running timer: "Working (5s • esc to interrupt)", "(esc to cancel, 12s)".
    private static let interruptHint = try? NSRegularExpression(pattern: #"\(\d+[hms][^)]*esc to (interrupt|cancel)|esc to (interrupt|cancel)[^)]*\d+s\)"#)
    /// The highlighted choice of an approval/question menu: "❯ 1. Yes", "› 2. No", "● 1. Yes, allow once".
    private static let selectedOption = try? NSRegularExpression(pattern: #"^\s*[❯›●▶>]\s*\d+[.)]\s+\S"#)
    private static let option = try? NSRegularExpression(pattern: #"^\s*([❯›●▶>]\s*)?\d+[.)]\s+\S"#)

    /// What the agent drawing this screen is doing. Only its live UI at the bottom of the screen is read:
    /// words like "Enter to select" also turn up in transcripts, so the checks look for the UI's shapes
    /// (a menu with a highlighted numbered option, a spinner line with a timer) rather than phrases.
    func agentScreenStatus() -> AgentStatus {
        var lines: [String] = []
        for a in max(screenTopAbs, firstAbs, lastAbs - 24)...lastAbs {
            guard let l = line(abs: a) else { continue }
            var s = ""
            for c in l.cells.prefix(l.trimmedLength) where c.width != 0 {
                let u = Unicode.Scalar(c.ch) ?? " "
                s.unicodeScalars.append(u == "\u{00A0}" || c.ch == 0 ? " " : u)
            }
            lines.append(s)
        }
        func matches(_ re: NSRegularExpression?, _ l: String) -> Bool {
            re?.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)) != nil
        }
        // A menu: the highlighted option plus at least one more numbered option within a few lines.
        for (i, l) in lines.enumerated() where matches(Self.selectedOption, l) {
            let near = lines[max(0, i - 6)..<min(lines.count, i + 7)]
            if near.filter({ matches(Self.option, $0) }).count >= 2 { return .waiting }
        }
        if lines.contains(where: { matches(Self.spinnerLine, $0) || matches(Self.interruptHint, $0.lowercased()) }) { return .working }
        if let first = title?.unicodeScalars.first, (0x2800...0x28FF).contains(first.value) { return .working }
        if lines.suffix(12).contains(where: { $0.contains("⎿") && $0.contains("API Error") }) { return .failed }
        return .done
    }
}
