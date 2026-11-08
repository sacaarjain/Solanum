import AppKit

// "Show Git Graph" (top of the status bar's branch picker, or the command palette): the repository's history as
// a graph, as VS Code's Git Graph draws it. Each line of development gets a lane in its own color, with curves
// where branches split off and merge back, and branch and tag labels beside the commits. Clicking a commit shows
// a card with its author, date, full message and size, and buttons to see its changes or copy its hash or message.
// Double-clicking a commit goes straight to its changes.

/// The graph, plus the card shown over it for the commit last clicked.
final class GitGraphView: NSView {
    private let scroll = NSScrollView()
    private let rowsView = GraphRowsView()
    private let card = CommitCard()
    private let toolbar = GraphToolbar()
    private let branchList = GraphBranchList()
    private let empty = NSTextField(labelWithString: "")
    private let runner: GitRunner
    private var details: [String: CommitCard.Details] = [:]
    private var cardRow: Int?
    private var scrollObserver: NSObjectProtocol?
    /// What's shown: every branch, or what the filters leave.
    private(set) var filter = GraphFilter()
    private var loadID = 0
    /// A commit's "View Changes", or a double-click on it.
    var onViewChanges: ((String) -> Void)?
    /// After each load: how many commits, or why there are none.
    var onLoaded: ((_ count: Int, _ filter: GraphFilter) -> Void)?
    var onFailed: ((String) -> Void)?
    /// Authors (most commits first) and the repository's folders and files, read once when a menu needs them.
    private var authors: [String]?
    private var me: String?
    private var paths: [String]?
    private static let listWidth: CGFloat = 230

