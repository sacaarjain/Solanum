import AppKit

// "3 agents running": a frosted pill in the top right of each window's focused terminal (above the files-changed pill,
// which is the pane's own) while coding agents run anywhere in Solanum, with a dot for each one's state. Clicking it
// grows it into a frosted panel, as the files-changed pill does: a row for every tab running one, in any window, the
// agents that need you first; clicking a row goes to that tab.
//
// It also says when an agent finishes, or stops to ask you something, in a tab you're not looking at (in place of the
// corner card): the pill announces it for a few seconds ("✓ T1 finished · 4m"), then keeps a "1 new" badge and a ring
// on that agent's dot, and its row in the list has your prompt, the start of the reply and how long it worked, until you
// go to that tab.
//
// And what each agent left running (Claude Code's background shells, see AgentTasks): its row lists them, its status
// says how many, its dot in the pill is half orange while it's stopped but they run, and one finishing while you're
// elsewhere is announced as its news ("T1 · pytest finished").

/// Every agent running in Solanum, and which pane in each window shows the pill.
final class AgentsRunning {
    static let shared = AgentsRunning()

    /// An agent that finished (or stopped to ask something) while you weren't looking: what it was asked, the start of
    /// its reply, and how long it worked.
    struct Note {
        let status: AgentStatus
        let prompt: String?
        let reply: String?
        let worked: TimeInterval
        /// A background task that finished (its command), rather than the agent itself.
        var task: String?
        var at = Date()
    }

    struct Entry {
        weak var pane: TerminalView?
        let info: AgentInfo
        /// Unseen news from it.
        let note: Note?
        /// "Group › Tab", or the tab's name.
        let place: String
        /// The tab's name, and its group's name and color (shown as the tab bar's chip) when it's in one.
        let title: String
        let group: (name: String, color: NSColor)?
        /// Which window it's in (1-based), said only when there are several.
        let window: Int
        /// What it left running (background tasks), oldest first.
        var tasks: [AgentTask] = []
    }

    private(set) var entries: [Entry] = []
    /// The note the pills are announcing now, and whose (for a few seconds after it comes).
    private(set) var announcing: (pane: TerminalView, note: Note)?
    private var announceEnd: DispatchWorkItem?
    static let announceTime: TimeInterval = 6
    /// Unseen notes, for the pill's badge.
    var unseen: Int { entries.filter { $0.note != nil }.count }
    private var signature: [String] = []
    private var pending = false

    /// Each agent's background tasks (by pane), from the last scan, and the processes seen running while it had stopped
    /// working (those are the background ones; one it runs while working is its own command, until it's still there once
    /// the agent stops).
    private var tasks: [ObjectIdentifier: [AgentTask]] = [:]
    private var background: [ObjectIdentifier: Set<pid_t>] = [:]
    private var lastScan = Date.distantPast
    private var scanning = false
    private static let scanEvery: TimeInterval = 2

