import CCanvas
import Foundation
import WinSDK

// Images pasted into Claude Code, as on the Mac (ImageChips.swift there). "[Image #N]" stays text where it's typed; the
// image itself shows where Claude Code lists a sent prompt's attachments ("⎿  [Image #8]" under the prompt), and, while
// a prompt is being written, above its input box. Clicking one opens a larger look; clicking that opens the file.
//
// On Windows, Claude Code keeps each image pasted into a session as %TEMP%\claude\<a hash of the folder>\<session>\images\
// <N>.png, the session named in %USERPROFILE%\.claude\sessions\<pid>.json. It writes the file just after showing
// "[Image #N]", so a lookup that misses is tried again for a while.

/// Finds the file behind each "[Image #N]".
enum ClaudeImages {
    struct Found {
        let path: String
        let width: Int32
        let height: Int32
    }

    private static var found: [String: Found] = [:]
    /// Lookups that came up empty: when first and last tried (Claude may still be writing the file).
    private static var missing: [String: (first: Date, last: Date)] = [:]
    private static let extensions = ["png", "jpg", "jpeg", "gif", "webp"]
    /// The Claude under each shell and its session, looked at again every couple of seconds (/clear and /resume
    /// change the session).
    private static var sessions: [DWORD: (id: String?, checked: Date)] = [:]
    /// Each session's images folder, once found.
    private static var folders: [String: String] = [:]

    private static var home: String { ProcessInfo.processInfo.environment["USERPROFILE"] ?? "" }
    private static var temp: String {
        let env = ProcessInfo.processInfo.environment
        return env["TEMP"] ?? env["TMP"] ?? (env["LOCALAPPDATA"].map { $0 + "\\Temp" } ?? "")
    }

    /// For off-screen drawing: a session and its images folder, in place of a running Claude's.
    static var testing: (session: String, folder: String)? {
        didSet { if let t = testing { folders[t.session] = t.folder } }
    }

    /// The session of the Claude running under `shell`: the first process beneath it with a session file.
    static func session(under shell: DWORD) -> String? {
        if let t = testing { return t.session }
        if let s = sessions[shell], Date().timeIntervalSince(s.checked) < 2 { return s.id }
        var id: String?
        let dir = home + "\\.claude\\sessions\\"
        for p in ProcessTree.descendants(of: shell) {
            guard let data = FileManager.default.contents(atPath: dir + "\(p.pid).json"),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let s = json["sessionId"] as? String else { continue }
            id = s
            break
        }
        sessions[shell] = (id, Date())
        return id
    }

    /// The session's images folder, in whichever of Claude's temp folders has it.
    private static func folder(for session: String) -> String? {
        if let known = folders[session] { return known }
        let root = temp + "\\claude"
        for hash in (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [] {
            let candidate = root + "\\" + hash + "\\" + session + "\\images"
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDir), isDir.boolValue {
                folders[session] = candidate
                return candidate
            }
        }
        return nil
    }

    /// Claude Code's file for image `n`. `retry` is set while a miss is new enough that the file may still be on its
    /// way (the caller draws again soon to look).
    static func lookup(_ n: Int, session: String, canvas: Canvas, retry: inout Bool) -> Found? {
        let key = "\(session)|\(n)"
        if let f = found[key] { return f }
        let now = Date()
        if let m = missing[key], now.timeIntervalSince(m.last) < 0.25 {
            if now.timeIntervalSince(m.first) < 10 { retry = true }
            return nil
        }
        let dir = folder(for: session)
        guard let dir, let path = extensions.lazy.map({ dir + "\\\(n).\($0)" }).first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            let first = missing[key]?.first ?? now
            missing[key] = (first, now)
            if now.timeIntervalSince(first) < 10 { retry = true }
            return nil
        }
        var w: Int32 = 0, h: Int32 = 0
        guard wide(path).withUnsafeBufferPointer({ sol_image_file_size(canvas.raw, $0.baseAddress, &w, &h) }) >= 0, w > 0, h > 0 else {
            missing[key] = (missing[key]?.first ?? now, now)
            retry = true
            return nil
        }
        let f = Found(path: path, width: w, height: h)
        found[key] = f
        missing[key] = nil
        return f
    }

    /// Images to draw, by canvas and file, made no bigger than they're shown.
    private static var images: [String: Int32] = [:]

    static func image(_ f: Found, on canvas: Canvas) -> Int32? {
        let key = "\(ObjectIdentifier(canvas))|\(f.path)"
        if let known = images[key] { return known >= 0 ? known : nil }
        let made = wide(f.path).withUnsafeBufferPointer { sol_canvas_load_image_file(canvas.raw, $0.baseAddress, 900) }
        images[key] = made
        return made >= 0 ? made : nil
    }
}

