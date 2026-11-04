import AppKit

/// Settings › Appearance › Edit Theme: name, live preview, base colors and the 16 terminal colors of a custom
/// theme. Changes are a draft: every window shows them as you go (the edited theme is the active one), but the
/// theme's file only changes on Save Changes, and Reset goes back to what's saved. Leaving with unsaved changes asks.
enum ThemeEditor {
    /// The theme as saved, and as edited; every control's closure sees the latest.
    final class Model {
        private(set) var saved: Theme
        /// What the controls show (and, through `ThemeLibrary.draft`, every window).
        var theme: Theme
        weak var preview: ThemeCardView?
        weak var controller: SettingsWindowController?
        weak var bar: ThemeSaveBar?
        weak var palette: PaletteEditorView?
        private var pending: DispatchWorkItem?

        /// Picks up unsaved changes to this theme from before the page was rebuilt.
        init(_ saved: Theme) {
            self.saved = saved
            if let d = ThemeLibrary.draft, d.file == saved.file { theme = d } else { theme = saved }
        }

        var isDirty: Bool { !NSDictionary(dictionary: theme.json).isEqual(to: saved.json) }

        /// Shows the draft everywhere, a moment after a burst of changes (dragging in the color panel) settles.
        func changed() {
            preview?.theme = theme
            ThemeLibrary.draft = isDirty ? theme : nil
            bar?.dirty = isDirty
            pending?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.controller?.commit() }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
        }

        /// Writes the draft to the theme's file (a new name made unique), and follows a rename in the config.
        func save() {
            pending?.cancel()
            let old = saved.name
            var t = theme
            t.name = ThemeLibrary.uniqueName(t.name, except: saved.file)
            ThemeLibrary.draft = nil
            saved = ThemeLibrary.save(t)
            theme = saved
            if Config.shared.themeName == old { Config.shared.themeName = saved.name }
            controller?.committing = false
            Config.shared.commit()
            controller?.rebuild()
        }