    /// Looks again at what the agents on this Mac have running (off the main thread, every couple of seconds).
    private func scanTasks(_ panes: [TerminalView]) {
        guard !scanning, Date().timeIntervalSince(lastScan) >= Self.scanEvery else { return }
        var agents: [pid_t: TerminalView] = [:]
        for p in panes where p.remote == nil { if let pid = p.pty?.foregroundPID { agents[pid] = p } }
        guard !agents.isEmpty || !tasks.isEmpty else { return }
        scanning = true
        lastScan = Date()
        let pids = Set(agents.keys)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let found = AgentTasks.scan(pids)
            DispatchQueue.main.async { self?.took(found, agents) }
        }
    }

    private func took(_ found: [pid_t: [AgentTask]], _ agents: [pid_t: TerminalView]) {
        scanning = false
        var changed = false
        var live = Set<ObjectIdentifier>()
        for (pid, pane) in agents {
            let id = ObjectIdentifier(pane)
            live.insert(id)
            let now = found[pid] ?? []
            let running = Set(now.map(\.pid))
            let idle = pane.agent.map { $0.status != .working } ?? false
            var bg = background[id, default: []].intersection(running)
            if idle { bg.formUnion(running) }
            background[id] = bg
            let shown = now.filter { bg.contains($0.pid) }
            let before = tasks[id] ?? []
            // One that's finished while the agent's stopped, in a tab you're not looking at: news.
            if idle, !pane.isWatched, let done = before.first(where: { !running.contains($0.pid) }), let status = pane.agent?.status {
                let note = Note(status: status, prompt: nil, reply: nil, worked: Date().timeIntervalSince(done.started), task: done.shown)
                announce(note, from: pane)
            }
            if shown != before { tasks[id] = shown; changed = true }
        }
        // Panes whose agent has gone (or that aren't on this Mac) have none, unless set by hand (DevTools).
        for id in tasks.keys where !live.contains(id) && !devTasks.contains(id) { tasks[id] = nil; background[id] = nil; changed = true }
        if changed { setNeedsRefresh() }
    }

    /// Dev aid: panes whose tasks were set by hand (no scan clears them).
    private var devTasks = Set<ObjectIdentifier>()
    func devSetTasks(_ list: [AgentTask], for pane: TerminalView) {
        devTasks.insert(ObjectIdentifier(pane))
        tasks[ObjectIdentifier(pane)] = list
        setNeedsRefresh()
    }

    /// Looked at again once this turn of the run loop is over (asked by every pane each second, and when a tab or pane
    /// is picked), however many ask.
    func setNeedsRefresh() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }

    /// The order you've dragged the agents into (by pane), for as long as Solanum runs; empty for theirs.
    private var ownOrder: [ObjectIdentifier] = []
    var hasOwnOrder: Bool { !ownOrder.isEmpty }

    /// Puts `pane`'s agent at `index` in the list (dragged there); the rest keep the order they're shown in.
    func move(_ pane: TerminalView, to index: Int) {
        var order = entries.compactMap { $0.pane.map(ObjectIdentifier.init) }
        let id = ObjectIdentifier(pane)
        guard let from = order.firstIndex(of: id) else { return }
        order.remove(at: from)
        order.insert(id, at: min(max(0, index), order.count))
        ownOrder = order
        refresh()
    }

    /// Back to the agents that need you first.
    func resetOrder() {
        ownOrder = []
        refresh()
    }

    private func refresh() {
        pending = false
        let windows = (NSApp.delegate as? AppDelegate)?.windows ?? []
        var list: [Entry] = []
        for (w, wc) in windows.enumerated() {
            for tab in wc.allTabs {
                for p in tab.panes {
                    // An agent still running (one that's exited, failed or not, is no longer running).
                    guard let info = p.agent, info.status != .failed, p.pty?.hasForegroundJob == true || p.devPretendingClaude else {
                        if p.agentNote != nil { p.agentNote = nil }
                        continue
                    }
                    // Seen once you're looking at it; stale once it's working again.
                    if p.agentNote != nil, p.isWatched || info.status == .working { p.agentNote = nil }
                    list.append(Entry(pane: p, info: info, note: p.agentNote, place: Self.place(of: tab), title: tab.title,
                                      group: tab.group.map { ($0.displayName, $0.color.color) }, window: w + 1,
                                      tasks: tasks[ObjectIdentifier(p)] ?? []))
                }
            }
        }
        // In the order you've put them in (dragged in the list), any not placed yet after; else the ones that need you
        // first, then those working, then the rest; in tab order within each.
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
        if let a = announcing, a.pane.agentNote == nil || !list.contains(where: { $0.pane === a.pane }) { announcing = nil }
        scanTasks(list.compactMap(\.pane))
        // (Each task by its minutes running too, so the list's "12m" moves on.)
        let sig = list.map { e in
            "\(e.pane.map { ObjectIdentifier($0).hashValue } ?? 0) \(e.info.status) \(e.place) \(e.note != nil) "
                + e.tasks.map { "\($0.pid):\(Int(-$0.started.timeIntervalSinceNow / 60))" }.joined(separator: ",")
        }
            + [announcing.map { "announcing \(ObjectIdentifier($0.pane).hashValue)" } ?? "-"]
        let changed = sig != signature
        entries = list
        signature = sig
        // Each window's pill, over its focused terminal (hidden while its tab shows only a file).
        for wc in windows {
            let host = !list.isEmpty && Config.shared.showAgentsPill && wc.activeTab?.showsTerminal == true ? wc.activeTab?.focusedPane : nil
            if host == nil, wc.agentsPillIfMade == nil { continue }
            wc.agentsPill.set(host: host, changed: changed)
        }
    }

    private static func order(_ s: AgentStatus) -> Int {
        switch s {
        case .waiting: return 0
        case .working: return 1
        case .done: return 2
        case .failed: return 3
        }
    }

    static func place(of tab: TabSession) -> String {
        tab.group.map { "\($0.displayName) › \(tab.title)" } ?? tab.title
    }

    /// An agent finished (or is asking something) in `pane`, while you weren't looking: every window's pill announces it
    /// for a few seconds, then keeps it as news until you go there. False when there's no pill to say it (turned off,
    /// or no window shows a terminal), for the corner card to say it instead.
    @discardableResult
    func announce(_ note: Note, from pane: TerminalView) -> Bool {
        let windows = (NSApp.delegate as? AppDelegate)?.windows ?? []
        guard Config.shared.showAgentsPill, windows.contains(where: { $0.activeTab?.showsTerminal == true }) else { return false }
        pane.agentNote = note
        announcing = (pane, note)
        announceEnd?.cancel()
        let end = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.announcing = nil
            self.setNeedsRefresh()
        }
        announceEnd = end
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.announceTime, execute: end)
        setNeedsRefresh()
        return true
    }

    /// Brings `pane` forward: its window, its column, its tab, and the pane itself within the tab.
    func go(to pane: TerminalView) {
        // Going there is seeing it.
        pane.agentNote = nil
        if announcing?.pane === pane { announcing = nil }
        guard let tab = pane.tab, let column = tab.owner as? TabColumn, let i = column.tabs.firstIndex(of: tab), let owner = column.owner else { return }
        // The pane first, so the tab focuses it when it's shown.
        tab.paneDidFocus(pane)
        owner.focus(column)
        column.select(index: i)
        owner.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        pane.window?.makeFirstResponder(pane)
        setNeedsRefresh()
    }

    static func label(_ n: Int) -> String { n == 1 ? "1 agent running" : "\(n) agents running" }

    /// Dev aid: what's counted, and where the pills show.
    var devState: String {
        let shown = ((NSApp.delegate as? AppDelegate)?.windows ?? []).filter { $0.agentsPillIfMade?.shown == true }.count
        return "agents=\(entries.map { "\($0.place):\($0.info.status.label)\($0.note != nil ? "(new)" : "")\($0.tasks.isEmpty ? "" : "[\($0.tasks.map(\.shown).joined(separator: "; "))]")" }) pills=\(shown) announcing=\(announcing?.pane.tab.map(AgentsRunning.place) ?? "-")"
    }
}

