import CCanvas
import Foundation
import WinSDK

// "3 agents running", as on the Mac (AgentsRunning.swift there): a frosted pill in the top right of each window's
// focused terminal (above its files-changed pill) while coding agents run anywhere in Solanum, with a dot in each one's
// state's color. Clicking it grows it into a frosted panel: a row for every tab running one, in any window, the ones that
// need you first; clicking a row (or ↑ ↓ and Enter) goes to that tab, and rows drag into an order of your own.
//
// It also says when an agent finishes, or stops to ask you something, in a tab you're not looking at, in place of the
// corner card: the pill announces it for a few seconds ("✓ T1 finished · 4m 23s"), then keeps a "1 new" badge and a
// ring round that agent's dot, and its row has your prompt, how long it worked and the start of the reply, until you go
// to that tab.

/// Every agent running in Solanum, in every window.
final class AgentsRunning {
    static let shared = AgentsRunning()

    /// An agent that finished (or stopped to ask something) while you weren't looking.
    struct Note {
        let status: AgentStatus
        let prompt: String?
        let reply: String?
        let worked: TimeInterval
        /// A background task that finished (its command), rather than the agent itself.
        var task: String? = nil
        var at = Date()
    }

    struct Entry {
        weak var pane: TerminalPane?
        let info: AgentInfo
        let note: Note?
        let title: String
        let group: (name: String, color: UInt32)?
        /// Which window it's in (1-based), said only when there are several.
        let window: Int
        /// What it left running (background tasks), oldest first.
        var tasks: [AgentTask] = []
    }

    private(set) var entries: [Entry] = []
    /// The news the pills are announcing now, and whose, until when.
    private(set) var announcing: (pane: TerminalPane, note: Note, until: Date)?
    static let announceTime: TimeInterval = 6
    var unseen: Int { entries.filter { $0.note != nil }.count }
    /// What the pills show, to redraw only when it changes.
    private(set) var signature = ""

    // MARK: Background tasks

    /// Each tab's background tasks from the last scan, and the processes seen running while its agent had stopped
    /// working (those are the background ones; one it runs while working is its own command, until it's still there
    /// once the agent stops).
    private var tasks: [ObjectIdentifier: [AgentTask]] = [:]
    private var background: [ObjectIdentifier: Set<DWORD>] = [:]
    private var lastScan = Date.distantPast
    private var scanning = false

    /// Looks again at what the agents on this PC have running, off the window's thread, every couple of seconds.
    private func scanTasks(_ panes: [TerminalPane]) {
        guard !scanning, Date().timeIntervalSince(lastScan) >= 2 else { return }
        var shells: [ObjectIdentifier: DWORD] = [:]
        var byID: [ObjectIdentifier: TerminalPane] = [:]
        for p in panes where p.sshArguments == nil && p.shellProcessID != 0 {
            shells[ObjectIdentifier(p)] = p.shellProcessID
            byID[ObjectIdentifier(p)] = p
        }
        guard !shells.isEmpty || !tasks.isEmpty else { return }
        scanning = true
        lastScan = Date()
        let post = TerminalWindow.onAnyWindowThread
        startThread { [weak self] in
            let found = AgentTasks.scan(shells)
            post { self?.took(found, byID) }
        }
    }

    private func took(_ found: [ObjectIdentifier: [AgentTask]], _ panes: [ObjectIdentifier: TerminalPane]) {
        scanning = false
        var changed = false
        for (id, pane) in panes {
            let now = found[id] ?? []
            let running = Set(now.map(\.pid))
            let idle = pane.agent.map { $0.status != .working } ?? false
            var bg = background[id, default: []].intersection(running)
            if idle { bg.formUnion(running) }
            background[id] = bg
            let shown = now.filter { bg.contains($0.pid) }
            let before = tasks[id] ?? []
            // One that's finished while the agent's stopped, in a tab you're not looking at: news.
            if idle, pane.host?.isWatching(pane) == false, let done = before.first(where: { !running.contains($0.pid) }), let status = pane.agent?.status {
                announce(Note(status: status, prompt: nil, reply: nil, worked: Date().timeIntervalSince(done.started), task: done.shown), from: pane)
            }
            if shown != before { tasks[id] = shown; changed = true }
        }
        for id in tasks.keys where panes[id] == nil { tasks[id] = nil; background[id] = nil; changed = true }
        if changed {
            refresh()
            TerminalWindow.allWindows.forEach { $0.agentsChanged() }
        }
    }

    /// For tests: a tab's background tasks, as if scanned.
    func setTasksForTest(_ list: [AgentTask], for pane: TerminalPane) {
        tasks[ObjectIdentifier(pane)] = list
        refresh()
    }

