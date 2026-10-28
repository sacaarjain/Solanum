import AppKit

// "[Image #N]" in Claude Code (in its input box, and in the prompts it shows above) gets a thumbnail of that image
// drawn over it; hovering shows it larger and clicking opens it. Claude Code keeps each image pasted into a
// session as /tmp/claude-<uid>/<cwd, non-alphanumerics as "-">/<session>/images/<N>.png, the session being its
// transcript's name in ~/.claude/projects/<same>/. An image pasted here is also kept from the clipboard and
// matched to the next new "[Image #N]", in case that file isn't there yet.

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

/// Per terminal: the chips drawn this frame, and the one hovered or just pasted.
final class ImageChipState {
    var chips: [(rect: CGRect, n: Int, found: ClaudeImages.Found)] = []
    var hover: Int?
    /// Shown for a moment after pasting, without hovering.
    var flash: Int?
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

    /// A rounded chip over each "[Image #N]" whose image is known: the thumbnail, then "Image #N" (or "#N").
    func drawImageChips(_ ctx: CGContext) {
        let st = imageChipState
        st.chips = []
        guard remote == nil, let pid = pty?.foregroundPID, let cwd = PTYProcess.directory(of: pid) else { return }
        let th = palette.theme
        let font = NSFont.systemFont(ofSize: max(9.5, fonts.size - 2.5), weight: .medium)
        var onScreen: Set<Int> = []
        for (r, abs) in rowMap.enumerated() where abs >= 0 {
            guard let line = terminal.line(abs: abs) else { continue }
            for (col, len, n) in imageTokens(line) {
                onScreen.insert(n)
                var f = ClaudeImages.lookup(n, cwd: cwd)
                // A number not seen before, right after a paste here: that's the pasted image. Preview it a moment.
                var justPasted = false
                if !st.seen.contains(n), let p = st.pending, Date().timeIntervalSince(p.at) < 10 {
                    if f == nil {
                        ClaudeImages.remember(p.image, as: n, cwd: cwd)
                        f = ClaudeImages.lookup(n, cwd: cwd)
                    }
                    st.pending = nil
                    justPasted = true
                }
                guard let f else { continue }
                if justPasted { flashImage(n) }
                let rect = CGRect(x: padX + CGFloat(col) * fonts.cellW, y: rowY(r) + 1, width: CGFloat(len) * fonts.cellW, height: fonts.cellH - 2)
                drawChip(rect, n: n, image: f.image, hovered: st.hover == n, font: font, th: th, ctx)
                st.chips.append((rect, n, f))
            }
        }
        st.seen.formUnion(onScreen)
    }

    private func drawChip(_ rect: CGRect, n: Int, image: NSImage, hovered: Bool, font: NSFont, th: Theme, _ ctx: CGContext) {
        let pill = CGPath(roundedRect: rect, cornerWidth: 4, cornerHeight: 4, transform: nil)
        // Opaque first, so the bracketed text underneath doesn't show through.
        ctx.setFillColor(th.background.mix(th.accent, hovered ? 0.22 : 0.12).cgColor)
        ctx.addPath(pill)
        ctx.fillPath()
        ctx.setStrokeColor(th.accent.withAlphaComponent(hovered ? 0.8 : 0.45).cgColor)
        ctx.setLineWidth(1)
        ctx.addPath(pill)
        ctx.strokePath()
        // Thumbnail, cropped to fill a small landscape frame.
        let thumbH = rect.height - 4
        let thumb = CGRect(x: rect.minX + 2, y: rect.minY + 2, width: min(thumbH * 1.5, rect.width * 0.4), height: thumbH)
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: thumb, cornerWidth: 2.5, cornerHeight: 2.5, transform: nil))
        ctx.clip()
        let s = image.size
        if s.width > 0, s.height > 0 {
            let scale = max(thumb.width / s.width, thumb.height / s.height)
            let w = s.width * scale, h = s.height * scale
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            image.draw(in: CGRect(x: thumb.midX - w / 2, y: thumb.midY - h / 2, width: w, height: h), from: .zero, operation: .sourceOver,
                       fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
            NSGraphicsContext.restoreGraphicsState()
        }
        ctx.restoreGState()
        let color = hovered ? th.foreground : th.foreground.withAlphaComponent(0.85)
        let room = rect.maxX - thumb.maxX - 9
        var label = NSAttributedString(string: "Image #\(n)", attributes: [.font: font, .foregroundColor: color])
        if label.size().width > room { label = NSAttributedString(string: "#\(n)", attributes: [.font: font, .foregroundColor: color]) }
        let size = label.size()
        drawLabel(label, at: CGPoint(x: thumb.maxX + 5 + max(0, (room - size.width) / 2), y: rect.midY - size.height / 2), ctx)
    }

    /// Shows the preview card for `n` for a moment (after pasting it).
    func flashImage(_ n: Int) {
        imageChipState.flash = n
        needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, self.imageChipState.flash == n else { return }
            self.imageChipState.flash = nil
            self.needsDisplay = true
        }
    }

    /// The hovered (or just pasted) image, larger, in a card above its chip (below when there's no room).
    func drawImagePreview(_ ctx: CGContext) {
        let st = imageChipState
        guard let n = st.hover ?? st.flash, let chip = st.chips.first(where: { $0.n == n }) else { return }
        let th = palette.theme
        let s = chip.found.image.size
        guard s.width > 0, s.height > 0 else { return }
        let maxW = min(320, bounds.width - 24), maxH = min(220, bounds.height * 0.45)
        let scale = min(maxW / s.width, maxH / s.height, 2)
        let iw = (s.width * scale).rounded(), ih = (s.height * scale).rounded()
        let pad: CGFloat = 6, caption: CGFloat = 18
        let w = iw + pad * 2, h = ih + pad * 2 + caption
        var y = chip.rect.minY - h - 6
        if y < 4 { y = chip.rect.maxY + 6 }
        let x = max(8, min(chip.rect.minX, bounds.width - w - 8))
        let card = CGRect(x: x, y: y, width: w, height: h)
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
        let text = "Image #\(n)" + (px.isEmpty ? "" : "  ·  \(px)") + (chip.found.url != nil ? "  ·  click to open" : "")
        let label = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: th.dimText])
        drawLabel(label, at: CGPoint(x: card.minX + pad + 1, y: imageRect.maxY + 3), ctx)
    }

    func imageChip(at p: NSPoint) -> (rect: CGRect, n: Int, found: ClaudeImages.Found)? {
        imageChipState.chips.first { $0.rect.contains(p) }
    }

    /// Opens a chip's image in the default viewer (Claude Code's saved copy, or the pasted one written out).
    func openImageChip(_ chip: (rect: CGRect, n: Int, found: ClaudeImages.Found)) {
        if let url = chip.found.url { NSWorkspace.shared.open(url); return }
        guard let tiff = chip.found.image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("solanum-image-\(chip.n)-\(UUID().uuidString.prefix(6)).png")
        if (try? png.write(to: url)) != nil { NSWorkspace.shared.open(url) }
    }
}