/// The pill and its panel for one window: they sit over the window's tabs (not inside a pane), so switching tabs leaves
/// them where they are; only the focused terminal they're placed over changes, and it places them (top right of it,
/// with its files-changed pill under them).
final class AgentsPillController {
    private weak var root: NSView?
    /// The terminal it's over, which lays it out; nil while it isn't shown.
    private(set) weak var pane: TerminalView?
    private let card = FrostedCard()
    let pill = AgentsPill()
    private let panel = FrostedCard()
    let list = AgentsListCanvas()
    private let scroll: CanvasScroll
    private(set) var shown = false
    private(set) var expanded = false
    private var morphing = false
    private var ghost: PromptChangesGhost?
    private var targetFrame: NSRect = .zero
    private var outsideClicks: Any?
    /// The note last announced here (to pulse once per note), and the pulse's timer.
    private var pulsedAt: Date?
    private var pulseTimer: Timer?
    /// The pill changes width (announcing, or back): it slides to its new width rather than jumping.
    private var animateWidth = false

    init(root: NSView) {
        self.root = root
        scroll = CanvasScroll(list)
        pill.usesCursorRects = true
        list.usesCursorRects = true
        pill.onClick = { [weak self] in
            // While it announces an agent's news, a click goes to that agent; otherwise it opens the list.
            if let a = AgentsRunning.shared.announcing { self?.go(to: a.pane) } else { self?.expand() }
        }
        list.controller = self
        card.isHidden = true
        panel.isHidden = true
        card.body.addSubview(pill)
        pill.autoresizingMask = [.width, .height]
        scroll.autoresizingMask = [.width, .height]
        panel.body.addSubview(scroll)
        root.addSubview(card)
        root.addSubview(panel)
    }

    deinit {
        if let m = outsideClicks { NSEvent.removeMonitor(m) }
        pulseTimer?.invalidate()
        card.removeFromSuperview()
        panel.removeFromSuperview()
    }

    /// Over `host` (the window's focused terminal), or hidden (nil). `changed`: what it says has changed.
    func set(host: TerminalView?, changed: Bool) {
        let moved = host !== pane
        if moved, expanded { collapse(animated: false) }
        let old = pane
        pane = host
        let shown = host != nil
        if changed || shown != self.shown {
            if abs(pill.preferredWidth - card.frame.width) > 1, !card.isHidden { animateWidth = true }
            if let a = AgentsRunning.shared.announcing, a.note.at != pulsedAt { pulsedAt = a.note.at; pulse() }
            pill.needsDisplay = true
            card.refreshCard()
            // The list follows as agents come, go or change state.
            if expanded { refitPanel() }
        }
        self.shown = shown
        card.isHidden = !shown || expanded
        // The terminal it's over places it (and moves its files-changed pill under it); the one it left moves its own back up.
        if moved { old?.needsLayout = true }
        host?.needsLayout = true
    }

    /// Where the pill ends in `pane`'s terms, while it's over it (its files-changed pill goes under it).
    func bottom(in pane: TerminalView) -> CGFloat? {
        guard shown, pane === self.pane, let root else { return nil }
        return pane.convert(card.frame, from: root).maxY
    }

