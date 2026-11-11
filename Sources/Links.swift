import AppKit

// Links in the terminal's text (http(s), file and ftp URLs, and bare localhost:PORT addresses) open with a click.
// Under the pointer a link is underlined and a small card above it says where it goes and what opens it (the
// default browser, with its icon), and for a local server whether anything is answering there. In the line being
// typed, or while a program reads the mouse itself, a plain click keeps its usual meaning and links take ⌘-click.
// Files named in the text (Sources/Links.swift:52, ~/notes.md, "My Notes/plan.md", My\ Notes/plan.md) take ⌘-click
// always, and open in the editor on the machine the pane is on. A path with spaces needs its quotes or backslashes:
// nothing else says where it starts and ends.

/// The link under the pointer, and what it opens with.
struct LinkHover {
    var url: URL
    /// The hovered row's part of the link: the screen line and columns (where its card goes).
    var line: Int
    var start: Int
    var end: Int
    /// Every row's part, for a link that wraps onto more lines (underlined on all of them); empty: just `line`'s.
    var rows: [LinkRow] = []
    var opener: String
    var icon: NSImage?
    /// Set when this is a file named in the text rather than a URL.
    var file: FileLink?
}

/// One row's part of a link: an absolute line and the columns from `start` through `end`.
struct LinkRow: Hashable {
    var line: Int
    var start: Int
    var end: Int
}

/// A file named in the terminal's text: where it may be (nearest folder first; just one on this Mac, where it was
/// looked for already) and the line to go to.
struct FileLink: Equatable {
    var paths: [String]
    var line: Int?
}

enum FileLinks {
    /// Everything in a piece of text that could name a file (see TextLinks.mentions).
    static func mentions(in text: String) -> [(range: NSRange, path: String, line: Int?)] { TextLinks.mentions(in: text) }

    /// The full paths `path` could mean: itself, under `home`, or under each of `folders` in turn.
    static func locations(of path: String, in folders: [String], home: String?) -> [String] {
        let full: [String]
        if path.hasPrefix("/") {
            full = [path]
        } else if path.hasPrefix("~/") {
            full = home.map { [$0 + path.dropFirst()] } ?? []
        } else {
            full = folders.map { FilePaths.join($0, path) }
        }
        var seen = Set<String>()
        return full.map { URL(fileURLWithPath: $0).standardized.path }.filter { seen.insert($0).inserted }
    }

    static func looksLikePath(_ s: String) -> Bool { TextLinks.looksLikePath(s) }

    static func isInside(_ path: String, _ folder: String) -> Bool {
        let f = folder.count > 1 && folder.hasSuffix("/") ? String(folder.dropLast()) : folder
        return f == "/" || path == f || path.hasPrefix(f + "/")
    }

    /// The first of `paths` that's a file on `fs`, asking the host about one folder at a time.
    static func firstFile(_ paths: [String], on fs: FileSystem, _ done: @escaping (String?) -> Void) {
        guard let path = paths.first else { return done(nil) }
        fs.list(FilePaths.parent(path)) { result in
            if case .success(let items) = result, items.contains(where: { $0.path == path && !$0.isDirectory && !$0.isDeleted }) {
                done(path)
            } else {
                firstFile(Array(paths.dropFirst()), on: fs, done)
            }
        }
    }
}

extension TerminalView {
    /// The links in a piece of text (see TextLinks.urls).
    static func links(in text: String) -> [(range: NSRange, url: URL)] { TextLinks.urls(in: text) }

    /// The whole wrapped logical line around `pos`, and the cell each UTF-16 unit of it came from.
    private func logicalLine(at pos: GridPos) -> (text: String, map: [GridPos]) {
        let (a, b) = lineRange(at: pos)
        var text = ""
        var map: [GridPos] = []
        for ln in a.line...b.line {
            guard let l = terminal.line(abs: ln) else { continue }
            for x in 0..<l.cells.count {
                let c = l.cells[x]
                if c.width == 0 { continue }
                let s = c.ch == 0 ? " " : String(Character(Unicode.Scalar(c.ch) ?? " "))
                for _ in s.utf16 { map.append(GridPos(line: ln, col: x)) }
                text += s
            }
        }
        return (text, map)
    }

    /// The columns of a line's first and last characters that aren't blank (nil: all blank).
    private func textSpan(_ a: Int) -> (first: Int, last: Int)? {
        guard let l = terminal.line(abs: a) else { return nil }
        let filled = l.cells.indices.filter { l.cells[$0].width != 0 && l.cells[$0].ch != 0 && l.cells[$0].ch != 0x20 }
        return filled.first.map { ($0, filled.last!) }
    }

