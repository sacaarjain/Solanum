import AppKit

/// Hosts for the status bar's ssh menu: every concrete `Host` in ~/.ssh/config (following `Include`),
/// plus readable (unhashed) entries in ~/.ssh/known_hosts that the config doesn't already cover.
struct SSHHost {
    /// What to put after `ssh`, e.g. "prod" or "-p 2222 example.com".
    let target: String
    let title: String
    /// "user@hostname:port" from the config, when it says more than the alias.
    var detail: String?
}

enum SSHHosts {
    static var dir: String { NSHomeDirectory() + "/.ssh" }
    static var configPath: String { dir + "/config" }

    static func load() -> (configured: [SSHHost], known: [SSHHost]) {
        var configured: [SSHHost] = []
        var seen = Set<String>()
        // Aliases plus the HostNames they point at, so known_hosts doesn't list them again.
        var covered = Set<String>()
        parseConfig(configPath, depth: 0, into: &configured, seen: &seen, covered: &covered)
        configured.removeAll { gitHosts.contains($0.title.lowercased()) }
        // "build01" in known_hosts is the configured "build01.example.com" under its short name.
        let short = Set(covered.filter { !isIPAddress($0) }.map(shortName))
        let known = knownHosts().filter {
            let t = $0.title.lowercased()
            return !covered.contains(t) && (isIPAddress(t) || !short.contains(shortName(t))) && !gitHosts.contains(t)
        }
        return (configured, known.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending })
    }

    /// Git hosting services: they take ssh keys but don't give you a shell.
    private static let gitHosts: Set<String> = ["github.com", "gitlab.com", "bitbucket.org", "ssh.dev.azure.com",
                                                "vs-ssh.visualstudio.com", "ssh.github.com", "altssh.bitbucket.org"]

    private static func shortName(_ host: String) -> String {
        String(host.split(separator: ".").first ?? Substring(host))
    }

    /// Makes ~/.ssh/config (0600) if there isn't one, so "Edit SSH Config" always has a file to open.
    static func ensureConfigExists() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: configPath) else { return }
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        fm.createFile(atPath: configPath, contents: Data("# Host myserver\n#     HostName example.com\n#     User me\n".utf8),
                      attributes: [.posixPermissions: 0o600])
    }

    // MARK: ~/.ssh/config

    private static func parseConfig(_ path: String, depth: Int, into hosts: inout [SSHHost], seen: inout Set<String>,
                                    covered: inout Set<String>) {
        guard depth < 8, let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        // Aliases of the current `Host` block, and what it sets; flushed at the next Host/Match.
        var aliases: [String] = []
        var hostName: String?, user: String?, port: String?
        func flush() {
            for a in aliases where !seen.contains(a.lowercased()) {
                seen.insert(a.lowercased())
                covered.insert(a.lowercased())
                // The alias is often the host name itself; then only the user (and port) add anything.
                let name = hostName.flatMap { $0.lowercased() == a.lowercased() ? nil : $0 }
                var detail = name.map { (user.map { $0 + "@" } ?? "") + $0 } ?? user.map { "as " + $0 } ?? ""
                if let port, port != "22" { detail += (detail.isEmpty ? "port " : ":") + port }
                hosts.append(SSHHost(target: shellQuote(a), title: a, detail: detail.isEmpty ? nil : detail))
            }
            if let hostName { covered.insert(hostName.lowercased()) }
            aliases = []
            hostName = nil; user = nil; port = nil
        }
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            // "Keyword value", "Keyword=value" or "Keyword = value".
            guard let sep = line.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "=" }) else { continue }
            let key = line[..<sep].lowercased()
            var value = line[sep...].drop { $0 == " " || $0 == "\t" || $0 == "=" }.trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 { value = String(value.dropFirst().dropLast()) }
            switch key {
            case "host":
                flush()
                // Patterns (*, ?, !negations) aren't hosts you can connect to.
                aliases = value.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                    .filter { !$0.contains("*") && !$0.contains("?") && !$0.hasPrefix("!") }
            case "match":
                flush()
            case "hostname": if hostName == nil { hostName = value }
            case "user": if user == nil { user = value }
            case "port": if port == nil { port = value }
            case "include":
                flush()
                for pattern in value.split(separator: " ") {
                    var p = String(pattern)
                    if p.hasPrefix("~/") { p = NSHomeDirectory() + p.dropFirst() } else if !p.hasPrefix("/") { p = dir + "/" + p }
                    for file in glob(p) { parseConfig(file, depth: depth + 1, into: &hosts, seen: &seen, covered: &covered) }
                }
            default: break
            }
        }
        flush()
    }

    private static func glob(_ pattern: String) -> [String] {
        var g = glob_t()
        defer { globfree(&g) }
        guard Darwin.glob(pattern, 0, nil, &g) == 0 else { return [] }
        return (0..<Int(g.gl_matchc)).compactMap { g.gl_pathv[$0].map { String(cString: $0) } }
    }

    // MARK: ~/.ssh/known_hosts

    private static func knownHosts() -> [SSHHost] {
        guard let text = try? String(contentsOfFile: dir + "/known_hosts", encoding: .utf8) else { return [] }
        var out: [SSHHost] = []
        var seen = Set<String>()
        for raw in text.split(whereSeparator: \.isNewline) {
            // Hashed names (|1|…) can't be read back; @cert-authority / @revoked lines aren't hosts.
            guard let first = raw.split(separator: " ").first, !first.hasPrefix("|"), !first.hasPrefix("@"), !first.hasPrefix("#") else { continue }
            let names = first.split(separator: ",").map(String.init).filter { !$0.contains("*") && !$0.contains("?") }
            // A line often lists "name,1.2.3.4"; show the name.
            guard let name = names.first(where: { !isIPAddress(bare($0).host) }) ?? names.first else { continue }
            let (host, port) = bare(name)
            guard !seen.contains(name.lowercased()) else { continue }
            seen.insert(name.lowercased())
            let target = port.map { "-p \($0) " + shellQuote(host) } ?? shellQuote(host)
            out.append(SSHHost(target: target, title: port.map { "\(host):\($0)" } ?? host))
        }
        return out
    }

    /// "[host]:2222" → ("host", "2222").
    private static func bare(_ name: String) -> (host: String, port: String?) {
        guard name.hasPrefix("["), let close = name.firstIndex(of: "]") else { return (name, nil) }
        let host = String(name[name.index(after: name.startIndex)..<close])
        let rest = name[name.index(after: close)...]
        return (host, rest.hasPrefix(":") ? String(rest.dropFirst()) : nil)
    }

    private static func isIPAddress(_ s: String) -> Bool {
        var v4 = in_addr(), v6 = in6_addr()
        return inet_pton(AF_INET, s, &v4) == 1 || inet_pton(AF_INET6, s, &v6) == 1
    }
}