    /// The order you've dragged them into (by pane), for as long as Solanum runs; empty for theirs.
    private var ownOrder: [ObjectIdentifier] = []
    var hasOwnOrder: Bool { !ownOrder.isEmpty }

    func move(_ pane: TerminalPane, to index: Int) {
        var order = entries.compactMap { $0.pane.map(ObjectIdentifier.init) }
        let id = ObjectIdentifier(pane)
        guard let from = order.firstIndex(of: id) else { return }
        order.remove(at: from)
        order.insert(id, at: min(max(0, index), order.count))
        ownOrder = order
        refresh()
    }

    func resetOrder() {
        ownOrder = []
        refresh()
    }

    /// Looked at again from each window's timer: which agents run, in what state, with what news. True when what the
    /// pills show has changed.
    @discardableResult
    func refresh() -> Bool {
        var list: [Entry] = []
        let windows = TerminalWindow.allWindows
        for (w, window) in windows.enumerated() {
            for p in window.allPanes {
                guard let info = p.agent, info.status != .failed else {
                    if p.agentNote != nil { p.agentNote = nil }
                    continue
                }
                // Seen once you're looking at it; stale once it's working again.
                if p.agentNote != nil, window.isWatching(p) || info.status == .working { p.agentNote = nil }
                list.append(Entry(pane: p, info: info, note: p.agentNote, title: p.tabTitle,
                                  group: p.group.map { ($0.name, $0.color.rgb) }, window: w + 1, tasks: tasks[ObjectIdentifier(p)] ?? []))
            }
        }
        let ids = Set(list.compactMap { $0.pane.map(ObjectIdentifier.init) })
        ownOrder.removeAll { !ids.contains($0) }
        let placed = Dictionary(ownOrder.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { a, _ in a })
        list = list.enumerated().sorted { a, b in
            let pa = a.element.pane.flatMap { placed[ObjectIdentifier($0)] } ?? Int.max
            let pb = b.element.pane.flatMap { placed[ObjectIdentifier($0)] } ?? Int.max
            if pa != pb { return pa < pb }
            let ua = Self.order(a.element.info.status), ub = Self.order(b.element.info.status)
            return ua != ub ? ua < ub : a.offset < b.offset
        }.map(\.element)
        if let a = announcing, Date() >= a.until || a.pane.agentNote == nil || !list.contains(where: { $0.pane === a.pane }) { announcing = nil }
        scanTasks(list.compactMap(\.pane))
        // (Each task by its minutes running too, so the list's "12m" moves on.)
        let sig = list.map { e in "\(e.pane.map { ObjectIdentifier($0).hashValue } ?? 0) \(e.info.kind.command) \(e.info.status) \(e.title) \(e.group?.name ?? "-") \(e.note != nil) \(e.window) "
            + e.tasks.map { "\($0.pid):\(Int(-$0.started.timeIntervalSinceNow / 60))" }.joined(separator: ",") }
            .joined(separator: "|") + (announcing.map { " announcing \($0.note.at.timeIntervalSince1970)" } ?? "") + " \(ownOrder.count)"
        entries = list
        let changed = sig != signature
        signature = sig
        return changed
    }

    private static func order(_ s: AgentStatus) -> Int {
        switch s {
        case .waiting: return 0
        case .working: return 1
        case .done: return 2
        case .failed: return 3
        }
    }

    /// An agent finished (or is asking something) in `pane` while you weren't looking: every window's pill announces it
    /// for a few seconds, then keeps it as news until you go there. False when no pill would say it (turned off, or no
    /// window shows a terminal), for the corner card to say it instead.
    @discardableResult
    func announce(_ note: Note, from pane: TerminalPane) -> Bool {
        guard AppSettings.shared.agentsPill, TerminalWindow.allWindows.contains(where: { $0.showsAgentsPill }) else { return false }
        pane.agentNote = note
        announcing = (pane, note, Date().addingTimeInterval(Self.announceTime))
        refresh()
        TerminalWindow.allWindows.forEach { $0.agentsChanged() }
        return true
    }

    /// Brings `pane` forward: its window and its tab.
    func go(to pane: TerminalPane) {
        pane.agentNote = nil
        if announcing?.pane === pane { announcing = nil }
        pane.host?.goTo(pane)
        refresh()
        TerminalWindow.allWindows.forEach { $0.agentsChanged() }
    }

    /// "1 needs you · 2 working · 5 done", "1 agent working", "8 agents done".
    static func label(_ statuses: [AgentStatus]) -> String {
        let waiting = statuses.filter { $0 == .waiting }.count
        let working = statuses.filter { $0 == .working }.count
        let done = statuses.count - waiting - working
        let parts = [(waiting, waiting == 1 ? "needs you" : "need you"), (working, "working"), (done, "done")].filter { $0.0 > 0 }
        if parts.count == 1, let only = parts.first { return "\(only.0) agent\(only.0 == 1 ? "" : "s") \(only.1)" }
        return parts.map { "\($0.0) \($0.1)" }.joined(separator: " · ")
    }

