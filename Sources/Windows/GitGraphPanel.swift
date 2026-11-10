import CCanvas
import Foundation
import WinSDK

// MARK: - Git Graph

/// Every branch's history, as VS Code's Git Graph draws it: a lane for each line of development, with branch and tag
/// labels. Resting the pointer on a commit shows its card (who, when, the full message, how much changed, and buttons to
/// see its changes or copy its hash or message), as on the Mac; clicking it opens its changes in a sub-tab.
final class GitGraphPanel: ColumnPanel {
    let place: GitPlace
    private(set) var head = ""
    private(set) var rows: [GraphRow] = []
    private(set) var loaded = false
    /// The row picked with the arrow keys.
    private(set) var selected: Int?
    private var scroll = 0
    private var hoveredRow: Int?
    private var hoveredPart: String?
    /// The commit whose card is showing, and each commit's full message and size once git has said.
    private(set) var cardRow: Int?
    private var details: [String: (message: String, stats: String)] = [:]
    /// A card button just used to copy: it says "Copied" for a moment.
    private var copied: (button: String, at: Date)?
    var invalidate: () -> Void = {}
    var close: () -> Void = {}
    var copy: (String) -> Void = { _ in }
    var post: (@escaping () -> Void) -> Void = { $0() }
    /// A commit clicked, or its card's View Changes: its hash and subject.
    var openCommit: (String, String) -> Void = { _, _ in }
    /// A dropdown under a filter's button, as the Mac's: its rows, the button, the search box's placeholder (nil for
    /// none), how wide at least (at 100%), and what to do when it closes.
    var showDropdown: (_ items: [MenuItem], _ under: UIRect, _ search: String?, _ minWidth: Float, _ closed: @escaping () -> Void) -> Void = { _, _, _, _, closed in closed() }
    /// The filter whose dropdown is open: its button shows pressed.
    private var openFilter: String?

    // The filters, as the Mac's toolbar has them (Core's GraphFilter): git does the filtering.
    private(set) var filter = GraphFilter()
    /// The search field above the graph, and whether it has the keyboard.
    private var search = TextFieldState("")
    private(set) var searchFocused = false
    private var searchGeneration = 0
    private var refs: GraphRefs?
    private var authors: [String]?
    private var me: String?
    private var paths: [String]?
    private var loadID = 0
    /// Where the toolbar's parts were drawn, for the pointer.
    private var toolbarParts: [(id: String, rect: UIRect)] = []

    init(place: GitPlace) { self.place = place }

    static let laneColors: [UInt32] = [0x4FA3F7, 0xE5A445, 0x6CC97A, 0xD46FC9, 0xE06B6B, 0x5FC9C2, 0xA98BF2, 0xC9B55F]

    func reload() { load(refreshLists: true) }

    /// Reads the history the filters leave (and, with `refreshLists`, the branches, users and paths again).
    private func load(refreshLists: Bool) {
        loadID += 1
        let id = loadID, filter = filter
        if refreshLists { refs = nil; authors = nil; paths = nil }
        place.run(filter.script(), timeout: 60) { [weak self] status, out, _ in
            let (log, topology) = GraphFilter.split(out)
            let parsed: (head: String, commits: [GraphCommit]) = status == 0 || !filter.isEmpty ? GraphCommit.parse(log) : ("", [])
            let rows = GraphLayout.rows(filter.arrange(parsed.commits, topology: topology))
            self?.post {
                guard let self, id == self.loadID else { return }
                self.head = parsed.head
                self.rows = rows
                self.loaded = true
                if let s = self.selected, !rows.indices.contains(s) { self.selected = nil }
                if let c = self.cardRow, !rows.indices.contains(c) { self.cardRow = nil }
                self.invalidate()
            }
        }
    }

    // MARK: The card

    private func showCard(_ row: Int?) {
        guard row != cardRow else { return }
        cardRow = row
        invalidate()
        guard let row, rows.indices.contains(row) else { return }
        let hash = rows[row].commit.hash
        guard details[hash] == nil else { return }
        // The full message, and the size of the change (against the first parent, for a merge).
        let q = RemoteConnection.quote(hash)
        place.run("git show --no-patch --format=%B%x00 \(q); git show --diff-merges=first-parent --shortstat --format= \(q)", timeout: 20) { [weak self] _, out, _ in
            let parts = String(decoding: out, as: UTF8.self).components(separatedBy: "\0")
            let info = (message: parts[0].trimmingCharacters(in: .whitespacesAndNewlines),
                        stats: parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : "")
            self?.post {
                self?.details[hash] = info
                self?.invalidate()
            }
        }
    }