    init(runner: GitRunner) {
        self.runner = runner
        super.init(frame: .zero)
        scroll.documentView = rowsView
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        addSubview(branchList)
        addSubview(toolbar)
        addSubview(scroll)
        empty.alignment = .center
        empty.isHidden = true
        addSubview(empty)
        card.isHidden = true
        addSubview(card)
        toolbar.onChange = { [weak self] f in self?.apply(f) }
        toolbar.onRefresh = { [weak self] in self?.reload(refreshLists: true) }
        toolbar.onBranchMenu = { [weak self] b in self?.showBranchMenu(b) }
        toolbar.onUserMenu = { [weak self] b in self?.showUserMenu(b) }
        toolbar.onPathMenu = { [weak self] b in self?.showPathPicker(b) }
        branchList.onPick = { [weak self] name in self?.toolbar.pick(branch: name) }
        // A click on a commit opens its card; on the same commit again, or anywhere else, closes it.
        rowsView.onClick = { [weak self] row in
            guard let self else { return }
            // Focus here, so Escape reaches keyDown and closes the card.
            self.window?.makeFirstResponder(self)
            if let row, row != self.cardRow { self.showCard(row) } else { self.hideCard() }
        }
        rowsView.onDoubleClick = { [weak self] row in
            guard let self, self.rowsView.rows.indices.contains(row) else { return }
            self.hideCard()
            self.onViewChanges?(self.rowsView.rows[row].commit.hash)
        }
        card.onViewChanges = { [weak self] hash in
            self?.hideCard()
            self?.onViewChanges?(hash)
        }
        // The card stays by the row it was opened for, so scrolling puts it away.
        scroll.contentView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView,
                                                                queue: .main) { [weak self] _ in
            if self?.cardRow != nil { self?.hideCard() }
        }
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { scrollObserver.map(NotificationCenter.default.removeObserver) }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, cardRow != nil { hideCard() } else { super.keyDown(with: event) }
    }

    override var isFlipped: Bool { true }
    /// Takes focus so ⌘W and the other editor commands reach the editor around it.
    override var acceptsFirstResponder: Bool { true }

    /// ⌘F: the Text or hash field.
    func focusSearch() { toolbar.focusSearch() }

    private func apply(_ f: GraphFilter) {
        filter = f
        branchList.selected = f.branch
        hideCard()
        reload(refreshLists: false)
    }

    /// Reads the history for the filters (and the branch list with it, or when asked).
    func reload(refreshLists: Bool = true) {
        loadID += 1
        let id = loadID, filter = filter
        if refreshLists || branchList.refs.locals.isEmpty {
            runner.run(GraphRefs.script, timeout: 30) { [weak self] status, out, _ in
                guard let self, status == 0 else { return }
                self.branchList.refs = GraphRefs.parse(out)
                self.branchList.selected = self.filter.branch
            }
            if refreshLists { authors = nil; paths = nil }
        }
        runner.run(filter.script(), timeout: 60) { [weak self] status, out, err in
            guard let self, id == self.loadID else { return }
            let (log, topology) = GraphFilter.split(out)
            let (head, commits) = GraphCommit.parse(log)
            if commits.isEmpty, status != 0, filter.isEmpty {
                self.onFailed?(err.isEmpty ? "Couldn't read the history." : err)
                return
            }
            self.show(head: head, commits: filter.arrange(commits, topology: topology))
            self.empty.stringValue = filter.isEmpty ? "No commits yet." : "No commits match these filters."
            self.empty.isHidden = !commits.isEmpty
            self.onLoaded?(commits.count, filter)
        }
    }

    func show(head: String, commits: [GraphCommit]) {
        rowsView.head = head
        rowsView.rows = GraphLayout.rows(commits)
        rowsView.fitSize()
        if let row = cardRow, !rowsView.rows.indices.contains(row) { hideCard() }
    }

    func applyTheme() {
        rowsView.needsDisplay = true
        card.applyTheme()
        toolbar.applyTheme()
        branchList.applyTheme()
        empty.textColor = Config.shared.theme.dimText
        empty.font = .systemFont(ofSize: 12.5)
    }

    override func layout() {
        super.layout()
        // The branch list gives way on a narrow editor.
        let list = bounds.width >= 640 ? Self.listWidth : 0
        branchList.isHidden = list == 0
        branchList.frame = NSRect(x: 0, y: 0, width: list, height: bounds.height)
        toolbar.frame = NSRect(x: list, y: 0, width: bounds.width - list, height: GraphToolbar.height)
        scroll.frame = NSRect(x: list, y: GraphToolbar.height, width: bounds.width - list, height: bounds.height - GraphToolbar.height)
        empty.frame = NSRect(x: list + 20, y: GraphToolbar.height + 40, width: max(0, bounds.width - list - 40), height: 20)
        rowsView.fitSize()
    }

    // MARK: Filter menus

    private func showBranchMenu(_ anchor: NSView) {
        let refs = branchList.refs
        var items: [DropdownItem] = [
            .item("All Branches", checked: filter.branch == nil) { [weak self] in self?.toolbar.pick(branch: nil) },
            .item("HEAD" + (refs.current.map { " (\($0))" } ?? ""), checked: filter.branch == "HEAD") { [weak self] in self?.toolbar.pick(branch: "HEAD") },
        ]
        func section(_ title: String, _ names: [String]) {
            guard !names.isEmpty else { return }
            items += [.separator, .header(title)]
            items += names.map { name in .item(name, checked: filter.branch == name) { [weak self] in self?.toolbar.pick(branch: name) } }
        }
        section("Local", refs.locals)
        section("Remote", refs.remotes)
        section("Tags", refs.tags)
        ThemedDropdown.show(items, under: anchor, minWidth: 240)
    }

    private func showUserMenu(_ anchor: NSView) {
        guard let authors else {
            runner.run("git config user.name; printf '\\036'; git log --all -n 5000 --format=%an | sort | uniq -c | sort -rn | head -40", timeout: 30) { [weak self] _, out, _ in
                guard let self else { return }
                let parts = String(decoding: out, as: UTF8.self).components(separatedBy: "\u{1e}")
                let me = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                self.me = me.isEmpty ? nil : me
                self.authors = (parts.count > 1 ? parts[1] : "").split(separator: "\n").compactMap { line in
                    let t = line.trimmingCharacters(in: .whitespaces)
                    guard let space = t.firstIndex(of: " ") else { return nil }
                    return String(t[t.index(after: space)...])
                }
                self.showUserMenu(anchor)
            }
            return
        }
        var items: [DropdownItem] = [.item("All Users", checked: filter.user == nil) { [weak self] in self?.toolbar.pick(user: nil) }]
        if let me {
            items.append(.item("Me (\(me))", checked: filter.user == me) { [weak self] in self?.toolbar.pick(user: me) })
        }
        items.append(.separator)
        items += authors.filter { $0 != me }.map { name in .item(name, checked: filter.user == name) { [weak self] in self?.toolbar.pick(user: name) } }
        ThemedDropdown.show(items, under: anchor)
    }

    /// The repository's folders and files (as HEAD has them) in a dropdown under Paths, with a field to narrow them.
    private func showPathPicker(_ anchor: NSView) {
        guard let paths else {
            runner.run("git ls-tree -r -t --name-only HEAD | head -50000", timeout: 30) { [weak self] _, out, _ in
                guard let self else { return }
                let all = String(decoding: out, as: UTF8.self).split(separator: "\n").map(String.init)
                // Folders first, shallowest first, then files.
                self.paths = all.sorted { a, b in
                    let da = a.split(separator: "/").count, db = b.split(separator: "/").count
                    return da != db ? da < db : a < b
                }
                self.showPathPicker(anchor)
            }
            return
        }
        if Headless.active {
            FileHandle.standardError.write("graph paths: \(paths.count), first \(paths.prefix(5))\n".data(using: .utf8)!)
        }
        var items: [DropdownItem] = [.item("All Paths", checked: filter.path == nil) { [weak self] in self?.toolbar.pick(path: nil) }, .separator]
        items += paths.map { p in .item(p, checked: filter.path == p) { [weak self] in self?.toolbar.pick(path: p) } }
        ThemedDropdown.show(items, under: anchor, minWidth: 360, placeholder: "Folder or file")
    }

    var devToolbar: GraphToolbar { toolbar }
    var devBranchList: GraphBranchList { branchList }
    var devRowCount: Int { rowsView.rows.count }

    // MARK: Commit card

    func devHover(_ row: Int) { showCard(row) }
    func devViewChanges(_ row: Int) { rowsView.onDoubleClick?(row) }

    private func hideCard() {
        card.isHidden = true
        cardRow = nil
        rowsView.selected = nil
    }

    private func showCard(_ row: Int) {
        guard rowsView.rows.indices.contains(row) else { return }
        let commit = rowsView.rows[row].commit
        cardRow = row
        rowsView.selected = row
        card.set(commit, details: details[commit.hash])
        placeCard(row)
        card.isHidden = false
        guard details[commit.hash] == nil else { return }
        // The full message, and the size of the change (against the first parent, for a merge).
        let q = shellQuote(commit.hash)
        runner.run("git show --no-patch --format=%B%x00 \(q); git show --diff-merges=first-parent --shortstat --format= \(q)") { [weak self] _, out, _ in
            guard let self else { return }
            let parts = String(decoding: out, as: UTF8.self).components(separatedBy: "\0")
            let info = CommitCard.Details(message: parts[0].trimmingCharacters(in: .whitespacesAndNewlines),
                                          stats: parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : "")
            self.details[commit.hash] = info
            if self.cardRow == row {
                self.card.set(commit, details: info)
                self.placeCard(row)
            }
        }
    }

    /// Just below the row, against the right edge so the messages stay readable (above the row when there's no room below).
    private func placeCard(_ row: Int) {
        let size = card.fittingSize(width: min(460, bounds.width - 24))
        let rowRect = convert(rowsView.rect(ofRow: row), from: rowsView)
        let x = max(12, bounds.width - size.width - 56)
        var y = rowRect.maxY + 2
        if y + size.height > bounds.height - 8 { y = max(8, rowRect.minY - size.height - 2) }
        card.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
    }
}