    /// "T1 finished · 4m 23s", "T2 needs you".
    static func announcement(_ n: Note, _ pane: TerminalPane) -> String {
        let name = pane.tabTitle
        if let t = n.task { return "\(name) · \(t.count > 32 ? String(t.prefix(30)) + "…" : t) finished" }
        return n.status == .waiting ? "\(name) needs you" : "\(name) finished · \(NoticeRules.formatDuration(n.worked))"
    }
}

/// One window's pill and its list, over the window's focused terminal.
final class AgentsPill {
    var invalidate: () -> Void = {}
    var animate: () -> Void = {}

    private(set) weak var pane: TerminalPane?
    private(set) var expanded = false
    private var entries: [AgentsRunning.Entry] { AgentsRunning.shared.entries }

    private var hits: [(rect: UIRect, id: String, run: (() -> Void)?)] = []
    private(set) var hover: String?
    private var pillRect: UIRect?
    private var panelRect: UIRect?
    /// The row picked with the arrow keys.
    private var keyed: Int?

    /// Growing out of the pill (or back), and the pulse as news comes.
    private var morph: (start: Date, opening: Bool)?
    private var pulseStart: Date?
    private var pulsedFor: Date?
    private static let growTime = 0.3, shrinkTime = 0.22, pulseTime = 1.6
    /// The pill sliding to a new width (news coming or going).
    private var widthFrom: (width: Float, start: Date)?
    private var lastWidth: Float = 0

    var isAnimating: Bool { morph != nil || pulseStart != nil || widthFrom != nil }

    /// From the window's animation timer. True while there's more to show.
    func tick() -> Bool {
        let now = Date()
        if let m = morph, now.timeIntervalSince(m.start) >= (m.opening ? Self.growTime : Self.shrinkTime) { morph = nil }
        if let p = pulseStart, now.timeIntervalSince(p) >= Self.pulseTime { pulseStart = nil }
        if let w = widthFrom, now.timeIntervalSince(w.start) >= 0.25 { widthFrom = nil }
        return isAnimating
    }

    /// The pill shows over `pane`, or nowhere (nil). New news pulses.
    func follow(_ pane: TerminalPane?) {
        if pane !== self.pane, expanded { collapse(animated: false) }
        self.pane = pane
        if let a = AgentsRunning.shared.announcing, a.note.at != pulsedFor {
            pulsedFor = a.note.at
            pulseStart = Date()
            animate()
        }
    }

    /// The files-changed panel folds when this opens (and this when it does).
    var onExpand: () -> Void = {}

    func expand() {
        guard !expanded, pane != nil, !entries.isEmpty else { return }
        onExpand()
        expanded = true
        keyed = nil
        morph = (Date(), true)
        animate()
        invalidate()
    }

    func collapse(animated: Bool = true) {
        guard expanded else { return }
        expanded = false
        drag = nil
        morph = animated ? (Date(), false) : nil
        if animated { animate() }
        invalidate()
    }

    private func go(to pane: TerminalPane) {
        collapse(animated: pane === self.pane)
        AgentsRunning.shared.go(to: pane)
    }

    // MARK: Sizes

    private static let pillHeight: Float = 30, maxDots = 10, rowHeight: Float = 38, lineH: Float = 17

    private var label: String {
        if let a = AgentsRunning.shared.announcing { return AgentsRunning.announcement(a.note, a.pane) }
        return AgentsRunning.label(entries.map(\.info.status))
    }
    private var badge: String? {
        let n = AgentsRunning.shared.unseen
        return n > 0 && AgentsRunning.shared.announcing == nil ? "\(n) new" : nil
    }
    private var more: String? { entries.count > Self.maxDots ? "+\(entries.count - Self.maxDots)" : nil }
    private static func slot(_ e: AgentsRunning.Entry) -> Float { e.note != nil ? 15 : 10 }

    private func pillWidth(_ p: PanelPaint) -> Float {
        let s = p.scale
        if AgentsRunning.shared.announcing != nil { return 34 * s + p.width(label, pixels: 12, semibold: true) + 14 * s }
        let dots = entries.prefix(Self.maxDots).reduce(Float(0)) { $0 + Self.slot($1) } * s
        var w = 32 * s + p.width(label, pixels: 12, semibold: true) + (dots > 0 ? 8 * s + dots : 0) + 12 * s
        if let m = more { w += 4 * s + p.width(m, pixels: 11, semibold: true) }
        if let b = badge { w += 6 * s + p.width(b, pixels: 10, semibold: true) + 12 * s }
        return w
    }