    /// Placed by the terminal it's over: top right of `bounds` (the terminal's), under `top` (its find bar, when open);
    /// the panel opens from there, as tall as its rows (up to the terminal's height).
    func layout(in bounds: NSRect, top: CGFloat, of pane: TerminalView) {
        guard pane === self.pane, let root else { return }
        let inset: CGFloat = 10, right = TerminalView.scrollbarStrip
        let w = min(pill.preferredWidth, 420, bounds.width - inset - right)
        let frame = pane.convert(NSRect(x: bounds.width - w - right, y: top + inset, width: w, height: AgentsPill.height), to: root)
        if animateWidth, frame != card.frame, !expanded {
            animateWidth = false
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.85, 0.25, 1)
                card.animator().frame = frame
            }
        } else if !card.frame.equalTo(frame) {
            animateWidth = false
            card.frame = frame
        }
        let pw = min(400, max(300, bounds.width * 0.4), bounds.width - inset - right)
        list.frame.size.width = pw
        let h = max(80, min(list.measure() + 12, bounds.height - top - inset * 2))
        targetFrame = pane.convert(NSRect(x: bounds.width - pw - right, y: top + inset, width: pw, height: h), to: root)
        if expanded && !morphing { panel.frame = targetFrame }
    }

    private func refitPanel() {
        pane?.needsLayout = true
        pane?.layoutSubtreeIfNeeded()
        scroll.frame = panel.body.bounds.insetBy(dx: 0, dy: 6)
        scroll.refit()
        panel.refreshCard()
        list.needsDisplay = true
    }

    /// Two soft pulses of the news's color, as it comes.
    private func pulse() {
        pulseTimer?.invalidate()
        let start = CACurrentMediaTime(), length = 1.6
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            let e = CACurrentMediaTime() - start
            if e >= length {
                timer.invalidate()
                self.pulseTimer = nil
                self.pill.pulse = 0
            } else {
                self.pill.pulse = CGFloat(sin(e / length * 2 * .pi * 2 - .pi / 2) * 0.5 + 0.5)
            }
            self.pill.needsDisplay = true
        }
        RunLoop.main.add(t, forMode: .common)
        pulseTimer = t
    }

    func applyTheme() {
        card.refreshCard()
        panel.refreshCard()
        pill.needsDisplay = true
        list.needsDisplay = true
    }

    private func makeGhost(at frame: NSRect, picture: NSImage?) -> PromptChangesGhost {
        let g = PromptChangesGhost(frame: frame, picture: picture)
        ghost?.removeFromSuperview()
        ghost = g
        root?.addSubview(g, positioned: .above, relativeTo: nil)
        return g
    }

    /// The pill grows into the list, as the files-changed pill grows into its panel (that one folds away first).
    func expand() {
        guard !expanded, shown, let pane, let root else { return }
        pane.promptChanges?.collapse(animated: false)
        expanded = true
        // Over everything else in the window.
        root.addSubview(panel, positioned: .above, relativeTo: nil)
        refitPanel()
        let from = card.frame, to = targetFrame
        panel.frame = to
        refitPanel()
        panel.isHidden = false
        panel.alphaValue = 0
        let g = makeGhost(at: from, picture: panel.picture())
        g.alphaValue = 0
        morphing = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.expanded else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.85, 0.25, 1)
                g.animator().frame = to
            }, completionHandler: { [weak self] in
                guard let self, self.expanded else { return }
                self.morphing = false
                self.panel.alphaValue = 1
                g.removeFromSuperview()
                if self.ghost === g { self.ghost = nil }
                self.card.isHidden = true
                self.card.alphaValue = 1
                self.pane?.needsLayout = true
                self.list.display()
                self.root?.window?.invalidateCursorRects(for: self.list)
                self.list.refreshPointer()
            })
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.1
                g.animator().alphaValue = 1
                self.card.animator().alphaValue = 0
            }
        }
        root.window?.makeFirstResponder(list)
        watchOutsideClicks(true)
    }

    /// The list shrinks back into the pill.
    func collapse(animated: Bool = true) {
        guard expanded else { return }
        expanded = false
        list.keyed = nil
        watchOutsideClicks(false)
        if let w = root?.window, w.firstResponder === list { w.makeFirstResponder(pane) }
        let showPill = { [weak self] in
            guard let self, !self.expanded else { return }
            self.morphing = false
            self.ghost?.removeFromSuperview()
            self.ghost = nil
            self.panel.isHidden = true
            self.panel.alphaValue = 1
            self.card.alphaValue = 1
            self.card.isHidden = !self.shown
            if self.shown { self.pill.refreshPointer() }
            self.pane?.needsLayout = true
        }
        guard animated, !panel.isHidden, shown else { return showPill() }
        morphing = true
        let g = makeGhost(at: panel.frame, picture: panel.picture())
        panel.alphaValue = 0
        let into = card.frame
        card.isHidden = false
        card.alphaValue = 0
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.9, 0.6)
                g.animator().frame = into
            }, completionHandler: showPill)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) { [weak self] in
                guard let self, !self.expanded else { return }
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.09
                    g.animator().alphaValue = 0
                    self.card.animator().alphaValue = 1
                }
            }
        }
    }

    /// A click anywhere in the window but the list folds it back (the click still does what it does there).
    private func watchOutsideClicks(_ on: Bool) {
        if let m = outsideClicks { NSEvent.removeMonitor(m); outsideClicks = nil }
        guard on else { return }
        root?.window?.acceptsMouseMovedEvents = true
        outsideClicks = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .mouseMoved]) { [weak self] e in
            guard let self, let root = self.root, e.window === root.window else { return e }
            if e.type == .mouseMoved {
                if !self.morphing { self.list.pointerMoved(to: e.locationInWindow) }
                return e
            }
            if !self.panel.frame.contains(root.convert(e.locationInWindow, from: nil)) { self.collapse() }
            return e
        }
    }

    /// A row was clicked: the list folds away and that agent's tab comes forward.
    func go(to pane: TerminalView) {
        collapse(animated: pane === self.pane)
        AgentsRunning.shared.go(to: pane)
    }

    /// The terminal it's over (the list says which agent is "here").
    var host: TerminalView? { pane }
}

