import AppKit

// Find in a file (⌘F in the editor), as VS Code does it: "3 of 12", and toggles for case, whole words and regular
// expressions, with a Replace row behind the chevron. The bar is here; finding, highlighting and stepping are in
// FileEditorView. What's found, and how, is Core's EditorFind, shared with Windows.

/// One of the Aa / ab / .* toggles, lit while it's on.
final class FindToggle: NSView {
    var isOn = false { didSet { needsDisplay = true } }
    var onToggle: (() -> Void)?
    private let label: String
    private let underlined: Bool
    /// Centered on what's actually drawn: `.*` has no capitals to center on, and its asterisk rides high.
    private let centersInk: Bool
    private var hovering = false { didSet { needsDisplay = true } }

    init(_ label: String, tip: String, underlined: Bool = false, centersInk: Bool = false) {
        self.label = label
        self.underlined = underlined
        self.centersInk = centersInk
        super.init(frame: .zero)
        toolTip = tip
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let th = Config.shared.theme
        if isOn || hovering {
            th.accent.withAlphaComponent(isOn ? 0.24 : 0.13).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        }
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        var attrs: [NSAttributedString.Key: Any] = [.font: font,
                                                    .foregroundColor: isOn || hovering ? th.accent : th.foreground.withAlphaComponent(0.6)]
        if underlined { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        let text = label as NSString
        let width = text.size(withAttributes: attrs).width
        var y = EditorFindBar.textTop(font, centeredIn: bounds)
        if centersInk {
            // The ink's box is measured up from the baseline; this is a flipped view.
            let ink = NSAttributedString(string: label, attributes: attrs).boundingRect(with: NSSize(width: 100, height: 100), options: [.usesDeviceMetrics])
            y = bounds.midY + ink.midY - font.ascender
        }
        text.draw(at: NSPoint(x: (bounds.width - width) / 2, y: y), withAttributes: attrs)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === self }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { onToggle?() }
}

/// An icon button with the same hover box as the toggles beside it.
final class FindButton: NSView {
    var symbol: String { didSet { needsDisplay = true } }
    var onPress: (() -> Void)?
    private let pointSize: CGFloat
    private var hovering = false { didSet { needsDisplay = true } }
    private var pressed = false { didSet { needsDisplay = true } }

    /// For a symbol whose drawing sits off its middle.
    private let nudgeDown: CGFloat

    init(_ symbol: String, tip: String, pointSize: CGFloat = 13, nudgeDown: CGFloat = 0) {
        self.symbol = symbol
        self.pointSize = pointSize
        self.nudgeDown = nudgeDown
        super.init(frame: .zero)
        toolTip = tip
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let th = Config.shared.theme
        if hovering || pressed {
            th.accent.withAlphaComponent(pressed ? 0.24 : 0.13).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        }
        let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular).applying(.init(paletteColors: [hovering ? th.accent : th.foreground.withAlphaComponent(0.6)]))
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip)?.withSymbolConfiguration(cfg) {
            img.draw(in: NSRect(x: (bounds.width - img.size.width) / 2, y: (bounds.height - img.size.height) / 2 + nudgeDown, width: img.size.width, height: img.size.height))
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === self }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseUp(with event: NSEvent) {
        pressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?() }
    }
}

final class EditorFindBar: NSView, NSTextFieldDelegate {
    let field = NSTextField()
    let replaceField = NSTextField()
    private var count = ""
    private var countIsProblem = false
    private var countRect = NSRect.zero
    private static let countFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private let chevron = FindButton("chevron.right", tip: "Toggle Replace", pointSize: 10)
    private let caseToggle = FindToggle("Aa", tip: "Match Case (⌥⌘C)")
    private let wordToggle = FindToggle("ab", tip: "Match Whole Word (⌥⌘W)", underlined: true)
    private let regexToggle = FindToggle(".*", tip: "Use Regular Expression (⌥⌘R)", centersInk: true)
    private var navButtons: [FindButton] = []
    private var replaceButtons: [FindButton] = []
    private(set) var showsReplace = false

    var onQueryChange: (() -> Void)?
    var onStep: ((Int) -> Void)?
    var onClose: (() -> Void)?
    var onReplace: (() -> Void)?
    var onReplaceAll: (() -> Void)?
    /// A read-only file has nothing to replace.
    var canReplace = true { didSet { if !canReplace { showsReplace = false }; chevron.isHidden = !canReplace; updateVisibility(); needsLayout = true } }

    /// Kept from one file to the next, as in VS Code.
    private static var lastOptions = EditorFindOptions()
    var options: EditorFindOptions {
        get { Self.lastOptions }
        set {
            Self.lastOptions = newValue
            syncToggles()
        }
    }

    static let rowHeight: CGFloat = 36
    /// Two rows of the same height either side of the line.
    var preferredHeight: CGFloat { showsReplace ? Self.rowHeight * 2 + 1 : Self.rowHeight }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        shadow = NSShadow()
        layer?.shadowOpacity = 0.35
        layer?.shadowRadius = 10
        layer?.shadowOffset = CGSize(width: 0, height: -3)

