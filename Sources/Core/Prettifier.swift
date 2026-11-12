import Foundation

// Beautify (the Mac's ⌥⌘F, Windows' Shift+Alt+F) for JSON, YAML and XML, without drawing: shared by the Mac and Windows.
// XML is printed by Foundation's XMLDocument on the Mac; elsewhere Foundation has none, so it's re-indented token by token.

/// Beautify (⌥⌘F) for the same languages: consistent indentation, one property or item per line.
enum Prettifier {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func format(_ text: String, as language: SyntaxLanguage, strictJSON: Bool = true) throws -> String {
        switch language {
        case .json: return try json(text, strict: strictJSON)
        case .yaml: return yaml(text)
        case .xml: return try xml(text)
        case .log: throw Failure(message: "Logs can't be beautified.")
        case .code: throw Failure(message: "Beautify works on JSON, YAML and XML.")
        }
    }

    // MARK: JSON

    /// Re-indents token by token, so key order and any comments (JSON with comments) are kept. `strict` checks
    /// the text is valid JSON first, so a mistake is reported instead of being reformatted.
    static func json(_ text: String, strict: Bool) throws -> String {
        if strict {
            do {
                _ = try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
            } catch {
                let detail = (error as NSError).userInfo["NSDebugDescription"] as? String
                throw Failure(message: detail ?? "This isn't valid JSON.")
            }
        }
        let c = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var level = 0
        var pendingBreak = false
        /// The source had a line break since the last token (a comment after it stays on its own line).
        var brokeLine = false
        func emit<S: Sequence>(_ s: S) where S.Element == Unicode.Scalar {
            if pendingBreak {
                out.append("\n")
                for _ in 0..<(level * 2) { out.append(" ") }
                pendingBreak = false
            }
            out.append(contentsOf: s)
            brokeLine = false
        }
        var k = 0
        while k < c.count {
            let ch = c[k]
            switch ch {
            case "\"", "'":
                var j = k + 1
                while j < c.count, c[j] != ch {
                    if c[j] == "\\" { j += 1 }
                    j += 1
                }
                guard j < c.count else { throw Failure(message: "A string never ends.") }
                emit(c[k...j])
                k = j + 1
                continue
            case "{", "[":
                var j = k + 1
                while j < c.count, " \t\r\n".unicodeScalars.contains(c[j]) { j += 1 }
                if j < c.count, c[j] == (ch == "{" ? "}" : "]") {
                    emit(ch == "{" ? "{}".unicodeScalars : "[]".unicodeScalars)
                    k = j + 1
                    continue
                }
                emit([ch])
                level += 1
                pendingBreak = true
            case "}", "]":
                level -= 1
                guard level >= 0 else { throw Failure(message: "A closing \(ch) has no opening bracket.") }
                pendingBreak = true
                emit([ch])
            case ",":
                pendingBreak = false
                emit([ch])
                pendingBreak = true
            case ":":
                emit(": ".unicodeScalars)
            case "\n":
                brokeLine = true
            case " ", "\t", "\r":
                break
            case "/" where k + 1 < c.count && (c[k + 1] == "/" || c[k + 1] == "*"):
                let line = c[k + 1] == "/"
                var j = k + 2
                if line {
                    while j < c.count, c[j] != "\n" { j += 1 }
                } else {
                    while j + 1 < c.count, !(c[j] == "*" && c[j + 1] == "/") { j += 1 }
                    j = min(c.count, j + 2)
                }
                // A comment that followed a value on its line stays beside it.
                if !brokeLine, !out.isEmpty, pendingBreak {
                    pendingBreak = false
                    out.append(" ")
                    out.append(contentsOf: c[k..<j])
                } else {
                    emit(c[k..<j])
                }
                pendingBreak = true
                k = j
                continue
            default:
                emit([ch])
            }
            k += 1
        }
        guard level == 0 else { throw Failure(message: "A bracket is never closed.") }
        return String(out) + "\n"
    }

    // MARK: YAML

