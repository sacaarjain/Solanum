import AppKit

// A dropdown in Solanum's own colors, drawn here rather than by AppKit's NSMenu, so it looks the same as the rest
// of the app (and as the Windows build's, which draws its own): a rounded panel under the button that opened it,
// check marks in the accent color, section headers and lines between groups. Long lists scroll, and a field at the
// top narrows any of them (focused from the start, so typing filters). ↑ / ↓ move, ↩ picks, Esc or a click outside closes it.

struct DropdownItem {
    enum Kind { case item, header, separator }
    var kind: Kind = .item
    var title = ""
    var checked = false
    var action: (() -> Void)?
    /// An SF Symbol drawn where the check mark goes.
    var symbol: String?
    /// Dim text after the title ("as sjain"); the filter matches it too.
    var detail: String?
    /// What ⌥-click or ⌥↩ does instead (connect in this pane rather than a new tab, say).
    var optionAction: (() -> Void)?
    /// Said in place of `detail`, in the accent color, while ⌥ is held ("open in this pane").
    var optionDetail: String?
    /// A dot of this color where the check mark goes (a tab group's color); checked, it's ringed instead of ticked.
    var color: NSColor?
    /// Picking it doesn't close the dropdown: the search field gets this text instead ("ssh ", to type a host after).
    var fill: String?

    static func item(_ title: String, checked: Bool = false, symbol: String? = nil, detail: String? = nil, color: NSColor? = nil,
                     option: (() -> Void)? = nil, optionDetail: String? = nil, _ action: @escaping () -> Void) -> DropdownItem {
        DropdownItem(kind: .item, title: title, checked: checked, action: action, symbol: symbol, detail: detail, optionAction: option,
                     optionDetail: optionDetail, color: color)
    }
    static func fill(_ title: String, symbol: String? = nil, _ text: String) -> DropdownItem {
        DropdownItem(kind: .item, title: title, symbol: symbol, fill: text)
    }
    static func header(_ title: String) -> DropdownItem { DropdownItem(kind: .header, title: title) }
    static let separator = DropdownItem(kind: .separator)
}

/// How it behaves (filtering, the highlight, the arrows) is Core's (Dropdown), shared with the Windows build's menus.
extension DropdownItem: DropdownRow {
    var dropdownKind: DropdownRowKind {
        switch kind {
        case .item: return .item
        case .header: return .header
        case .separator: return .separator
        }
    }
    var isChecked: Bool { checked }
    var isEnabled: Bool { true }
}

/// A button a dropdown opens from: it shows pressed while its dropdown is open, and a second click while the list
/// is still being fetched (from git, say) cancels it instead of opening it late.
protocol DropdownAnchor: AnyObject {
    /// Whether a dropdown asked for may still open under it.
    var dropdownWanted: Bool { get }
    var dropdownOpen: Bool { get set }
}

/// Covers the window while open (a click anywhere outside the panel closes it, and still reaches what it's on); the panel sits under the anchor.
final class ThemedDropdown: NSView, NSTextFieldDelegate, WindowOverlay {
    private static weak var current: ThemedDropdown?
    /// Dev aid: the last dropdown's items (headless runs print them instead of showing anything).
    static var devLastItems: [DropdownItem] = []

    private let panel = DropdownPanel()
    private let scroll = NSScrollView()
    private let list = DropdownListView()
    private let field = NSTextField()
    private let all: [DropdownItem]
    private let searchable: Bool
    private weak var previous: NSResponder?
    /// The button it opened from: a click there only closes it (rather than closing and opening it again).
    private weak var anchor: NSView?
    /// The part of `anchor` that's the button (all of it, unless the button is drawn inside a bigger view).
    private var anchorRect: NSRect = .zero
    /// Opened upward (no room below, as from the status bar): the panel keeps its bottom edge as it shrinks.
    private var above = false
    private var anchorEdge: CGFloat = 0
    /// The tallest the panel may be where it is (it shrinks to fit what the filter leaves).
    private var tallest: CGFloat = 0
    /// Typed before what's searched for, and left out of the search ("ssh " in the hosts dropdown).
    private var prefix: String?
    /// Rows made from what's typed, above the matches (connecting to a host that isn't listed, say).
    private var extra: ((String) -> [DropdownItem])?
    /// While open: ⌥ going down or up switches the rows to what ⌥ does (see `DropdownItem.optionDetail`).
    private var flagsMonitor: Any?

