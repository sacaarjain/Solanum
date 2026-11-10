import Foundation

// Markdown, parsed for drawing as GitHub shows it (the Mac renders it to HTML in a web view; Windows draws it itself):
// headings, paragraphs, lists (with task boxes), quotes, fenced and indented code, tables and rules, and within text
// bold, italic, strikethrough, inline code and links. Foundation only.

enum MarkdownDoc {
    struct Span: Equatable {
        enum Style: Equatable { case plain, bold, italic, boldItalic, code, strike, link(String) }
        var text: String
        var style: Style
    }

    enum Block: Equatable {
        case heading(level: Int, spans: [Span])
        case paragraph([Span])
        /// One item: how deep it's nested, its marker ("•", "3.", or a task box), and its text.
        case listItem(depth: Int, marker: String, checked: Bool?, spans: [Span])
        case quote([Span])
        case code(language: String, lines: [String])
        case table(header: [[Span]], rows: [[[Span]]])
        case rule
    }

    static func isMarkdown(path: String) -> Bool {
        let lower = path.lowercased()
        return [".md", ".markdown", ".mdown", ".mkd", ".mdx"].contains { lower.hasSuffix($0) }
    }

    static func parse(_ text: String) -> [Block] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\t", with: "    ")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var blocks: [Block] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(inline(paragraph.joined(separator: " ")))) }
            paragraph = []
        }
        func indent(_ s: String) -> Int { s.prefix { $0 == " " }.count }
        func blank(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespaces).isEmpty }
        var i = 0
        while i < lines.count {
            let line = lines[i], trimmed = line.trimmingCharacters(in: .whitespaces)
            if blank(line) { flush(); i += 1; continue }
            // Fenced code.
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush()
                let fence = String(trimmed.prefix(3)), language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[i])
                    i += 1
                }
                blocks.append(.code(language: language, lines: code))
                i += 1
                continue
            }
            // Indented code, not inside a paragraph.
            if paragraph.isEmpty, indent(line) >= 4, listMarker(line) == nil {
                var code: [String] = []
                while i < lines.count, indent(lines[i]) >= 4 || blank(lines[i]) {
                    code.append(String(lines[i].dropFirst(min(4, indent(lines[i])))))
                    i += 1
                }
                while code.last.map(blank) == true { code.removeLast() }
                blocks.append(.code(language: "", lines: code))
                continue
            }
            // Headings: "# Title", or a line underlined with === or ---.
            if trimmed.hasPrefix("#") {
                let level = trimmed.prefix { $0 == "#" }.count
                let rest = trimmed.dropFirst(level)
                if level <= 6, rest.isEmpty || rest.first == " " {
                    flush()
                    var title = rest.trimmingCharacters(in: .whitespaces)
                    while title.hasSuffix("#") { title.removeLast() }
                    blocks.append(.heading(level: level, spans: inline(title.trimmingCharacters(in: .whitespaces))))
                    i += 1
                    continue
                }
            }
            if !paragraph.isEmpty, !trimmed.isEmpty, trimmed.allSatisfy({ $0 == "=" }) || (trimmed.count >= 2 && trimmed.allSatisfy({ $0 == "-" })) {
                let title = paragraph.joined(separator: " ")
                paragraph = []
                blocks.append(.heading(level: trimmed.first == "=" ? 1 : 2, spans: inline(title)))
                i += 1
                continue
            }
            // Rules.
            let compact = trimmed.replacingOccurrences(of: " ", with: "")
            if compact.count >= 3, let c = compact.first, "-*_".contains(c), compact.allSatisfy({ $0 == c }) {
                flush()
                blocks.append(.rule)
                i += 1
                continue
            }
            // Quotes, joined line by line.
            if trimmed.hasPrefix(">") {
                flush()
                var quoted: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    quoted.append(String(lines[i].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                blocks.append(.quote(inline(quoted.joined(separator: " "))))
                continue
            }
            // Tables: a header row, then a row of dashes.
            if line.contains("|"), i + 1 < lines.count, isTableRule(lines[i + 1]) {
                flush()
                let header = cells(line).map(inline)
                var rows: [[[Span]]] = []
                i += 2
                while i < lines.count, lines[i].contains("|"), !blank(lines[i]) {
                    rows.append(cells(lines[i]).map(inline))
                    i += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }
            // List items, with their continuation lines.
            if let marker = listMarker(line) {
                flush()
                var text = String(line.dropFirst(marker.content))
                var checked: Bool?
                if text.hasPrefix("[ ] ") || text.hasPrefix("[x] ") || text.hasPrefix("[X] ") {
                    checked = text.hasPrefix("[ ]") ? false : true
                    text = String(text.dropFirst(4))
                }
                i += 1
                while i < lines.count, !blank(lines[i]), listMarker(lines[i]) == nil, indent(lines[i]) >= marker.content || !lines[i].hasPrefix(" ") && !isBlockStart(lines[i]) {
                    text += " " + lines[i].trimmingCharacters(in: .whitespaces)
                    i += 1
                }
                let depth = indent(line) / 2
                blocks.append(.listItem(depth: min(depth, 6), marker: marker.ordered ? "\(marker.number)." : ["•", "◦", "▪"][depth % 3], checked: checked, spans: inline(text)))
                continue
            }
            if isBlockStart(line) { flush() }
            paragraph.append(trimmed)
            i += 1
        }
        flush()
        return blocks
    }

    private static func isBlockStart(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("#") || t.hasPrefix(">") || t.hasPrefix("```") || t.hasPrefix("~~~")
    }

    private static func isTableRule(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.contains("-") && t.allSatisfy { "|:- ".contains($0) }
    }

    private static func cells(_ row: String) -> [String] {
        var t = row.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// "- ", "* ", "+ ", or "12. " / "12) ": whether it's numbered, its number, and where its text starts.
    static func listMarker(_ line: String) -> (ordered: Bool, number: Int, content: Int)? {
        let lead = line.prefix { $0 == " " }.count
        let rest = line.dropFirst(lead)
        if let c = rest.first, "-*+".contains(c), rest.dropFirst().first == " " { return (false, 0, lead + 2) }
        let digits = rest.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 9 else { return nil }
        let after = rest.dropFirst(digits.count)
        guard let d = after.first, d == "." || d == ")", after.dropFirst().first == " " else { return nil }
        return (true, Int(digits) ?? 1, lead + digits.count + 2)
    }

    /// Text with its inline marks turned into styled runs. Marks that don't close stay as they were.
    static func inline(_ text: String) -> [Span] {
        let c = Array(text)
        var spans: [Span] = []
        var plain = ""
        func add(_ s: String, _ style: Span.Style) {
            guard !s.isEmpty else { return }
            if style == .plain, let last = spans.last, last.style == .plain { spans[spans.count - 1].text += s } else { spans.append(Span(text: s, style: style)) }
        }
        func flushPlain() { add(plain, .plain); plain = "" }
        func close(_ mark: String, from i: Int) -> Int? {
            let m = Array(mark)
            var j = i
            while j + m.count <= c.count {
                if Array(c[j..<(j + m.count)]) == m, j > i { return j }
                j += 1
            }
            return nil
        }
        var i = 0
        while i < c.count {
            let ch = c[i]
            if ch == "\\", i + 1 < c.count, "\\`*_{}[]()#+-.!|~<>".contains(c[i + 1]) {
                plain.append(c[i + 1])
                i += 2
                continue
            }
            if ch == "`" {
                let ticks = c[i...].prefix { $0 == "`" }.count
                if let end = close(String(repeating: "`", count: ticks), from: i + ticks) {
                    flushPlain()
                    add(String(c[(i + ticks)..<end]).trimmingCharacters(in: .whitespaces), .code)
                    i = end + ticks
                    continue
                }
            }
            // Images show as their description; links as their text, carrying where they go.
            if ch == "[" || (ch == "!" && i + 1 < c.count && c[i + 1] == "[") {
                let open = ch == "!" ? i + 1 : i
                if let mid = close("](", from: open), let end = close(")", from: mid + 2) {
                    flushPlain()
                    let label = String(c[(open + 1)..<mid]), target = String(c[(mid + 2)..<end]).split(separator: " ").first.map(String.init) ?? ""
                    for span in inline(ch == "!" ? (label.isEmpty ? "image" : label) : label) {
                        add(span.text, span.style == .plain ? .link(target) : span.style)
                    }
                    i = end + 1
                    continue
                }
            }
            if ch == "<", let end = close(">", from: i + 1) {
                let inside = String(c[(i + 1)..<end])
                if inside.hasPrefix("http://") || inside.hasPrefix("https://") {
                    flushPlain()
                    add(inside, .link(inside))
                    i = end + 1
                    continue
                }
            }
            var handled = false
            if ch == "*" || ch == "_" || ch == "~" {
                for (mark, style) in [("***", Span.Style.boldItalic), ("___", .boldItalic), ("**", .bold), ("__", .bold), ("~~", .strike), ("*", .italic), ("_", .italic)] {
                    let m = Array(mark)
                    guard i + m.count <= c.count, Array(c[i..<(i + m.count)]) == m else { continue }
                    // An underscore inside a word (snake_case) isn't emphasis.
                    if mark.hasPrefix("_"), i > 0, c[i - 1].isLetter || c[i - 1].isNumber { continue }
                    guard i + m.count < c.count, !c[i + m.count].isWhitespace, let end = close(mark, from: i + m.count) else { continue }
                    flushPlain()
                    for span in inline(String(c[(i + m.count)..<end])) {
                        let combined: Span.Style
                        switch (span.style, style) {
                        case (.plain, _): combined = style
                        case (.italic, .bold), (.bold, .italic): combined = .boldItalic
                        default: combined = span.style
                        }
                        add(span.text, combined)
                    }
                    i = end + m.count
                    handled = true
                    break
                }
            }
            if !handled {
                plain.append(ch)
                i += 1
            }
        }
        flushPlain()
        return spans
    }
}