    private static let absolute: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .short
        return f
    }()

    /// The card's parts for the commit on `row`, laid out at `a`'s width.
    private struct Card {
        var box: UIRect
        var byline: UIRect, message: UIRect, stats: UIRect
        var buttons: [(id: String, glyph: UInt16, title: String, rect: UIRect)]
    }

    private func cardTitle(_ id: String, _ normal: String) -> String {
        if let copied, copied.button == id, Date().timeIntervalSince(copied.at) < 1.2 { return "Copied" }
        return normal
    }

    private func card(for row: Int, in a: UIRect, _ p: PanelPaint, _ s: Float) -> Card? {
        guard rows.indices.contains(row) else { return nil }
        let commit = rows[row].commit, l = listArea(a, s)
        let width = min(460 * s, a.width - 24 * s), pad = 12 * s, inner = width - pad * 2
        let message = details[commit.hash]?.message ?? commit.subject
        let units = Array(message.utf16)
        let messageH = min(sol_canvas_paragraph(p.canvas.raw, 0, 0, inner, units, Int32(units.count), 12.5 * s, 0, 0, 0, 1), 12 * 18 * s).rounded(.up)
        let height = pad + 18 * s + 10 * s + messageH + 12 * s + 18 * s + 10 * s + 24 * s + 8 * s
        let r = rowRect(row, a, s)
        let x = max(a.x + 12 * s, a.maxX - width - 56 * s)
        var y = r.maxY + 2 * s
        if y + height > a.maxY - 8 * s { y = max(l.y + 4 * s, r.y - height - 2 * s) }
        let box = UIRect(x: x.rounded(), y: y.rounded(), width: width.rounded(), height: height.rounded())
        var cy = box.y + pad
        let byline = UIRect(x: box.x + pad, y: cy, width: inner, height: 18 * s)
        cy += 18 * s + 10 * s
        let messageRect = UIRect(x: box.x + pad, y: cy, width: inner, height: messageH)
        cy += messageH + 12 * s
        let stats = UIRect(x: box.x + pad, y: cy, width: inner, height: 18 * s)
        cy += 18 * s + 10 * s
        var bx = box.x + pad - 4 * s
        var buttons: [(String, UInt16, String, UIRect)] = []
        for (id, glyph, title) in [("view", UInt16(0xE8A1), "View Changes"), ("hash", UInt16(0xE8C8), String(commit.hash.prefix(8))), ("message", UInt16(0xE8C8), "Message")] {
            let w = max(p.width(title), p.width("Copied")) + 30 * s
            buttons.append((id, glyph, title, UIRect(x: bx, y: cy, width: w, height: 24 * s)))
            bx += w + 10 * s
        }
        return Card(box: box, byline: byline, message: messageRect, stats: stats, buttons: buttons)
    }

    private func drawCard(_ row: Int, in a: UIRect, _ p: PanelPaint, _ s: Float) {
        guard let c = card(for: row, in: a, p, s) else { return }
        let commit = rows[row].commit, raw = p.canvas.raw, fg = p.fg
        let surface = TerminalPalette.mix(0xFFFFFF, TerminalPalette.background, TerminalPalette.isDark ? 0.06 : 0.02)
        sol_canvas_fill_rounded(raw, c.box.x, c.box.y + 3 * s, c.box.width, c.box.height, 8 * s, 0x000000, 0.3)
        sol_canvas_fill_rounded(raw, c.box.x, c.box.y, c.box.width, c.box.height, 8 * s, surface, 1)
        sol_canvas_stroke_rounded(raw, c.box.x + 0.5, c.box.y + 0.5, c.box.width - 1, c.box.height - 1, 8 * s, fg, 0.12, 1)
        // Who and when.
        var x = c.byline.x
        p.icon(0xE77B, UIRect(x: x, y: c.byline.y, width: 14 * s, height: c.byline.height), pixels: 11, alpha: 0.55)
        x += 18 * s
        let authorW = min(p.width(commit.author, semibold: true), c.byline.width * 0.45)
        p.label(commit.author, UIRect(x: x, y: c.byline.y, width: authorW + 2, height: c.byline.height), semibold: true)
        x += authorW + 12 * s
        p.icon(0xE81C, UIRect(x: x, y: c.byline.y, width: 14 * s, height: c.byline.height), pixels: 11, alpha: 0.55)
        x += 18 * s
        let when = GitLook.ago(commit.date) + " (" + Self.absolute.string(from: commit.date) + ")"
        p.label(when, UIRect(x: x, y: c.byline.y, width: max(c.byline.maxX - x, 0), height: c.byline.height), alpha: 0.85)
        // The message, wrapped.
        let message = details[commit.hash]?.message ?? commit.subject
        let units = Array(message.utf16)
        sol_canvas_push_clip(raw, c.message.x, c.message.y, c.message.width, c.message.height)
        _ = sol_canvas_paragraph(raw, c.message.x, c.message.y, c.message.width, units, Int32(units.count), 12.5 * s, 0, fg, 1, 0)
        sol_canvas_pop_clip(raw)
        // Rules between the sections, as in VS Code's card.
        for r in [c.message, c.stats] { p.fill(UIRect(x: c.box.x, y: (r.maxY + 5 * s).rounded(), width: c.box.width, height: 1), fg, 0.10) }
        // How much changed: insertions in green, deletions in red, as git colors them.
        let stats = details[commit.hash].map { $0.stats.isEmpty ? "No changes" : $0.stats } ?? "Loading…"
        var sx = c.stats.x
        for (i, part) in stats.components(separatedBy: ", ").enumerated() {
            let text = (i > 0 ? ", " : "") + part
            let color: UInt32? = part.contains("insertion") ? 0x72BD78 : part.contains("deletion") ? 0xE06B6B : nil
            let w = p.width(text)
            p.label(text, UIRect(x: sx, y: c.stats.y, width: w + 2, height: c.stats.height), color: color)
            sx += w
        }
        // Link-style buttons in the accent color.
        for b in c.buttons {
            let hovered = hoveredPart == "card:" + b.id
            if hovered { p.fill(b.rect, TerminalPalette.accent, 0.12, radius: 4) }
            p.icon(b.glyph, UIRect(x: b.rect.x + 4 * s, y: b.rect.y, width: 14 * s, height: b.rect.height), pixels: 11, color: TerminalPalette.accent)
            p.label(cardTitle(b.id, b.title), UIRect(x: b.rect.x + 22 * s, y: b.rect.y, width: b.rect.width - 24 * s, height: b.rect.height), color: TerminalPalette.accent)
        }
    }

    private func pressCardButton(_ id: String, row: Int) {
        guard rows.indices.contains(row) else { return }
        let commit = rows[row].commit
        switch id {
        case "view":
            cardRow = nil
            openCommit(commit.hash, commit.subject)
        case "hash":
            copy(commit.hash)
            flash(id)
        default:
            copy(details[commit.hash]?.message ?? commit.subject)
            flash(id)
        }
    }

    private func flash(_ id: String) {
        copied = (id, Date())
        invalidate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.3) { [weak self] in self?.post { self?.invalidate() } }
    }

    // MARK: Layout

    private func header(_ a: UIRect, _ s: Float) -> UIRect { UIRect(x: a.x, y: a.y, width: a.width, height: (40 * s).rounded()) }
    private func closeButton(_ a: UIRect, _ s: Float) -> UIRect { UIRect(x: a.maxX - 34 * s, y: a.y + 8 * s, width: 24 * s, height: 24 * s) }
    private func refreshButton(_ a: UIRect, _ s: Float) -> UIRect { UIRect(x: a.maxX - 62 * s, y: a.y + 8 * s, width: 24 * s, height: 24 * s) }
    /// Under the header: the search, then Branch, User, Date and Paths, as the Mac's toolbar.
    private func toolbar(_ a: UIRect, _ s: Float) -> UIRect {
        let h = header(a, s)
        return UIRect(x: a.x, y: h.maxY, width: a.width, height: (36 * s).rounded())
    }
    private func listArea(_ a: UIRect, _ s: Float) -> UIRect {
        let t = toolbar(a, s)
        return UIRect(x: a.x, y: t.maxY, width: a.width, height: max(a.maxY - t.maxY, 0))
    }
    private func rowHeight(_ s: Float) -> Float { (24 * s).rounded() }
    private func laneWidth(_ s: Float) -> Float { (14 * s).rounded() }
    private func rowRect(_ i: Int, _ a: UIRect, _ s: Float) -> UIRect {
        let l = listArea(a, s)
        return UIRect(x: l.x, y: l.y + Float(i - scroll) * rowHeight(s), width: l.width, height: rowHeight(s))
    }
    private var visibleRows: Int = 20
    /// Where the card was last drawn, for the pointer: it keeps the card up while it's over it.
    private var lastCard: Card?

    // MARK: Drawing

    func draw(on canvas: Canvas, in a: UIRect, scale s: Float) {
        let p = PanelPaint(canvas: canvas, scale: s), fg = p.fg
        p.backdrop(a, TerminalPalette.background)
        sol_canvas_push_clip(canvas.raw, a.x, a.y, a.width, a.height)
        defer { sol_canvas_pop_clip(canvas.raw) }
        let h = header(a, s)
        p.backdrop(h, TerminalPalette.chrome)
        p.fill(UIRect(x: a.x, y: h.maxY - 1, width: a.width, height: 1), fg, 0.10)
        p.label("Git Graph" + (rows.isEmpty ? "" : " · \(rows.count) commit\(rows.count == 1 ? "" : "s")"), UIRect(x: a.x + 12 * s, y: h.y, width: a.width * 0.5, height: h.height),
                pixels: 13, semibold: true)
        p.button(0xE72C, refreshButton(a, s), hovered: hoveredPart == "refresh")
        p.button(0xE8BB, closeButton(a, s), hovered: hoveredPart == "close")
        drawToolbar(a, p, s)

        let l = listArea(a, s), rh = rowHeight(s), lw = laneWidth(s)
        visibleRows = max(Int(l.height / rh), 1)
        if !loaded {
            p.label("Loading…", UIRect(x: l.x + 14 * s, y: l.y + 10 * s, width: l.width - 28 * s, height: 22 * s), alpha: 0.55)
        } else if rows.isEmpty {
            p.label(filter.isEmpty ? "No commits here, or not a git repository." : "No commits match these filters.", UIRect(x: l.x + 14 * s, y: l.y + 10 * s, width: l.width - 28 * s, height: 22 * s), alpha: 0.55)
        }
        sol_canvas_push_clip(canvas.raw, l.x, l.y, l.width, l.height)
        func laneX(_ lane: Int) -> Float { l.x + 14 * s + Float(lane) * lw }
        func color(_ c: Int) -> UInt32 { Self.laneColors[c % Self.laneColors.count] }
        for i in rows.indices where i >= scroll && i < scroll + visibleRows + 1 {
            let r = rowRect(i, a, s), row = rows[i], mid = r.midY, thick = 1.6 * s
            if cardRow == i || selected == i { p.fill(r, TerminalPalette.accent, 0.18) } else if hoveredRow == i { p.fill(r, fg, 0.05) }
            for (segment, c) in row.segments {
                switch segment {
                case .through(let lane): sol_canvas_line(canvas.raw, laneX(lane), r.y, laneX(lane), r.maxY, color(c), 0.9, thick)
                case .top(let from, let to): sol_canvas_line(canvas.raw, laneX(from), r.y, laneX(to), mid, color(c), 0.9, thick)
                case .bottom(let from, let to): sol_canvas_line(canvas.raw, laneX(from), mid, laneX(to), r.maxY, color(c), 0.9, thick)
                }
            }
            // A dot for a commit, a ringed dot for a merge, a ring for HEAD, as VS Code marks them.
            let isHead = row.commit.hash == head, cx = laneX(row.lane)
            if isHead {
                sol_canvas_fill_ellipse(canvas.raw, cx, mid, 5 * s, 5 * s, color(row.color), 1)
                sol_canvas_fill_ellipse(canvas.raw, cx, mid, 3 * s, 3 * s, TerminalPalette.background, 1)
            } else if row.commit.parents.count > 1 {
                sol_canvas_fill_ellipse(canvas.raw, cx, mid, 5 * s, 5 * s, color(row.color), 1)
                sol_canvas_fill_ellipse(canvas.raw, cx, mid, 3.4 * s, 3.4 * s, TerminalPalette.background, 1)
                sol_canvas_fill_ellipse(canvas.raw, cx, mid, 2 * s, 2 * s, color(row.color), 1)
            } else {
                sol_canvas_fill_ellipse(canvas.raw, cx, mid, 4 * s, 4 * s, color(row.color), 1)
            }
            var x = laneX(row.width) + 6 * s
            for label in GraphLabel.labels(row.commit.refs).prefix(4) {
                let text = label.kind == .tag ? "◆ " + label.name : label.name + (label.onRemote ? " ☁" : "")
                let w = min(p.width(text, pixels: 11, semibold: true) + 12 * s, 180 * s)
                let pill = UIRect(x: x, y: mid - 9 * s, width: w, height: 18 * s)
                p.fill(pill, label.kind == .tag ? 0xE5A445 : color(row.color), label.current ? 0.95 : 0.35, radius: 9)
                p.label(text, UIRect(x: pill.x + 6 * s, y: pill.y, width: w - 12 * s, height: pill.height), pixels: 11, semibold: true,
                        color: label.current ? TerminalPalette.background : nil)
                x += w + 4 * s
            }
            let meta = row.commit.author + "  ·  " + GitLook.ago(row.commit.date) + "  ·  " + String(row.commit.hash.prefix(7))
            let metaW = min(p.width(meta, pixels: 11.5), r.width * 0.4)
            p.label(row.commit.subject, UIRect(x: x + 2 * s, y: r.y, width: max(r.maxX - metaW - 24 * s - x, 0), height: r.height), alpha: 0.92)
            p.label(meta, UIRect(x: r.maxX - metaW - 12 * s, y: r.y, width: metaW + 2, height: r.height), pixels: 11.5, alpha: 0.45)
        }
        sol_canvas_pop_clip(canvas.raw)
        lastCard = nil
        if let row = cardRow, row >= scroll, row < scroll + visibleRows + 1 {
            lastCard = card(for: row, in: a, p, s)
            drawCard(row, in: a, p, s)
        }
    }

    // MARK: Mouse and keys

    func mouse(_ message: UINT, x: Float, y: Float, in a: UIRect, scale s: Float) -> Bool {
        let before = (hoveredRow, hoveredPart, cardRow)
        hoveredPart = closeButton(a, s).contains(x, y) ? "close" : refreshButton(a, s).contains(x, y) ? "refresh"
            : toolbarParts.first { $0.rect.contains(x, y) }.map { "bar:" + $0.id }
        hoveredRow = nil
        if message == Win.WM_LBUTTONDOWN {
            // The search takes the keyboard when clicked, and gives it back when anything else is.
            let onSearch = hoveredPart == "bar:search"
            if onSearch != searchFocused { searchFocused = onSearch; invalidate() }
        }
        if let part = hoveredPart, part.hasPrefix("bar:") {
            if message == Win.WM_LBUTTONUP, let r = toolbarParts.first(where: { "bar:" + $0.id == part })?.rect { pressToolbar(String(part.dropFirst(4)), r) }
            if before.1 != hoveredPart || message != Win.WM_MOUSEMOVE { invalidate() }
            return true
        }
        if let c = lastCard, let row = cardRow, c.box.contains(x, y) {
            // Over the card: it stays, and its buttons work.
            if let b = c.buttons.first(where: { $0.rect.contains(x, y) }) { hoveredPart = "card:" + b.id }
            if message == Win.WM_LBUTTONUP, let part = hoveredPart, part.hasPrefix("card:") { pressCardButton(String(part.dropFirst(5)), row: row) }
        } else {
            if listArea(a, s).contains(x, y) { hoveredRow = rows.indices.first { $0 >= scroll && rowRect($0, a, s).contains(x, y) } }
            // Resting on a commit shows its card; anywhere else puts it away.
            if message == Win.WM_MOUSEMOVE { showCard(hoveredRow) }
            if message == Win.WM_LBUTTONUP {
                switch hoveredPart {
                case "close": close()
                case "refresh": reload()
                default:
                    if let i = hoveredRow {
                        selected = i
                        cardRow = nil
                        openCommit(rows[i].commit.hash, rows[i].commit.subject)
                    }
                }
            }
        }
        if before.0 != hoveredRow || before.1 != hoveredPart || before.2 != cardRow || message != Win.WM_MOUSEMOVE { invalidate() }
        return true
    }

    func mouseLeft() {
        guard hoveredRow != nil || hoveredPart != nil || cardRow != nil else { return }
        hoveredRow = nil
        hoveredPart = nil
        cardRow = nil
        invalidate()
    }

    func scroll(lines: Int, x: Float, y: Float, in a: UIRect, scale s: Float) {
        scroll = min(max(scroll - lines, 0), max(rows.count - 3, 0))
        // The card stays by the row it was opened for, so scrolling puts it away.
        cardRow = nil
        invalidate()
    }

    func key(_ key: Int32, shift: Bool, ctrl: Bool) -> Bool {
        // Ctrl+F, as the Mac's ⌘F in the graph: its search.
        if ctrl && key == 0x46 {
            searchFocused = true
            invalidate()
            return true
        }
        if searchFocused {
            switch key {
            case Win.VK_ESCAPE, Win.VK_RETURN, Win.VK_DOWN:
                // Back to the commits; Esc with something typed clears it first.
                if key == Win.VK_ESCAPE && !search.text.isEmpty { search = TextFieldState(""); searchChanged() } else { searchFocused = false }
            case Win.VK_BACK: search.deleteBackward(word: ctrl); searchChanged()
            case Win.VK_DELETE: search.deleteForward(); searchChanged()
            case Win.VK_LEFT: search.move(by: -1)
            case Win.VK_RIGHT: search.move(by: 1)
            case Win.VK_HOME: search.move(to: 0)
            case Win.VK_END: search.move(to: search.text.count)
            case 0x56 where ctrl:
                if let text = paste()?.split(whereSeparator: \.isNewline).first { search.insert(String(text)); searchChanged() }
            default: return ctrl ? false : false
            }
            invalidate()
            return true
        }
        switch key {
        case Win.VK_ESCAPE:
            if cardRow != nil { cardRow = nil } else if !filter.isEmpty { clearFilters() } else { close() }
        case Win.VK_UP, Win.VK_DOWN:
            guard !rows.isEmpty else { return true }
            let i = min(max((selected ?? -1) + (key == Win.VK_UP ? -1 : 1), 0), rows.count - 1)
            selected = i
            if i < scroll { scroll = i }
            if i >= scroll + visibleRows { scroll = i - visibleRows + 1 }
            cardRow = nil
            showCard(i)
        case Win.VK_RETURN:
            if let i = selected, rows.indices.contains(i) {
                cardRow = nil
                openCommit(rows[i].commit.hash, rows[i].commit.subject)
            }
        case Win.VK_PRIOR: scroll = max(scroll - visibleRows, 0); cardRow = nil
        case Win.VK_NEXT: scroll = min(scroll + visibleRows, max(rows.count - 3, 0)); cardRow = nil
        case 0x43 where ctrl: if let i = selected, rows.indices.contains(i) { copy(rows[i].commit.hash) }
        default: return ctrl
        }
        invalidate()
        return true
    }

    func typed(_ text: String) {
        guard searchFocused else { return }
        search.insert(text)
        searchChanged()
        invalidate()
    }

    var paste: () -> String? = { nil }

    // MARK: The filters

    /// A moment after typing stops, the history for what's typed (text in a message, or the start of a hash).
    private func searchChanged() {
        searchGeneration += 1
        let generation = searchGeneration
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.post {
                guard let self, generation == self.searchGeneration, self.filter.text != self.search.text else { return }
                self.change { $0.text = self.search.text }
            }
        }
    }

    private func change(_ edit: (inout GraphFilter) -> Void) {
        var f = filter
        edit(&f)
        guard f != filter else { return }
        filter = f
        scroll = 0
        selected = nil
        cardRow = nil
        loaded = false
        load(refreshLists: false)
        invalidate()
    }

    func clearFilters() {
        search = TextFieldState("")
        change { $0 = GraphFilter() }
    }

    private func pressToolbar(_ id: String, _ r: UIRect) {
        switch id {
        case "search": searchFocused = true
        case "regex": change { $0.regex.toggle() }
        case "case": change { $0.matchCase.toggle() }
        case "branch": showBranches(under: r)
        case "user": showUsers(under: r)
        case "date":
            var items = [MenuItem(title: "Any Time", isChecked: filter.days == nil) { [weak self] in self?.change { $0.days = nil } }, .separator]
            for choice in GraphFilter.dayChoices {
                items.append(MenuItem(title: choice.title, isChecked: filter.days == choice.days) { [weak self] in self?.change { $0.days = choice.days } })
            }
            dropdown("date", items, under: r)
        case "paths": showPaths(under: r)
        case "clear": clearFilters()
        default: break
        }
        invalidate()
    }

    /// A filter's dropdown under its button, with a search box, as the Mac's; the button shows pressed while it's open.
    private func dropdown(_ id: String, _ items: [MenuItem], under r: UIRect, search: String = "Filter", minWidth: Float = 200) {
        openFilter = id
        invalidate()
        showDropdown(items, r, search, minWidth) { [weak self] in
            guard let self, self.openFilter == id else { return }
            self.openFilter = nil
            self.invalidate()
        }
    }

    /// Every branch and tag, typed to narrow: All Branches, HEAD, then local, remote and tags.
    private func showBranches(under r: UIRect) {
        guard let refs else {
            place.run(GraphRefs.script, timeout: 30) { [weak self] status, out, _ in
                let parsed = GraphRefs.parse(out)
                self?.post {
                    guard let self, status == 0 else { return }
                    self.refs = parsed
                    self.showBranches(under: r)
                }
            }
            return
        }
        var items = [
            MenuItem(title: "All Branches", isChecked: filter.branch == nil) { [weak self] in self?.change { $0.branch = nil } },
            MenuItem(title: "HEAD" + (refs.current.map { " (\($0))" } ?? ""), isChecked: filter.branch == "HEAD") { [weak self] in self?.change { $0.branch = "HEAD" } },
        ]
        func section(_ title: String, _ names: [String]) {
            guard !names.isEmpty else { return }
            items += [.separator, .header(title)]
            items += names.map { name in MenuItem(title: name, isChecked: filter.branch == name) { [weak self] in self?.change { $0.branch = name } } }
        }
        section("Local", refs.locals)
        section("Remote", refs.remotes)
        section("Tags", refs.tags)
        dropdown("branch", items, under: r, search: "Branch or tag", minWidth: 240)
    }

    /// You, then the most frequent authors of the last 5000 commits.
    private func showUsers(under r: UIRect) {
        guard let authors else {
            place.run("git config user.name; printf '\\036'; git log --all -n 5000 --format=%an | sort | uniq -c | sort -rn | head -40", timeout: 30) { [weak self] _, out, _ in
                let parts = String(decoding: out, as: UTF8.self).components(separatedBy: "\u{1e}")
                let me = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let names = (parts.count > 1 ? parts[1] : "").split(separator: "\n").compactMap { line -> String? in
                    let t = line.trimmingCharacters(in: .whitespaces)
                    guard let space = t.firstIndex(of: " ") else { return nil }
                    return String(t[t.index(after: space)...])
                }
                self?.post {
                    guard let self else { return }
                    self.me = me.isEmpty ? nil : me
                    self.authors = names
                    self.showUsers(under: r)
                }
            }
            return
        }
        var items = [MenuItem(title: "All Users", isChecked: filter.user == nil) { [weak self] in self?.change { $0.user = nil } }]
        if let me { items.append(MenuItem(title: "Me (\(me))", isChecked: filter.user == me) { [weak self] in self?.change { $0.user = me } }) }
        items.append(.separator)
        for name in authors where name != me {
            items.append(MenuItem(title: name, isChecked: filter.user == name) { [weak self] in self?.change { $0.user = name } })
        }
        dropdown("user", items, under: r)
    }

    /// The repository's folders and files (as HEAD has them), folders first, typed to narrow.
    private func showPaths(under r: UIRect) {
        guard let paths else {
            place.run("git ls-tree -r -t --name-only HEAD | head -50000", timeout: 30) { [weak self] _, out, _ in
                let all = String(decoding: out, as: UTF8.self).split(separator: "\n").map(String.init).sorted { a, b in
                    let da = a.split(separator: "/").count, db = b.split(separator: "/").count
                    return da != db ? da < db : a < b
                }
                self?.post {
                    guard let self else { return }
                    self.paths = all
                    self.showPaths(under: r)
                }
            }
            return
        }
        var items = [MenuItem(title: "All Paths", isChecked: filter.path == nil) { [weak self] in self?.change { $0.path = nil } }, .separator]
        items += paths.map { p in MenuItem(title: p, isChecked: filter.path == p) { [weak self] in self?.change { $0.path = p } } }
        dropdown("paths", items, under: r, search: "Folder or file", minWidth: 360)
    }

    /// The search, its regex and case toggles, then Branch, User, Date and Paths, each in the accent color when set.
    private func drawToolbar(_ a: UIRect, _ p: PanelPaint, _ s: Float) {
        let t = toolbar(a, s), fg = p.fg, accent = TerminalPalette.accent
        p.fill(UIRect(x: t.x, y: t.maxY - 1, width: t.width, height: 1), fg, 0.08)
        toolbarParts = []
        let h = (24 * s).rounded(), y = (t.y + (t.height - h) / 2).rounded()
        var x = t.x + 10 * s
        // The search field.
        let fieldW = min(280 * s, max(t.width * 0.3, 140 * s))
        let field = UIRect(x: x, y: y, width: fieldW, height: h)
        p.fill(field, fg, searchFocused ? 0.09 : 0.06, radius: 5)
        if searchFocused { sol_canvas_stroke_rounded(p.canvas.raw, field.x + 0.5, field.y + 0.5, field.width - 1, field.height - 1, 5 * s, accent, 0.8, 1) }
        p.icon(0xE721, UIRect(x: field.x + 4 * s, y: field.y, width: 18 * s, height: h), pixels: 10, alpha: 0.5)
        let inner = UIRect(x: field.x + 24 * s, y: field.y, width: field.width - 80 * s, height: h)
        if search.text.isEmpty {
            p.label("Text or hash", inner, pixels: 12, alpha: 0.4)
        } else {
            sol_canvas_push_clip(p.canvas.raw, inner.x, inner.y, inner.width, inner.height)
            let caretX = p.width(search.beforeCaret, pixels: 12), shift = max(0, caretX - inner.width + 4 * s)
            p.label(search.text, UIRect(x: inner.x - shift, y: inner.y, width: p.width(search.text, pixels: 12) + 4, height: h), pixels: 12)
            if searchFocused { p.fill(UIRect(x: (inner.x - shift + caretX).rounded(), y: field.y + 5 * s, width: max((1.5 * s).rounded(), 1), height: h - 10 * s), accent, 1) }
            sol_canvas_pop_clip(p.canvas.raw)
        }
        if search.text.isEmpty && searchFocused { p.fill(UIRect(x: inner.x, y: field.y + 5 * s, width: max((1.5 * s).rounded(), 1), height: h - 10 * s), accent, 1) }
        toolbarParts.append(("search", UIRect(x: field.x, y: field.y, width: field.width - 52 * s, height: h)))
        // .* and Aa inside the field's right end.
        for (id, title, on) in [("regex", ".*", filter.regex), ("case", "Aa", filter.matchCase)] {
            let r = UIRect(x: field.maxX - (id == "regex" ? 50 : 26) * s, y: field.y + 2 * s, width: 24 * s, height: h - 4 * s)
            let hovered = hoveredPart == "bar:" + id
            if on || hovered { p.fill(r, accent, on ? 0.24 : 0.13, radius: 4) }
            let tw = p.width(title, pixels: 11.5, semibold: true)
            p.label(title, UIRect(x: (r.x + (r.width - tw) / 2).rounded(), y: r.y, width: tw + 2, height: r.height), pixels: 11.5, semibold: true,
                    color: on || hovered ? accent : nil, alpha: on || hovered ? 1 : 0.55)
            toolbarParts.append((id, r))
        }
        x = field.maxX + 10 * s
        let dateTitle = filter.days.flatMap { d in GraphFilter.dayChoices.first { $0.days == d }?.title }
        let buttons: [(id: String, name: String, value: String?)] = [
            ("branch", "Branch", filter.branch), ("user", "User", filter.user), ("date", "Date", dateTitle), ("paths", "Paths", filter.path),
        ]
        for b in buttons {
            let title = b.name + (b.value.map { ": " + ($0.count > 24 ? String($0.prefix(23)) + "\u{2026}" : $0) } ?? "")
            let tw = p.width(title, pixels: 12, semibold: b.value != nil)
            let r = UIRect(x: x, y: y, width: tw + 30 * s, height: h)
            guard r.maxX < t.maxX - 70 * s else { break }
            let hovered = hoveredPart == "bar:" + b.id, on = b.value != nil || openFilter == b.id
            // As the Mac's: set or open, an accent box behind accent text; hovered, a lighter one.
            if on || hovered { p.fill(r, accent, on ? 0.24 : 0.13, radius: 5) }
            p.label(title, UIRect(x: r.x + 8 * s, y: r.y, width: tw + 2, height: h), pixels: 12, semibold: b.value != nil,
                    color: on || hovered ? accent : nil, alpha: on || hovered ? 1 : 0.75)
            p.icon(0xE70D, UIRect(x: r.maxX - 18 * s, y: r.y, width: 12 * s, height: h), pixels: 8, color: on || hovered ? accent : nil, alpha: 0.7)
            toolbarParts.append((b.id, r))
            x = r.maxX + 4 * s
        }
        if !filter.isEmpty {
            let r = UIRect(x: x + 4 * s, y: y, width: p.width("Clear", pixels: 12) + 16 * s, height: h)
            if r.maxX < t.maxX - 8 * s {
                p.textButton("Clear", r, hovered: hoveredPart == "bar:clear")
                toolbarParts.append(("clear", r))
            }
        }
    }

    // For tests
    func selectRow(_ i: Int) {
        selected = i
        showCard(i)
    }
    var cardLoaded: Bool { cardRow.map { rows.indices.contains($0) && details[rows[$0].commit.hash] != nil } ?? false }
    func setFilterForTesting(_ edit: (inout GraphFilter) -> Void) { change(edit) }
    /// The toolbar part's place, for tests: "branch", "user", "date", "paths", "search", "clear".
    func toolbarRect(_ id: String) -> UIRect? { toolbarParts.first { $0.id == id }?.rect }
}
