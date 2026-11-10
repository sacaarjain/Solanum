import AppKit

// The Git Graph's filters, as IntelliJ's Git log has them: a list of branches and tags down the left (picking one
// shows just its history), and along the top a search for text or a hash, and Branch, User, Date and Paths.
// git does the filtering, so a search reaches the whole history rather than the newest commits loaded.

// GraphFilter and GraphRefs, what's shown and the git that finds it, are Core's (GitGraphFilter.swift), shared with
// Windows.

// MARK: - The list of branches

/// Down the left of the graph: a field to narrow it, then HEAD, the local branches, and (folded until opened, or
/// searched) the remote ones and the tags. Clicking one shows its history; clicking it again, every branch's.
final class GraphBranchList: NSView, NSTextFieldDelegate {
    private let field = NSTextField()
    private let scroll = NSScrollView()
    private let rowsView = BranchRowsView()
    var refs = GraphRefs() { didSet { rebuild() } }
    /// The branch the graph is showing, picked out.
    var selected: String? { didSet { rowsView.selected = selected } }
    var onPick: ((String?) -> Void)?
    private var openSections: Set<String> = ["Local"]

    override init(frame: NSRect) {
        super.init(frame: frame)
        let cell = CenteredTextFieldCell(textCell: "")
        cell.horizontalInset = 24
        field.cell = cell
        field.isEditable = true
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 12.5)
        field.delegate = self
        field.cell?.isScrollable = true
        addSubview(field)
        scroll.documentView = rowsView
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        addSubview(scroll)
        rowsView.onPick = { [weak self] item in self?.picked(item) }
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func applyTheme() {
        let th = Config.shared.theme
        field.textColor = th.foreground
        field.placeholderAttributedString = NSAttributedString(string: "Branch or tag",
                                                               attributes: [.foregroundColor: th.dimText, .font: NSFont.systemFont(ofSize: 12.5)])
        rowsView.needsDisplay = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        field.frame = NSRect(x: 8, y: 8, width: bounds.width - 16, height: 26)
        scroll.frame = NSRect(x: 0, y: 40, width: bounds.width, height: bounds.height - 40)
        rowsView.fit(width: scroll.contentSize.width)
    }

    override func draw(_ dirtyRect: NSRect) {
        let th = Config.shared.theme
        let box = NSBezierPath(roundedRect: field.frame, xRadius: 6, yRadius: 6)
        th.foreground.withAlphaComponent(0.06).setFill()
        box.fill()
        th.border.setStroke()
        box.stroke()
        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium).applying(.init(paletteColors: [th.dimText]))
        if let img = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
            img.draw(in: NSRect(x: field.frame.minX + 8, y: field.frame.midY - img.size.height / 2, width: img.size.width, height: img.size.height))
        }
        th.border.setFill()
        NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill()
    }

    func controlTextDidChange(_ obj: Notification) { rebuild() }

    private func picked(_ item: BranchRowsView.Item) {
        switch item {
        case .section(let title, _):
            if openSections.contains(title) { openSections.remove(title) } else { openSections.insert(title) }
            rebuild(sliding: title)
        case .ref(let name, _, _):
            onPick?(name == selected ? nil : name)
        }
    }

    /// The rows, narrowed to what the field says (opening every section, so nothing that matches stays folded).
    /// `sliding`: the section just opened or closed, whose rows slide out from under it (or back).
    private func rebuild(sliding: String? = nil) {
        let query = field.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        func keep(_ names: [String]) -> [String] { query.isEmpty ? names : names.filter { $0.lowercased().contains(query) } }
        var items: [BranchRowsView.Item] = []
        if query.isEmpty || "head".contains(query) || (refs.current?.lowercased().contains(query) ?? false) {
            items.append(.ref(name: "HEAD", title: "HEAD" + (refs.current.map { " (\($0))" } ?? ""), kind: .head))
        }
        for (title, names, kind) in [("Local", refs.locals, BranchRowsView.Kind.local), ("Remote", refs.remotes, .remote), ("Tags", refs.tags, .tag)] {
            let shown = keep(names)
            guard !shown.isEmpty else { continue }
            let open = !query.isEmpty || openSections.contains(title)
            items.append(.section(title: title, open: open))
            if open { items += shown.map { .ref(name: $0, title: $0, kind: $0 == refs.current && kind == .local ? .current : kind) } }
        }
        rowsView.selected = selected
        if let sliding { rowsView.slide(to: items, section: sliding, width: scroll.contentSize.width) }
        else { rowsView.items = items; rowsView.fit(width: scroll.contentSize.width) }
    }

    var devTitles: [String] { rowsView.items.map(\.title) }
    func devPick(_ title: String) { rowsView.items.first { $0.title == title }.map(picked) }
    func devFilter(_ text: String) { field.stringValue = text; rebuild() }
}

