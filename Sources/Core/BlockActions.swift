import Foundation

// What a finished command offers, without drawing: its status badge ("✓ 1.2s", "✕ exit 1 · 3s"), whether it gets the
// "Copy output" and "Send to chat" buttons when the pointer's over it, and the text a command (or several, picked with
// ⌘-click on the Mac and Ctrl+click on Windows) copies or sends. Shared by the Mac (TerminalView) and Windows
// (TerminalPane); each draws them its own way.

enum BlockActions {
    /// "Copy output" and "Send to chat" on a command: one that finished and printed something, not an agent's session
    /// (whose prompts have their own).
    static func offersButtons(_ b: Block) -> Bool {
        guard b.state == .finished, !b.isAgentSession, let o = b.outputLine, let e = b.endLine else { return false }
        return e >= o
    }

    enum BadgeKind: Equatable { case running, succeeded, failed, plain }

    /// The badge on a command's first line: how long it ran and how it ended. A failed or running one always shows one;
    /// any other only while it's `shown` (picked, or under the pointer). Nil when it shows none.
    static func badge(_ b: Block, shown: Bool) -> (text: String, kind: BadgeKind)? {
        guard let d = b.duration, shown || b.failed || b.state == .running else { return nil }
        switch b.state {
        case .running:
            guard d > 1 && !b.isAgentSession else { return nil }
            return ("\u{25CF} running  \(NoticeRules.formatDuration(d))", .running)
        default:
            // How a command on an ssh host exited isn't known: just how long it took.
            if b.onHost { return (NoticeRules.formatDuration(d), .plain) }
            if b.failed { return ("\u{2715} exit \(b.exitCode ?? -1)  \u{00B7}  \(NoticeRules.formatDuration(d))", .failed) }
            return ("\u{2713} \(NoticeRules.formatDuration(d))", .succeeded)
        }
    }

    /// A command with what it printed, as it's copied and sent: "$ command", then the output.
    static func entry(command: String, output: String) -> String {
        "$ \(command)" + (output.isEmpty ? "" : "\n" + output)
    }

    /// Several of them, oldest first, a blank line between.
    static func transcript(_ parts: [String]) -> String { parts.joined(separator: "\n\n") }

    /// Picked commands in the order they ran.
    static func chronological(_ blocks: [Block]) -> [Block] { blocks.sorted { $0.id < $1.id } }

    /// The bar over several picked commands.
    static func selectionLabel(_ count: Int) -> String { "\(count) commands selected" }

    /// ⌘-click (Ctrl+click on Windows): a command in or out of the picked ones, in the order picked.
    static func toggle(_ id: Int, in picked: [Int]) -> [Int] {
        picked.contains(id) ? picked.filter { $0 != id } : picked + [id]
    }
}