    /// Whether the logical line ending at line `a` runs on into the next as a link would: Claude Code wraps its replies
    /// itself, so a link longer than the room left breaks at the right edge, with the rest on the next line after an
    /// indent. A line ending in text right up to (nearly) the edge, with the next line starting with text, is one.
    private func continuesLink(after a: Int) -> Bool {
        guard let end = textSpan(a), end.last >= terminal.cols - 3, let next = textSpan(a + 1),
              let l = terminal.line(abs: a + 1), let c = Unicode.Scalar(l.cells[next.first].ch) else { return false }
        return !CharacterSet.whitespaces.contains(c) && c != "●" && c != "⎿" && c != "│"
    }

    /// The text a link under `pos` could be in: its wrapped logical line, joined to the lines before and after it that
    /// Claude Code broke it onto (see continuesLink), without their indents or the edge's blanks; and the cell each
    /// UTF-16 unit came from.
    private func linkLine(at pos: GridPos) -> (text: String, map: [GridPos]) {
        var (a, b) = lineRange(at: pos)
        for _ in 0..<12 where continuesLink(after: a.line - 1) { a = lineRange(at: GridPos(line: a.line - 1, col: 0)).0 }
        for _ in 0..<12 where continuesLink(after: b.line) { b = lineRange(at: GridPos(line: b.line + 1, col: 0)).1 }
        var text = ""
        var map: [GridPos] = []
        var ln = a.line
        while ln <= b.line {
            let (s, e) = lineRange(at: GridPos(line: ln, col: 0))
            var (t, m) = logicalLine(at: s)
            // A continuation starts at its text, and every part but the last stops at its own.
            if ln > a.line, let span = textSpan(s.line) {
                let k = m.firstIndex { $0.col >= span.first } ?? 0
                t = String(t.utf16.dropFirst(k)) ?? t; m.removeFirst(k)
            }
            if e.line < b.line, let span = textSpan(e.line) {
                let k = m.lastIndex { $0.line < e.line || $0.col <= span.last }.map { $0 + 1 } ?? m.count
                t = String(t.utf16.prefix(k)) ?? t; m = Array(m.prefix(k))
            }
            text += t; map += m
            ln = e.line + 1
        }
        return (text, map)
    }

    /// Each row's part of the text from `range` in `map` (a link that wraps covers several rows).
    private func rows(_ range: NSRange, _ map: [GridPos]) -> [LinkRow] {
        var out: [LinkRow] = []
        for p in map[range.location..<(range.location + range.length)] {
            if let i = out.indices.last, out[i].line == p.line {
                out[i].start = min(out[i].start, p.col); out[i].end = max(out[i].end, p.col)
            } else {
                out.append(LinkRow(line: p.line, start: p.col, end: p.col))
            }
        }
        return out
    }

    /// Finds a link under the given point: one a program printed (OSC 8), or a URL in the text, searching the whole
    /// wrapped logical line and the lines Claude Code broke it onto. Gives the hovered row's part and every row's.
    func urlAt(_ p: NSPoint) -> (url: URL, line: Int, start: Int, end: Int, rows: [LinkRow])? {
        let pos = gridPos(at: p)
        if let l = terminal.line(abs: pos.line), let target = l.links?[pos.col] {
            guard let url = Self.hyperlinkURL(target) else { return nil }
            // The hovered row's run of cells linking there, and the runs above and below it that carry on to there.
            func run(_ a: Int, around col: Int) -> LinkRow? {
                guard let l = terminal.line(abs: a), l.links?[col] == target else { return nil }
                var s = col, e = col
                while s > 0, l.links?[s - 1] == target { s -= 1 }
                while e + 1 < l.cells.count, l.links?[e + 1] == target { e += 1 }
                return LinkRow(line: a, start: s, end: e)
            }
            guard let here = run(pos.line, around: pos.col) else { return nil }
            var rows = [here]
            while rows.count < 12, let top = rows.first, top.start <= 8,
                  let up = terminal.line(abs: top.line - 1), let col = (0..<up.cells.count).last(where: { up.links?[$0] == target }),
                  col >= terminal.cols - 3, let r = run(top.line - 1, around: col) { rows.insert(r, at: 0) }
            while rows.count < 12, let bottom = rows.last, bottom.end >= terminal.cols - 3,
                  let down = terminal.line(abs: bottom.line + 1), let col = (0..<down.cells.count).first(where: { down.links?[$0] == target }),
                  col <= 8, let r = run(bottom.line + 1, around: col) { rows.append(r) }
            return (url, here.line, here.start, here.end, rows)
        }
        let (text, map) = linkLine(at: pos)
        for (r, url) in Self.links(in: text) {
            let first = map[r.location], last = map[r.location + r.length - 1]
            guard pos >= first && pos <= last else { continue }
            let rows = rows(r, map)
            let here = rows.first { $0.line == pos.line } ?? rows[0]
            return (url, here.line, here.start, here.end, rows)
        }
        return nil
    }

