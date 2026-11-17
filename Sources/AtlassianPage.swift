import AppKit

// The Atlassian extension's page (AtlassianModel.swift has its state): a header with the sections (Board, My
// Issues, Pull Requests), the board picker and filters; under it the section, with a ticket's side panel and a pull
// request's page in AtlassianDetail.swift and the forms (Start work, Create, …) in AtlassianSheet.swift.

final class AtlassianPageView: NSView, ExtensionPage {
    let model = AtlassianModel()
    private let header = AtlassianHeader()
    let board = BoardCanvas()
    private(set) var boardScroll: BoardScroll!
    let list = AtlassianListCanvas()
    private var listScroll: CanvasScroll!
    let drawer = IssueDrawer()
    let prPage = PRCanvas()
    private var prScroll: CanvasScroll!
    let setup = AtlassianSetupView()
    private let toast = ToastView()
    let searchField = ThemedField("", placeholder: "Filter", mono: false)
    var sheet: AtlassianSheet?
    private var timer: Timer?
    var onSubtitleChanged: (() -> Void)?

    var section: AtlassianSection {
        get { AtlassianSection(rawValue: model.settings.section) ?? .board }
        set {
            guard newValue != section else { return }
            model.settings.section = newValue.rawValue
            // A ticket's panel would cover the pull requests.
            if newValue == .prs { model.detail = nil }
            if newValue == .prs { findRepo(load: true) } else { model.load() }
            relayout()
        }
    }

    var subtitle: String {
        guard model.connected else { return "Jira & Bitbucket · connect your account" }
        switch section {
        case .board: return "Jira · " + (model.board?.name ?? "Board") + (model.sprintName.map { " · " + $0 } ?? "")
        case .mine: return "Jira · My Issues"
        case .prs: return "Bitbucket · " + (model.repo?.path ?? "Pull Requests")
        }
    }

    var focusView: NSView { model.connected ? board : setup.firstField }

    override init(frame: NSRect) {
        super.init(frame: frame)
        boardScroll = BoardScroll(board)
        listScroll = CanvasScroll(list)
        prScroll = CanvasScroll(prPage)
        header.page = self
        board.page = self
        list.page = self
        drawer.page = self
        prPage.page = self
        setup.model = model
        for v in [header, bodyCard, drawer, setup, toast] as [NSView] { addSubview(v) }
        for v in [boardScroll!, listScroll!, prScroll!] as [NSView] { bodyCard.addSubview(v) }
        header.addSubview(searchField)
        searchField.onEdit = { [weak self] s in self?.model.search = s }
        searchField.font = .systemFont(ofSize: 12.5)
        searchField.layer?.cornerRadius = PageCanvas.radius
        searchField.placeholderAttributedString = NSAttributedString(string: "Filter issues", attributes: [
            .foregroundColor: Config.shared.theme.dimText.withAlphaComponent(0.6), .font: NSFont.systemFont(ofSize: 12.5)])
        model.onChange = { [weak self] in self?.modelChanged() }
        modelChanged()
        model.load()
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit {
        timer?.invalidate()
        if let m = outsideClicks { NSEvent.removeMonitor(m) }
    }

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        timer = nil
        guard window != nil else { return }
        findRepo(load: section == .prs)
        model.load()
        // Others move tickets too: every two minutes while it's on screen.
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            guard let self, NSApp.isActive, self.window?.isVisible == true, !self.isHiddenOrHasHiddenAncestor, !self.board.dragging else { return }
            self.model.load(force: true)
        }
        timer?.tolerance = 20
    }

    /// The tab this page is in.
    var tab: TabSession? {
        var v: NSView? = self
        while let cur = v {
            if let area = cur as? EditorAreaView { return area.tab }
            v = cur.superview
        }
        return nil
    }

    /// The tab's folder on this Mac (its terminal's, else the folder pinned in its sidebar).
    var tabFolder: String? {
        guard let tab else { return nil }
        if tab.focusedPane.remote == nil, let d = tab.focusedPane.currentDirectory { return d }
        if let pinned = tab.pinnedFolder, pinned.fs is LocalFileSystem { return pinned.path }
        return nil
    }

    func findRepo(load: Bool) {
        model.findRepo(tabFolder) { [weak self] in if load || self?.model.prs.isEmpty == false { self?.model.loadPRs() } }
    }

    private func modelChanged() {
        setup.isHidden = model.connected
        for v in [header, boardScroll!, listScroll!, prScroll!] as [NSView] { v.isHidden = !model.connected }
        toast.message = model.toast
        relayout()
        onSubtitleChanged?()
    }

    func relayout() {
        needsLayout = true
        header.needsDisplay = true
        board.needsDisplay = true
        boardScroll.refit()
        listScroll.refit()
        prScroll.refit()
        drawer.refresh()
        setup.needsLayout = true
    }

    override func layout() {
        super.layout()
        header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: AtlassianHeader.height)
        // The section sits in a rounded card under the header, a little in from the page's edges, as Solanum's panels do.
        let ci = Self.cardInset
        let card = NSRect(x: ci, y: header.frame.maxY, width: max(0, bounds.width - ci * 2), height: max(0, bounds.height - header.frame.maxY - ci))
        if bodyCard.frame != card || bodyCard.isHidden == model.connected { needsDisplay = true }
        bodyCard.frame = card
        bodyCard.isHidden = !model.connected
        let body = bodyCard.bounds
        let s = section
        let showPR = s == .prs && model.pr != nil
        boardScroll.isHidden = !model.connected || s != .board
        listScroll.isHidden = !model.connected || (s == .board) || showPR
        prScroll.isHidden = !model.connected || !showPR
        boardScroll.frame = body
        listScroll.frame = body
        prScroll.frame = body
        placeDrawer(in: card)
        setup.frame = bounds
        searchField.isHidden = s == .prs
        searchField.frame = header.searchRect
        toast.frame = NSRect(x: card.minX + 12, y: card.maxY - 48, width: max(0, card.width - 24), height: 36)
        boardScroll.refit()
        listScroll.refit()
        prScroll.refit()
    }

    func applyTheme() {
        let th = Config.shared.theme
        searchField.textColor = th.foreground
        searchField.layer?.backgroundColor = th.background.withAlphaComponent(0.6).cgColor
        needsDisplay = true
        setup.applyTheme()
        sheet?.applyTheme()
        drawer.applyTheme()
        relayout()
    }

    // MARK: The section's card

    /// As far in from the page's edges as Solanum's cards are apart.
    static let cardInset: CGFloat = Cards.gap
    static let cardRadius: CGFloat = PageCanvas.radius
    private let bodyCard: NSView = {
        let v = FlippedView()
        v.wantsLayer = true
        v.layer?.cornerRadius = AtlassianPageView.cardRadius
        v.layer?.cornerCurve = .continuous
        v.layer?.masksToBounds = true
        return v
    }()

    /// The page around the card: the chrome's wash, as the header had. The card itself is left clear, showing the
    /// theme's own background, so the color change is its edge (no line).
    override func draw(_ dirtyRect: NSRect) {
        let th = Config.shared.theme
        th.tabBarTint.setFill()
        let path = NSBezierPath(rect: bounds)
        if !bodyCard.isHidden {
            path.append(NSBezierPath(roundedRect: bodyCard.frame, xRadius: Self.cardRadius, yRadius: Self.cardRadius))
            path.windingRule = .evenOdd
        }
        path.fill()
    }

    // MARK: The ticket's panel

    /// Whether the panel is out (or on its way out), and the click watcher that closes it.
    private var drawerOut = false
    private var sliding = false
    private var shownDrawerFrame: NSRect = .zero
    private var outsideClicks: Any?

    /// The ticket's panel: a frosted card floating over the right of the section, a little in from its edges. It slides
    /// in from the right when a ticket opens and back out when it's closed.
    private func placeDrawer(in body: NSRect) {
        // Inside the section's card, just in from its edges.
        let inset: CGFloat = 6, right: CGFloat = 6
        let dw = min(480, max(340, body.width * 0.42))
        let shown = NSRect(x: body.maxX - dw - right, y: body.minY + inset, width: dw, height: max(0, body.height - inset * 2))
        shownDrawerFrame = shown
        let away = shown.offsetBy(dx: dw + right + 30, dy: 0)
        let want = model.connected && model.detail != nil
        if want && !drawerOut {
            drawerOut = true
            drawer.isHidden = false
            drawer.frame = away
            drawer.alphaValue = 0
            drawer.scrollToTop()
            watchOutsideClicks(true)
            // From off to the right, once that's been put on screen (in the same pass, the slide would start from
            // wherever the panel's layer last was).
            sliding = true
            DispatchQueue.main.async { [weak self] in
                guard let self, self.drawerOut else { self?.sliding = false; return }
                self.slide(self.drawer, to: self.shownDrawerFrame, alpha: 1, duration: 0.24, curve: .easeOut)
            }
        } else if !want && drawerOut {
            drawerOut = false
            watchOutsideClicks(false)
            slide(drawer, to: away, alpha: 0, duration: 0.18, curve: .easeIn) { [weak self] in
                guard let self, !self.drawerOut else { return }
                self.drawer.isHidden = true
                self.drawer.canvas.lastShown = nil
            }
        } else if want {
            // Kept in place as the page resizes, but not while it's sliding in.
            if !sliding { drawer.frame = shown }
        } else {
            drawer.isHidden = true
        }
    }

    private func slide(_ v: NSView, to frame: NSRect, alpha: CGFloat, duration: TimeInterval, curve: CAMediaTimingFunctionName,
                       done: (() -> Void)? = nil) {
        sliding = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: curve)
            v.animator().frame = frame
            v.animator().alphaValue = alpha
        }, completionHandler: { [weak self] in
            self?.sliding = false
            done?()
            self?.needsLayout = true
        })
    }

    func closeIssue() {
        model.closeDetail()
        needsLayout = true
    }

    /// A click on the page outside the panel closes it, unless it's on something there that does something (a card,
    /// which opens that ticket instead; a row; the header's controls). Forms and dropdowns over the page keep it open.
    private func watchOutsideClicks(_ on: Bool) {
        if let m = outsideClicks { NSEvent.removeMonitor(m); outsideClicks = nil }
        guard on else { return }
        outsideClicks = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] e in
            guard let self, e.window === self.window, self.sheet == nil else { return e }
            if self.closesPanel(clickAt: e.locationInWindow) { self.closeIssue() }
            return e
        }
    }

    /// Whether a click at `p` (window coordinates) is one that closes the ticket's panel.
    func closesPanel(clickAt p: NSPoint) -> Bool {
        guard drawerOut, let root = window?.contentView?.superview ?? window?.contentView,
              let hit = root.hitTest(root.convert(p, from: nil)) else { return false }
        if hit.isDescendant(of: drawer) || !hit.isDescendant(of: self) || hit.isDescendant(of: header) || hit === searchField
            || hit.isDescendant(of: searchField) { return false }
        // Something with an action of its own there.
        var v: NSView? = hit
        while let c = v, c !== self {
            if let canvas = c as? PageCanvas {
                let q = canvas.convert(p, from: nil)
                return !canvas.hits.contains { $0.rect.contains(q) }
            }
            v = c.superview
        }
        return true
    }

    // MARK: Actions

    func openIssue(_ key: String) {
        model.open(key)
        needsLayout = true
    }

    func openPR(_ id: Int) {
        model.openPR(id)
        prScroll.scrollToTop()
        needsLayout = true
    }

    func closePR() {
        model.closePR()
        needsLayout = true
    }

    /// Sends a ticket to Claude Code in this tab, ready for you to add to and send.
    func askClaude(about i: JiraIssue) {
        var lines = ["Jira ticket \(i.key): \(i.summary)", "Status: \(i.status.name) · Type: \(i.type)" + (i.priority.map { " · Priority: \($0)" } ?? "")]
        if let p = i.parentKey { lines.append("Parent: \(p)" + (i.parentSummary.map { " \($0)" } ?? "")) }
        if let url = model.api.browseURL(i.key) { lines.append(url.absoluteString) }
        let desc = ADF.plainText(i.description)
        if !desc.isEmpty { lines += ["", "Description:", desc] }
        lines += ["", ""]
        ExtensionChat.ask(lines.joined(separator: "\n"), from: self, submit: false)
    }

    /// A form over the whole window (the page can be a short strip above the terminal).
    func show(_ s: AtlassianSheet) {
        sheet?.removeFromSuperview()
        guard let content = window?.contentView else { return }
        sheet = s
        s.frame = content.bounds
        s.autoresizingMask = [.width, .height]
        content.addSubview(s)
        s.appear()
    }

    func closeSheet() {
        sheet?.removeFromSuperview()
        sheet = nil
        window?.makeFirstResponder(board)
    }

    // MARK: Dev

    func devState() -> String {
        var cols: [String] = []
        if let c = model.config {
            for (i, col) in c.columns.enumerated() { cols.append("\(col.name)=[\(model.cards(in: i).map(\.key).joined(separator: ","))]") }
        }
        return "section=\(section.rawValue) board=\(model.board?.name ?? "-") cols=\(cols.joined(separator: " ")) detail=\(model.detail?.key ?? "-") "
            + "status=\(model.detail?.status.name ?? "-") pr=\(model.pr.map { "#\($0.id)" } ?? "-") prs=\(model.prs.map(\.id)) repo=\(model.repo?.path ?? "-") "
            + "branch=\(model.branch ?? "-") toast=\(model.toast?.0 ?? "-") sheet=\(sheet?.title ?? "-") onlyMine=\(model.settings.onlyMine) "
            + "prFilter=\(model.prFilter) shownPRs=\(model.shownPRs.map(\.id)) prTab=\(prPage.tab) collapsed=\(model.collapsedFiles.sorted())"
    }
}