/// Per terminal: where the thumbnails go this frame, the one hovered, and the one open larger.
final class ImageChips {
    private(set) var chips: [(rect: UIRect, n: Int, found: ClaudeImages.Found)] = []
    /// "[Image #N]" text under a thumbnail, by line: left undrawn.
    private(set) var hidden: [Int: [Range<Int>]] = [:]
    private var strips: [(images: [(n: Int, found: ClaudeImages.Found)], area: UIRect, bottom: Bool)] = []
    var hover: Int?
    /// The image shown larger (clicked), and where that card was drawn.
    var popup: Int?
    private var popupRect: UIRect?
    /// A lookup missed and should be tried again shortly.
    private(set) var wantsRetry = false

    /// Before the text is drawn: which images show where, and which "[Image #N]" they cover. An attachment line's
    /// images, and those of the lines right after it (Claude Code lists each on its own "⎿" line), share the run's rows
    /// and the blank rows below; the prompt being written shows its images in the blank rows above its input box.
    func layout(terminal: Terminal, top: Int, canvas: Canvas, shell: DWORD, scale: Float) {
        strips = []
        hidden = [:]
        wantsRetry = false
        guard let session = ClaudeImages.session(under: shell) else { chips = []; return }
        let m = canvas.metrics, rows = terminal.rows
        let right = (canvas.terminalArea.map { $0.maxX } ?? canvas.contentX + Float(terminal.cols) * m.cellWidth) - canvas.padding
        func y(_ row: Int) -> Float { canvas.contentY + Float(row) * m.cellHeight }
        func blankRows(from r: Int, down: Bool, limit: Int) -> Int {
            var k = 0
            while k < limit {
                let i = down ? r + 1 + k : r - 1 - k
                guard i >= 0, i < rows else { break }
                if let l = terminal.line(abs: top + i), !ImageTokens.isBlank(l) { break }
                k += 1
            }
            return k
        }
        var retry = false
        func image(_ n: Int) -> ClaudeImages.Found? { ClaudeImages.lookup(n, session: session, canvas: canvas, retry: &retry) }
        let block = terminal.currentBlock
        let boxRows = block.flatMap { terminal.agentInputRows($0) }
        let boxTop = block.flatMap { terminal.agentInputBoxTop($0) }
        var inBox: [Int] = []
        var run: (row: Int, x: Float, images: [(n: Int, found: ClaudeImages.Found)], rows: Int)?
        func endRun() {
            guard let g = run else { return }
            run = nil
            let count = g.rows + blankRows(from: g.row + g.rows - 1, down: true, limit: 3)
            strips.append((g.images, UIRect(x: g.x, y: y(g.row) + 2 * scale, width: right - g.x, height: Float(count) * m.cellHeight - 6 * scale), false))
        }
        for r in 0..<rows {
            let abs = top + r
            guard let line = terminal.line(abs: abs) else { endRun(); continue }
            if let box = boxRows, box.contains(abs) {
                endRun()
                for t in ImageTokens.tokens(line) where !inBox.contains(t.number) { inBox.append(t.number) }
                continue
            }
            guard let attached = ImageTokens.attachments(line) else { endRun(); continue }
            let found = attached.compactMap { t in image(t.number).map { (t, $0) } }
            guard let first = found.first else { endRun(); continue }
            for (t, _) in found { hidden[abs, default: []].append(t.start..<(t.start + t.length)) }
            let x = canvas.contentX + Float(first.0.start) * m.cellWidth
            if var g = run, g.row + g.rows == r {
                g.images += found.map { ($0.0.number, $0.1) }.filter { new in !g.images.contains { $0.n == new.0 } }
                g.rows += 1
                run = g
            } else {
                endRun()
                run = (r, x, found.map { ($0.0.number, $0.1) }, 1)
            }
        }
        endRun()
        if let boxTop, boxTop - top >= 0, boxTop - top < rows {
            let r = boxTop - top
            let images = inBox.compactMap { n in image(n).map { (n, $0) } }
            if !images.isEmpty {
                let count = max(1, blankRows(from: r, down: false, limit: 3))
                let height = Float(count) * m.cellHeight - 6 * scale
                let x = canvas.contentX + m.cellWidth * 2
                strips.append((images, UIRect(x: x, y: y(r) - height - 3 * scale, width: right - x, height: height), true))
            }
        }
        wantsRetry = retry
        // Thumbnails' places, for clicks before the next frame.
        chips = []
        for strip in strips {
            let area = ImageTokens.Rect(x: Double(strip.area.x), y: Double(strip.area.y), width: Double(strip.area.width), height: Double(strip.area.height))
            let sizes = strip.images.map { (width: Double($0.found.width), height: Double($0.found.height)) }
            for (i, r) in ImageTokens.wrap(sizes, in: area, bottom: strip.bottom, minHeight: Double(m.cellHeight - 6 * scale), gap: Double(6 * scale)).enumerated() {
                chips.append((UIRect(x: Float(r.x), y: Float(r.y), width: Float(r.width), height: Float(r.height)), strip.images[i].n, strip.images[i].found))
            }
        }
        if let n = popup, !chips.contains(where: { $0.n == n }) { popup = nil }
    }