    /// Where the pill would go over `area`: its bottom is where the files-changed pill starts.
    func pillFrame(in area: UIRect, _ p: PanelPaint) -> UIRect {
        let s = p.scale, inset = 10 * s, right = PromptChangesPanel.barStrip * s
        var w = min(pillWidth(p), 420 * s, area.width - inset - right)
        if abs(w - lastWidth) > 1, lastWidth > 0, widthFrom == nil, !expanded { widthFrom = (lastWidth, Date()); animate() }
        if let f = widthFrom {
            let t = Float(min(1, Date().timeIntervalSince(f.start) / 0.25))
            let e = 1 - pow(1 - t, 3)
            let target = w
            w = f.width + (target - f.width) * e
            if t >= 1 { lastWidth = target }
        } else {
            lastWidth = w
        }
        return UIRect(x: (area.maxX - w - right).rounded(), y: (area.y + inset).rounded(), width: w.rounded(), height: (Self.pillHeight * s).rounded())
    }

    private func panelFrame(in area: UIRect, _ p: PanelPaint) -> UIRect {
        let s = p.scale, inset = 10 * s, right = PromptChangesPanel.barStrip * s
        let w = min(400 * s, max(300 * s, area.width * 0.4), area.width - inset - right)
        let h = max(80 * s, min(renderList(p, width: w, top: 0, x0: 0, measuring: true) + 2 * s, area.height - inset * 2))
        return UIRect(x: (area.maxX - w - right).rounded(), y: (area.y + inset).rounded(), width: w.rounded(), height: h.rounded())
    }

    /// How far down the list is scrolled.
    private var scrollY: Float = 0
    private var scrollMaxY: Float = 0

    // MARK: Drawing

    /// Over `pane`'s terminal (`area`): the pill, or the list. Where the pill ends (for the files-changed pill under it);
    /// nil when it isn't shown.
    @discardableResult
    func draw(over pane: TerminalPane, area: UIRect, canvas: Canvas, scale s: Float) -> Float? {
        hits = []
        rowRects = []
        pillRect = nil
        panelRect = nil
        guard pane === self.pane, !entries.isEmpty || morph != nil else { return nil }
        lastScale = s
        let p = PanelPaint(canvas: canvas, scale: s)
        let pill = pillFrame(in: area, p)
        let bottom = pill.maxY - area.y
        if let m = morph {
            let panel = panelFrame(in: area, p)
            let span = m.opening ? Self.growTime : Self.shrinkTime
            let t = Float(min(1, Date().timeIntervalSince(m.start) / span))
            let e = m.opening ? 1 - pow(1 - t, 3) : t * t
            let k = m.opening ? e : 1 - e
            let r = UIRect(x: pill.x + (panel.x - pill.x) * k, y: pill.y + (panel.y - pill.y) * k,
                           width: pill.width + (panel.width - pill.width) * k, height: pill.height + (panel.height - pill.height) * k)
            PromptChangesPanel.card(p, r)
            sol_canvas_push_clip(canvas.raw, r.x, r.y, r.width, r.height)
            if k < 0.35 {
                sol_canvas_push_opacity(canvas.raw, 1 - k / 0.35)
                drawPill(p, UIRect(x: r.x, y: r.y, width: pill.width, height: pill.height))
                sol_canvas_pop_opacity(canvas.raw)
            } else {
                sol_canvas_push_opacity(canvas.raw, min(1, (k - 0.35) / 0.4))
                renderList(p, width: panel.width, top: r.y, x0: r.x, measuring: false, clip: r, recording: false)
                sol_canvas_pop_opacity(canvas.raw)
            }
            sol_canvas_pop_clip(canvas.raw)
            return bottom
        }
        if expanded {
            let panel = panelFrame(in: area, p)
            panelRect = panel
            PromptChangesPanel.card(p, panel)
            sol_canvas_push_clip(canvas.raw, panel.x, panel.y, panel.width, panel.height)
            let full = renderList(p, width: panel.width, top: panel.y - scrollY, x0: panel.x, measuring: false, clip: panel)
            sol_canvas_pop_clip(canvas.raw)
            scrollMaxY = max(0, full + 12 * s - panel.height)
            if scrollY > scrollMaxY { scrollY = scrollMaxY }
            drawHoverTip(p, within: area)
            return bottom
        }
        pillRect = pill
        PromptChangesPanel.card(p, pill)
        drawPill(p, pill)
        hits.append((pill, "agents", { [weak self] in
            guard let self else { return }
            // While it announces news, a click goes to that agent; otherwise it opens the list.
            if let a = AgentsRunning.shared.announcing { self.go(to: a.pane) } else { self.expand() }
        }))
        drawHoverTip(p, within: area)
        return bottom
    }