    /// The folders that count as this pane's: its shell's folder and, on the same machine, the tab's pinned folder.
    /// Relative paths are looked for in them, and a file in either opens above the terminal.
    var fileLinkFolders: [String] {
        var folders = browseDirectory.map { [$0] } ?? []
        if let pin = tab?.pinnedFolder, pin.fs === fileSystem, !folders.contains(pin.path) { folders.append(pin.path) }
        return folders
    }

    /// The file named under the given point: on this Mac one that exists, on an ssh host one that may (checked on click).
    func fileLinkAt(_ p: NSPoint) -> (link: FileLink, line: Int, start: Int, end: Int, rows: [LinkRow])? {
        let pos = gridPos(at: p)
        let (text, map) = logicalLine(at: pos)
        let fs = fileSystem, folders = fileLinkFolders
        let here = FileLinks.mentions(in: text).filter { pos >= map[$0.range.location] && pos <= map[NSMaxRange($0.range) - 1] }
        func link(_ paths: [String], _ line: Int?, _ range: NSRange) -> (link: FileLink, line: Int, start: Int, end: Int, rows: [LinkRow]) {
            let rows = rows(range, map)
            let u = rows.first { $0.line == pos.line } ?? rows[0]
            return (FileLink(paths: paths, line: line), u.line, u.start, u.end, rows)
        }
        guard fs.isRemote else {
            for m in here {
                if let path = FileLinks.locations(of: m.path, in: folders, home: fs.home).first(where: Self.isLocalFile) { return link([path], m.line, m.range) }
            }
            return nil
        }
        // Quoted words that aren't a path can't be told apart without asking the host, so the click tries each in turn.
        let worthTrying = here.filter { FileLinks.looksLikePath($0.path) }
        guard let widest = worthTrying.first else { return nil }
        return link(worthTrying.flatMap { FileLinks.locations(of: $0.path, in: folders, home: fs.home) },
                    worthTrying.lazy.compactMap(\.line).first, widest.range)
    }

    private static func isLocalFile(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue
    }

    /// Where an OSC 8 link goes: web, mail and file links only. ls --hyperlink and the like name the host in file
    /// links; one on this Mac opens, one on another host (from an ssh session) isn't a link here.
    static func hyperlinkURL(_ s: String) -> URL? {
        guard var c = URLComponents(string: s), let scheme = c.scheme?.lowercased(),
              ["http", "https", "file", "ftp", "mailto"].contains(scheme) else { return nil }
        if scheme == "file" {
            if let h = c.host?.lowercased(), !h.isEmpty, h != "localhost", !localHostNames.contains(h) { return nil }
            c.host = ""
        }
        return c.url
    }

    /// This Mac's host name, with and without ".local".
    private static let localHostNames: Set<String> = {
        var buf = [CChar](repeating: 0, count: 256)
        guard gethostname(&buf, buf.count) == 0 else { return [] }
        let name = String(cString: buf).lowercased()
        let short = name.hasSuffix(".local") ? String(name.dropLast(6)) : name
        return [name, short, short + ".local"]
    }()

    /// Whether a plain click on a link in this line opens it: not in the line being typed (where a click places
    /// the text cursor) and not while a program reads the mouse.
    func plainClickOpensLinks(on line: Int) -> Bool {
        guard terminal.mouseMode == .none else { return false }
        guard !terminal.usingAlt, let b = terminal.currentBlock else { return true }
        if b.state == .running {
            guard let rows = terminal.agentInputRows(b) else { return true }
            return !(rows.contains(line) && rows.contains(terminal.cursorAbs))
        }
        guard b.state == .prompt, let start = b.commandLine else { return true }
        return line < start || line > max(start, terminal.cursorAbs)
    }