// MARK: Header

final class AtlassianHeader: PageCanvas, DropdownAnchor {
    static let height: CGFloat = 96
    weak var page: AtlassianPageView?
    var dropdownWanted: Bool { true }
    var dropdownOpen = false { didSet { needsDisplay = true } }
    private(set) var searchRect: NSRect = .zero

    override func render() -> CGFloat {
        guard let page else { return 0 }
        let model = page.model
        let w = bounds.width, pad: CGFloat = 20

        // Top row: icon, where you are, account.
        let icon = NSRect(x: pad, y: 11, width: 34, height: 34)
        if visible(icon) { AtlassianExtension.drawIcon(icon) }
        let section = page.section
        var title: String
        switch section {
        case .board: title = model.board?.name ?? (model.loadingBoard ? "Loading…" : "Board")
        case .mine: title = "My Issues"
        case .prs: title = model.repo?.slug ?? "Pull Requests"
        }
        let tf = NSFont.systemFont(ofSize: 15, weight: .semibold)
        let tw = min(max(80, w - 560), PageCanvas.textWidth(title, tf))
        let titleRect = NSRect(x: icon.maxX + 8, y: 10, width: tw + (section == .board ? 30 : 12), height: 24)
        if section == .board, model.boards.count > 1 {
            if hover == "board" || dropdownOpen { fill(titleRect, th.foreground.withAlphaComponent(0.08), radius: PageCanvas.radius) }
            symbol("chevron.down", NSRect(x: titleRect.minX + tw + 10, y: 13, width: 14, height: 18), th.dimText, size: 9, weight: .bold)
            hit(titleRect, "board") { [weak self] in self?.showBoards() }
        }
        text(title, tf, th.foreground, x: titleRect.minX + 6, y: 13, width: tw)
        var sub: [String] = []
        switch section {
        case .board:
            if let b = model.board {
                if let k = b.projectKey { sub.append(k) }
                sub.append(b.type == "scrum" ? "Scrum" : b.type == "simple" ? "Team board" : "Kanban")
            }
            if let s = model.sprintName { sub.append(s) }
            let total = model.issues.filter(model.matches).count
            if model.config != nil { sub.append("\(total) issue\(total == 1 ? "" : "s")") }
        case .mine: sub.append("Assigned to you and not done · \(model.mine.count)")
        case .prs:
            if let r = model.repo { sub.append(r.workspace) }
            if let b = model.branch { sub.append("on " + b) }
            if model.repo == nil { sub.append(model.repoRoot == nil ? "This tab's folder isn't a git repository" : "Its origin isn't on Bitbucket") }
        }
        text(sub.joined(separator: " · "), .systemFont(ofSize: 11.5), th.dimText, x: titleRect.minX + 6, y: 34, width: max(80, w - titleRect.minX - 260))

        // Right of the top row: create, refresh, account.
        var x = w - pad
        if let me = model.me {
            let av = NSRect(x: x - 30, y: 13, width: 30, height: 30)
            avatar(me.avatarURL.flatMap(URL.init(string:)), av, initials: PageCanvas.initials(me.displayName))
            if hover == "account" { stroke(av.insetBy(dx: -2, dy: -2), th.accent, radius: av.width / 2 + 2, width: 2) }
            hit(av.insetBy(dx: -2, dy: -2), "account") { [weak self] in self?.showAccount() }
            x -= 42
        }
        let busy = model.loadingBoard || model.loadingMine || model.loadingPRs
        x -= button("", id: "refresh", x: x, y: 13, height: 30, symbol: busy ? "hourglass" : "arrow.clockwise", style: .secondary, rightAligned: true) { [weak page] in
            page?.model.load(force: true)
        } + 8
        if section == .prs {
            if model.repo != nil {
                button("Create pull request", id: "newpr", x: x, y: 13, height: 30, symbol: "plus", style: .primary, rightAligned: true) { [weak page] in
                    guard let page else { return }
                    AtlassianSheet.createPR(on: page)
                }
            }
        } else {
            button("Create", id: "create", x: x, y: 13, height: 30, symbol: "plus", style: .primary, rightAligned: true) { [weak page] in
                guard let page else { return }
                AtlassianSheet.createIssue(on: page)
            }
        }

        // Second row: the sections, then the section's filters, all one height and shape.
        let y2: CGFloat = 54
        var sx = pad
        sx += segmented(AtlassianSection.allCases.map { ($0.rawValue, $0.title, $0.symbol) }, selected: section.rawValue, x: sx, y: y2, prefix: "sec.") { [weak page] id in
            if let s = AtlassianSection(rawValue: id) { page?.section = s }
        } + 14
        if section == .prs {
            searchRect = .zero
            segmented([("all", "All open", nil), ("mine", "Mine", nil), ("review", "To review", nil)], selected: model.prFilter, x: sx, y: y2, prefix: "f.") { [weak page] id in
                page?.model.prFilter = id
                page?.closePR()
            }
        } else {
            searchRect = NSRect(x: sx, y: y2, width: min(220, max(120, w - sx - 150)), height: Self.controlH)
            sx = searchRect.maxX + 8
            if section == .board {
                let mine = model.settings.onlyMine
                let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
                let mw = PageCanvas.textWidth("Only mine", font) + 36
                let mr = NSRect(x: sx, y: y2, width: mw, height: Self.controlH)
                fill(mr, mine ? th.accent.withAlphaComponent(0.16) : th.foreground.withAlphaComponent(hover == "mine" ? 0.10 : 0.05), radius: PageCanvas.radius)
                symbol(mine ? "checkmark.circle" : "circle", NSRect(x: mr.minX + 9, y: mr.minY, width: 14, height: mr.height), mine ? th.accent : th.dimText, size: 11, weight: .semibold)
                text("Only mine", font, mine ? th.foreground : th.dimText, x: mr.minX + 28, y: Self.textY(font, in: mr), width: mw - 30)
                hit(mr, "mine") { [weak page] in
                    guard let page else { return }
                    page.model.settings.onlyMine.toggle()
                    page.model.changed()
                }
            }
        }
        return Self.height
    }

