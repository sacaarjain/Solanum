import AppKit

// Code blocks and tables in Claude Code's replies get a box with a Copy button, and selecting text inside a
// code block copies the original code. Claude Code prints code without fences, indented under its reply and
// hard-wrapped to the window, so copying it off the screen picks up stray indentation and line breaks in the
// middle of commands. The original markdown is in its transcript
// (~/.claude/projects/<cwd, non-alphanumerics as "-">/<session>.jsonl); each code block from there is found on
// screen by matching its non-space characters in order, which also maps every screen cell back to the source.

/// A code block or table found on screen.
struct CodeBox {
    enum Kind { case code, table }
    let kind: Kind
    /// Absolute lines it spans.
    let first: Int
    let last: Int
    /// Column its text starts at (the box is drawn from just before it).
    let indent: Int
    /// What Copy puts on the clipboard: the original code, or the table as markdown.
    let copyText: String
    /// Code only: the offset into `copyText`'s unicode scalars of each non-space cell.
    var offsets: [GridPos: Int] = [:]
    /// Table only: its cells, header row first.
    var rows: [[String]] = []
    /// One cell and its character, to notice when the screen no longer shows this box (cleared, reflowed).
    let probe: (pos: GridPos, ch: UInt32)

    func contains(line: Int) -> Bool { line >= first && line <= last }

    /// Puts the box on a pasteboard. A table goes on as HTML and RTF too, so Word, Google Docs, Teams, Outlook
    /// and spreadsheets paste a real table; plain-text apps (terminals, editors, Slack) get the markdown.
    func copy(to pb: NSPasteboard = .general) {
        pb.clearContents()
        guard kind == .table, let header = rows.first else {
            pb.setString(copyText, forType: .string)
            return
        }
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        let cell = "border:1px solid #999;padding:4px 8px;text-align:left;vertical-align:top"
        var html = #"<meta charset="utf-8"><table style="border-collapse:collapse">"#
        html += "<tr>" + header.map { "<th style=\"\(cell);font-weight:bold\">\(esc($0))</th>" }.joined() + "</tr>"
        for r in rows.dropFirst() {
            html += "<tr>" + r.map { "<td style=\"\(cell)\">\(esc($0))</td>" }.joined() + "</tr>"
        }
        html += "</table>"
        pb.declareTypes([.html, .rtf, .string], owner: nil)
        pb.setString(html, forType: .html)
        if let data = html.data(using: .utf8),
           let attr = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.html,
                                                                    .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil),
           let rtf = try? attr.data(from: NSRange(location: 0, length: attr.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
            pb.setData(rtf, forType: .rtf)
        }
        pb.setString(copyText, forType: .string)
    }
}

// MARK: - Claude Code transcripts

enum ClaudeTranscript {
    private static let queue = DispatchQueue(label: "solanum.transcripts", qos: .utility)
    /// Per transcript file: its size when read, and the code blocks found.
    private static var cache: [String: (size: UInt64, blocks: [String])] = [:]
    /// Only the end of a transcript is read; recent replies are what's on screen.
    private static let tailBytes: UInt64 = 3 << 20

    /// Code from fenced blocks in recent replies of the Claude sessions started in `cwd` (newest last), plus a
    /// signature that changes when any of those transcripts grows. `done` runs on the main queue.
    static func codeBlocks(cwd: String, _ done: @escaping ([String], String) -> Void) {
        queue.async {
            let slug = String(String.UnicodeScalarView(cwd.unicodeScalars.map {
                $0.isASCII && CharacterSet.alphanumerics.contains($0) ? $0 : "-"
            }))
            let dir = NSHomeDirectory() + "/.claude/projects/" + slug
            let fm = FileManager.default
            let files = ((try? fm.contentsOfDirectory(atPath: dir)) ?? [])
                .filter { $0.hasSuffix(".jsonl") }
                .map { dir + "/" + $0 }
                .map { ($0, (try? fm.attributesOfItem(atPath: $0)[.modificationDate] as? Date) ?? .distantPast) }
                .sorted { $0.1 > $1.1 }
                .prefix(3)
            var blocks: [String] = []
            var signature = ""
            // Oldest of the recent sessions first, so the newest session's blocks end up last.
            for (path, _) in files.reversed() {
                let size = (try? fm.attributesOfItem(atPath: path)[.size] as? NSNumber)?.uint64Value ?? 0
                signature += "\(path):\(size);"
                if let c = cache[path], c.size == size {
                    blocks += c.blocks
                    continue
                }
                let found = read(path, size: size)
                cache[path] = (size, found)
                blocks += found
            }
            let recent = Array(blocks.suffix(80))
            DispatchQueue.main.async { done(recent, signature) }
        }
    }

