import Foundation

/// Command aliases set in Settings › Aliases (e.g. `c` → `claude`). Saved to ~/.config/solanum/aliases.json and
/// written out as a shell file that the shell integration re-reads before every prompt, so edits reach
/// open tabs without restarting them.
final class AliasStore {
    struct Alias: Codable, Equatable {
        var name: String
        var command: String
    }

    static let shared = AliasStore()
    private(set) var aliases: [Alias] = []

    private var url: URL { Config.shared.dir.appendingPathComponent("aliases.json") }
    static var shellFile: URL { ShellIntegration.dir.appendingPathComponent("aliases.sh") }

    /// Letters, digits and `_ . -`, not starting with `-`: names both bash and zsh accept as aliases.
    static func isValidName(_ name: String) -> Bool {
        guard let first = name.first, first != "-" else { return false }
        return name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "_.-".contains($0)) }
    }

    func load() {
        if let data = try? Data(contentsOf: url), let list = try? JSONDecoder().decode([Alias].self, from: data) {
            aliases = list
        } else if !FileManager.default.fileExists(atPath: url.path) {
            // First run: the two the user asked for.
            aliases = [Alias(name: "c", command: "claude"), Alias(name: "ca", command: "caffeinate")]
            save()
        }
        writeShellFile()
    }

    /// The name of an alias that runs `program` (e.g. `c` for `claude --model opus`), if any.
    func alias(running program: String) -> String? {
        aliases.first { Self.isValidName($0.name) && $0.command.split(separator: " ").first.map(String.init) == program }?.name
    }

    func set(_ list: [Alias]) {
        aliases = list
        save()
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        try? FileManager.default.createDirectory(at: Config.shared.dir, withIntermediateDirectories: true)
        try? enc.encode(aliases).write(to: url, options: .atomic)
        writeShellFile()
    }

    /// Only complete, valid entries are written; the previous names are unaliased first by the loader.
    private func writeShellFile() {
        let valid = aliases.filter { Self.isValidName($0.name) && !$0.command.trimmingCharacters(in: .whitespaces).isEmpty }
        var text = "# Written by Solanum from Settings › Aliases. Edits here are overwritten.\n"
        text += "__solanum_alias_names=\(shellQuote(valid.map(\.name).joined(separator: " ")))\n"
        for a in valid { text += "alias \(a.name)=\(shellQuote(a.command))\n" }
        try? FileManager.default.createDirectory(at: ShellIntegration.dir, withIntermediateDirectories: true)
        try? text.write(to: Self.shellFile, atomically: true, encoding: .utf8)
    }
}
