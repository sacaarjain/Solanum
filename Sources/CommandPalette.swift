import AppKit

/// ⇧⌘P palette that fuzzy-searches every menu command (actions, themes, snippets…).
final class CommandPalette: NSView, NSTextFieldDelegate {
    struct Item {
        let title: String
        let path: String
        let shortcut: String
        /// Section label row ("Recently used"); not selectable.
        var isHeader = false
        /// What ⌘↩ does instead of `run`, when set.
        var alternate: (() -> Void)? = nil
        /// What Tab puts in the field (a "Go to:" folder suggestion).
        var completion: String? = nil
        /// A section label shown as written (a file's path), not in capitals.
        var keepsCase = false
        /// Search in Project Folder: the title is a line of text, with this shown picked out in it.
        var highlight: String? = nil
        let run: () -> Void

        var recentKey: String { path + " › " + title }

        static func header(_ title: String) -> Item { Item(title: title, path: "", shortcut: "", isHeader: true) {} }
    }

    private static let recentsKey = "SolanumPaletteRecents"
    private static let maxRecents = 5

    private static weak var current: CommandPalette?

    private let allItems: [Item]
    /// Only the main command palette remembers what was run; custom lists (jump to prompt) don't.
    private let tracksRecents: Bool
    /// Matches stay in list order (e.g. most recent first) instead of best-score first; exact substring
    /// matches still come before fuzzy ones.
    private let keepsOrder: Bool
    private var filtered: [Item] = []
    private var selected = 0
    private var scrollTop = 0
    private weak var previousResponder: NSResponder?
    let field = NSTextField()
    private let panel = NSVisualEffectView()
    private let list = PaletteList()
    private let maxRows = 10
    /// Go to Folder's own palette: the field is a path, not a command (see `showGoTo`).
    private var goToMode = false
    /// A live list (Search in Project Folder): called with each change to the field, instead of filtering `allItems`.
    private var onQuery: ((CommandPalette, String) -> Void)?
    /// Shown when the list is empty.
    private(set) var emptyMessage = "No matching commands"
    /// What a live list is over, at the right of the field.
    private let scopeLabel = NSTextField(labelWithString: "")
    private let rowH: CGFloat = 34

    static func toggle(in window: NSWindow) {
        if let c = current, c.window === window {
            c.dismiss(restoreFocus: true)
            return
        }
        show(in: window, items: collectItems(), tracksRecents: true)
    }

    /// Opens the palette over a custom list (e.g. prompts to jump to).
    /// Go to Folder (⌘O on an ssh tab, and Go to Folder…): a palette of its own whose field is just the path, so it
    /// can be cleared and typed afresh. Its list is `goToItems`, as for "Go to:" in the command palette.
    static func showGoTo(in window: NSWindow, path: String = "") {
        show(in: window, items: [], placeholder: "Go to folder: a path, ~/…, or a folder in this one", icon: "folder")
        guard let p = current else { return }
        p.goToMode = true
        p.field.stringValue = path
        p.field.currentEditor()?.selectedRange = NSRange(location: (path as NSString).length, length: 0)
        p.filter(path)
    }

    static func show(in window: NSWindow, items: [Item], placeholder: String = "Type a command, theme, or snippet…",
                     tracksRecents: Bool = false, keepsOrder: Bool = false, icon: String = "command", query: String = "") {
        current?.dismiss(restoreFocus: false)
        guard let content = window.contentView else { return }
        let palette = CommandPalette(items: items, placeholder: placeholder, tracksRecents: tracksRecents, keepsOrder: keepsOrder,
                                     icon: icon, previous: window.firstResponder)
        palette.frame = content.bounds
        palette.autoresizingMask = [.width, .height]
        content.addSubview(palette)
        current = palette
        palette.layoutPanel()
        window.makeFirstResponder(palette.field)
        if !query.isEmpty {
            palette.field.stringValue = query
            palette.field.currentEditor()?.selectedRange = NSRange(location: (query as NSString).length, length: 0)
            palette.filter(query)
        }
    }

