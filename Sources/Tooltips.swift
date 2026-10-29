import AppKit

/// Solanum's own tooltips in place of AppKit's: a small bubble in the theme's colors under the pointer, with a
/// trailing shortcut ("Pin This Folder (⇧⌘B)") set apart. Views keep setting `toolTip` as usual (also changing it
/// as the pointer moves over their parts); once the pointer rests, this reads it from the view under the pointer.
final class Tooltips {
    static let shared = Tooltips()

    private let panel: NSPanel
    private let bubble = TooltipBubble()
    private var restTimer: Timer?
    /// Re-checks while a tip shows, for leaving the window (no mouse-moved event arrives then).
    private var watchTimer: Timer?
    private var monitor: Any?
    private var shown: String?
    private var hiddenAt = Date.distantPast
    /// A tip clicked through stays away until the pointer reaches something else.
    private var dismissed: String?

    private init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.contentView = bubble
    }

    func start() {
        // AppKit's tooltips put off indefinitely (the delay is in milliseconds), so only these show.
        UserDefaults.standard.set(1_000_000_000, forKey: "NSInitialToolTipDelay")
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown,
                                                              .scrollWheel, .keyDown, .leftMouseDragged]) { [weak self] e in
            self?.handle(e)
            return e
        }
        let nc = NotificationCenter.default
        // Mouse-moved events only arrive for windows that ask for them.
        NSApp.windows.forEach { $0.acceptsMouseMovedEvents = true }
        nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            (note.object as? NSWindow)?.acceptsMouseMovedEvents = true
        }
        nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.hide()
        }
    }

    private func handle(_ e: NSEvent) {
        switch e.type {
        case .mouseMoved:
            if shown != nil {
                // After the view under the pointer has handled the move (and maybe changed its tip).
                DispatchQueue.main.async { [weak self] in self?.update() }
            } else {
                // Straight on from one tip to the next; otherwise once the pointer rests.
                let delay = Date().timeIntervalSince(hiddenAt) < 0.5 ? 0.05 : 0.6
                restTimer?.invalidate()
                restTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in self?.update() }
            }
        default:
            restTimer?.invalidate()
            // A click also dismisses a tip that hadn't shown yet; keys and scrolling only the one showing.
            let clicked = [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(e.type)
            if let s = shown ?? (clicked ? tipUnderPointer() : nil) { dismissed = s }
            hide(quietly: true)
        }
    }

    private func update() {
        guard NSApp.isActive, let tip = tipUnderPointer() else {
            dismissed = nil
            return hide()
        }
        if tip == dismissed { return hide(quietly: true) }
        dismissed = nil
        if tip != shown { show(tip) }
    }

    private func show(_ tip: String) {
        let th = Config.shared.theme
        panel.appearance = NSAppearance(named: th.isDark ? .darkAqua : .aqua)
        bubble.set(tip)
        let size = bubble.fittingSize
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        // Below and just right of the pointer's tip, kept on screen; above the pointer when there's no room below.
        var origin = NSPoint(x: mouse.x - 6, y: mouse.y - 24 - size.height)
        if origin.y < screen.minY { origin.y = mouse.y + 10 }
        origin.x = min(max(origin.x, screen.minX + 4), screen.maxX - size.width - 4)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        if shown == nil {
            panel.alphaValue = 0
            panel.orderFront(nil)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                panel.animator().alphaValue = 1
            }
        }
        shown = tip
        if watchTimer == nil {
            watchTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.update() }
        }
    }

    /// `quietly`: after a click or key press, the next tip waits for the pointer to rest again.
    private func hide(quietly: Bool = false) {
        watchTimer?.invalidate()
        watchTimer = nil
        guard shown != nil else { return }
        shown = nil
        panel.orderOut(nil)
        hiddenAt = quietly ? .distantPast : Date()
    }

    /// The tip of the innermost view under the pointer that has one (labels that let clicks through count too).
    private func tipUnderPointer() -> String? {
        let mouse = NSEvent.mouseLocation
        let number = NSWindow.windowNumber(at: mouse, belowWindowWithWindowNumber: panel.isVisible ? panel.windowNumber : 0)
        guard let win = NSApp.window(withWindowNumber: number), win !== panel, win.isVisible,
              let root = win.contentView?.superview ?? win.contentView else { return nil }
        let p = win.convertPoint(fromScreen: mouse)
        // Hit-testing passes over overlays that let the mouse through (e.g. the window's tab-drop preview, which
        // covers it all); the view hit can still hold such a label with a tip of its own.
        guard let hit = root.hitTest(p) else { return nil }
        if let t = Self.tip(within: hit, at: p) { return t }
        var view = hit.superview
        while let v = view {
            if let t = v.toolTip, !t.isEmpty { return t }
            view = v.superview
        }
        return nil
    }

    /// The tip of the innermost view under the point in `v`'s subtree, `v`'s own last.
    private static func tip(within v: NSView, at windowPoint: NSPoint) -> String? {
        guard !v.isHidden, v.alphaValue > 0, v.isMousePoint(v.convert(windowPoint, from: nil), in: v.bounds) else { return nil }
        for sub in v.subviews.reversed() {
            if let t = tip(within: sub, at: windowPoint) { return t }
        }
        if let t = v.toolTip, !t.isEmpty { return t }
        return nil
    }
}

/// The bubble: rounded, in the theme's raised surface with a hairline border; a trailing "(⇧⌘B)" shows dimmer,
/// without its parentheses.
private final class TooltipBubble: NSView {
    private var text = NSAttributedString()
    private static let pad = NSSize(width: 8, height: 4.5)
    private static let maxTextWidth: CGFloat = 300

    func set(_ tip: String) {
        let th = Config.shared.theme
        let font = NSFont.systemFont(ofSize: 11.5)
        let s = NSMutableAttributedString(string: tip, attributes: [.font: font, .foregroundColor: th.foreground])
        if let m = tip.range(of: #"\s*\(([⌃⌥⇧⌘][^()]*)\)$"#, options: .regularExpression) {
            let keys = tip[m].trimmingCharacters(in: .whitespaces).dropFirst().dropLast()
            s.replaceCharacters(in: NSRange(m, in: tip), with: NSAttributedString(string: "   " + keys, attributes: [
                .font: NSFont.systemFont(ofSize: 11.5, weight: .medium), .foregroundColor: th.dimText]))
        }
        text = s
        needsDisplay = true
    }

    private var textSize: NSSize {
        let r = text.boundingRect(with: NSSize(width: Self.maxTextWidth, height: 1000), options: [.usesLineFragmentOrigin, .usesFontLeading])
        return NSSize(width: ceil(r.width), height: ceil(r.height))
    }

    override var fittingSize: NSSize {
        let t = textSize
        return NSSize(width: t.width + Self.pad.width * 2, height: t.height + Self.pad.height * 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        let th = Config.shared.theme
        let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        th.surface.mix(th.isDark ? .white : .black, 0.04).setFill()
        box.fill()
        th.foreground.withAlphaComponent(th.isDark ? 0.16 : 0.18).setStroke()
        box.lineWidth = 1
        box.stroke()
        let t = textSize
        text.draw(with: NSRect(x: Self.pad.width, y: (bounds.height - t.height) / 2, width: t.width, height: t.height),
                  options: [.usesLineFragmentOrigin, .usesFontLeading])
    }
}
