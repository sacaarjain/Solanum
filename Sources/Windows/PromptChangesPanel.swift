import CCanvas
import Foundation
import WinSDK

// The pill and panel of "Files changed this prompt", as on the Mac: over the focused tab when it runs Claude Code on
// this PC, a frosted pill in the terminal's top right ("3 files changed +42 −7") once a prompt has changed a file;
// clicking it grows it into a frosted panel there listing the files, each unfolding to its diff. ‹ › (or ← →) step back
// through earlier prompts' changes, Whole chat adds them all up, Ask starts a question to Claude naming the files and
// where they changed. A click outside, Esc or ✕ shrinks it back into the pill. What changed is PromptChangesTracker's.

final class PromptChangesPanel {
    /// The window's: redraw, open a file above a tab's terminal, and keep frames coming while something moves.
    var invalidate: () -> Void = {}
    var openFile: (TerminalPane, String) -> Void = { _, _ in }
    var animate: () -> Void = {}

    /// The tab it's showing.
    private(set) weak var pane: TerminalPane?
    var tracker: PromptChangesTracker? { testTracker ?? pane?.promptChanges }
    /// For drawing off screen (--prompt-changes): a tracker of its own, with no tab.
    var testTracker: PromptChangesTracker?

    enum Showing: Equatable { case following, prompt(String), chat }
    private(set) var showing: Showing = .following
    private(set) var expanded = false

    // MARK: What's shown

    struct Shown {
        let title: String
        let prompt: AgentPrompt?
        let files: [ChangedFile]
        let fromGit: Bool
        let key: String
        let promptID: String?
        let step: (Int, Int)?
        let scope: String
    }

    private var steps: [PromptChangesTracker.Entry] { tracker?.entries.filter { !$0.files.isEmpty } ?? [] }

    var shown: Shown {
        guard let t = tracker else { return Shown(title: "This prompt", prompt: nil, files: [], fromGit: false, key: "-", promptID: nil, step: nil, scope: "for my last prompt") }
        if showing == .chat {
            return Shown(title: "This whole chat", prompt: nil, files: t.chatFiles, fromGit: t.chatFromGit, key: "chat", promptID: nil, step: nil, scope: "in this chat")
        }
        var entry = t.pillEntry
        if case .prompt(let id) = showing, let e = t.entries.first(where: { $0.prompt.id == id }) { entry = e }
        guard let e = entry else {
            return Shown(title: "This prompt", prompt: nil, files: [], fromGit: false, key: "-", promptID: nil, step: nil, scope: "for my last prompt")
        }
        let ago = (t.entries.count - 1) - (t.entries.firstIndex(of: e) ?? (t.entries.count - 1))
        let title = ago == 0 ? "This prompt" : ago == 1 ? "The prompt before" : "\(ago) prompts ago"
        let place = steps.firstIndex(of: e).map { ($0 + 1, steps.count) }
        let words = e.prompt.text.replacingOccurrences(of: "\n", with: " ")
        let scope = ago == 0 ? "for my last prompt" : "for my prompt “\(words.count > 50 ? String(words.prefix(48)) + "…" : words)”"
        return Shown(title: title, prompt: e.prompt, files: e.files, fromGit: e.fromGit, key: "p:" + e.prompt.id, promptID: e.prompt.id, step: place, scope: scope)
    }

    /// Whether the pill (or panel) shows over `pane`: Claude Code running in it on this PC, a prompt that changed something,
    /// the pill on in Settings, and the terminal showing.
    func shows(over pane: TerminalPane) -> Bool {
        AppSettings.shared.filesChangedPill && pane.agent?.kind == .claude && pane.sshArguments == nil
            && !(pane.promptChanges.files.isEmpty) && (pane.showsTerminal || pane.editors.isEmpty)
    }

    /// The tab whose changes show: the focused one. Another tab focused folds the panel.
    func follow(_ pane: TerminalPane?) {
        guard pane !== self.pane else { return }
        if expanded { collapse(animated: false) }
        self.pane = pane
        showing = .following
        forget(except: [], key: nil)
    }

    /// The tracker's said something changed.
    func trackerChanged(_ from: PromptChangesTracker) {
        guard from === tracker else { return }
        let s = shown
        forget(except: Set(s.files.map(\.path)), key: s.key)
        if expanded, !(pane.map(shows) ?? false) { collapse(animated: false) }
        invalidate()
    }

    /// Opens the panel at a prompt's changes (the chip on its box in the terminal).
    func show(prompt id: String, in pane: TerminalPane) {
        follow(pane)
        showing = id == tracker?.pillEntry?.prompt.id ? .following : .prompt(id)
        if expanded { changed() } else { expand(keeping: true) }
    }

    func step(_ by: Int) {
        let list = steps
        guard showing != .chat, let p = shown.promptID, let i = list.firstIndex(where: { $0.prompt.id == p }) else { return }
        let j = i + by
        guard list.indices.contains(j) else { return }
        showing = j == list.count - 1 ? .following : .prompt(list[j].prompt.id)
        changed()
    }

    func toggleChat() {
        showing = showing == .chat ? .following : .chat
        changed()
    }

    private func changed() {
        let s = shown
        forget(except: Set(s.files.map(\.path)), key: s.key)
        invalidate()
    }

    // MARK: Growing and shrinking

    /// The pill grows into the panel (and shrinks back): since when, which way, and the panel's picture meanwhile.
    private var morph: (start: Date, opening: Bool)?
    private static let growTime = 0.3, shrinkTime = 0.22
    private var picture: Int32 = -1
    private var pictureCanvas: Canvas?
    private var pictureSize: (Float, Float) = (0, 0)
    private var needsPicture = false

