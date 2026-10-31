import AppKit

/// A card in the top-right corner of a window: the offer to restore the last session at launch, or a long
/// command finishing in a background tab. Cards stack downwards (see `WindowRootView.showNotice`) and hide
/// themselves after `lifetime`, or on ✕.
final class CornerNoticeView: NSView {
    static let width: CGFloat = 300
    /// Cards grow past `width` to show their text whole, up to this.
    private static let maxWidth: CGFloat = 480
    private static let lineHeight: CGFloat = 17

    /// Clicking the card itself (not its button or ✕), e.g. to go to the tab it's about.
    var onClick: (() -> Void)?
    /// Called once the card has faded out and left the window.
    var onDismiss: ((CornerNoticeView) -> Void)?
    private let symbol: (name: String, color: NSColor)?
    private let titleLabel: NSTextField
    private let lineLabels: [NSTextField]
    private var actionButton: NSButton?
    private let closeButton = NSButton()
    /// The pointer is on ✕: it's highlighted, so it's clear the click closes the card.
    private var hoverClose = false { didSet { if hoverClose != oldValue { updateCloseImage(); needsDisplay = true } } }

    /// `lines` show under the title; the first is brighter (e.g. the tab), the rest dimmer, one line each.
    init(title: String, symbol: (name: String, color: NSColor)? = nil, lines: [String] = [],
         button: (title: String, action: () -> Void)? = nil, lifetime: TimeInterval) {
        self.symbol = symbol
        let th = Config.shared.theme
        titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        titleLabel.textColor = th.foreground
        titleLabel.lineBreakMode = .byTruncatingTail
        lineLabels = lines.enumerated().map { i, text in
            let l = NSTextField(labelWithString: text)
            l.font = .systemFont(ofSize: 11.5, weight: i == 0 ? .medium : .regular)
            l.textColor = i == 0 ? th.foreground.withAlphaComponent(0.85) : th.dimText
            l.lineBreakMode = .byTruncatingMiddle
            return l
        }
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 0))
        frame.size = NSSize(width: preferredWidth, height: preferredHeight)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.3
        layer?.shadowRadius = 10
        layer?.shadowOffset = CGSize(width: 0, height: -3)
        addSubview(titleLabel)
        lineLabels.forEach(addSubview)
        if let button {
            let b = SettingsPages.linkButton(button.title) { [weak self] in
                button.action()
                self?.dismiss()
            }
            actionButton = b
            addSubview(b)
        }
        updateCloseImage()
        closeButton.isBordered = false
        closeButton.target = self
        closeButton.action = #selector(close(_:))
        addSubview(closeButton)
        DispatchQueue.main.asyncAfter(deadline: .now() + lifetime) { [weak self] in self?.dismiss() }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    var preferredHeight: CGFloat { lineLabels.isEmpty ? 40 : 38 + CGFloat(lineLabels.count) * Self.lineHeight }

    /// Wide enough for the title and every line (the same insets as `layout`), between `width` and `maxWidth`.
    var preferredWidth: CGFloat {
        let x: CGFloat = symbol == nil ? 14 : 34
        let button = actionButton.map { $0.fittingSize.width + 8 } ?? 0
        let title = x + ceil(titleLabel.fittingSize.width) + 4 + button + 34
        let lines = lineLabels.map { x + ceil($0.fittingSize.width) + 14 }.max() ?? 0
        return min(Self.maxWidth, max(Self.width, title, lines))
    }

    override func layout() {
        super.layout()
        let top: CGFloat = lineLabels.isEmpty ? (bounds.height - 18) / 2 : 11
        closeButton.frame = NSRect(x: bounds.width - 30, y: top - 1, width: 20, height: 20)
        var right = closeButton.frame.minX - 4
        if let b = actionButton {
            let w = b.fittingSize.width
            b.frame = NSRect(x: right - w - 4, y: top - 1, width: w, height: 20)
            right = b.frame.minX - 4
        }
        let x: CGFloat = symbol == nil ? 14 : 34
        titleLabel.frame = NSRect(x: x, y: top, width: right - x, height: 17)
        for (i, l) in lineLabels.enumerated() {
            l.frame = NSRect(x: x, y: top + 22 + CGFloat(i) * Self.lineHeight, width: bounds.width - x - 14, height: 16)
        }
    }

    private func updateCloseImage() {
        let th = Config.shared.theme
        let cfg = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold).applying(.init(paletteColors: [hoverClose ? th.foreground : th.dimText]))
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Dismiss")?.withSymbolConfiguration(cfg)
    }

    override func draw(_ dirtyRect: NSRect) {
        let th = Config.shared.theme
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 9, yRadius: 9)
        th.surface.withAlphaComponent(1).setFill()
        path.fill()
        th.border.setStroke()
        path.stroke()
        if hoverClose {
            th.foreground.withAlphaComponent(0.14).setFill()
            NSBezierPath(roundedRect: closeButton.frame, xRadius: 5, yRadius: 5).fill()
        }
        if let symbol {
            // The mark in white on a disc of the color (one color for both left a plain disc).
            let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold).applying(.init(paletteColors: [.white, symbol.color]))
            if let img = NSImage(systemSymbolName: symbol.name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
                img.draw(in: NSRect(x: 13, y: titleLabel.frame.midY - img.size.height / 2, width: img.size.width, height: img.size.height))
            }
        }
    }

    // A hand over the buttons, and over the whole card when clicking it does something; the terminal underneath
    // doesn't get a say.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === self }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func cursorUpdate(with event: NSEvent) { track(event) }
    override func mouseMoved(with event: NSEvent) { track(event) }
    override func mouseEntered(with event: NSEvent) { track(event) }
    override func mouseExited(with event: NSEvent) { hoverClose = false }

    private func track(_ e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        hoverClose = closeButton.frame.contains(p)
        let onButton = hoverClose || actionButton?.frame.contains(p) == true
        (onButton || onClick != nil ? NSCursor.pointingHand : NSCursor.arrow).set()
    }

    override func mouseDown(with e: NSEvent) {
        guard let onClick else { return }
        onClick()
        dismiss()
    }

    @objc private func close(_ sender: Any?) { dismiss() }

    func dismiss() {
        guard superview != nil, alphaValue == 1 else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; animator().alphaValue = 0 }) { [weak self] in
            guard let self else { return }
            self.removeFromSuperview()
            self.onDismiss?(self)
        }
    }
}