        /// Back to what's saved.
        func reset() {
            pending?.cancel()
            ThemeLibrary.draft = nil
            theme = saved
            Config.shared.commit()
            controller?.rebuild()
        }
    }

    static func build(_ v: SettingsPageView, _ ctl: SettingsWindowController, _ theme: Theme) {
        let model = Model(theme)
        model.controller = ctl
        ctl.themeDraft = model
        let bar = ThemeSaveBar()
        bar.dirty = model.isDirty
        bar.onSave = { model.save() }
        bar.onReset = { model.reset() }
        model.bar = bar
        ctl.footer = bar

        v.add(SettingsPages.linkButton("‹ All Themes") { [weak ctl] in ctl?.show(.appearance) }, height: 18, gap: 16)

        let preview = ThemeCardView(model.theme)
        preview.interactive = false
        model.preview = preview
        let previewHolder = NSView()
        previewHolder.addSubview(preview)
        preview.frame = NSRect(x: 0, y: 0, width: 300, height: ThemeCardView.height)
        v.add(previewHolder, height: ThemeCardView.height, gap: 22)

        let name = ThemedField(model.theme.name, placeholder: "My Theme", mono: false)
        name.onCommit = { text in
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { name.stringValue = model.theme.name; return }
            model.theme.name = trimmed
            model.changed()
        }
        v.add(sectionHeader("Name"), height: 16, gap: 10)
        let nameCard = SettingsCard()
        nameCard.add(SettingRow(icon: "character.cursor.ibeam", title: "Theme name", detail: "Shown on its card and in the Theme menu.",
                                accessory: name, width: 220))
        v.add(card: nameCard, gap: 26)

        v.add(sectionHeader("Base colors"), height: 16, gap: 10)
        func colorRow(_ icon: String, _ title: String, _ detail: String?, alpha: Bool = false,
                      get: @escaping () -> NSColor, set: @escaping (NSColor) -> Void) -> SettingRow {
            let control = ColorControl(get(), allowsAlpha: alpha)
            control.onChange = { set($0); model.changed() }
            return SettingRow(icon: icon, title: title, detail: detail, accessory: control, width: ColorControl.width)
        }
        let gradient = GradientControl(model.theme.background2)
        gradient.onChange = { model.theme.background2 = $0; model.changed() }
        let base = SettingsCard()
        base.add(colorRow("square.fill", "Background", nil, get: { model.theme.background }, set: { model.theme.background = $0 }))
        base.add(SettingRow(icon: "square.bottomhalf.filled", title: "Gradient", detail: "Fade the background toward a second color at the bottom.",
                            accessory: gradient, width: GradientControl.width))
        base.add(colorRow("textformat", "Text", nil, get: { model.theme.foreground }, set: { model.theme.foreground = $0 }))
        base.add(colorRow("sparkle", "Accent", "Tab underline, highlights and markers.", get: { model.theme.accent }, set: { model.theme.accent = $0 }))
        base.add(colorRow("character.cursor.ibeam", "Cursor", nil, get: { model.theme.cursor }, set: { model.theme.cursor = $0 }))
        base.add(colorRow("selection.pin.in.out", "Selection", "Usually see-through so the text stays readable.", alpha: true,
                          get: { model.theme.selection }, set: { model.theme.selection = $0 }))
        v.add(card: base, gap: 26)

        v.add(sectionHeader("Terminal colors"), height: 16, gap: 10)
        let palette = PaletteEditorView(model.theme.ansi, saved: model.saved.ansi)
        model.palette = palette
        palette.onChange = { i, c in model.theme.ansi[i] = c; model.changed() }
        v.add(palette, height: PaletteEditorView.height, gap: 26)

        let actions = NSStackView(views: [
            // A copy as it's shown, unsaved changes and all; this theme stays as saved.
            SettingsPages.linkButton("Duplicate") { [weak ctl] in
                let copy = model.theme
                ThemeLibrary.draft = nil
                ctl?.themeDraft = nil
                ctl?.edit(ThemeLibrary.duplicate(copy))
            },
            destructiveButton("Delete Theme…") { [weak ctl] in confirmDelete(model.theme, ctl) },
        ])
        actions.spacing = 20
        v.add(actions, height: 20, gap: 0)
    }

    private static func destructiveButton(_ title: String, _ action: @escaping () -> Void) -> NSButton {
        let b = SettingsPages.linkButton(title, action)
        b.attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .medium),
                                                                            .foregroundColor: Config.shared.theme.red])
        return b
    }

    /// Moves the theme's file to the Trash after asking; windows using it fall back to the default theme.
    static func confirmDelete(_ theme: Theme, _ ctl: SettingsWindowController?) {
        guard theme.isCustom, let w = ctl?.window else { return }
        let alert = NSAlert()
        alert.messageText = "Delete “\(theme.name)”?"
        alert.informativeText = "Its file moves to the Trash."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: w) { resp in
            guard resp == .alertFirstButtonReturn else { return }
            ThemeLibrary.draft = nil
            ctl?.themeDraft = nil
            ThemeLibrary.delete(theme)
            if Config.shared.themeName == theme.name { Config.shared.themeName = ThemeLibrary.defaultName }
            ctl?.editingTheme = nil
            Config.shared.commit()
            ctl?.rebuild()
        }
    }
}

/// Opens the system color panel; alpha is offered only where a color may be see-through.
final class ThemedColorWell: NSColorWell {
    var allowsAlpha = false
    var onChange: ((NSColor) -> Void)?

    init(_ color: NSColor, allowsAlpha: Bool) {
        super.init(frame: NSRect(x: 0, y: 0, width: 44, height: 24))
        self.color = color
        self.allowsAlpha = allowsAlpha
        colorWellStyle = .default
        target = self
        action = #selector(picked)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The color panel is editing this well (it shows a ring), or stopped.
    var onActiveChange: ((Bool) -> Void)?

    override func activate(_ exclusive: Bool) {
        NSColorPanel.shared.showsAlpha = allowsAlpha
        super.activate(exclusive)
        needsDisplay = true
        onActiveChange?(true)
    }

    override func deactivate() {
        super.deactivate()
        needsDisplay = true
        onActiveChange?(false)
    }

    @objc private func picked() { onChange?(color) }

    // Hover: a ring in the accent color and a pointing hand, so the swatches read as buttons.
    private var hovering = false { didSet { needsDisplay = true } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === self }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with e: NSEvent) { if isEnabled { hovering = true } }
    override func mouseExited(with e: NSEvent) { hovering = false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    /// Differs from the saved theme: a dot in the corner.
    var unsaved = false { didSet { needsDisplay = true } }
    /// Drawn as a rounded rectangle rather than a capsule (the palette's swatches).
    var cornerRadius: CGFloat?

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let th = Config.shared.theme
        // The one the color panel is editing keeps a thick ring; hovering shows a thin one.
        if isActive || hovering {
            let r = cornerRadius ?? (bounds.height / 2 - 1)
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: r, yRadius: r)
            ring.lineWidth = isActive ? 3 : 2
            th.accent.setStroke()
            ring.stroke()
        }
        if unsaved {
            let d: CGFloat = 8
            let dot = NSBezierPath(ovalIn: NSRect(x: bounds.maxX - d - 4, y: bounds.minY + 4, width: d, height: d))
            th.accent.setFill()
            dot.fill()
            th.background.setStroke()
            dot.lineWidth = 1.5
            dot.stroke()
        }
    }
}