    static let rowHeight: CGFloat = 26
    private static let fieldHeight: CGFloat = 34
    private static let maxHeight: CGFloat = 420

    /// Opens under `anchor` (its left edge, or right-aligned when it'd run off the window), or over it when there's
    /// more room there. `rect`: the button within `anchor`, when it's drawn inside a bigger view (the status bar).
    /// `placeholder`: what the filter field says while empty. `searchable`: false for a short menu of actions, with no
    /// filter field (↑ / ↓ and ↩ still work).
    /// `prefix` and `extra`: see their properties.
    static func show(_ items: [DropdownItem], under anchor: NSView, rect: NSRect? = nil, minWidth: CGFloat = 200, placeholder: String = "Filter",
                     searchable: Bool = true, prefix: String? = nil, extra: ((String) -> [DropdownItem])? = nil) {
        if let a = anchor as? DropdownAnchor, !a.dropdownWanted { return }
        devLastItems = items
        // A view in the window, not a menu with its own event loop, so headless runs show it too (and print it).
        if Headless.active {
            FileHandle.standardError.write("dropdown: \(items.map { $0.kind == .separator ? "---" : ($0.checked ? "✓ " : "") + $0.title })\n".data(using: .utf8)!)
        }
        current?.dismiss()
        guard let window = anchor.window, let content = window.contentView else { return }
        // The field is focused from the start: typing narrows the list straight away.
        let d = ThemedDropdown(items, searchable: searchable, placeholder: placeholder, previous: window.firstResponder)
        d.frame = content.bounds
        d.autoresizingMask = [.width, .height]
        d.prefix = prefix
        d.extra = extra
        content.addSubview(d)
        d.anchor = anchor
        d.anchorRect = rect ?? anchor.bounds
        current = d
        d.place(under: anchor, minWidth: minWidth)
        window.makeFirstResponder(d.searchable ? d.field : d)
        (anchor as? DropdownAnchor)?.dropdownOpen = true
        d.slideIn()
        d.coverChanged()
    }

    /// Where the panel is, so resize strips under it (the sidebar's edge) don't show their ↔ cursor through it.
    var coveredRects: [NSRect] {
        guard superview != nil else { return [] }
        return [convert(panel.frame.insetBy(dx: -10, dy: -10), to: superview)]
    }

    private func coverChanged(in root: NSView? = nil) { ((root ?? superview) as? WindowRootView)?.overlaysChanged() }

    // An arrow over the panel (but the text cursor over the search field): what's under it doesn't get a say.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === self }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    override func cursorUpdate(with e: NSEvent) { setCursor(e) }
    override func mouseMoved(with e: NSEvent) { setCursor(e); super.mouseMoved(with: e) }

    private func setCursor(_ e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        guard panel.frame.contains(p) else { return }
        (searchable && convert(field.frame, from: panel).contains(p) ? NSCursor.iBeam : NSCursor.arrow).set()
    }

    /// Closes whichever dropdown is open.
    static func dismissCurrent() { current?.dismiss() }

