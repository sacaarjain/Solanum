import AppKit

// Images pasted into Claude Code. "[Image #N]" stays as text where it's typed; the image itself shows where Claude
// Code lists a sent prompt's attachments ("⎿  [Image #8]" under the prompt), and, while a prompt is being written,
// above its input box. Clicking one opens it in a small popup; clicking the popup opens the file. Claude Code keeps
// each image pasted into a session as /tmp/claude-<uid>/<cwd, non-alphanumerics as "-">/<session>/images/<N>.png,
// the session being its transcript's name in ~/.claude/projects/<same>/. An image pasted here is also kept from the
// clipboard and matched to the next new "[Image #N]", in case that file isn't there yet.

/// Finds the image behind each "[Image #N]".
enum ClaudeImages {
    struct Found {
        let image: NSImage
        /// The file Claude Code saved it as; nil when only the clipboard copy is known.
        let url: URL?
    }

    private static var found: [String: Found] = [:]
    /// Lookups that came up empty, retried after a moment (Claude may still be writing the file).
    private static var missing: [String: Date] = [:]
    /// The newest session per folder, re-read every couple of seconds.
    private static var sessions: [String: (id: String?, checked: Date)] = [:]

    static func slug(_ cwd: String) -> String {
        String(String.UnicodeScalarView(cwd.unicodeScalars.map { $0.isASCII && CharacterSet.alphanumerics.contains($0) ? $0 : "-" }))
    }

    /// The Claude session most recently active in `cwd`: its newest transcript.
    private static func session(_ cwd: String) -> String? {
        if let s = sessions[cwd], Date().timeIntervalSince(s.checked) < 2 { return s.id }
        let dir = NSHomeDirectory() + "/.claude/projects/" + slug(cwd)
        let fm = FileManager.default
        let newest = ((try? fm.contentsOfDirectory(atPath: dir)) ?? [])
            .filter { $0.hasSuffix(".jsonl") }
            .map { ($0, (try? fm.attributesOfItem(atPath: dir + "/" + $0)[.modificationDate] as? Date) ?? .distantPast) }
            .max { $0.1 < $1.1 }
        let id = newest.map { String($0.0.dropLast(6)) }
        sessions[cwd] = (id, Date())
        return id
    }

    static func lookup(_ n: Int, cwd: String) -> Found? {
        guard let s = session(cwd) else { return nil }
        let key = "\(s)|\(n)"
        if let f = found[key] { return f }
        if let t = missing[key], Date().timeIntervalSince(t) < 1.5 { return nil }
        let url = URL(fileURLWithPath: "/private/tmp/claude-\(getuid())/\(slug(cwd))/\(s)/images/\(n).png")
        guard let image = NSImage(contentsOf: url) else {
            missing[key] = Date()
            return nil
        }
        let f = Found(image: image, url: url)
        found[key] = f
        missing[key] = nil
        return f
    }

    /// An image pasted here, before (or instead of) Claude Code's own copy.
    static func remember(_ image: NSImage, as n: Int, cwd: String) {
        guard let s = session(cwd) else { return }
        found["\(s)|\(n)"] = Found(image: image, url: nil)
    }
}

/// Per terminal: the thumbnails drawn this frame, the one hovered, and the one open in a popup.
final class ImageChipState {
    var chips: [(rect: CGRect, n: Int, found: ClaudeImages.Found)] = []
    /// This frame's groups of images and the space each may use (`bottom`: kept to the bottom of it).
    var strips: [(images: [(n: Int, found: ClaudeImages.Found)], area: CGRect, bottom: Bool)] = []
    /// "[Image #N]" text under a thumbnail, by line: left undrawn.
    var hidden: [Int: [Range<Int>]] = [:]
    var hover: Int?
    /// The image shown in a popup (clicked), and where that popup was drawn.
    var popup: Int?
    var popupRect: CGRect = .null
    /// Images pasted here, oldest first, each waiting for its "[Image #N]" to appear.
    var pending: [(image: NSImage, at: Date)] = []
    /// Numbers already on screen, so a new one can be matched to `pending`.
    var seen: Set<Int> = []
}