final class BranchRowsView: NSView {
    enum Kind { case head, current, local, remote, tag }
    enum Item {
        case section(title: String, open: Bool)
        case ref(name: String, title: String, kind: Kind)
        var title: String {
            switch self {
            case .section(let t, _): return t
            case .ref(_, let t, _): return t
            }
        }
    }

    var items: [Item] = [] { didSet { needsDisplay = true } }
    var selected: String? { didSet { needsDisplay = true } }
    var onPick: ((Item) -> Void)?
    private var hovered: Int? { didSet { if hovered != oldValue { needsDisplay = true } } }
    private static let rowHeight: CGFloat = 24

    override var isFlipped: Bool { true }

    /// A section's rows on the move: `count` rows from `start` (just under its header), `shown` of the way out
    /// (0 tucked under the header, 1 in place). Everything below moves with them.
    private var sliding: (start: Int, count: Int, shown: CGFloat)?
    private var slideTimer: Timer?
    private var fitWidth: CGFloat = 0

    func fit(width: CGFloat) {
        fitWidth = width
        let hidden = sliding.map { CGFloat($0.count) * (1 - $0.shown) } ?? 0
        setFrameSize(NSSize(width: width, height: (CGFloat(items.count) - hidden) * Self.rowHeight + 8))
        needsDisplay = true
    }

    /// Opens or closes `section` with its rows sliding down out from under the header (or back up under it).
    func slide(to new: [Item], section: String, width: CGFloat) {
        finishSlide()
        let old = items
        guard let h = new.firstIndex(where: { $0.title == section }), new.count != old.count else {
            items = new
            return fit(width: width)
        }
        let opening = new.count > old.count
        let count = abs(new.count - old.count)
        if opening { items = new }
        sliding = (h + 1, count, opening ? 0 : 1)
        fit(width: width)
        let began = Date(), duration = 0.2
        slideTimer = Timer.scheduledTimer(withTimeInterval: 1 / 120, repeats: true) { [weak self] _ in
            guard let self else { return }
            let t = min(1, Date().timeIntervalSince(began) / duration)
            let eased = CGFloat(1 - pow(1 - t, 3))
            self.sliding?.shown = opening ? eased : 1 - eased
            if t >= 1 {
                self.finishSlide()
                self.items = new
            }
            self.fit(width: self.fitWidth)
        }
        RunLoop.main.add(slideTimer!, forMode: .common)
    }

    private func finishSlide() {
        slideTimer?.invalidate()
        slideTimer = nil
        sliding = nil
    }

    /// Where row `i` is drawn: rows from a sliding section down are pulled up by what's still tucked away.
    private func top(ofRow i: Int) -> CGFloat {
        var y = CGFloat(i) * Self.rowHeight
        if let s = sliding, i >= s.start { y -= CGFloat(s.count) * (1 - s.shown) * Self.rowHeight }
        return y
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === self }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    private func row(_ e: NSEvent) -> Int? {
        guard sliding == nil else { return nil }
        let r = Int(convert(e.locationInWindow, from: nil).y / Self.rowHeight)
        return items.indices.contains(r) ? r : nil
    }

    override func mouseMoved(with e: NSEvent) { hovered = row(e) }
    override func mouseExited(with e: NSEvent) { hovered = nil }
    override func mouseDown(with e: NSEvent) { if let r = row(e) { onPick?(items[r]) } }