final class GraphRowsView: NSView {
    var rows: [GraphRow] = [] { didSet { needsDisplay = true } }
    var head = ""
    /// The row under the pointer, and the one whose card is open; only their rows are redrawn when they change.
    private var hovered: Int? { didSet { if hovered != oldValue { redraw(oldValue, hovered) } } }
    var selected: Int? { didSet { if selected != oldValue { redraw(oldValue, selected) } } }
    var onClick: ((Int?) -> Void)?
    var onDoubleClick: ((Int) -> Void)?

    static let rowHeight: CGFloat = 24
    private static let laneWidth: CGFloat = 14
    private static let left: CGFloat = 16
    private static let palette: [NSColor] = ["#4C9DF3", "#E5B62C", "#E0457B", "#3FB5A6", "#B06CF0", "#E8853A", "#6CC04A", "#E05555"]
        .map { NSColor(hex: $0) }
    private let font = NSFont.systemFont(ofSize: 12.5)
    private let boldFont = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
    private let pillFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    /// Label icons by name and color, made once rather than on every draw.
    private var symbols: [String: NSImage] = [:]

    override var isFlipped: Bool { true }

    /// Resizing redraws it; otherwise nothing changed and nothing needs drawing.
    func fitSize() {
        let size = NSSize(width: enclosingScrollView?.contentSize.width ?? 0, height: CGFloat(rows.count) * Self.rowHeight + 8)
        if size != frame.size { setFrameSize(size) }
    }

