import Foundation

// Syntax for the hand-edited config formats, JSON, YAML and XML (source files and scripts are in CodeSyntax.swift), without drawing: which parts of a text are comments,
// keys, strings and so on. Shared by the Mac (SyntaxHighlighter colors them in AppKit) and Windows (the editor draws
// them). Each language is one regex whose alternatives are tried left to right, so a token is claimed by whatever starts
// first: a `//` inside a JSON string stays part of the string, a `#` inside a quoted YAML value isn't a comment.

enum SyntaxLanguage: Equatable {
    case json, yaml, xml
    /// Logs: colored by LogFormat (time, level, logger, stack traces…), their own ANSI colors shown, not printed.
    case log
    /// Source files, scripts, markdown and diffs (CodeSyntax.swift).
    case code(CodeLanguage)

    /// JSON, YAML and XML can be beautified; the rest can't.
    var canFormat: Bool {
        switch self {
        case .json, .yaml, .xml: return true
        case .log, .code: return false
        }
    }

    /// A script with no extension that says what it is, from its `#!` line (or an XML file from its `<?xml`).
    init?(firstLine line: Substring) {
        if line.hasPrefix("<?xml") { self = .xml; return }
        guard let code = CodeLanguage(shebang: line) else { return nil }
        self = .code(code)
    }

    init?(path: String) {
        let name = path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        if LogFormats.isLogFile(name: name) { self = .log; return }
        switch (path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map { name -> String in
            guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
            return String(name[name.index(after: dot)...])
        } ?? "").lowercased() {
        case "json", "jsonc", "json5", "geojson", "webmanifest": self = .json
        case "yaml", "yml": self = .yaml
        case "xml", "plist", "svg", "xsd", "xsl", "xslt", "pom", "csproj", "fsproj", "vbproj", "props", "targets", "xaml", "storyboard", "xib",
             "config", "resx", "vcxproj", "nuspec", "manifest":
            self = .xml
        default:
            // Everything else by VS Code's language for the name (Dockerfile, .bashrc, x.d.ts…).
            guard let id = VSCodeLanguages.id(forFileName: name) else { return nil }
            switch id {
            case "json", "jsonc", "jsonl", "snippets": self = .json
            case "yaml": self = .yaml
            case "xml", "xsl", "html", "vue", "svelte", "astro", "razor", "handlebars": self = .xml
            case "log": self = .log
            default:
                guard let code = CodeLanguage(vscodeId: id) else { return nil }
                self = .code(code)
            }
        }
    }
}

/// What a piece of text is, for its color.
enum SyntaxToken { case comment, key, string, number, literal, tag, attribute, punctuation, entity, keyword, type, function, variable, removed }

enum SyntaxScanner {
    /// Larger texts stay plain: scanning runs on every edit.
    static let maxLength = 1_000_000

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

    /// Each token in `text`, as a UTF-16 range (NSString's, as NSAttributedString and NSRegularExpression count) and what
    /// it is, in the order found. Nothing for a text longer than `maxLength`.
    static func tokens(in text: String, as language: SyntaxLanguage) -> [(range: NSRange, token: SyntaxToken)] {
        let length = text.utf16.count
        guard length <= maxLength else { return [] }
        var out: [(range: NSRange, token: SyntaxToken)] = []
        let whole = NSRange(location: 0, length: length)
        func add(_ r: NSRange, _ t: SyntaxToken) {
            if r.location != NSNotFound, r.length > 0 { out.append((r, t)) }
        }
        switch language {
        case .log:
            // Painted by LogFormat instead.
            break
        case .code(let code):
            code.grammar.tokens(in: text, range: whole, into: &out)
        case .json:
            let kinds: [SyntaxToken] = [.comment, .key, .string, .number, .literal]
            json.enumerateMatches(in: text, range: whole) { m, _, _ in
                guard let m else { return }
                for (i, t) in kinds.enumerated() { add(m.range(at: i + 1), t) }
            }
        case .yaml:
            let kinds: [SyntaxToken] = [.comment, .key, .string, .literal, .entity, .punctuation]
            yaml.enumerateMatches(in: text, range: whole) { m, _, _ in
                guard let m else { return }
                for (i, t) in kinds.enumerated() { add(m.range(at: i + 1), t) }
            }
        case .xml:
            xml.enumerateMatches(in: text, range: whole) { m, _, _ in
                guard let m else { return }
                add(m.range(at: 1), .comment)
                add(m.range(at: 2), .punctuation)
                add(m.range(at: 3), .tag)
                add(m.range(at: 5), .punctuation)
                add(m.range(at: 6), .entity)
                let attrs = m.range(at: 4)
                guard attrs.location != NSNotFound, attrs.length > 0 else { return }
                xmlAttribute.enumerateMatches(in: text, range: attrs) { a, _, _ in
                    guard let a else { return }
                    add(a.range(at: 1), .attribute)
                    add(a.range(at: 2), .punctuation)
                    add(a.range(at: 3), .string)
                }
            }
        }
        return out
    }
}