    static let controlH: CGFloat = 30

    /// Where text in `font` sits to look centered in `r`.
    static func textY(_ font: NSFont, in r: NSRect) -> CGFloat {
        r.minY + ((r.height - (font.ascender - font.descender)) / 2).rounded(.down)
    }

    /// A row of choices in one rounded box, the chosen one raised; returns its width.
    @discardableResult
    private func segmented(_ items: [(String, String, String?)], selected: String, x: CGFloat, y: CGFloat, prefix: String,
                           action: @escaping (String) -> Void) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let widths = items.map { PageCanvas.textWidth($0.1, font) + ($0.2 == nil ? 24 : 42) }
        let total = widths.reduce(0, +) + 6
        let box = NSRect(x: x, y: y, width: total, height: Self.controlH)
        fill(box, th.foreground.withAlphaComponent(0.05), radius: PageCanvas.radius)
        var sx = x + 3
        for ((id, title, sym), sw) in zip(items, widths) {
            let r = NSRect(x: sx, y: y + 3, width: sw, height: Self.controlH - 6)
            let on = id == selected
            if on {
                fill(r, th.accent.withAlphaComponent(0.20), radius: PageCanvas.radius)
            } else if hover == prefix + id {
                fill(r, th.foreground.withAlphaComponent(0.07), radius: PageCanvas.radius)
            }
            var tx = r.minX + 12
            if let sym {
                symbol(sym, NSRect(x: r.minX + 10, y: r.minY, width: 16, height: r.height), on ? th.accent : th.dimText, size: 11, weight: .semibold)
                tx = r.minX + 30
            }
            text(title, font, on ? th.foreground : th.dimText, x: tx, y: Self.textY(font, in: r), width: r.maxX - tx)
            hit(r, prefix + id) { action(id) }
            sx += sw
        }
        return total
    }

    private func showBoards() {
        guard let page else { return }
        let m = page.model
        let items = m.boards.map { b in
            DropdownItem.item(b.name, checked: b.id == m.board?.id, symbol: "rectangle.split.3x1", detail: b.projectKey) { [weak page] in page?.model.selectBoard(b.id) }
        }
        ThemedDropdown.show(items, under: self, rect: NSRect(x: 58, y: 10, width: 200, height: 24), minWidth: 280, placeholder: "Boards")
    }

    private func showAccount() {
        guard let page, let me = page.model.me else { return }
        let m = page.model
        var items: [DropdownItem] = [.header(me.displayName), .item(m.settings.email, symbol: "envelope") {}, .item(m.settings.site, symbol: "globe") {
            if let u = URL(string: "https://\(m.settings.site)/jira") { NSWorkspace.shared.open(u) }
        }]
        items.append(.item(m.bitbucketMe.map { "Bitbucket: \($0.displayName)" } ?? "Bitbucket: no token", symbol: "arrow.triangle.pull") {})
        items.append(.separator)
        items.append(.item("Change tokens…", symbol: "key") { [weak page] in
            guard let page else { return }
            AtlassianSheet.tokens(on: page)
        })
        items.append(.item("Sign out", symbol: "rectangle.portrait.and.arrow.right", color: th.red) { [weak page] in page?.model.disconnect() })
        ThemedDropdown.show(items, under: self, rect: NSRect(x: bounds.width - 50, y: 13, width: 30, height: 30), minWidth: 260, searchable: false)
    }
}

// MARK: Board

/// Scrolls the board both ways: its columns keep a readable width and run off to the right when there are many.
final class BoardScroll: NSScrollView {
    let canvas: BoardCanvas

    init(_ canvas: BoardCanvas) {
        self.canvas = canvas
        super.init(frame: .zero)
        documentView = canvas
        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func refit() {
        let size = contentView.bounds.size
        guard size.width > 0 else { return }
        let w = max(size.width, canvas.minimumWidth)
        canvas.frame.size.width = w
        let h = max(canvas.measure(), size.height)
        canvas.frame = NSRect(x: 0, y: 0, width: w, height: h)
        canvas.needsDisplay = true
    }

    override func layout() {
        super.layout()
        refit()
    }
}

final class BoardCanvas: PageCanvas {
    weak var page: AtlassianPageView?
    static let minColumn: CGFloat = 230
    /// From the card's edges: with the card's own inset, the columns line up with the header's controls.
    static let pad: CGFloat = 14
    static let gap: CGFloat = 10