/// Hex field + color well, kept in sync.
final class ColorControl: NSView {
    static let width: CGFloat = 152
    var onChange: ((NSColor) -> Void)?
    private let hex: ThemedField
    private let well: ThemedColorWell

    init(_ color: NSColor, allowsAlpha: Bool) {
        hex = ThemedField(color.hexString, placeholder: "#RRGGBB")
        well = ThemedColorWell(color, allowsAlpha: allowsAlpha)
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 26))
        hex.onCommit = { [weak self] text in self?.typed(text) }
        well.onChange = { [weak self] c in
            self?.hex.stringValue = c.hexString
            self?.onChange?(c)
        }
        addSubview(hex)
        addSubview(well)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var fittingSize: NSSize { NSSize(width: Self.width, height: 26) }

    override func layout() {
        super.layout()
        hex.frame = NSRect(x: 0, y: (bounds.height - 24) / 2, width: 98, height: 24)
        well.frame = NSRect(x: bounds.width - 46, y: (bounds.height - 24) / 2, width: 46, height: 24)
    }

    var isEnabled: Bool = true {
        didSet {
            hex.isEnabled = isEnabled
            well.isEnabled = isEnabled
            alphaValue = isEnabled ? 1 : 0.4
        }
    }

    var color: NSColor { well.color }

    private func typed(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespaces)
        let digits = t.hasPrefix("#") ? String(t.dropFirst()) : t
        guard [3, 6, 8].contains(digits.count), digits.allSatisfy(\.isHexDigit) else {
            hex.stringValue = well.color.hexString
            return NSSound.beep()
        }
        let c = NSColor(hex: digits)
        well.color = c
        hex.stringValue = c.hexString
        onChange?(c)
    }
}

/// Switch for the optional bottom gradient color, plus its color.
final class GradientControl: NSView {
    static let width: CGFloat = ColorControl.width + 50
    var onChange: ((NSColor?) -> Void)?
    private let toggle = ThemedToggle()
    private let color: ColorControl

    init(_ initial: NSColor?) {
        color = ColorControl(initial ?? NSColor(hex: "#000000"), allowsAlpha: false)
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 26))
        toggle.isOn = initial != nil
        color.isEnabled = initial != nil
        toggle.onChange = { [weak self] on in
            guard let self else { return }
            self.color.isEnabled = on
            self.onChange?(on ? self.color.color : nil)
        }
        color.onChange = { [weak self] c in
            guard let self, self.toggle.isOn else { return }
            self.onChange?(c)
        }
        addSubview(toggle)
        addSubview(color)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var fittingSize: NSSize { NSSize(width: Self.width, height: 26) }

    override func layout() {
        super.layout()
        toggle.frame = NSRect(x: 0, y: (bounds.height - 22) / 2, width: 38, height: 22)
        color.frame = NSRect(x: bounds.width - ColorControl.width, y: 0, width: ColorControl.width, height: bounds.height)
    }
}

/// The 16 ANSI colors: normal on top, bright below. Each is a swatch (click for the color panel) with its hex code
/// under it (type one in); the swatch being edited is ringed and named above, and ones that differ from the saved
/// theme carry a dot.
final class PaletteEditorView: NSView {
    static let height: CGFloat = 212
    private static let names = ["Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White"]
    var onChange: ((Int, NSColor) -> Void)?
    private var wells: [ThemedColorWell] = []
    private var fields: [ThemedField] = []
    private var labels: [NSTextField] = []
    private let editing = NSTextField(labelWithString: "")
    private let saved: [NSColor]

    private static func name(_ i: Int) -> String { (i < 8 ? "" : "Bright ") + names[i % 8] }
    private static func hex(_ c: NSColor) -> String { String(c.hexString.dropFirst()) }