    /// Opening: the panel fades in, sliding down a little from under its button.
    private func slideIn() {
        let end = panel.frame
        panel.alphaValue = 0
        panel.frame.origin.y += above ? 8 : -8
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrameOrigin(end.origin)
        }
    }

    /// Dev aid: types `text` as the keyboard would (to whatever has it), then prints the rows left.
    static func devType(_ text: String) {
        guard let d = current, let w = d.window else { return }
        for ch in text {
            guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: w.windowNumber, context: nil, characters: String(ch),
                                           charactersIgnoringModifiers: String(ch), isARepeat: false, keyCode: 0) else { continue }
            w.firstResponder?.keyDown(with: e)
        }
        let rows = d.list.items.filter { $0.kind == .item }.map(\.title)
        FileHandle.standardError.write("dropdown filter \"\(d.field.stringValue)\": \(rows.count) \(rows.prefix(6))\n".data(using: .utf8)!)
    }

    /// Dev aid: the open dropdown as it looks while ⌥ is held.
    static func devHoldOption() { current?.list.optionHeld = true }

    deinit { if let m = flagsMonitor { NSEvent.removeMonitor(m) } }

    /// Dev aid: picks the last dropdown's item called `title`.
    static func devRun(_ title: String) {
        // As a click would: through the open dropdown (closing it first), else straight from its items.
        if let d = current, let i = d.list.items.firstIndex(where: { $0.kind == .item && $0.title == title }) { return d.pick(i) }
        devLastItems.first { $0.kind == .item && $0.title == title }?.action?()
    }

    private init(_ items: [DropdownItem], searchable: Bool, placeholder: String, previous: NSResponder?) {
        all = items
        self.searchable = searchable
        self.previous = previous
        super.init(frame: .zero)
        addSubview(panel)
        scroll.documentView = list
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        panel.addSubview(scroll)
        list.items = items
        list.onPick = { [weak self] i, option in self?.pick(i, option: option) }
        if searchable {
            let cell = CenteredTextFieldCell(textCell: "")
            cell.horizontalInset = 26
            field.cell = cell
            field.isEditable = true
            field.isBordered = false
            field.drawsBackground = false
            field.focusRingType = .none
            field.font = .systemFont(ofSize: 12.5)
            field.textColor = Config.shared.theme.foreground
            field.placeholderAttributedString = NSAttributedString(string: placeholder,
                                                                   attributes: [.foregroundColor: Config.shared.theme.dimText, .font: NSFont.systemFont(ofSize: 12.5)])
            field.delegate = self
            field.cell?.isScrollable = true
            panel.addSubview(field)
            panel.searchField = field
        }
        list.highlighted = Dropdown.initialHighlight(list.items)
        if items.contains(where: { $0.optionDetail != nil }) {
            list.optionHeld = NSEvent.modifierFlags.contains(.option)
            flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
                self?.list.optionHeld = e.modifierFlags.contains(.option)
                return e
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private func place(under anchor: NSView, minWidth: CGFloat) {
        let a = convert(anchorRect, from: anchor)
        let font = NSFont.systemFont(ofSize: 13), small = NSFont.systemFont(ofSize: 11.5)
        let widest = all.prefix(400).map { item -> CGFloat in
            let t = (item.title as NSString).size(withAttributes: [.font: font]).width
            let d = [item.detail, item.optionDetail].compactMap { $0 }.map { ($0 as NSString).size(withAttributes: [.font: small]).width + 8 }.max()
            return t + (d ?? 0)
        }.max() ?? 0
        let w = min(max(minWidth, a.width, ceil(widest) + 56), bounds.width - 16)
        let listH = list.contentHeight
        let top = searchable ? Self.fieldHeight + 6 : 6
        let roomBelow = bounds.height - a.maxY - 12, roomAbove = a.minY - 12
        above = roomBelow < min(top + listH + 6, Self.maxHeight) && roomAbove > roomBelow
        anchorEdge = above ? a.minY - 4 : a.maxY + 4
        tallest = min(Self.maxHeight * (above ? 1.6 : 1), max(above ? roomAbove : roomBelow, 120))
        let h = min(top + listH + 6, tallest)
        var x = a.minX
        if x + w > bounds.width - 8 { x = max(8, a.maxX - w) }
        panel.frame = NSRect(x: x, y: above ? anchorEdge - h : anchorEdge, width: w, height: h)
        if searchable { field.frame = NSRect(x: 8, y: 8, width: w - 16, height: Self.fieldHeight - 8) }
        scroll.frame = NSRect(x: 0, y: top, width: w, height: h - top - 6)
        list.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: listH)
        scrollToHighlighted()
    }

    /// `option`: ⌥ was held, for the item's other action when it has one.
    private func pick(_ i: Int, option: Bool = false) {
        guard list.items.indices.contains(i), list.items[i].kind == .item else { return }
        let item = list.items[i]
        if let fill = item.fill, searchable {
            field.stringValue = fill
            window?.makeFirstResponder(field)
            field.currentEditor()?.selectedRange = NSRange(location: (fill as NSString).length, length: 0)
            controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
            return
        }
        let action = option ? item.optionAction ?? item.action : item.action
        dismiss()
        action?()
    }

    private var optionHeld: Bool { NSApp.currentEvent?.modifierFlags.contains(.option) ?? false }

    func dismiss() {
        if let m = flagsMonitor { NSEvent.removeMonitor(m); flagsMonitor = nil }
        let w = window, root = superview
        (anchor as? DropdownAnchor)?.dropdownOpen = false
        if Headless.active, superview != nil { FileHandle.standardError.write("dropdown: closed\n".data(using: .utf8)!) }
        removeFromSuperview()
        coverChanged(in: root)
        if let previous, previous !== field, previous !== self { w?.makeFirstResponder(previous) }
    }

    override func mouseDown(with e: NSEvent) {
        // Outside the panel: close, and the click goes on to what's under it (another filter button opens its own
        // dropdown in one click), except on the button this opened from, which just closes it.
        guard !panel.frame.contains(convert(e.locationInWindow, from: nil)) else { return }
        let w = window
        let onAnchor = anchor.map { anchorRect.contains($0.convert(e.locationInWindow, from: nil)) } ?? false
        dismiss()
        // Delivered as the window would (re-sending the event from inside its own handling doesn't reach anything).
        guard !onAnchor, let w, let root = w.contentView?.superview ?? w.contentView,
              let v = root.hitTest(root.convert(e.locationInWindow, from: nil)) else { return }
        if v.acceptsFirstResponder { w.makeFirstResponder(v) }
        v.mouseDown(with: e)
    }

    override func scrollWheel(with e: NSEvent) {}

    private func move(_ d: Int) {
        if let i = Dropdown.step(list.items, from: list.highlighted, by: d) {
            list.highlighted = i
            scrollToHighlighted()
        }
    }

    private func scrollToHighlighted() {
        guard let i = list.highlighted else { return }
        list.scrollToVisible(list.rect(ofRow: i).insetBy(dx: 0, dy: -4))
    }

    override func keyDown(with e: NSEvent) {
        switch e.keyCode {
        case 125: move(1)
        case 126: move(-1)
        case 36, 76: if let i = list.highlighted { pick(i, option: e.modifierFlags.contains(.option)) }
        case 53: dismiss()
        default:
            // Typing while the field doesn't have the keyboard (after a click on the panel, say) still goes there.
            guard searchable, let chars = e.characters, !chars.isEmpty,
                  e.modifierFlags.intersection([.command, .control]).isEmpty,
                  chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return super.keyDown(with: e) }
            window?.makeFirstResponder(field)
            field.currentEditor()?.insertText(chars)
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        var q = field.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        if let p = prefix?.lowercased() {
            let bare = p.trimmingCharacters(in: .whitespaces)
            if q == bare { q = "" } else if q.hasPrefix(p) { q = q.dropFirst(p.count).trimmingCharacters(in: .whitespaces) }
        }
        let made = extra?(field.stringValue) ?? []
        // Only the prefix typed ("ssh ", from New Connection…): the whole list, less what fills the field, and
        // nothing picked yet, so ↩ doesn't connect to the first host by surprise.
        let onlyPrefix = q.isEmpty && !field.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
        if q.isEmpty {
            let rest = onlyPrefix ? Array(all.drop { $0.fill != nil || $0.kind == .separator }) : all
            list.items = made + (made.isEmpty ? [] : [.separator]) + rest
        } else {
            // Just the matching items (with no headers or lines between, which only grouped the full list).
            // What's typed, made into rows, comes after anything it matches ("ssh lanode2" → lanode23 first).
            list.items = Dropdown.filter(all.filter { $0.fill == nil }, query: q) + made
        }
        list.highlighted = onlyPrefix && made.isEmpty ? nil : Dropdown.firstPickable(list.items, from: 0, by: 1)
        list.frame.size.height = list.contentHeight
        let top = Self.fieldHeight + 6
        panel.frame.size.height = min(top + list.contentHeight + 6, tallest)
        if above { panel.frame.origin.y = anchorEdge - panel.frame.height }
        scroll.frame.size.height = panel.frame.height - top - 6
        list.frame.size.width = scroll.contentSize.width
        scrollToHighlighted()
        coverChanged()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): move(1)
        case #selector(NSResponder.moveUp(_:)): move(-1)
        case #selector(NSResponder.insertNewline(_:)): if let i = list.highlighted { pick(i, option: optionHeld) }
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)): if let i = list.highlighted { pick(i, option: true) }
        case #selector(NSResponder.cancelOperation(_:)): dismiss()
        default: return false
        }
        return true
    }
}

