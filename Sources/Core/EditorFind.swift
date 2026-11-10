import Foundation

// Find in a file, as VS Code does it: plain text, matching case, whole words or a regular expression, and replacing.
// Without drawing: the Mac's bar is EditorFindBar (EditorFindBar.swift), Windows' is drawn by its file editor.

struct EditorFindOptions: Equatable {
    var matchCase = false
    var wholeWord = false
    var regex = false
}

enum EditorFind {
    /// Matches counted; past that it says so ("12000+"), rather than spend the time on a search that broad.
    static let cap = 20000

    /// What's searched for, or a thrown error for a regular expression that doesn't parse.
    static func expression(_ query: String, _ o: EditorFindOptions) throws -> NSRegularExpression {
        var pattern = o.regex ? query : NSRegularExpression.escapedPattern(for: query)
        if o.wholeWord { pattern = "\\b(?:\(pattern))\\b" }
        var options: NSRegularExpression.Options = [.anchorsMatchLines]
        if !o.matchCase { options.insert(.caseInsensitive) }
        return try NSRegularExpression(pattern: pattern, options: options)
    }

    /// Empty matches (of `x*`, say) can't be stepped through, so they don't count.
    static func matches(of e: NSRegularExpression, in text: String) -> (ranges: [NSRange], capped: Bool) {
        var out: [NSRange] = []
        var capped = false
        e.enumerateMatches(in: text, range: NSRange(location: 0, length: text.utf16.count)) { m, _, stop in
            guard let r = m?.range, r.length > 0 else { return }
            out.append(r)
            if out.count >= cap {
                capped = true
                stop.pointee = true
            }
        }
        return (out, capped)
    }

    /// The text replacing `match`: with a regular expression, $1 and the like are filled in.
    static func replacement(_ template: String, for match: NSTextCheckingResult, in text: String, _ e: NSRegularExpression, regex: Bool) -> String {
        regex ? e.replacementString(for: match, in: text, offset: 0, template: template) : template
    }

    /// The first match at or after `location`, else the first of all.
    static func index(of ranges: [NSRange], from location: Int) -> Int? {
        guard !ranges.isEmpty else { return nil }
        var lo = 0, hi = ranges.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if ranges[mid].location < location { lo = mid + 1 } else { hi = mid }
        }
        return lo < ranges.count ? lo : 0
    }
}

/// The file's text as UTF-16 (what NSRange counts in), kept between searches so typing doesn't copy it each time, and
/// searched directly for plain text: Boyer-Moore-Horspool jumps ahead by up to the query's length at each look, so
/// most of a file is never touched. Only a regular expression goes through the slower regex engine.
final class FindBuffer {
    let chars: [UInt16]
    /// ASCII lowercased, for ignoring case; made when first needed. Only read after that, so safe to search on any queue.
    private lazy var folded: [UInt16] = chars.map { $0 >= 65 && $0 <= 90 ? $0 + 32 : $0 }

    init(units: [UInt16]) { chars = units }

    convenience init(_ text: String) { self.init(units: Array(text.utf16)) }

    init(_ text: NSString) {
        let n = text.length
        chars = [UInt16](unsafeUninitializedCapacity: n) { buffer, count in
            if n > 0 { text.getCharacters(buffer.baseAddress!, range: NSRange(location: 0, length: n)) }
            count = n
        }
    }

    /// Makes `folded` while still on one queue.
    func prepare(matchCase: Bool) { if !matchCase { _ = folded } }

    /// Whether plain search gives what the regex engine would: ignoring case outside ASCII needs its Unicode tables.
    static func canSearch(_ query: String, _ o: EditorFindOptions) -> Bool {
        !o.regex && !query.isEmpty && (o.matchCase || query.utf16.allSatisfy { $0 < 128 })
    }

    /// `\b`'s idea of a word character: letters, digits and underscore.
    private static func isWord(_ u: Unicode.Scalar) -> Bool {
        let c = u.value
        if c < 128 { return c == 95 || (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) }
        return CharacterSet.alphanumerics.contains(u)
    }

    private static func pair(_ lead: UInt16, _ trail: UInt16) -> Unicode.Scalar {
        Unicode.Scalar(0x10000 + ((UInt32(lead) - 0xD800) << 10) + (UInt32(trail) - 0xDC00)) ?? "\u{FFFD}"
    }

    /// The character ending just before `i`, and the one starting at `i`, whole even if it takes two UTF-16 units.
    private func wordBefore(_ i: Int) -> Bool {
        guard i > 0 else { return false }
        let c = chars[i - 1]
        if UTF16.isTrailSurrogate(c), i > 1, UTF16.isLeadSurrogate(chars[i - 2]) { return Self.isWord(Self.pair(chars[i - 2], c)) }
        return Unicode.Scalar(c).map(Self.isWord) ?? false
    }

    private func wordAfter(_ i: Int) -> Bool {
        guard i < chars.count else { return false }
        let c = chars[i]
        if UTF16.isLeadSurrogate(c), i + 1 < chars.count, UTF16.isTrailSurrogate(chars[i + 1]) { return Self.isWord(Self.pair(c, chars[i + 1])) }
        return Unicode.Scalar(c).map(Self.isWord) ?? false
    }

    func matches(of query: String, _ o: EditorFindOptions) -> (ranges: [NSRange], capped: Bool) {
        var needle = Array(query.utf16)
        if !o.matchCase { needle = needle.map { $0 >= 65 && $0 <= 90 ? $0 + 32 : $0 } }
        let m = needle.count
        let source = o.matchCase ? chars : folded
        let n = source.count
        guard m > 0, m <= n else { return ([], false) }
        // How far to jump, by the low byte of the text under the query's last place. Characters sharing a low byte
        // share a jump, the smallest of theirs, so one is never skipped past.
        var skip = [Int](repeating: m, count: 256)
        for i in 0..<(m - 1) { skip[Int(needle[i] & 0xFF)] = m - 1 - i }
        let last = needle[m - 1]
        // Whole word: a boundary at each end means one side is a word character and the other isn't.
        let firstIsWord = query.unicodeScalars.first.map(Self.isWord) ?? false, lastIsWord = query.unicodeScalars.last.map(Self.isWord) ?? false
        var out: [NSRange] = []
        var capped = false
        source.withUnsafeBufferPointer { text in
            needle.withUnsafeBufferPointer { pattern in
                var i = 0
                while i <= n - m {
                    let c = text[i + m - 1]
                    if c == last {
                        var j = m - 2
                        while j >= 0, text[i + j] == pattern[j] { j -= 1 }
                        if j < 0 {
                            let bounded = !o.wholeWord || (wordBefore(i) != firstIsWord && wordAfter(i + m) != lastIsWord)
                            if bounded {
                                out.append(NSRange(location: i, length: m))
                                if out.count >= EditorFind.cap {
                                    capped = true
                                    break
                                }
                                i += m
                                continue
                            }
                        }
                    }
                    i += skip[Int(c & 0xFF)]
                }
            }
        }
        return (out, capped)
    }
}