    var isAnimating: Bool { morph != nil || !moving.isEmpty }

    func expand(keeping: Bool = false) {
        guard !expanded, let pane, shows(over: pane) else { return }
        expanded = true
        if !keeping { showing = .following }
        changed()
        scrollY = 0
        morph = (Date(), true)
        needsPicture = true
        prefetch()
        animate()
        invalidate()
    }

    func collapse(animated: Bool = true) {
        guard expanded else { return }
        expanded = false
        anchor = nil
        focus = nil
        if animated {
            morph = (Date(), false)
            needsPicture = true
            animate()
        } else {
            morph = nil
        }
        invalidate()
    }

    // MARK: Folding files

    private var open: Set<String> = []
    private var diffs: [String: DiffFile] = [:]
    private var loading: Set<String> = []
    private var forKey: String?
    private var moving: [String: (from: Float, to: Float, start: Date)] = [:]
    private var openOnLoad: Set<String> = []
    private static let foldTime = 0.22

    private func forget(except paths: Set<String>, key: String?) {
        if key != forKey { open = []; forKey = key; anchor = nil; focus = nil; moving = [:]; openOnLoad = []; scrollX = [:]; scrollY = 0 }
        open = open.intersection(paths)
        diffs = diffs.filter { paths.contains($0.key) }
        prefetch()
    }

    private func openness(_ path: String) -> Float {
        guard let m = moving[path] else { return open.contains(path) && diffs[path] != nil ? 1 : 0 }
        let t = Float(min(1, max(0, Date().timeIntervalSince(m.start) / Self.foldTime)))
        let eased = 1 - pow(1 - t, 3)
        return m.from + (m.to - m.from) * eased
    }

    private func setOpen(_ path: String, _ on: Bool) {
        let from = openness(path)
        if on {
            open.insert(path)
            guard diffs[path] != nil else {
                openOnLoad.insert(path)
                return load(path)
            }
        } else {
            open.remove(path)
            openOnLoad.remove(path)
        }
        move(path, from: from, to: on ? 1 : 0)
    }

    private func move(_ path: String, from: Float, to: Float) {
        moving[path] = (from, to, Date())
        animate()
        invalidate()
    }

    private var prefetching = false
    private func prefetch() {
        guard expanded, !prefetching, let t = tracker else { return }
        prefetching = true
        let key = shown.key
        t.diffs(prompt: shown.promptID) { [weak self] all in
            guard let self else { return }
            self.prefetching = false
            guard self.shown.key == key else { return }
            for (path, d) in all { self.diffs[path] = d }
            for path in self.openOnLoad where all[path] != nil && self.open.contains(path) { self.move(path, from: 0, to: 1) }
            self.openOnLoad.subtract(all.keys)
            self.invalidate()
        }
    }

    private func load(_ path: String) {
        guard let t = tracker, !loading.contains(path) else { return }
        loading.insert(path)
        t.diff(path, prompt: shown.promptID) { [weak self] f in
            guard let self else { return }
            self.loading.remove(path)
            if let f { self.diffs[path] = f }
            if self.openOnLoad.remove(path) != nil, f != nil, self.open.contains(path) { self.move(path, from: 0, to: 1) }
            self.invalidate()
        }
    }

    /// From the window's animation timer. True while there's more to show.
    func tick() -> Bool {
        let now = Date()
        moving = moving.filter { now.timeIntervalSince($0.value.start) < Self.foldTime }
        if let m = morph, now.timeIntervalSince(m.start) >= (m.opening ? Self.growTime : Self.shrinkTime) {
            morph = nil
            freePicture()
        }
        return isAnimating
    }

    // MARK: Asking and opening

    var agentName: String { pane?.agent?.kind.name ?? "Claude" }

    /// A line naming the files and where they changed, in Claude's input box for you to finish (not sent).
    func ask(about paths: [String]? = nil) {
        guard let pane, let t = tracker else { return }
        let s = shown
        let files = s.files.filter { paths?.contains($0.path) ?? true }
        guard !files.isEmpty else { return }
        var got: [String: DiffFile] = [:]
        var left = files.filter { !$0.binary }.count
        let finish = { [weak self, weak pane] in
            guard let pane else { return }
            let text = PromptChanges.ask(about: files.map { ($0, got[$0.path]) }, scope: s.scope)
            self?.lastAsk = text
            self?.collapse()
            pane.sendToChat(text)
        }
        if left == 0 { return finish() }
        for f in files where !f.binary {
            t.diff(f.path, prompt: s.promptID) { d in
                if let d { got[f.path] = d }
                left -= 1
                if left == 0 { finish() }
            }
        }
    }

    /// For tests: the last line Ask started.
    private(set) var lastAsk: String?

    func openFile(_ path: String) {
        guard let pane, let t = tracker else { return }
        collapse()
        openFile(pane, t.absolute(path))
    }

    // MARK: Layout

    private static let pillHeight: Float = 30
    private var hits: [(rect: UIRect, id: String, run: (() -> Void)?)] = []
    private(set) var hover: String?
    private var panelRect: UIRect?
    private var pillRect: UIRect?
    private var diffAreas: [(path: String, rect: UIRect)] = []

    /// The strip down the terminal's right that its scrollbar takes: the pill and panel end where it starts.
    private static let barStrip: Float = 14

    private func pillWidth(_ p: PanelPaint) -> Float {
        let c = counts
        return 34 * p.scale + p.width(pillLabel, pixels: 12, semibold: true) + 10 * p.scale + p.width(c.0, pixels: 11.5, semibold: true)
            + 6 * p.scale + p.width(c.1, pixels: 11.5, semibold: true) + 14 * p.scale
    }
    private var pillLabel: String {
        let n = tracker?.files.count ?? 0
        return n == 1 ? "1 file changed" : "\(n) files changed"
    }
    private var counts: (String, String) {
        let f = tracker?.files ?? []
        return ("+\(f.map(\.added).reduce(0, +))", "−\(f.map(\.removed).reduce(0, +))")
    }

