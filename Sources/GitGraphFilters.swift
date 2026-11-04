import AppKit

// The Git Graph's filters, as IntelliJ's Git log has them: a list of branches and tags down the left (picking one
// shows just its history), and along the top a search for text or a hash, and Branch, User, Date and Paths.
// git does the filtering, so a search reaches the whole history rather than the newest commits loaded.

/// What the graph shows. Empty: every branch's history.
struct GraphFilter: Equatable {
    /// In a commit's message, or the start of its hash.
    var text = ""
    var regex = false
    var matchCase = false
    /// One branch or tag's history (its short name, as `git log` takes it); nil for all of them.
    var branch: String?
    var user: String?
    /// The last so many days.
    var days: Int?
    /// A folder or file in the repository (from its top).
    var path: String?

    var isEmpty: Bool { text.isEmpty && branch == nil && user == nil && days == nil && path == nil }
    /// Whether git keeps what's left connected: it rewrites parents past the commits a branch, date or path leaves
    /// out, but not past ones a text or user search does. For those the history's shape is read too (see `arrange`).
    var keepsAncestry: Bool { text.isEmpty && user == nil }

    /// How many commits' parents are read to connect a text or user search's commits.
    static let topologyLimit = 50000
    /// Between the commits and the history's shape in the script's output.
    static let topologyMark: UInt8 = 0x1D

    static let dayChoices: [(title: String, days: Int)] = [("Last 24 Hours", 1), ("Last 7 Days", 7), ("Last 30 Days", 30),
                                                          ("Last 90 Days", 90), ("Last Year", 365)]

    /// HEAD's hash on the first line, then the commits (see `GraphCommit.parse`).
    func script(limit: Int = GraphCommit.limit) -> String {
        let format = "--format='%H%x1f%P%x1f%an%x1f%at%x1f%s%x1f%D%x1e'"
        var args = [branch.map { shellQuote($0) } ?? "--all", "--parents", "--date-order", "-n \(limit)", format]
        if let user { args.append("--author=" + shellQuote("^" + NSRegularExpression.escapedPattern(for: user) + " <")) }
        if let days { args.append("--since=" + shellQuote("\(days) days ago")) }
        let query = text.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            args.append("--grep=" + shellQuote(query))
            args.append(regex ? "-E" : "-F")
            if !matchCase { args.append("-i") }
        }
        if let path { args += ["--", shellQuote(path)] }
        var script = "printf '%s\\n' \"$(git rev-parse HEAD 2>/dev/null)\"\ngit log " + args.joined(separator: " ")
        // A hash (or the start of one): that commit too, when it's one.
        if query.count >= 4, query.count <= 40, query.allSatisfy(\.isHexDigit) {
            let q = shellQuote(query + "^{commit}")
            script += "\nif h=$(git rev-parse -q --verify \(q) 2>/dev/null); then git log -n 1 \(format) \"$h\"; fi"
        }
        // Text or user: the history's shape too, newest first with children before parents, to connect what's shown.
        if !keepsAncestry {
            script += "\nprintf '\\035'\ngit log \(branch.map { shellQuote($0) } ?? "--all") --topo-order -n \(Self.topologyLimit) --format='%H %P'"
        }
        return script
    }

    /// The script's output split into the commits (for `GraphCommit.parse`) and, when it was read, each commit's
    /// parents.
    static func split(_ out: Data) -> (log: Data, topology: [(String, [String])]?) {
        guard let mark = out.firstIndex(of: topologyMark) else { return (out, nil) }
        var topology: [(String, [String])] = []
        for line in String(decoding: out[out.index(after: mark)...], as: UTF8.self).split(separator: "\n") {
            let f = line.split(separator: " ").map(String.init)
            if let h = f.first { topology.append((h, Array(f.dropFirst()))) }
        }
        return (Data(out[..<mark]), topology)
    }

    /// The commits as the graph should lay them out: each once, newest first, and (for a text or user search) with
    /// parents that aren't shown left out, rather than lines to commits that aren't there.
    /// The commits as the graph should lay them out: each once, newest first. For a text or user search, each one's
    /// parents become its nearest ancestors that are shown, through the ones that aren't (as IntelliJ draws it), from
    /// `topology` (children before parents); without it, parents that aren't shown are just left out.
    func arrange(_ commits: [GraphCommit], topology: [(String, [String])]? = nil) -> [GraphCommit] {
        var seen = Set<String>(), out: [GraphCommit] = []
        for c in commits where seen.insert(c.hash).inserted { out.append(c) }
        if out.count != commits.count || !text.isEmpty { out.sort { $0.date > $1.date } }
        guard !keepsAncestry else { return out }
        let shown = Set(out.map(\.hash))
        // Oldest first, so each commit's parents are worked out before it: its nearest shown ancestors are its shown
        // parents, and those of the parents that aren't (a few at most, so a busy history stays cheap).
        var nearest: [String: [String]] = [:]
        for (hash, parents) in (topology ?? []).reversed() {
            var acc: [String] = []
            for p in parents {
                for a in shown.contains(p) ? [p] : nearest[p] ?? [] where !acc.contains(a) && acc.count < 3 { acc.append(a) }
            }
            nearest[hash] = acc
        }
        return out.map { c in
            let parents = nearest[c.hash] ?? c.parents.filter(shown.contains)
            return GraphCommit(hash: c.hash, parents: parents, author: c.author, date: c.date, subject: c.subject, refs: c.refs)
        }
    }
}