    func updateLinkHover(_ p: NSPoint, cmd: Bool) {
        // Moving onto the card keeps it open.
        if hoverURL != nil, linkCardRect.insetBy(dx: 0, dy: -5).contains(p) {
            if !hoverLinkCard { hoverLinkCard = true; needsDisplay = true }
            return
        }
        var newHover: LinkHover?
        if bounds.contains(p), let u = urlAt(p), cmd || plainClickOpensLinks(on: u.line) {
            if let h = hoverURL, h.url == u.url, h.line == u.line, h.start == u.start {
                newHover = h
            } else {
                let opener = Self.opener(for: u.url)
                newHover = LinkHover(url: u.url, line: u.line, start: u.start, end: u.end, rows: u.rows, opener: opener.name, icon: opener.icon)
            }
        } else if cmd, bounds.contains(p), let f = fileLinkAt(p) {
            let url = URL(fileURLWithPath: f.link.paths[0])
            if let h = hoverURL, h.url == url, h.line == f.line, h.start == f.start, h.file == f.link {
                newHover = h
            } else {
                let above = (tab?.owner as? TabColumn) == nil || fileLinkFolders.contains { FileLinks.isInside(f.link.paths[0], $0) }
                newHover = LinkHover(url: url, line: f.line, start: f.start, end: f.end, rows: f.rows, opener: above ? "Open in Editor" : "Open in New Tab",
                                     icon: NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil), file: f.link)
            }
        }
        let changed = newHover?.line != hoverURL?.line || newHover?.start != hoverURL?.start || newHover?.url != hoverURL?.url
        if changed || hoverLinkCard {
            hoverURL = newHover
            hoverLinkCard = false
            updateCursor()
            needsDisplay = true
        }
    }

    /// file:// links to files open in Solanum's editor; folders and web links go to their usual app.
    func openLink(_ url: URL) {
        var isDir: ObjCBool = false
        if url.isFileURL, FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue,
           let app = NSApp.delegate as? AppDelegate {
            app.openInEditor(url.path)
        } else {
            NSWorkspace.shared.open(url)
        }
        clearLinkHover()
    }

    /// A file named in the text opens above this terminal when it's in one of the pane's folders, else in its own tab.
    func openFileLink(_ link: FileLink) {
        clearLinkHover()
        let fs = fileSystem, folders = fileLinkFolders
        let open: (String) -> Void = { [weak self] path in
            self?.tab?.openLinkedFile(fs, path, line: link.line, folders: folders)
        }
        guard fs.isRemote else { return link.paths.first.map(open) ?? () }
        FileLinks.firstFile(link.paths, on: fs) { path in
            if let path { open(path) } else { NSSound.beep() }
        }
    }

    private func clearLinkHover() {
        hoverURL = nil
        hoverLinkCard = false
        updateCursor()
        needsDisplay = true
    }

    /// What a click on the link does, for the card: "Open in Safari" with Safari's icon, or the editor or Finder.
    static func opener(for url: URL) -> (name: String, icon: NSImage?) {
        if url.isFileURL {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue {
                return ("Open in Editor", NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil))
            }
        }
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return ("Open", nil) }
        let info = Bundle(url: app)?.infoDictionary
        let name = info?["CFBundleDisplayName"] as? String ?? info?["CFBundleName"] as? String ?? app.deletingPathExtension().lastPathComponent
        return ("Open in \(name)", NSWorkspace.shared.icon(forFile: app.path))
    }

    // MARK: - Local servers

    static func isLocal(_ url: URL) -> Bool {
        guard let h = url.host?.lowercased(), url.scheme == "http" || url.scheme == "https" else { return false }
        return h == "localhost" || h.hasSuffix(".localhost") || h == "127.0.0.1" || h == "::1" || h == "0.0.0.0"
    }

    /// Whether a local server answers at the link's address: nil until the first check comes back. Checked in the
    /// background with a quick request (any reply at all counts) and re-checked when a few seconds old.
    func localServerUp(_ url: URL) -> Bool? {
        guard Self.isLocal(url), let host = url.host else { return nil }
        let key = "\(host):\(url.port ?? (url.scheme == "https" ? 443 : 80))"
        let known = LocalProbes.results[key]
        if let k = known, Date().timeIntervalSince(k.at) < 4 { return k.up }
        guard !LocalProbes.inFlight.contains(key) else { return known?.up }
        LocalProbes.inFlight.insert(key)
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 1.5)
        req.httpMethod = "HEAD"
        LocalProbes.session.dataTask(with: req) { _, response, _ in
            DispatchQueue.main.async { [weak self] in
                LocalProbes.inFlight.remove(key)
                let up = response != nil
                let changed = LocalProbes.results[key]?.up != up
                LocalProbes.results[key] = (up, Date())
                if changed, let self, self.hoverURL?.url == url { self.needsDisplay = true }
            }
        }.resume()
        return known?.up
    }

    // MARK: - Card

    /// The card over the hovered link: [browser icon] address · ● running · Open in Chrome ↗.
    func drawLinkCard(_ ctx: CGContext) {
        linkCardRect = .null
        guard let h = hoverURL, let r = rowMap.firstIndex(of: h.line) else { return }
        let th = palette.theme
        let font = NSFont.systemFont(ofSize: max(10, fonts.size - 2.5), weight: .medium)
        let gap: CGFloat = 8

        var address = h.url.isFileURL ? h.url.path + (h.file?.line.map { ":\($0)" } ?? "") : h.url.absoluteString
        if let range = address.range(of: "://") { address.removeSubrange(address.startIndex..<range.upperBound) }
        if address.hasSuffix("/") { address.removeLast() }
        if address.count > 56 { address = address.prefix(36) + "…" + String(address.suffix(19)) }
        var parts: [NSAttributedString] = [NSAttributedString(string: address, attributes: [.font: font, .foregroundColor: th.foreground])]
        if Self.isLocal(h.url) {
            let (text, color): (String, NSColor)
            switch localServerUp(h.url) {
            case nil: (text, color) = ("○ checking", th.dimText)
            case true?: (text, color) = ("● running", th.green)
            case false?: (text, color) = ("● not responding", th.red)
            }
            parts.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
        }
        let actionColor = hoverLinkCard ? th.foreground : th.dimText
        parts.append(NSAttributedString(string: h.opener, attributes: [.font: font, .foregroundColor: actionColor]))
        let arrow = NSImage(systemSymbolName: "arrow.up.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: font.pointSize - 2, weight: .semibold).applying(.init(paletteColors: [actionColor])))

        let iconSide = font.pointSize + 3
        let textH = parts[0].size().height
        let w = 10 + (h.icon == nil ? 0 : iconSide + 6) + parts.reduce(0) { $0 + $1.size().width } + CGFloat(parts.count - 1) * gap * 2
            + (arrow.map { $0.size.width + 4 } ?? 0) + 10
        let height = max(textH, iconSide) + 8
        let linkX = padX + CGFloat(h.start) * fonts.cellW
        let x = max(4, min(linkX - 6, bounds.width - w - 8))
        let above = rowY(r) - scrollPixelShift - height - 2
        let y = above >= 2 ? above : rowY(r) - scrollPixelShift + fonts.cellH + 2
        let rect = CGRect(x: x, y: y, width: w, height: height)
        linkCardRect = rect

        let path = CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: 8, color: NSColor.black.withAlphaComponent(0.3).cgColor)
        ctx.setFillColor(th.surface.cgColor)
        ctx.addPath(path)
        ctx.fillPath()
        ctx.restoreGState()
        if hoverLinkCard {
            ctx.setFillColor(th.foreground.withAlphaComponent(0.08).cgColor)
            ctx.addPath(path)
            ctx.fillPath()
        }
        ctx.setStrokeColor(th.border.cgColor)
        ctx.setLineWidth(1)
        ctx.addPath(path)
        ctx.strokePath()

        func drawImage(_ img: NSImage, _ frame: CGRect) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            img.draw(in: frame)
            NSGraphicsContext.restoreGraphicsState()
        }
        var tx = rect.minX + 10
        if let icon = h.icon {
            let img = icon.isTemplate ? icon.withSymbolConfiguration(.init(paletteColors: [th.dimText])) ?? icon : icon
            drawImage(img, CGRect(x: tx, y: rect.midY - iconSide / 2, width: iconSide, height: iconSide))
            tx += iconSide + 6
        }
        for (i, part) in parts.enumerated() {
            if i > 0 {
                ctx.setFillColor(th.border.cgColor)
                ctx.fill(CGRect(x: tx + gap - 0.5, y: rect.minY + 6, width: 1, height: rect.height - 12))
                tx += gap * 2
            }
            drawLabel(part, at: CGPoint(x: tx, y: rect.midY - textH / 2), ctx)
            tx += part.size().width
        }
        if let arrow {
            drawImage(arrow, CGRect(x: tx + 4, y: rect.midY - arrow.size.height / 2, width: arrow.size.width, height: arrow.size.height))
        }
    }
}

/// Local server checks, shared by every terminal.
enum LocalProbes {
    static var results: [String: (up: Bool, at: Date)] = [:]
    static var inFlight = Set<String>()
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 1.5
        c.connectionProxyDictionary = [:]
        return URLSession(configuration: c)
    }()
}