    func pillFrame(in area: UIRect, _ p: PanelPaint) -> UIRect {
        let s = p.scale, inset = 10 * s, right = Self.barStrip * s
        let w = min(pillWidth(p), area.width - inset - right)
        return UIRect(x: (area.maxX - w - right).rounded(), y: (area.y + inset).rounded(), width: w.rounded(), height: (Self.pillHeight * s).rounded())
    }

    private func panelFrame(in area: UIRect, _ p: PanelPaint) -> UIRect {
        let s = p.scale, inset = 10 * s, right = Self.barStrip * s
        let w = min(560 * s, max(320 * s, area.width * 0.5), area.width - inset - right)
        let content = render(p, width: w, top: 0, measuring: true)
        let h = max(120 * s, min(content, area.height - inset * 2))
        return UIRect(x: (area.maxX - w - right).rounded(), y: (area.y + inset).rounded(), width: w.rounded(), height: h.rounded())
    }

    /// How far down the panel's list is scrolled, and how far it can go.
    private var scrollY: Float = 0
    private var scrollMaxY: Float = 0

    // MARK: Drawing

    /// Over `pane`'s terminal (`area`), after it's drawn.
    func draw(over pane: TerminalPane, area: UIRect, canvas: Canvas, scale s: Float) {
        hits = []
        diffAreas = []
        rows = []
        pillRect = nil
        panelRect = nil
        let p = PanelPaint(canvas: canvas, scale: s)
        guard pane === self.pane, shows(over: pane) || morph != nil else { return }
        drawContents(area: area, p)
    }

    /// Off screen, with `testTracker`: the pill, or the panel with `open` unfolded.
    func drawForTest(area: UIRect, canvas: Canvas, scale s: Float, expand: Bool, open paths: [String] = []) {
        hits = []
        diffAreas = []
        rows = []
        if expand && !expanded {
            expanded = true
            prefetch()
            for path in paths { setOpen(path, true) }
            moving = [:]
        }
        drawContents(area: area, PanelPaint(canvas: canvas, scale: s))
    }

    private func drawContents(area: UIRect, _ p: PanelPaint) {
        let s = p.scale, canvas = p.canvas
        let pill = pillFrame(in: area, p)
        let panel = panelFrame(in: area, p)
        if let m = morph {
            // The panel's picture, from the pill's size and place to its own (or back), on a frosted card that does the same.
            let span = m.opening ? Self.growTime : Self.shrinkTime
            let t = Float(min(1, Date().timeIntervalSince(m.start) / span))
            let e = m.opening ? 1 - pow(1 - t, 3) : t * t
            let k = m.opening ? e : 1 - e
            let r = UIRect(x: pill.x + (panel.x - pill.x) * k, y: pill.y + (panel.y - pill.y) * k,
                           width: pill.width + (panel.width - pill.width) * k, height: pill.height + (panel.height - pill.height) * k)
            card(p, r)
            if needsPicture || sol_canvas_layer_alive(canvas.raw, picture) == 0 || pictureCanvas !== canvas { makePicture(p, panel) }
            // The pill shows through at the start of growing and the end of shrinking.
            let pillAlpha = max(0, 1 - k * 4)
            if pillAlpha > 0 { drawPill(p, pill: r, alpha: pillAlpha) }
            if picture >= 0 { sol_canvas_layer_draw(canvas.raw, picture, r.x, r.y, r.width, r.height, min(1, k * 2)) }
            return
        }
        if expanded {
            panelRect = panel
            card(p, panel)
            sol_canvas_push_clip(canvas.raw, panel.x, panel.y, panel.width, panel.height)
            let full = render(p, width: panel.width, top: panel.y - scrollY, x0: panel.x, measuring: false, clip: panel)
            sol_canvas_pop_clip(canvas.raw)
            scrollMaxY = max(0, full - panel.height)
            if scrollY > scrollMaxY { scrollY = scrollMaxY }
            if scrollMaxY > 0 {
                ScrollBars.draw(id: "prompt-changes", on: canvas, track: UIRect(x: panel.x, y: panel.y + 4 * s, width: panel.width - 2 * s, height: panel.height - 8 * s),
                                axis: .vertical, total: Double(full), visible: Double(panel.height), offset: Double(scrollY), scale: s) { [weak self] top in
                    self?.scrollY = Float(top)
                    self?.invalidate()
                }
            }
        } else {
            pillRect = pill
            card(p, pill)
            drawPill(p, pill: pill, alpha: 1)
            hits.append((pill, "pill", { [weak self] in self?.expand() }))
        }
    }

    /// Solanum's cards' corners, as on the Mac (Cards.radius).
    static let radius: Float = 8

    /// A frosted card as the Mac's FrostedCard: the window's glass under a tint between the theme's background and its
    /// raised surface, a hairline edge, and a soft shadow falling below it.
    private func card(_ p: PanelPaint, _ r: UIRect) {
        let c = p.canvas.raw, s = p.scale, radius = Self.radius * s, dark = TerminalPalette.isDark
        let shadow: Float = dark ? 0.45 : 0.22
        for (grow, alpha) in [(Float(22), Float(0.05)), (16, 0.07), (10, 0.1), (5, 0.14), (2, 0.2)] {
            let g = grow * s
            sol_canvas_fill_rounded(c, r.x - g, r.y - g + 8 * s, r.width + g * 2, r.height + g * 2, radius + g, 0x000000, alpha * shadow)
        }
        let tint = Self.mix(TerminalPalette.background, TerminalPalette.surface, 0.5)
        if sol_canvas_frost_rounded(c, r.x, r.y, r.width, r.height, radius, 20 * s, tint, 0.68) == 0 {
            sol_canvas_fill_rounded(c, r.x, r.y, r.width, r.height, radius, tint, 0.96)
        }
        sol_canvas_stroke_rounded(c, r.x + 0.5, r.y + 0.5, r.width - 1, r.height - 1, radius, TerminalPalette.foreground, dark ? 0.12 : 0.1, 1)
    }