    var minimumWidth: CGFloat {
        let n = CGFloat(page?.model.config?.columns.count ?? 1)
        return Self.pad * 2 + n * Self.minColumn + (n - 1) * Self.gap
    }

    /// Where each card was drawn, and each column, for dragging.
    private var cardRects: [(key: String, column: Int, rect: NSRect)] = []
    private var columnRects: [NSRect] = []
    // Dragging
    private var downKey: String?
    private var downPoint: NSPoint = .zero
    private var grabOffset: NSPoint = .zero
    private(set) var dragging = false
    private var dragPoint: NSPoint = .zero
    private var dropTarget: (column: Int, index: Int)?
    private var autoscroll: Timer?

    override func render() -> CGFloat {
        guard let page else { return 0 }
        let m = page.model
        if !measuring { cardRects = []; columnRects = [] }
        guard let config = m.config else {
            let msg = m.boardError ?? (m.loadingBoard ? "Loading the board…" : "No board yet.")
            symbol(m.boardError == nil ? "rectangle.split.3x1" : "exclamationmark.triangle", NSRect(x: 0, y: 60, width: bounds.width, height: 30),
                   m.boardError == nil ? th.dimText : th.red, size: 22)
            paragraph(msg, .systemFont(ofSize: 13), m.boardError == nil ? th.dimText : th.red, x: max(20, bounds.width / 2 - 240), y: 100,
                      width: min(480, bounds.width - 40))
            return 200
        }
        let n = config.columns.count
        // The ticket's panel floats over the board, so the columns keep their width under it.
        let avail = bounds.width
        let colW = max(Self.minColumn, (avail - Self.pad * 2 - CGFloat(n - 1) * Self.gap) / CGFloat(max(1, n)))
        var maxY: CGFloat = 0
        let viewH = enclosingScrollView?.contentView.bounds.height ?? bounds.height
        for (c, col) in config.columns.enumerated() {
            let x = Self.pad + CGFloat(c) * (colW + Self.gap)
            let cards = m.cards(in: c)
            let isTarget = dragging && dropTarget?.column == c
            // Column body: as tall as the view at least, so there's somewhere to drop.
            var y: CGFloat = 14
            let headerH: CGFloat = 34
            var cardsH: CGFloat = 0
            for card in cards where !(dragging && card.key == downKey) { cardsH += cardHeight(card, width: colW - 16) + 8 }
            if dragging, isTarget, let k = downKey, let card = m.issues.first(where: { $0.key == k }) { cardsH += cardHeight(card, width: colW - 16) + 8 }
            let colH = max(viewH - 28, headerH + cardsH + 16)
            let colRect = NSRect(x: x, y: y, width: colW, height: colH)
            if !measuring { columnRects.append(colRect) }
            let done = col.statusIds.contains { id in m.issues.first { $0.status.id == id }?.status.isDone ?? false } || col.name.lowercased().contains("done")
            fill(colRect, isTarget ? th.accent.withAlphaComponent(0.10) : th.foreground.withAlphaComponent(th.isDark ? 0.035 : 0.04), radius: PageCanvas.radius)
            if isTarget { stroke(colRect, th.accent.withAlphaComponent(0.45), radius: PageCanvas.radius, width: 1.5) }
            // Header: name, count.
            let hf = NSFont.systemFont(ofSize: 11, weight: .bold)
            let name = col.name.uppercased()
            let nw = min(colW - 60, PageCanvas.textWidth(name, hf))
            if done { symbol("checkmark.circle", NSRect(x: x + 10, y: y + 9, width: 14, height: 16), th.green, size: 11, weight: .bold) }
            text(name, hf, th.dimText, x: x + (done ? 28 : 12), y: y + 10, width: nw)
            let countW = pill("\(cards.count)", x: x + (done ? 28 : 12) + nw + 6, y: y + 8, height: 18, color: th.foreground,
                              font: .monospacedDigitSystemFont(ofSize: 10, weight: .bold), minWidth: 22)
            _ = countW
            y += headerH
            var index = 0
            for card in cards {
                if dragging, card.key == downKey { continue }
                if dragging, isTarget, dropTarget?.index == index { y = dropGap(x: x + 8, y: y, width: colW - 16) }
                let h = cardHeight(card, width: colW - 16)
                let r = NSRect(x: x + 8, y: y, width: colW - 16, height: h)
                if !measuring { cardRects.append((card.key, c, r)) }
                if visible(r) { drawCard(card, r, done: done) }
                y += h + 8
                index += 1
            }
            if dragging, isTarget, (dropTarget?.index ?? 0) >= index { y = dropGap(x: x + 8, y: y, width: colW - 16) }
            if cards.isEmpty && !(dragging && isTarget) {
                text(m.search.isEmpty && !m.settings.onlyMine ? "Nothing here" : "No matches", .systemFont(ofSize: 11.5), th.dimText.withAlphaComponent(0.7),
                     x: x, y: y + 8, width: colW, align: .center)
            }
            maxY = max(maxY, colRect.maxY)
        }
        // The card being dragged, under the pointer.
        if dragging, !measuring, let k = downKey, let card = m.issues.first(where: { $0.key == k }) {
            let h = cardHeight(card, width: colW - 16)
            let r = NSRect(x: dragPoint.x - grabOffset.x, y: dragPoint.y - grabOffset.y, width: colW - 16, height: h)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowBlurRadius = 14
            shadow.shadowOffset = NSSize(width: 0, height: -4)
            shadow.shadowColor = NSColor.black.withAlphaComponent(th.isDark ? 0.5 : 0.22)
            shadow.set()
            fill(r, th.surface, radius: PageCanvas.radius)
            NSGraphicsContext.restoreGraphicsState()
            drawCard(card, r, done: false, lifted: true)
        }
        return maxY + 16
    }

