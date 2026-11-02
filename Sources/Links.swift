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
    /// The screen line and columns of the underlined part (the hovered row's part of a link that wraps).
    var line: Int
    var start: Int
    var end: Int
    var opener: String
    var icon: NSImage?
    /// Set when this is a file named in the text rather than a URL.
    var file: FileLink?
}

/// A file named in the terminal's text: where it may be (nearest folder first; just one on this Mac, where it was
/// looked for already) and the line to go to.
struct FileLink: Equatable {
    var paths: [String]
    var line: Int?
}

enum FileLinks {
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
        let ns = text as NSString
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

    /// Where looking is slow (an ssh host), what's worth offering a click on before looking.
    static func looksLikePath(_ s: String) -> Bool {
        guard !s.hasSuffix("/"), s.contains(where: { $0.isLetter || $0.isNumber }) else { return false }
        return s.contains("/") || !(s as NSString).pathExtension.isEmpty
    }

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
    static let urlRegex = try? NSRegularExpression(
        pattern: #"(?:https?|file|ftp)://[^\s<>"'`]+|\b(?:localhost|127\.0\.0\.1|0\.0\.0\.0)(?::\d{2,5})(?:/[^\s<>"'`]*)?"#)

    /// The links in a piece of text: trailing punctuation is left out, a bare localhost address gets http://, and
    /// 0.0.0.0 (where servers say they listen) becomes localhost, which browsers open.
    static func links(in text: String) -> [(range: NSRange, url: URL)] {
        guard let re = urlRegex else { return [] }
        let ns = text as NSString
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

    /// The part to underline of a link from `first` to `last`: for one that wraps, the hovered row's portion.
    private func underlined(_ pos: GridPos, _ first: GridPos, _ last: GridPos) -> (line: Int, start: Int, end: Int) {
        if first.line == last.line { return (first.line, first.col, last.col) }
        return (pos.line, pos.line == first.line ? first.col : 0, pos.line == last.line ? last.col : terminal.cols - 1)
    }

    /// Finds a link under the given point: one a program printed (OSC 8), or a URL in the text, searching the whole
    /// wrapped logical line.
    func urlAt(_ p: NSPoint) -> (url: URL, line: Int, start: Int, end: Int)? {
        let pos = gridPos(at: p)
        if let l = terminal.line(abs: pos.line), let target = l.links?[pos.col] {
            guard let url = Self.hyperlinkURL(target) else { return nil }
            // The hovered row's run of cells linking there.
            var s = pos.col, e = pos.col
            while s > 0, l.links?[s - 1] == target { s -= 1 }
            while l.links?[e + 1] == target { e += 1 }
            return (url, pos.line, s, e)
        }
        let (text, map) = logicalLine(at: pos)
        for (r, url) in Self.links(in: text) {
            let first = map[r.location], last = map[r.location + r.length - 1]
            guard pos >= first && pos <= last else { continue }
            let u = underlined(pos, first, last)
            return (url, u.line, u.start, u.end)
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
    func fileLinkAt(_ p: NSPoint) -> (link: FileLink, line: Int, start: Int, end: Int)? {
        let pos = gridPos(at: p)
        let (text, map) = logicalLine(at: pos)
        let fs = fileSystem, folders = fileLinkFolders
        let here = FileLinks.mentions(in: text).filter { pos >= map[$0.range.location] && pos <= map[NSMaxRange($0.range) - 1] }
        func link(_ paths: [String], _ line: Int?, _ range: NSRange) -> (link: FileLink, line: Int, start: Int, end: Int) {
            let u = underlined(pos, map[range.location], map[NSMaxRange(range) - 1])
            return (FileLink(paths: paths, line: line), u.line, u.start, u.end)
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
                newHover = LinkHover(url: u.url, line: u.line, start: u.start, end: u.end, opener: opener.name, icon: opener.icon)
            }
        } else if cmd, bounds.contains(p), let f = fileLinkAt(p) {
            let url = URL(fileURLWithPath: f.link.paths[0])
            if let h = hoverURL, h.url == url, h.line == f.line, h.start == f.start, h.file == f.link {
                newHover = h
            } else {
                let above = (tab?.owner as? TabColumn) == nil || fileLinkFolders.contains { FileLinks.isInside(f.link.paths[0], $0) }
                newHover = LinkHover(url: url, line: f.line, start: f.start, end: f.end, opener: above ? "Open in Editor" : "Open in New Tab",
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