    /// Two colors mixed: `t` of the way from `a` to `b`.
    static func mix(_ a: UInt32, _ b: UInt32, _ t: Float) -> UInt32 {
        func ch(_ c: UInt32, _ shift: UInt32) -> Float { Float((c >> shift) & 0xFF) }
        func m(_ shift: UInt32) -> UInt32 { UInt32((ch(a, shift) + (ch(b, shift) - ch(a, shift)) * t).rounded()) << shift }
        return m(16) | m(8) | m(0)
    }

    /// The Mac's "sparkles": a four-pointed star with a small one at its top right, in `rect`.
    static func sparkles(_ p: PanelPaint, _ rect: UIRect, color: UInt32, alpha: Float = 1) {
        func star(cx: Float, cy: Float, r: Float) {
            let i = r * 0.28
            let xy: [Float] = [cx, cy - r, cx + i, cy - i, cx + r, cy, cx + i, cy + i, cx, cy + r, cx - i, cy + i, cx - r, cy, cx - i, cy - i]
            xy.withUnsafeBufferPointer { sol_canvas_fill_polygon(p.canvas.raw, $0.baseAddress, 8, color, alpha) }
        }
        let size = min(rect.width, rect.height), cx = rect.x + rect.width / 2, cy = rect.y + rect.height / 2
        star(cx: cx - size * 0.08, cy: cy + size * 0.06, r: size * 0.36)
        star(cx: cx + size * 0.3, cy: cy - size * 0.3, r: size * 0.14)
    }

    private func drawPill(_ p: PanelPaint, pill r: UIRect, alpha: Float) {
        let s = p.scale, fg = TerminalPalette.foreground
        // On its frosted card: lit up under the pointer.
        if hover == "pill" { p.fill(r, fg, 0.08 * alpha, radius: Self.radius) }
        p.icon(0xE8A5, UIRect(x: r.x + 10 * s, y: r.y, width: 16 * s, height: r.height), pixels: 12, color: TerminalPalette.accent, alpha: alpha)
        var x = r.x + 32 * s
        p.label(pillLabel, UIRect(x: x, y: r.y, width: max(0, r.maxX - x - 8 * s), height: r.height), pixels: 12, semibold: true, alpha: alpha)
        x += p.width(pillLabel, pixels: 12, semibold: true) + 10 * s
        let c = counts
        guard x < r.maxX - 8 * s else { return }
        p.label(c.0, UIRect(x: x, y: r.y, width: 60 * s, height: r.height), pixels: 11.5, semibold: true, color: TerminalPalette.ansi[2], alpha: alpha)
        x += p.width(c.0, pixels: 11.5, semibold: true) + 6 * s
        p.label(c.1, UIRect(x: x, y: r.y, width: 60 * s, height: r.height), pixels: 11.5, semibold: true, color: TerminalPalette.ansi[1], alpha: alpha)
    }

    /// The panel's picture for growing and shrinking: its contents as they are now, on nothing.
    private func makePicture(_ p: PanelPaint, _ panel: UIRect) {
        needsPicture = false
        let c = p.canvas.raw
        if pictureCanvas !== p.canvas || pictureSize != (panel.width, panel.height) || sol_canvas_layer_alive(c, picture) == 0 {
            freePicture()
            picture = sol_canvas_layer_make(c, panel.width, panel.height)
            pictureCanvas = p.canvas
            pictureSize = (panel.width, panel.height)
        }
        guard picture >= 0, sol_canvas_layer_begin(c, picture, 1) != 0 else { return }
        let saved = (hits, rows, diffAreas)
        _ = render(p, width: panel.width, top: -scrollY, x0: 0, measuring: false, clip: UIRect(x: 0, y: 0, width: panel.width, height: panel.height))
        (hits, rows, diffAreas) = saved
        sol_canvas_layer_end(c)
    }

    private func freePicture() {
        if let pc = pictureCanvas, picture >= 0 { sol_canvas_layer_free(pc.raw, picture) }
        picture = -1
        pictureCanvas = nil
    }

    private static let lineH: Float = 18

