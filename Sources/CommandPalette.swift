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
    private let rowH: CGFloat = 34

    static func toggle(in window: NSWindow) {
        if let c = current, c.window === window {
            c.dismiss(restoreFocus: true)
            return
        }
        show(in: window, items: collectItems(), tracksRecents: true)
    }

    /// Opens the palette over a custom list (e.g. prompts to jump to).
    static func show(in window: NSWindow, items: [Item], placeholder: String = "Type a command, theme, or snippet…",
                     tracksRecents: Bool = false, keepsOrder: Bool = false, icon: String = "command") {
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

        list.palette = self
        panel.addSubview(list)
        filter("")
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

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
        let top: CGFloat = min(90, bounds.height * 0.14)
        panel.frame = NSRect(x: (bounds.width - width) / 2, y: top, width: width, height: height)
        panel.subviews.first?.frame = panel.bounds
        // NSVisualEffectView is not flipped; place subviews from the top.
        let h = panel.bounds.height
        // Icon and text share a center line (the field's text sits at the top of its frame).
        panel.viewWithTag(1)?.frame = NSRect(x: 16, y: h - 35, width: 18, height: 18)
        field.frame = NSRect(x: 42, y: h - 37, width: width - 58, height: 22)
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
        let query = Array(q.lowercased().filter { $0 != " " })
        if query.isEmpty {
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
        guard tracksRecents else { return }
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
            ("No matching commands" as NSString).draw(at: NSPoint(x: 14, y: 9), withAttributes: attrs)
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
                let hs = (item.title.uppercased() as NSString).size(withAttributes: hAttrs)
                (item.title.uppercased() as NSString).draw(at: NSPoint(x: 14, y: r.maxY - hs.height - 6), withAttributes: hAttrs)
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
            let titleAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13.5, weight: .medium), .foregroundColor: th.foreground, .paragraphStyle: truncate]
            let title = item.title as NSString
            let ts = title.size(withAttributes: titleAttrs)
            let pAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: th.dimText, .paragraphStyle: truncate]
            let ps = item.path.isEmpty ? .zero : (item.path as NSString).size(withAttributes: pAttrs)
            var titleMax = right - 14
            if !item.path.isEmpty { titleMax = max(titleMax / 2, titleMax - ps.width - 16) }
            let tw = min(ts.width, titleMax)
            title.draw(in: NSRect(x: 14, y: r.midY - ts.height / 2, width: tw, height: ts.height), withAttributes: titleAttrs)

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
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with e: NSEvent) {
        if let r = row(at: e) { palette?.hover(row: r) }
    }

    override func mouseDown(with e: NSEvent) {
        if let r = row(at: e), let p = palette, !p.visibleItems[p.visibleItems.startIndex + r].isHeader {
            palette?.hover(row: r)
            palette?.runSelected()
        }
    }

    override func scrollWheel(with e: NSEvent) {
        let d = e.scrollingDeltaY
        if abs(d) > 2 { palette?.scrollList(by: d > 0 ? -1 : 1) }
    }
}
