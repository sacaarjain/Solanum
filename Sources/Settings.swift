import AppKit

/// Settings (⌘,, the flower in the tab bar, or `settings` at a prompt): Appearance, Text & Size, Shortcuts,
/// Aliases and Preferences. Drawn in the current theme; every change is written to the config file and applied live.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()

    enum Page: Int, CaseIterable {
        case appearance, text, shortcuts, aliases, preferences

        var title: String {
            switch self {
            case .appearance: return "Appearance"
            case .text: return "Text & Size"
            case .shortcuts: return "Shortcuts"
            case .aliases: return "Aliases"
            case .preferences: return "Preferences"
            }
        }

        var subtitle: String {
            switch self {
            case .appearance: return "Pick a planet. Every open window updates instantly."
            case .text: return "Font, size and cursor for every terminal."
            case .shortcuts: return "Everything you can do from the keyboard."
            case .aliases: return "Short names for commands you type often. Open tabs pick up changes at their next prompt."
            case .preferences: return "How Solanum starts up, and where files moving between servers are kept on the way."
            }
        }

        var symbol: String {
            switch self {
            case .appearance: return "paintpalette"
            case .text: return "textformat.size"
            case .shortcuts: return "keyboard"
            case .aliases: return "chevron.left.forwardslash.chevron.right"
            case .preferences: return "gearshape"
            }
        }
    }

    private let root = SettingsRootView()
    private(set) var page = Page.appearance
    /// The custom theme open in the editor (Appearance shows the editor instead of the cards while set).
    var editingTheme: URL?
    private var observer: NSObjectProtocol?
    private var lastTheme = ""
    /// Set while a control here is committing, so our own change doesn't rebuild the page under the pointer.
    var committing = false

    private init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 640),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "Solanum Settings"
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isOpaque = false
        w.backgroundColor = .clear
        w.minSize = NSSize(width: 720, height: 480)
        w.isReleasedWhenClosed = false
        w.contentView = root
        super.init(window: w)
        w.delegate = self
        root.controller = self
        observer = NotificationCenter.default.addObserver(forName: .solanumConfigChanged, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            let theme = Config.shared.theme.name
            if theme != self.lastTheme || !self.committing { self.rebuild() } else { self.root.needsDisplay = true }
        }
        updateObserver = NotificationCenter.default.addObserver(forName: .solanumUpdateChanged, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.root.sidebar.needsDisplay = true
            if self.page == .preferences, self.window?.isVisible == true { self.rebuild() }
        }
        w.center()
    }

    private var updateObserver: NSObjectProtocol?

    required init?(coder: NSCoder) { fatalError() }

    func present(_ page: Page? = nil) {
        if let page { self.page = page }
        rebuild()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func show(_ p: Page) {
        page = p
        editingTheme = nil
        rebuild()
        root.scrollToTop()
    }

    /// Opens a custom theme in the editor, switching to it so edits show live in every window.
    func edit(_ theme: Theme) {
        guard let url = theme.file else { return }
        page = .appearance
        editingTheme = url
        if Config.shared.themeName != theme.name {
            Config.shared.themeName = theme.name
            Config.shared.commit()
        }
        rebuild()
        root.scrollToTop()
    }

    func rebuild() {
        lastTheme = Config.shared.theme.name
        root.applyTheme()
        // Picking a theme (or any change) rebuilds the page in place; only a different page or editor starts at the top.
        let same = builtPage == page && builtEditing == editingTheme
        builtPage = page
        builtEditing = editingTheme
        root.show(SettingsPages.make(page, controller: self), keepScroll: same)
    }
    private var builtPage: Page?
    private var builtEditing: URL?

    /// Writes the config and broadcasts it, without rebuilding the page (the control already shows the value).
    func commit() {
        committing = true
        Config.shared.commit()
        committing = false
    }
}

// MARK: - Window chrome

final class SettingsRootView: NSView {
    weak var controller: SettingsWindowController?
    private let effect = NSVisualEffectView()
    let sidebar = SettingsSidebar()
    private let scroll = NSScrollView()
    private var pageView: SettingsPageView?
    static let sidebarWidth: CGFloat = 210

    override init(frame: NSRect) {
        super.init(frame: frame)
        effect.blendingMode = .behindWindow
        effect.material = .hudWindow
        effect.state = .active
        addSubview(effect)
        addSubview(sidebar)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        addSubview(scroll)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func applyTheme() {
        let th = Config.shared.theme
        appearance = NSAppearance(named: th.isDark ? .darkAqua : .aqua)
        window?.appearance = appearance
        sidebar.controller = controller
        sidebar.needsDisplay = true
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let th = Config.shared.theme
        if let b2 = th.background2 {
            NSGradient(starting: th.background.withAlphaComponent(0.94), ending: b2.withAlphaComponent(0.94))?.draw(in: bounds, angle: 90)
        } else {
            th.background.withAlphaComponent(0.94).setFill()
            bounds.fill()
        }
    }

    /// Swaps in a freshly built page; `keepScroll` holds the scroll position (a rebuild of the page already showing).
    func show(_ page: SettingsPageView, keepScroll: Bool = false) {
        let offset = scroll.contentView.bounds.origin.y
        pageView = page
        scroll.documentView = page
        needsLayout = true
        layoutSubtreeIfNeeded()
        if keepScroll {
            let maxY = max(0, page.frame.height - scroll.contentSize.height)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: min(offset, maxY)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    func scrollToTop() {
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    override func layout() {
        super.layout()
        effect.frame = bounds
        sidebar.frame = NSRect(x: 0, y: 0, width: Self.sidebarWidth, height: bounds.height)
        scroll.frame = NSRect(x: Self.sidebarWidth, y: 0, width: bounds.width - Self.sidebarWidth, height: bounds.height)
        guard let page = pageView else { return }
        let w = scroll.contentSize.width
        page.frame = NSRect(x: 0, y: 0, width: w, height: page.height(forWidth: w))
    }
}

/// Flower and name, the page list, and the version at the bottom.
final class SettingsSidebar: NSView {
    weak var controller: SettingsWindowController?
    private var rows: [(SettingsWindowController.Page, NSRect)] = []
    private var hover: Int?
    private static let flower = SolanumArt.flowerImage(size: 40)

    override var isFlipped: Bool { true }

    private func symbol(_ name: String, _ color: NSColor) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium).applying(.init(paletteColors: [color]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
    }

    override func draw(_ dirtyRect: NSRect) {
        let th = Config.shared.theme
        th.tabBarTint.setFill()
        bounds.fill()
        th.border.setFill()
        NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill()

        // Header below the traffic lights.
        Self.flower.draw(in: NSRect(x: 16, y: 44, width: 36, height: 36))
        ("Solanum" as NSString).draw(at: NSPoint(x: 60, y: 45), withAttributes: [.font: NSFont.systemFont(ofSize: 15, weight: .bold), .foregroundColor: th.foreground])
        ("Settings" as NSString).draw(at: NSPoint(x: 60, y: 64), withAttributes: [.font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: th.dimText])

        rows = []
        var y: CGFloat = 104
        for (i, p) in SettingsWindowController.Page.allCases.enumerated() {
            let r = NSRect(x: 10, y: y, width: bounds.width - 20, height: 34)
            rows.append((p, r))
            let selected = controller?.page == p
            if selected || hover == i {
                (selected ? th.accent.withAlphaComponent(0.18) : th.foreground.withAlphaComponent(0.06)).setFill()
                NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8).fill()
            }
            let box = NSRect(x: r.minX + 8, y: r.midY - 12, width: 24, height: 24)
            (selected ? th.accent.withAlphaComponent(0.9) : th.foreground.withAlphaComponent(0.08)).setFill()
            NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
            if let img = symbol(p.symbol, selected ? .white : th.foreground.withAlphaComponent(0.75)) {
                img.draw(in: NSRect(x: box.midX - img.size.width / 2, y: box.midY - img.size.height / 2, width: img.size.width, height: img.size.height))
            }
            (p.title as NSString).draw(at: NSPoint(x: box.maxX + 10, y: r.midY - 8),
                                       withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: selected ? .semibold : .medium),
                                                        .foregroundColor: selected ? th.foreground : th.foreground.withAlphaComponent(0.8)])
            // An update waiting: "1" on the page that offers it, as on the flower in the tab bar.
            if p == .preferences, Updater.shared.needsAttention {
                let badge = NSRect(x: r.maxX - 28, y: r.midY - 8, width: 16, height: 16)
                th.accent.setFill()
                NSBezierPath(ovalIn: badge).fill()
                let one = NSAttributedString(string: "1", attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .bold), .foregroundColor: NSColor.white])
                let s = one.size()
                one.draw(at: NSPoint(x: badge.midX - s.width / 2, y: badge.midY - s.height / 2))
            }
            y += 38
        }

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        ("Solanum \(version) · built locally" as NSString).draw(at: NSPoint(x: 18, y: bounds.height - 28),
                                                                 withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: th.dimText])
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === self }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        let h = rows.firstIndex { $0.1.contains(p) }
        if h != hover { hover = h; needsDisplay = true }
    }

    override func mouseExited(with e: NSEvent) {
        hover = nil
        needsDisplay = true
    }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if let row = rows.first(where: { $0.1.contains(p) }) {
            controller?.show(row.0)
            needsDisplay = true
        }
    }
}

