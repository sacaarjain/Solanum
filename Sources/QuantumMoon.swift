import AppKit

/// An easter egg for the Quantum Moon theme. Like the moon in Outer Wilds, its icon only moves while nobody is
/// looking: each time Solanum comes back to the front, the moon may have left its place beside the theme name
/// (which stays) for the flower's corner of the tab bar, or for the status bar's left side by the folder path.
/// Caught there and clicked, it shows a line from the game: Bells' and Solanum's, taking turns.
enum QuantumMoon {
    enum Spot: CaseIterable { case home, flower, folders }

    private(set) static var spot = Spot.home
    private static var observers: [NSObjectProtocol] = []

    /// The theme is Quantum Moon with its icon showing.
    static var active: Bool { Config.shared.themeIcon && PlanetArt.planet(for: Config.shared.theme) == .quantumMoon }

    /// The moon is at `s` right now.
    static func at(_ s: Spot) -> Bool { active && spot == s }

    static func start() {
        guard observers.isEmpty else { return }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                                object: nil, queue: .main) { _ in
            guard active else { return }
            // Home half the time; otherwise one of the other spots.
            move(to: Bool.random() ? .home : [.flower, .folders].randomElement()!)
        })
    }

    static func move(to next: Spot) {
        guard next != spot else { return }
        spot = next
        for w in NSApp.windows { w.contentView.map(redraw) }
    }

    private static func redraw(_ v: NSView) {
        if v is StatusBarView || v is TabBarView { v.needsDisplay = true }
        v.subviews.forEach(redraw)
    }

    private static let encountersKey = "QuantumMoonEncounters"

    /// A line from Outer Wilds, in an alert-like panel under the quantum symbol: Bells' and Solanum's take turns,
    /// Bells first (the turn is kept across launches).
    static func showQuote(over window: NSWindow?) {
        let seen = UserDefaults.standard.integer(forKey: encountersKey)
        UserDefaults.standard.set(seen + 1, forKey: encountersKey)
        let quote = seen % 2 == 0
            ? "“Be curious on your journey.”\n\n— Bells"
            : "“As a child, I considered such unknowns sinister. Now, though, I understand they bear no ill will. "
                + "The universe is, and we are.”\n\n— Solanum"
        QuotePanel(quote: quote).run(over: window)
    }

    /// NSAlert keeps its icon small and in the corner; this is laid out like one, centered, with the art large.
    private final class QuotePanel: NSPanel {
        private static let width: CGFloat = 300

        init(quote: String) {
            super.init(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 100),
                       styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
            titlebarAppearsTransparent = true
            titleVisibility = .hidden
            isMovableByWindowBackground = true
            [.closeButton, .miniaturizeButton, .zoomButton].forEach { standardWindowButton($0)?.isHidden = true }

            let effect = NSVisualEffectView()
            effect.material = .popover
            effect.blendingMode = .behindWindow
            effect.state = .active
            contentView = effect

            let art = NSImageView()
            art.image = Bundle.main.image(forResource: "QuantumMoon").map { QuantumMoon.rounded($0) }
            art.imageScaling = .scaleProportionallyUpOrDown
            let title = NSTextField(labelWithString: "Quantum Moon")
            title.font = .systemFont(ofSize: 15, weight: .bold)
            title.alignment = .center
            let text = NSTextField(wrappingLabelWithString: quote)
            text.font = .systemFont(ofSize: 13)
            text.alignment = .center
            text.preferredMaxLayoutWidth = Self.width - 48
            let ok = NSButton(title: "OK", target: self, action: #selector(done))
            ok.keyEquivalent = "\r"
            ok.controlSize = .large

            let stack = NSStackView(views: [art, title, text, ok])
            stack.orientation = .vertical
            stack.alignment = .centerX
            stack.spacing = 12
            stack.setCustomSpacing(16, after: art)
            stack.setCustomSpacing(20, after: text)
            stack.edgeInsets = NSEdgeInsets(top: 28, left: 24, bottom: 20, right: 24)
            stack.translatesAutoresizingMaskIntoConstraints = false
            effect.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: effect.topAnchor),
                stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
                stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
                effect.widthAnchor.constraint(equalToConstant: Self.width),
                art.widthAnchor.constraint(equalToConstant: 150),
                art.heightAnchor.constraint(equalToConstant: 150),
                text.widthAnchor.constraint(equalToConstant: Self.width - 48),
                ok.widthAnchor.constraint(equalToConstant: Self.width - 48),
            ])
        }

        /// Centered on `parent` (the screen when there isn't one).
        func run(over parent: NSWindow?) {
            layoutIfNeeded()
            if let p = parent?.frame {
                setFrameOrigin(NSPoint(x: (p.midX - frame.width / 2).rounded(), y: (p.midY - frame.height / 2).rounded()))
            } else {
                center()
            }
            NSApp.runModal(for: self)
            orderOut(nil)
        }

        @objc private func done() { NSApp.stopModal() }
        override func cancelOperation(_ sender: Any?) { done() }
        override var canBecomeKey: Bool { true }
    }

    /// The art (a black square) with rounded corners, like an app icon.
    fileprivate static func rounded(_ img: NSImage) -> NSImage {
        let side: CGFloat = 300
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { r in
            NSBezierPath(roundedRect: r, xRadius: side * 0.22, yRadius: side * 0.22).addClip()
            img.draw(in: r)
            return true
        }
    }

    /// Draws the moon in `rect` of a flipped view `height` tall (the art is drawn y-up).
    static func draw(in rect: CGRect, viewHeight height: CGFloat) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.translateBy(x: 0, y: height)
        ctx.scaleBy(x: 1, y: -1)
        PlanetArt.draw(.quantumMoon, in: ctx, rect: CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height), icon: true)
        ctx.restoreGState()
    }
}
