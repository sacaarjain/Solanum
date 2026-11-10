import Foundation

/// What continues a coding agent's latest session in a folder, for bringing a tab back the way it was: the Mac's defaults
/// (AgentKind.defaultContinueCommand there). Foundation only.
enum AgentResume {
    /// By the agent's command: what continues it.
    static let commands: [String: String] = [
        "claude": "claude -c", "codex": "codex resume --last", "agy": "agy -c",
        "aider": "aider --restore-chat-history", "opencode": "opencode --continue", "cursor-agent": "cursor-agent --continue",
        "goose": "goose session --resume", "crush": "crush --continue", "qwen": "qwen --continue", "copilot": "copilot --continue",
        "droid": "droid resume --last", "kiro-cli": "kiro-cli chat --resume", "auggie": "auggie --continue",
    ]

    /// The command that continues the agent a typed command started (`claude`, `C:\…\claude.exe --model x`, `npx codex`),
    /// or nil when it didn't start one.
    static func command(continuing typed: String) -> String? { agent(typed: typed).flatMap { commands[$0] } }

    /// The agent a typed command started (`claude`, `C:\…\claude.exe --model x`, `npx codex`), by its command; nil when
    /// it didn't start one.
    static func agent(typed: String) -> String? {
        let words = typed.split(whereSeparator: { $0 == " " || $0 == "\t" }).prefix(3).map { word -> String in
            var name = word.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init)?.lowercased() ?? ""
            name = name.trimmingCharacters(in: CharacterSet(charactersIn: "'\"&"))
            for ext in [".exe", ".cmd", ".ps1", ".bat"] where name.hasSuffix(ext) { name.removeLast(ext.count) }
            return name
        }
        // The program, or what npx, pnpm dlx and the like run (or PowerShell's & runs, which trims to nothing).
        let launchers: Set<String> = ["npx", "pnpx", "bunx", "pnpm", "dlx", "yarn", ""]
        for word in words {
            if commands[word] != nil { return word }
            if !launchers.contains(word) { return nil }
        }
        return nil
    }
}
