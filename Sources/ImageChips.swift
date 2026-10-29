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
    var hover: Int?
    /// The image shown in a popup (clicked), and where that popup was drawn.
    var popup: Int?
    var popupRect: CGRect = .null
    /// An image pasted here, waiting for its "[Image #N]" to appear.
    var pending: (image: NSImage, at: Date)?
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
        if let image { imageChipState.pending = (image, Date()) }
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

    /// "⎿  [Image #8] [Image #9]": a sent prompt's attachments, as Claude Code lists them under it. Nil for any
    /// other line (inline mentions stay text).
    private func attachmentTokens(_ line: Line) -> [(Int, Int, Int)]? {
        let c = line.cells
        guard let mark = c.firstIndex(where: { $0.ch != 0x20 && $0.ch != 0 }), c[mark].ch == 0x23BF else { return nil }
        let tokens = imageTokens(line)
        guard !tokens.isEmpty else { return nil }
        var covered = Set<Int>()
        for (start, len, _) in tokens { covered.formUnion(start..<(start + len)) }
        for x in (mark + 1)..<max(mark + 1, line.trimmedLength) where !covered.contains(x) && c[x].ch != 0x20 && c[x].ch != 0 {
            return nil
        }
        return tokens
    }

    /// Blank screen rows next to row `r` (below when `down`, else above), at most `limit`: room for a taller thumbnail.
    private func blankRows(from r: Int, down: Bool, limit: Int) -> Int {
        var k = 0
        while k < limit {
            let i = down ? r + 1 + k : r - 1 - k
            guard rowMap.indices.contains(i), rowMap[i] >= 0, terminal.line(abs: rowMap[i])?.isBlank ?? true else { break }
            k += 1
        }
        return k
    }

    /// The images on screen: in place of each attachment line's "[Image #N]", and above the live input box for the
    /// ones in the prompt being written.
    func drawImageChips(_ ctx: CGContext) {
        let st = imageChipState
        st.chips = []
        guard remote == nil, let pid = pty?.foregroundPID, let cwd = PTYProcess.directory(of: pid) else { return }
        let th = palette.theme
        var onScreen: Set<Int> = []
        func image(_ n: Int) -> ClaudeImages.Found? {
            if let f = ClaudeImages.lookup(n, cwd: cwd) { return f }
            // A number not seen before, right after a paste here: that's the pasted image.
            guard !st.seen.contains(n), let p = st.pending, Date().timeIntervalSince(p.at) < 10 else { return nil }
            ClaudeImages.remember(p.image, as: n, cwd: cwd)
            st.pending = nil
            return ClaudeImages.lookup(n, cwd: cwd)
        }
        // Thumbnails `height` tall, keeping each image's shape (within limits), left to right from `x`.
        func strip(_ ns: [Int], x: CGFloat, top: CGFloat, height: CGFloat) {
            var x = x
            for n in ns {
                guard let f = image(n) else { continue }
                let s = f.image.size
                let aspect = s.width > 0 && s.height > 0 ? min(max(s.width / s.height, 0.75), 2.5) : 1.5
                let rect = CGRect(x: x, y: top, width: (height * aspect).rounded(), height: height)
                drawThumb(rect, n: n, image: f.image, hovered: st.hover == n, open: st.popup == n, th: th, ctx)
                st.chips.append((rect, n, f))
                x = rect.maxX + 6
            }
        }

        let block = terminal.currentBlock
        let boxRows = block.flatMap { terminal.agentInputRows($0) }
        let boxTop = block.flatMap { terminal.agentInputBoxTop($0) }
        var inBox: [Int] = []
        for (r, abs) in rowMap.enumerated() where abs >= 0 {
            guard let line = terminal.line(abs: abs) else { continue }
            let tokens = imageTokens(line)
            tokens.forEach { onScreen.insert($0.2) }
            if let rows = boxRows, rows.contains(abs) {
                for t in tokens where !inBox.contains(t.2) { inBox.append(t.2) }
                continue
            }
            guard let attached = attachmentTokens(line), let first = attached.first, let last = attached.last else { continue }
            // Cover the "[Image #N]" text, then draw over it and the blank rows below.
            let y = rowY(r)
            let x = padX + CGFloat(first.0) * fonts.cellW
            ctx.setFillColor(th.background.cgColor)
            ctx.fill(CGRect(x: x, y: y, width: CGFloat(last.0 + last.1 - first.0) * fonts.cellW, height: fonts.cellH))
            let rows = 1 + blankRows(from: r, down: true, limit: 3)
            strip(attached.map(\.2), x: x, top: y + 2, height: CGFloat(rows) * fonts.cellH - 6)
        }
        // The prompt being written: its images in the blank rows above the box's top rule.
        if let top = boxTop, !inBox.isEmpty, let r = rowMap.firstIndex(of: top) {
            let rows = max(1, blankRows(from: r, down: false, limit: 3))
            let height = CGFloat(rows) * fonts.cellH - 6
            strip(inBox, x: padX + fonts.cellW * 2, top: rowY(r) - height - 3, height: height)
        }
        st.seen.formUnion(onScreen)
        if let n = st.popup, !st.chips.contains(where: { $0.n == n }) { st.popup = nil }
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
        let w = iw + pad * 2, h = ih + pad * 2 + caption
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
        let imageRect = CGRect(x: card.minX + pad, y: card.minY + pad, width: iw, height: ih)
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: imageRect, cornerWidth: 5, cornerHeight: 5, transform: nil))
        ctx.clip()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        chip.found.image.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                              hints: [.interpolation: NSImageInterpolation.high.rawValue])
        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()
        let px = chip.found.image.representations.first.map { "\($0.pixelsWide) × \($0.pixelsHigh)" } ?? ""
        let font = NSFont.systemFont(ofSize: 10.5, weight: .medium)
        let text = "Image #\(n)" + (px.isEmpty ? "" : "  ·  \(px)") + "  ·  click to open"
        let label = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: th.dimText])
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