/// The rounded panel itself: lifted off the background, with a border and a shadow, and a box behind the filter field.
final class DropdownPanel: NSView {
    weak var searchField: NSTextField? { didSet { tint.searchField = searchField } }
    /// Frosted like the command palette: what's behind shows through blurred, under a wash of the theme's background.
    private let blur = NSVisualEffectView()
    private let tint = DropdownTint()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowOpacity = 0.4
        layer?.shadowRadius = 14
        layer?.shadowOffset = CGSize(width: 0, height: -4)
        blur.material = .popover
        blur.blendingMode = .withinWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 10
        blur.layer?.masksToBounds = true
        blur.layer?.borderWidth = 1
        blur.autoresizingMask = [.width, .height]
        tint.autoresizingMask = [.width, .height]
        blur.addSubview(tint)
        addSubview(blur)
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        blur.frame = bounds
        tint.frame = blur.bounds
        // The shadow follows the rounded panel (its own layer draws nothing to cast one from).
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 10, cornerHeight: 10, transform: nil)
    }

    func applyTheme() {
        let th = Config.shared.theme
        blur.appearance = NSAppearance(named: th.isDark ? .darkAqua : .aqua)
        blur.layer?.borderColor = th.border.cgColor
        tint.layer?.backgroundColor = th.background.withAlphaComponent(0.55).cgColor
        tint.needsDisplay = true
    }

    // Clicks inside stay inside (the cover behind closes on the ones outside).
    override func mouseDown(with e: NSEvent) {}
}