    /// A palette whose list comes from `onQuery`, which answers through `setResults`. The same shortcut closes it.
    static func showLive(in window: NSWindow, placeholder: String, scope: String, message: String, query: String,
                         onQuery: @escaping (CommandPalette, String) -> Void) {
        if let c = current, c.window === window, c.onQuery != nil {
            c.dismiss(restoreFocus: true)
            return
        }
        current?.dismiss(restoreFocus: false)
        guard let content = window.contentView else { return }
        let palette = CommandPalette(items: [], placeholder: placeholder, tracksRecents: false, keepsOrder: false, icon: "magnifyingglass",
                                     previous: window.firstResponder)
        palette.frame = content.bounds
        palette.autoresizingMask = [.width, .height]
        palette.onQuery = onQuery
        palette.emptyMessage = message
        palette.scopeLabel.stringValue = scope
        palette.scopeLabel.isHidden = false
        content.addSubview(palette)
        current = palette
        palette.layoutPanel()
        window.makeFirstResponder(palette.field)
        if !query.isEmpty {
            palette.field.stringValue = query
            palette.field.currentEditor()?.selectedRange = NSRange(location: (query as NSString).length, length: 0)
            palette.filter(query)
        }
    }

    /// A live list's new results.
    /// `keepSelection`: more of the same search arrived, so what's selected and scrolled to stays where it is.
    func setResults(_ items: [Item], scope: String, message: String, keepSelection: Bool = false) {
        let keep = keepSelection && filtered.indices.contains(selected) && items.indices.contains(selected)
            && !items[selected].isHeader && items[selected].title == filtered[selected].title
        filtered = items
        emptyMessage = message
        scopeLabel.stringValue = scope
        if !keep {
            selected = filtered.firstIndex { !$0.isHeader } ?? 0
            scrollTop = 0
        }
        layoutPanel()
    }

    /// A search has started: what's listed stays until its results come.
    func setSearching() {
        if filtered.isEmpty { emptyMessage = "Searching…" }
        list.needsDisplay = true
    }

    private init(items: [Item], placeholder: String, tracksRecents: Bool, keepsOrder: Bool, icon symbol: String, previous: NSResponder?) {
        allItems = items
        self.tracksRecents = tracksRecents
        self.keepsOrder = keepsOrder
        previousResponder = previous
        super.init(frame: .zero)
        let th = Config.shared.theme

        panel.material = .popover
        panel.blendingMode = .withinWindow
        panel.state = .active
        panel.appearance = NSAppearance(named: th.isDark ? .darkAqua : .aqua)
        panel.wantsLayer = true
        panel.layer?.cornerRadius = 12
        panel.layer?.masksToBounds = true
        panel.layer?.borderWidth = 1
        panel.layer?.borderColor = th.border.cgColor
        addSubview(panel)

        let tint = NSView()
        tint.wantsLayer = true
        tint.layer?.backgroundColor = th.background.withAlphaComponent(0.55).cgColor
        tint.autoresizingMask = [.width, .height]
        panel.addSubview(tint)

        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = th.accent
        icon.tag = 1
        panel.addSubview(icon)

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = NSFont.systemFont(ofSize: 16)
        field.textColor = th.foreground
        field.placeholderAttributedString = NSAttributedString(string: placeholder,
                                                               attributes: [.foregroundColor: th.dimText, .font: NSFont.systemFont(ofSize: 16)])
        field.delegate = self
        field.cell?.isScrollable = true
        panel.addSubview(field)

        scopeLabel.font = .systemFont(ofSize: 11.5)
        scopeLabel.textColor = th.dimText
        scopeLabel.alignment = .right
        scopeLabel.lineBreakMode = .byTruncatingHead
        scopeLabel.isHidden = true
        panel.addSubview(scopeLabel)

        list.palette = self
        panel.addSubview(list)
        filter("")
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// ⌘↩ runs the selected item's alternate (a new tab, for Go to Folder). The text system has no action for it,
    /// so it never reaches `control(_:textView:doCommandBy:)`; it's caught here, ahead of the menus.
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
        if mods == .command, e.keyCode == 36 || e.keyCode == 76 {
            runSelected(alternate: true)
            return true
        }
        return super.performKeyEquivalent(with: e)
    }