// MARK: - Page layout

/// A page: blocks stacked top to bottom. Each block knows its height for a given width.
final class SettingsPageView: NSView {
    struct Block {
        let view: NSView
        let height: (CGFloat) -> CGFloat
        var gapAfter: CGFloat
    }

    private(set) var blocks: [Block] = []
    static let margin: CGFloat = 32

    override var isFlipped: Bool { true }

    /// Clicking empty space leaves whatever field was being edited.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(nil)
    }

    func add(_ view: NSView, height: @escaping (CGFloat) -> CGFloat, gap: CGFloat = 18) {
        blocks.append(Block(view: view, height: height, gapAfter: gap))
        addSubview(view)
    }

    func add(_ view: NSView, height: CGFloat, gap: CGFloat = 18) {
        add(view, height: { _ in height }, gap: gap)
    }

    func height(forWidth w: CGFloat) -> CGFloat {
        let inner = w - Self.margin * 2
        return blocks.reduce(46) { $0 + $1.height(inner) + $1.gapAfter } + 24
    }

    override func layout() {
        super.layout()
        let inner = bounds.width - Self.margin * 2
        var y: CGFloat = 46
        for b in blocks {
            let h = b.height(inner)
            b.view.frame = NSRect(x: Self.margin, y: y, width: inner, height: h)
            y += h + b.gapAfter
        }
    }
}

/// A label that draws in the theme's colors.
func settingsLabel(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, dim: Bool = false, mono: Bool = false) -> NSTextField {
    let th = Config.shared.theme
    let l = NSTextField(labelWithString: text)
    l.font = mono ? .monospacedSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
    l.textColor = dim ? th.dimText : th.foreground
    l.lineBreakMode = .byTruncatingTail
    return l
}

func sectionHeader(_ text: String) -> NSTextField {
    let l = settingsLabel(text.uppercased(), size: 11, weight: .semibold, dim: true)
    l.attributedStringValue = NSAttributedString(string: text.uppercased(), attributes: [
        .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: Config.shared.theme.dimText, .kern: 0.8])
    return l
}

/// Rounded card holding setting rows separated by hairlines.
final class SettingsCard: NSView {
    private(set) var rows: [SettingRow] = []
    override var isFlipped: Bool { true }

    func add(_ row: SettingRow) {
        rows.append(row)
        addSubview(row)
    }

    var totalHeight: CGFloat { rows.reduce(0) { $0 + $1.rowHeight } }

    override func layout() {
        super.layout()
        var y: CGFloat = 0
        for r in rows {
            r.frame = NSRect(x: 0, y: y, width: bounds.width, height: r.rowHeight)
            y += r.rowHeight
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let th = Config.shared.theme
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        th.surface.withAlphaComponent(0.55).setFill()
        path.fill()
        th.border.setStroke()
        path.lineWidth = 1
        path.stroke()
        th.border.setFill()
        var y: CGFloat = 0
        for r in rows.dropLast() {
            y += r.rowHeight
            NSRect(x: 16, y: y, width: bounds.width - 32, height: 1).fill()
        }
    }
}

/// Icon, title and description on the left; a control (or anything) on the right.
class SettingRow: NSView {
    let rowHeight: CGFloat
    private let icon: String?
    private let titleLabel: NSTextField
    private let detailLabel: NSTextField?
    private let accessory: NSView?
    private let accessoryWidth: CGFloat