    init(_ colors: [NSColor], saved: [NSColor]) {
        self.saved = saved
        super.init(frame: .zero)
        for i in 0..<16 {
            let w = ThemedColorWell(colors[i], allowsAlpha: false)
            w.cornerRadius = 7
            w.toolTip = Self.name(i)
            w.unsaved = colors[i].hexString != saved[i].hexString
            w.onChange = { [weak self] c in self?.set(i, c) }
            w.onActiveChange = { [weak self] _ in self?.updateEditing() }
            wells.append(w)
            addSubview(w)
            // Without the # (narrow cells); typing one in works either way.
            let f = ThemedField(Self.hex(colors[i]), placeholder: "RRGGBB")
            f.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            f.alignment = .center
            f.onCommit = { [weak self] text in self?.typed(i, text) }
            fields.append(f)
            addSubview(f)
        }
        for name in Self.names {
            let l = settingsLabel(name, size: 10.5, dim: true)
            l.alignment = .center
            labels.append(l)
            addSubview(l)
        }
        for title in ["Normal", "Bright"] {
            let l = settingsLabel(title, size: 11, weight: .medium, dim: true)
            labels.append(l)
            addSubview(l)
        }
        editing.font = .systemFont(ofSize: 11, weight: .medium)
        addSubview(editing)
        updateEditing()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// A new color for swatch `i`, from the panel or typed.
    private func set(_ i: Int, _ c: NSColor) {
        wells[i].color = c
        fields[i].stringValue = Self.hex(c)
        wells[i].unsaved = c.hexString != saved[i].hexString
        updateEditing()
        onChange?(i, c)
    }

    private func typed(_ i: Int, _ text: String) {
        let t = text.trimmingCharacters(in: .whitespaces)
        let digits = t.hasPrefix("#") ? String(t.dropFirst()) : t
        guard [3, 6].contains(digits.count), digits.allSatisfy(\.isHexDigit) else {
            fields[i].stringValue = Self.hex(wells[i].color)
            return NSSound.beep()
        }
        set(i, NSColor(hex: digits))
    }

    /// "Editing Bright Red · #FF9DAC" while the color panel is on a swatch here.
    private func updateEditing() {
        let th = Config.shared.theme
        if let i = wells.firstIndex(where: \.isActive) {
            editing.stringValue = "Editing \(Self.name(i)) · \(wells[i].color.hexString)"
            editing.textColor = th.accent
        } else {
            let changed = wells.filter(\.unsaved).count
            editing.stringValue = changed > 0 ? "\(changed) changed" : "Click a color to change it"
            editing.textColor = changed > 0 ? th.accent : th.dimText
        }
    }

    override func layout() {
        super.layout()
        let left: CGFloat = 76, right: CGFloat = 16, gap: CGFloat = 8, top: CGFloat = 56
        let cellW = (bounds.width - left - right - gap * 7) / 8
        let rowH: CGFloat = 70
        for i in 0..<8 {
            labels[i].frame = NSRect(x: left + CGFloat(i) * (cellW + gap) - 4, y: top - 18, width: cellW + 8, height: 14)
        }
        for i in 0..<16 {
            let col = CGFloat(i % 8), row = CGFloat(i / 8)
            let x = left + col * (cellW + gap), y = top + row * rowH
            wells[i].frame = NSRect(x: x, y: y, width: cellW, height: 34)
            fields[i].frame = NSRect(x: x, y: y + 38, width: cellW, height: 20)
        }
        labels[8].frame = NSRect(x: 18, y: top + 9, width: 56, height: 16)
        labels[9].frame = NSRect(x: 18, y: top + rowH + 9, width: 56, height: 16)
        editing.frame = NSRect(x: 18, y: 12, width: bounds.width - 36, height: 15)
    }

    override func draw(_ dirtyRect: NSRect) {
        let th = Config.shared.theme
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        th.surface.withAlphaComponent(0.55).setFill()
        path.fill()
        th.border.setStroke()
        path.stroke()
    }

    /// Dev aid: as the color panel setting swatch `i`.
    func devSet(_ i: Int, _ hex: String) { set(i, NSColor(hex: hex)) }
    var devEditing: String { editing.stringValue }
}

/// Pinned under Settings while a theme is being edited: whether there's anything unsaved, Reset and Save Changes.
final class ThemeSaveBar: NSView {
    static let height: CGFloat = 56
    var dirty = false { didSet { update() } }
    var onSave: (() -> Void)?
    var onReset: (() -> Void)?
    private let label = NSTextField(labelWithString: "")
    private let save = BarButton("Save Changes", filled: true)
    private let reset = BarButton("Reset", filled: false)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        label.font = .systemFont(ofSize: 12.5, weight: .medium)
        [label, save, reset].forEach(addSubview)
        save.onPress = { [weak self] in self?.onSave?() }
        reset.onPress = { [weak self] in self?.onReset?() }
        update()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func update() {
        let th = Config.shared.theme
        label.stringValue = dirty ? "Unsaved changes" : "All changes saved"
        label.textColor = dirty ? th.foreground : th.dimText
        save.isEnabled = dirty
        reset.isEnabled = dirty
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let h: CGFloat = 30, y = (bounds.height - h) / 2
        let saveW = save.preferredWidth, resetW = reset.preferredWidth
        save.frame = NSRect(x: bounds.width - SettingsPageView.margin - saveW, y: y, width: saveW, height: h)
        reset.frame = NSRect(x: save.frame.minX - 10 - resetW, y: y, width: resetW, height: h)
        label.frame = NSRect(x: SettingsPageView.margin + 18, y: bounds.midY - 9, width: max(0, reset.frame.minX - SettingsPageView.margin - 30), height: 18)
    }