    // Clicking outside the panel dismisses it.
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if !panel.frame.contains(p) { dismiss(restoreFocus: true) }
    }

    override func layout() {
        super.layout()
        layoutPanel()
    }

    func layoutPanel() {
        let width = min(620, bounds.width - 40)
        let rows = min(maxRows, max(filtered.count, 1))
        let height = 52 + CGFloat(rows) * rowH + 12
        // Centered in the window at its full height, and kept there as it shrinks while typing, so the field
        // doesn't move.
        let fullHeight = 52 + CGFloat(maxRows) * rowH + 12
        let top = max(12, (bounds.height - fullHeight) / 2)
        panel.frame = NSRect(x: (bounds.width - width) / 2, y: top, width: width, height: height)
        panel.subviews.first?.frame = panel.bounds
        // NSVisualEffectView is not flipped; place subviews from the top.
        let h = panel.bounds.height
        // Icon and text share a center line (the field's text sits at the top of its frame).
        panel.viewWithTag(1)?.frame = NSRect(x: 16, y: h - 35, width: 18, height: 18)
        // A live list's scope shares the field's line, and never takes more than half of it.
        let scopeFull = (scopeLabel.stringValue as NSString).size(withAttributes: [.font: scopeLabel.font ?? .systemFont(ofSize: 11.5)]).width
        let scopeW = scopeLabel.isHidden ? 0 : min(ceil(scopeFull) + 8, (width - 58) / 2)
        field.frame = NSRect(x: 42, y: h - 37, width: width - 58 - (scopeW > 0 ? scopeW + 10 : 0), height: 22)
        scopeLabel.frame = NSRect(x: width - 16 - scopeW, y: h - 34, width: scopeW, height: 16)
        list.frame = NSRect(x: 6, y: 6, width: width - 12, height: h - 58)
        list.needsDisplay = true
    }

    // MARK: Data

    static func collectItems() -> [Item] {
        var out: [Item] = []
        func walk(_ menu: NSMenu, _ path: [String]) {
            menu.delegate?.menuNeedsUpdate?(menu)
            for item in menu.items {
                if item.isSeparatorItem || item.isHidden { continue }
                if let sub = item.submenu {
                    walk(sub, path + [item.title])
                    continue
                }
                guard let action = item.action,
                      action != #selector(TerminalWindowController.showCommandPalette(_:)) else { continue }
                guard let target = NSApp.target(forAction: action, to: item.target, from: item) else { continue }
                if let v = target as? NSMenuItemValidation, !v.validateMenuItem(item) { continue }
                let path = path.filter { !$0.isEmpty }.joined(separator: " › ")
                out.append(Item(title: item.title, path: path, shortcut: shortcutString(item)) { [weak item] in
                    guard let item else { return }
                    NSApp.sendAction(action, to: item.target, from: item)
                })
            }
        }
        if let main = NSApp.mainMenu {
            // App menu (About/Quit…) goes last so everyday commands appear first.
            let tops = Array(main.items.dropFirst()) + main.items.prefix(1)
            for top in tops {
                if let sub = top.submenu { walk(sub, [top.title == "" ? "Solanum" : top.title]) }
            }
        }
        return out
    }

    static func shortcutString(_ item: NSMenuItem) -> String {
        guard !item.keyEquivalent.isEmpty else { return "" }
        let m = item.keyEquivalentModifierMask
        var s = ""
        var key = item.keyEquivalent
        let impliedShift = key.count == 1 && key.uppercased() == key && key.lowercased() != key
        if m.contains(.control) { s += "⌃" }
        if m.contains(.option) { s += "⌥" }
        if m.contains(.shift) || impliedShift { s += "⇧" }
        if m.contains(.command) { s += "⌘" }
        switch key.unicodeScalars.first.map({ Int($0.value) }) ?? 0 {
        case NSUpArrowFunctionKey: key = "↑"
        case NSDownArrowFunctionKey: key = "↓"
        case NSLeftArrowFunctionKey: key = "←"
        case NSRightArrowFunctionKey: key = "→"
        case 0x09: key = "⇥"
        case 0x0D: key = "↩"
        case 0x20: key = "Space"
        default: key = key.uppercased()
        }
        return s + key
    }

    private static func score(_ query: [Character], _ text: String) -> Int? {
        let t = Array(text.lowercased())
        var ti = 0, total = 0, prev = -2
        for qc in query {
            var found = false
            while ti < t.count {
                if t[ti] == qc {
                    var s = 1
                    if ti == prev + 1 { s += 6 }
                    if ti == 0 || " ›:-/".contains(t[ti - 1]) { s += 8 }
                    total += s
                    prev = ti
                    ti += 1
                    found = true
                    break
                }
                ti += 1
            }
            if !found { return nil }
        }
        return total * 4 - t.count
    }

    private func filter(_ q: String) {
        if let onQuery { return onQuery(self, q) }
        let query = Array(q.lowercased().filter { $0 != " " })
        if goToMode {
            filtered = goToItems(q)
        } else if tracksRecents, let path = Self.goToPath(q) {
            filtered = goToItems(path)
        } else if query.isEmpty {
            filtered = allItems
            // With no query, the last few commands run go on top, then everything else.
            let recents = tracksRecents ? recentItems() : []
            if !recents.isEmpty {
                let keys = Set(recents.map(\.recentKey))
                filtered = [.header("Recently used")] + recents + [.header("All commands")] + allItems.filter { !keys.contains($0.recentKey) }
            }
        } else if keepsOrder {
            let needle = q.lowercased().trimmingCharacters(in: .whitespaces)
            var exact: [Item] = [], fuzzy: [Item] = []
            for it in allItems where !it.isHeader {
                if it.title.lowercased().contains(needle) { exact.append(it) }
                else if CommandPalette.score(query, it.title) != nil { fuzzy.append(it) }
            }
            filtered = exact + fuzzy
        } else {
            var scored: [(Item, Int)] = []
            for it in allItems {
                if let s = CommandPalette.score(query, it.title) {
                    scored.append((it, s + 20))
                } else if let s = CommandPalette.score(query, it.path + " " + it.title) {
                    scored.append((it, s))
                }
            }
            filtered = scored.sorted { $0.1 > $1.1 }.map { $0.0 }
        }
        selected = filtered.firstIndex { !$0.isHeader } ?? 0
        scrollTop = 0
        layoutPanel()
    }

    private func recentItems() -> [Item] {
        let keys = UserDefaults.standard.stringArray(forKey: CommandPalette.recentsKey) ?? []
        return keys.compactMap { k in allItems.first { $0.recentKey == k } }.prefix(CommandPalette.maxRecents).map { $0 }
    }

    private func recordRecent(_ item: Item) {
        // Only commands that will be there next time ("Go to:" folders aren't).
        guard tracksRecents, allItems.contains(where: { $0.recentKey == item.recentKey }) else { return }
        var keys = UserDefaults.standard.stringArray(forKey: CommandPalette.recentsKey) ?? []
        keys.removeAll { $0 == item.recentKey }
        keys.insert(item.recentKey, at: 0)
        // Keep a few spares so disabled commands don't shrink the list.
        UserDefaults.standard.set(Array(keys.prefix(CommandPalette.maxRecents * 3)), forKey: CommandPalette.recentsKey)
    }

    var visibleItems: ArraySlice<Item> {
        filtered[scrollTop..<min(filtered.count, scrollTop + maxRows)]
    }
    var visibleSelected: Int { selected - scrollTop }
    var rowHeight: CGFloat { rowH }

    private func move(_ d: Int) {
        guard filtered.contains(where: { !$0.isHeader }) else { return }
        repeat { selected = (selected + d + filtered.count) % filtered.count } while filtered[selected].isHeader
        // Keep a section header in view when stepping onto the first item under it.
        if selected > 0, filtered[selected - 1].isHeader, selected - 1 < scrollTop { scrollTop = selected - 1 }
        if selected < scrollTop { scrollTop = selected }
        if selected >= scrollTop + maxRows { scrollTop = selected - maxRows + 1 }
        list.needsDisplay = true
    }

    func hover(row: Int) {
        let i = scrollTop + row
        guard i < filtered.count, i != selected, !filtered[i].isHeader else { return }
        selected = i
        list.needsDisplay = true
    }

    func scrollList(by d: Int) {
        let maxTop = max(0, filtered.count - maxRows)
        scrollTop = max(0, min(maxTop, scrollTop + d))
        selected = max(scrollTop, min(selected, scrollTop + maxRows - 1))
        if filtered.indices.contains(selected), filtered[selected].isHeader, selected + 1 < filtered.count { selected += 1 }
        list.needsDisplay = true
    }

    func runSelected(alternate: Bool = false) {
        guard filtered.indices.contains(selected), !filtered[selected].isHeader else { return }
        let item = filtered[selected]
        recordRecent(item)
        dismiss(restoreFocus: true)
        let action = alternate ? item.alternate ?? item.run : item.run
        DispatchQueue.main.async { action() }
    }

    func dismiss(restoreFocus: Bool) {
        let w = window
        removeFromSuperview()
        if CommandPalette.current === self { CommandPalette.current = nil }
        if restoreFocus, let r = previousResponder { w?.makeFirstResponder(r) }
    }

    // MARK: Go to a folder

    static let goToPrefix = "Go to: "

    /// Dev aid (DevTools palette-run): Return in the open palette.
    static func devRunSelected() { current?.runSelected() }

    /// What follows "Go to:" (or "goto:"), as typed, when the query starts with it.
    static func goToPath(_ q: String) -> String? {
        let t = q.drop { $0 == " " }
        for p in ["go to:", "goto:"] where t.lowercased().hasPrefix(p) {
            return String(t.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// Where "Go to:" looks: this Mac, or the ssh host of the focused tab, whose folders are listed over its session.
    private struct GoToPlace {
        let remote: RemoteSession?
        let base: String
        let home: String
        let open: (String) -> Void
        /// A `cd` in the focused pane, when it's at a prompt (on the same host, for an ssh tab); nil when it can't take one.
        let here: ((String) -> Void)?
    }

    /// Folder listings from an ssh host, by path: nil while one is on its way.
    private var remoteListings: [String: [FileItem]?] = [:]

    private func goToPlace() -> GoToPlace {
        let controller = window?.windowController as? TerminalWindowController
            ?? NSApp.windows.lazy.compactMap { $0.windowController as? TerminalWindowController }.first
        let pane = controller?.activeTab?.focusedPane
        let here: ((String) -> Void)? = pane.flatMap { p in p.canChangeDirectory && p.hasStarted ? { [weak p] dir in _ = p?.changeDirectory(to: dir) } : nil }
        if let tab = controller?.activeTab, let remote = tab.browseRemote, remote.isReady, let home = remote.home {
            // A new tab logs in to the same host again, in that folder; here is only for a pane on that host.
            return GoToPlace(remote: remote, base: tab.browseDirectory ?? home, home: home, open: { [weak controller] dir in
                let pane = controller?.addTab(cwd: nil).focusedPane
                pane?.pendingCommand = remote.reconnectCommand(in: dir)
            }, here: pane?.remote === remote ? here : nil)
        }
        return GoToPlace(remote: nil, base: controller?.focused.currentLocalFolder ?? NSHomeDirectory(), home: NSHomeDirectory(),
                         open: { [weak controller] dir in controller?.addTab(cwd: dir) },
                         here: pane?.remote == nil ? here : nil)
    }

    /// `p` with `.` and `..` worked out, without looking at the disk (it may be another machine's).
    private static func normalized(_ p: String) -> String {
        var parts: [Substring] = []
        for c in p.split(separator: "/") {
            if c == "." { continue }
            if c == ".." { if !parts.isEmpty { parts.removeLast() }; continue }
            parts.append(c)
        }
        return "/" + parts.joined(separator: "/")
    }

    /// The folders in `dir`, or nil while an ssh host's are on their way (the list is redone when they come).
    private func folders(in dir: String, _ place: GoToPlace) -> [String]? {
        guard let remote = place.remote else {
            let fm = FileManager.default
            return ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter {
                var d: ObjCBool = false
                return fm.fileExists(atPath: (dir as NSString).appendingPathComponent($0), isDirectory: &d) && d.boolValue
            }
        }
        if let listed = remoteListings[dir] { return listed.map { $0.filter(\.isDirectory).map(\.name) } }
        remoteListings[dir] = .some(nil)
        remote.list(dir) { [weak self] result in
            guard let self else { return }
            self.remoteListings[dir] = (try? result.get()) ?? []
            if self.goToMode || Self.goToPath(self.field.stringValue) != nil { self.filter(self.field.stringValue) }
        }
        return nil
    }

    /// Whether `path` is a folder; nil while that's not known yet.
    private func isFolder(_ path: String, _ place: GoToPlace) -> Bool? {
        guard place.remote != nil else {
            var d: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &d) && d.boolValue
        }
        if path == "/" { return true }
        let parent = (path as NSString).deletingLastPathComponent, name = (path as NSString).lastPathComponent
        return folders(in: parent.isEmpty ? "/" : parent, place)?.contains(name)
    }

    /// For "Go to: <path>": open that folder in a new tab, with the folders that start with what's typed so far as
    /// suggestions (Tab goes into one, ".." up). Relative paths start at the terminal's folder. On an ssh tab, it's
    /// that host's folders, and the new tab is logged in there too.
    private func goToItems(_ raw: String) -> [Item] {
        let place = goToPlace()
        // Pasted from a shell: quotes around it, or backslash-escaped spaces.
        var typed = raw.replacingOccurrences(of: "\\ ", with: " ")
        if typed.count >= 2, let f = typed.first, f == typed.last, f == "\"" || f == "'" { typed = String(typed.dropFirst().dropLast()) }
        func resolve(_ p: String) -> String {
            let e = p == "~" ? place.home : p.hasPrefix("~/") ? place.home + p.dropFirst(1) : p
            return Self.normalized(e.hasPrefix("/") ? e : place.base + "/" + e)
        }
        func shown(_ p: String) -> String {
            let short = FilePaths.abbreviate(p, home: place.home)
            return place.remote?.hostLabel.map { "\($0):\(short)" } ?? short
        }
        // Return opens where the terminal is, ⌘Return a new tab; with no terminal to cd in, Return is a new tab.
        let open: (String) -> Void = place.here ?? place.open
        let alternate: ((String) -> (() -> Void))? = place.here == nil ? nil : { dir in { place.open(dir) } }

        var out: [Item] = []
        let target = resolve(typed.isEmpty ? "." : typed)
        let folder = isFolder(target, place)
        if folder == true {
            if place.here != nil {
                var item = Item(title: "Open \(shown(target)) Here", path: "cd in this tab", shortcut: "↩", run: { open(target) })
                item.alternate = alternate?(target)
                out.append(item)
                out.append(Item(title: "Open \(shown(target)) in a New Tab", path: place.remote == nil ? "" : "signs in again", shortcut: "⌘↩",
                                run: { place.open(target) }))
            } else {
                out.append(Item(title: "Open \(shown(target)) in a New Tab", path: "Go to", shortcut: "↩", run: { open(target) }))
            }
        }
        // Suggestions: inside the folder when the path ends at one ("~/Projects/" or nothing typed), otherwise
        // the folders next to it whose names start with its last part.
        let inside = typed.isEmpty || typed.hasSuffix("/") || (folder == true && typed.hasSuffix("."))
        let parent = inside ? target : (target as NSString).deletingLastPathComponent.isEmpty ? "/" : (target as NSString).deletingLastPathComponent
        let stem = inside ? "" : (typed as NSString).lastPathComponent.lowercased()
        let typedParent = typed.isEmpty || typed.hasSuffix("/") ? typed
            : typed.contains("/") ? String(typed[...typed.lastIndex(of: "/")!]) : ""
        guard let listed = folders(in: parent, place) else {
            out.append(.header("Loading \(shown(parent))…"))
            return out
        }
        let names = listed
            .filter { $0.lowercased().hasPrefix(stem) && ($0.hasPrefix(".") == stem.hasPrefix(".")) }
            .filter { inside || $0.lowercased() != stem }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .prefix(30)
        if inside, parent != "/" {
            // Up a level, staying in the browser.
            var up = Item(title: "..", path: "Parent folder", shortcut: "⇥") { [weak window] in
                guard let window else { return }
                let above = (parent as NSString).deletingLastPathComponent
                CommandPalette.showGoTo(in: window, path: FilePaths.abbreviate(above.isEmpty ? "/" : above, home: place.home) + (above == "/" ? "" : "/"))
            }
            up.completion = typedParent + "../"
            if out.isEmpty { out.append(.header("In \(shown(parent))")) }
            out.append(up)
        }
        if !names.isEmpty {
            out.append(.header(inside ? "In \(shown(parent))" : "Folders"))
            for n in names {
                let dir = parent == "/" ? "/" + n : parent + "/" + n
                var item = Item(title: n, path: shown(parent), shortcut: "⇥", run: { open(dir) })
                item.alternate = alternate?(dir)
                item.completion = typedParent + n + "/"
                out.append(item)
            }
        }
        if out.isEmpty || (out.count == 1 && out[0].isHeader) { out.append(.header("No folder at \(shown(target))")) }
        return out
    }

    /// Into the selected "Go to:" folder (Tab, or a click), to look around before opening one.
    func completeSelected() {
        guard filtered.indices.contains(selected), let c = filtered[selected].completion else { return }
        let text = (goToMode ? "" : Self.goToPrefix) + c
        field.stringValue = text
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        filter(text)
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        filter(field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveUp(_:)): move(-1); return true
        case #selector(NSResponder.moveDown(_:)): move(1); return true
        case #selector(NSResponder.insertNewline(_:)):
            runSelected(alternate: NSApp.currentEvent?.modifierFlags.contains(.command) == true)
            return true
        case #selector(NSResponder.cancelOperation(_:)): dismiss(restoreFocus: true); return true
        case #selector(NSResponder.insertTab(_:)):
            completeSelected()
            return true
        default: return false
        }
    }
}