        chevron.onPress = { [weak self] in self?.toggleReplace() }
        addSubview(chevron)

        for (f, placeholder) in [(field, "Find"), (replaceField, "Replace")] {
            let cell = CenteredTextFieldCell(textCell: "")
            cell.onEditorSetUp = { [weak self] editor in self?.styleEditor(editor, on: true) }
            f.cell = cell
            f.isEditable = true
            f.isSelectable = true
            f.isBordered = false
            f.drawsBackground = false
            f.focusRingType = .none
            f.font = .systemFont(ofSize: 13)
            f.delegate = self
            f.cell?.isScrollable = true
            f.placeholderString = placeholder
            addSubview(f)
        }

        for (t, keyPath) in [(caseToggle, \EditorFindOptions.matchCase), (wordToggle, \.wholeWord), (regexToggle, \.regex)] {
            t.onToggle = { [weak self] in self?.flip(keyPath) }
            addSubview(t)
        }

        let nav: [(String, String, () -> Void)] = [("chevron.up", "Previous Match (⇧↩)", { [weak self] in self?.onStep?(-1) }),
                                                   ("chevron.down", "Next Match (↩)", { [weak self] in self?.onStep?(1) }),
                                                   ("xmark", "Close (Esc)", { [weak self] in self?.onClose?() })]
        for (symbol, tip, press) in nav {
            let b = FindButton(symbol, tip: tip)
            b.onPress = press
            navButtons.append(b)
            addSubview(b)
        }
        let replacing: [(String, String, () -> Void)] = [("arrow.turn.down.left", "Replace (↩)", { [weak self] in self?.onReplace?() }),
                                                         ("text.badge.checkmark", "Replace All", { [weak self] in self?.onReplaceAll?() })]
        for (symbol, tip, press) in replacing {
            let b = FindButton(symbol, tip: tip, nudgeDown: symbol == "arrow.turn.down.left" ? 1 : 0)
            b.onPress = press
            replaceButtons.append(b)
            addSubview(b)
        }
        syncToggles()
        updateVisibility()
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func applyTheme() {
        let th = Config.shared.theme
        // As the commit card's: the theme's background lifted a little, with its accent at the edge.
        layer?.backgroundColor = th.background.mix(th.isDark ? .white : .black, th.isDark ? 0.07 : 0.02).withAlphaComponent(1).cgColor
        layer?.borderColor = th.accent.withAlphaComponent(th.isDark ? 0.3 : 0.35).cgColor
        for (f, text) in [(field, "Find"), (replaceField, "Replace")] {
            f.textColor = th.foreground
            f.placeholderAttributedString = NSAttributedString(string: text, attributes: [.foregroundColor: th.dimText, .font: NSFont.systemFont(ofSize: 13)])
        }
        (navButtons + replaceButtons + [chevron]).forEach { $0.needsDisplay = true }
        needsDisplay = true
        updateChevron()
        [caseToggle, wordToggle, regexToggle].forEach { $0.needsDisplay = true }
    }

    private func updateChevron() {
        chevron.symbol = showsReplace ? "chevron.down" : "chevron.right"
    }

    private func updateVisibility() {
        replaceField.isHidden = !showsReplace
        replaceButtons.forEach { $0.isHidden = !showsReplace }
        updateChevron()
    }

    override func layout() {
        super.layout()
        let h = Self.rowHeight
        var x: CGFloat = 8
        if canReplace {
            chevron.frame = NSRect(x: x - 2, y: (h - 22) / 2, width: 20, height: 22)
            x += 22
        }
        // From the right: close, next, previous, the three toggles, then the count against them, which is only as
        // wide as it needs (nothing before a search). The field has what's left, and those stay put as it changes.
        var right = bounds.width - 6
        for b in navButtons.reversed() {
            right -= 22
            b.frame = NSRect(x: right, y: (h - 22) / 2, width: 22, height: 22)
            right -= 2
        }
        right -= 6
        for t in [regexToggle, wordToggle, caseToggle] {
            right -= 24
            t.frame = NSRect(x: right, y: (h - 22) / 2, width: 24, height: 22)
            right -= 2
        }
        let countW = count.isEmpty ? 0 : ceil((count as NSString).size(withAttributes: [.font: Self.countFont]).width)
        right -= countW + (countW > 0 ? 8 : 0)
        countRect = NSRect(x: right, y: 0, width: countW, height: h)
        // A point lower than centered, where the text lines up with the buttons beside it.
        field.frame = NSRect(x: x, y: (h - 20) / 2 + 1, width: max(60, right - x - 4), height: 20)
        // The replace row lines up under the find field, its buttons at the right, below the line `draw` puts there.
        let y2 = h + 1
        var r2 = bounds.width - 6
        for b in replaceButtons.reversed() {
            r2 -= 24
            b.frame = NSRect(x: r2, y: y2 + (h - 22) / 2, width: 24, height: 22)
            r2 -= 2
        }
        replaceField.frame = NSRect(x: x, y: y2 + (h - 20) / 2 + 1, width: max(60, r2 - x - 4), height: 20)
    }