/// "3 agents running ● ● ●": a dot in each agent's state's color.
final class AgentsPill: PageCanvas {
    static let height: CGFloat = 30
    private static let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
    private static let maxDots = 10
    var onClick: (() -> Void)?

    /// How lit the pulse is (0 to 1), as news comes.
    var pulse: CGFloat = 0
    private static let badgeFont = NSFont.systemFont(ofSize: 10, weight: .bold)

    override func tip(for id: String) -> String? {
        AgentsRunning.shared.announcing != nil ? "Go to this agent's tab" : "Tabs running agents, in every window: click to see them and go to one"
    }

    private var entries: [AgentsRunning.Entry] { AgentsRunning.shared.entries }
    private var label: String {
        if let a = AgentsRunning.shared.announcing { return Self.announcement(a.note, a.pane) }
        return AgentsRunning.label(entries.count)
    }
    private var badge: String? {
        let n = AgentsRunning.shared.unseen
        return n > 0 && AgentsRunning.shared.announcing == nil ? "\(n) new" : nil
    }

    /// "T1 finished · 4m", "T2 needs you", "T1 · pytest finished".
    static func announcement(_ n: AgentsRunning.Note, _ pane: TerminalView) -> String {
        let name = pane.tab?.title ?? pane.agent?.kind.name ?? "Agent"
        if let t = n.task { return "\(name) · \(t.count > 32 ? String(t.prefix(30)) + "…" : t) finished" }
        return n.status == .waiting ? "\(name) needs you" : "\(name) finished · \(TerminalView.formatDuration(n.worked))"
    }

    /// The room an agent's dot takes: 10 points, or 15 with a ring round it (11 across) for unseen news.
    private static func slot(_ e: AgentsRunning.Entry) -> CGFloat { e.note != nil ? 15 : 10 }

    /// Past the dots shown, how many more agents there are ("+2").
    private var more: String? { entries.count > Self.maxDots ? "+\(entries.count - Self.maxDots)" : nil }
    private static let moreFont = NSFont.systemFont(ofSize: 11, weight: .semibold)

    var preferredWidth: CGFloat {
        if AgentsRunning.shared.announcing != nil { return 34 + PageCanvas.textWidth(label, Self.font) + 14 }
        let dots = entries.prefix(Self.maxDots).reduce(CGFloat(0)) { $0 + Self.slot($1) }
        var w = 32 + PageCanvas.textWidth(label, Self.font) + (dots > 0 ? 8 + dots : 0) + 12
        if let m = more { w += 2 + PageCanvas.textWidth(m, Self.moreFont) + 2 }
        if let b = badge { w += 6 + PageCanvas.textWidth(b, Self.badgeFont) + 12 }
        return w
    }