/// A repository's branches and tags, for the list beside the graph.
struct GraphRefs {
    var current: String?
    var locals: [String] = []
    var remotes: [String] = []
    var tags: [String] = []

    static let script = """
        git symbolic-ref -q --short HEAD; printf '\\036'
        git for-each-ref --sort=refname --format='%(refname)' refs/heads refs/remotes refs/tags
        """

    static func parse(_ out: Data) -> GraphRefs {
        let s = String(decoding: out, as: UTF8.self)
        let parts = s.components(separatedBy: "\u{1e}")
        var refs = GraphRefs()
        let current = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        refs.current = current.isEmpty ? nil : current
        for line in (parts.count > 1 ? parts[1] : "").split(separator: "\n").map(String.init) {
            if line.hasPrefix("refs/heads/") { refs.locals.append(String(line.dropFirst(11))) }
            else if line.hasPrefix("refs/remotes/"), !line.hasSuffix("/HEAD") { refs.remotes.append(String(line.dropFirst(13))) }
            else if line.hasPrefix("refs/tags/") { refs.tags.append(String(line.dropFirst(10))) }
        }
        return refs
    }
}

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
            rebuild()
        case .ref(let name, _, _):
            onPick?(name == selected ? nil : name)
        }
    }

    /// The rows, narrowed to what the field says (opening every section, so nothing that matches stays folded).
    private func rebuild() {
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
        rowsView.items = items
        rowsView.selected = selected
        rowsView.fit(width: scroll.contentSize.width)
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

    func fit(width: CGFloat) {
        setFrameSize(NSSize(width: width, height: CGFloat(items.count) * Self.rowHeight + 8))
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === self }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    private func row(_ e: NSEvent) -> Int? {
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
            let r = NSRect(x: 0, y: CGFloat(i) * Self.rowHeight, width: bounds.width, height: Self.rowHeight)
            guard r.intersects(dirtyRect) else { continue }
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
        let menu = NSMenu()
        menu.addItem(ActionMenuItem("Any Time", checked: filter.days == nil) { [weak self] in self?.change { $0.days = nil } })
        menu.addItem(.separator())
        for choice in GraphFilter.dayChoices {
            menu.addItem(ActionMenuItem(choice.title, checked: filter.days == choice.days) { [weak self] in self?.change { $0.days = choice.days } })
        }
        Self.popUp(menu, under: anchor)
    }

    static func popUp(_ menu: NSMenu, under anchor: NSView) {
        if Headless.active {
            FileHandle.standardError.write("graph menu: \(menu.items.map { $0.isSeparatorItem ? "---" : ($0.state == .on ? "✓ " : "") + $0.title })\n".data(using: .utf8)!)
            devLastMenu = menu
            return
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.maxY + 4), in: anchor)
    }

    /// Dev aid: the last menu a filter opened (headless runs print it instead of showing it).
    static var devLastMenu: NSMenu?

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
        [branchButton, userButton, dateButton, pathButton].first { $0.title == title }.map { $0.onPress?($0) }
    }
    func devPath(_ path: String) { pick(path: path) }
    func devType(_ text: String) {
        field.stringValue = text
        change { $0.text = text }
    }
}

/// "User ▾", or, set, "User: sjain ▾" in the accent color.
final class FilterButton: NSView {
    let title: String
    var value: String? { didSet { needsDisplay = true; superview?.needsLayout = true } }
    var onPress: ((FilterButton) -> Void)?
    private var hovering = false { didSet { needsDisplay = true } }
    private static let font = NSFont.systemFont(ofSize: 12.5)

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
    override func mouseDown(with e: NSEvent) { onPress?(self) }

    override func draw(_ dirtyRect: NSRect) {
        let th = Config.shared.theme
        let on = value != nil
        if hovering || on {
            (on ? th.accent.withAlphaComponent(0.16) : th.foreground.withAlphaComponent(0.07)).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        let color = on ? th.accent : th.foreground.withAlphaComponent(0.85)
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