    private func dropGap(x: CGFloat, y: CGFloat, width: CGFloat) -> CGFloat {
        guard let k = downKey, let card = page?.model.issues.first(where: { $0.key == k }) else { return y }
        let h = cardHeight(card, width: width)
        let r = NSRect(x: x, y: y, width: width, height: h)
        fill(r, th.accent.withAlphaComponent(0.08), radius: PageCanvas.radius)
        let dash = NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), xRadius: PageCanvas.radius, yRadius: PageCanvas.radius)
        dash.setLineDash([5, 4], count: 2, phase: 0)
        th.accent.withAlphaComponent(0.6).setStroke()
        if visible(r) { dash.stroke() }
        return y + h + 8
    }

    static let summaryFont = NSFont.systemFont(ofSize: 12.5, weight: .medium)

    func cardHeight(_ i: JiraIssue, width: CGFloat) -> CGFloat {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byWordWrapping
        p.lineSpacing = 2
        let h = (i.summary as NSString).boundingRect(with: NSSize(width: width - 24, height: 200), options: [.usesLineFragmentOrigin],
                                                     attributes: [.font: Self.summaryFont, .paragraphStyle: p]).height
        let lineH = Self.summaryFont.ascender - Self.summaryFont.descender + Self.summaryFont.leading + 2
        let summaryH = min(ceil(h), ceil(lineH * 3))
        return 12 + summaryH + 10 + 22 + (i.parentKey != nil ? 22 : 0) + 10
    }

    func drawCard(_ i: JiraIssue, _ r: NSRect, done: Bool, lifted: Bool = false) {
        guard let page else { return }
        let m = page.model
        let open = m.detail?.key == i.key
        let hot = hover == "card." + i.key && !dragging
        let mineCard = i.assignee?.accountId == m.me?.accountId && m.me != nil
        fill(r, lifted ? th.surface : hot ? th.surface.mix(th.foreground, 0.05) : th.surface, radius: PageCanvas.radius)
        if mineCard, visible(r) {
            // Yours: an accent edge down the left, following the card's corners.
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: r, xRadius: PageCanvas.radius, yRadius: PageCanvas.radius).addClip()
            th.accent.setFill()
            NSRect(x: r.minX, y: r.minY, width: 3, height: r.height).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        stroke(r, open ? th.accent : th.border.withAlphaComponent(hot ? 0.9 : 0.45), radius: PageCanvas.radius, width: open ? 1.5 : 1)
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byWordWrapping
        p.lineSpacing = 2
        let lineH = Self.summaryFont.ascender - Self.summaryFont.descender + Self.summaryFont.leading + 2
        let sh = min(ceil((i.summary as NSString).boundingRect(with: NSSize(width: r.width - 24, height: 200), options: [.usesLineFragmentOrigin],
                                                                attributes: [.font: Self.summaryFont, .paragraphStyle: p]).height), ceil(lineH * 3))
        paragraph(i.summary, Self.summaryFont, done ? th.foreground.withAlphaComponent(0.6) : th.foreground, x: r.minX + 12, y: r.minY + 11,
                  width: r.width - 24, maxLines: 3)
        var y = r.minY + 12 + sh + 8
        if let pk = i.parentKey {
            let label = i.parentSummary ?? pk
            pill(label.count > 28 ? String(label.prefix(27)) + "…" : label, x: r.minX + 12, y: y, height: 18, color: th.ansi[5],
                 font: .systemFont(ofSize: 10, weight: .semibold))
            y += 22
        }
        // Bottom row: type, key, priority, points … assignee.
        IssueGlyph.type(i.type, NSRect(x: r.minX + 12, y: y + 3, width: 16, height: 16), th)
        let kf = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        let kw = PageCanvas.textWidth(i.key, kf)
        text(i.key, kf, done ? th.dimText : th.dimText, x: r.minX + 32, y: y + 3, width: kw + 2)
        if done { fill(NSRect(x: r.minX + 32, y: y + 10, width: kw, height: 1), th.dimText.withAlphaComponent(0.7)) }
        var x = r.minX + 32 + kw + 8
        if let pr = i.priority {
            IssueGlyph.priority(pr, NSRect(x: x, y: y + 3, width: 16, height: 16), th)
            x += 20
        }
        if let sp = i.storyPoints {
            pill(sp == sp.rounded() ? "\(Int(sp))" : String(format: "%.1f", sp), x: x, y: y + 2, height: 18, color: th.foreground,
                 font: .monospacedDigitSystemFont(ofSize: 10, weight: .bold), minWidth: 20)
        }
        let av = NSRect(x: r.maxX - 34, y: y, width: 22, height: 22)
        // A move still on its way to Jira: in the bottom row, so the summary keeps the width the card was measured for.
        if m.pending[i.key] != nil { symbol("arrow.triangle.2.circlepath", NSRect(x: av.minX - 22, y: y + 3, width: 16, height: 16), th.dimText, size: 10) }
        if let a = i.assignee {
            avatar(a.avatarURL.flatMap(URL.init(string:)), av, initials: PageCanvas.initials(a.displayName))
        } else {
            emptyAvatar(av)
        }
        if !dragging && !lifted { hit(r, "card." + i.key) { [weak page] in page?.openIssue(i.key) } }
    }

    // MARK: Dragging

    private func card(at p: NSPoint) -> (key: String, column: Int, rect: NSRect)? { cardRects.last { $0.rect.contains(p) } }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if let c = card(at: p) {
            window?.makeFirstResponder(self)
            downKey = c.key
            downPoint = p
            grabOffset = NSPoint(x: p.x - c.rect.minX, y: p.y - c.rect.minY)
            return
        }
        downKey = nil
        super.mouseDown(with: e)
    }

    override func mouseDragged(with e: NSEvent) {
        guard downKey != nil else { return super.mouseDragged(with: e) }
        let p = convert(e.locationInWindow, from: nil)
        if !dragging {
            guard hypot(p.x - downPoint.x, p.y - downPoint.y) > 4 else { return }
            dragging = true
            NSCursor.closedHand.set()
        }
        dragTo(p)
        startAutoscroll()
    }

    func dragTo(_ p: NSPoint) {
        dragPoint = p
        dropTarget = target(at: p)
        needsDisplay = true
    }

    /// The column under `p` and where among its cards the dragged one would go.
    private func target(at p: NSPoint) -> (column: Int, index: Int)? {
        guard !columnRects.isEmpty else { return nil }
        // The column the pointer's over, or the nearest one beside it.
        let c = columnRects.firstIndex { $0.minX <= p.x && p.x <= $0.maxX + BoardCanvas.gap }
            ?? (p.x < columnRects[0].minX ? 0 : columnRects.count - 1)
        let cards = cardRects.filter { $0.column == c && $0.key != downKey }
        let index = cards.firstIndex { p.y < $0.rect.midY } ?? cards.count
        return (c, index)
    }

    override func mouseUp(with e: NSEvent) {
        autoscroll?.invalidate()
        autoscroll = nil
        guard let key = downKey else { return super.mouseUp(with: e) }
        downKey = nil
        if dragging {
            dragging = false
            NSCursor.arrow.set()
            if let t = dropTarget { page?.model.drop(key, column: t.column, index: t.index) }
            dropTarget = nil
            needsDisplay = true
        } else {
            page?.openIssue(key)
        }
    }

    /// Scrolls when the dragged card nears the view's edge.
    private func startAutoscroll() {
        guard autoscroll == nil else { return }
        autoscroll = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] t in
            guard let self, self.dragging, let clip = self.enclosingScrollView?.contentView else { t.invalidate(); self?.autoscroll = nil; return }
            let vis = clip.documentVisibleRect
            var d = NSPoint.zero
            let edge: CGFloat = 40
            if self.dragPoint.x > vis.maxX - edge { d.x = 12 } else if self.dragPoint.x < vis.minX + edge { d.x = -12 }
            if self.dragPoint.y > vis.maxY - edge { d.y = 12 } else if self.dragPoint.y < vis.minY + edge { d.y = -12 }
            guard d != .zero else { return }
            var o = vis.origin
            o.x = max(0, min(self.bounds.width - vis.width, o.x + d.x))
            o.y = max(0, min(self.bounds.height - vis.height, o.y + d.y))
            guard o != vis.origin else { return }
            clip.scroll(to: o)
            self.enclosingScrollView?.reflectScrolledClipView(clip)
            self.dragTo(NSPoint(x: self.dragPoint.x + (o.x - vis.origin.x), y: self.dragPoint.y + (o.y - vis.origin.y)))
        }
    }

    /// Dev aid: drags `key` to column `c` at `index` as the pointer would, and drops it.
    func devDrag(_ key: String, column c: Int, index: Int, hold: Bool) {
        guard let from = cardRects.first(where: { $0.key == key }), c < columnRects.count else { return }
        downKey = key
        grabOffset = NSPoint(x: 20, y: 10)
        dragging = true
        let cards = cardRects.filter { $0.column == c && $0.key != key }
        let y = index < cards.count ? cards[index].rect.minY + 4 : (cards.last.map { $0.rect.maxY + 10 } ?? columnRects[c].minY + 40)
        _ = from
        dragTo(NSPoint(x: columnRects[c].midX, y: y))
        if !hold {
            dragging = false
            downKey = nil
            if let t = dropTarget { page?.model.drop(key, column: t.column, index: t.index) }
            dropTarget = nil
            needsDisplay = true
        }
    }
}

/// Little pictures for an issue's type and priority, drawn rather than fetched (Jira's own icons need signing in).
enum IssueGlyph {
    static func typeColor(_ type: String, _ th: Theme) -> NSColor {
        switch type.lowercased() {
        case "bug": return NSColor(srgbRed: 0.90, green: 0.29, blue: 0.24, alpha: 1)
        case "story": return NSColor(srgbRed: 0.39, green: 0.73, blue: 0.27, alpha: 1)
        case "epic": return NSColor(srgbRed: 0.55, green: 0.38, blue: 0.85, alpha: 1)
        case "improvement": return NSColor(srgbRed: 0.10, green: 0.70, blue: 0.70, alpha: 1)
        case "sub-task", "subtask": return NSColor(srgbRed: 0.30, green: 0.60, blue: 0.95, alpha: 1)
        default: return NSColor(srgbRed: 0.25, green: 0.55, blue: 0.95, alpha: 1)
        }
    }