/// In the corner of a pane whose ssh connection was lost: what to do about it, for as long as that's still the
/// question (the notice saying so goes away on its own, or gets closed).
final class ConnectionLostBar: NSView {
    static let height: CGFloat = 32
    private let label: NSTextField
    private let reconnectButton: NSButton
    private let closeButton: NSButton

    init(host: String, onReconnect: @escaping () -> Void, onClose: @escaping () -> Void) {
        let th = Config.shared.theme
        label = NSTextField(labelWithString: "Lost connection to \(host)")
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = th.foreground
        label.lineBreakMode = .byTruncatingMiddle
        reconnectButton = SettingsPages.linkButton("Reconnect", onReconnect)
        closeButton = SettingsPages.linkButton("Close", onClose)
        super.init(frame: .zero)
        [label, reconnectButton, closeButton].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    var preferredWidth: CGFloat {
        32 + ceil(label.fittingSize.width) + 12 + reconnectButton.fittingSize.width + 10 + closeButton.fittingSize.width + 12
    }

    override func layout() {
        super.layout()
        let closeW = closeButton.fittingSize.width, reconnectW = reconnectButton.fittingSize.width
        closeButton.frame = NSRect(x: bounds.width - closeW - 12, y: 6, width: closeW, height: 20)
        reconnectButton.frame = NSRect(x: closeButton.frame.minX - reconnectW - 10, y: 6, width: reconnectW, height: 20)
        label.frame = NSRect(x: 32, y: 7, width: max(0, reconnectButton.frame.minX - 44), height: 17)
    }

    override func draw(_ dirtyRect: NSRect) {
        let th = Config.shared.theme
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        th.surface.withAlphaComponent(1).setFill()
        path.fill()
        th.border.setStroke()
        path.stroke()
        let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold).applying(.init(paletteColors: [.white, th.red]))
        if let img = NSImage(systemSymbolName: "wifi.exclamationmark", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
            img.draw(in: NSRect(x: 11, y: (bounds.height - img.size.height) / 2, width: img.size.width, height: img.size.height))
        }
    }

    // Clicks and the pointer stay here, not with the terminal underneath.
    override func mouseDown(with e: NSEvent) {}

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === self }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .activeAlways, .inVisibleRect], owner: self))
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }

    func devPress(_ title: String) { [reconnectButton, closeButton].first { $0.title == title }?.performClick(nil) }
}

/// In the corner of a pane with several commands selected: what to do with them all.
final class BlockSelectionBar: NSView {
    static let height: CGFloat = 32
    private let label = NSTextField(labelWithString: "")
    private let copyButton: NSButton
    private var sendButton: NSButton!
    private let clearButton: NSButton

    init(onCopy: @escaping () -> Void, onSend: @escaping (NSView) -> Void, onClear: @escaping () -> Void) {
        let th = Config.shared.theme
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = th.foreground
        copyButton = SettingsPages.linkButton("Copy All", onCopy)
        clearButton = SettingsPages.linkButton("Clear", onClear)
        super.init(frame: .zero)
        sendButton = SettingsPages.linkButton("Send to Chat") { [weak self] in
            if let b = self?.sendButton { onSend(b) }
        }
        [label, copyButton, sendButton!, clearButton].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    var count = 0 {
        didSet {
            label.stringValue = "\(count) commands selected"
            needsLayout = true
            superview?.needsLayout = true
        }
    }

    var preferredWidth: CGFloat {
        14 + ceil(label.fittingSize.width) + [copyButton, sendButton!, clearButton].reduce(0) { $0 + 12 + $1.fittingSize.width } + 12
    }

    override func layout() {
        super.layout()
        var right = bounds.width - 12
        for b in [clearButton, sendButton!, copyButton] {
            let w = b.fittingSize.width
            b.frame = NSRect(x: right - w, y: 6, width: w, height: 20)
            right = b.frame.minX - 12
        }
        label.frame = NSRect(x: 14, y: 7, width: max(0, right - 14), height: 17)
    }

    override func draw(_ dirtyRect: NSRect) {
        let th = Config.shared.theme
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        th.surface.withAlphaComponent(1).setFill()
        path.fill()
        th.accent.withAlphaComponent(0.6).setStroke()
        path.stroke()
    }

    // Clicks and the pointer stay here, not with the terminal underneath.
    override func mouseDown(with e: NSEvent) {}

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === self }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .activeAlways, .inVisibleRect], owner: self))
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }

    func devPress(_ title: String) { [copyButton, sendButton!, clearButton].first { $0.title == title }?.performClick(nil) }
}