/// The panel's wash of color over the blur, and the box behind the filter field.
final class DropdownTint: NSView {
    weak var searchField: NSTextField? { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let f = searchField?.frame else { return }
        let th = Config.shared.theme
        let box = NSBezierPath(roundedRect: f, xRadius: 6, yRadius: 6)
        th.foreground.withAlphaComponent(0.06).setFill()
        box.fill()
        th.border.setStroke()
        box.stroke()
        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium).applying(.init(paletteColors: [th.dimText]))
        if let img = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
            img.draw(in: NSRect(x: f.minX + 8, y: f.midY - img.size.height / 2, width: img.size.width, height: img.size.height))
        }
    }
}

final class DropdownListView: NSView {
    var items: [DropdownItem] = [] { didSet { needsDisplay = true } }
    var highlighted: Int? { didSet { if highlighted != oldValue { needsDisplay = true } } }
    /// ⌥ is down: rows with an `optionDetail` say it instead of their detail.
    var optionHeld = false { didSet { if optionHeld != oldValue { needsDisplay = true } } }
    /// The row, and whether ⌥ was held.
    var onPick: ((Int, Bool) -> Void)?
    private static let separatorHeight: CGFloat = 11
    private static let headerHeight: CGFloat = 24

    override var isFlipped: Bool { true }

    private func height(_ item: DropdownItem) -> CGFloat {
        switch item.kind {
        case .item: return ThemedDropdown.rowHeight
        case .header: return Self.headerHeight
        case .separator: return Self.separatorHeight
        }
    }

    /// With nothing left after filtering, one row's room for "No matches".
    var contentHeight: CGFloat { items.isEmpty ? ThemedDropdown.rowHeight : items.reduce(0) { $0 + height($1) } }

    func rect(ofRow i: Int) -> NSRect {
        let y = items.prefix(i).reduce(0) { $0 + height($1) }
        return NSRect(x: 0, y: y, width: bounds.width, height: items.indices.contains(i) ? height(items[i]) : 0)
    }