    /// The panel's contents, from `top`: its height. Measuring draws nothing and records nothing.
    @discardableResult
    private func render(_ p: PanelPaint, width: Float, top: Float, x0: Float = 0, measuring: Bool, clip: UIRect? = nil) -> Float {
        let s = p.scale, fg = TerminalPalette.foreground
        let t = shown
        let pad = 16 * s
        let w = width - pad * 2
        var y = top + 12 * s
        func visible(_ r: UIRect) -> Bool { !measuring && (clip.map { r.maxY >= $0.y && r.y <= $0.maxY } ?? true) }
        func hit(_ r: UIRect, _ id: String, _ run: (() -> Void)?) {
            guard !measuring else { return }
            let shown = clip.map { r.intersection($0) } ?? r
            if let shown, shown.width > 0, shown.height > 0 { hits.append((shown, id, run)) }
        }
        func button(_ glyph: UInt16, id: String, rightEdge: Float, y: Float, enabled: Bool = true, _ run: @escaping () -> Void) -> Float {
            let r = UIRect(x: rightEdge - 26 * s, y: y, width: 26 * s, height: 26 * s)
            if visible(r) {
                if hover == id && enabled { p.fill(r, fg, 0.07, radius: Self.radius) }
                p.icon(glyph, r, pixels: 11, color: enabled ? TerminalPalette.accent : fg, alpha: enabled ? 1 : 0.4)
            }
            if enabled { hit(r, id, run) }
            return 26 * s
        }
        /// `secondary`: on a light fill with an edge, in the text's color (Ask); else plain, in the accent (Whole chat).
        func textButton(_ title: String, id: String, rightEdge: Float, y: Float, secondary: Bool, enabled: Bool = true,
                        icon: (UIRect, UInt32, Float) -> Void, _ run: @escaping () -> Void) -> Float {
            let tw = p.width(title, pixels: 12, semibold: true)
            let bw = tw + 40 * s
            let r = UIRect(x: rightEdge - bw, y: y, width: bw, height: 26 * s)
            if visible(r) {
                let hot = hover == id && enabled
                if secondary {
                    p.fill(r, fg, hot ? 0.12 : 0.07, radius: Self.radius)
                    sol_canvas_stroke_rounded(p.canvas.raw, r.x + 0.5, r.y + 0.5, r.width - 1, r.height - 1, Self.radius * s, fg, TerminalPalette.isDark ? 0.1 : 0.14, 1)
                } else if hot {
                    p.fill(r, fg, 0.07, radius: Self.radius)
                }
                let color = secondary ? fg : TerminalPalette.accent
                let a: Float = enabled ? 1 : 0.55
                icon(UIRect(x: r.x + 12 * s, y: r.y, width: 14 * s, height: r.height), enabled ? color : fg, a)
                p.label(title, UIRect(x: r.x + 30 * s, y: r.y, width: tw + 2 * s, height: r.height), pixels: 12, semibold: true, color: enabled ? color : fg, alpha: a)
            }
            if enabled { hit(r, id, run) }
            return bw
        }

        // Title; ‹ › through the prompts that changed something; ✕.
        var right = x0 + width - pad + 6 * s
        right -= button(0xE711, id: "close", rightEdge: right, y: y - 2 * s) { [weak self] in self?.collapse() } + 2 * s
        if let (i, n) = t.step, n > 1 {
            right -= button(0xE76C, id: "next", rightEdge: right, y: y - 2 * s, enabled: i < n) { [weak self] in self?.step(1) }
            right -= button(0xE76B, id: "prev", rightEdge: right, y: y - 2 * s, enabled: i > 1) { [weak self] in self?.step(-1) }
            let place = "\(i)/\(n)"
            let pw = p.width(place, pixels: 11.5, semibold: true)
            right -= pw + 6 * s
            if visible(UIRect(x: right, y: y, width: pw, height: 22 * s)) {
                p.label(place, UIRect(x: right, y: y, width: pw + 2 * s, height: 22 * s), pixels: 11.5, semibold: true, alpha: 0.55)
            }
        }
        if visible(UIRect(x: x0 + pad, y: y, width: w, height: 22 * s)) {
            p.label(t.title, UIRect(x: x0 + pad, y: y, width: max(0, right - x0 - pad - 4 * s), height: 22 * s), pixels: 13.5, semibold: true)
        }
        y += 28 * s
        if let prompt = t.prompt {
            let text = "“" + prompt.text.replacingOccurrences(of: "\n", with: " ") + "”"
            let shownText = Self.fit(p, text, pixels: 12, width: w, lines: 2)
            for line in shownText {
                if visible(UIRect(x: x0 + pad, y: y, width: w, height: 17 * s)) {
                    p.label(line, UIRect(x: x0 + pad, y: y, width: w, height: 17 * s), pixels: 12, alpha: 0.55)
                }
                y += 17 * s
            }
            y += 8 * s
        }
        let added = t.files.map(\.added).reduce(0, +), removed = t.files.map(\.removed).reduce(0, +)
        let summary = "\(t.files.count) file\(t.files.count == 1 ? "" : "s") · +\(added) −\(removed)" + (t.fromGit || t.promptID == nil ? "" : " · from Claude's edits")
        let askW = textButton(width < 400 * s ? "Ask" : "Ask " + agentName, id: "askall", rightEdge: x0 + width - pad, y: y - 4 * s, secondary: true,
                              enabled: !t.files.isEmpty, icon: { r, color, a in Self.sparkles(p, r.insetBy(1.5 * s), color: color, alpha: a) }) { [weak self] in self?.ask() }
        let chatGlyph: UInt16 = showing == .chat ? 0xE72B : 0xE8F1
        let chatW = textButton(showing == .chat ? "This prompt" : "Whole chat", id: "chat", rightEdge: x0 + width - pad - askW - 6 * s, y: y - 4 * s,
                               secondary: false, icon: { r, color, a in p.icon(chatGlyph, r, pixels: 11.5, color: color, alpha: a) }) { [weak self] in self?.toggleChat() }
        if visible(UIRect(x: x0 + pad, y: y, width: w, height: 18 * s)) {
            p.label(summary, UIRect(x: x0 + pad, y: y - 1 * s, width: max(0, w - askW - chatW - 14 * s), height: 20 * s), pixels: 11.5, semibold: true, alpha: 0.55)
        }
        y += 30 * s
        if t.files.isEmpty {
            if visible(UIRect(x: x0 + pad, y: y, width: w, height: 18 * s)) {
                p.label("Nothing changed.", UIRect(x: x0 + pad, y: y, width: w, height: 18 * s), pixels: 12, alpha: 0.6)
            }
            y += 28 * s
        }
        let lineH = (Self.lineH * s).rounded()
        for f in t.files {
            let unfolded = open.contains(f.path)
            let shownPart = openness(f.path)
            let r = UIRect(x: x0 + pad, y: y, width: w, height: 32 * s)
            let id = "file." + f.path
            let rowHot = hover == id || hover == "openfile." + f.path || hover == "askfile." + f.path
            if visible(r) {
                if rowHot { p.fill(r, fg, 0.08, radius: Self.radius) } else { p.fill(r, TerminalPalette.surface, 0.6, radius: Self.radius) }
                p.icon(shownPart > 0.5 ? 0xE70D : 0xE76C, UIRect(x: r.x + 8 * s, y: r.y, width: 12 * s, height: r.height), pixels: 8.5, alpha: 0.55)
                let name = f.path.split(separator: "/").last.map(String.init) ?? f.path
                let dir = f.path.contains("/") ? String(f.path[..<f.path.lastIndex(of: "/")!]) : ""
                let stat = f.binary ? "binary" : "+\(f.added) −\(f.removed)"
                let sw = p.width(stat, pixels: 11.5, semibold: true)
                var x = r.x + 26 * s
                if f.change != .modified {
                    let word = f.change == .added ? "new" : "deleted"
                    let color = f.change == .added ? TerminalPalette.ansi[2] : TerminalPalette.ansi[1]
                    let tw = p.width(word, pixels: 10, semibold: true) + 12 * s
                    let chip = UIRect(x: x, y: r.y + 7 * s, width: tw, height: 18 * s)
                    p.fill(chip, color, 0.2, radius: 9)
                    p.label(word, UIRect(x: chip.x + 6 * s, y: chip.y, width: tw, height: chip.height), pixels: 10, semibold: true, color: color)
                    x += tw + 6 * s
                }
                let rightLimit = r.maxX - sw - 12 * s - (rowHot ? 60 * s : 0)
                let nw = min(p.width(name, pixels: 12.5, semibold: true) + 2 * s, max(0, rightLimit - x - 8 * s))
                p.label(name, UIRect(x: x, y: r.y, width: nw, height: r.height), pixels: 12.5, semibold: true, alpha: f.change == .deleted ? 0.6 : 1)
                if !dir.isEmpty, nw + 30 * s < rightLimit - x {
                    p.label(dir, UIRect(x: x + nw + 6 * s, y: r.y, width: rightLimit - x - nw - 6 * s, height: r.height), pixels: 11.5, alpha: 0.55)
                }
                if f.binary {
                    p.label(stat, UIRect(x: r.maxX - sw - 12 * s, y: r.y, width: sw + 2 * s, height: r.height), pixels: 11.5, semibold: true, alpha: 0.6)
                } else {
                    let a = "+\(f.added)", d = "−\(f.removed)"
                    p.label(a, UIRect(x: r.maxX - sw - 12 * s, y: r.y, width: sw, height: r.height), pixels: 11.5, semibold: true, color: TerminalPalette.ansi[2])
                    let dw = p.width(d, pixels: 11.5, semibold: true)
                    p.label(d, UIRect(x: r.maxX - 12 * s - dw, y: r.y, width: dw + 2 * s, height: r.height), pixels: 11.5, semibold: true, color: TerminalPalette.ansi[1])
                }
                if rowHot {
                    var bx = r.maxX - sw - 40 * s
                    if f.change != .deleted {
                        let o = UIRect(x: bx, y: r.y + 3 * s, width: 26 * s, height: 26 * s)
                        if hover == "openfile." + f.path { p.fill(o, fg, 0.1, radius: Self.radius) }
                        p.icon(0xE8A7, o, pixels: 10.5, color: TerminalPalette.accent)
                        hit(o, "openfile." + f.path) { [weak self] in self?.openFile(f.path) }
                        bx -= 28 * s
                    }
                    let a = UIRect(x: bx, y: r.y + 3 * s, width: 26 * s, height: 26 * s)
                    if hover == "askfile." + f.path { p.fill(a, fg, 0.1, radius: Self.radius) }
                    Self.sparkles(p, a.insetBy(7 * s), color: TerminalPalette.accent)
                    hit(a, "askfile." + f.path) { [weak self] in self?.ask(about: [f.path]) }
                }
            }
            hit(r, id) { [weak self] in self?.setOpen(f.path, !unfolded) }
            y += 36 * s
            guard shownPart > 0 else { continue }
            if let d = diffs[f.path], !d.isBinary {
                let full = Float(d.lines.count) * lineH + 10 * s
                let part = (full * shownPart).rounded()
                let area = UIRect(x: x0 + pad, y: y, width: w, height: part)
                if !measuring {
                    diffAreas.append((f.path, area))
                    if visible(area) {
                        let visibleArea = clip.flatMap { area.intersection($0) } ?? area
                        sol_canvas_push_clip(p.canvas.raw, visibleArea.x, visibleArea.y, visibleArea.width, visibleArea.height)
                        drawDiff(d, path: f.path, p, area: area, lineH: lineH, selectable: shownPart >= 1, clip: visibleArea)
                        sol_canvas_pop_clip(p.canvas.raw)
                    }
                }
                y += part
            } else if unfolded {
                let note = loading.contains(f.path) ? "Loading…" : f.binary ? "Binary file." : "No changes to show."
                if visible(UIRect(x: x0 + pad + 26 * s, y: y, width: w, height: 18 * s)) {
                    p.label(note, UIRect(x: x0 + pad + 26 * s, y: y, width: w - 26 * s, height: 18 * s), pixels: 12, alpha: 0.6)
                }
                y += 28 * s
            }
        }
        return y + 6 * s - top
    }