    override func draw(_ dirtyRect: NSRect) {
        let th = Config.shared.theme
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        for (i, item) in items.enumerated() {
            let r = NSRect(x: 0, y: top(ofRow: i), width: bounds.width, height: Self.rowHeight)
            guard r.intersects(dirtyRect) else { continue }
            // A sliding section's rows show only below its header, fading in as they come out.
            let moving = sliding.map { i >= $0.start && i < $0.start + $0.count } ?? false
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            if moving, let s = sliding {
                NSRect(x: 0, y: CGFloat(s.start) * Self.rowHeight, width: bounds.width, height: bounds.height).clip()
                NSGraphicsContext.current?.cgContext.setAlpha(s.shown)
            }
            let font = NSFont.systemFont(ofSize: 12.5)
            let textY = r.midY - 8
            switch item {
            case .section(let title, let open):
                if hovered == i { th.foreground.withAlphaComponent(0.06).setFill(); NSBezierPath(roundedRect: r.insetBy(dx: 6, dy: 1), xRadius: 5, yRadius: 5).fill() }
                draw(symbol: open ? "chevron.down" : "chevron.right", at: NSPoint(x: 14, y: r.midY), size: 9, color: th.dimText)
                (title as NSString).draw(in: NSRect(x: 28, y: textY, width: r.width - 36, height: 17),
                                         withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: th.dimText])
            case .ref(let name, let title, let kind):
                let isSelected = name == selected
                if isSelected || hovered == i {
                    (isSelected ? th.accent.withAlphaComponent(0.22) : th.foreground.withAlphaComponent(0.06)).setFill()
                    NSBezierPath(roundedRect: r.insetBy(dx: 6, dy: 1), xRadius: 5, yRadius: 5).fill()
                }
                let indent: CGFloat = kind == .head ? 14 : 30
                let symbol: String
                switch kind {
                case .head: symbol = "scope"
                case .tag: symbol = "tag"
                case .remote: symbol = "cloud"
                case .current: symbol = "star.fill"
                case .local: symbol = "arrow.triangle.branch"
                }
                let tint = kind == .current || kind == .head ? th.accent : th.dimText
                draw(symbol: symbol, at: NSPoint(x: indent + 6, y: r.midY), size: 11, color: tint)
                (title as NSString).draw(in: NSRect(x: indent + 18, y: textY, width: r.width - indent - 26, height: 17),
                                         withAttributes: [.font: kind == .current ? NSFont.systemFont(ofSize: 12.5, weight: .semibold) : font,
                                                          .foregroundColor: th.foreground.withAlphaComponent(0.9), .paragraphStyle: para])
            }
        }
    }

    private func draw(symbol: String, at c: NSPoint, size: CGFloat, color: NSColor) {
        let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: .medium).applying(.init(paletteColors: [color]))
        guard let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else { return }
        img.draw(in: NSRect(x: c.x - img.size.width / 2, y: c.y - img.size.height / 2, width: img.size.width, height: img.size.height))
    }
}

// MARK: - The toolbar

/// Above the graph: Text or hash (with regex and match-case), Branch, User, Date, Paths, then refresh and clear.
final class GraphToolbar: NSView, NSTextFieldDelegate {
    static let height: CGFloat = 40
    private let field = NSTextField()
    private let regexToggle = FindToggle(".*", tip: "Regular Expression", centersInk: true)
    private let caseToggle = FindToggle("Aa", tip: "Match Case")
    private let branchButton = FilterButton("Branch")
    private let userButton = FilterButton("User")
    private let dateButton = FilterButton("Date")
    private let pathButton = FilterButton("Paths")
    private let refresh = FindButton("arrow.clockwise", tip: "Refresh", pointSize: 12)
    private let clear = FindButton("xmark.circle", tip: "Clear Filters", pointSize: 12)
    private var pendingText: DispatchWorkItem?

