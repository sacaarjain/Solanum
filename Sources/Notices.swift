import AppKit

/// A card in the top-right corner of a window: the offer to restore the last session at launch, or a long
/// command finishing in a background tab. Cards stack downwards (see `WindowRootView.showNotice`) and hide
/// themselves after `lifetime`, or on ✕.
final class CornerNoticeView: NSView {
    static let width: CGFloat = 300
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
        frame.size.height = preferredHeight
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
        let cfg = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold).applying(.init(paletteColors: [th.dimText]))
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Dismiss")?.withSymbolConfiguration(cfg)
        closeButton.isBordered = false
        closeButton.target = self
        closeButton.action = #selector(close(_:))
        addSubview(closeButton)
        DispatchQueue.main.asyncAfter(deadline: .now() + lifetime) { [weak self] in self?.dismiss() }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    var preferredHeight: CGFloat { lineLabels.isEmpty ? 40 : 38 + CGFloat(lineLabels.count) * Self.lineHeight }

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

    override func draw(_ dirtyRect: NSRect) {
        let th = Config.shared.theme
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 9, yRadius: 9)
        th.surface.withAlphaComponent(1).setFill()
        path.fill()
        th.border.setStroke()
        path.stroke()
        if let symbol {
            // The mark in white on a disc of the color (one color for both left a plain disc).
            let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold).applying(.init(paletteColors: [.white, symbol.color]))
            if let img = NSImage(systemSymbolName: symbol.name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
                img.draw(in: NSRect(x: 13, y: titleLabel.frame.midY - img.size.height / 2, width: img.size.width, height: img.size.height))
            }
        }
    }

    override func resetCursorRects() {
        if onClick != nil { addCursorRect(bounds, cursor: .pointingHand) }
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
