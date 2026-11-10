import Foundation

// Coding agents (Claude Code, Codex, Antigravity, …) running in a pane: which one, and whether it's working,
// waiting on you, done, or failed. Shown on the tab, on the Mac and on Windows alike; each draws its marks itself
// (AgentStatus.swift on the Mac, WindowChrome.swift on Windows).
//
// Agents don't report their state to the terminal, so it's read from what they draw: each prints a
// "esc to interrupt"-style hint while working and a numbered "1. Yes" menu when asking for approval.

enum AgentKind: Equatable {
    case claude, codex, antigravity
    case other(String)

    /// Command names of other terminal agents, as they appear in argv.
    private static let others = ["aider", "opencode", "cursor-agent", "amp", "goose", "crush", "qwen", "copilot", "droid", "kiro-cli", "auggie"]

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

    /// Identifies an agent from the foreground process: its name, executable path and arguments. Native
    /// Claude Code runs as a file named after its version (…/claude/versions/2.1.312); npm-installed agents run
    /// under node with the agent's script in argv. On Windows, a name may end in ".exe".
    static func detect(name: String, path: String, args: [String]) -> AgentKind? {
        let words = ([name, path] + args.prefix(3)).map { word -> String in
            var last = String(word.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last ?? Substring(word)).lowercased()
            if last.hasSuffix(".exe") { last.removeLast(4) }
            return last
        }
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

    /// A title without the status glyph agents put in front of it (Claude Code's ✳ and spinners), which the tab shows
    /// its own way.
    static func withoutStatusGlyph(_ title: String) -> String {
        let scalars = title.unicodeScalars
        guard let first = scalars.first, scalars.dropFirst().first == " " else { return title }
        let v = first.value
        let isGlyph = (0x2800...0x28FF).contains(v)       // braille spinners
            || (0x25A0...0x25FF).contains(v)              // geometric shapes: ◐ ◓ ◑ ◒ ● ○
            || (0x2700...0x27BF).contains(v)              // dingbats: ✳ ✶ ✻ ✽ ✢
            || "·*+".unicodeScalars.contains(first)
        guard isGlyph else { return title }
        let rest = String(scalars.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? title : rest
    }

    /// OpenAI's mark (from Simple Icons), drawn for Codex, on a 24-unit square.
    static let openAIPath = "M22.2819 9.8211a5.9847 5.9847 0 0 0-.5157-4.9108 6.0462 6.0462 0 0 0-6.5098-2.9A6.0651 6.0651 0 0 0 4.9807 4.1818a5.9847 5.9847 0 0 0-3.9977 2.9 6.0462 6.0462 0 0 0 .7427 7.0966 5.98 5.98 0 0 0 .511 4.9107 6.051 6.051 0 0 0 6.5146 2.9001A5.9847 5.9847 0 0 0 13.2599 24a6.0557 6.0557 0 0 0 5.7718-4.2058 5.9894 5.9894 0 0 0 3.9977-2.9001 6.0557 6.0557 0 0 0-.7475-7.0729zm-9.022 12.6081a4.4755 4.4755 0 0 1-2.8764-1.0408l.1419-.0804 4.7783-2.7582a.7948.7948 0 0 0 .3927-.6813v-6.7369l2.02 1.1686a.071.071 0 0 1 .038.052v5.5826a4.504 4.504 0 0 1-4.4945 4.4944zm-9.6607-4.1254a4.4708 4.4708 0 0 1-.5346-3.0137l.142.0852 4.783 2.7582a.7712.7712 0 0 0 .7806 0l5.8428-3.3685v2.3324a.0804.0804 0 0 1-.0332.0615L9.74 19.9502a4.4992 4.4992 0 0 1-6.1408-1.6464zM2.3408 7.8956a4.485 4.485 0 0 1 2.3655-1.9728V11.6a.7664.7664 0 0 0 .3879.6765l5.8144 3.3543-2.0201 1.1685a.0757.0757 0 0 1-.071 0l-4.8303-2.7865A4.504 4.504 0 0 1 2.3408 7.872zm16.5963 3.8558L13.1038 8.364 15.1192 7.2a.0757.0757 0 0 1 .071 0l4.8303 2.7913a4.4944 4.4944 0 0 1-.6765 8.1042v-5.6772a.79.79 0 0 0-.407-.667zm2.0107-3.0231l-.142-.0852-4.7735-2.7818a.7759.7759 0 0 0-.7854 0L9.409 9.2297V6.8974a.0662.0662 0 0 1 .0284-.0615l4.8303-2.7866a4.4992 4.4992 0 0 1 6.6802 4.66zM8.3065 12.863l-2.02-1.1638a.0804.0804 0 0 1-.038-.0567V6.0742a4.4992 4.4992 0 0 1 7.3757-3.4537l-.142.0805L8.704 5.459a.7948.7948 0 0 0-.3927.6813zm1.0976-2.3654l2.602-1.4998 2.6069 1.4998v2.9994l-2.5974 1.4997-2.6067-1.4997Z"
}

enum AgentStatus: Equatable {
    case working, waiting, done, failed

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

    /// Its dot's color, as the Mac's system colors: orange working, purple waiting on you, green done, red failed.
    var rgb: UInt32 {
        switch self {
        case .working: return 0xFF9F0A
        case .waiting: return 0xBF5AF2
        case .done: return 0x30D158
        case .failed: return 0xFF453A
        }
    }
}

struct AgentInfo: Equatable {
    let kind: AgentKind
    let status: AgentStatus

    var summary: String { "\(kind.name) — \(status.label)" }
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
