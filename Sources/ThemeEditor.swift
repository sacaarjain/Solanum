import AppKit

/// Settings › Appearance › Edit Theme: name, live preview, base colors and the 16 terminal colors of a custom
/// theme. Every change is written to the theme's JSON file and, since the edited theme is the active one,
/// shows in all windows as you go.
enum ThemeEditor {
    /// Holds the theme being edited so every control's closure sees the latest values.
    final class Model {
        var theme: Theme
        weak var preview: ThemeCardView?
        weak var controller: SettingsWindowController?
        private var pending: DispatchWorkItem?

        init(_ theme: Theme) { self.theme = theme }

        /// Coalesces bursts (dragging in the color panel) into one save and broadcast.
        func changed() {
            preview?.theme = theme
            pending?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.theme = ThemeLibrary.save(self.theme)
                self.controller?.commit()
            }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
        }
    }

    static func build(_ v: SettingsPageView, _ ctl: SettingsWindowController, _ theme: Theme) {
        let model = Model(theme)
        model.controller = ctl

        v.add(SettingsPages.linkButton("‹ All Themes") { [weak ctl] in ctl?.show(.appearance) }, height: 18, gap: 16)

        let preview = ThemeCardView(theme)
        preview.interactive = false
        model.preview = preview
        let previewHolder = NSView()
        previewHolder.addSubview(preview)
        preview.frame = NSRect(x: 0, y: 0, width: 300, height: ThemeCardView.height)
        v.add(previewHolder, height: ThemeCardView.height, gap: 22)

        let name = ThemedField(theme.name, placeholder: "My Theme", mono: false)
        name.onCommit = { [weak ctl] text in
            let old = model.theme.name
            let newName = ThemeLibrary.uniqueName(text, except: model.theme.file)
            guard newName != old else { name.stringValue = old; return }
            model.theme.name = newName
            model.theme = ThemeLibrary.save(model.theme)
            if Config.shared.themeName == old { Config.shared.themeName = newName }
            Config.shared.commit()
            ctl?.rebuild()
        }
        v.add(sectionHeader("Name"), height: 16, gap: 10)
        let nameCard = SettingsCard()
        nameCard.add(SettingRow(icon: "character.cursor.ibeam", title: "Theme name", detail: "Shown on its card and in the Theme menu.",
                                accessory: name, width: 220))
        v.add(nameCard, height: { nameCard.height(forWidth: $0) }, gap: 26)

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
        v.add(base, height: { base.height(forWidth: $0) }, gap: 26)

        v.add(sectionHeader("Terminal colors"), height: 16, gap: 10)
        let palette = PaletteEditorView(model.theme.ansi)
        palette.onChange = { i, c in model.theme.ansi[i] = c; model.changed() }
        v.add(palette, height: PaletteEditorView.height, gap: 26)

        let actions = NSStackView(views: [
            SettingsPages.linkButton("Duplicate") { [weak ctl] in ctl?.edit(ThemeLibrary.duplicate(model.theme)) },
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

    override func activate(_ exclusive: Bool) {
        NSColorPanel.shared.showsAlpha = allowsAlpha
        super.activate(exclusive)
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

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard hovering else { return }
        let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: bounds.height / 2 - 1, yRadius: bounds.height / 2 - 1)
        ring.lineWidth = 2
        Config.shared.theme.accent.setStroke()
        ring.stroke()
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

/// The 16 ANSI colors: normal on top, bright below, each a color well with its name.
final class PaletteEditorView: NSView {
    static let height: CGFloat = 156
    private static let names = ["Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White"]
    var onChange: ((Int, NSColor) -> Void)?
    private var wells: [ThemedColorWell] = []
    private var labels: [NSTextField] = []

    init(_ colors: [NSColor]) {
        super.init(frame: .zero)
        for i in 0..<16 {
            let w = ThemedColorWell(colors[i], allowsAlpha: false)
            w.toolTip = "\(i < 8 ? "" : "Bright ")\(Self.names[i % 8]) · \(colors[i].hexString)"
            w.onChange = { [weak self, weak w] c in
                w?.toolTip = "\(i < 8 ? "" : "Bright ")\(Self.names[i % 8]) · \(c.hexString)"
                self?.onChange?(i, c)
            }
            wells.append(w)
            addSubview(w)
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
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let left: CGFloat = 76, right: CGFloat = 16, gap: CGFloat = 8
        let cellW = (bounds.width - left - right - gap * 7) / 8
        for i in 0..<16 {
            let col = CGFloat(i % 8), row = CGFloat(i / 8)
            wells[i].frame = NSRect(x: left + col * (cellW + gap), y: 18 + row * 48, width: cellW, height: 34)
        }
        for i in 0..<8 {
            labels[i].frame = NSRect(x: left + CGFloat(i) * (cellW + gap) - 4, y: 18 + 2 * 48 + 2, width: cellW + 8, height: 14)
        }
        labels[8].frame = NSRect(x: 18, y: 18 + 9, width: 56, height: 16)
        labels[9].frame = NSRect(x: 18, y: 18 + 48 + 9, width: 56, height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        let th = Config.shared.theme
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        th.surface.withAlphaComponent(0.55).setFill()
        path.fill()
        th.border.setStroke()
        path.stroke()
    }
}