    /// The diffs' monospaced font, at the Mac's size.
    private static let monoFamily = wide("Cascadia Mono")
    private static let monoPixels: Float = 11.5

    /// One line of monospaced text from `x` (or ending at `x` with `right`), not wrapped. Its width.
    @discardableResult
    private func mono(_ p: PanelPaint, _ text: String, x: Float, y: Float, color: UInt32, alpha: Float = 1, right: Bool = false, measure: Bool = false) -> Float {
        let u = Array(text.utf16)
        guard !u.isEmpty else { return 0 }
        var used: Float = 0
        let px = Self.monoPixels * p.scale
        Self.monoFamily.withUnsafeBufferPointer { f in
            _ = sol_canvas_text_in(p.canvas.raw, f.baseAddress, 0, 0, 100_000, u, Int32(u.count), px, 0, color, 0, Int32(u.count), 1, &used)
        }
        if measure { return used }
        let x0 = right ? x - used : x
        Self.monoFamily.withUnsafeBufferPointer { f in
            _ = sol_canvas_text_in(p.canvas.raw, f.baseAddress, x0, y, 100_000, u, Int32(u.count), px, 0, color, alpha, Int32(u.count), 0, &used)
        }
        return used
    }

    /// A file's diff, as the Mac's: old and new line numbers, then the text on its color (green added, red removed, the
    /// hunk's header tinted). Long lines scroll sideways, the numbers staying put.
    private func drawDiff(_ d: DiffFile, path: String, _ p: PanelPaint, area: UIRect, lineH: Float, selectable: Bool, clip: UIRect) {
        let s = p.scale, fg = TerminalPalette.foreground, dark = TerminalPalette.isDark
        let biggest = d.lines.compactMap { max($0.old ?? 0, $0.new ?? 0) }.max() ?? 0
        let numW = max(28 * s, mono(p, String(biggest), x: 0, y: 0, color: fg, measure: true) + 10 * s)
        let textX = area.x + numW * 2 + 12 * s
        let column = max(0, area.maxX - textX - 4 * s)
        let widest = d.lines.filter { $0.kind != .hunk }.map { $0.text.replacingOccurrences(of: "\t", with: "    ") }
            .sorted { $0.count > $1.count }.prefix(4).map { mono(p, $0, x: 0, y: 0, color: fg, measure: true) }.max() ?? 0
        diffScrollMax[path] = max(0, widest + 12 * s - column)
        let dx = min(scrollX[path] ?? 0, diffScrollMax[path] ?? 0)
        var y = area.y
        for (n, l) in d.lines.enumerated() {
            defer { y += lineH }
            let r = UIRect(x: area.x, y: y, width: area.width, height: lineH)
            guard y + lineH >= clip.y, y <= clip.maxY else {
                if l.kind != .hunk && selectable { rows.append(Row(key: "\(path)#\(n)", rect: r, text: l.text)) }
                continue
            }
            let ty = y + 1 * s
            switch l.kind {
            case .added: p.fill(r, TerminalPalette.ansi[2], dark ? 0.16 : 0.14)
            case .removed: p.fill(r, TerminalPalette.ansi[1], dark ? 0.16 : 0.12)
            case .hunk: p.fill(r, TerminalPalette.accent, 0.08)
            default: break
            }
            if l.kind == .hunk {
                mono(p, l.text, x: area.x + numW * 2 + 10 * s, y: ty, color: fg, alpha: 0.55)
                continue
            }
            if let o = l.old { mono(p, "\(o)", x: area.x + numW - 6 * s, y: ty, color: fg, alpha: 0.33, right: true) }
            if let nn = l.new { mono(p, "\(nn)", x: area.x + numW * 2 - 6 * s, y: ty, color: fg, alpha: 0.33, right: true) }
            let mark = l.kind == .added ? "+" : l.kind == .removed ? "−" : " "
            mono(p, mark, x: area.x + numW * 2, y: ty, color: l.kind == .added ? TerminalPalette.ansi[2] : l.kind == .removed ? TerminalPalette.ansi[1] : fg,
                 alpha: l.kind == .context ? 0.55 : 1)
            let text = l.text.replacingOccurrences(of: "\t", with: "    ")
            if let lc = UIRect(x: textX, y: y, width: column, height: lineH).intersection(clip) {
                sol_canvas_push_clip(p.canvas.raw, lc.x, lc.y, lc.width, lc.height)
                mono(p, text, x: textX - dx, y: ty, color: fg, alpha: l.kind == .note ? 0.55 : 1)
                sol_canvas_pop_clip(p.canvas.raw)
            }
            if selectable {
                rows.append(Row(key: "\(path)#\(n)", rect: r, text: l.text))
                if isSelected(rows.count - 1) { p.fill(r, TerminalPalette.accent, 0.25) }
            }
        }
    }