    /// Where to draw `font`'s line so its capitals are centered in `r`, which is what lines the bar's text up.
    static func textTop(_ font: NSFont, centeredIn r: NSRect) -> CGFloat {
        r.midY + font.capHeight / 2 - font.ascender
    }

    /// The count, and the line between the find and replace rows.
    override func draw(_ dirtyRect: NSRect) {
        let th = Config.shared.theme
        if !count.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [.font: Self.countFont, .foregroundColor: countIsProblem ? th.red : th.dimText]
            (count as NSString).draw(at: NSPoint(x: countRect.minX, y: Self.textTop(Self.countFont, centeredIn: countRect)), withAttributes: attrs)
        }
        guard showsReplace else { return }
        th.foreground.withAlphaComponent(th.isDark ? 0.16 : 0.2).setFill()
        NSRect(x: 8, y: Self.rowHeight, width: bounds.width - 16, height: 1).fill()
    }

    /// The caret and selection in the bar's fields in the theme's accent. The field editor is shared with the rest of
    /// the window, so it's only while one of them has the focus.
    private func styleEditor(_ editor: NSTextView, on: Bool) {
        let th = Config.shared.theme
        editor.insertionPointColor = on ? th.accent : .controlTextColor
        editor.selectedTextAttributes = on ? [.backgroundColor: th.accent.withAlphaComponent(0.3), .foregroundColor: th.foreground]
            : [.backgroundColor: NSColor.selectedTextBackgroundColor, .foregroundColor: NSColor.selectedTextColor]
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if let editor = obj.userInfo?["NSFieldEditor"] as? NSTextView { styleEditor(editor, on: false) }
    }

    func focus() {
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    /// "3 of 12"; nil for nothing searched yet.
    func setCount(_ text: String?, problem: Bool = false) {
        count = text ?? ""
        countIsProblem = problem
        needsLayout = true
        needsDisplay = true
    }

    private func syncToggles() {
        caseToggle.isOn = Self.lastOptions.matchCase
        wordToggle.isOn = Self.lastOptions.wholeWord
        regexToggle.isOn = Self.lastOptions.regex
    }

    func flip(_ key: WritableKeyPath<EditorFindOptions, Bool>) {
        var o = options
        o[keyPath: key].toggle()
        options = o
        onQueryChange?()
    }

    /// While the bar has the focus: VS Code's keys for the toggles, ahead of the menu's (⌥⌘W closes a tab).
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard let responder = window?.firstResponder as? NSView, responder.isDescendant(of: self) || (responder as? NSText)?.delegate === field || (responder as? NSText)?.delegate === replaceField,
              e.modifierFlags.intersection([.command, .option, .control, .shift]) == [.command, .option] else { return super.performKeyEquivalent(with: e) }
        switch e.keyCode {
        case 8: flip(\.matchCase)
        case 13: flip(\.wholeWord)
        case 15: flip(\.regex)
        default: return super.performKeyEquivalent(with: e)
        }
        return true
    }

    func controlTextDidChange(_ obj: Notification) {
        if (obj.object as? NSTextField) === field { onQueryChange?() }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) {
            if control === replaceField {
                onReplace?()
            } else {
                onStep?(NSApp.currentEvent?.modifierFlags.contains(.shift) == true ? -1 : 1)
            }
            return true
        }
        if sel == #selector(NSResponder.cancelOperation(_:)) {
            onClose?()
            return true
        }
        return false
    }

    // The pointer over all of the bar. The text views under and in it set their I-beam by cursor rects and on every mouse
    // move, which fought this and made the cursor flicker: the window's cursor rects are off while the mouse is here,
    // and EditorTextView leaves the bar alone (`coveredBy`).
    private var mouseInside = false {
        didSet {
            guard mouseInside != oldValue else { return }
            if mouseInside { window?.disableCursorRects() } else { window?.enableCursorRects() }
            (mouseInside ? NSCursor.pointingHand : NSCursor.arrow).set()
            if !mouseInside { window?.resetCursorRects() }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === self }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }
    override func mouseMoved(with event: NSEvent) { NSCursor.pointingHand.set() }
    override func mouseEntered(with event: NSEvent) { mouseInside = true }
    override func mouseExited(with event: NSEvent) { mouseInside = false }

    /// Closing under the mouse mustn't leave the window's cursors off.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { mouseInside = false }
        super.viewWillMove(toWindow: newWindow)
    }

    private func toggleReplace() {
        showsReplace.toggle()
        updateVisibility()
        needsLayout = true
        needsDisplay = true
        superview?.needsLayout = true
        window?.makeFirstResponder(showsReplace ? replaceField : field)
    }

    /// Dev aid (DevTools find-bar).
    func devShowReplace() { if !showsReplace { toggleReplace() } }

}