    init(icon: String? = nil, title: String, detail: String? = nil, accessory: NSView? = nil, width: CGFloat? = nil, mono: Bool = false) {
        self.icon = icon
        titleLabel = settingsLabel(title, size: 13, weight: .medium, mono: mono)
        detailLabel = detail.map { settingsLabel($0, size: 11.5, dim: true) }
        self.accessory = accessory
        accessoryWidth = width ?? accessory?.fittingSize.width ?? 0
        rowHeight = detail == nil ? 46 : 58
        super.init(frame: .zero)
        addSubview(titleLabel)
        detailLabel.map(addSubview)
        accessory.map(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let x: CGFloat = icon == nil ? 18 : 58
        let right = bounds.width - 16
        let aw = min(accessoryWidth, bounds.width * 0.6)
        let textW = right - aw - 16 - x
        if let d = detailLabel {
            titleLabel.frame = NSRect(x: x, y: 10, width: textW, height: 18)
            d.frame = NSRect(x: x, y: 29, width: textW, height: 16)
        } else {
            titleLabel.frame = NSRect(x: x, y: (bounds.height - 18) / 2, width: textW, height: 18)
        }
        if let a = accessory {
            let h = min(a.fittingSize.height > 0 ? a.fittingSize.height : 24, bounds.height - 8)
            a.frame = NSRect(x: right - aw, y: (bounds.height - h) / 2, width: aw, height: h)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let icon else { return }
        let th = Config.shared.theme
        let box = NSRect(x: 16, y: (bounds.height - 30) / 2, width: 30, height: 30)
        th.accent.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium).applying(.init(paletteColors: [th.accent]))
        if let img = NSImage(systemSymbolName: icon, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
            img.draw(in: NSRect(x: box.midX - img.size.width / 2, y: box.midY - img.size.height / 2, width: img.size.width, height: img.size.height))
        }
    }
}

// MARK: - Controls

/// On/off switch in the theme's purple.
final class ThemedToggle: NSControl {
    var isOn = false { didSet { needsDisplay = true } }
    var onChange: ((Bool) -> Void)?
    private var hovering = false { didSet { needsDisplay = true } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === self }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with e: NSEvent) { hovering = true }
    override func mouseExited(with e: NSEvent) { hovering = false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override var intrinsicContentSize: NSSize { NSSize(width: 38, height: 22) }
    override var fittingSize: NSSize { intrinsicContentSize }

    override func draw(_ dirtyRect: NSRect) {
        let th = Config.shared.theme
        let r = NSRect(x: 0, y: (bounds.height - 22) / 2, width: 38, height: 22)
        let track = isOn ? (hovering ? th.accent.blended(withFraction: 0.15, of: .white) ?? th.accent : th.accent)
                         : th.foreground.withAlphaComponent(hovering ? 0.3 : 0.18)
        track.setFill()
        NSBezierPath(roundedRect: r, xRadius: 11, yRadius: 11).fill()
        let knob = NSRect(x: isOn ? r.maxX - 20 : r.minX + 2, y: r.minY + 2, width: 18, height: 18)
        NSGraphicsContext.saveGraphicsState()
        let sh = NSShadow()
        sh.shadowColor = NSColor.black.withAlphaComponent(0.3)
        sh.shadowBlurRadius = 2
        sh.shadowOffset = NSSize(width: 0, height: -1)
        sh.set()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: knob).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    override func mouseDown(with e: NSEvent) {
        isOn.toggle()
        onChange?(isOn)
    }
}

/// Slider with its value printed beside it.
final class ValueSlider: NSView {
    let slider = NSSlider()
    private let value = NSTextField(labelWithString: "")
    private let format: (Double) -> String
    var onChange: ((Double) -> Void)?

    init(min: Double, max: Double, value v: Double, format: @escaping (Double) -> String) {
        self.format = format
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
        slider.minValue = min
        slider.maxValue = max
        slider.doubleValue = v
        slider.trackFillColor = Config.shared.theme.accent
        slider.target = self
        slider.action = #selector(moved)
        value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        value.textColor = Config.shared.theme.dimText
        value.alignment = .right
        value.stringValue = format(v)
        addSubview(slider)
        addSubview(value)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var fittingSize: NSSize { NSSize(width: 240, height: 22) }

    override func layout() {
        super.layout()
        slider.frame = NSRect(x: 0, y: 0, width: bounds.width - 56, height: bounds.height)
        value.frame = NSRect(x: bounds.width - 50, y: (bounds.height - 16) / 2, width: 50, height: 16)
    }

    @objc private func moved() {
        value.stringValue = format(slider.doubleValue)
        onChange?(slider.doubleValue)
    }
}

/// Pop-up menu that reports the chosen title.
final class ChoicePopup: NSPopUpButton {
    var onChange: ((String) -> Void)?

    init(_ titles: [String], selected: String) {
        super.init(frame: .zero, pullsDown: false)
        addItems(withTitles: titles)
        if item(withTitle: selected) == nil { addItem(withTitle: selected) }
        selectItem(withTitle: selected)
        target = self
        action = #selector(chose)
        sizeToFit()
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func chose() { onChange?(titleOfSelectedItem ?? "") }
}

/// Single-line field in the theme's colors; reports on Return or when focus leaves.
final class ThemedField: NSTextField, NSTextFieldDelegate {
    var onCommit: ((String) -> Void)?
    var onEdit: ((String) -> Void)?

    // Text centered vertically with some padding, instead of hugging the top-left corner of the box.
    override class var cellClass: AnyClass? {
        get { CenteredTextFieldCell.self }
        set {}
    }

    init(_ text: String, placeholder: String = "", mono: Bool = true) {
        super.init(frame: .zero)
        (cell as? CenteredTextFieldCell)?.horizontalInset = 8
        let th = Config.shared.theme
        stringValue = text
        placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [.foregroundColor: th.dimText.withAlphaComponent(0.6),
                                                                                           .font: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)])
        font = mono ? .monospacedSystemFont(ofSize: 12.5, weight: .regular) : .systemFont(ofSize: 13)
        textColor = th.foreground
        isBordered = false
        // The background lives on the rounded layer only: drawn by the field too, the centered cell painted it a
        // second time behind the text, a darker box inside the box.
        drawsBackground = false
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.backgroundColor = th.background.withAlphaComponent(0.6).cgColor
        cell?.isScrollable = true
        delegate = self
        updateBorder()
    }

    private var hovering = false { didSet { updateBorder() } }
    private var editing = false { didSet { updateBorder() } }

    private func updateBorder() {
        let th = Config.shared.theme
        layer?.borderColor = (editing ? th.accent.withAlphaComponent(0.9) : hovering ? th.foreground.withAlphaComponent(0.35) : th.border).cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === self }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with e: NSEvent) { hovering = true }
    override func mouseExited(with e: NSEvent) { hovering = false }

    /// What the field held when editing began; Esc puts it back.
    private var valueBeforeEditing = ""

    func controlTextDidBeginEditing(_ obj: Notification) {
        editing = true
        valueBeforeEditing = stringValue
    }

    /// Esc cancels the edit (original value back) and Return keeps it; either way the field lets go of the keyboard.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.cancelOperation(_:)):
            stringValue = valueBeforeEditing
            onEdit?(stringValue)
            window?.makeFirstResponder(nil)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            window?.makeFirstResponder(nil)
            return true
        default:
            return false
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var fittingSize: NSSize { NSSize(width: 120, height: 24) }

    func controlTextDidChange(_ obj: Notification) { onEdit?(stringValue) }
    func controlTextDidEndEditing(_ obj: Notification) {
        editing = false
        onCommit?(stringValue)
    }
}

/// A shortcut drawn as key caps, e.g. ⇧ ⌘ P.
final class KeyCapsView: NSView {
    private let keys: [String]
    init(_ shortcut: String) {
        // Split modifier glyphs from the key; multi-character keys ("Space", "Tab") stay whole.
        var parts: [String] = []
        var rest = Substring(shortcut)
        while let f = rest.first, "⌃⌥⇧⌘".contains(f) { parts.append(String(f)); rest = rest.dropFirst() }
        if !rest.isEmpty { parts.append(String(rest)) }
        keys = parts
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    private static let font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)