    // MARK: Scrolling long lines sideways

    /// How far each file's diff is scrolled sideways, and how far it can go, in pixels.
    private var scrollX: [String: Float] = [:]
    private var diffScrollMax: [String: Float] = [:]

    // MARK: Selecting lines in the diffs

    private struct Row {
        let key: String
        let rect: UIRect
        let text: String
    }
    private var rows: [Row] = []
    private var anchor: String?
    private var focus: String?
    private var selecting = false

    /// A row's place among every diff line shown: its file's place, then its line's.
    private func order(_ key: String) -> Int? {
        guard let hash = key.lastIndex(of: "#"), let n = Int(key[key.index(after: hash)...]),
              let f = shown.files.firstIndex(where: { $0.path == key[..<hash] }) else { return nil }
        return f * 1_000_000 + n
    }

    private func isSelected(_ i: Int) -> Bool {
        guard let anchor, let focus, let a = order(anchor), let f = order(focus), let k = order(rows[i].key) else { return false }
        return (min(a, f)...max(a, f)).contains(k)
    }

    var selectedText: String? {
        guard let anchor, let focus, let a = rows.firstIndex(where: { $0.key == anchor }), let f = rows.firstIndex(where: { $0.key == focus }) else { return nil }
        return rows[min(a, f)...max(a, f)].map(\.text).joined(separator: "\r\n")
    }

