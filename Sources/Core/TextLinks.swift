import Foundation

// Links in a terminal's text, without drawing: web addresses, and words that could name a file. Shared by the Mac and
// Windows; whether a word does name a file is for each to find out, on its disk.

enum TextLinks {
    static let urlRegex = try? NSRegularExpression(
        pattern: #"(?:https?|file|ftp)://[^\s<>"'`]+|\b(?:localhost|127\.0\.0\.1|0\.0\.0\.0)(?::\d{2,5})(?:/[^\s<>"'`]*)?"#)

    /// The links in a piece of text: trailing punctuation is left out, a bare localhost address gets http://, and
    /// 0.0.0.0 (where servers say they listen) becomes localhost, which browsers open.
    static func urls(in text: String) -> [(range: NSRange, url: URL)] {
        guard let re = urlRegex else { return [] }
        let ns = NSString(string: text)
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            var r = m.range
            while r.length > 0, let last = ns.substring(with: NSRange(location: r.location + r.length - 1, length: 1)).first,
                  ".,;:!?)]}'\"*".contains(last) {
                r.length -= 1
            }
            guard r.length > 0 else { return nil }
            var s = ns.substring(with: r)
            if !s.contains("://") { s = "http://" + s }
            guard var c = URLComponents(string: s) else { return nil }
            if c.host == "0.0.0.0" { c.host = "localhost" }
            return c.url.map { (r, $0) }
        }
    }

    /// A run of path characters, where a backslash lets any character in (My\ Notes/plan.md).
    private static let wordRegex = try? NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}_.~/@+\\-])((?:\\.|[\p{L}\p{N}_.~/@+-])*(?:\\.|[\p{L}\p{N}_/@+-]))(?::(\d+)(?::\d+)?)?"#)
    /// Anything between a pair of quotes or backticks, with the line number inside or just after them. A quote with a
    /// letter or digit on its outer side is an apostrophe (it's, dogs').
    private static let quotedRegex = try? NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}])(["'`])((?:(?!\1).)+?)(?::(\d+)(?::\d+)?)?\1(?::(\d+)(?::\d+)?)?(?![\p{L}\p{N}])"#)

    /// Everything in a piece of text that could name a file, with the line number after it if any: quoted text first,
    /// then single words (which may overlap it). Whether one does name a file is up to `locations` and a look on disk.
    static func mentions(in text: String) -> [(range: NSRange, path: String, line: Int?)] {
        let ns = NSString(string: text)
        let all = NSRange(location: 0, length: ns.length)
        func number(_ r: NSRange) -> Int? { Int(ns.substring(with: r)).flatMap { $0 > 0 ? $0 : nil } }
        var found: [(range: NSRange, path: String, line: Int?)] = (quotedRegex?.matches(in: text, range: all) ?? []).map { m in
            let inner = m.range(at: 2)
            let line = [4, 3].map { m.range(at: $0) }.first { $0.location != NSNotFound }
            let end = line.map(NSMaxRange) ?? NSMaxRange(inner)
            return (NSRange(location: inner.location, length: end - inner.location), ns.substring(with: inner), line.flatMap(number))
        }
        let quoted = Set(found.map(\.range))
        for m in wordRegex?.matches(in: text, range: all) ?? [] where !quoted.contains(m.range) {
            let path = ns.substring(with: m.range(at: 1)).replacingOccurrences(of: #"\\(.)"#, with: "$1", options: .regularExpression)
            found.append((m.range, path, m.range(at: 2).location == NSNotFound ? nil : number(m.range(at: 2))))
        }
        return found
    }

    /// Where looking is slow (an ssh host), what's worth offering a click on before looking.
    static func looksLikePath(_ s: String) -> Bool {
        guard !s.hasSuffix("/"), s.contains(where: { $0.isLetter || $0.isNumber }) else { return false }
        return s.contains("/") || !NSString(string: s).pathExtension.isEmpty
    }

}