    override var fittingSize: NSSize {
        let w = keys.reduce(0) { $0 + max(22, ($1 as NSString).size(withAttributes: [.font: Self.font]).width + 12) + 4 }
        return NSSize(width: max(w - 4, 0), height: 22)
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let th = Config.shared.theme
        var x = bounds.width - fittingSize.width
        for k in keys {
            let w = max(22, (k as NSString).size(withAttributes: [.font: Self.font]).width + 12)
            let r = NSRect(x: x, y: (bounds.height - 22) / 2, width: w, height: 22)
            th.foreground.withAlphaComponent(0.09).setFill()
            NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).fill()
            th.border.setStroke()
            NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5).stroke()
            let attrs: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: th.foreground.withAlphaComponent(0.85)]
            let s = (k as NSString).size(withAttributes: attrs)
            (k as NSString).draw(at: NSPoint(x: r.midX - s.width / 2, y: r.midY - s.height / 2), withAttributes: attrs)
            x += w + 4
        }
    }
}

// MARK: - Theme cards

/// A theme's look in miniature: a prompt, git status line and its palette, with the name underneath.
final class ThemeCardView: NSView {
    var theme: Theme { didSet { needsDisplay = true } }
    var onPick: (() -> Void)?
    var onEdit: (() -> Void)?
    var onDuplicate: (() -> Void)?
    var onDelete: (() -> Void)?
    /// False for the editor's preview, which isn't clickable.
    var interactive = true
    private var hovering = false
    private var pencilRect = NSRect.zero
    static let height: CGFloat = 128

    init(_ theme: Theme) {
        self.theme = theme
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private var isSelected: Bool { Config.shared.theme.name == theme.name }

    override func draw(_ dirtyRect: NSRect) {
        let ui = Config.shared.theme
        let t = theme
        let card = bounds.insetBy(dx: 1.5, dy: 1.5)
        let shape = NSBezierPath(roundedRect: card, xRadius: 11, yRadius: 11)
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        let preview = NSRect(x: card.minX, y: card.minY, width: card.width, height: card.height - 32)
        if let b2 = t.background2 {
            NSGradient(starting: t.background, ending: b2)?.draw(in: preview, angle: -90)
        } else {
            t.background.setFill()
            preview.fill()
        }
        ui.surface.withAlphaComponent(0.8).setFill()
        NSRect(x: card.minX, y: preview.maxY, width: card.width, height: 32).fill()

        // Window dots
        for (i, c) in [t.ansi[1], t.ansi[3], t.ansi[2]].enumerated() {
            c.setFill()
            NSBezierPath(ovalIn: NSRect(x: preview.minX + 12 + CGFloat(i) * 12, y: preview.minY + 10, width: 7, height: 7)).fill()
        }
        let mono = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        func line(_ parts: [(String, NSColor)], _ y: CGFloat) {
            let s = NSMutableAttributedString()
            for (text, color) in parts { s.append(NSAttributedString(string: text, attributes: [.font: mono, .foregroundColor: color])) }
            s.draw(at: NSPoint(x: preview.minX + 12, y: preview.minY + y))
        }
        let dim = t.foreground.withAlphaComponent(0.55)
        line([("❯ ", t.accent), ("git status", t.foreground)], 24)
        line([("on ", dim), ("main", t.ansi[5]), (" ✓ clean", t.ansi[2])], 40)
        line([("● ", t.ansi[3]), ("3 files ", t.foreground), ("changed", t.ansi[4])], 56)
        for (i, c) in [t.ansi[1], t.ansi[2], t.ansi[3], t.ansi[4], t.ansi[5], t.ansi[6]].enumerated() {
            c.setFill()
            NSBezierPath(roundedRect: NSRect(x: preview.minX + 12 + CGFloat(i) * 19, y: preview.minY + 76, width: 15, height: 6),
                         xRadius: 2, yRadius: 2).fill()
        }
        NSGraphicsContext.restoreGraphicsState()

        (t.name as NSString).draw(at: NSPoint(x: card.minX + 12, y: preview.maxY + 8),
                                  withAttributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .semibold), .foregroundColor: ui.foreground])
        pencilRect = .zero
        if interactive && theme.isCustom {
            pencilRect = NSRect(x: card.maxX - (isSelected ? 50 : 28), y: preview.maxY + 6, width: 20, height: 20)
            let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
                .applying(.init(paletteColors: [hovering ? ui.foreground : ui.dimText]))
            if let img = NSImage(systemSymbolName: "pencil", accessibilityDescription: "Edit")?.withSymbolConfiguration(cfg) {
                img.draw(in: NSRect(x: pencilRect.midX - img.size.width / 2, y: pencilRect.midY - img.size.height / 2,
                                    width: img.size.width, height: img.size.height))
            }
        }
        if isSelected {
            let r = NSRect(x: card.maxX - 26, y: preview.maxY + 8, width: 16, height: 16)
            ui.accent.setFill()
            NSBezierPath(ovalIn: r).fill()
            let check = NSBezierPath()
            check.move(to: NSPoint(x: r.minX + 4.2, y: r.midY + 0.3))
            check.line(to: NSPoint(x: r.minX + 7, y: r.midY + 3))
            check.line(to: NSPoint(x: r.maxX - 4, y: r.midY - 3))
            check.lineWidth = 1.8
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            NSColor.white.setStroke()
            check.stroke()
        }
        if isSelected {
            ui.accent.setStroke()
            shape.lineWidth = 2.5
        } else {
            (hovering ? ui.foreground.withAlphaComponent(0.3) : ui.border).setStroke()
            shape.lineWidth = 1
        }
        shape.stroke()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === self }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with e: NSEvent) { if interactive { hovering = true; needsDisplay = true } }
    override func mouseExited(with e: NSEvent) { hovering = false; needsDisplay = true }

    override func mouseDown(with e: NSEvent) {
        guard interactive else { return }
        if e.modifierFlags.contains(.control) { return rightMouseDown(with: e) }
        if pencilRect.contains(convert(e.locationInWindow, from: nil)) || e.clickCount == 2 && theme.isCustom { onEdit?() } else { onPick?() }
    }

    override func rightMouseDown(with e: NSEvent) {
        guard interactive else { return }
        let m = NSMenu()
        if theme.isCustom { m.addItem(ActionMenuItem("Edit Theme…") { [weak self] in self?.onEdit?() }) }
        m.addItem(ActionMenuItem(theme.isCustom ? "Duplicate" : "Duplicate and Customize…") { [weak self] in self?.onDuplicate?() })
        if theme.isCustom {
            m.addItem(.separator())
            m.addItem(ActionMenuItem("Delete Theme…") { [weak self] in self?.onDelete?() })
        }
        NSMenu.popUpContextMenu(m, with: e, for: self)
    }
}