final class PaletteList: NSView {
    weak var palette: CommandPalette?
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let p = palette else { return }
        let th = Config.shared.theme
        let items = Array(p.visibleItems)
        if items.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: th.dimText]
            (p.emptyMessage as NSString).draw(at: NSPoint(x: 14, y: 9), withAttributes: attrs)
            return
        }
        // Divider under the search field
        th.border.setFill()
        NSRect(x: 4, y: 0, width: bounds.width - 8, height: 1).fill()
        for (i, item) in items.enumerated() {
            let r = NSRect(x: 0, y: 4 + CGFloat(i) * p.rowHeight, width: bounds.width, height: p.rowHeight)
            if item.isHeader {
                // Section label sitting low in its row, with a hairline above all but the first.
                let hAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: th.dimText]
                let label = (item.keepsCase ? item.title : item.title.uppercased()) as NSString
                let hs = label.size(withAttributes: hAttrs)
                label.draw(at: NSPoint(x: 14, y: r.maxY - hs.height - 6), withAttributes: hAttrs)
                if i > 0 {
                    th.border.setFill()
                    NSRect(x: 10, y: r.minY + 8, width: r.width - 20, height: 1).fill()
                }
                continue
            }
            if i == p.visibleSelected {
                th.accent.withAlphaComponent(0.20).setFill()
                NSBezierPath(roundedRect: r.insetBy(dx: 2, dy: 1), xRadius: 7, yRadius: 7).fill()
            }
            let truncate = NSMutableParagraphStyle()
            truncate.lineBreakMode = .byTruncatingTail
            var right = r.maxX - 12
            if !item.shortcut.isEmpty {
                let kAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11.5, weight: .medium), .foregroundColor: th.foreground.withAlphaComponent(0.7)]
                let ks = (item.shortcut as NSString).size(withAttributes: kAttrs)
                let kr = NSRect(x: right - ks.width - 12, y: r.midY - 10, width: ks.width + 12, height: 20)
                th.foreground.withAlphaComponent(0.08).setFill()
                NSBezierPath(roundedRect: kr, xRadius: 5, yRadius: 5).fill()
                (item.shortcut as NSString).draw(at: NSPoint(x: kr.minX + 6, y: kr.midY - ks.height / 2), withAttributes: kAttrs)
                right = kr.minX - 10
            }
            // Long titles end in "…" so the path stays visible; the title keeps at least half the row.
            // A line of a file is in the terminal's font, with what was searched for picked out.
            let titleFont = item.highlight == nil ? NSFont.systemFont(ofSize: 13.5, weight: .medium)
                : NSFont(descriptor: (FontSet.current.regular as NSFont).fontDescriptor, size: 12.5) ?? .monospacedSystemFont(ofSize: 12.5, weight: .regular)
            let titleAttrs: [NSAttributedString.Key: Any] = [.font: titleFont, .foregroundColor: th.foreground, .paragraphStyle: truncate]
            let title = NSMutableAttributedString(string: item.title, attributes: titleAttrs)
            if let h = item.highlight {
                var from = item.title.startIndex
                while let m = item.title.range(of: h, options: .caseInsensitive, range: from..<item.title.endIndex), !m.isEmpty {
                    let ns = NSRange(m, in: item.title)
                    title.addAttributes([.foregroundColor: th.accent, .backgroundColor: th.accent.withAlphaComponent(0.18)], range: ns)
                    from = m.upperBound
                }
            }
            let ts = title.size()
            let pAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: th.dimText, .paragraphStyle: truncate]
            let ps = item.path.isEmpty ? .zero : (item.path as NSString).size(withAttributes: pAttrs)
            var titleMax = right - 14
            if !item.path.isEmpty { titleMax = max(titleMax / 2, titleMax - ps.width - 16) }
            let tw = min(ts.width, titleMax)
            title.draw(in: NSRect(x: 14, y: r.midY - ts.height / 2, width: tw, height: ts.height))

            if !item.path.isEmpty {
                let x = max(14 + tw + 16, right - ps.width)
                if x + 20 < right {
                    (item.path as NSString).draw(in: NSRect(x: x, y: r.midY - ps.height / 2, width: right - x, height: ps.height), withAttributes: pAttrs)
                }
            }
        }
    }

    private func row(at e: NSEvent) -> Int? {
        guard let p = palette else { return nil }
        let pt = convert(e.locationInWindow, from: nil)
        let r = Int((pt.y - 4) / p.rowHeight)
        return r >= 0 && r < p.visibleItems.count ? r : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === self }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .cursorUpdate, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    // The arrow over the list. It floats over the terminal (and maybe a sidebar), whose I-beam would show through:
    // the window's cursor rects are off while the mouse is here, as for the find bar.
    private var mouseInside = false {
        didSet {
            guard mouseInside != oldValue else { return }
            if mouseInside { window?.disableCursorRects() } else { window?.enableCursorRects() }
            NSCursor.arrow.set()
            if !mouseInside { window?.resetCursorRects() }
        }
    }

    override func mouseEntered(with e: NSEvent) { mouseInside = true }
    override func mouseExited(with e: NSEvent) { mouseInside = false }
    override func cursorUpdate(with e: NSEvent) { NSCursor.arrow.set() }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { mouseInside = false }
        super.viewWillMove(toWindow: newWindow)
    }

    override func mouseMoved(with e: NSEvent) {
        NSCursor.arrow.set()
        if let r = row(at: e) { palette?.hover(row: r) }
    }

    override func mouseDown(with e: NSEvent) {
        if let r = row(at: e), let p = palette, !p.visibleItems[p.visibleItems.startIndex + r].isHeader {
            p.hover(row: r)
            // A "Go to:" folder: a click goes into it, to keep looking; Return is what opens one.
            if p.visibleItems[p.visibleItems.startIndex + r].completion != nil { return p.completeSelected() }
            p.runSelected(alternate: e.modifierFlags.contains(.command))
        }
    }

    override func scrollWheel(with e: NSEvent) {
        let d = e.scrollingDeltaY
        if abs(d) > 2 { palette?.scrollList(by: d > 0 ? -1 : 1) }
    }
}