    private func drawPill(_ p: PanelPaint, _ r: UIRect) {
        let s = p.scale, fg = TerminalPalette.foreground, c = p.canvas.raw
        if let a = AgentsRunning.shared.announcing {
            // The news, on its state's color, pulsing as it comes.
            let tint = a.note.status.rgb
            let pulse: Float = pulseStart.map { Float(sin(Date().timeIntervalSince($0) / Self.pulseTime * 2 * .pi * 2 - .pi / 2) * 0.5 + 0.5) } ?? 0
            p.fill(r, tint, 0.14 + 0.22 * pulse, radius: PromptChangesPanel.radius)
            if hover == "agents" { p.fill(r, fg, 0.08, radius: PromptChangesPanel.radius) }
            let cx = r.x + 19 * s, cy = r.y + r.height / 2, rad = 8 * s
            sol_canvas_fill_ellipse(c, cx, cy, rad, rad, tint, 1)
            if a.note.status == .waiting {
                let t = Array("?".utf16), tw = sol_canvas_measure_label(c, t, 1, 11 * s, 1)
                sol_canvas_draw_label(c, cx - tw / 2, cy - rad, tw + 2, rad * 2, t, 1, 11 * s, 1, 0xFFFFFF, 1)
            } else {
                sol_canvas_draw_icon(c, cx - rad, cy - rad, rad * 2, rad * 2, 0xE73E, 9 * s, 0xFFFFFF, 1)
            }
            p.label(label, UIRect(x: r.x + 34 * s, y: r.y, width: max(0, r.width - 44 * s), height: r.height), pixels: 12, semibold: true)
            return
        }
        if hover == "agents" { p.fill(r, fg, 0.08, radius: PromptChangesPanel.radius) }
        PromptChangesPanel.sparkles(p, UIRect(x: r.x + 11 * s, y: r.y + (r.height - 14 * s) / 2, width: 14 * s, height: 14 * s), color: TerminalPalette.accent)
        p.label(label, UIRect(x: r.x + 32 * s, y: r.y, width: max(0, r.width - 40 * s), height: r.height), pixels: 12, semibold: true)
        var x = r.x + 32 * s + p.width(label, pixels: 12, semibold: true) + 8 * s
        for e in entries.prefix(Self.maxDots) {
            guard x < r.maxX - 6 * s else { break }
            let slot = Self.slot(e) * s
            let cx = x + slot / 2, cy = r.y + r.height / 2
            sol_canvas_fill_ellipse(c, cx, cy, 3 * s, 3 * s, e.info.status.rgb, 1)
            // Stopped, but with background tasks running: its right half in the working color.
            if !e.tasks.isEmpty, e.info.status != .working {
                sol_canvas_push_clip(c, cx, cy - 4 * s, 4 * s, 8 * s)
                sol_canvas_fill_ellipse(c, cx, cy, 3 * s, 3 * s, AgentStatus.working.rgb, 1)
                sol_canvas_pop_clip(c)
            }
            // Unseen news: a ring around its dot.
            if e.note != nil {
                let ring = 5.5 * s
                var xy: [Float] = []
                for k in 0...24 {
                    let a = Float(k) / 24 * 2 * .pi
                    xy += [cx + cos(a) * ring, cy + sin(a) * ring]
                }
                xy.withUnsafeBufferPointer { sol_canvas_stroke_polyline(c, $0.baseAddress, Int32(xy.count / 2), 1, e.info.status.rgb, 1, 1.2 * s) }
            }
            x += slot
        }
        if let m = more {
            x += 2 * s
            p.label(m, UIRect(x: x, y: r.y, width: 40 * s, height: r.height), pixels: 11, semibold: true, alpha: 0.55)
            x += p.width(m, pixels: 11, semibold: true) + 2 * s
        }
        if let b = badge {
            x += 4 * s
            let bw = p.width(b, pixels: 10, semibold: true) + 12 * s
            let chip = UIRect(x: x, y: r.y + (r.height - 18 * s) / 2, width: bw, height: 18 * s)
            p.fill(chip, TerminalPalette.accent, TerminalPalette.isDark ? 0.2 : 0.14, radius: 9)
            p.label(b, UIRect(x: chip.x + 6 * s, y: chip.y, width: bw, height: chip.height), pixels: 10, semibold: true, color: TerminalPalette.accent)
        }
    }