extension TerminalView {
    /// Remembers the clipboard's image as it's pasted into Claude Code.
    func notePastedImage(_ pb: NSPasteboard) {
        var image = NSImage(pasteboard: pb)
        if image == nil, let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let u = urls.first, ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp"].contains(u.pathExtension.lowercased()) {
            image = NSImage(contentsOf: u)
        }
        if let image { imageChipState.pending.append((image, Date())) }
    }

    /// "[Image #N]" runs on a line: (start column, length, N).
    private func imageTokens(_ line: Line) -> [(Int, Int, Int)] {
        let c = line.cells
        let word = Array("Image #".unicodeScalars.map(\.value))
        var out: [(Int, Int, Int)] = []
        var i = 0
        while i < c.count {
            guard c[i].ch == 0x5B, i + 1 + word.count < c.count else { i += 1; continue }
            var ok = true
            for (k, w) in word.enumerated() where c[i + 1 + k].ch != w { ok = false; break }
            var j = i + 1 + word.count
            var n = 0
            while ok, j < c.count, c[j].ch >= 0x30, c[j].ch <= 0x39, n < 100_000 { n = n * 10 + Int(c[j].ch - 0x30); j += 1 }
            if ok, j > i + 1 + word.count, j < c.count, c[j].ch == 0x5D {
                out.append((i, j - i + 1, n))
                i = j + 1
            } else {
                i += 1
            }
        }
        return out
    }

    /// Blank in Claude Code's output, which lays out with no-break spaces.
    private static func isSpace(_ ch: UInt32) -> Bool { ch == 0 || ch == 0x20 || ch == 0xA0 }

    /// "⎿  [Image #8] [Image #9]": a sent prompt's attachments, as Claude Code lists them under it. Nil for any
    /// other line (inline mentions stay text).
    private func attachmentTokens(_ line: Line) -> [(Int, Int, Int)]? {
        let c = line.cells
        guard let mark = c.firstIndex(where: { !Self.isSpace($0.ch) }), c[mark].ch == 0x23BF else { return nil }
        let tokens = imageTokens(line)
        guard !tokens.isEmpty else { return nil }
        var covered = Set<Int>()
        for (start, len, _) in tokens { covered.formUnion(start..<(start + len)) }
        for x in (mark + 1)..<max(mark + 1, line.trimmedLength) where !covered.contains(x) && !Self.isSpace(c[x].ch) {
            return nil
        }
        return tokens
    }

    /// Blank screen rows next to row `r` (below when `down`, else above), at most `limit`: room for a taller thumbnail.
    private func blankRows(from r: Int, down: Bool, limit: Int) -> Int {
        var k = 0
        while k < limit {
            let i = down ? r + 1 + k : r - 1 - k
            guard rowMap.indices.contains(i), rowMap[i] >= 0 else { break }
            if let l = terminal.line(abs: rowMap[i]), l.cells.contains(where: { !Self.isSpace($0.ch) || $0.bg != 0 }) { break }
            k += 1
        }
        return k
    }

    /// Before the text is drawn: which images show where, and which "[Image #N]" text they replace (left undrawn,
    /// see `drawCells`). An attachment line's images, and those of the lines right after it (Claude Code lists each
    /// image on its own "⎿" line), share the run's rows and the blank rows below; the prompt being written shows its
    /// images in the blank rows above its input box.
    func layoutImageChips() {
        let st = imageChipState
        st.strips = []
        st.hidden = [:]
        guard remote == nil, let pid = pty?.foregroundPID, let cwd = PTYProcess.directory(of: pid) else { return }
        var onScreen: Set<Int> = []
        // Pastes still waiting after 10 s never got a number of their own.
        st.pending.removeAll { Date().timeIntervalSince($0.at) > 10 }
        /// `pasted`: a number in the prompt being written, where a new paste's number appears.
        func image(_ n: Int, pasted: Bool = false) -> ClaudeImages.Found? {
            if let f = ClaudeImages.lookup(n, cwd: cwd) { return f }
            // A number not seen before, after a paste here: the oldest pasted image still waiting. (Claude Code may
            // only save an image when the prompt is sent, so while it's being written this copy is all there is.)
            guard pasted, !st.seen.contains(n), !st.pending.isEmpty else { return nil }
            ClaudeImages.remember(st.pending.removeFirst().image, as: n, cwd: cwd)
            st.seen.insert(n)
            return ClaudeImages.lookup(n, cwd: cwd)
        }
        let block = terminal.currentBlock
        let boxRows = block.flatMap { terminal.agentInputRows($0) }
        let boxTop = block.flatMap { terminal.agentInputBoxTop($0) }
        var inBox: [Int] = []
        var run: (row: Int, x: CGFloat, images: [(n: Int, found: ClaudeImages.Found)], rows: Int)?
        func endRun() {
            guard let g = run else { return }
            run = nil
            let rows = g.rows + blankRows(from: g.row + g.rows - 1, down: true, limit: 3)
            st.strips.append((g.images, CGRect(x: g.x, y: rowY(g.row) + 2, width: bounds.width - g.x - padX,
                                               height: CGFloat(rows) * fonts.cellH - 6), false))
        }
        for (r, abs) in rowMap.enumerated() {
            guard abs >= 0, let line = terminal.line(abs: abs) else { endRun(); continue }
            let tokens = imageTokens(line)
            tokens.forEach { onScreen.insert($0.2) }
            if let rows = boxRows, rows.contains(abs) {
                endRun()
                for t in tokens where !inBox.contains(t.2) { inBox.append(t.2) }
                continue
            }
            guard let attached = attachmentTokens(line) else { endRun(); continue }
            let found = attached.compactMap { t in image(t.2).map { (t, $0) } }
            guard let first = found.first else { endRun(); continue }
            for (t, _) in found { st.hidden[abs, default: []].append(t.0..<(t.0 + t.1)) }
            let x = padX + CGFloat(first.0.0) * fonts.cellW
            if var g = run, g.row + g.rows == r {
                g.images += found.map { ($0.0.2, $0.1) }.filter { new in !g.images.contains { $0.n == new.0 } }
                g.rows += 1
                run = g
            } else {
                endRun()
                run = (r, x, found.map { ($0.0.2, $0.1) }, 1)
            }
        }
        endRun()
        if let top = boxTop, let r = rowMap.firstIndex(of: top) {
            let images = inBox.compactMap { n in image(n, pasted: true).map { (n, $0) } }
            if !images.isEmpty {
                let rows = max(1, blankRows(from: r, down: false, limit: 3))
                let height = CGFloat(rows) * fonts.cellH - 6
                let x = padX + fonts.cellW * 2
                st.strips.append((images, CGRect(x: x, y: rowY(r) - height - 3, width: bounds.width - x - padX, height: height), true))
            }
        }
        st.seen.formUnion(onScreen)
    }

    /// The thumbnails laid out by `layoutImageChips`, drawn over the text.
    func drawImageChips(_ ctx: CGContext) {
        let st = imageChipState
        st.chips = []
        let th = palette.theme
        for strip in st.strips {
            for (rect, n, f) in Self.wrap(strip.images, in: strip.area, bottom: strip.bottom, minHeight: fonts.cellH - 6) {
                drawThumb(rect, n: n, image: f.image, hovered: st.hover == n, open: st.popup == n, th: th, ctx)
                st.chips.append((rect, n, f))
            }
        }
        if let n = st.popup, !st.chips.contains(where: { $0.n == n }) { st.popup = nil }
    }

    /// Thumbnails in rows across `area`: as tall as fits (wrapping onto more rows when there are many), never
    /// larger than the image itself, each keeping its shape within limits. At the top of the area, or the bottom.
    private static func wrap(_ images: [(n: Int, found: ClaudeImages.Found)], in area: CGRect, bottom: Bool,
                             minHeight: CGFloat) -> [(CGRect, Int, ClaudeImages.Found)] {
        guard !images.isEmpty, area.width > 20 else { return [] }
        let gap: CGFloat = 6
        let shapes = images.map { item -> (aspect: CGFloat, natural: CGFloat) in
            let s = item.found.image.size
            guard s.width > 0, s.height > 0 else { return (1.5, area.height) }
            return (min(max(s.width / s.height, 0.75), 2.5), s.height)
        }
        /// Rows of (index, size) at height `h`.
        func lines(_ h: CGFloat) -> [[(Int, CGSize)]] {
            var out: [[(Int, CGSize)]] = [[]]
            var x: CGFloat = 0
            for (i, shape) in shapes.enumerated() {
                let ih = min(h, max(shape.natural, minHeight))
                let size = CGSize(width: (ih * shape.aspect).rounded(), height: ih)
                if x > 0, x + size.width > area.width { out.append([]); x = 0 }
                out[out.count - 1].append((i, size))
                x += size.width + gap
            }
            return out
        }
        var h = area.height
        var rows = lines(h)
        while h > minHeight, CGFloat(rows.count) * h + CGFloat(rows.count - 1) * gap > area.height {
            h = max(minHeight, h - 2)
            rows = lines(h)
        }
        let total = rows.reduce(CGFloat(0)) { $0 + ($1.map(\.1.height).max() ?? 0) } + CGFloat(rows.count - 1) * gap
        var y = bottom ? area.maxY - total : area.minY
        var out: [(CGRect, Int, ClaudeImages.Found)] = []
        for row in rows {
            var x = area.minX
            let rowH = row.map(\.1.height).max() ?? 0
            for (i, size) in row {
                let rect = CGRect(x: x, y: bottom ? y + rowH - size.height : y, width: size.width, height: size.height)
                out.append((rect, images[i].n, images[i].found))
                x = rect.maxX + gap
            }
            y += rowH + gap
        }
        return out
    }

    /// A thumbnail with rounded corners, a hairline border (the accent while hovered or open) and its number.
    private func drawThumb(_ rect: CGRect, n: Int, image: NSImage, hovered: Bool, open: Bool, th: Theme, _ ctx: CGContext) {
        let path = CGPath(roundedRect: rect, cornerWidth: 4, cornerHeight: 4, transform: nil)
        ctx.saveGState()
        ctx.setFillColor(th.background.mix(th.foreground, 0.06).cgColor)
        ctx.addPath(path)
        ctx.fillPath()
        ctx.addPath(path)
        ctx.clip()
        let s = image.size
        if s.width > 0, s.height > 0 {
            let scale = max(rect.width / s.width, rect.height / s.height)
            let w = s.width * scale, h = s.height * scale
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            image.draw(in: CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h), from: .zero, operation: .sourceOver,
                       fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
            NSGraphicsContext.restoreGraphicsState()
        }
        // "#N" in the corner, when there's room.
        if rect.height >= 18 {
            let label = NSAttributedString(string: "#\(n)", attributes: [.font: NSFont.systemFont(ofSize: 9.5, weight: .semibold),
                                                                        .foregroundColor: NSColor.white])
            let ls = label.size()
            let tag = CGRect(x: rect.minX + 3, y: rect.maxY - ls.height - 4, width: ls.width + 8, height: ls.height + 1)
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
            ctx.addPath(CGPath(roundedRect: tag, cornerWidth: 3, cornerHeight: 3, transform: nil))
            ctx.fillPath()
            drawLabel(label, at: CGPoint(x: tag.minX + 4, y: tag.minY + 0.5), ctx)
        }
        ctx.restoreGState()
        ctx.setStrokeColor((hovered || open ? th.accent : th.foreground.withAlphaComponent(0.25)).cgColor)
        ctx.setLineWidth(hovered || open ? 1.5 : 1)
        ctx.addPath(path)
        ctx.strokePath()
    }

    /// The clicked image, larger, in a card above its thumbnail (below when there's no room).
    func drawImagePreview(_ ctx: CGContext) {
        let st = imageChipState
        st.popupRect = .null
        guard let n = st.popup, let chip = st.chips.first(where: { $0.n == n }) else { return }
        let th = palette.theme
        let s = chip.found.image.size
        guard s.width > 0, s.height > 0 else { return }
        let maxW = min(420, bounds.width - 24), maxH = min(300, bounds.height * 0.55)
        let scale = min(maxW / s.width, maxH / s.height, 2)
        let iw = (s.width * scale).rounded(), ih = (s.height * scale).rounded()
        let pad: CGFloat = 6, caption: CGFloat = 18
        // The caption sets a minimum width, so a tall, narrow image doesn't leave it hanging off the card.
        let px = chip.found.image.representations.first.map { "\($0.pixelsWide) × \($0.pixelsHigh)" } ?? ""
        let label = NSAttributedString(string: "Image #\(n)" + (px.isEmpty ? "" : "  ·  \(px)") + "  ·  click to open",
                                       attributes: [.font: NSFont.systemFont(ofSize: 10.5, weight: .medium), .foregroundColor: th.dimText])
        let w = max(iw, ceil(label.size().width) + 2) + pad * 2, h = ih + pad * 2 + caption
        var y = chip.rect.minY - h - 6
        if y < 4 { y = chip.rect.maxY + 6 }
        let x = max(8, min(chip.rect.minX, bounds.width - w - 8))
        let card = CGRect(x: x, y: y, width: w, height: h)
        st.popupRect = card
        let path = CGPath(roundedRect: card, cornerWidth: 8, cornerHeight: 8, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 4), blur: 14, color: NSColor.black.withAlphaComponent(0.45).cgColor)
        ctx.setFillColor(th.background.mix(th.foreground, th.isDark ? 0.07 : 0.03).cgColor)
        ctx.addPath(path)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.setStrokeColor(th.border.cgColor)
        ctx.addPath(path)
        ctx.strokePath()
        let imageRect = CGRect(x: card.midX - iw / 2, y: card.minY + pad, width: iw, height: ih)
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: imageRect, cornerWidth: 5, cornerHeight: 5, transform: nil))
        ctx.clip()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        chip.found.image.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                              hints: [.interpolation: NSImageInterpolation.high.rawValue])
        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()
        drawLabel(label, at: CGPoint(x: card.minX + pad + 1, y: imageRect.maxY + 3), ctx)
    }

    func imageChip(at p: NSPoint) -> (rect: CGRect, n: Int, found: ClaudeImages.Found)? {
        imageChipState.chips.first { $0.rect.contains(p) }
    }

    /// A click on a thumbnail opens (or closes) its popup; on the popup, opens the image; anywhere else, closes the
    /// popup. Returns whether the click was used up.
    func handleImageClick(at p: NSPoint) -> Bool {
        let st = imageChipState
        if st.popupRect.contains(p), let n = st.popup, let chip = st.chips.first(where: { $0.n == n }) {
            openImageChip(chip)
            return true
        }
        if let chip = imageChip(at: p) {
            st.popup = st.popup == chip.n ? nil : chip.n
            needsDisplay = true
            return true
        }
        if st.popup != nil {
            st.popup = nil
            needsDisplay = true
        }
        return false
    }

    /// Opens an image in the default viewer (Claude Code's saved copy, or the pasted one written out).
    func openImageChip(_ chip: (rect: CGRect, n: Int, found: ClaudeImages.Found)) {
        if let url = chip.found.url { NSWorkspace.shared.open(url); return }
        guard let tiff = chip.found.image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("solanum-image-\(chip.n)-\(UUID().uuidString.prefix(6)).png")
        if (try? png.write(to: url)) != nil { NSWorkspace.shared.open(url) }
    }
}
