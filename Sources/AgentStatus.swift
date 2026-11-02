import AppKit

// Coding agents (Claude Code, Codex, Antigravity, …) running in a pane: which one, and whether it's working,
// waiting on you, done, or failed. Shown on the tab and in the file sidebar's header.
//
// Agents don't report their state to the terminal, so it's read from what they draw: each prints a
// "esc to interrupt"-style hint while working and a numbered "1. Yes" menu when asking for approval.

enum AgentKind: Equatable {
    case claude, codex, antigravity
    case other(String)

    /// Command names of other terminal agents, as they appear in argv.
    private static let others = ["astra", "aider", "opencode", "cursor-agent", "amp", "goose", "crush", "qwen", "copilot", "droid", "kiro-cli", "auggie"]

    var name: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .antigravity: return "Antigravity"
        case .other(let n): return n.prefix(1).uppercased() + n.dropFirst()
        }
    }

    /// What starts it, and every agent Solanum knows how to start.
    var command: String {
        switch self {
        case .claude: return "claude"
        case .codex: return "codex"
        case .antigravity: return "agy"
        case .other(let n): return n
        }
    }

    static var known: [AgentKind] { [.claude, .codex, .antigravity] + others.map { .other($0) } }

    static func named(_ command: String) -> AgentKind? { known.first { $0.command == command } }

    /// What continues its latest session in this folder, by default. Empty for an agent with no such command, or none
    /// known (Amp's docs only show continuing a thread by its ID).
    var defaultContinueCommand: String {
        switch self {
        case .claude: return "claude -c"
        case .codex: return "codex resume --last"
        case .antigravity: return "agy -c"
        case .other(let n):
            let commands = ["aider": "aider --restore-chat-history", "opencode": "opencode --continue", "cursor-agent": "cursor-agent --continue",
                            "goose": "goose session --resume", "crush": "crush --continue", "qwen": "qwen --continue", "copilot": "copilot --continue",
                            "droid": "droid resume --last", "kiro-cli": "kiro-cli chat --resume", "auggie": "auggie --continue"]
            return commands[n] ?? ""
        }
    }

    /// `command` through the user's alias for the agent's program, when it starts with that program.
    func throughAlias(_ command: String, alias: String?) -> String {
        guard let alias, command == self.command || command.hasPrefix(self.command + " ") else { return command }
        return alias + command.dropFirst(self.command.count)
    }

    /// The mark as an image, for menus and Settings.
    var markImage: NSImage {
        let image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { r in
            drawMark(in: r)
            return true
        }
        image.accessibilityDescription = name
        return image
    }

    /// Identifies an agent from the foreground process: its name, executable path and arguments. Native
    /// Claude Code runs as a file named after its version (…/claude/versions/2.1.312); npm-installed agents run
    /// under node with the agent's script in argv.
    static func detect(name: String, path: String, args: [String]) -> AgentKind? {
        let words = ([name, path] + args.prefix(3)).map { ($0 as NSString).lastPathComponent.lowercased() }
        let all = ([path] + args.prefix(3)).joined(separator: " ").lowercased()
        if words.contains("claude") || path.contains("/claude/versions/") || all.contains("claude-code") { return .claude }
        if words.contains(where: { $0 == "codex" || $0.hasPrefix("codex-") }) || all.contains("@openai/codex") { return .codex }
        if words.contains("agy") { return .antigravity }
        if let o = others.first(where: { words.contains($0) }) { return .other(o) }
        return nil
    }

    /// Claude Code sets the window title to "✳ …" when idle and a braille spinner while working, also over ssh.
    static func fromTitle(_ title: String?) -> AgentKind? {
        guard let first = title?.unicodeScalars.first else { return nil }
        return first == "✳" || (0x2800...0x28FF).contains(first.value) ? .claude : nil
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

extension Terminal {
    /// Claude Code's busy line: a spinner glyph, a gerund ending in "…", then a timer, e.g.
    /// "✻ Sublimating… (1m 1s · ↓ 1.5k tokens)" or "✢ Scurrying… (43s · thought for 1s)".
    private static let spinnerLine = try? NSRegularExpression(pattern: #"^\s*[·✢✳✶✻✽*+]\s+\S.*…\s+\((\d+[hm]\s+)?\d+s\b"#)
    /// Other agents' busy hints with a running timer: "Working (5s • esc to interrupt)", "(esc to cancel, 12s)".
    private static let interruptHint = try? NSRegularExpression(pattern: #"\(\d+[hms][^)]*esc to (interrupt|cancel)|esc to (interrupt|cancel)[^)]*\d+s\)"#)
    /// The highlighted choice of an approval/question menu: "❯ 1. Yes", "› 2. No", "● 1. Yes, allow once".
    private static let selectedOption = try? NSRegularExpression(pattern: #"^\s*[❯›●▶>]\s*\d+[.)]\s+\S"#)
    private static let option = try? NSRegularExpression(pattern: #"^\s*([❯›●▶>]\s*)?\d+[.)]\s+\S"#)

    /// What the agent drawing this screen is doing. Only its live UI at the bottom of what's drawn is read:
    /// words like "Enter to select" also turn up in transcripts, so the checks look for the UI's shapes
    /// (a menu with a highlighted numbered option, a spinner line with a timer) rather than phrases.
    func agentScreenStatus() -> AgentStatus {
        var lines: [String] = []
        // The bottom of what's drawn, which in a tall window can be well above the bottom of the screen.
        var bottom = lastAbs
        while bottom > screenTopAbs, line(abs: bottom)?.isBlank != false { bottom -= 1 }
        for a in max(screenTopAbs, firstAbs, bottom - 24)...bottom {
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
