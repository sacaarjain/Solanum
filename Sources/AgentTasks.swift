import AppKit

// The commands a coding agent left running: Claude Code runs every command (its own and its background shells) as a
// child process, a shell wrapping it as
//     /bin/bash -c source ~/.claude/shell-snapshots/snapshot-….sh … && eval '<the command>' < /dev/null && pwd -P >| …
// so its children with that wrapper are its commands, and what the agent ran is the `eval` word. One still running while
// the agent has stopped working is a background task (see AgentsRunning). The agent's other children (MCP servers, its
// status line, a language server) have no wrapper and aren't counted. On this Mac only: over ssh, the agent's processes
// are on the host.

/// A command an agent started that's still running.
struct AgentTask: Equatable {
    let pid: pid_t
    let command: String
    let started: Date

    /// The command on one line, as the list shows it: its first line, its spaces closed up.
    var shown: String {
        let first = command.split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        return first.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
    }
}

enum AgentTasks {
    /// What Claude Code's wrapper shell runs (from the wrapper's argv); nil for any other process.
    static func command(fromWrapper args: [String]) -> String? {
        guard args.count >= 3, args[1] == "-c", args[2].contains("/shell-snapshots/"),
              let r = args[2].range(of: "eval ") else { return nil }
        return shellWord(String(args[2][r.upperBound...]))
    }

    /// The first shell word of `s`, as the shell reads it: '…' and "…" unquoted, \ escapes taken, pieces joined.
    static func shellWord(_ s: String) -> String? {
        let c = Array(s)
        var out = "", i = 0, any = false
        while i < c.count {
            switch c[i] {
            case "'":
                guard let e = c[(i + 1)...].firstIndex(of: "'") else { return nil }
                out += String(c[(i + 1)..<e])
                i = e + 1
                any = true
            case "\"":
                i += 1
                while i < c.count, c[i] != "\"" {
                    if c[i] == "\\", i + 1 < c.count { i += 1 }
                    out.append(c[i])
                    i += 1
                }
                guard i < c.count else { return nil }
                i += 1
                any = true
            case " ", "\t", "\n":
                if any { return out }
                i += 1
            case "\\":
                i += 1
                if i < c.count { out.append(c[i]); i += 1 }
                any = true
            default:
                out.append(c[i])
                i += 1
                any = true
            }
        }
        return any ? out : nil
    }

    /// The wrapper shells under each of `agents` (by pid), with what they run and when they started. An agent started
    /// through something else (an alias's npx, a wrapper script) has them further down, so its whole tree is looked
    /// through, though not inside a wrapper (what a command runs is its own business).
    static func scan(_ agents: Set<pid_t>) -> [pid_t: [AgentTask]] {
        guard !agents.isEmpty else { return [:] }
        var pids = [pid_t](repeating: 0, count: Int(proc_listallpids(nil, 0)) + 64)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        var children: [pid_t: [(pid: pid_t, started: Date)]] = [:]
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        for p in pids.prefix(Int(max(count, 0))) where p > 0 {
            var info = proc_bsdinfo()
            guard proc_pidinfo(p, PROC_PIDTBSDINFO, 0, &info, size) == size else { continue }
            let started = Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
            children[pid_t(info.pbi_ppid), default: []].append((p, started))
        }
        var out: [pid_t: [AgentTask]] = [:]
        for agent in agents {
            var stack = children[agent] ?? []
            var looked = 0
            while let c = stack.popLast(), looked < 500 {
                looked += 1
                if let cmd = command(fromWrapper: PTYProcess.arguments(of: c.pid)) {
                    out[agent, default: []].append(AgentTask(pid: c.pid, command: cmd, started: c.started))
                } else {
                    stack += children[c.pid] ?? []
                }
            }
            out[agent]?.sort { $0.started < $1.started }
        }
        return out
    }
}
