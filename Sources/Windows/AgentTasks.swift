import Foundation
import WinSDK

// The commands a coding agent left running, as on the Mac (AgentTasks.swift there). Claude Code runs every command (its
// own and its background shells) as a child process, Git Bash wrapping it as
//     bash.exe -c "source /c/Users/…/.claude/shell-snapshots/snapshot-bash-….sh … && { eval '<the command>' < /dev/null; } && pwd -P >| …"
// so its children with that wrapper are its commands, and what it ran is the `eval` word. One still running while the
// agent has stopped working is a background task (see AgentsRunning). Its other children (MCP servers, its status line)
// have no wrapper and aren't counted. On this PC only: over ssh, the agent's processes are on the host.

/// A command an agent started that's still running.
struct AgentTask: Equatable {
    let pid: DWORD
    let command: String
    let started: Date

    /// The command on one line, as the list shows it: its first line, its spaces closed up.
    var shown: String {
        let first = command.split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        return first.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
    }
}

enum AgentTasks {
    /// What Claude Code's wrapper shell runs (from its arguments); nil for any other process.
    static func command(fromWrapper args: [String]) -> String? {
        guard args.count >= 3, args[1] == "-c", args[2].contains("/shell-snapshots/"), let r = args[2].range(of: "eval ") else { return nil }
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

    /// The wrapper shells under the agent running in each tab (keyed by the tab, given its shell's process), with what
    /// they run and when they started. An agent started through something else (npx, a script) has them further down,
    /// so the tree under the shell is looked through, though not inside a wrapper.
    static func scan(_ shells: [ObjectIdentifier: DWORD]) -> [ObjectIdentifier: [AgentTask]] {
        guard !shells.isEmpty else { return [:] }
        let all = ProcessTree.all()
        var children: [DWORD: [(pid: DWORD, name: String)]] = [:]
        for p in all where p.pid != 0 {
            var name = p.name.lowercased()
            if name.hasSuffix(".exe") { name.removeLast(4) }
            children[p.parent, default: []].append((p.pid, name))
        }
        var out: [ObjectIdentifier: [AgentTask]] = [:]
        for (tab, shell) in shells where shell != 0 {
            var stack = children[shell] ?? []
            var looked = 0
            var found: [AgentTask] = []
            while let c = stack.popLast(), looked < 500 {
                looked += 1
                if c.name == "bash", let cmd = command(fromWrapper: arguments(of: c.pid)) {
                    found.append(AgentTask(pid: c.pid, command: cmd, started: startTime(of: c.pid) ?? Date()))
                } else {
                    stack += children[c.pid] ?? []
                }
            }
            out[tab] = found.sorted { $0.started < $1.started }
        }
        return out
    }

    // MARK: Reading another process

    private typealias QueryInformation = @convention(c) (HANDLE?, Int32, UnsafeMutableRawPointer?, ULONG, UnsafeMutablePointer<ULONG>?) -> LONG
    private static let queryInformation: QueryInformation? = {
        guard let ntdll = GetModuleHandleW(wide("ntdll.dll")), let f = GetProcAddress(ntdll, "NtQueryInformationProcess") else { return nil }
        return unsafeBitCast(f, to: QueryInformation.self)
    }()

    /// A process's command line, split as its C runtime splits it; empty when it can't be read.
    static func arguments(of pid: DWORD) -> [String] {
        guard let query = queryInformation, let h = OpenProcess(DWORD(PROCESS_QUERY_LIMITED_INFORMATION), false, pid) else { return [] }
        defer { CloseHandle(h) }
        // ProcessCommandLineInformation (60): a UNICODE_STRING and, after it, the text it points to.
        var size: ULONG = 0
        _ = query(h, 60, nil, 0, &size)
        guard size > 0, size < 1 << 20 else { return [] }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { buffer.deallocate() }
        guard query(h, 60, buffer, size, &size) >= 0 else { return [] }
        let length = Int(buffer.load(as: UInt16.self)) / 2
        guard let text = buffer.load(fromByteOffset: 8, as: UnsafeMutablePointer<UInt16>?.self), length > 0 else { return [] }
        let line = Array(UnsafeBufferPointer(start: text, count: length)) + [0]
        var count: Int32 = 0
        guard let argv = CommandLineToArgvW(line, &count) else { return [] }
        defer { LocalFree(argv) }
        return (0..<Int(count)).compactMap { argv[$0].map { String(decodingCString: $0, as: UTF16.self) } }
    }

    /// When a process started.
    static func startTime(of pid: DWORD) -> Date? {
        guard let h = OpenProcess(DWORD(PROCESS_QUERY_LIMITED_INFORMATION), false, pid) else { return nil }
        defer { CloseHandle(h) }
        var created = FILETIME(), exited = FILETIME(), kernel = FILETIME(), user = FILETIME()
        guard GetProcessTimes(h, &created, &exited, &kernel, &user) else { return nil }
        let ticks = UInt64(created.dwHighDateTime) << 32 | UInt64(created.dwLowDateTime)
        return Date(timeIntervalSince1970: (Double(ticks) - 116_444_736_000_000_000) / 10_000_000)
    }
}