    private func redraw(_ rows: Int?...) {
        for r in rows.compactMap({ $0 }) { setNeedsDisplay(rect(ofRow: r)) }
    }

    static func color(_ i: Int) -> NSColor { palette[i % palette.count] }
    private func x(_ lane: Int) -> CGFloat { Self.left + CGFloat(lane) * Self.laneWidth }
    func rect(ofRow r: Int) -> NSRect { NSRect(x: 0, y: CGFloat(r) * Self.rowHeight, width: bounds.width, height: Self.rowHeight) }
    func textX(_ r: Int) -> CGFloat { x(rows[r].width) + 2 }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === self }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    private func row(at e: NSEvent) -> Int? {
        let r = Int(convert(e.locationInWindow, from: nil).y / Self.rowHeight)
        return rows.indices.contains(r) ? r : nil
    }

    override func mouseMoved(with e: NSEvent) { hovered = row(at: e) }
    override func mouseExited(with e: NSEvent) { hovered = nil }
    override func mouseDown(with e: NSEvent) {
        if e.clickCount == 2, let r = row(at: e) { onDoubleClick?(r) } else { onClick?(row(at: e)) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !rows.isEmpty else { return }
        let th = Config.shared.theme
        let h = Self.rowHeight
        let first = max(0, Int(dirtyRect.minY / h))
        let last = min(rows.count - 1, Int(dirtyRect.maxY / h))
        guard first <= last else { return }
        for r in first...last {
            let row = rows[r]
            let y = CGFloat(r) * h
            let mid = y + h / 2
            let isHead = row.commit.hash == head
            if r == hovered || r == selected || isHead {
                th.foreground.withAlphaComponent(r == selected ? 0.1 : r == hovered ? 0.07 : 0.04).setFill()
                NSRect(x: 0, y: y, width: bounds.width, height: h).fill()
            }
            // The lines, then the commit's dot over them.
            for (segment, color) in row.segments {
                let path = NSBezierPath()
                path.lineWidth = 1.6
                path.lineCapStyle = .round
                switch segment {
                case .through(let i):
                    path.move(to: NSPoint(x: x(i), y: y))
                    path.line(to: NSPoint(x: x(i), y: y + h))
                case .top(let from, let to):
                    path.move(to: NSPoint(x: x(from), y: y))
                    if from == to {
                        path.line(to: NSPoint(x: x(to), y: mid))
                    } else {
                        path.curve(to: NSPoint(x: x(to), y: mid), controlPoint1: NSPoint(x: x(from), y: mid), controlPoint2: NSPoint(x: x(from), y: mid))
                    }
                case .bottom(let from, let to):
                    path.move(to: NSPoint(x: x(from), y: mid))
                    if from == to {
                        path.line(to: NSPoint(x: x(to), y: y + h))
                    } else {
                        path.curve(to: NSPoint(x: x(to), y: y + h), controlPoint1: NSPoint(x: x(to), y: mid), controlPoint2: NSPoint(x: x(to), y: mid))
                    }
                }
                Self.color(color).setStroke()
                path.stroke()
            }
            drawNode(row, at: NSPoint(x: x(row.lane), y: mid), isHead: isHead, th: th)
            drawText(row, row: r, y: y, isHead: isHead, th: th)
        }
    }

    /// A dot for a commit, a ringed dot for a merge, a ring for HEAD (as VS Code marks them).
    private func drawNode(_ row: GraphRow, at c: NSPoint, isHead: Bool, th: Theme) {
        let color = Self.color(row.color)
        func circle(_ r: CGFloat) -> NSBezierPath { NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)) }
        if isHead || row.commit.parents.count > 1 {
            let r: CGFloat = isHead ? 6 : 4.5
            th.background.setFill()
            circle(r).fill()
            color.setStroke()
            let ring = circle(r)
            ring.lineWidth = isHead ? 2.2 : 1.6
            ring.stroke()
            if !isHead {
                color.setFill()
                circle(1.8).fill()
            }
        } else {
            color.setFill()
            circle(4).fill()
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    /// Columns from the right, as IntelliJ's log has them: the date, then the author (each dropped when the view is
    /// too narrow for them and a readable subject).
    private var columns: (author: CGFloat, date: CGFloat) {
        let w = bounds.width
        return (w >= 620 ? 140 : 0, w >= 480 ? 140 : 0)
    }

    /// The subject with its branch and tag labels, then the author and date in their columns; the subject gives way
    /// when space runs short.
    private func drawText(_ row: GraphRow, row r: Int, y: CGFloat, isHead: Bool, th: Theme) {
        let x0 = textX(r)
        let cols = columns
        let dateX = bounds.width - 10 - cols.date
        let authorX = dateX - cols.author
        let right = authorX - 12
        let pills = Self.labels(row.commit.refs)
        let pillWidths = pills.map { pillWidth($0) }
        let pillsW = pillWidths.reduce(0) { $0 + $1 + 5 }
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        let subjectAttrs: [NSAttributedString.Key: Any] = [.font: isHead ? boldFont : font, .paragraphStyle: para,
                                                           .foregroundColor: th.foreground.withAlphaComponent(0.92)]
        let subjectW = (row.commit.subject as NSString).size(withAttributes: subjectAttrs).width
        // Labels keep up to half the room; the subject gets the rest.
        let room = right - x0 - (pills.isEmpty ? 0 : min(pillsW + 6, (right - x0) / 2))
        let w = max(0, min(subjectW + 1, room))
        let textY = y + (Self.rowHeight - ceil(font.ascender - font.descender)) / 2
        (row.commit.subject as NSString).draw(in: NSRect(x: x0, y: textY, width: w, height: Self.rowHeight), withAttributes: subjectAttrs)
        var x = x0 + w + 6
        for (i, label) in pills.enumerated() where x + pillWidths[i] < right {
            drawPill(label, x: x, midY: y + Self.rowHeight / 2, color: Self.color(row.color), th: th)
            x += pillWidths[i] + 5
        }
        let dim: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: th.dimText, .paragraphStyle: para]
        if cols.author > 0 {
            (row.commit.author as NSString).draw(in: NSRect(x: authorX, y: textY, width: cols.author - 10, height: Self.rowHeight), withAttributes: dim)
        }
        if cols.date > 0 {
            (Self.dateFormatter.string(from: row.commit.date) as NSString).draw(in: NSRect(x: dateX, y: textY, width: cols.date, height: Self.rowHeight),
                                                                                  withAttributes: dim)
        }
    }

    // MARK: Branch and tag labels

    typealias Label = GraphLabel
    static func labels(_ refs: [String]) -> [Label] { GraphLabel.labels(refs) }

    private func pillSymbol(_ l: Label) -> String? {
        switch l.kind {
        case .branch: return l.current ? "scope" : nil
        case .remote: return "cloud"
        case .tag: return "tag"
        case .head: return nil
        }
    }

    private func pillWidth(_ l: Label) -> CGFloat {
        var w = (l.name as NSString).size(withAttributes: [.font: pillFont]).width + 14
        if pillSymbol(l) != nil { w += 15 }
        if l.onRemote { w += 17 }
        return ceil(w)
    }

    private func drawPill(_ l: Label, x: CGFloat, midY: CGFloat, color: NSColor, th: Theme) {
        let r = NSRect(x: x, y: midY - 9, width: pillWidth(l), height: 18)
        let solid = l.kind == .branch || l.kind == .head
        let path = NSBezierPath(roundedRect: r, xRadius: 9, yRadius: 9)
        if solid {
            color.setFill()
            path.fill()
        } else {
            color.withAlphaComponent(0.14).setFill()
            path.fill()
            color.withAlphaComponent(0.8).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        let ink: NSColor = solid ? .white : color
        var tx = r.minX + 7
        if let name = pillSymbol(l), let img = symbol(name, ink) {
            img.draw(in: NSRect(x: tx, y: midY - img.size.height / 2, width: img.size.width, height: img.size.height))
            tx += 15
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: pillFont, .foregroundColor: ink]
        (l.name as NSString).draw(at: NSPoint(x: tx, y: midY - ceil(pillFont.ascender - pillFont.descender) / 2), withAttributes: attrs)
        if l.onRemote, let img = symbol("cloud.fill", ink) {
            let cx = r.maxX - 7 - img.size.width
            img.draw(in: NSRect(x: cx, y: midY - img.size.height / 2, width: img.size.width, height: img.size.height))
        }
    }

    private func symbol(_ name: String, _ color: NSColor) -> NSImage? {
        let key = "\(name) \(color)"
        if let img = symbols[key] { return img }
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9.5, weight: .semibold).applying(.init(paletteColors: [color])))
        symbols[key] = img
        return img
    }
}