/// The last card in the grid: starts a new theme from the current one.
final class NewThemeCardView: NSView {
    var onCreate: (() -> Void)?
    private var hovering = false
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let ui = Config.shared.theme
        let card = bounds.insetBy(dx: 1.5, dy: 1.5)
        let shape = NSBezierPath(roundedRect: card, xRadius: 11, yRadius: 11)
        (hovering ? ui.accent.withAlphaComponent(0.10) : ui.surface.withAlphaComponent(0.25)).setFill()
        shape.fill()
        shape.setLineDash([5, 4], count: 2, phase: 0)
        shape.lineWidth = 1.5
        (hovering ? ui.accent : ui.foreground.withAlphaComponent(0.25)).setStroke()
        shape.stroke()
        let cfg = NSImage.SymbolConfiguration(pointSize: 20, weight: .medium).applying(.init(paletteColors: [hovering ? ui.accent : ui.dimText]))
        if let img = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
            img.draw(in: NSRect(x: card.midX - img.size.width / 2, y: card.midY - 22, width: img.size.width, height: img.size.height))
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12.5, weight: .semibold),
                                                    .foregroundColor: hovering ? ui.foreground : ui.dimText]
        let t = "New Theme" as NSString
        let sz = t.size(withAttributes: attrs)
        t.draw(at: NSPoint(x: card.midX - sz.width / 2, y: card.midY + 8), withAttributes: attrs)
        let sub = "Starts from the current one" as NSString
        let subAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: ui.dimText]
        let ss = sub.size(withAttributes: subAttrs)
        sub.draw(at: NSPoint(x: card.midX - ss.width / 2, y: card.midY + 26), withAttributes: subAttrs)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === self }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with e: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with e: NSEvent) { hovering = false; needsDisplay = true }
    override func mouseDown(with e: NSEvent) { onCreate?() }
}

/// Theme cards in as many columns as fit (at most three).
final class ThemeGridView: NSView {
    private(set) var cards: [NSView] = []
    private static let gap: CGFloat = 14

    override var isFlipped: Bool { true }

    func add(_ card: NSView) {
        cards.append(card)
        addSubview(card)
    }

    private static func columns(_ w: CGFloat) -> Int { max(1, min(3, Int((w + gap) / (200 + gap)))) }

    static func height(forWidth w: CGFloat, count: Int) -> CGFloat {
        let rows = (count + columns(w) - 1) / columns(w)
        return CGFloat(rows) * ThemeCardView.height + CGFloat(max(rows - 1, 0)) * gap
    }

    override func layout() {
        super.layout()
        let cols = Self.columns(bounds.width)
        let w = (bounds.width - Self.gap * CGFloat(cols - 1)) / CGFloat(cols)
        for (i, c) in cards.enumerated() {
            c.frame = NSRect(x: CGFloat(i % cols) * (w + Self.gap), y: CGFloat(i / cols) * (ThemeCardView.height + Self.gap),
                             width: w, height: ThemeCardView.height)
        }
    }
}

// MARK: - Pages

enum SettingsPages {
    static func make(_ page: SettingsWindowController.Page, controller: SettingsWindowController) -> SettingsPageView {
        let v = SettingsPageView()
        let editing = page == .appearance ? controller.editingTheme.flatMap { url in ThemeLibrary.custom.first { $0.file == url } } : nil
        v.add(settingsLabel(editing == nil ? page.title : "Edit Theme", size: 26, weight: .bold), height: 32, gap: 4)
        let sub = settingsLabel(editing == nil ? page.subtitle : "Changes save as you go and show in every window using this theme.", size: 13, dim: true)
        sub.lineBreakMode = .byWordWrapping
        sub.maximumNumberOfLines = 2
        v.add(sub, height: 20, gap: 24)
        switch page {
        case .appearance:
            if let editing { ThemeEditor.build(v, controller, editing) } else { appearance(v, controller) }
        case .text: text(v, controller)
        case .shortcuts: shortcuts(v, controller)
        case .aliases: aliases(v, controller)
        case .preferences: preferences(v, controller)
        }
        return v
    }