    private static let fence = try? NSRegularExpression(pattern: #"(?m)^[ \t]*(```|~~~)[^\n]*\n([\s\S]*?)\n[ \t]*\1[ \t]*$"#)

    private static func read(_ path: String, size: UInt64) -> [String] {
        guard let h = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? h.close() }
        let start = size > tailBytes ? size - tailBytes : 0
        try? h.seek(toOffset: start)
        guard let data = try? h.readToEnd() else { return [] }
        var lines = data.split(separator: UInt8(ascii: "\n"))
        if start > 0, !lines.isEmpty { lines.removeFirst() }  // cut mid-line
        var out: [String] = []
        // Cheap pre-filter before parsing; the real check is the "type" field below.
        let marker = Data("\"assistant\"".utf8)
        for raw in lines where raw.range(of: marker) != nil {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(raw)) as? [String: Any], obj["type"] as? String == "assistant",
                  let msg = obj["message"] as? [String: Any], let content = msg["content"] as? [[String: Any]] else { continue }
            for c in content where c["type"] as? String == "text" {
                guard let text = c["text"] as? String, text.contains("```") || text.contains("~~~"), let fence else { continue }
                for m in fence.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                    guard let r = Range(m.range(at: 2), in: text) else { continue }
                    let code = String(text[r])
                    if code.unicodeScalars.filter({ !$0.properties.isWhitespace }).count >= 3 { out.append(code) }
                }
            }
        }
        return out
    }
}

// MARK: - Finding boxes on screen

/// The transcript's lines as they were at one moment, for finding boxes off the main thread. Scrollback lines are
/// never written again once there, so they're shared; screen lines are copied.
struct LineSnapshot {
    let firstAbs: Int
    let lines: [Line]
    var lastAbs: Int { firstAbs + lines.count - 1 }

    func line(abs a: Int) -> Line? {
        let i = a - firstAbs
        return i >= 0 && i < lines.count ? lines[i] : nil
    }

    /// Where code boxes are searched for, one scan at a time.
    static let scanQueue = DispatchQueue(label: "solanum.codeboxes", qos: .utility)
}

extension Terminal {
    func snapshot() -> LineSnapshot {
        let top = screenTopAbs
        let lines = firstAbs <= lastAbs ? (firstAbs...lastAbs).compactMap { a in line(abs: a).map { a >= top ? $0.copy() : $0 } } : []
        return LineSnapshot(firstAbs: firstAbs, lines: lines)
    }

    /// Whether the screen still shows `box` where it was found.
    func stillShows(_ box: CodeBox) -> Bool {
        guard let l = line(abs: box.probe.pos.line), box.probe.pos.col < l.cells.count else { return false }
        return l.cells[box.probe.pos.col].ch == box.probe.ch
    }
}

extension LineSnapshot {
    private static func isBlank(_ c: Cell) -> Bool {
        c.ch == 0 || c.ch == 0x20 || c.ch == 0xA0 || c.ch == 0x09
    }

    /// First column with text on a line, skipping the "⏺ " Claude Code puts before a reply's first line.
    private func textStart(_ l: Line) -> Int? {
        let n = l.trimmedLength
        var x = 0
        while x < n, l.cells[x].width == 0 || Self.isBlank(l.cells[x]) { x += 1 }
        if x < n, l.cells[x].ch == 0x23FA {
            x += 1
            while x < n, l.cells[x].width == 0 || Self.isBlank(l.cells[x]) { x += 1 }
        }
        return x < n ? x : nil
    }

    /// A full-width line of ─, as Claude Code draws above and below its prompt.
    private static func isRule(_ l: Line) -> Bool {
        let n = l.trimmedLength
        guard n >= 20, n * 10 >= l.cells.count * 9 else { return false }
        return l.cells[..<n].allSatisfy { $0.ch == 0x2500 || $0.width == 0 }
    }

    /// Top of Claude Code's prompt box when it's at the bottom of the screen. Below that is the user's typing and
    /// the status line, never a reply, so text there that happens to match a code block gets no box.
    private func promptTop() -> Int? {
        var rules: [Int] = []
        var text = 0
        var a = lastAbs
        while a >= firstAbs, rules.count < 2, let l = line(abs: a) {
            if Self.isRule(l) {
                rules.append(a)
            } else if l.trimmedLength > 0 {
                text += 1
                if rules.isEmpty && text > 8 { return nil }  // no prompt box under the footer
                if text > 60 { break }
            }
            a -= 1
        }
        return rules.last
    }

