import AppKit

// Links in the terminal's text (http(s), file and ftp URLs, and bare localhost:PORT addresses) open with a click.
// Under the pointer a link is underlined and a small card above it says where it goes and what opens it (the
// default browser, with its icon), and for a local server whether anything is answering there. In the line being
// typed, or while a program reads the mouse itself, a plain click keeps its usual meaning and links take ⌘-click.

/// The link under the pointer, and what it opens with.
struct LinkHover {
    var url: URL
    /// The screen line and columns of the underlined part (the hovered row's part of a link that wraps).
    var line: Int
    var start: Int
    var end: Int
    var opener: String
    var icon: NSImage?
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
        for (r, url) in Self.links(in: text) {
            let first = map[r.location], last = map[r.location + r.length - 1]
            guard pos >= first && pos <= last else { continue }
            if first.line == last.line { return (url, first.line, first.col, last.col) }
            // Multi-line links: underline only the hovered row's portion.
            let s = pos.line == first.line ? first.col : 0
            let en = pos.line == last.line ? last.col : terminal.cols - 1
            return (url, pos.line, s, en)
        }
        return nil
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

        var address = h.url.isFileURL ? h.url.path : h.url.absoluteString
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
