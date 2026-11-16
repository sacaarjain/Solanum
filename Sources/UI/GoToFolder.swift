import Foundation

/// Go to Folder's paths, worked out without looking at the disk (it may be another machine's): this PC's, with drive
/// letters and either slash, or an ssh host's, from /.
struct GoToPaths {
    let unix: Bool
    /// The terminal's folder, where a relative path starts.
    let base: String
    let home: String
    /// Environment variables a path on this PC can name, as %APPDATA% or $env:APPDATA (names in any case, as Windows
    /// takes them). Empty: none are worked out.
    var variables: [String: String] = [:]

    var separator: String { unix ? "/" : "\\" }

    func isSeparator(_ c: Character) -> Bool { c == "/" || (!unix && c == "\\") }

    func endsInSeparator(_ typed: String) -> Bool { typed.last.map(isSeparator) ?? false }

    /// Quotes around a pasted path taken off, and on a host, backslash-escaped spaces.
    func cleaned(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespaces)
        if unix { t = t.replacingOccurrences(of: "\\ ", with: " ") }
        if t.count >= 2, let f = t.first, f == t.last, f == "\"" || f == "'" { t = String(t.dropFirst().dropLast()) }
        return t
    }

    /// Where what's typed leads: ~ is home, a relative path starts at the terminal's folder, and . and .. are worked out.
    func resolve(_ typed: String) -> String {
        let t = unix ? typed : expandingVariables(typed).replacingOccurrences(of: "/", with: "\\")
        let sep = separator
        let expanded = t == "~" ? home : t.hasPrefix("~" + sep) ? home + t.dropFirst(1) : t
        if unix { return normalized(expanded.hasPrefix("/") ? expanded : base + "/" + expanded) }
        let chars = Array(expanded)
        if expanded.hasPrefix("\\\\") { return normalized(expanded) }
        if chars.count >= 2, chars[0].isLetter, chars[1] == ":" { return normalized(expanded) }
        // From the top of the terminal's drive.
        if expanded.hasPrefix("\\") { return normalized(String(base.prefix(2)) + expanded) }
        return normalized(base + "\\" + expanded)
    }

    /// %NAME% and $env:NAME replaced by the variable's value, as cmd and PowerShell do; a name that isn't set is left as
    /// typed.
    func expandingVariables(_ typed: String) -> String {
        guard !variables.isEmpty, typed.contains("%") || typed.lowercased().contains("$env:") else { return typed }
        func value(_ name: Substring) -> String? {
            let wanted = name.lowercased()
            return variables.first { $0.key.lowercased() == wanted }?.value
        }
        var out = "", rest = Substring(typed)
        while let c = rest.first {
            if c == "%", let close = rest.dropFirst().firstIndex(of: "%"), let v = value(rest[rest.index(after: rest.startIndex)..<close]) {
                out += v
                rest = rest[rest.index(after: close)...]
            } else if rest.lowercased().hasPrefix("$env:") {
                let name = rest.dropFirst(5).prefix { $0.isLetter || $0.isNumber || $0 == "_" }
                if !name.isEmpty, let v = value(name) {
                    out += v
                    rest = rest.dropFirst(5 + name.count)
                } else {
                    out.append(c)
                    rest = rest.dropFirst()
                }
            } else {
                out.append(c)
                rest = rest.dropFirst()
            }
        }
        return out
    }

    /// An absolute path with . and .. worked out, never going above the top.
    func normalized(_ p: String) -> String {
        if unix {
            var parts: [Substring] = []
            for c in p.split(separator: "/") {
                if c == "." { continue }
                if c == ".." { if !parts.isEmpty { parts.removeLast() }; continue }
                parts.append(c)
            }
            return "/" + parts.joined(separator: "/")
        }
        let s = p.replacingOccurrences(of: "/", with: "\\")
        var root: String
        var rest: [Substring]
        if s.hasPrefix("\\\\") {
            let comps = s.dropFirst(2).split(separator: "\\")
            guard comps.count >= 2 else { return s }
            root = "\\\\" + comps[0] + "\\" + comps[1]
            rest = Array(comps.dropFirst(2))
        } else {
            root = String(s.prefix(2)).uppercased()
            rest = s.dropFirst(2).split(separator: "\\")
        }
        var parts: [Substring] = []
        for c in rest {
            if c == "." { continue }
            if c == ".." { if !parts.isEmpty { parts.removeLast() }; continue }
            parts.append(c)
        }
        return root + "\\" + parts.joined(separator: "\\")
    }

    /// The folder above, or nil at the top (of a drive, a share, or /).
    func parent(_ p: String) -> String? {
        if unix { return AnyPath.parent(p) }
        if p.hasPrefix("\\\\") {
            let comps = p.dropFirst(2).split(separator: "\\")
            guard comps.count > 2 else { return nil }
            return "\\\\" + comps.dropLast().joined(separator: "\\")
        }
        return WindowsPath.parent(p)
    }

    /// As it goes in the field: home as ~.
    func shown(_ p: String) -> String {
        let same: (String, String) -> Bool = unix ? { $0 == $1 } : { $0.lowercased() == $1.lowercased() }
        let trimmedHome = home.count > 1 && home.last.map(isSeparator) == true ? String(home.dropLast()) : home
        if same(p, trimmedHome) { return "~" }
        let prefix = trimmedHome + separator
        if p.count > prefix.count, same(String(p.prefix(prefix.count)), prefix) { return "~" + separator + p.dropFirst(prefix.count) }
        return p
    }

    /// What's typed up to and including its last separator.
    func typedParent(_ typed: String) -> String {
        guard let i = typed.lastIndex(where: isSeparator) else { return "" }
        return String(typed[...i])
    }

    /// What's typed after its last separator.
    func lastPart(_ typed: String) -> String {
        guard let i = typed.lastIndex(where: isSeparator) else { return typed }
        return String(typed[typed.index(after: i)...])
    }

    /// `p` as it starts the field: shown, with a separator after, ready for a folder inside it.
    func field(_ p: String) -> String {
        let s = shown(p)
        return endsInSeparator(s) ? s : s + separator
    }
}
