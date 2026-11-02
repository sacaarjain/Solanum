import Foundation

/// A host for the status bar's ssh menu.
struct SSHHostEntry: Equatable {
    /// What goes after `ssh`.
    let target: String
    let title: String
    /// "user@hostname:port", when the config says more than the alias.
    var detail: String?
}

/// Hosts from ~/.ssh/config (following Include, without wildcards) and unhashed entries in ~/.ssh/known_hosts that the
/// config doesn't already cover, as on the Mac. Git hosting services are left out: they take keys but give no shell.
enum SSHHostList {
    private static let gitHosts: Set<String> = ["github.com", "gitlab.com", "bitbucket.org", "ssh.dev.azure.com",
                                                "vs-ssh.visualstudio.com", "ssh.github.com", "altssh.bitbucket.org"]

    static func load(sshFolder: String) -> (configured: [SSHHostEntry], known: [SSHHostEntry]) {
        var configured: [SSHHostEntry] = []
        var covered = Set<String>()
        parseConfig(at: sshFolder + "\\config", folder: sshFolder, depth: 0, into: &configured, covered: &covered)
        configured.removeAll { gitHosts.contains($0.title.lowercased()) }
        let knownText = (try? String(contentsOfFile: sshFolder + "\\known_hosts", encoding: .utf8)) ?? ""
        let known = knownHosts(knownText).filter { !covered.contains($0.title.lowercased()) && !gitHosts.contains($0.title.lowercased()) }
        return (configured, known.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending })
    }

    static func parseConfig(at path: String, folder: String, depth: Int, into hosts: inout [SSHHostEntry], covered: inout Set<String>) {
        guard depth < 5, let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        parse(text, folder: folder, depth: depth, into: &hosts, covered: &covered)
    }

    static func parse(_ text: String, folder: String = "", depth: Int = 0, into hosts: inout [SSHHostEntry], covered: inout Set<String>) {
        var aliases: [String] = []
        var settings: [String: String] = [:]
        func finish() {
            let hostName = settings["hostname"], user = settings["user"], port = settings["port"]
            var detail = ""
            if let user { detail += user + "@" }
            if let hostName { detail += hostName } else if user != nil || port != nil { detail += aliases.first ?? "" }
            if let port { detail += ":" + port }
            for alias in aliases where !alias.contains("*") && !alias.contains("?") && !alias.hasPrefix("!") {
                guard !hosts.contains(where: { $0.title == alias }) else { continue }
                hosts.append(SSHHostEntry(target: alias, title: alias, detail: detail.isEmpty || detail == alias ? nil : detail))
                covered.insert(alias.lowercased())
                if let hostName { covered.insert(hostName.lowercased()) }
            }
            aliases = []
            settings = [:]
        }
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" }).map(String.init)
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased(), value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " =\t\""))
            switch key {
            case "host":
                finish()
                aliases = value.split(separator: " ").map(String.init)
            case "match":
                finish()
            case "include":
                finish()
                var target = value
                if target.hasPrefix("~/") { target = (ProcessInfo.processInfo.environment["USERPROFILE"] ?? "") + "\\" + target.dropFirst(2) }
                else if !target.contains(":") { target = folder + "\\" + target }
                if !target.contains("*") {
                    parseConfig(at: target.replacingOccurrences(of: "/", with: "\\"), folder: folder, depth: depth + 1, into: &hosts, covered: &covered)
                }
            default:
                if !aliases.isEmpty && settings[key] == nil { settings[key] = value }
            }
        }
        finish()
    }

    /// Readable entries of a known_hosts file: plain names, and [name]:port ones.
    static func knownHosts(_ text: String) -> [SSHHostEntry] {
        var seen = Set<String>()
        var out: [SSHHostEntry] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("|"), !line.hasPrefix("@") else { continue }
            guard let names = line.split(separator: " ").first else { continue }
            for name in names.split(separator: ",") {
                var host = String(name), port: String?
                if host.hasPrefix("["), let close = host.firstIndex(of: "]") {
                    port = host[host.index(after: close)...].split(separator: ":").first.map(String.init)
                    host = String(host[host.index(after: host.startIndex)..<close])
                }
                let key = host.lowercased() + (port ?? "")
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                out.append(SSHHostEntry(target: port.map { "-p \($0) \(host)" } ?? host, title: port.map { "\(host):\($0)" } ?? host))
            }
        }
        return out
    }

    /// The host an ssh command line connects to: its first argument that isn't an option or an option's value.
    static func destination(fromArguments args: [String]) -> String? {
        let takesValue: Set<Character> = ["b", "c", "D", "E", "e", "F", "I", "i", "J", "L", "l", "m", "O", "o", "p", "Q", "R", "S", "W", "w", "B"]
        var i = 0
        while i < args.count {
            let arg = args[i]
            if arg.hasPrefix("-"), arg.count >= 2 {
                let letters = Array(arg.dropFirst())
                // A value-taking letter last in a group takes the next argument; otherwise its value is in the group.
                if let last = letters.last, takesValue.contains(last), letters.count == 1 || !letters.dropLast().contains(where: { takesValue.contains($0) }) {
                    if letters.count == 1 || letters.firstIndex(of: last) == letters.count - 1 { i += 1 }
                }
                i += 1
                continue
            }
            return arg
        }
        return nil
    }

    /// What the status bar shows for a destination: the host, without the user.
    static func hostLabel(_ destination: String) -> String {
        destination.split(separator: "@").last.map(String.init) ?? destination
    }
}