/// The commit card: who and when, the full message, how much changed, and copy buttons for the hash and message.
final class CommitCard: NSView {
    struct Details {
        let message: String
        /// git's summary, e.g. "2 files changed, 122 insertions(+), 105 deletions(-)"; empty for no changes.
        let stats: String
    }

    private let byline = NSTextField(labelWithString: "")
    private let message = NSTextField(wrappingLabelWithString: "")
    private let stats = NSTextField(labelWithString: "")
    private let viewChanges = CardButton()
    private let copyHash = CardButton()
    private let copyMessage = CardButton()
    private var commit: GraphCommit?
    private var details: Details?
    /// The commit's files and their changes (see GitStatusView.swift).
    var onViewChanges: ((String) -> Void)?
    private static let pad: CGFloat = 12

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        shadow = NSShadow()
        layer?.shadowOpacity = 0.35
        layer?.shadowRadius = 10
        layer?.shadowOffset = CGSize(width: 0, height: -3)
        message.maximumNumberOfLines = 12
        message.lineBreakMode = .byWordWrapping
        message.isSelectable = true
        for v in [byline, message, stats, viewChanges, copyHash, copyMessage] as [NSView] { addSubview(v) }
        viewChanges.action = { [weak self] in
            guard let self, let c = self.commit else { return }
            self.onViewChanges?(c.hash)
        }
        copyHash.action = { [weak self] in
            guard let self, let c = self.commit else { return }
            self.copy(c.hash, button: self.copyHash)
        }
        copyMessage.action = { [weak self] in
            guard let self, let c = self.commit else { return }
            self.copy(self.details?.message ?? c.subject, button: self.copyMessage)
        }
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func applyTheme() {
        let th = Config.shared.theme
        layer?.backgroundColor = th.background.mix(th.isDark ? .white : .black, th.isDark ? 0.06 : 0.02).cgColor
        layer?.borderColor = th.border.cgColor
        message.textColor = th.foreground
        message.font = .systemFont(ofSize: 12.5)
        if let commit { set(commit, details: details) }
        needsDisplay = true
    }

