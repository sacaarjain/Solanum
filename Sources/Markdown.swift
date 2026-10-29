import AppKit
import WebKit

// Open Preview (right-click a Markdown file in the sidebar): the file rendered the way GitHub shows it, in the
// theme's colors, in a tab above the terminal. MarkdownHTML converts GitHub-flavored Markdown (headings, lists
// and task lists, quotes, fenced code, tables, rules, inline HTML, emphasis, links and images) to HTML; the page
// has scripts turned off, and links open in the browser.

enum MarkdownHTML {
    /// The body HTML for `markdown`.
    static func render(_ markdown: String) -> String {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\t", with: "    ")
            .components(separatedBy: "\n")
        return blocks(lines[...])
    }

    // MARK: Blocks

    private static func indent(_ s: String) -> Int { s.prefix { $0 == " " }.count }
    private static func isBlank(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespaces).isEmpty }

    private static func blocks(_ lines: ArraySlice<String>) -> String {
        var html = ""
        var i = lines.startIndex
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { html += "<p>" + inline(paragraph.joined(separator: "\n")) + "</p>\n" }
            paragraph = []
        }
        while i < lines.endIndex {
            let line = lines[i]
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { flush(); i += 1; continue }
            // Fenced code.
            if t.hasPrefix("```") || t.hasPrefix("~~~") {
                flush()
                let fence = String(t.prefix(3))
                let lang = t.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.endIndex, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) { code.append(lines[i]); i += 1 }
                i += 1
                html += "<pre><code\(lang.isEmpty ? "" : " class=\"language-\(escape(lang))\"")>" + escape(code.joined(separator: "\n")) + "</code></pre>\n"
                continue
            }
            // ATX heading.
            if let h = t.range(of: #"^#{1,6}(\s|$)"#, options: .regularExpression) {
                flush()
                let level = t[h].filter { $0 == "#" }.count
                let text = t[h.upperBound...].replacingOccurrences(of: #"\s+#+\s*$"#, with: "", options: .regularExpression)
                html += "<h\(level) id=\"\(slug(text))\">" + inline(text) + "</h\(level)>\n"
                i += 1
                continue
            }
            // Setext heading: a paragraph line underlined with === or ---.
            if !paragraph.isEmpty, t.range(of: #"^(=+|-+)$"#, options: .regularExpression) != nil {
                let text = paragraph.joined(separator: " ")
                paragraph = []
                let level = t.hasPrefix("=") ? 1 : 2
                html += "<h\(level) id=\"\(slug(text))\">" + inline(text) + "</h\(level)>\n"
                i += 1
                continue
            }
            // Rule.
            if t.range(of: #"^([-*_])(\s*\1){2,}$"#, options: .regularExpression) != nil {
                flush()
                html += "<hr>\n"
                i += 1
                continue
            }
            // Quote: its lines without the ">", rendered as blocks of their own.
            if t.hasPrefix(">") {
                flush()
                var inner: [String] = []
                while i < lines.endIndex, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    var s = lines[i].trimmingCharacters(in: .whitespaces).dropFirst()
                    if s.first == " " { s = s.dropFirst() }
                    inner.append(String(s))
                    i += 1
                }
                html += "<blockquote>\n" + blocks(inner[...]) + "</blockquote>\n"
                continue
            }
            // Table: a header row, then a row of dashes.
            if t.contains("|"), i + 1 < lines.endIndex,
               lines[i + 1].trimmingCharacters(in: .whitespaces).range(of: #"^\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?$"#, options: .regularExpression) != nil {
                flush()
                let aligns = cells(lines[i + 1]).map { c -> String in
                    let l = c.hasPrefix(":"), r = c.hasSuffix(":")
                    return l && r ? " style=\"text-align:center\"" : r ? " style=\"text-align:right\"" : l ? " style=\"text-align:left\"" : ""
                }
                func row(_ s: String, _ tag: String) -> String {
                    "<tr>" + cells(s).enumerated().map { k, c in "<\(tag)\(k < aligns.count ? aligns[k] : "")>\(inline(c))</\(tag)>" }.joined() + "</tr>\n"
                }
                html += "<table>\n<thead>\n" + row(line, "th") + "</thead>\n<tbody>\n"
                i += 2
                while i < lines.endIndex, lines[i].contains("|"), !isBlank(lines[i]) { html += row(lines[i], "td"); i += 1 }
                html += "</tbody>\n</table>\n"
                continue
            }
            // List.
            if let marker = listMarker(line) {
                flush()
                let start = i
                let base = indent(line)
                /// An item of this same list (a bullet list ends where numbering starts, and the other way round).
                func sameKind(_ l: String) -> Bool { indent(l) == base && listMarker(l)?.ordered == marker.ordered }
                i += 1
                // The list runs on through its items, their continuation lines and nested lists, and single blank lines.
                while i < lines.endIndex {
                    let l = lines[i]
                    if isBlank(l) {
                        if i + 1 < lines.endIndex, !isBlank(lines[i + 1]), indent(lines[i + 1]) > base || sameKind(lines[i + 1]) { i += 1; continue }
                        break
                    }
                    if indent(l) < base { break }
                    if indent(l) == base, listMarker(l) != nil ? !sameKind(l) : !paragraphContinues(l) { break }
                    i += 1
                }
                html += list(lines[start..<i])
                continue
            }
            // HTML block: passed through as written.
            if t.hasPrefix("<"), t.range(of: #"^</?[A-Za-z][A-Za-z0-9-]*(\s|>|/>|$)"#, options: .regularExpression) != nil, paragraph.isEmpty {
                var block: [String] = []
                while i < lines.endIndex, !isBlank(lines[i]) { block.append(lines[i]); i += 1 }
                html += block.joined(separator: "\n") + "\n"
                continue
            }
            // Indented code.
            if paragraph.isEmpty, indent(line) >= 4 {
                var code: [String] = []
                while i < lines.endIndex, indent(lines[i]) >= 4 || (isBlank(lines[i]) && i + 1 < lines.endIndex && indent(lines[i + 1]) >= 4) {
                    code.append(String(lines[i].dropFirst(min(4, lines[i].count))))
                    i += 1
                }
                html += "<pre><code>" + escape(code.joined(separator: "\n")) + "</code></pre>\n"
                continue
            }
            paragraph.append(t)
            i += 1
        }
        flush()
        return html
    }

    /// A line that isn't a new block (a lazy continuation of the list item above).
    private static func paragraphContinues(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        return !(t.hasPrefix("#") || t.hasPrefix(">") || t.hasPrefix("```") || t.hasPrefix("~~~") || t.hasPrefix("|"))
    }

    /// (ordered, number, content column) for a list item's first line.
    private static func listMarker(_ s: String) -> (ordered: Bool, start: Int, content: Int)? {
        let w = indent(s)
        let t = s.dropFirst(w)
        if let f = t.first, "-*+".contains(f), t.dropFirst().first == " " { return (false, 1, w + 2) }
        let digits = t.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 9, let next = t.dropFirst(digits.count).first, next == "." || next == ")",
           t.dropFirst(digits.count + 1).first == " " {
            return (true, Int(digits) ?? 1, w + digits.count + 2)
        }
        return nil
    }

    private static func list(_ lines: ArraySlice<String>) -> String {
        guard let first = lines.first, let m = listMarker(first) else { return "" }
        let base = indent(first)
        var items: [[String]] = []
        for l in lines {
            if indent(l) == base, listMarker(l) != nil {
                let mk = listMarker(l)!
                items.append([String(l.dropFirst(mk.content))])
            } else if !items.isEmpty {
                // Continuation and nested lines, shifted to the item's own margin.
                let cut = min(indent(l), m.content)
                items[items.count - 1].append(String(l.dropFirst(cut)))
            }
        }
        let tag = m.ordered ? "ol" : "ul"
        var html = m.ordered && m.start != 1 ? "<ol start=\"\(m.start)\">\n" : "<\(tag)>\n"
        for item in items {
            var body = item
            var task = ""
            if let head = body.first, let r = head.range(of: #"^\[( |x|X)\]\s"#, options: .regularExpression) {
                let done = head[r].contains("x") || head[r].contains("X")
                task = "<input type=\"checkbox\" disabled\(done ? " checked" : "")> "
                body[0] = String(head[r.upperBound...])
            }
            // A one-paragraph item stays tight (no <p>).
            let inner = blocks(body[...])
            let tight = inner.hasPrefix("<p>") && inner.components(separatedBy: "<p>").count == 2
            let content = tight ? inner.replacingOccurrences(of: "<p>", with: "").replacingOccurrences(of: "</p>", with: "") : inner
            html += "<li\(task.isEmpty ? "" : " class=\"task\"")>" + task + content + "</li>\n"
        }
        return html + "</\(tag)>\n"
    }

    private static func cells(_ row: String) -> [String] {
        var t = row.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// GitHub's heading anchors: lowercase, spaces to hyphens, punctuation dropped.
    static func slug(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" || $0 == "_" }
            .replacingOccurrences(of: " ", with: "-")
    }

    // MARK: Inline

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// For text between tags, where quotes can stay as they are.
    private static func escapeText(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    private static let rules: [(NSRegularExpression, String)] = [
        (#"!\[([^\]]*)\]\(\s*<?([^)\s>]+)>?(?:\s+"([^"]*)")?\s*\)"#, "<img src=\"$2\" alt=\"$1\" title=\"$3\">"),
        (#"\[([^\]]+)\]\(\s*<?([^)\s>]+)>?(?:\s+"([^"]*)")?\s*\)"#, "<a href=\"$2\" title=\"$3\">$1</a>"),
        (#"&lt;(https?://[^\s&]+)&gt;"#, "<a href=\"$1\">$1</a>"),
        (#"(?<!["=>])\b(https?://[^\s<]+[^\s<.,;:!?)\]'"])"#, "<a href=\"$1\">$1</a>"),
        (#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#, "<strong>$2</strong>"),
        (#"(?<![\w*])\*(?=\S)(.+?)(?<=\S)\*(?![\w*])"#, "<em>$1</em>"),
        (#"(?<![\w_])_(?=\S)(.+?)(?<=\S)_(?![\w_])"#, "<em>$1</em>"),
        (#"~~(?=\S)(.+?)(?<=\S)~~"#, "<del>$1</del>"),
        (#"  \n"#, "<br>\n"),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    /// Inline HTML tags written in the Markdown pass through; everything else is escaped.
    private static let tag = try! NSRegularExpression(pattern: #"</?[A-Za-z][A-Za-z0-9-]*(\s[^<>]*)?/?>"#)

    static func inline(_ text: String) -> String {
        // Code spans first, set aside so nothing inside them is touched.
        var spans: [String] = []
        var s = text.replacingOccurrences(of: #"(`+)(.+?)\1"#, with: "\u{0}$2\u{0}", options: .regularExpression)
        var parts = s.components(separatedBy: "\u{0}")
        for k in stride(from: 1, to: parts.count, by: 2) {
            spans.append("<code>" + escape(parts[k].trimmingCharacters(in: .whitespaces)) + "</code>")
            parts[k] = "\u{1}\(spans.count - 1)\u{1}"
        }
        s = parts.joined()
        // Escape, but keep inline tags (<br>, <img …>, <kbd>…) as HTML.
        var out = ""
        var last = s.startIndex
        for m in tag.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            guard let r = Range(m.range, in: s) else { continue }
            out += escapeText(String(s[last..<r.lowerBound])) + s[r]
            last = r.upperBound
        }
        out += escapeText(String(s[last...]))
        for (re, template) in rules {
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: template)
        }
        out = out.replacingOccurrences(of: " title=\"\"", with: "")
        for (k, span) in spans.enumerated() { out = out.replacingOccurrences(of: "\u{1}\(k)\u{1}", with: span) }
        return out
    }

    // MARK: Page

    /// A full page in GitHub's layout, colored by `theme`; `base` resolves relative links and images.
    static func page(_ body: String, theme th: Theme, base: URL?) -> String {
        let bg = th.background.hexString, fg = th.foreground.hexString, accent = th.accent.hexString
        let dim = th.dimText.hexString, border = th.border.hexString, surface = th.surface.hexString
        return """
        <!doctype html><html><head><meta charset="utf-8">\(base.map { "<base href=\"\(escape($0.absoluteString))\">" } ?? "")
        <style>
        :root { color-scheme: \(th.isDark ? "dark" : "light"); }
        html { background: \(bg); }
        body { margin: 0 auto; max-width: 880px; padding: 28px 36px 60px; color: \(fg); background: \(bg);
               font: 15px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif; }
        h1, h2, h3, h4, h5, h6 { margin: 24px 0 16px; font-weight: 600; line-height: 1.25; }
        h1 { font-size: 2em; padding-bottom: .3em; border-bottom: 1px solid \(border); }
        h2 { font-size: 1.5em; padding-bottom: .3em; border-bottom: 1px solid \(border); }
        h3 { font-size: 1.25em; } h4 { font-size: 1em; } h5 { font-size: .875em; } h6 { font-size: .85em; color: \(dim); }
        p, ul, ol, blockquote, pre, table { margin: 0 0 16px; }
        a { color: \(accent); text-decoration: none; } a:hover { text-decoration: underline; }
        ul, ol { padding-left: 2em; } li + li { margin-top: .25em; } li.task { list-style: none; margin-left: -1.4em; }
        li > ul, li > ol { margin: .25em 0 0; }
        blockquote { padding: 0 1em; color: \(dim); border-left: .25em solid \(border); margin-left: 0; }
        code { font: 85% ui-monospace, SFMono-Regular, Menlo, monospace; padding: .2em .4em; border-radius: 6px; background: \(surface); }
        pre { padding: 16px; overflow: auto; border-radius: 6px; background: \(surface); line-height: 1.45; }
        pre code { padding: 0; background: none; font-size: 85%; }
        hr { height: .25em; padding: 0; margin: 24px 0; background: \(border); border: 0; }
        table { border-collapse: collapse; display: block; overflow: auto; }
        th, td { padding: 6px 13px; border: 1px solid \(border); } th { font-weight: 600; }
        tr:nth-child(2n) td { background: \(surface); }
        img { max-width: 100%; } kbd { font: 11px ui-monospace, monospace; padding: 3px 5px; border: 1px solid \(border); border-radius: 6px; }
        </style></head><body>
        \(body)
        </body></html>
        """
    }
}

/// The rendered page. Links open in the browser (or scroll, within the page); relative images load from the file's
/// folder on this Mac.
final class MarkdownPreviewView: NSView, WKNavigationDelegate {
    private let web: WKWebView
    private var scrollY: Double = 0
    private var pageFile: URL?
    private var folder: URL?

    override init(frame: NSRect) {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        web = WKWebView(frame: .zero, configuration: config)
        super.init(frame: frame)
        web.navigationDelegate = self
        web.setValue(false, forKey: "drawsBackground")
        addSubview(web)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { if let f = pageFile { try? FileManager.default.removeItem(at: f) } }

    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        web.frame = bounds
    }

    /// Renders `markdown`; `folder` is the file's folder on this Mac (nil for an ssh file: its images can't load).
    func show(_ markdown: String, folder: URL?) {
        self.folder = folder
        let html = MarkdownHTML.page(MarkdownHTML.render(markdown), theme: Config.shared.theme, base: folder)
        // Keep the place when re-rendering after a save.
        web.evaluateJavaScript("window.scrollY") { [weak self] y, _ in
            guard let self else { return }
            self.scrollY = (y as? Double) ?? 0
            // From a file, so the page may read images next to the Markdown (loadHTMLString can't).
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("solanum-preview-\(ObjectIdentifier(self).hashValue).html")
            guard (try? html.write(to: file, atomically: true, encoding: .utf8)) != nil else {
                self.web.loadHTMLString(html, baseURL: folder)
                return
            }
            self.pageFile = file
            self.web.loadFileURL(file, allowingReadAccessTo: URL(fileURLWithPath: "/"))
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if scrollY > 0 { webView.evaluateJavaScript("window.scrollTo(0, \(scrollY))") }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard action.navigationType == .linkActivated, let url = action.request.url else { return decisionHandler(.allow) }
        // A link to a heading on this page ("#install", resolved against the file's folder) scrolls there.
        if let id = url.fragment, url.path == webView.url?.path || url.standardizedFileURL.path == folder?.standardizedFileURL.path {
            let q = id.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
            webView.evaluateJavaScript("document.getElementById('\(q)')?.scrollIntoView()")
            return decisionHandler(.cancel)
        }
        NSWorkspace.shared.open(url)
        decisionHandler(.cancel)
    }
}