    var filter = GraphFilter() { didSet { sync() } }
    var onChange: ((GraphFilter) -> Void)?
    var onRefresh: (() -> Void)?
    /// Menus that need the repository: its branches, its authors, its paths.
    var onBranchMenu: ((NSView) -> Void)?
    var onUserMenu: ((NSView) -> Void)?
    var onPathMenu: ((NSView) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        let cell = CenteredTextFieldCell(textCell: "")
        cell.horizontalInset = 26
        field.cell = cell
        field.isEditable = true
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 12.5)
        field.delegate = self
        field.cell?.isScrollable = true
        addSubview(field)
        regexToggle.onToggle = { [weak self] in self?.change { $0.regex.toggle() } }
        caseToggle.onToggle = { [weak self] in self?.change { $0.matchCase.toggle() } }
        branchButton.onPress = { [weak self] b in self?.onBranchMenu?(b) }
        userButton.onPress = { [weak self] b in self?.onUserMenu?(b) }
        dateButton.onPress = { [weak self] b in self?.showDateMenu(b) }
        pathButton.onPress = { [weak self] b in self?.onPathMenu?(b) }
        refresh.onPress = { [weak self] in self?.onRefresh?() }
        clear.onPress = { [weak self] in
            self?.field.stringValue = ""
            self?.change { $0 = GraphFilter() }
        }
        for v in [regexToggle, caseToggle, branchButton, userButton, dateButton, pathButton, refresh, clear] as [NSView] { addSubview(v) }
        applyTheme()
        sync()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func applyTheme() {
        let th = Config.shared.theme
        field.textColor = th.foreground
        field.placeholderAttributedString = NSAttributedString(string: "Text or hash",
                                                               attributes: [.foregroundColor: th.dimText, .font: NSFont.systemFont(ofSize: 12.5)])
        subviews.forEach { $0.needsDisplay = true }
        needsDisplay = true
    }

    func focusSearch() {
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    private func change(_ edit: (inout GraphFilter) -> Void) {
        var f = filter
        edit(&f)
        guard f != filter else { return }
        filter = f
        onChange?(f)
    }

    private func sync() {
        regexToggle.isOn = filter.regex
        caseToggle.isOn = filter.matchCase
        if field.stringValue != filter.text, field.currentEditor() == nil { field.stringValue = filter.text }
        branchButton.value = filter.branch
        userButton.value = filter.user
        dateButton.value = filter.days.flatMap { d in GraphFilter.dayChoices.first { $0.days == d }?.title }
        pathButton.value = filter.path
        clear.isHidden = filter.isEmpty
        needsLayout = true
    }

    /// Searching waits for typing to pause, as each change asks git again.
    func controlTextDidChange(_ obj: Notification) {
        pendingText?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let text = self.field.stringValue
            self.change { $0.text = text }
        }
        pendingText = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)), !field.stringValue.isEmpty {
            field.stringValue = ""
            pendingText?.cancel()
            change { $0.text = "" }
            return true
        }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            pendingText?.perform()
            return true
        }
        return false
    }

    private func showDateMenu(_ anchor: NSView) {
        var items: [DropdownItem] = [.item("Any Time", checked: filter.days == nil) { [weak self] in self?.change { $0.days = nil } }, .separator]
        for choice in GraphFilter.dayChoices {
            items.append(.item(choice.title, checked: filter.days == choice.days) { [weak self] in self?.change { $0.days = choice.days } })
        }
        ThemedDropdown.show(items, under: anchor)
    }

    func setFilter(_ f: GraphFilter, notify: Bool) {
        filter = f
        if notify { onChange?(f) }
    }

    func pick(branch: String?) { change { $0.branch = branch } }
    func pick(user: String?) { change { $0.user = user } }
    func pick(path: String?) { change { $0.path = path } }

    override func layout() {
        super.layout()
        let h: CGFloat = 26, y = (bounds.height - h) / 2
        var x: CGFloat = 10
        let fieldW = min(260, max(150, bounds.width * 0.28))
        field.frame = NSRect(x: x, y: y, width: fieldW, height: h)
        x += fieldW + 6
        for t in [regexToggle, caseToggle] {
            t.frame = NSRect(x: x, y: y, width: 26, height: h)
            x += 28
        }
        x += 6
        for b in [branchButton, userButton, dateButton, pathButton] {
            let w = b.preferredWidth
            b.frame = NSRect(x: x, y: y, width: w, height: h)
            x += w + 4
        }
        refresh.frame = NSRect(x: bounds.width - 36, y: y, width: 26, height: h)
        clear.frame = NSRect(x: bounds.width - 64, y: y, width: 26, height: h)
    }

    override func draw(_ dirtyRect: NSRect) {
        let th = Config.shared.theme
        let box = NSBezierPath(roundedRect: field.frame, xRadius: 6, yRadius: 6)
        th.foreground.withAlphaComponent(0.06).setFill()
        box.fill()
        (filter.text.isEmpty ? th.border : th.accent.withAlphaComponent(0.6)).setStroke()
        box.stroke()
        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium).applying(.init(paletteColors: [th.dimText]))
        if let img = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
            img.draw(in: NSRect(x: field.frame.minX + 9, y: field.frame.midY - img.size.height / 2, width: img.size.width, height: img.size.height))
        }
        th.border.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    var devButtons: [String] { [branchButton, userButton, dateButton, pathButton].map(\.shown) }
    func devPress(_ title: String) {
        [branchButton, userButton, dateButton, pathButton].first { $0.title == title }?.press()
    }
    /// Dev aid: a real click on the button (through the window, as the mouse would), not a call to its action.
    func devClick(_ title: String) {
        guard let b = [branchButton, userButton, dateButton, pathButton].first(where: { $0.title.hasPrefix(title) }), let w = window else { return }
        let p = b.convert(NSPoint(x: b.bounds.midX, y: b.bounds.midY), to: nil)
        // Headless windows ignore the mouse, so this does the window's part: the view under the point gets it.
        guard let content = w.contentView,
              let e = NSEvent.mouseEvent(with: .leftMouseDown, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return }
        content.superview?.hitTest(content.superview!.convert(p, from: nil))?.mouseDown(with: e)
    }
    func devPath(_ path: String) { pick(path: path) }
    func devType(_ text: String) {
        field.stringValue = text
        change { $0.text = text }
    }
}