    override func render() -> CGFloat {
        let r = bounds
        let ty = AtlassianHeader.textY(Self.font, in: r)
        if let a = AgentsRunning.shared.announcing {
            // The news, on its state's color, pulsing as it comes.
            let tint = a.note.status.color
            fill(r, tint.withAlphaComponent(0.14 + 0.22 * pulse), radius: PageCanvas.radius)
            if hover == "agents" { fill(r, th.foreground.withAlphaComponent(0.08), radius: PageCanvas.radius) }
            // A dot of its color with a white ✓ (finished) or ? (asking) on it.
            let badge = NSRect(x: 11, y: (r.midY - 8).rounded(), width: 16, height: 16)
            fill(badge, tint, radius: 8)
            symbol(a.note.status == .waiting ? "questionmark" : "checkmark", badge, .white, size: 9, weight: .heavy)
            text(label, Self.font, th.foreground, x: 34, y: ty, width: r.width - 34 - 10)
            hit(r, "agents") { [weak self] in self?.onClick?() }
            return r.height
        }
        if hover == "agents" { fill(r, th.foreground.withAlphaComponent(0.08), radius: PageCanvas.radius) }
        symbol("sparkles", NSRect(x: 10, y: 0, width: 16, height: r.height), th.accent, size: 11, weight: .semibold)
        text(label, Self.font, th.foreground, x: 32, y: ty, width: r.width - 32)
        var x = 32 + PageCanvas.textWidth(label, Self.font) + 8
        if !measuring {
            for e in entries.prefix(Self.maxDots) {
                // Centered in its slot: a ringed one's wider, so its ring keeps clear of the dots beside it.
                let slot = Self.slot(e)
                let dot = NSRect(x: (x + (slot - 10) / 2).rounded(), y: (r.midY - 3).rounded(), width: 6, height: 6)
                e.info.status.color.setFill()
                NSBezierPath(ovalIn: dot).fill()
                // Stopped, but with background tasks running: its right half in the working color.
                if !e.tasks.isEmpty, e.info.status != .working, let ctx = NSGraphicsContext.current?.cgContext {
                    ctx.saveGState()
                    ctx.clip(to: NSRect(x: dot.midX, y: dot.minY, width: dot.width / 2, height: dot.height))
                    AgentStatus.working.color.setFill()
                    NSBezierPath(ovalIn: dot).fill()
                    ctx.restoreGState()
                }
                // Unseen news: a ring around its dot.
                if e.note != nil {
                    e.info.status.color.setStroke()
                    let ring = NSBezierPath(ovalIn: dot.insetBy(dx: -2.5, dy: -2.5))
                    ring.lineWidth = 1.2
                    ring.stroke()
                }
                x += slot
            }
        }
        if let m = more {
            x += 2
            text(m, Self.moreFont, th.dimText, x: x, y: AtlassianHeader.textY(Self.moreFont, in: r), width: 40)
            x += PageCanvas.textWidth(m, Self.moreFont) + 2
        }
        if let b = badge {
            x += 4
            pill(b, x: x, y: (r.midY - 9).rounded(), height: 18, color: th.accent, font: Self.badgeFont)
        }
        hit(r, "agents") { [weak self] in self?.onClick?() }
        return r.height
    }
}

/// The panel's list: a row for each tab running an agent (its mark and state's dot, as on its tab; the tab's name; what
/// it's doing), clicked (or picked with ↑ ↓ and ↩) to go there.
final class AgentsListCanvas: PageCanvas {
    weak var controller: AgentsPillController?
    /// The row picked with the arrow keys.
    var keyed: Int? { didSet { if keyed != oldValue { needsDisplay = true } } }
    static let rowHeight: CGFloat = 38
    private static let lineH: CGFloat = 17

    override func tip(for id: String) -> String? {
        if id == "close" { return "Close (Esc)" }
        if id == "reset" { return "Back to the agents that need you first" }
        if id.hasPrefix("agent.") { return "Go to this tab (drag to reorder)" }
        return nil
    }

    private var rows: [AgentsRunning.Entry] { AgentsRunning.shared.entries.filter { $0.pane != nil } }

    /// A row being dragged to a new place: which, where in it it was grabbed, and where the pointer is.
    private struct Drag {
        let index: Int
        let grab: CGFloat
        let start: NSPoint
        var y: CGFloat
        var started = false
    }
    private var drag: Drag?
    /// Where each row was last drawn (for picking one up).
    private var rowRects: [NSRect] = []
    private var listTop: CGFloat = 0

    private static let lineFont = NSFont.systemFont(ofSize: 11.5)
    private static let taskFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    /// The lines under its name: its news (finished or asking, unseen: your prompt, then how long it worked and the start
    /// of the reply; or which background task finished), then each task it has running, and for how long.
    private func news(_ e: AgentsRunning.Entry) -> [(String, NSColor, NSFont)] {
        var out: [(String, NSColor, NSFont)] = []
        if let n = e.note {
            if let t = n.task {
                out.append(("✓ \(t) finished · ran \(TerminalView.formatDuration(n.worked))", th.foreground.withAlphaComponent(0.8), Self.lineFont))
            } else {
                if let q = n.prompt, !q.isEmpty { out.append(("❯ " + q, th.foreground.withAlphaComponent(0.8), Self.lineFont)) }
                // How long it worked first, so a long reply cuts off rather than it.
                out.append(("Worked \(TerminalView.formatDuration(n.worked))" + (n.reply.map { " · " + $0 } ?? ""), th.dimText, Self.lineFont))
            }
        }
        // How long each has run, in whole minutes (the list is redrawn as the minutes turn, not every second).
        for t in e.tasks {
            let s = max(0, Int(-t.started.timeIntervalSinceNow))
            let ran = s < 60 ? "under a minute" : s < 3600 ? "\(s / 60)m" : "\(s / 3600)h \(s % 3600 / 60)m"
            out.append(("▸ \(t.shown) · \(ran)", th.dimText, Self.taskFont))
        }
        return out
    }

