import AppKit

/// A message in Solanum's own colors instead of an NSAlert: the window dims and a card in the middle shows a mark
/// (the flower, or a symbol on a colored disc), a title, the text and an OK button. OK, Return, Escape or a click
/// outside the card closes it. It lives inside the window, so it never takes over another one or the app.
final class ThemedAlertView: NSView {
    private static let cardWidth: CGFloat = 320
    private static let flower = SolanumArt.flowerImage(size: 128)

    private let symbol: (name: String, color: NSColor)?
    private let titleLabel: NSTextField
    private let textLabel: NSTextField
    private let okButton = AlertButton()
    private var card = NSRect.zero
    private var onClose: (() -> Void)?
    private var closing = false
    private weak var previousResponder: NSResponder?

    /// Shows the message over `window` (the key window when nil); without a window it falls back to an NSAlert.
    @discardableResult
    static func show(_ title: String, _ text: String, symbol: (name: String, color: NSColor)? = nil,
                     in window: NSWindow? = nil, onClose: (() -> Void)? = nil) -> ThemedAlertView? {
        guard let w = window ?? NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeKey }),
              let content = w.contentView else {
            if !Headless.active {
                let a = NSAlert()
                a.messageText = title
                a.informativeText = text
                a.runModal()
            }
            onClose?()
            return nil
        }
        // One at a time: an alert already up goes at once (and hands back the focus it took).
        content.subviews.compactMap { $0 as? ThemedAlertView }.forEach { $0.close(animated: false) }
        let v = ThemedAlertView(title: title, text: text, symbol: symbol)
        v.onClose = onClose
        v.frame = content.bounds
        v.autoresizingMask = [.width, .height]
        v.alphaValue = 0
        content.addSubview(v, positioned: .above, relativeTo: nil)
        v.previousResponder = w.firstResponder
        w.makeFirstResponder(v)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; v.animator().alphaValue = 1 }
        return v
    }

    private init(title: String, text: String, symbol: (name: String, color: NSColor)?) {
        self.symbol = symbol
        let th = Config.shared.theme
        titleLabel = NSTextField(wrappingLabelWithString: title)
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = th.foreground
        titleLabel.alignment = .center
        textLabel = NSTextField(wrappingLabelWithString: text)
        textLabel.font = .systemFont(ofSize: 12.5)
        textLabel.textColor = th.dimText
        textLabel.alignment = .center
        textLabel.isSelectable = true
        textLabel.maximumNumberOfLines = 12
        textLabel.cell?.truncatesLastVisibleLine = true
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(titleLabel)
        addSubview(textLabel)
        okButton.title = "OK"
        okButton.onPress = { [weak self] in self?.close() }
        addSubview(okButton)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private let pad: CGFloat = 22
    private let markSize: CGFloat = 56

    override func layout() {
        super.layout()
        let w = Self.cardWidth, inner = w - 2 * pad
        let titleH = ceil(titleLabel.sizeThatFits(NSSize(width: inner, height: .greatestFiniteMagnitude)).height)
        let textH = ceil(textLabel.sizeThatFits(NSSize(width: inner, height: .greatestFiniteMagnitude)).height)
        let h = pad + markSize + 14 + titleH + 6 + textH + 20 + 30 + pad
        card = NSRect(x: round((bounds.width - w) / 2), y: round((bounds.height - h) / 2), width: w, height: h)
        var y = card.minY + pad + markSize + 14
        titleLabel.frame = NSRect(x: card.minX + pad, y: y, width: inner, height: titleH)
        y += titleH + 6
        textLabel.frame = NSRect(x: card.minX + pad, y: y, width: inner, height: textH)
        y += textH + 20
        okButton.frame = NSRect(x: card.minX + pad, y: y, width: inner, height: 30)
    }

    override func draw(_ dirtyRect: NSRect) {
        let th = Config.shared.theme
        NSColor.black.withAlphaComponent(th.isDark ? 0.4 : 0.22).setFill()
        bounds.fill()

        // The card, with a soft shadow under it.
        let path = NSBezierPath(roundedRect: card.insetBy(dx: 0.5, dy: 0.5), xRadius: 14, yRadius: 14)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 24
        shadow.shadowOffset = NSSize(width: 0, height: -6)
        shadow.set()
        th.background.mix(th.isDark ? .white : .black, th.isDark ? 0.06 : 0.02).withAlphaComponent(1).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        th.border.setStroke()
        path.stroke()

        let mark = NSRect(x: card.midX - markSize / 2, y: card.minY + pad, width: markSize, height: markSize)
        if let symbol {
            symbol.color.withAlphaComponent(0.16).setFill()
            NSBezierPath(ovalIn: mark).fill()
            let cfg = NSImage.SymbolConfiguration(pointSize: 24, weight: .bold).applying(.init(paletteColors: [symbol.color]))
            if let img = NSImage(systemSymbolName: symbol.name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
                img.draw(in: NSRect(x: mark.midX - img.size.width / 2, y: mark.midY - img.size.height / 2,
                                    width: img.size.width, height: img.size.height))
            }
        } else {
            Self.flower.draw(in: mark.insetBy(dx: -4, dy: -4))
        }
    }

    // Clicks outside the card close it; nothing reaches the window underneath.
    override func mouseDown(with event: NSEvent) {
        if !card.contains(convert(event.locationInWindow, from: nil)) { close() }
    }
    override func rightMouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === self }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .activeAlways, .inVisibleRect], owner: self))
    }
    override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76, 53, 49: close()     // Return, Enter, Escape, Space
        default: if event.modifierFlags.contains(.command) { super.keyDown(with: event) }
        }
    }
    override func cancelOperation(_ sender: Any?) { close() }

    func close(animated: Bool = true) {
        guard superview != nil, !closing else { return }
        closing = true
        let done = onClose
        onClose = nil
        if let w = window, w.firstResponder === self {
            let back = (previousResponder as? NSView).flatMap { $0.window === w ? $0 : nil } ?? (previousResponder as? NSWindow)
            w.makeFirstResponder(back)
        }
        if animated {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.12; animator().alphaValue = 0 }) { [weak self] in
                self?.removeFromSuperview()
            }
        } else {
            removeFromSuperview()
        }
        done?()
    }

    func devPress() { okButton.onPress?() }
}

/// The alert's filled accent button, a little lighter under the pointer and darker while pressed.
private final class AlertButton: NSView {
    var title = ""
    var onPress: (() -> Void)?
    private var hovering = false { didSet { needsDisplay = true } }
    private var pressed = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let accent = Config.shared.theme.accent
        let fill = pressed ? accent.mix(.black, 0.15) : hovering ? accent.mix(.white, 0.1) : accent
        fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let text: NSColor = fill.luminance > 0.6 ? .black : .white
        let size = (title as NSString).size(withAttributes: [.font: font])
        (title as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
                                 withAttributes: [.font: font, .foregroundColor: text])
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === self }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect], owner: self))
    }
    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseDragged(with event: NSEvent) { pressed = bounds.contains(convert(event.locationInWindow, from: nil)) }
    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        if inside { onPress?() }
    }
}