    /// The thumbnails, over the text.
    func draw(on canvas: Canvas, scale s: Float) {
        for chip in chips { drawThumb(chip.rect, n: chip.n, found: chip.found, on: canvas, scale: s) }
        drawPopup(on: canvas, scale: s)
    }

    /// Rounded corners, a hairline border (the accent while hovered or open) and its number.
    private func drawThumb(_ r: UIRect, n: Int, found: ClaudeImages.Found, on canvas: Canvas, scale s: Float) {
        let c = canvas.raw, fg = TerminalPalette.foreground, radius = 4 * s
        let lit = hover == n || popup == n
        sol_canvas_fill_rounded(c, r.x, r.y, r.width, r.height, radius, TerminalPalette.mix(fg, TerminalPalette.background, 0.06), 1)
        if let image = ClaudeImages.image(found, on: canvas) {
            // Filling the tile, unless that would enlarge it: then whole, at most its own size, centered.
            let iw = Float(found.width), ih = Float(found.height)
            let fill = max(r.width / iw, r.height / ih)
            let k = fill <= 1 ? fill : min(1, r.width / iw, r.height / ih)
            let w = iw * k, h = ih * k
            if fill <= 1 {
                sol_canvas_fill_rounded_image(c, image, r.x, r.y, r.width, r.height, radius, r.x + (r.width - w) / 2, r.y + (r.height - h) / 2, w, h)
            } else {
                let x = r.x + (r.width - w) / 2, y = r.y + (r.height - h) / 2
                sol_canvas_fill_rounded_image(c, image, x, y, w, h, min(radius, w / 2, h / 2), x, y, w, h)
            }
        }
        // "#N" in the corner, when there's room.
        if r.height >= 18 * s {
            let label = Array("#\(n)".utf16), px = 9.5 * s
            let lw = sol_canvas_measure_label(c, label, Int32(label.count), px, 1)
            let tag = UIRect(x: r.x + 3 * s, y: r.maxY - 15 * s, width: lw + 8 * s, height: 12 * s)
            sol_canvas_fill_rounded(c, tag.x, tag.y, tag.width, tag.height, 3 * s, 0x000000, 0.55)
            sol_canvas_draw_label(c, tag.x + 4 * s, tag.y, lw + 2, tag.height, label, Int32(label.count), px, 1, 0xFFFFFF, 1)
        }
        sol_canvas_stroke_rounded(c, r.x + 0.5, r.y + 0.5, r.width - 1, r.height - 1, radius, lit ? TerminalPalette.accent : fg, lit ? 1 : 0.25, lit ? 1.5 * s : 1)
    }