    /// The lines under a row's name: its unseen news (your prompt, then how long it worked and the start of the reply).
    private func news(_ e: AgentsRunning.Entry) -> [(String, Float)] {
        var out: [(String, Float)] = []
        if let n = e.note {
            if let t = n.task {
                out.append(("✓ \(t) finished · ran \(NoticeRules.formatDuration(n.worked))", 0.8))
            } else {
                if let q = n.prompt, !q.isEmpty { out.append(("❯ " + q, 0.8)) }
                out.append(("Worked \(NoticeRules.formatDuration(n.worked))" + (n.reply.map { " · " + $0 } ?? ""), 0.55))
            }
        }
        // How long each has run, in whole minutes.
        for t in e.tasks {
            let s = max(0, Int(-t.started.timeIntervalSinceNow))
            let ran = s < 60 ? "under a minute" : s < 3600 ? "\(s / 60)m" : "\(s / 3600)h \(s % 3600 / 60)m"
            out.append(("▸ \(t.shown) · \(ran)", 0.55))
        }
        return out
    }

    private func height(_ e: AgentsRunning.Entry) -> Float {
        let n = news(e).count
        return Self.rowHeight + (n == 0 ? 0 : Float(n) * Self.lineH + 4)
    }

    /// A row being dragged to a new place: which, where it was grabbed, and where the pointer is.
    private struct Drag {
        let index: Int
        let grab: Float
        let start: (x: Float, y: Float)
        var y: Float
        var started = false
    }
    private var drag: Drag?
    private var rowRects: [UIRect] = []
    private var listTop: Float = 0

    /// The list's contents from `top`: its height.
    @discardableResult
    private func renderList(_ p: PanelPaint, width: Float, top: Float, x0: Float, measuring: Bool, clip: UIRect? = nil, recording: Bool = true) -> Float {
        let s = p.scale, fg = TerminalPalette.foreground
        let pad = 16 * s, w = width - pad * 2
        var y = top + 10 * s
        let list = entries.filter { $0.pane != nil }
        func hit(_ r: UIRect, _ id: String, _ run: (() -> Void)?) {
            guard !measuring, recording else { return }
            if let shown = clip.map({ r.intersection($0) }) ?? r { hits.append((shown, id, run)) }
        }
        var right = x0 + width - pad + 6 * s
        // ✕, and with an order of your own, a way back to the agents that need you first.
        let close = UIRect(x: right - 26 * s, y: y - 2 * s, width: 26 * s, height: 26 * s)
        if !measuring {
            if hover == "close" { p.fill(close, fg, 0.07, radius: PromptChangesPanel.radius) }
            p.icon(0xE711, close, pixels: 11, color: TerminalPalette.accent)
        }
        hit(close, "close") { [weak self] in self?.collapse() }
        right -= 28 * s
        if AgentsRunning.shared.hasOwnOrder {
            let tw = p.width("Reset order", pixels: 12, semibold: true) + 20 * s
            let r = UIRect(x: right - tw, y: y - 2 * s, width: tw, height: 26 * s)
            if !measuring {
                if hover == "reset" { p.fill(r, fg, 0.07, radius: PromptChangesPanel.radius) }
                p.label("Reset order", UIRect(x: r.x + 10 * s, y: r.y, width: tw, height: r.height), pixels: 12, semibold: true, color: TerminalPalette.accent)
            }
            hit(r, "reset") { AgentsRunning.shared.resetOrder() }
            right -= tw + 4 * s
        }
        if !measuring {
            p.label(AgentsRunning.label(list.map(\.info.status)), UIRect(x: x0 + pad, y: y, width: max(0, right - x0 - pad), height: 22 * s), pixels: 13.5, semibold: true)
        }
        y += 32 * s
        listTop = y
        let several = Set(list.map(\.window)).count > 1
        let heights = list.map { height($0) * s }
        if let d = drag, d.started, list.indices.contains(d.index), !measuring {
            let lifted = heights[d.index]
            let liftedTop = min(max(d.y - d.grab, listTop), listTop + heights.reduce(0, +) - lifted)
            let to = target(for: d, heights: heights)
            var others = Array(list.indices)
            others.remove(at: d.index)
            for (k, i) in others.enumerated() {
                if k == to { y += lifted }
                drawRow(p, list[i], i, at: y, x0: x0, width: w, pad: pad, several: several, lit: false, measuring: measuring, recording: false)
                y += heights[i]
            }
            if to >= others.count { y += lifted }
            for (grow, alpha) in [(Float(10), Float(0.08)), (5, 0.12), (2, 0.16)] {
                let g = grow * s
                sol_canvas_fill_rounded(p.canvas.raw, x0 + pad - 6 * s - g, liftedTop - g + 3 * s, w + 12 * s + g * 2, lifted - 4 * s + g * 2,
                                        PromptChangesPanel.radius * s + g, 0x000000, alpha)
            }
            drawRow(p, list[d.index], d.index, at: liftedTop, x0: x0, width: w, pad: pad, several: several, lit: true, measuring: measuring, recording: false, lifted: true)
            return y + 4 * s - top
        }
        for (i, e) in list.enumerated() {
            drawRow(p, e, i, at: y, x0: x0, width: w, pad: pad, several: several, lit: hover == "agent.\(i)" || keyed == i, measuring: measuring, recording: recording)
            if recording, !measuring, let pane = e.pane {
                let full = UIRect(x: x0 + pad - 6 * s, y: y, width: w + 12 * s, height: heights[i] - 4 * s)
                rowRects.append(full)
                hit(full, "agent.\(i)") { [weak self] in self?.go(to: pane) }
            }
            y += heights[i]
        }
        return y + 4 * s - top
    }