    private func row(at p: NSPoint) -> Int? {
        var y: CGFloat = 0
        for (i, item) in items.enumerated() {
            let h = height(item)
            if p.y >= y, p.y < y + h { return item.kind == .item ? i : nil }
            y += h
        }
        return nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === self }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with e: NSEvent) {
        if let r = row(at: convert(e.locationInWindow, from: nil)) { highlighted = r }
    }

    override func mouseDown(with e: NSEvent) {}

    override func mouseUp(with e: NSEvent) {
        if let r = row(at: convert(e.locationInWindow, from: nil)) { onPick?(r, e.modifierFlags.contains(.option)) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let th = Config.shared.theme
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        // Items too long for the panel lose their middle, keeping where a path starts and the file it names.
        let middle = NSMutableParagraphStyle()
        middle.lineBreakMode = .byTruncatingMiddle
        if items.isEmpty {
            ("No matches" as NSString).draw(in: NSRect(x: 34, y: ThemedDropdown.rowHeight / 2 - 8.5, width: bounds.width - 46, height: 17),
                                            withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: th.dimText])
        }
        var y: CGFloat = 0
        for (i, item) in items.enumerated() {
            let h = height(item)
            defer { y += h }
            let r = NSRect(x: 0, y: y, width: bounds.width, height: h)
            guard r.intersects(dirtyRect) else { continue }
            switch item.kind {
            case .separator:
                th.border.setFill()
                NSRect(x: 12, y: r.midY, width: r.width - 24, height: 1).fill()
            case .header:
                (item.title.uppercased() as NSString).draw(in: NSRect(x: 14, y: r.maxY - 18, width: r.width - 28, height: 14),
                                                           withAttributes: [.font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
                                                                            .foregroundColor: th.dimText, .kern: 0.6, .paragraphStyle: para])
            case .item:
                if i == highlighted {
                    th.accent.withAlphaComponent(0.2).setFill()
                    NSBezierPath(roundedRect: r.insetBy(dx: 6, dy: 1), xRadius: 6, yRadius: 6).fill()
                }
                if let dot = item.color {
                    let c = NSRect(x: 15, y: (r.midY - 5).rounded(), width: 10, height: 10)
                    dot.setFill()
                    NSBezierPath(ovalIn: c).fill()
                    if item.checked {
                        dot.setStroke()
                        let ring = NSBezierPath(ovalIn: c.insetBy(dx: -3, dy: -3))
                        ring.lineWidth = 1.5
                        ring.stroke()
                    }
                } else if let symbol = item.symbol, !item.checked {
                    let cfg = NSImage.SymbolConfiguration(pointSize: 11.5, weight: .regular)
                        .applying(.init(paletteColors: [i == highlighted ? th.accent : th.foreground.withAlphaComponent(0.7)]))
                    if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
                        img.draw(in: NSRect(x: 20 - img.size.width / 2, y: (r.midY - img.size.height / 2).rounded(), width: img.size.width, height: img.size.height))
                    }
                }
                if item.checked && item.color == nil {
                    let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .bold).applying(.init(paletteColors: [th.accent]))
                    if let img = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
                        img.draw(in: NSRect(x: 14, y: r.midY - img.size.height / 2, width: img.size.width, height: img.size.height))
                    }
                }
                let font = NSFont.systemFont(ofSize: 13, weight: item.checked ? .semibold : .regular)
                (item.title as NSString).draw(in: NSRect(x: 34, y: r.midY - 8.5, width: r.width - 46, height: 17),
                                              withAttributes: [.font: font, .paragraphStyle: middle,
                                                               .foregroundColor: item.checked && item.color == nil ? th.accent : th.foreground.withAlphaComponent(0.92)])
                let alternate = optionHeld ? item.optionDetail : nil
                if let detail = alternate ?? item.detail {
                    let tw = (item.title as NSString).size(withAttributes: [.font: font]).width
                    let x = 34 + ceil(tw) + 8
                    if x < r.width - 40 {
                        (detail as NSString).draw(in: NSRect(x: x, y: r.midY - 7.5, width: r.width - 12 - x, height: 15),
                                                  withAttributes: [.font: NSFont.systemFont(ofSize: 11.5, weight: alternate == nil ? .regular : .medium),
                                                                   .foregroundColor: alternate == nil ? th.dimText : th.accent, .paragraphStyle: para])
                    }
                }
            }
        }
    }
}