    /// Code blocks (from `code`, newest last) and tables on screen. Each block is matched to its latest
    /// unclaimed appearance, so a command shown twice gets both boxes.
    func findBoxes(code: [String]) -> [CodeBox] {
        let lo = firstAbs, hi = promptTop().map { $0 - 1 } ?? lastAbs
        guard hi >= lo else { return [] }
        var starts: [Int: (col: Int, ch: UInt32)] = [:]
        for a in lo...hi {
            if let l = line(abs: a), let x = textStart(l) { starts[a] = (x, l.cells[x].ch) }
        }
        var boxes = findTables(lo...hi, starts)
        var claimed = IndexSet()
        for b in boxes { claimed.insert(integersIn: b.first...b.last) }
        for src in code.reversed() {
            let scalars = Array(src.unicodeScalars)
            let target = scalars.indices.filter { !scalars[$0].properties.isWhitespace }
            guard let firstCh = target.first.map({ scalars[$0].value }) else { continue }
            var a = hi
            while a >= lo {
                if !claimed.contains(a), let s = starts[a], s.ch == firstCh,
                   let box = match(scalars, target, from: a, through: hi, col: s.col, source: src, claimed: claimed) {
                    boxes.append(box)
                    claimed.insert(integersIn: box.first...box.last)
                    break
                }
                a -= 1
            }
        }
        return boxes.sorted { $0.first < $1.first }
    }

    private func match(_ scalars: [Unicode.Scalar], _ target: [Int], from a: Int, through hi: Int, col: Int, source: String,
                       claimed: IndexSet) -> CodeBox? {
        var k = 0
        var offsets: [GridPos: Int] = [:]
        var ln = a, x = col, indent = col
        while k < target.count {
            guard ln <= hi, ln - a < target.count + 50, !claimed.contains(ln), let l = line(abs: ln) else { return nil }
            let n = l.trimmedLength
            var lineStart = true
            while x < n {
                let c = l.cells[x]
                if c.width == 0 || Self.isBlank(c) { x += 1; continue }
                if k == target.count { return nil }  // more text after the code on its last line
                guard c.ch == scalars[target[k]].value else { return nil }
                if lineStart { indent = min(indent, x); lineStart = false }
                offsets[GridPos(line: ln, col: x)] = target[k]
                k += 1
                x += 1
            }
            if k == target.count {
                return CodeBox(kind: .code, first: a, last: ln, indent: indent, copyText: source, offsets: offsets,
                               probe: (GridPos(line: a, col: col), scalars[target[0]].value))
            }
            ln += 1
            x = 0
        }
        return nil
    }

    /// Box-drawn tables (┌─┬─┐ … └─┴─┘), as Claude Code renders markdown tables. Copy gives markdown.
    private func findTables(_ range: ClosedRange<Int>, _ starts: [Int: (col: Int, ch: UInt32)]) -> [CodeBox] {
        var out: [CodeBox] = []
        var a = range.lowerBound
        while a <= range.upperBound {
            guard let s = starts[a], s.ch == 0x250C else { a += 1; continue }  // ┌
            var b = a + 1
            var rows: [[String]] = []
            var current: [String]?
            while b <= range.upperBound, let t = starts[b], t.col == s.col, let l = line(abs: b) {
                if t.ch == 0x2514 { break }  // └
                if t.ch == 0x251C { if let c = current { rows.append(c) }; current = nil }  // ├
                else if t.ch == 0x2502 {  // │
                    let text = l.text(from: s.col, to: l.cells.count - 1, trim: true)
                    var cells = text.split(separator: "│", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                    if cells.first == "" { cells.removeFirst() }
                    if cells.last == "" { cells.removeLast() }
                    if let c = current {
                        // A wrapped cell continues on the next line until a ├ separator.
                        current = zip(c, cells).map { [$0, $1].filter { !$0.isEmpty }.joined(separator: " ") }
                            + (cells.count > c.count ? Array(cells[c.count...]) : [])
                    } else {
                        current = cells
                    }
                } else { break }
                b += 1
            }
            guard b <= range.upperBound, starts[b]?.ch == 0x2514 else { a = b + 1; continue }
            if let c = current { rows.append(c) }
            if rows.count >= 1 {
                func row(_ cells: [String]) -> String { "| " + cells.map { $0.replacingOccurrences(of: "|", with: "\\|") }.joined(separator: " | ") + " |" }
                var md = [row(rows[0]), "|" + Array(repeating: "---|", count: rows[0].count).joined()]
                md += rows.dropFirst().map(row)
                out.append(CodeBox(kind: .table, first: a, last: b, indent: s.col, copyText: md.joined(separator: "\n"),
                                   rows: rows, probe: (GridPos(line: a, col: s.col), 0x250C)))
            }
            a = b + 1
        }
        return out
    }

}