    // MARK: Mouse and keys

    /// What's under the pointer: the pill, or anywhere on the open panel.
    func contains(x: Float, y: Float) -> Bool {
        (pillRect?.contains(x, y) ?? false) || (panelRect?.contains(x, y) ?? false)
    }

    func wantsHand(x: Float, y: Float) -> Bool? {
        guard contains(x: x, y: y) else { return nil }
        return hits.last { $0.rect.contains(x, y) && $0.run != nil } != nil
    }

    /// A mouse message. True when the pill or panel took it; a press outside the open panel folds it (and goes on).
    func mouse(_ message: UINT, x: Float, y: Float) -> Bool {
        let inside = contains(x: x, y: y)
        let over = inside ? hits.last(where: { $0.rect.contains(x, y) })?.id : nil
        if over != hover { hover = over; invalidate() }
        switch message {
        case Win.WM_LBUTTONDOWN, Win.WM_LBUTTONDBLCLK:
            guard inside else {
                if expanded { collapse() }
                return false
            }
            if let row = rows.first(where: { $0.rect.contains(x, y) }), hits.last(where: { $0.rect.contains(x, y) })?.id.hasPrefix("file.") != true {
                anchor = row.key
                focus = row.key
                selecting = true
                invalidate()
                return true
            }
            anchor = nil
            focus = nil
            if let h = hits.last(where: { $0.rect.contains(x, y) }), let run = h.run { run() }
            invalidate()
            return true
        case Win.WM_MOUSEMOVE:
            if selecting, let row = rows.min(by: { abs($0.rect.midY - y) < abs($1.rect.midY - y) }) {
                if row.key != focus { focus = row.key; invalidate() }
                return true
            }
            return inside
        case Win.WM_LBUTTONUP:
            if selecting { selecting = false; return true }
            return inside
        default:
            return inside
        }
    }

    /// The wheel over the panel: its list scrolls (sideways over a diff with Shift, or a sideways swipe). True if used.
    func wheel(x: Float, y: Float, delta: Float, sideways: Bool, cellWidth: Float) -> Bool {
        guard let panel = panelRect, panel.contains(x, y) else { return pillRect?.contains(x, y) ?? false }
        if sideways, let area = diffAreas.first(where: { $0.rect.contains(x, y) }) {
            scrollX[area.path] = min(max(0, (scrollX[area.path] ?? 0) - delta), diffScrollMax[area.path] ?? 0).rounded()
        } else {
            scrollY = min(max(0, scrollY - delta), scrollMaxY)
        }
        invalidate()
        return true
    }

    /// A key while the panel's open. True if used: Esc (a selection first), ← →, Ctrl+C, Ctrl+A.
    func key(_ key: Int32, ctrl: Bool, copy: (String) -> Void) -> Bool {
        guard expanded else { return false }
        switch key {
        case Win.VK_ESCAPE:
            if anchor != nil { anchor = nil; focus = nil; invalidate() } else { collapse() }
            return true
        case Win.VK_LEFT where !ctrl: step(-1); return true
        case Win.VK_RIGHT where !ctrl: step(1); return true
        case 0x43 where ctrl:
            guard let text = selectedText else { return false }
            copy(text)
            return true
        case 0x41 where ctrl:
            anchor = rows.first?.key
            focus = rows.last?.key
            invalidate()
            return rows.first != nil
        default:
            return false
        }
    }

    /// Wrapped into `lines` lines at most, the last cut with "…".
    private static func fit(_ p: PanelPaint, _ text: String, pixels: Float, width: Float, lines: Int) -> [String] {
        var out: [String] = []
        var rest = Substring(text)
        while !rest.isEmpty && out.count < lines {
            var cut = rest.endIndex
            if p.width(String(rest), pixels: pixels) > width {
                var lo = 1, hi = rest.count
                while lo < hi {
                    let mid = (lo + hi + 1) / 2
                    if p.width(String(rest.prefix(mid)), pixels: pixels) <= width { lo = mid } else { hi = mid - 1 }
                }
                cut = rest.index(rest.startIndex, offsetBy: lo)
                if out.count < lines - 1, let space = rest[..<cut].lastIndex(of: " ") { cut = rest.index(after: space) }
            }
            var line = String(rest[..<cut])
            rest = rest[cut...]
            if out.count == lines - 1 && !rest.isEmpty {
                while line.count > 1 && p.width(line + "…", pixels: pixels) > width { line.removeLast() }
                line += "…"
                rest = ""
            }
            out.append(line.trimmingCharacters(in: .whitespaces))
        }
        return out
    }

    // MARK: For tests

    var testHits: [String] { hits.map(\.id) }
    func testRect(_ id: String) -> UIRect? { hits.last { $0.id == id }?.rect }
    var testOpen: Set<String> { open }
    var testDiffsLoaded: Set<String> { Set(diffs.keys) }
}

extension UIRect {
    func insetBy(_ d: Float) -> UIRect { UIRect(x: x + d, y: y + d, width: max(0, width - d * 2), height: max(0, height - d * 2)) }

    /// Where two rectangles overlap; nil when they don't.
    func intersection(_ o: UIRect) -> UIRect? {
        let x0 = max(x, o.x), y0 = max(y, o.y), x1 = min(maxX, o.maxX), y1 = min(maxY, o.maxY)
        return x1 > x0 && y1 > y0 ? UIRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0) : nil
    }
}