    static func typeSymbol(_ type: String) -> String {
        switch type.lowercased() {
        case "bug": return "ladybug.fill"
        case "story": return "bookmark.fill"
        case "epic": return "bolt.fill"
        case "improvement": return "arrow.up"
        case "sub-task", "subtask": return "square.on.square"
        default: return "checkmark"
        }
    }

    static func type(_ type: String, _ r: NSRect, _ th: Theme) {
        let c = typeColor(type, th)
        c.setFill()
        NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
        let cfg = NSImage.SymbolConfiguration(pointSize: r.height * 0.55, weight: .bold).applying(.init(paletteColors: [.white]))
        if let img = NSImage(systemSymbolName: typeSymbol(type), accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
            let s = img.size
            img.draw(in: NSRect(x: r.midX - s.width / 2, y: r.midY - s.height / 2, width: s.width, height: s.height), from: .zero, operation: .sourceOver,
                     fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    static func priorityColor(_ p: String, _ th: Theme) -> NSColor {
        switch p.lowercased() {
        case "highest", "blocker", "critical": return NSColor(srgbRed: 0.85, green: 0.20, blue: 0.20, alpha: 1)
        case "high", "major": return NSColor(srgbRed: 0.95, green: 0.45, blue: 0.25, alpha: 1)
        case "medium": return NSColor(srgbRed: 0.95, green: 0.70, blue: 0.20, alpha: 1)
        case "low", "minor": return NSColor(srgbRed: 0.25, green: 0.60, blue: 0.95, alpha: 1)
        default: return NSColor(srgbRed: 0.35, green: 0.50, blue: 0.85, alpha: 1)
        }
    }

    /// Chevrons: up for high, a bar for medium, down for low.
    static func priority(_ p: String, _ r: NSRect, _ th: Theme) {
        let name: String
        switch p.lowercased() {
        case "highest", "blocker", "critical": name = "chevron.up.2"
        case "high", "major": name = "chevron.up"
        case "medium": name = "equal"
        case "low", "minor": name = "chevron.down"
        default: name = "chevron.down.2"
        }
        let cfg = NSImage.SymbolConfiguration(pointSize: r.height * 0.62, weight: .heavy).applying(.init(paletteColors: [priorityColor(p, th)]))
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else { return }
        let s = img.size
        img.draw(in: NSRect(x: r.midX - s.width / 2, y: r.midY - s.height / 2, width: s.width, height: s.height), from: .zero, operation: .sourceOver,
                 fraction: 1, respectFlipped: true, hints: nil)
    }

    static func statusColor(_ s: JiraStatus, _ th: Theme) -> NSColor {
        switch s.category {
        case "done": return th.green
        case "new": return th.dimText
        default: return th.ansi[4]
        }
    }
}

// MARK: My Issues and Pull Requests

final class AtlassianListCanvas: PageCanvas {
    weak var page: AtlassianPageView?

    override func render() -> CGFloat {
        guard let page else { return 0 }
        let width = bounds.width
        switch page.section {
        case .mine: return renderMine(page.model, width: width)
        case .prs: return renderPRs(page.model, width: width)
        case .board: return 0
        }
    }

    private func sectionTitle(_ t: String, _ count: Int?, x: CGFloat, y: CGFloat, width: CGFloat) {
        text(t.uppercased(), .systemFont(ofSize: 10.5, weight: .bold), th.dimText, x: x, y: y, width: width)
        if let count { text("\(count)", .monospacedDigitSystemFont(ofSize: 10.5, weight: .medium), th.dimText.withAlphaComponent(0.7), x: x, y: y, width: width, align: .right) }
    }

    private func message(_ s: String, error: Bool, y: CGFloat, width: CGFloat) -> CGFloat {
        symbol(error ? "exclamationmark.triangle" : "info.circle", NSRect(x: 24, y: y, width: 16, height: 18), error ? th.red : th.dimText, size: 12)
        return paragraph(s, .systemFont(ofSize: 12.5), error ? th.red : th.dimText, x: 48, y: y, width: width - 72) + 12
    }

    private func renderMine(_ m: AtlassianModel, width: CGFloat) -> CGFloat {
        let pad: CGFloat = 14
        var y: CGFloat = 12
        if let e = m.mineError { y += message(e, error: true, y: y, width: width) }
        let shown = m.mine.filter(m.matches)
        // Grouped by status, in workflow order (to do, then in progress).
        let groups = Dictionary(grouping: shown, by: { $0.status.name })
        let order = shown.sorted { a, b in
            let ra = a.status.category == "indeterminate" ? 0 : 1, rb = b.status.category == "indeterminate" ? 0 : 1
            return ra != rb ? ra < rb : a.status.name < b.status.name
        }.map(\.status.name)
        var seen = Set<String>()
        for name in order where seen.insert(name).inserted {
            let list = groups[name] ?? []
            sectionTitle(name, list.count, x: pad, y: y, width: width - pad * 2)
            y += 22
            for i in list { y = row(i, m, x: pad, y: y, width: width - pad * 2) + 6 }
            y += 14
        }
        if shown.isEmpty && m.mineError == nil {
            y += message(m.loadingMine ? "Loading your issues…" : "Nothing assigned to you that's open. 🎉", error: false, y: y, width: width)
        }
        if !m.recent.isEmpty {
            sectionTitle("Recently viewed", m.recent.count, x: pad, y: y, width: width - pad * 2)
            y += 22
            for i in m.recent.filter(m.matches) { y = row(i, m, x: pad, y: y, width: width - pad * 2) + 6 }
        }
        return y + 24
    }

    /// A ticket in a list: type, key, summary, status, priority, assignee, when it changed.
    private func row(_ i: JiraIssue, _ m: AtlassianModel, x: CGFloat, y: CGFloat, width: CGFloat) -> CGFloat {
        let r = NSRect(x: x, y: y, width: width, height: 46)
        let open = m.detail?.key == i.key
        fill(r, open ? th.accent.withAlphaComponent(0.12) : hover == "row." + i.key ? th.foreground.withAlphaComponent(0.07) : th.surface.withAlphaComponent(0.6), radius: PageCanvas.radius)
        stroke(r, open ? th.accent.withAlphaComponent(0.55) : th.border.withAlphaComponent(0.35), radius: PageCanvas.radius)
        let mid = r.midY
        IssueGlyph.type(i.type, NSRect(x: x + 14, y: mid - 8, width: 16, height: 16), th)
        let kf = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .semibold)
        text(i.key, kf, th.dimText, x: x + 40, y: mid - 8, width: 76)
        // Right to left: who, when, priority, status; the summary takes what's left.
        var rx = r.maxX - 14
        let av = NSRect(x: rx - 24, y: mid - 12, width: 24, height: 24)
        if let a = i.assignee { avatar(a.avatarURL.flatMap(URL.init(string:)), av, initials: PageCanvas.initials(a.displayName)) } else { emptyAvatar(av) }
        rx = av.minX - 12
        let small = NSFont.systemFont(ofSize: 11.5)
        if let u = i.updated { text(PageCanvas.ago(u), small, th.dimText, x: rx - 64, y: mid - 8, width: 64, align: .right) }
        rx -= 64 + 14
        if let p = i.priority { IssueGlyph.priority(p, NSRect(x: rx - 16, y: mid - 8, width: 16, height: 16), th) }
        rx -= 16 + 12
        let sw = pill(i.status.name.uppercased(), x: rx, y: mid - 9, color: IssueGlyph.statusColor(i.status, th), rightAligned: true)
        let sx = x + 122
        text(i.summary, .systemFont(ofSize: 13, weight: .medium), th.foreground, x: sx, y: mid - 9, width: max(40, rx - sw - 16 - sx))
        hit(r, "row." + i.key) { [weak page] in page?.openIssue(i.key) }
        return r.maxY
    }

    private func renderPRs(_ m: AtlassianModel, width: CGFloat) -> CGFloat {
        let pad: CGFloat = 14
        var y: CGFloat = 12
        guard m.repo != nil else {
            let folder = page?.tabFolder
            let msg = folder == nil
                ? "This tab isn't in a folder on this Mac. Pull requests are shown for the repository of the tab the page is in: cd into one, or open the page from a tab that's in one."
                : m.repoRoot == nil
                    ? "\((folder! as NSString).abbreviatingWithTildeInPath) isn't in a git repository. cd into one in this tab's terminal, then refresh."
                    : "This repository's origin isn't on Bitbucket Cloud (bitbucket.org)."
            return y + message(msg, error: false, y: y, width: width) + 20
        }
        if let e = m.prError { y += message(e, error: true, y: y, width: width) }
        // Your branch, when it has no pull request yet.
        if let b = m.branch, !m.prs.contains(where: { $0.source == b }), m.prError == nil, !m.loadingPRs, !["main", "master", "develop", "qa", "staging"].contains(b.lowercased()) {
            let r = NSRect(x: pad, y: y, width: width - pad * 2, height: 46)
            fill(r, th.accent.withAlphaComponent(0.10), radius: PageCanvas.radius)
            stroke(r, th.accent.withAlphaComponent(0.35), radius: PageCanvas.radius)
            symbol("arrow.triangle.branch", NSRect(x: r.minX + 12, y: r.minY, width: 18, height: 46), th.accent, size: 13)
            text("You're on \(b)", .systemFont(ofSize: 12.5, weight: .semibold), th.foreground, x: r.minX + 38, y: r.minY + 8, width: r.width - 220)
            text("No pull request for it yet.", .systemFont(ofSize: 11.5), th.dimText, x: r.minX + 38, y: r.minY + 25, width: r.width - 220)
            button("Create pull request", id: "branchpr", x: r.maxX - 10, y: r.minY + 9, height: 28, symbol: "plus", style: .primary, rightAligned: true) { [weak page] in
                guard let page else { return }
                AtlassianSheet.createPR(on: page)
            }
            y = r.maxY + 18
        }
        let list = m.shownPRs
        sectionTitle(m.prFilter == "mine" ? "Your pull requests" : m.prFilter == "review" ? "Waiting on your review" : "Open pull requests", list.count,
                     x: pad, y: y, width: width - pad * 2)
        y += 22
        if list.isEmpty && m.prError == nil {
            y += message(m.loadingPRs ? "Loading pull requests…" : "None.", error: false, y: y, width: width)
        }
        for p in list { y = prRow(p, m, x: pad, y: y, width: width - pad * 2) + 8 }
        return y + 24
    }

    private func prRow(_ p: BitbucketPullRequest, _ m: AtlassianModel, x: CGFloat, y: CGFloat, width: CGFloat) -> CGFloat {
        let r = NSRect(x: x, y: y, width: width, height: 62)
        fill(r, hover == "pr.\(p.id)" ? th.foreground.withAlphaComponent(0.07) : th.surface.withAlphaComponent(0.6), radius: PageCanvas.radius)
        stroke(r, th.border.withAlphaComponent(0.35), radius: PageCanvas.radius)
        if let a = p.author { avatar(a.avatarURL.flatMap(URL.init(string:)), NSRect(x: x + 14, y: r.midY - 17, width: 34, height: 34), initials: PageCanvas.initials(a.displayName)) }
        // Right, centered on the row: reviewers' faces, approvals, changes asked for, comments.
        let mid = r.midY
        var rx = r.maxX - 16
        let cf = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        if p.comments > 0 {
            let cw = PageCanvas.textWidth("\(p.comments)", cf)
            text("\(p.comments)", cf, th.dimText, x: rx - cw, y: mid - 8, width: cw)
            symbol("bubble.left", NSRect(x: rx - cw - 20, y: mid - 9, width: 16, height: 18), th.dimText, size: 11)
            rx -= cw + 32
        }
        if p.changesRequested { rx -= pill("Changes requested", x: rx, y: mid - 9, color: th.yellow, rightAligned: true) + 8 }
        if p.approvals > 0 { rx -= pill("✓ \(p.approvals)", x: rx, y: mid - 9, color: th.green, rightAligned: true) + 8 }
        let reviewers = p.participants.filter(\.isReviewer).prefix(4)
        for (n, part) in reviewers.enumerated() {
            let ar = NSRect(x: rx - 24 - CGFloat(n) * 18, y: mid - 12, width: 24, height: 24)
            avatar(part.user.avatarURL.flatMap(URL.init(string:)), ar, initials: PageCanvas.initials(part.user.displayName))
            if part.approved { stroke(ar.insetBy(dx: -1.5, dy: -1.5), th.green, radius: 13.5, width: 2) }
        }
        if !reviewers.isEmpty { rx -= 24 + CGFloat(reviewers.count - 1) * 18 + 8 }
        // Left: the ticket, the title (without the ticket's key again in front), and where it goes.
        let tx = x + 62
        var kx = tx
        var title = p.title
        if let k = p.issueKey {
            kx += pill(k, x: kx, y: y + 11, height: 18, color: th.accent, font: .monospacedSystemFont(ofSize: 10, weight: .bold)) + 8
            if title.uppercased().hasPrefix(k) {
                title = String(title.dropFirst(k.count)).trimmingCharacters(in: CharacterSet(charactersIn: " :-–—"))
            }
        }
        text(title, .systemFont(ofSize: 13, weight: .semibold), th.foreground, x: kx, y: y + 11, width: max(60, rx - kx - 12))
        let sub = "#\(p.id) · \(p.author?.displayName ?? "") · \(p.source) → \(p.destination)" + (p.updated.map { " · " + PageCanvas.ago($0) } ?? "")
        text(sub, .systemFont(ofSize: 11.5), th.dimText, x: tx, y: y + 35, width: max(60, rx - tx - 12))
        hit(r, "pr.\(p.id)") { [weak page] in page?.openPR(p.id) }
        return r.maxY
    }
}

// MARK: Toast

final class ToastView: NSView {
    var message: (String, Bool)? { didSet { isHidden = message == nil; needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let (text, ok) = message else { return }
        let th = Config.shared.theme
        let font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        let w = min(bounds.width, PageCanvas.textWidth(text, font) + 50)
        let r = NSRect(x: 0, y: 0, width: w, height: bounds.height)
        th.surface.mix(th.foreground, 0.06).setFill()
        NSBezierPath(roundedRect: r, xRadius: PageCanvas.radius, yRadius: PageCanvas.radius).fill()
        (ok ? th.green : th.red).withAlphaComponent(0.6).setStroke()
        NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: PageCanvas.radius, yRadius: PageCanvas.radius).stroke()
        let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold).applying(.init(paletteColors: [ok ? th.green : th.red]))
        NSImage(systemSymbolName: ok ? "checkmark.circle" : "exclamationmark.triangle", accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)?.draw(in: NSRect(x: 12, y: (bounds.height - 14) / 2, width: 14, height: 14), from: .zero, operation: .sourceOver,
                                                fraction: 1, respectFlipped: true, hints: nil)
        (text as NSString).draw(with: NSRect(x: 34, y: (bounds.height - 16) / 2, width: w - 44, height: 18), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                attributes: [.font: font, .foregroundColor: th.foreground])
    }
}

// MARK: Connecting

final class AtlassianSetupView: NSView {
    weak var model: AtlassianModel?
    let site = ThemedField("", placeholder: "yourcompany.atlassian.net", mono: false)
    let email = ThemedField("", placeholder: "you@company.com", mono: false)
    let jira = AtlassianSecureField()
    let bitbucket = AtlassianSecureField()
    let canvas = AtlassianSetupCanvas()
    /// Scrolls the card when the page is shorter than it.
    private let scroll = NSScrollView()
    private let doc = FlippedView()
    var firstField: NSView { site.stringValue.isEmpty ? site : jira }

