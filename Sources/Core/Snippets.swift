import Foundation

// Saved command snippets (snippets.json in Solanum's settings folder), and reading shells' history files for Command
// History, without drawing. Shared by the Mac (its Snippets menu, ⌃H) and Windows (the palette, Ctrl+Shift+H).

struct Snippet: Codable, Equatable {
    var name: String
    var command: String
}

final class SnippetStore {
    static let shared = SnippetStore()
    private(set) var snippets: [Snippet] = []
    var fileURL: URL { LogFormatStore.configFolder.appendingPathComponent("snippets.json") }

    /// A few to start with, for this system's shells.
    static var starters: [Snippet] {
        #if os(Windows)
        return [
            Snippet(name: "Git: pretty log graph", command: "git log --oneline --graph --decorate -20"),
            Snippet(name: "Git: branches by recent commit", command: "git branch --sort=-committerdate"),
            Snippet(name: "Size of each folder here", command: "Get-ChildItem -Directory | ForEach-Object { '{0,10:N0} MB  {1}' -f ((Get-ChildItem $_ -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1MB), $_.Name }"),
            Snippet(name: "Listening ports", command: "Get-NetTCPConnection -State Listen | Sort-Object LocalPort | Format-Table LocalAddress, LocalPort, OwningProcess"),
            Snippet(name: "Find large files (>100MB)", command: "Get-ChildItem -Recurse -File -ErrorAction SilentlyContinue | Where-Object Length -gt 100MB | Select-Object FullName, Length"),
            Snippet(name: "Top processes by CPU", command: "Get-Process | Sort-Object CPU -Descending | Select-Object -First 15 Id, CPU, WS, ProcessName"),
        ]
        #else
        return [
            Snippet(name: "Git: pretty log graph", command: "git log --oneline --graph --decorate -20"),
            Snippet(name: "Git: branches by recent commit", command: "git branch --sort=-committerdate | head -15"),
            Snippet(name: "Disk usage of current folder", command: "du -sh * | sort -h"),
            Snippet(name: "Listening ports", command: "lsof -iTCP -sTCP:LISTEN -n -P"),
            Snippet(name: "Find large files (>100MB)", command: "find . -type f -size +100M 2>/dev/null"),
            Snippet(name: "Top processes by CPU", command: "ps -Ao pid,pcpu,pmem,comm -r | head -15"),
        ]
        #endif
    }

    func load() {
        if let data = try? Data(contentsOf: fileURL), let s = try? JSONDecoder().decode([Snippet].self, from: data) {
            snippets = s
        } else {
            snippets = Self.starters
            save()
        }
    }

    func add(_ s: Snippet) {
        snippets.append(s)
        save()
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(snippets) {
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: fileURL)
        }
    }
}

/// Shells' history files, read for Command History.
enum HistoryFile {
    static let limit = 10_000

    /// A file's lines, ending in "\n" or Windows' "\r\n" (which Swift takes as one character, so splitting on "\n"
    /// alone never finds it).
    private static func lines(_ text: String) -> [Substring] {
        text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" })
    }

    /// Oldest-first lines → newest-first unique commands.
    static func newestFirst(_ commands: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for c in commands.reversed() where !c.isEmpty && seen.insert(c).inserted {
            out.append(c)
            if out.count >= limit { break }
        }
        return out
    }

    /// Handles plain bash history, bash `#<epoch>` timestamp lines, zsh extended history
    /// (`: <epoch>:<secs>;cmd`) and zsh's backslash-continued multi-line commands.
    static func parse(_ text: String) -> [String] {
        var out: [String] = []
        var pending: String?
        for raw in lines(text) {
            var line = String(raw)
            if let p = pending {
                line = p + "\n" + line
                pending = nil
            } else {
                if line.hasPrefix("#"), line.dropFirst().allSatisfy(\.isNumber), line.count > 1 { continue }
                if line.hasPrefix(": "), let semi = line.firstIndex(of: ";"),
                   line[line.index(line.startIndex, offsetBy: 2)..<semi].allSatisfy({ $0.isNumber || $0 == ":" }) {
                    line = String(line[line.index(after: semi)...])
                }
            }
            if line.hasSuffix("\\") && !line.hasSuffix("\\\\") {
                pending = String(line.dropLast())
                continue
            }
            let c = line.trimmingCharacters(in: .whitespaces)
            if !c.isEmpty { out.append(c) }
        }
        return out
    }

    /// PowerShell's (PSReadLine's ConsoleHost_history.txt): a command a line, one of several lines with a backtick at
    /// the end of each but its last.
    static func parsePowerShell(_ text: String) -> [String] {
        var out: [String] = []
        var pending: String?
        for raw in lines(text) {
            var line = String(raw)
            if let p = pending { line = p + "\n" + line; pending = nil }
            if line.hasSuffix("`") {
                pending = String(line.dropLast())
                continue
            }
            let c = line.trimmingCharacters(in: .whitespaces)
            if !c.isEmpty { out.append(c) }
        }
        return out
    }
}