    // Updates: where Solanum stands against main in its repository, and what to do about it (see Updater).
    private static func updates(_ v: SettingsPageView, _ ctl: SettingsWindowController) {
        let u = Updater.shared
        v.add(sectionHeader("Updates"), height: 16, gap: 10)
        let status: SettingRow
        switch u.state {
        case .available(let commits):
            let n = commits.count
            let latest = commits.prefix(4).map(Updater.subject).joined(separator: " · ")
            status = SettingRow(icon: "arrow.down.circle", title: n == 0 ? "An update is available" : "\(n) new commit\(n == 1 ? "" : "s") on main",
                                detail: latest.isEmpty ? "main has moved on since this build." : latest + (n > 4 ? " · and \(n - 4) more" : ""))
        case .building:
            status = SettingRow(icon: "hammer", title: "Building the update…", detail: "Usually a minute or two. You can keep working.")
        case .ready:
            status = SettingRow(icon: "checkmark.circle", title: "Update ready",
                                detail: "Installed in ~/Applications. Restart Solanum to start using it.")
        case .failed:
            status = SettingRow(icon: "xmark.octagon", title: "The last update failed", detail: "Nothing was installed. The build log has the details.")
        case .idle:
            status = u.canUpdate
                ? SettingRow(icon: "checkmark.seal", title: "Solanum is up to date", detail: "This build is \(u.built.map { String($0.prefix(7)) } ?? "")."
                             + " It checks main in the repository it was built from.")
                : SettingRow(icon: "questionmark.circle", title: "Updates need a build made with build.sh",
                             detail: "This copy doesn't know which repository it came from.")
        }
        card(v, [
            status,
            SettingRow(icon: "clock.arrow.circlepath", title: "Check for updates daily",
                       detail: "Looks for new commits on main once a day and offers them; nothing installs or restarts without you.",
                       accessory: toggle(Config.shared.checkForUpdates) { [weak ctl] on in Config.shared.checkForUpdates = on; ctl?.commit() }),
        ], gap: 12)
        switch u.state {
        case .available, .ready:
            let note = NSTextField(wrappingLabelWithString: "Your work is safe. Updates are built in a separate copy of the repository "
                + "(\(FilePaths.abbreviate(Updater.worktree, home: NSHomeDirectory()))), so if you're working on Solanum itself, "
                + "your checkout, its branch and any uncommitted changes aren't touched. Restarting brings back your windows and tabs, "
                + "and Claude chats continue where they left off; other programs running in tabs are stopped.")
            note.font = .systemFont(ofSize: 12)
            note.textColor = Config.shared.theme.dimText
            v.add(note, height: { w in note.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: w, height: 1000)).height ?? 48 }, gap: 10)
        default: break
        }
        var actions: [NSButton] = []
        switch u.state {
        case .available:
            actions = [linkButton("Download Only") { u.update(restart: false) },
                       linkButton("Download and Install (will restart)") { u.update(restart: true) }]
        case .ready:
            actions = [linkButton("Restart Now") { u.restartNow() }]
        case .failed:
            actions = [linkButton("Try Again") { u.update(restart: false) }, linkButton("Show Log") { NSWorkspace.shared.open(Updater.log) }]
        case .idle:
            if u.canUpdate { actions = [linkButton("Check Now") { u.check(manual: true, force: true) }] }
        case .building:
            break
        }
        if !actions.isEmpty {
            let row = NSStackView(views: actions)
            row.spacing = 18
            row.alignment = .centerY
            row.distribution = .gravityAreas
            v.add(row, height: 20, gap: 26)
        } else {
            v.add(NSView(), height: 1, gap: 26)
        }
    }

    private static func card(_ v: SettingsPageView, _ rows: [SettingRow], gap: CGFloat = 26) {
        let c = SettingsCard()
        rows.forEach(c.add)
        v.add(c, height: c.totalHeight, gap: gap)
    }

    private static func toggle(_ on: Bool, _ set: @escaping (Bool) -> Void) -> ThemedToggle {
        let t = ThemedToggle()
        t.isOn = on
        t.onChange = set
        return t
    }

    // Appearance: theme cards, then window options.
    private static func appearance(_ v: SettingsPageView, _ ctl: SettingsWindowController) {
        let c = Config.shared
        let grid = ThemeGridView()
        let vsGrid = ThemeGridView()
        for t in ThemeLibrary.all {
            let card = ThemeCardView(t)
            // Committing broadcasts the change; the controller rebuilds this page in the new theme.
            card.onPick = {
                Config.shared.themeName = t.name
                Config.shared.commit()
            }
            card.onEdit = { [weak ctl] in ctl?.edit(t) }
            card.onDuplicate = { [weak ctl] in ctl?.edit(ThemeLibrary.duplicate(t)) }
            card.onDelete = { [weak ctl] in ThemeEditor.confirmDelete(t, ctl) }
            (ThemeLibrary.isVSCode(t) ? vsGrid : grid).add(card)
        }
        let newCard = NewThemeCardView()
        newCard.onCreate = { [weak ctl] in ctl?.edit(ThemeLibrary.duplicate(Config.shared.theme)) }
        grid.add(newCard)
        let count = grid.cards.count, vsCount = vsGrid.cards.count
        v.add(grid, height: { ThemeGridView.height(forWidth: $0, count: count) }, gap: 24)
        v.add(sectionHeader("Status Bar"), height: 16, gap: 10)
        card(v, [
            SettingRow(icon: "globe.americas", title: "Theme icon", detail: "An icon beside the theme name in the status bar; Outer Wilds themes show their planet. Off shows just the name.",
                       accessory: toggle(c.themeIcon) { [weak ctl] on in Config.shared.themeIcon = on; ctl?.commit() }),
        ])
        v.add(sectionHeader("VS Code"), height: 16, gap: 10)
        v.add(vsGrid, height: { ThemeGridView.height(forWidth: $0, count: vsCount) }, gap: 30)

        v.add(sectionHeader("Window"), height: 16, gap: 10)
        let opacity = ValueSlider(min: 0.5, max: 1, value: Double(c.opacity)) { "\(Int(($0 * 100).rounded()))%" }
        opacity.onChange = { [weak ctl] val in Config.shared.opacity = (CGFloat(val) * 100).rounded() / 100; ctl?.commit() }
        let padding = ValueSlider(min: 0, max: 40, value: Double(c.padding)) { "\(Int($0)) pt" }
        padding.onChange = { [weak ctl] val in Config.shared.padding = CGFloat(Int(val)); ctl?.commit() }
        card(v, [
            SettingRow(icon: "circle.lefthalf.filled", title: "Background opacity", detail: "How much of the desktop shows through.", accessory: opacity),
            SettingRow(icon: "drop", title: "Blur behind the window", detail: "Frosted glass when the background is see-through.",
                       accessory: toggle(c.blur) { [weak ctl] on in Config.shared.blur = on; ctl?.commit() }),
            SettingRow(icon: "rectangle.inset.filled", title: "Padding", detail: "Space between the text and the window edge.", accessory: padding),
        ])

        let buttons = NSStackView(views: [
            linkButton("Open Themes Folder") {
                // It only exists once a custom theme has been saved; make it so there's always something to open.
                try? FileManager.default.createDirectory(at: Config.shared.themesDir, withIntermediateDirectories: true)
                NSWorkspace.shared.open(Config.shared.themesDir)
            },
            linkButton("Open Config File") { (NSApp.delegate as? AppDelegate)?.openConfigFile(nil) },
        ])
        // One row: .leading (a vertical-stack alignment) stacked them in a 20pt slot, and the top button lost its clicks.
        buttons.orientation = .horizontal
        buttons.spacing = 18
        buttons.alignment = .centerY
        buttons.distribution = .gravityAreas
        v.add(buttons, height: 20, gap: 0)
    }

    // Preferences: startup, notifications and file transfers.
    private static func preferences(_ v: SettingsPageView, _ ctl: SettingsWindowController) {
        let c = Config.shared
        updates(v, ctl)
        v.add(sectionHeader("Workspace"), height: 16, gap: 10)
        let notify = ThemedField(String(Int(c.notifyAfterSeconds)), placeholder: "10")
        notify.alignment = .right
        notify.onCommit = { [weak ctl] s in if let n = Double(s) { Config.shared.notifyAfterSeconds = max(0, n); ctl?.commit() } }
        let newTabFolder = ChoicePopup(["Current Folder", "Home Folder"], selected: c.newTabFolder == "home" ? "Home Folder" : "Current Folder")
        newTabFolder.onChange = { [weak ctl] s in Config.shared.newTabFolder = s == "Home Folder" ? "home" : "current"; ctl?.commit() }
        card(v, [
            SettingRow(icon: "macwindow.on.rectangle", title: "Reload workspace every time",
                       detail: "Off: Solanum starts fresh, and offers the last session for a minute.",
                       accessory: toggle(c.restoreSession) { [weak ctl] on in Config.shared.restoreSession = on; ctl?.commit() }),
            SettingRow(icon: "text.alignleft", title: "Include recent output", detail: "Bring back each tab's last few thousand lines.",
                       accessory: toggle(c.restoreScrollback) { [weak ctl] on in Config.shared.restoreScrollback = on; ctl?.commit() }),
            SettingRow(icon: "bell", title: "Notify after (seconds)", detail: "When a command in a background tab runs at least this long. 0 turns it off.",
                       accessory: notify, width: 70),
            SettingRow(icon: "plus.rectangle.on.rectangle", title: "New tabs open in",
                       detail: "Where ⌘T starts. ⌥⌘T always opens the current folder, in the tab's group.",
                       accessory: newTabFolder, width: 150),
        ])

        v.add(sectionHeader("File Transfers"), height: 16, gap: 10)
        let shown = c.transferFolder.isEmpty ? "" : FilePaths.abbreviate(c.transferFolder, home: NSHomeDirectory())
        let folder = ThemedField(shown, placeholder: FilePaths.abbreviate(Config.defaultTransferDir.path, home: NSHomeDirectory()))
        folder.onCommit = { [weak ctl] s in
            Config.shared.transferFolder = s.trimmingCharacters(in: .whitespaces)
            ctl?.commit()
        }
        card(v, [SettingRow(icon: "externaldrive", title: "Staging folder",
                            detail: "Files copied between two ssh hosts land here on this Mac first, and are deleted once delivered.",
                            accessory: folder, width: 300)], gap: 12)
        let buttons = NSStackView(views: [
            linkButton("Choose Folder…") { [weak ctl] in
                let panel = NSOpenPanel()
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.canCreateDirectories = true
                panel.prompt = "Use Folder"
                panel.directoryURL = Config.shared.transferStagingDir
                guard let w = ctl?.window else { return }
                panel.beginSheetModal(for: w) { resp in
                    guard resp == .OK, let url = panel.url else { return }
                    Config.shared.transferFolder = FilePaths.abbreviate(url.path, home: NSHomeDirectory())
                    Config.shared.commit()
                }
            },
            linkButton("Use Default") {
                Config.shared.transferFolder = ""
                Config.shared.commit()
            },
            linkButton("Show in Finder") {
                let dir = Config.shared.transferStagingDir
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                NSWorkspace.shared.open(dir)
            },
        ])
        buttons.orientation = .horizontal
        buttons.spacing = 18
        buttons.alignment = .centerY
        buttons.distribution = .gravityAreas
        v.add(buttons, height: 20, gap: 0)
    }

    // Text & Size: font, size, spacing, cursor, scrollback.
    private static func text(_ v: SettingsPageView, _ ctl: SettingsWindowController) {
        let c = Config.shared
        var families = Set<String>()
        for name in NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? [] {
            if let fam = NSFont(name: name, size: 12)?.familyName, !fam.hasPrefix(".") { families.insert(fam) }
        }
        let font = ChoicePopup(["System Mono"] + families.sorted(), selected: c.fontFamily)
        font.onChange = { [weak ctl] f in Config.shared.fontFamily = f; ctl?.commit() }
        let size = ValueSlider(min: 9, max: 28, value: Double(c.fontSize)) { "\(Int($0)) pt" }
        size.slider.numberOfTickMarks = 20
        size.slider.allowsTickMarkValuesOnly = true
        size.onChange = { [weak ctl] val in Config.shared.fontSize = CGFloat(Int(val.rounded())); ctl?.commit() }
        let lineHeight = ValueSlider(min: 1, max: 1.8, value: Double(c.lineHeight)) { String(format: "%.2f×", $0) }
        lineHeight.onChange = { [weak ctl] val in Config.shared.lineHeight = (CGFloat(val) * 20).rounded() / 20; ctl?.commit() }

        v.add(sectionHeader("Font"), height: 16, gap: 10)
        card(v, [
            SettingRow(icon: "textformat", title: "Font", detail: "Any monospaced font installed on this Mac.", accessory: font, width: 220),
            SettingRow(icon: "textformat.size", title: "Size", detail: "Also ⌘+ and ⌘−; ⌘0 resets.", accessory: size),
            SettingRow(icon: "arrow.up.and.down.text.horizontal", title: "Line height", accessory: lineHeight),
            SettingRow(icon: "link", title: "Ligatures", detail: "Join character pairs like -> and != when the font has them.",
                       accessory: toggle(c.ligatures) { [weak ctl] on in Config.shared.ligatures = on; ctl?.commit() }),
        ])

        v.add(sectionHeader("Cursor"), height: 16, gap: 10)
        let style = ChoicePopup(["Bar", "Block", "Underline"], selected: c.cursorStyle.capitalized)
        style.onChange = { [weak ctl] s in Config.shared.cursorStyle = s.lowercased(); ctl?.commit() }
        card(v, [
            SettingRow(icon: "character.cursor.ibeam", title: "Style", accessory: style, width: 130),
            SettingRow(icon: "light.max", title: "Blink",
                       accessory: toggle(c.cursorBlink) { [weak ctl] on in Config.shared.cursorBlink = on; ctl?.commit() }),
        ])

        v.add(sectionHeader("Scrollback"), height: 16, gap: 10)
        let lines = ThemedField(String(c.scrollback), placeholder: "10000")
        lines.alignment = .right
        lines.onCommit = { [weak ctl] s in if let n = Int(s) { Config.shared.scrollback = min(max(n, 100), 200_000); ctl?.commit() } }
        card(v, [SettingRow(icon: "scroll", title: "Lines kept per tab", detail: "Older output is dropped past this.", accessory: lines, width: 90)], gap: 0)
    }

    // Shortcuts: keyboard options, then every menu shortcut and the ones that live outside menus.
    private static func shortcuts(_ v: SettingsPageView, _ ctl: SettingsWindowController) {
        let c = Config.shared
        let hotkey = ThemedField(c.quickTerminalHotkey, placeholder: "ctrl+`")
        hotkey.onCommit = { [weak ctl] s in
            let hk = s.trimmingCharacters(in: .whitespaces)
            guard !hk.isEmpty, hk != Config.shared.quickTerminalHotkey else { return }
            Config.shared.quickTerminalHotkey = hk
            ctl?.commit()
            (NSApp.delegate as? AppDelegate)?.registerHotKey()
        }
        v.add(sectionHeader("Keyboard & Mouse"), height: 16, gap: 10)
        card(v, [
            SettingRow(icon: "option", title: "Option key acts as Meta", detail: "⌥← and ⌥→ jump words; ⌥ shortcuts reach the shell.",
                       accessory: toggle(c.optionAsMeta) { [weak ctl] on in Config.shared.optionAsMeta = on; ctl?.commit() }),
            SettingRow(icon: "doc.on.clipboard", title: "Copy on select",
                       accessory: toggle(c.copyOnSelect) { [weak ctl] on in Config.shared.copyOnSelect = on; ctl?.commit() }),
            SettingRow(icon: "rectangle.topthird.inset.filled", title: "Quick terminal hotkey", detail: "From any app, e.g. ctrl+`  or  alt+space.",
                       accessory: hotkey, width: 120),
            SettingRow(icon: "eye.slash", title: "Hide the quick terminal when it loses focus",
                       accessory: toggle(c.quickTerminalAutoHide) { [weak ctl] on in Config.shared.quickTerminalAutoHide = on; ctl?.commit() }),
        ])

        var groups: [(String, [(String, String)])] = []
        if let main = NSApp.mainMenu {
            func walk(_ menu: NSMenu, into list: inout [(String, String)]) {
                for item in menu.items where !item.isSeparatorItem && !item.isHidden {
                    if let sub = item.submenu { walk(sub, into: &list); continue }
                    let keys = CommandPalette.shortcutString(item)
                    if !keys.isEmpty { list.append((item.title, keys)) }
                }
            }
            for top in main.items {
                guard let sub = top.submenu else { continue }
                var list: [(String, String)] = []
                walk(sub, into: &list)
                if !list.isEmpty { groups.append((top.title.isEmpty || top === main.items.first ? "Solanum" : top.title, list)) }
            }
        }
        groups.append(("Elsewhere", [
            ("Search command history", "⌃H"),
            ("Next / previous tab", "⌃⇥"),
            ("Delete the selected part of a command", "⌫"),
            ("Open a link", "⌘Click"),
            ("Edit a history entry · run it", "↩"),
            ("Run a history entry", "⌘↩"),
            ("Wrap lines in the file editor", "⌥Z"),
            ("Quick terminal", Self.hotkeyGlyphs(c.quickTerminalHotkey)),
        ]))
        for (title, list) in groups {
            v.add(sectionHeader(title), height: 16, gap: 10)
            card(v, list.map { SettingRow(title: $0.0, accessory: KeyCapsView($0.1)) })
        }
    }

    /// "ctrl+`" → "⌃`" for display.
    static func hotkeyGlyphs(_ s: String) -> String {
        let parts = s.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        var out = ""
        for p in parts.dropLast() {
            switch p {
            case "ctrl", "control": out += "⌃"
            case "alt", "option", "opt": out += "⌥"
            case "shift": out += "⇧"
            case "cmd", "command": out += "⌘"
            default: break
            }
        }
        let key = parts.last ?? ""
        return out + (key == "space" ? "Space" : key.uppercased())
    }

    // Aliases: name → command rows, editable in place.
    private static func aliases(_ v: SettingsPageView, _ ctl: SettingsWindowController) {
        var list = AliasStore.shared.aliases
        let c = SettingsCard()
        let th = Config.shared.theme

        func save() { AliasStore.shared.set(list) }

        for i in list.indices {
            let row = AliasRowView(name: list[i].name, command: list[i].command)
            row.onChange = { name, command in
                guard list.indices.contains(i) else { return }
                list[i] = AliasStore.Alias(name: name, command: command)
                save()
            }
            row.onRemove = { [weak ctl] in
                guard list.indices.contains(i) else { return }
                list.remove(at: i)
                save()
                ctl?.rebuild()
            }
            c.add(row)
        }
        let add = SettingRow(title: list.isEmpty ? "No aliases yet" : "", accessory: linkButton("＋ Add Alias") { [weak ctl] in
            list.append(AliasStore.Alias(name: "", command: ""))
            AliasStore.shared.set(list)
            ctl?.rebuild()
            // Put the cursor in the new row's name field.
            DispatchQueue.main.async {
                let fields = ctl?.window?.contentView.map { allFields(in: $0) } ?? []
                if let f = fields.dropLast().last { ctl?.window?.makeFirstResponder(f) }
            }
        })
        c.add(add)
        v.add(c, height: c.totalHeight, gap: 14)

        let hint = settingsLabel("Type the alias at a prompt, e.g. c to start Claude. Aliases apply in Solanum's local shells, not over ssh.",
                         size: 11.5, dim: true)
        hint.lineBreakMode = .byWordWrapping
        hint.maximumNumberOfLines = 2
        hint.textColor = th.dimText
        v.add(hint, height: 32, gap: 0)
    }

    private static func allFields(in view: NSView) -> [NSTextField] {
        view.subviews.flatMap { sub -> [NSTextField] in
            if let f = sub as? ThemedField { return [f] }
            return allFields(in: sub)
        }
    }

    static func linkButton(_ title: String, _ action: @escaping () -> Void) -> NSButton {
        let b = ClosureButton(title: title, action: action)
        b.isBordered = false
        b.attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .medium),
                                                                            .foregroundColor: Config.shared.theme.accent])
        b.sizeToFit()
        return b
    }
}