    override init(frame: NSRect) {
        super.init(frame: frame)
        canvas.setup = self
        for f in [site, email] { f.layer?.cornerRadius = PageCanvas.radius }
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = doc
        addSubview(scroll)
        doc.addSubview(canvas)
        for f in [site, email, jira, bitbucket] as [NSTextField] { doc.addSubview(f) }
        jira.placeholderString = "Jira API token"
        bitbucket.placeholderString = "Bitbucket API token (optional, for pull requests)"
        bitbucket.target = self
        bitbucket.action = #selector(connect)
        let s = AtlassianClient.shared.settings
        site.stringValue = s.site
        email.stringValue = s.email
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    func applyTheme() {
        let th = Config.shared.theme
        for f in [site, email, jira, bitbucket] as [NSTextField] {
            f.textColor = th.foreground
            f.layer?.backgroundColor = th.background.withAlphaComponent(0.6).cgColor
        }
        canvas.needsDisplay = true
    }

    @objc func connect() {
        model?.connect(site: site.stringValue, email: email.stringValue, jiraToken: jira.stringValue, bitbucketToken: bitbucket.stringValue)
    }

    /// The card, in the scrolled document's coordinates.
    var cardRect: NSRect {
        let w = min(560, doc.bounds.width - 40)
        return NSRect(x: (doc.bounds.width - w) / 2, y: max(20, min(bounds.height * 0.08, 60)), width: w, height: 530)
    }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        let width = scroll.contentSize.width
        doc.frame = NSRect(x: 0, y: 0, width: width, height: 0)
        doc.frame.size.height = max(scroll.contentSize.height, cardRect.maxY + 30)
        canvas.frame = doc.bounds
        let c = cardRect
        let fx = c.minX + 28, fw = c.width - 56
        site.frame = NSRect(x: fx, y: c.minY + 186, width: fw, height: 30)
        email.frame = NSRect(x: fx, y: c.minY + 244, width: fw, height: 30)
        jira.frame = NSRect(x: fx, y: c.minY + 302, width: fw, height: 30)
        bitbucket.frame = NSRect(x: fx, y: c.minY + 360, width: fw, height: 30)
        canvas.needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {}

    /// Dev aid: scrolls the card `y` points down (as far as it goes).
    func devScroll(_ y: CGFloat) {
        let maxY = max(0, doc.frame.height - scroll.contentSize.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: min(maxY, y)))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}

/// A flipped plain view, to hold subviews top-down in a scroll view.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// The secure field's cell, centered and padded as the themed fields' are.
final class CenteredSecureCell: NSSecureTextFieldCell {
    override func setUpFieldEditorAttributes(_ textObj: NSText) -> NSText {
        let t = super.setUpFieldEditorAttributes(textObj)
        t.drawsBackground = false
        (t as? NSTextView)?.backgroundColor = .clear
        return t
    }