    private func target(for d: Drag, heights: [Float]) -> Int {
        let top = d.y - d.grab
        var gap = listTop, best = 0, bestDistance = abs(top - gap), k = 0
        for i in heights.indices where i != d.index {
            gap += heights[i]
            k += 1
            if abs(top - gap) < bestDistance { best = k; bestDistance = abs(top - gap) }
        }
        return best
    }

    private func drawRow(_ p: PanelPaint, _ e: AgentsRunning.Entry, _ i: Int, at y: Float, x0: Float, width w: Float, pad: Float, several: Bool,
                         lit: Bool, measuring: Bool, recording: Bool, lifted: Bool = false) {
        guard !measuring, let pane = e.pane else { return }
        let s = p.scale, fg = TerminalPalette.foreground, c = p.canvas.raw
        let lines = news(e)
        let extra = lines.isEmpty ? 0 : (Float(lines.count) * Self.lineH + 4) * s
        let full = UIRect(x: x0 + pad - 6 * s, y: y, width: w + 12 * s, height: (Self.rowHeight - 4) * s + extra)
        let r = UIRect(x: full.x, y: full.y, width: full.width, height: (Self.rowHeight - 4) * s)
        if lifted { p.fill(full, PromptChangesPanel.mix(TerminalPalette.background, TerminalPalette.surface, 0.5), 1, radius: PromptChangesPanel.radius) }
        if e.note != nil {
            p.fill(full, e.info.status.rgb, TerminalPalette.isDark ? 0.16 : 0.12, radius: PromptChangesPanel.radius)
        } else {
            p.fill(full, TerminalPalette.surface, 0.5, radius: PromptChangesPanel.radius)
        }
        if lit { p.fill(full, fg, 0.07, radius: PromptChangesPanel.radius) }
        // Its mark and its state's dot, as on its tab.
        let mark = 16 * s
        AgentMarks.draw(e.info.kind, on: p.canvas, in: UIRect(x: r.x + 10 * s, y: r.y + (r.height - mark) / 2, width: mark, height: mark), scale: s)
        sol_canvas_fill_ellipse(c, r.x + 10 * s + mark + 6 * s, r.y + r.height / 2, 3 * s, 3 * s, e.info.status.rgb, 1)
        let nameX = r.x + 10 * s + mark + 16 * s
        var status = e.info.status.label
        if !e.tasks.isEmpty { status += " · \(e.tasks.count) task\(e.tasks.count == 1 ? "" : "s") running" }
        if pane === self.pane { status += " · here" } else if several { status += " · window \(e.window)" }
        let sw = p.width(status, pixels: 11.5, semibold: true)
        let nameEnd = r.maxX - 12 * s - sw - 10 * s
        var x = nameX
        // A tab in a group: the group's chip, in its color, as the tab bar draws it; then the tab's name.
        if let g = e.group, !g.name.isEmpty {
            let cw = min(p.width(g.name, pixels: 11, semibold: true) + 14 * s, max(40 * s, (nameEnd - x) * 0.45))
            let chip = UIRect(x: x, y: r.y + (r.height - 20 * s) / 2, width: cw, height: 20 * s)
            p.fill(chip, g.color, 0.88, radius: 6)
            p.label(g.name, UIRect(x: chip.x + 7 * s, y: chip.y, width: cw - 14 * s, height: chip.height), pixels: 11, semibold: true,
                    color: Self.luminance(g.color) > 0.6 ? 0x1A1A1A : 0xFFFFFF)
            x = chip.maxX + 8 * s
        } else if let g = e.group {
            sol_canvas_fill_ellipse(c, x + 5 * s, r.y + r.height / 2, 5 * s, 5 * s, g.color, 1)
            x += 18 * s
        }
        p.label(e.title, UIRect(x: x, y: r.y, width: max(0, nameEnd - x), height: r.height), pixels: 12.5, semibold: true)
        p.label(status, UIRect(x: r.maxX - 12 * s - sw, y: r.y, width: sw + 2 * s, height: r.height), pixels: 11.5, semibold: true,
                color: PromptChangesPanel.mix(e.info.status.rgb, fg, 0.25))
        var ly = r.maxY - 4 * s
        for (line, alpha) in lines {
            p.label(line, UIRect(x: nameX, y: ly, width: max(0, full.maxX - 12 * s - nameX), height: Self.lineH * s), pixels: 11.5, alpha: alpha)
            ly += Self.lineH * s
        }
    }