    /// Two spaces per level of nesting, one space after "key:" and "-", no trailing spaces, at most one blank line
    /// in a row. Block text (after "|" or ">") keeps its own indentation, moved along with its key.
    static func yaml(_ text: String) -> String {
        var out: [String] = []
        var stack: [Int] = []
        /// Inside "key: |" text: the key's new indentation, and the text's original first-line indentation.
        var block: (keyIndent: Int, contentIndent: Int?, keyOld: Int)?
        var blanks = 0
        let keySpacing = try? NSRegularExpression(pattern: #"^((?:- +)*)("[^"\n]*"|'[^'\n]*'|[^\s#'"\-][^:#\n]*?):[ \t]{2,}(?=\S)"#)
        let dashSpacing = try? NSRegularExpression(pattern: #"^-[ \t]{2,}(?=\S)"#)
        func indentOf(_ s: Substring) -> Int { s.prefix { $0 == " " }.count }
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            if line.isEmpty {
                blanks += 1
                continue
            }
            let w = indentOf(Substring(line))
            if let b = block {
                if w > b.keyOld {
                    let first = b.contentIndent ?? w
                    block?.contentIndent = first
                    if blanks > 0 { out.append(contentsOf: Array(repeating: "", count: min(blanks, 1))) }
                    blanks = 0
                    out.append(String(repeating: " ", count: b.keyIndent + 2 + max(0, w - first)) + line.drop { $0 == " " })
                    continue
                }
                block = nil
            }
            if blanks > 0, !out.isEmpty { out.append("") }
            blanks = 0
            var body = String(line.dropFirst(w))
            if body == "---" || body == "..." {
                stack = []
                out.append(body)
                continue
            }
            while let last = stack.last, last > w { stack.removeLast() }
            if body.hasPrefix("#") {
                out.append(String(repeating: " ", count: max(0, stack.count - (stack.last == w ? 1 : 0)) * 2) + body)
                continue
            }
            if stack.last != w { stack.append(w) }
            let indent = (stack.count - 1) * 2
            let range = NSRange(body.startIndex..., in: body)
            if let re = dashSpacing { body = re.stringByReplacingMatches(in: body, range: range, withTemplate: "- ") }
            if let re = keySpacing {
                body = re.stringByReplacingMatches(in: body, range: NSRange(body.startIndex..., in: body), withTemplate: "$1$2: ")
            }
            out.append(String(repeating: " ", count: indent) + body)
            // "key: |", "key: >-", "- |2" and the like start block text on the following lines.
            if body.range(of: #"(^|[:\-]\s+)[|>][+\-0-9]*\s*(#.*)?$"#, options: .regularExpression) != nil {
                block = (indent, nil, w)
            }
        }
        while out.last == "" { out.removeLast() }
        return out.joined(separator: "\n") + "\n"
    }

    // MARK: XML

#if os(macOS)
    /// AppKit's XML parser, printed with indentation. Comments and CDATA are kept; external DTDs aren't fetched.
    static func xml(_ text: String) throws -> String {
        let doc: XMLDocument
        do {
            doc = try XMLDocument(xmlString: text, options: [.nodePreserveCDATA, .nodeLoadExternalEntitiesNever])
        } catch {
            throw Failure(message: error.localizedDescription)
        }
        var out = doc.xmlString(options: [.nodePrettyPrint, .nodeCompactEmptyElement, .nodePreserveCDATA])
        // The file's own declaration as it was written (the parser's adds standalone="yes"), or none if it had none.
        if out.hasPrefix("<?xml"), let end = out.range(of: "?>") {
            let body = String(out[end.upperBound...]).trimmingCharacters(in: .newlines)
            let original = text.range(of: #"^\s*<\?xml[^>]*\?>"#, options: .regularExpression)
                .map { text[$0].trimmingCharacters(in: .whitespacesAndNewlines) }
            out = original.map { $0 + "\n" + body } ?? body
        }
        return out.trimmingCharacters(in: .newlines) + "\n"
    }
#else
    static func xml(_ text: String) throws -> String { try indentXML(text) }
#endif

    /// Each element on its own line, indented two spaces per level; an element holding only short text stays on one line
    /// (<name>text</name>). Declarations, comments, CDATA and doctypes are kept as written. Tags left open or closed in the
    /// wrong order are reported rather than reformatted.
    static func indentXML(_ text: String) throws -> String {
        enum Token { case open(String, name: String), close(String, name: String), empty(String), text(String), other(String) }
        let s = Array(text.unicodeScalars)
        var tokens: [Token] = []
        var k = 0
        func scalars(_ a: Int, _ b: Int) -> String { var v = String.UnicodeScalarView(); v.append(contentsOf: s[a..<b]); return String(v) }
        func starts(_ p: String, at i: Int) -> Bool {
            let u = Array(p.unicodeScalars)
            return i + u.count <= s.count && Array(s[i..<(i + u.count)]) == u
        }
        func find(_ p: String, from i: Int) -> Int? {
            var j = i
            while j < s.count { if starts(p, at: j) { return j }; j += 1 }
            return nil
        }
        while k < s.count {
            if s[k] == "<" {
                let ends: [(String, String)] = [("<!--", "-->"), ("<![CDATA[", "]]>"), ("<?", "?>")]
                if let (_, close) = ends.first(where: { starts($0.0, at: k) }) {
                    guard let e = find(close, from: k) else { throw Failure(message: "A comment, CDATA section or declaration never ends.") }
                    tokens.append(.other(scalars(k, e + close.unicodeScalars.count)))
                    k = e + close.unicodeScalars.count
                    continue
                }
                if starts("<!", at: k) {
                    // A doctype, which can hold [ … ] with tags inside.
                    var j = k, depth = 0
                    while j < s.count { if s[j] == "[" { depth += 1 } else if s[j] == "]" { depth -= 1 } else if s[j] == ">" && depth <= 0 { break }; j += 1 }
                    guard j < s.count else { throw Failure(message: "A <! declaration never ends.") }
                    tokens.append(.other(scalars(k, j + 1)))
                    k = j + 1
                    continue
                }
                var j = k + 1, quote: Unicode.Scalar?
                while j < s.count {
                    if let q = quote { if s[j] == q { quote = nil } } else if s[j] == "\"" || s[j] == "'" { quote = s[j] } else if s[j] == ">" { break }
                    j += 1
                }
                guard j < s.count else { throw Failure(message: "A tag never ends.") }
                let tag = scalars(k, j + 1)
                let inner = tag.dropFirst(tag.hasPrefix("</") ? 2 : 1)
                let name = String(inner.prefix { !$0.isWhitespace && $0 != ">" && $0 != "/" })
                if tag.hasPrefix("</") { tokens.append(.close(tag, name: name)) }
                else if tag.hasSuffix("/>") { tokens.append(.empty(tag)) }
                else { tokens.append(.open(tag, name: name)) }
                k = j + 1
            } else {
                var j = k
                while j < s.count, s[j] != "<" { j += 1 }
                let t = scalars(k, j).trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { tokens.append(.text(t)) }
                k = j
            }
        }
        var out: [String] = [], level = 0, open: [String] = []
        func pad() -> String { String(repeating: "  ", count: max(level, 0)) }
        var i = 0
        while i < tokens.count {
            switch tokens[i] {
            case .open(let tag, let name):
                // <a>short text</a> on one line.
                if i + 2 < tokens.count, case .text(let t) = tokens[i + 1], !t.contains("\n"), t.count <= 80,
                   case .close(let closing, let closeName) = tokens[i + 2], closeName == name {
                    out.append(pad() + tag + t + closing)
                    i += 3
                    continue
                }
                if i + 1 < tokens.count, case .close(let closing, let closeName) = tokens[i + 1], closeName == name {
                    out.append(pad() + tag + closing)
                    i += 2
                    continue
                }
                out.append(pad() + tag)
                open.append(name)
                level += 1
            case .close(let tag, let name):
                guard open.last == name else { throw Failure(message: "</\(name)> closes \(open.last.map { "<\($0)>" } ?? "nothing").") }
                open.removeLast()
                level -= 1
                out.append(pad() + tag)
            case .empty(let tag), .other(let tag):
                out.append(pad() + tag)
            case .text(let t):
                for line in t.split(whereSeparator: \.isNewline) { out.append(pad() + line.trimmingCharacters(in: .whitespaces)) }
            }
            i += 1
        }
        guard open.isEmpty else { throw Failure(message: "<\(open.last!)> is never closed.") }
        return out.joined(separator: "\n") + "\n"
    }
}