    override func titleRect(forBounds r: NSRect) -> NSRect {
        let inner = r.insetBy(dx: 5.5, dy: 0)
        let h = min(inner.height, cellSize(forBounds: inner).height)
        return NSRect(x: inner.minX, y: inner.minY + ((inner.height - h) / 2).rounded(), width: inner.width, height: h)
    }

    override func drawInterior(withFrame frame: NSRect, in view: NSView) { super.drawInterior(withFrame: titleRect(forBounds: frame), in: view) }

    override func edit(withFrame r: NSRect, in v: NSView, editor: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: titleRect(forBounds: r), in: v, editor: editor, delegate: delegate, event: event)
    }

    override func select(withFrame r: NSRect, in v: NSView, editor: NSText, delegate: Any?, start: Int, length: Int) {
        super.select(withFrame: titleRect(forBounds: r), in: v, editor: editor, delegate: delegate, start: start, length: length)
    }
}

/// A password field in the themed fields' look.
final class AtlassianSecureField: NSSecureTextField {
    override class var cellClass: AnyClass? {
        get { CenteredSecureCell.self }
        set {}
    }

    override var placeholderString: String? {
        didSet {
            placeholderAttributedString = NSAttributedString(string: placeholderString ?? "", attributes: [
                .foregroundColor: Config.shared.theme.dimText.withAlphaComponent(0.6), .font: NSFont.systemFont(ofSize: 13)])
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        let th = Config.shared.theme
        font = .systemFont(ofSize: 13)
        textColor = th.foreground
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = PageCanvas.radius
        layer?.borderWidth = 1
        layer?.borderColor = th.border.cgColor
        layer?.backgroundColor = th.background.withAlphaComponent(0.6).cgColor
        cell?.isScrollable = true
    }

    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }

    override func setFrameSize(_ s: NSSize) {
        super.setFrameSize(s)
        recenterEditor()
    }
}

final class AtlassianSetupCanvas: PageCanvas {
    weak var setup: AtlassianSetupView?

    override func render() -> CGFloat {
        guard let setup else { return 0 }
        let c = setup.cardRect
        fill(c, th.surface.withAlphaComponent(0.75), radius: PageCanvas.radius)
        stroke(c, th.border, radius: PageCanvas.radius)
        let icon = NSRect(x: c.minX + 28, y: c.minY + 28, width: 52, height: 52)
        if visible(icon) { AtlassianExtension.drawIcon(icon) }
        text("Connect Jira & Bitbucket", .systemFont(ofSize: 20, weight: .bold), th.foreground, x: icon.maxX + 16, y: c.minY + 32, width: c.width - 120)
        text("Your board and pull requests, beside Claude Code", .systemFont(ofSize: 12.5), th.dimText, x: icon.maxX + 16, y: c.minY + 58, width: c.width - 120)
        paragraph("Solanum signs in with API tokens, kept in a file only your account can read. Make them at id.atlassian.com › Security › API tokens: a classic token for Jira, and one with Bitbucket scopes (read and write for repositories and pull requests) for Bitbucket.",
                  .systemFont(ofSize: 12), th.foreground.withAlphaComponent(0.85), x: c.minX + 28, y: c.minY + 96, width: c.width - 56)
        for (label, y) in [("Jira site", 168.0), ("Atlassian account email", 226.0), ("Jira API token", 284.0), ("Bitbucket API token", 342.0)] {
            text(label.uppercased(), .systemFont(ofSize: 10, weight: .bold), th.dimText, x: c.minX + 28, y: c.minY + CGFloat(y), width: 300)
        }
        if setup.model?.api.hasCredentials(.jira) == false, AtlassianTokens.get(.jira) != nil {
            text("A token is saved; leave it blank to keep it.", .systemFont(ofSize: 10.5), th.dimText, x: c.minX + 28, y: c.minY + 284, width: c.width - 56, align: .right)
        }
        let model = setup.model
        let busy = model?.connecting == true
        button(busy ? "Connecting…" : "Connect", id: "connect", x: c.maxX - 28, y: c.minY + 410, height: 32, style: .primary, rightAligned: true, enabled: !busy) { [weak setup] in
            setup?.connect()
        }
        button("Make a token", id: "tokens", x: c.minX + 28, y: c.minY + 410, height: 32, symbol: "key", style: .secondary) {
            if let u = URL(string: "https://id.atlassian.com/manage-profile/security/api-tokens") { NSWorkspace.shared.open(u) }
        }
        if let e = model?.connectError {
            symbol("exclamationmark.triangle", NSRect(x: c.minX + 28, y: c.minY + 458, width: 16, height: 16), th.red, size: 11)
            paragraph(e, .systemFont(ofSize: 12), th.red, x: c.minX + 50, y: c.minY + 458, width: c.width - 78, maxLines: 3)
        } else {
            paragraph("Only this Mac sees the tokens: Solanum sends them to Atlassian's servers and nowhere else.", .systemFont(ofSize: 11.5), th.dimText,
                      x: c.minX + 28, y: c.minY + 460, width: c.width - 56)
        }
        return bounds.height
    }
}