    private static func luminance(_ c: UInt32) -> Float {
        (0.2126 * Float((c >> 16) & 0xFF) + 0.7152 * Float((c >> 8) & 0xFF) + 0.0722 * Float(c & 0xFF)) / 255
    }

    /// What the pointer's on does, as the Mac's tooltips say it.
    private func tip(_ id: String) -> String? {
        if id == "agents" {
            return AgentsRunning.shared.announcing != nil ? "Go to this agent's tab" : "Tabs running agents, in every window: click to see them and go to one"
        }
        if id == "close" { return "Close (Esc)" }
        if id == "reset" { return "Back to the agents that need you first" }
        if id.hasPrefix("agent.") { return "Go to this tab (drag to reorder)" }
        return nil
    }

    private func drawHoverTip(_ p: PanelPaint, within bounds: UIRect) {
        guard drag?.started != true, let hover, let text = tip(hover), let r = hits.last(where: { $0.id == hover })?.rect else { return }
        PromptChangesPanel.drawTip(p, text, under: r, within: bounds)
    }

    // MARK: Mouse and keys

    func contains(x: Float, y: Float) -> Bool { (pillRect?.contains(x, y) ?? false) || (panelRect?.contains(x, y) ?? false) }

    func wantsHand(x: Float, y: Float) -> Bool? {
        guard contains(x: x, y: y) else { return nil }
        return hits.last { $0.rect.contains(x, y) && $0.run != nil } != nil
    }

    /// True when the pill or list took it; a press outside the open list folds it (and goes on).
    func mouse(_ message: UINT, x: Float, y: Float) -> Bool {
        let inside = contains(x: x, y: y)
        let over = inside && drag?.started != true ? hits.last(where: { $0.rect.contains(x, y) })?.id : nil
        if over != hover { hover = over; invalidate() }
        switch message {
        case Win.WM_LBUTTONDOWN, Win.WM_LBUTTONDBLCLK:
            guard inside else {
                if expanded { collapse() }
                return false
            }
            if expanded, let i = rowRects.firstIndex(where: { $0.contains(x, y) }), hits.last(where: { $0.rect.contains(x, y) })?.id.hasPrefix("agent.") == true {
                drag = Drag(index: i, grab: y - rowRects[i].y, start: (x, y), y: y)
                return true
            }
            if let h = hits.last(where: { $0.rect.contains(x, y) }), let run = h.run { run() }
            invalidate()
            return true
        case Win.WM_MOUSEMOVE:
            guard var d = drag else { return inside }
            if !d.started, hypot(x - d.start.x, y - d.start.y) < 4 { return true }
            d.started = true
            d.y = y
            drag = d
            invalidate()
            return true
        case Win.WM_LBUTTONUP:
            guard let d = drag else { return inside }
            drag = nil
            let list = entries.filter { $0.pane != nil }
            if !d.started {
                // A click, not a drag: go to that tab.
                if list.indices.contains(d.index), let pane = list[d.index].pane { go(to: pane) }
            } else if list.indices.contains(d.index), let pane = list[d.index].pane {
                AgentsRunning.shared.move(pane, to: target(for: Drag(index: d.index, grab: d.grab, start: d.start, y: y), heights: list.map { height($0) * lastScale }))
            }
            invalidate()
            return true
        default:
            return inside
        }
    }

    /// The scale last drawn at (for dropping a dragged row where it was shown).
    var lastScale: Float = 1

    func wheel(x: Float, y: Float, delta: Float) -> Bool {
        guard let panel = panelRect, panel.contains(x, y) else { return pillRect?.contains(x, y) ?? false }
        scrollY = min(max(0, scrollY - delta), scrollMaxY)
        invalidate()
        return true
    }

    /// Esc, ↑ ↓ and Enter while the list's open.
    func key(_ key: Int32) -> Bool {
        guard expanded else { return false }
        let list = entries.filter { $0.pane != nil }
        let n = list.count
        switch key {
        case Win.VK_ESCAPE:
            if drag != nil { drag = nil } else { collapse() }
        case 0x28: keyed = n == 0 ? nil : min(n - 1, (keyed ?? -1) + 1)
        case 0x26: keyed = n == 0 ? nil : max(0, (keyed ?? n) - 1)
        case Win.VK_RETURN:
            if let k = keyed, list.indices.contains(k), let pane = list[k].pane { go(to: pane) }
        default:
            return false
        }
        invalidate()
        return true
    }

    // MARK: For tests

    var testHits: [String] { hits.map(\.id) }
    func testRect(_ id: String) -> UIRect? { hits.last { $0.id == id }?.rect }
}