    func set(_ c: GraphCommit, details d: Details?) {
        commit = c
        details = d
        let th = Config.shared.theme
        let line = NSMutableAttributedString()
        func icon(_ name: String) {
            let a = NSTextAttachment()
            a.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .regular).applying(.init(paletteColors: [th.dimText])))
            line.append(NSAttributedString(attachment: a))
            line.append(NSAttributedString(string: " "))
        }
        icon("person.crop.circle")
        line.append(NSAttributedString(string: c.author, attributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .semibold), .foregroundColor: th.foreground]))
        line.append(NSAttributedString(string: ",  "))
        icon("clock.arrow.circlepath")
        let when = "\(Self.relative.localizedString(for: c.date, relativeTo: Date())) (\(Self.absolute.string(from: c.date)))"
        line.append(NSAttributedString(string: when, attributes: [.font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: th.foreground.withAlphaComponent(0.85)]))
        byline.attributedStringValue = line
        message.stringValue = d?.message ?? c.subject
        stats.attributedStringValue = Self.styledStats(d.map { $0.stats.isEmpty ? "No changes" : $0.stats } ?? "Loading…", th)
        viewChanges.set(symbol: "plusminus", title: "View Changes")
        copyHash.set(symbol: "doc.on.doc", title: String(c.hash.prefix(8)))
        copyMessage.set(symbol: "doc.on.doc", title: "Message")
        needsLayout = true
    }

    /// Insertions in green and deletions in red, as git colors them.
    private static func styledStats(_ s: String, _ th: Theme) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (i, part) in s.components(separatedBy: ", ").enumerated() {
            if i > 0 { out.append(NSAttributedString(string: ", ", attributes: [.font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: th.foreground])) }
            let color = part.contains("insertion") ? th.green : part.contains("deletion") ? th.red : th.foreground
            out.append(NSAttributedString(string: part, attributes: [.font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: color]))
        }
        return out
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    private static let absolute: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .short
        return f
    }()

    func fittingSize(width: CGFloat) -> NSSize {
        let inner = width - Self.pad * 2
        let messageH = message.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: inner, height: 400)).height ?? 18
        return NSSize(width: width, height: Self.pad + 18 + 10 + messageH + 12 + 18 + 10 + 24 + 8)
    }

    override func layout() {
        super.layout()
        let inner = bounds.width - Self.pad * 2
        var y = Self.pad
        byline.frame = NSRect(x: Self.pad, y: y, width: inner, height: 18)
        y += 18 + 10
        let messageH = message.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: inner, height: 400)).height ?? 18
        message.frame = NSRect(x: Self.pad, y: y, width: inner, height: messageH)
        y += messageH + 12
        stats.frame = NSRect(x: Self.pad, y: y, width: inner, height: 18)
        y += 18 + 10
        viewChanges.frame = NSRect(x: Self.pad - 4, y: y, width: viewChanges.fittingWidth, height: 24)
        copyHash.frame = NSRect(x: viewChanges.frame.maxX + 10, y: y, width: copyHash.fittingWidth, height: 24)
        copyMessage.frame = NSRect(x: copyHash.frame.maxX + 10, y: y, width: copyMessage.fittingWidth, height: 24)
    }

    override func draw(_ dirtyRect: NSRect) {
        // Rules between the sections, as in VS Code's card.
        let th = Config.shared.theme
        th.border.setFill()
        for v in [message, stats] {
            NSRect(x: 0, y: v.frame.maxY + 5, width: bounds.width, height: 1).fill()
        }
    }

    private func copy(_ text: String, button: CardButton) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        button.flash("Copied")
    }
}

