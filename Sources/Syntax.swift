import AppKit

// Syntax colors for the hand-edited config formats: JSON, YAML and XML. Each language is one regex whose
// alternatives are tried left to right, so a token is claimed by whatever starts first: a `//` inside a JSON
// string stays part of the string, a `#` inside a quoted YAML value isn't a comment.

enum SyntaxLanguage {
    case json, yaml, xml

    init?(path: String) {
        switch (path as NSString).pathExtension.lowercased() {
        case "json", "jsonc", "json5", "geojson", "webmanifest": self = .json
        case "yaml", "yml": self = .yaml
        case "xml", "plist", "svg", "xsd", "xsl", "xslt", "pom", "csproj", "fsproj", "vbproj", "props", "targets", "xaml", "storyboard", "xib":
            self = .xml
        default: return nil
        }
    }
}

enum SyntaxHighlighter {
    /// Larger files stay plain: re-coloring runs on every edit.
    static let maxLength = 1_000_000

    private enum Token { case comment, key, string, number, literal, tag, attribute, punctuation, entity }

    private static func color(_ t: Token, _ th: Theme) -> NSColor {
        switch t {
        case .comment: return th.foreground.withAlphaComponent(0.42)
        case .key, .tag: return th.ansi[4]
        case .string: return th.green
        case .number: return th.ansi[5]
        case .literal: return th.ansi[6]
        case .attribute: return th.yellow
        case .punctuation: return th.foreground.withAlphaComponent(0.5)
        case .entity: return th.ansi[5]
        }
    }

    private static let string = #""(?:[^"\\\n]|\\.)*""#

    /// Groups: 1 comment, 2 key, 3 string, 4 number, 5 true/false/null.
    private static let json = try! NSRegularExpression(pattern: [
        #"(//[^\n]*|/\*[\s\S]*?\*/)"#,
        "(\(string))(?=\\s*:)",
        "(\(string))",
        #"(-?\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b)"#,
        #"\b(true|false|null)\b"#,
    ].joined(separator: "|"))

    /// Groups: 1 comment, 2 key (after indentation and any `- `), 3 string, 4 scalar literal, 5 anchor/alias,
    /// 6 document marker.
    private static let yaml = try! NSRegularExpression(pattern: [
        #"((?:^|(?<=\s))#[^\n]*)"#,
        #"^[ \t]*(?:-[ \t]+)*("[^"\n]*"|'[^'\n]*'|[^\s#'"\-:][^:#\n]*?|-[^\s:][^:#\n]*?)(?=:(?:[ \t]|$))"#,
        #"("(?:[^"\\\n]|\\.)*"|'(?:[^'\n]|'')*')"#,
        #"(?<=: |- |\[|, )(true|false|True|False|TRUE|FALSE|null|Null|NULL|~|yes|no|on|off|-?\d[\d_]*(?:\.\d+)?(?:[eE][+-]?\d+)?)(?=[ \t]*(?:#|,|\]|$))"#,
        #"((?<=\s|^)[&*][\w.-]+)"#,
        #"^(---|\.\.\.)(?=\s|$)"#,
    ].joined(separator: "|"), options: [.anchorsMatchLines])

    /// Groups: 1 comment / CDATA / declaration, 2 tag opener `<` or `</`, 3 tag name, 4 the tag's attributes,
    /// 5 tag closer `>` or `/>`, 6 entity.
    private static let xml = try! NSRegularExpression(pattern: [
        #"(<!--[\s\S]*?-->|<!\[CDATA\[[\s\S]*?\]\]>|<\?[\s\S]*?\?>|<![A-Za-z][^>]*>)"#,
        #"(</?)([\w:.-]+)((?:\s+[\w:.-]+(?:\s*=\s*(?:"[^"]*"|'[^']*'))?)*)\s*(/?>)"#,
        #"(&(?:\w+|#\d+|#x[0-9a-fA-F]+);)"#,
    ].joined(separator: "|"))

    private static let xmlAttribute = try! NSRegularExpression(pattern: #"([\w:.-]+)(?:\s*(=)\s*("[^"]*"|'[^']*'))?"#)

    /// Colors `text` in place (foreground only); call after resetting it to the plain foreground.
    static func highlight(_ text: NSMutableAttributedString, as language: SyntaxLanguage, theme th: Theme = Config.shared.theme) {
        guard text.length <= maxLength else { return }
        let s = text.string
        let whole = NSRange(location: 0, length: text.length)
        func paint(_ r: NSRange, _ t: Token) {
            if r.location != NSNotFound, r.length > 0 { text.addAttribute(.foregroundColor, value: color(t, th), range: r) }
        }
        switch language {
        case .json:
            let tokens: [Token] = [.comment, .key, .string, .number, .literal]
            json.enumerateMatches(in: s, range: whole) { m, _, _ in
                guard let m else { return }
                for (i, t) in tokens.enumerated() { paint(m.range(at: i + 1), t) }
            }
        case .yaml:
            let tokens: [Token] = [.comment, .key, .string, .literal, .entity, .punctuation]
            yaml.enumerateMatches(in: s, range: whole) { m, _, _ in
                guard let m else { return }
                for (i, t) in tokens.enumerated() { paint(m.range(at: i + 1), t) }
            }
        case .xml:
            xml.enumerateMatches(in: s, range: whole) { m, _, _ in
                guard let m else { return }
                paint(m.range(at: 1), .comment)
                paint(m.range(at: 2), .punctuation)
                paint(m.range(at: 3), .tag)
                paint(m.range(at: 5), .punctuation)
                paint(m.range(at: 6), .entity)
                let attrs = m.range(at: 4)
                guard attrs.location != NSNotFound, attrs.length > 0 else { return }
                xmlAttribute.enumerateMatches(in: s, range: attrs) { a, _, _ in
                    guard let a else { return }
                    paint(a.range(at: 1), .attribute)
                    paint(a.range(at: 2), .punctuation)
                    paint(a.range(at: 3), .string)
                }
            }
        }
    }
}

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
}
