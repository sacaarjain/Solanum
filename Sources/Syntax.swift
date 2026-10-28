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