    private func height(_ e: AgentsRunning.Entry) -> CGFloat {
        let n = news(e).count
        return Self.rowHeight + (n == 0 ? 0 : CGFloat(n) * Self.lineH + 4)
    }

    override func render() -> CGFloat {
        let pad: CGFloat = 16, w = bounds.width - pad * 2
        var y: CGFloat = 10
        let list = rows
        var right = bounds.width - pad + 6
        right -= button("", id: "close", x: right, y: y - 2, height: 26, symbol: "xmark", style: .plain, rightAligned: true) { [weak self] in
            self?.controller?.collapse()
        } + 2
        // Put in an order of your own: a way back to the agents that need you first.
        if AgentsRunning.shared.hasOwnOrder {
            right -= button("Reset order", id: "reset", x: right, y: y - 2, height: 26, style: .plain, rightAligned: true) {
                AgentsRunning.shared.resetOrder()
            } + 4
        }
        text(AgentsRunning.label(list.count), .systemFont(ofSize: 13.5, weight: .bold), th.foreground, x: pad, y: y + 3, width: right - pad - 4)
        y += 32
        listTop = y
        let several = Set(list.map(\.window)).count > 1
        let heights = list.map(height)
        if !measuring { rowRects = [] }
        // While a row's dragged: the others close up around a gap where it would land, and it floats under the pointer.
        if let d = drag, d.started, list.indices.contains(d.index) {
            let lifted = heights[d.index]
            let top = min(max(d.y - d.grab, listTop), listTop + heights.reduce(0, +) - lifted)
            let to = target(for: d, heights: heights)
            var others = Array(list.indices)
            others.remove(at: d.index)
            for (k, i) in others.enumerated() {
                if k == to { y += lifted }
                drawRow(list[i], i, at: y, width: w, pad: pad, several: several, lit: false)
                y += heights[i]
            }
            if to >= others.count { y += lifted }
            if !measuring, let ctx = NSGraphicsContext.current?.cgContext {
                ctx.saveGState()
                ctx.setShadow(offset: CGSize(width: 0, height: -3), blur: 12, color: NSColor.black.withAlphaComponent(0.35).cgColor)
                drawRow(list[d.index], d.index, at: top, width: w, pad: pad, several: several, lit: true, lifted: true)
                ctx.restoreGState()
            }
            return y + 4
        }
        for (i, e) in list.enumerated() {
            drawRow(e, i, at: y, width: w, pad: pad, several: several, lit: hover == "agent.\(i)" || keyed == i)
            y += heights[i]
        }
        return y + 4
    }

    /// Where the dragged row would land among the others: the gap (between them, closed up) whose top is nearest its own.
    private func target(for d: Drag, heights: [CGFloat]) -> Int {
        let top = d.y - d.grab
        var gap = listTop, best = 0, bestDistance = abs(top - gap), k = 0
        for i in heights.indices where i != d.index {
            gap += heights[i]
            k += 1
            if abs(top - gap) < bestDistance { best = k; bestDistance = abs(top - gap) }
        }
        return best
    }