    override func draw(_ dirtyRect: NSRect) {
        let th = Config.shared.theme
        th.background.mix(th.isDark ? .white : .black, th.isDark ? 0.05 : 0.03).withAlphaComponent(0.97).setFill()
        bounds.fill()
        th.border.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        // A dot by the words: the accent while there's something to save.
        (dirty ? th.accent : th.dimText.withAlphaComponent(0.5)).setFill()
        NSBezierPath(ovalIn: NSRect(x: SettingsPageView.margin + 2, y: bounds.midY - 4, width: 8, height: 8)).fill()
    }

    func devPress(_ title: String) { [save, reset].first { $0.title == title && $0.isEnabled }?.onPress?() }
    var devState: String { "\(label.stringValue), save \(save.isEnabled ? "on" : "off")" }
}

/// A button in the theme's colors: filled with the accent (the one to press), or outlined.
final class BarButton: NSView {
    let title: String
    private let filled: Bool
    var isEnabled = true { didSet { needsDisplay = true } }
    var onPress: (() -> Void)?
    private var hovering = false { didSet { needsDisplay = true } }
    private var pressed = false { didSet { needsDisplay = true } }
    private static let font = NSFont.systemFont(ofSize: 13, weight: .semibold)

    init(_ title: String, filled: Bool) {
        self.title = title
        self.filled = filled
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    var preferredWidth: CGFloat { ceil((title as NSString).size(withAttributes: [.font: Self.font]).width) + 36 }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === self }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate], owner: self))
    }

    override func cursorUpdate(with e: NSEvent) { (isEnabled ? NSCursor.pointingHand : NSCursor.arrow).set() }
    override func mouseEntered(with e: NSEvent) { hovering = true }
    override func mouseExited(with e: NSEvent) { hovering = false }
    override func mouseDown(with e: NSEvent) { if isEnabled { pressed = true } }
    override func mouseUp(with e: NSEvent) {
        let inside = bounds.contains(convert(e.locationInWindow, from: nil))
        let fire = pressed && inside && isEnabled
        pressed = false
        if fire { onPress?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        let th = Config.shared.theme
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
        let alpha: CGFloat = isEnabled ? (pressed ? 0.75 : 1) : 0.35
        let text: NSColor
        if filled {
            th.accent.withAlphaComponent(alpha * (hovering && isEnabled ? 0.88 : 1)).setFill()
            path.fill()
            text = (th.accent.luminance > 0.55 ? NSColor.black : NSColor.white).withAlphaComponent(isEnabled ? 1 : 0.6)
        } else {
            th.foreground.withAlphaComponent(hovering && isEnabled ? 0.1 : 0.04).setFill()
            path.fill()
            th.foreground.withAlphaComponent(0.25 * alpha).setStroke()
            path.stroke()
            text = th.foreground.withAlphaComponent(isEnabled ? 0.9 : 0.35)
        }
        let size = (title as NSString).size(withAttributes: [.font: Self.font])
        (title as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
                                 withAttributes: [.font: Self.font, .foregroundColor: text])
    }
}