/// Text button (Duplicate, Delete Theme…, Open Config File…): underlined with a pointing hand on hover, dimmed
/// while pressed.
final class ClosureButton: NSButton {
    private var handler: (() -> Void)?
    /// The title as styled by whoever made the button; hover adds an underline on top of it.
    private var restingTitle: NSAttributedString?
    private var hovering = false { didSet { restyle() } }

    convenience init(title: String, action: @escaping () -> Void) {
        self.init(frame: .zero)
        self.title = title
        handler = action
        target = self
        self.action = #selector(fire)
    }

    @objc private func fire() { handler?() }

    private func restyle() {
        if restingTitle == nil || !hovering && attributedTitle.string != restingTitle?.string { restingTitle = attributedTitle }
        guard let base = restingTitle else { return }
        if hovering {
            let t = NSMutableAttributedString(attributedString: base)
            t.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: 0, length: t.length))
            attributedTitle = t
        } else {
            attributedTitle = base
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === self }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with e: NSEvent) { if isEnabled { hovering = true } }
    override func mouseExited(with e: NSEvent) { hovering = false }

    override func mouseDown(with e: NSEvent) {
        alphaValue = 0.6
        super.mouseDown(with: e)
        alphaValue = 1
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// One alias: name field, arrow, command field and a remove button. Invalid names turn red.
final class AliasRowView: SettingRow {
    var onChange: ((String, String) -> Void)?
    var onRemove: (() -> Void)?
    private let nameField: ThemedField
    private let commandField: ThemedField
    private let arrow = NSTextField(labelWithString: "→")
    private let remove: NSButton

    init(name: String, command: String) {
        nameField = ThemedField(name, placeholder: "c")
        commandField = ThemedField(command, placeholder: "claude")
        remove = NSButton(image: NSImage(systemSymbolName: "minus.circle.fill", accessibilityDescription: "Remove") ?? NSImage(),
                          target: nil, action: nil)
        super.init(title: "")
        let th = Config.shared.theme
        arrow.textColor = th.dimText
        arrow.font = .systemFont(ofSize: 13, weight: .medium)
        remove.isBordered = false
        remove.contentTintColor = th.dimText
        remove.toolTip = "Remove this alias"
        remove.target = self
        remove.action = #selector(removeTapped)
        for f in [nameField, commandField] {
            f.onEdit = { [weak self] _ in self?.edited() }
        }
        [nameField, arrow, commandField, remove].forEach(addSubview)
        validate()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let y = (bounds.height - 26) / 2
        nameField.frame = NSRect(x: 18, y: y, width: 110, height: 26)
        arrow.frame = NSRect(x: 136, y: (bounds.height - 18) / 2, width: 20, height: 18)
        remove.frame = NSRect(x: bounds.width - 38, y: (bounds.height - 22) / 2, width: 22, height: 22)
        commandField.frame = NSRect(x: 160, y: y, width: bounds.width - 160 - 48, height: 26)
    }

    private func validate() {
        let name = nameField.stringValue
        let ok = name.isEmpty || AliasStore.isValidName(name)
        nameField.textColor = ok ? Config.shared.theme.foreground : Config.shared.theme.red
        nameField.toolTip = ok ? nil : "Use letters, numbers, _ . or - (no spaces)."
    }

    private func edited() {
        validate()
        onChange?(nameField.stringValue.trimmingCharacters(in: .whitespaces), commandField.stringValue)
    }

    @objc private func removeTapped() { onRemove?() }
}