    private func drawRow(_ e: AgentsRunning.Entry, _ i: Int, at y: CGFloat, width w: CGFloat, pad: CGFloat, several: Bool, lit: Bool, lifted: Bool = false) {
        guard let p = e.pane else { return }
        let lines = news(e)
        let extra = lines.isEmpty ? 0 : CGFloat(lines.count) * Self.lineH + 4
        let full = NSRect(x: pad - 6, y: y, width: w + 12, height: Self.rowHeight - 4 + extra)
        let r = NSRect(x: full.minX, y: full.minY, width: full.width, height: Self.rowHeight - 4)
        // Lifted, it's drawn solid (the rows under it don't show through).
        if lifted { fill(full, th.background.mix(th.surface, 0.5), radius: PageCanvas.radius) }
        let base = e.note != nil ? e.info.status.color.withAlphaComponent(th.isDark ? 0.16 : 0.12) : th.surface.withAlphaComponent(0.5)
        fill(full, base, radius: PageCanvas.radius)
        if lit { fill(full, th.foreground.withAlphaComponent(0.07), radius: PageCanvas.radius) }
        if !measuring, visible(r) { e.info.draw(at: r.minX + 10, midY: r.midY) }
        let nameX = r.minX + 10 + AgentInfo.markSide + 3 + 6 + 10
        // What it's doing, in its state's color, on the right; where it is (this pane, or another window) after it.
        var status = e.info.status.label
        // Stopped but not idle: what it left running.
        if !e.tasks.isEmpty { status += " · \(e.tasks.count) task\(e.tasks.count == 1 ? "" : "s") running" }
        if p === controller?.host { status += " · here" } else if several { status += " · window \(e.window)" }
        let sf = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        let sw = PageCanvas.textWidth(status, sf)
        let nf = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        let nameEnd = r.maxX - 12 - sw - 10
        var x = nameX
        // A tab in a group: the group's chip, in its color, as the tab bar draws it; then the tab's name.
        if let g = e.group, !g.name.isEmpty {
            let cf = NSFont.systemFont(ofSize: 11, weight: .bold)
            let cw = min(PageCanvas.textWidth(g.name, cf) + 14, max(40, (nameEnd - x) * 0.45))
            let chip = NSRect(x: x, y: (r.midY - 10).rounded(), width: cw, height: 20)
            fill(chip, g.color.withAlphaComponent(0.88), radius: 6)
            text(g.name, cf, g.color.luminance > 0.6 ? NSColor(white: 0.1, alpha: 1) : .white, x: chip.minX + 7, y: chip.minY + 3, width: cw - 14)
            x = chip.maxX + 8
        } else if let g = e.group {
            // An unnamed group: its dot, as on the tab bar.
            fill(NSRect(x: x, y: r.midY - 5, width: 10, height: 10), g.color, radius: 5)
            x += 18
        }
        text(e.title, nf, th.foreground, x: x, y: r.minY + (r.height - 16) / 2, width: nameEnd - x)
        text(status, sf, e.info.status.color.blended(withFraction: 0.25, of: th.foreground) ?? th.dimText,
             x: r.maxX - 12 - sw, y: r.minY + (r.height - 15) / 2, width: sw + 2)
        var ly = r.maxY - 4
        for (line, color, font) in lines {
            text(line, font, color, x: nameX, y: ly, width: full.maxX - 12 - nameX)
            ly += Self.lineH
        }
        guard !lifted, drag?.started != true else { return }
        if !measuring { rowRects.append(full) }
        hit(full, "agent.\(i)") { [weak self] in self?.controller?.go(to: p) }
    }

    // MARK: Dragging a row to reorder

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if let i = rowRects.firstIndex(where: { $0.contains(p) }) {
            drag = Drag(index: i, grab: p.y - rowRects[i].minY, start: p, y: p.y)
        }
        super.mouseDown(with: e)
    }

    override func mouseDragged(with e: NSEvent) {
        guard var d = drag else { return super.mouseDragged(with: e) }
        let p = convert(e.locationInWindow, from: nil)
        // A few points' move before it's a drag rather than a click.
        if !d.started, hypot(p.x - d.start.x, p.y - d.start.y) < 4 { return }
        if !d.started { d.started = true; hover = nil }
        d.y = p.y
        drag = d
        NSCursor.closedHand.set()
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        guard let d = drag else { return super.mouseUp(with: e) }
        drag = nil
        guard d.started else { return super.mouseUp(with: e) }
        // Let go: it takes the place it was shown in (no click).
        let list = rows
        if list.indices.contains(d.index) {
            let to = target(for: Drag(index: d.index, grab: d.grab, start: d.start, y: convert(e.locationInWindow, from: nil).y), heights: list.map(height))
            if let pane = list[d.index].pane { AgentsRunning.shared.move(pane, to: to) }
        }
        NSCursor.arrow.set()
        needsDisplay = true
        refreshPointer()
    }

    /// Dev aid: drags row `from` (by mouse events) to where row `to` is, and lets go; the order after.
    func devDrag(from: Int, to: Int) -> String {
        display()
        guard let w = window, rowRects.indices.contains(from), rowRects.indices.contains(to) else { return "no rows (\(rowRects.count))" }
        func event(_ type: NSEvent.EventType, _ y: CGFloat) -> NSEvent? {
            let p = convert(NSPoint(x: rowRects[from].midX, y: y), to: nil)
            return NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber, context: nil,
                                      eventNumber: 0, clickCount: 1, pressure: 1)
        }
        let a = rowRects[from].midY, b = rowRects[to].midY + (to > from ? 8 : -8)
        if let e = event(.leftMouseDown, a) { mouseDown(with: e) }
        for k in 1...6 { if let e = event(.leftMouseDragged, a + (b - a) * CGFloat(k) / 6) { mouseDragged(with: e) } }
        if let e = event(.leftMouseUp, b) { mouseUp(with: e) }
        display()
        return AgentsRunning.shared.entries.compactMap { $0.pane?.tab?.title }.joined(separator: ",")
    }

    override func keyDown(with e: NSEvent) {
        let n = rows.count
        switch e.keyCode {
        case 53: if drag != nil { drag = nil; needsDisplay = true } else { controller?.collapse() }
        case 125: keyed = n == 0 ? nil : min(n - 1, (keyed ?? -1) + 1)
        case 126: keyed = n == 0 ? nil : max(0, (keyed ?? n) - 1)
        case 36, 76: if let k = keyed, rows.indices.contains(k), let p = rows[k].pane { controller?.go(to: p) }
        default: super.keyDown(with: e)
        }
    }
}