/// "User ▾", or, set, "User: sjain ▾" in the accent color. Each click toggles its dropdown: it shows pressed while
/// open, and a second click before the list has loaded cancels it.
final class FilterButton: NSView, DropdownAnchor {
    let title: String
    var value: String? { didSet { needsDisplay = true; superview?.needsLayout = true } }
    var onPress: ((FilterButton) -> Void)?
    private var hovering = false { didSet { needsDisplay = true } }
    private static let font = NSFont.systemFont(ofSize: 12.5)
    /// When it was pressed, until its dropdown opens (or a second press cancels it); a press that never opened
    /// anything (git failed) stops counting after a few seconds.
    private var pressedAt: Date?
    var dropdownWanted: Bool { pressedAt.map { Date().timeIntervalSince($0) < 8 } ?? false }
    var dropdownOpen = false { didSet { if dropdownOpen { pressedAt = nil }; needsDisplay = true } }

    init(_ title: String) {
        self.title = title
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    var shown: String {
        guard let value else { return title }
        let short = value.count > 28 ? "…" + value.suffix(27) : Substring(value)
        return "\(title): \(short)"
    }

    var preferredWidth: CGFloat { ceil((shown as NSString).size(withAttributes: [.font: Self.font]).width) + 32 }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === self }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with e: NSEvent) { hovering = true }
    override func mouseExited(with e: NSEvent) { hovering = false }
    override func mouseDown(with e: NSEvent) { press() }

    func press() {
        if dropdownOpen { return ThemedDropdown.dismissCurrent() }
        if dropdownWanted { pressedAt = nil; needsDisplay = true; return }
        pressedAt = Date()
        needsDisplay = true
        onPress?(self)
    }

    override func draw(_ dirtyRect: NSRect) {
        let th = Config.shared.theme
        // Styled as the find bar's toggles (Aa, .*): set or open, an accent box behind accent text; hovered, a lighter one.
        let on = value != nil || dropdownOpen || dropdownWanted
        if on || hovering {
            th.accent.withAlphaComponent(on ? 0.24 : 0.13).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        }
        let color = on || hovering ? th.accent : th.foreground.withAlphaComponent(0.85)
        // The text's capitals centered in the button, and the chevron centered on them.
        let f = Self.font
        let top = EditorFindBar.textTop(f, centeredIn: bounds)
        (shown as NSString).draw(at: NSPoint(x: 10, y: top), withAttributes: [.font: f, .foregroundColor: color])
        // The chevron on the middle of the capitals beside it.
        let capMid = top + f.ascender - f.capHeight / 2
        let cfg = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold).applying(.init(paletteColors: [color]))
        if let img = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
            img.draw(in: NSRect(x: bounds.width - 17, y: (capMid - img.size.height / 2).rounded(), width: img.size.width, height: img.size.height))
        }
    }

    override var isFlipped: Bool { true }
}