/// A link-style button on the card: an icon and a title in the accent color, "Copied" for a moment after a click.
final class CardButton: NSView {
    var action: (() -> Void)?
    private var symbolName = ""
    private var title = ""
    private var shown = ""
    private var hovering = false { didSet { needsDisplay = true } }
    private let font = NSFont.systemFont(ofSize: 12.5)

    override var isFlipped: Bool { true }

    func set(symbol: String, title: String) {
        symbolName = symbol
        if shown == self.title || shown.isEmpty { shown = title }
        self.title = title
        needsDisplay = true
    }

    /// Room for the title or "Copied", whichever is wider.
    var fittingWidth: CGFloat {
        ceil(max((title as NSString).size(withAttributes: [.font: font]).width, ("Copied" as NSString).size(withAttributes: [.font: font]).width)) + 30
    }

    func flash(_ text: String) {
        shown = text
        needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self else { return }
            self.shown = self.title
            self.needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let th = Config.shared.theme
        if hovering {
            th.accent.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        }
        let color = th.accent
        if let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular).applying(.init(paletteColors: [color]))) {
            img.draw(in: NSRect(x: 4, y: (bounds.height - img.size.height) / 2, width: img.size.width, height: img.size.height))
        }
        let h = ceil(font.ascender - font.descender)
        (shown as NSString).draw(at: NSPoint(x: 22, y: (bounds.height - h) / 2), withAttributes: [.font: font, .foregroundColor: color])
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === self }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action?() }
    }
}