    /// The clicked image, larger, in a card above its thumbnail (below when there's no room).
    private func drawPopup(on canvas: Canvas, scale s: Float) {
        popupRect = nil
        guard let n = popup, let chip = chips.first(where: { $0.n == n }), let image = ClaudeImages.image(chip.found, on: canvas) else { return }
        let c = canvas.raw, fg = TerminalPalette.foreground
        let area = canvas.terminalArea ?? UIRect(x: 0, y: 0, width: 800, height: 600)
        let iw0 = Float(chip.found.width), ih0 = Float(chip.found.height)
        let maxW = min(420 * s, area.width - 24 * s), maxH = min(300 * s, area.height * 0.55)
        let k = min(maxW / iw0, maxH / ih0, 2 * s)
        let iw = (iw0 * k).rounded(), ih = (ih0 * k).rounded()
        let pad = 6 * s, captionH = 18 * s
        let caption = "Image #\(n)  \u{00B7}  \(chip.found.width) \u{00D7} \(chip.found.height)  \u{00B7}  click to open"
        let units = Array(caption.utf16), px = 10.5 * s
        let cw = sol_canvas_measure_label(c, units, Int32(units.count), px, 1)
        let w = max(iw, cw + 2) + pad * 2, h = ih + pad * 2 + captionH
        var y = chip.rect.y - h - 6 * s
        if y < area.y + 4 * s { y = chip.rect.maxY + 6 * s }
        let x = max(area.x + 8 * s, min(chip.rect.x, area.maxX - w - 8 * s))
        let card = UIRect(x: x, y: y, width: w, height: h)
        popupRect = card
        for (grow, alpha) in [(Float(8), Float(0.08)), (4, 0.12), (2, 0.16)] {
            let g = grow * s
            sol_canvas_fill_rounded(c, card.x - g, card.y - g + 3 * s, card.width + g * 2, card.height + g * 2, 8 * s + g, 0x000000, alpha)
        }
        sol_canvas_fill_rounded(c, card.x, card.y, card.width, card.height, 8 * s,
                                TerminalPalette.mix(fg, TerminalPalette.background, TerminalPalette.isDark ? 0.07 : 0.03), 1)
        sol_canvas_stroke_rounded(c, card.x + 0.5, card.y + 0.5, card.width - 1, card.height - 1, 8 * s, fg, 0.15, 1)
        let ir = UIRect(x: card.x + (card.width - iw) / 2, y: card.y + pad, width: iw, height: ih)
        sol_canvas_fill_rounded_image(c, image, ir.x, ir.y, ir.width, ir.height, 5 * s, ir.x, ir.y, ir.width, ir.height)
        sol_canvas_draw_label(c, card.x + pad + 1, ir.maxY + 2 * s, card.width - pad * 2, captionH, units, Int32(units.count), px, 1, fg, 0.55)
    }

    /// Nothing to show (no agent running).
    func clear() {
        chips = []
        hidden = [:]
        strips = []
        popup = nil
        wantsRetry = false
    }

    /// A move: which thumbnail is under the pointer. True if that changed.
    func hovered(atX x: Float, y: Float) -> Bool {
        let now = chips.first { $0.rect.contains(x, y) }?.n
        guard now != hover else { return false }
        hover = now
        return true
    }

    /// A click on a thumbnail opens (or closes) its larger look; on that, opens the image; anywhere else, closes it.
    /// Whether the click was used up, and whether anything changed.
    func click(atX x: Float, y: Float) -> (used: Bool, changed: Bool) {
        if let card = popupRect, card.contains(x, y), let n = popup, let chip = chips.first(where: { $0.n == n }) {
            _ = wide(chip.found.path).withUnsafeBufferPointer { ShellExecuteW(nil, nil, $0.baseAddress, nil, nil, 1) }
            return (true, false)
        }
        if let chip = chips.first(where: { $0.rect.contains(x, y) }) {
            popup = popup == chip.n ? nil : chip.n
            return (true, true)
        }
        if popup != nil {
            popup = nil
            return (false, true)
        }
        return (false, false)
    }

    /// Whether a point is on a thumbnail or the open card: the pointer becomes a hand there.
    func isOver(x: Float, y: Float) -> Bool {
        chips.contains { $0.rect.contains(x, y) } || (popupRect?.contains(x, y) ?? false)
    }
}
