import AppKit

// Files opened in a tab show above its terminal, VS Code style: a strip of file sub-tabs, then the active file.
// A tab can also hold just files (a "file tab", no terminal): double-click a file in the sidebar, or drag a
// sub-tab up onto the main tab strip.

/// The top part of a tab: the file sub-tabs and the active file's editor.
final class EditorAreaView: NSView {
    weak var tab: TabSession?
    let strip = FileTabStrip()
    private weak var shown: FileEditorView?
    /// Holds the file, clipped to the panel's rounded corners. Layer-backed from the start, as this view is: a file view
    /// made layer-backed itself once laid out lost its line numbers' room (the text ran under them, the gutter black).
    private let clip = NSView()

    init(tab: TabSession) {
        self.tab = tab
        super.init(frame: .zero)
        strip.tab = tab
        addSubview(strip)
        // A card (see `Cards`) from the start: becoming layer-backed later, mid-draw, can leave the file's scroll view
        // laid out without room for its line numbers.
        wantsLayer = true
        clip.wantsLayer = true
        clip.layer?.cornerRadius = FileTabStrip.radius
        clip.layer?.masksToBounds = true
        addSubview(clip)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// The file, below the sub-tabs: a rounded panel of its own inside the card, inset as the sub-tabs are (so their
    /// left edges line up) with corners concentric with the card's.
    private var panel: NSRect {
        let m = FileTabStrip.inset, top = showsStrip ? FileTabStrip.height : m
        return NSRect(x: m, y: top, width: max(0, bounds.width - 2 * m), height: max(0, bounds.height - top - m))
    }

    /// The sub-tabs show when there's more than the one file, or a terminal under it (see `TabSession.arrange`).
    private var showsStrip: Bool { tab.map { $0.showsTerminal || $0.editors.count > 1 } ?? true }

    /// A well in the card, set apart by its color alone: the card's outline is the only line around it, as around
    /// every other card (an edge of its own as well made a second border just inside the card's).
    override func draw(_ dirtyRect: NSRect) {
        let r = panel, radius = FileTabStrip.radius
        guard r.width > 0, r.height > 0 else { return }
        Self.fill(in: self).setFill()
        NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
    }

    /// What the file is drawn on, in `view`'s window; the active sub-tab is filled with it too, so it's one piece with
    /// the file it opens onto. Over a picture (the theme's or the desktop's), the theme's background made half again
    /// as solid as the window's, so the file stands apart from the terminal below it, as on Windows; on the window's
    /// own background, a shade darker than it (lighter's too faint on a light theme: a touch of the text color there).
    static func fill(in view: NSView) -> NSColor {
        let th = Config.shared.theme
        var root = view.superview
        while let v = root, !(v is WindowRootView) { root = v.superview }
        let shade = th.isDark ? NSColor.black.withAlphaComponent(0.22) : th.foreground.withAlphaComponent(0.05)
        guard let backdrop = (root as? WindowRootView)?.background.backdrop else { return shade }
        let cfg = Config.shared, base: CGFloat
        switch backdrop {
        case .none: return shade
        case .picture(_, let image): base = CGFloat(image.tint)
        case .wallpaper: base = cfg.opacity
        }
        return cfg.theme.background.withAlphaComponent(base + (1 - base) * 0.5)
    }

    func show(_ ed: FileEditorView) {
        if shown !== ed {
            shown?.removeFromSuperview()
            shown = ed
            clip.addSubview(ed)
        }
        needsLayout = true
        strip.needsDisplay = true
    }

    override func layout() {
        super.layout()
        strip.frame = NSRect(x: 0, y: 0, width: bounds.width, height: FileTabStrip.height)
        strip.isHidden = !showsStrip
        clip.frame = panel
        shown?.frame = clip.bounds
        needsDisplay = true
    }
}

/// Sub-tabs for a tab's open files. Click to switch, ✕ (or middle-click) to close, drag one up onto the main
/// tab strip to give it a tab of its own. The terminal button at the right shows or hides the tab's terminal.
final class FileTabStrip: NSView {
    static let height: CGFloat = 30
    weak var tab: TabSession?
    private var rects: [CGRect] = []
    private var closeRects: [CGRect] = []
    private var terminalRect: CGRect = .zero
    private var hover: Int?
    private var hoverClose = false
    private var hoverTerminal = false
    private var pressed: Int?
    private var pressPoint: NSPoint = .zero
    private var dragging = false
    /// While a sub-tab is dragged along the strip: the slot it would move to (editors.count = the end).
    private var insertBefore: Int?
    /// How far the sub-tabs are scrolled when they don't all fit beside the terminal button.
    private var scrollX: CGFloat = 0
    private var maxScrollX: CGFloat = 0
    /// The active sub-tab last scrolled into view, so switching or opening a file brings its sub-tab into sight
    /// without undoing the user's own scrolling otherwise.
    private weak var revealed: FileEditorView?
    /// ‹ and ›, when the sub-tabs don't all fit (as the main tab strip has them); the sub-tabs show between them.
    private var leftArrowRect: CGRect = .null
    private var rightArrowRect: CGRect = .null
    private var hoverArrow: Int?
    private var viewport: CGRect = .zero
    /// The arrows slide the sub-tabs rather than jump them.
    private var slide: (from: CGFloat, to: CGFloat, start: CFTimeInterval)?
    private var slideTimer: Timer?

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    private static let font = NSFont.systemFont(ofSize: 11.5, weight: .medium)

    private func layoutRects() {
        rects = []
        closeRects = []
        guard let tab else { return }
        // Everything floats `inset` in from the card's edges, so the sub-tabs' corners (`radius`) are concentric with
        // the card's own (Cards.radius = inset + radius) and the gaps around them are even.
        let m = Self.inset, h = bounds.height - 2 * m
        terminalRect = CGRect(x: bounds.width - m - h, y: m, width: h, height: h)
        let limit = terminalRect.minX - m
        let widths = tab.editors.map { ed in
            min(260, max(90, (ed.displayName as NSString).size(withAttributes: [.font: Self.font]).width + 56))
        }
        let total = widths.reduce(0, +) + CGFloat(max(0, widths.count - 1)) * m
        if m + total > limit {
            leftArrowRect = CGRect(x: m, y: m, width: 20, height: h)
            rightArrowRect = CGRect(x: limit - 20, y: m, width: 20, height: h)
            viewport = CGRect(x: leftArrowRect.maxX + 2, y: 0, width: rightArrowRect.minX - 2 - leftArrowRect.maxX - 2, height: bounds.height)
        } else {
            leftArrowRect = .null
            rightArrowRect = .null
            viewport = CGRect(x: 0, y: 0, width: max(0, limit), height: bounds.height)
        }
        let pad: CGFloat = leftArrowRect.isNull ? m : 2
        var laid: [CGRect] = []
        var x = viewport.minX + pad
        for w in widths {
            laid.append(CGRect(x: x, y: m, width: w, height: h))
            x += w + m
        }
        maxScrollX = max(0, x - m + pad - viewport.maxX)
        if tab.editors.indices.contains(tab.activeEditorIndex), tab.editors[tab.activeEditorIndex] !== revealed {
            revealed = tab.editors[tab.activeEditorIndex]
            stopSlide()
            let r = laid[tab.activeEditorIndex]
            if r.minX - pad - scrollX < viewport.minX { scrollX = r.minX - pad - viewport.minX }
            if r.maxX + pad - scrollX > viewport.maxX { scrollX = r.maxX + pad - viewport.maxX }
        }
        scrollX = min(max(0, scrollX), maxScrollX)
        for l in laid {
            let r = l.offsetBy(dx: -scrollX, dy: 0)
            rects.append(r)
            closeRects.append(CGRect(x: r.maxX - 20, y: r.midY - 8, width: 16, height: 16))
        }
    }

    /// The sub-tab under `p`, if it's in the part of the strip the sub-tabs show in (not under an arrow or the
    /// terminal button).
    private func index(at p: NSPoint) -> Int? {
        guard p.x >= viewport.minX, p.x < viewport.maxX else { return nil }
        return rects.firstIndex { $0.contains(p) }
    }

    override func scrollWheel(with e: NSEvent) {
        guard maxScrollX > 0 else { return super.scrollWheel(with: e) }
        // Sideways swipes, or an ordinary mouse wheel, move the sub-tabs.
        let d = abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY) ? e.scrollingDeltaX : e.scrollingDeltaY
        scroll(by: -(e.hasPreciseScrollingDeltas ? d : d * 24))
    }

    func scroll(by dx: CGFloat) {
        stopSlide()
        let to = min(max(0, scrollX + dx), maxScrollX)
        guard to != scrollX else { return }
        set(scrollX: to)
    }

    private func set(scrollX x: CGFloat) {
        scrollX = x
        layoutRects()
        if let w = window {
            let p = convert(w.mouseLocationOutsideOfEventStream, from: nil)
            hover = index(at: p)
            hoverClose = hover.map { closeRects[$0].contains(p) } ?? false
        }
        needsDisplay = true
    }

    /// ‹ / ›: three quarters of the visible strip that way. Pressing again on the way carries on from where it was heading.
    func slide(_ dir: Int) {
        let to = min(max(0, (slide?.to ?? scrollX) + CGFloat(dir) * viewport.width * 0.75), maxScrollX)
        guard to != scrollX else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { return set(scrollX: to) }
        slide = (scrollX, to, CACurrentMediaTime())
        guard slideTimer == nil else { return }
        let timer = Timer(timeInterval: 1 / 120, repeats: true) { [weak self] _ in self?.slideStep() }
        RunLoop.main.add(timer, forMode: .common)
        slideTimer = timer
    }

    private func slideStep() {
        guard let s = slide, window != nil else { return stopSlide() }
        let t = min(1, (CACurrentMediaTime() - s.start) / 0.24)
        set(scrollX: s.from + (s.to - s.from) * CGFloat(1 - pow(1 - t, 3)))
        if t >= 1 { stopSlide() }
    }

    private func stopSlide() {
        slideTimer?.invalidate()
        slideTimer = nil
        slide = nil
    }

    var devScrollState: String { "scroll=\(Int(scrollX)) of \(Int(maxScrollX)) arrows=\(!leftArrowRect.isNull)" }

    /// How far everything floats in from the card's edges, and the sub-tabs' corners: concentric with the card's. The
    /// file's panel below them (EditorAreaView) is inset and rounded the same.
    static let inset: CGFloat = 3
    static let radius: CGFloat = Cards.radius - inset

    private static func pill(_ r: CGRect) -> NSBezierPath {
        NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
    }

    override func draw(_ dirtyRect: NSRect) {
        // On the card's own background (see `Cards`). The sub-tabs float on it as pills, inset evenly from the card's
        // edges with corners concentric with its own, as the file's panel below is; the active one is a piece of that
        // file (its surface).
        let th = Config.shared.theme
        layoutRects()
        guard let tab else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: viewport).addClip()
        // In a layer of their own, so the edges can fade the sub-tabs out (the bar behind them is see-through).
        let cg = NSGraphicsContext.current?.cgContext
        cg?.beginTransparencyLayer(auxiliaryInfo: nil)
        for (i, ed) in tab.editors.enumerated() where rects[i].maxX > viewport.minX && rects[i].minX < viewport.maxX {
            let r = rects[i]
            let active = i == tab.activeEditorIndex
            if active {
                // The same flat surface as the file's panel below: one material, no edges.
                EditorAreaView.fill(in: self).setFill()
                Self.pill(r).fill()
            } else if hover == i {
                th.surface.withAlphaComponent(0.5).setFill()
                Self.pill(r).fill()
            }
            let name = ed.displayName
            if ed.mode == .file, let img = IconPacks.current?.icon(forName: name, directory: false, light: !th.isDark) {
                img.draw(in: NSRect(x: r.minX + 9, y: r.midY - 7, width: 14, height: 14))
            } else {
                drawSymbol(ed.mode, name, r, th)
            }
            let para = NSMutableParagraphStyle()
            para.lineBreakMode = .byTruncatingMiddle
            // Deleted from disk: struck through in red, as VS Code shows it.
            var attrs: [NSAttributedString.Key: Any] = [.font: Self.font, .paragraphStyle: para,
                                                         .foregroundColor: active ? th.foreground : th.foreground.withAlphaComponent(0.6)]
            if ed.isDeleted {
                attrs[.foregroundColor] = th.red.withAlphaComponent(active ? 1 : 0.75)
                attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            (name as NSString).draw(in: NSRect(x: r.minX + 30, y: r.midY - 7, width: r.width - 54, height: 16), withAttributes: attrs)
            // Unsaved: a dot where the ✕ goes, until hovered.
            let cr = closeRects[i]
            if hover == i || active {
                if hover == i && hoverClose {
                    th.foreground.withAlphaComponent(0.12).setFill()
                    NSBezierPath(roundedRect: cr, xRadius: 4, yRadius: 4).fill()
                }
                if ed.isDirty && !(hover == i) {
                    th.foreground.withAlphaComponent(0.7).setFill()
                    NSBezierPath(ovalIn: cr.insetBy(dx: 4.5, dy: 4.5)).fill()
                } else {
                    th.foreground.withAlphaComponent(0.6).setStroke()
                    let x = NSBezierPath()
                    x.lineWidth = 1.2
                    x.lineCapStyle = .round
                    x.move(to: NSPoint(x: cr.minX + 5, y: cr.minY + 5)); x.line(to: NSPoint(x: cr.maxX - 5, y: cr.maxY - 5))
                    x.move(to: NSPoint(x: cr.maxX - 5, y: cr.minY + 5)); x.line(to: NSPoint(x: cr.minX + 5, y: cr.maxY - 5))
                    x.stroke()
                }
            } else if ed.isDirty {
                th.foreground.withAlphaComponent(0.7).setFill()
                NSBezierPath(ovalIn: cr.insetBy(dx: 4.5, dy: 4.5)).fill()
            }
        }
        // Where a sub-tab dragged along the strip would land.
        if dragging, let ins = insertBefore, let from = pressed, ins != from, ins != from + 1 {
            let x = ins < rects.count ? rects[ins].minX - 1.5 : (rects.last?.maxX ?? 6) + 0.5
            th.accent.setFill()
            NSBezierPath(roundedRect: NSRect(x: x - 1, y: 4, width: 2.5, height: bounds.height - 8), xRadius: 1.25, yRadius: 1.25).fill()
        }
        // More sub-tabs that way: they fade out at the edge instead of stopping in a hard cut.
        cg?.setBlendMode(.destinationOut)
        if scrollX > 0.5, let g = NSGradient(starting: .black, ending: .clear) {
            g.draw(in: NSRect(x: viewport.minX, y: 0, width: 20, height: bounds.height - 1), angle: 0)
        }
        if scrollX < maxScrollX - 0.5, let g = NSGradient(starting: .clear, ending: .black) {
            g.draw(in: NSRect(x: viewport.maxX - 20, y: 0, width: 20, height: bounds.height - 1), angle: 0)
        }
        cg?.endTransparencyLayer()
        NSGraphicsContext.restoreGraphicsState()
        drawArrows(th)

        // Show / hide this tab's terminal.
        if hoverTerminal {
            th.surface.withAlphaComponent(0.7).setFill()
            Self.pill(terminalRect).fill()
        }
        let tc = tab.showsTerminal ? th.accent : th.foreground.withAlphaComponent(hoverTerminal ? 0.9 : 0.55)
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium).applying(.init(paletteColors: [tc]))
        if let img = NSImage(systemSymbolName: "terminal", accessibilityDescription: "Terminal")?.withSymbolConfiguration(config) {
            img.draw(in: NSRect(x: terminalRect.midX - img.size.width / 2, y: terminalRect.midY - img.size.height / 2,
                                width: img.size.width, height: img.size.height))
        }
    }

    /// ‹ and ›, as the main tab strip draws them: bright when there's more that way, faint at the end.
    private func drawArrows(_ th: Theme) {
        for (dir, r) in [(-1, leftArrowRect), (1, rightArrowRect)] where !r.isNull {
            let more = dir < 0 ? scrollX > 0.5 : scrollX < maxScrollX - 0.5
            if more && hoverArrow == dir {
                th.surface.withAlphaComponent(0.7).setFill()
                Self.pill(r).fill()
            }
            let color = th.foreground.withAlphaComponent(more ? (hoverArrow == dir ? 0.95 : 0.7) : 0.18)
            let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold).applying(.init(paletteColors: [color]))
            if let img = NSImage(systemSymbolName: dir < 0 ? "chevron.left" : "chevron.right", accessibilityDescription: nil)?
                .withSymbolConfiguration(config) {
                img.draw(in: NSRect(x: r.midX - img.size.width / 2, y: r.midY - img.size.height / 2, width: img.size.width, height: img.size.height))
            }
        }
    }

    /// Solanum's own tab icon: what the tab shows, or the kind of file.
    static func symbol(_ mode: EditorMode, _ name: String) -> String {
        switch mode {
        case .diff, .stagedDiff, .commitDiff: return "plusminus"
        case .commit: return "smallcircle.filled.circle"
        case .status: return "square.and.pencil"
        case .graph: return "arrow.triangle.branch"
        case .preview: return "doc.richtext"
        case .file: return FileSidebarView.symbol(for: name)
        case .extensions: return "puzzlepiece.extension"
        case .extensionPage(let id): return id == SleeperExtension.id ? "football" : "puzzlepiece.extension"
        }
    }

    private func drawSymbol(_ mode: EditorMode, _ name: String, _ r: NSRect, _ th: Theme) {
        // An extension's page: its own icon (Sleeper's logo), as on its card in Extensions.
        if case .extensionPage(let id) = mode, let ext = Extensions.find(id) {
            return ext.drawIcon(NSRect(x: r.minX + 9, y: (r.midY - 7).rounded(), width: 14, height: 14))
        }
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular).applying(.init(paletteColors: [th.dimText]))
        if let img = NSImage(systemSymbolName: Self.symbol(mode, name), accessibilityDescription: nil)?.withSymbolConfiguration(config) {
            img.draw(in: NSRect(x: r.minX + 9, y: r.midY - img.size.height / 2, width: img.size.width, height: img.size.height))
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === self }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        let h = index(at: p)
        let hc = h.map { closeRects[$0].contains(p) } ?? false
        let ht = terminalRect.contains(p)
        let ha = leftArrowRect.contains(p) ? -1 : rightArrowRect.contains(p) ? 1 : nil
        if h != hover || hc != hoverClose || ht != hoverTerminal || ha != hoverArrow {
            hover = h
            hoverClose = hc
            hoverTerminal = ht
            hoverArrow = ha
            toolTip = ht ? (tab?.showsTerminal == true ? "Hide Terminal" : "Show Terminal")
                : h.flatMap { i in tab.map { $0.editors[i].path } }
            needsDisplay = true
        }
    }

    override func mouseExited(with e: NSEvent) {
        hover = nil
        hoverClose = false
        hoverTerminal = false
        hoverArrow = nil
        needsDisplay = true
    }

    override func mouseDown(with e: NSEvent) {
        guard let tab else { return }
        let p = convert(e.locationInWindow, from: nil)
        if terminalRect.contains(p) { return tab.toggleTerminal() }
        if leftArrowRect.contains(p) { return slide(-1) }
        if rightArrowRect.contains(p) { return slide(1) }
        guard let i = index(at: p) else { return }
        if closeRects[i].contains(p) { return tab.editors[i].requestClose() }
        pressed = i
        pressPoint = p
        dragging = false
    }

    override func mouseDragged(with e: NSEvent) {
        guard let tab, let i = pressed, tab.editors.indices.contains(i) else { return }
        let p = convert(e.locationInWindow, from: nil)
        guard dragging || hypot(p.x - pressPoint.x, p.y - pressPoint.y) > 6 else { return }
        if !dragging { NSCursor.closedHand.push() }
        dragging = true
        // Along the strip: reorder. Off it: a tab of its own, or the other column (see editorDragOver).
        if bounds.contains(p) {
            tab.windowController?.clearEditorDrop()
            // Near either end of a scrolling strip, carry the sub-tab on past the ones out of view.
            if maxScrollX > 0 {
                if p.x < viewport.minX + 24 { scroll(by: -14) } else if p.x > viewport.maxX - 24 { scroll(by: 14) }
            }
            insertBefore = rects.firstIndex { $0.midX > p.x } ?? rects.count
        } else {
            insertBefore = nil
            tab.windowController?.editorDragOver(tab.editors[i], from: tab, at: e.locationInWindow,
                                                 grabX: rects.indices.contains(i) ? pressPoint.x - rects[i].minX : 20)
        }
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        defer { pressed = nil; dragging = false; insertBefore = nil; needsDisplay = true }
        guard let tab, let i = pressed, tab.editors.indices.contains(i) else { return }
        if dragging {
            NSCursor.pop()
            if let ins = insertBefore {
                tab.moveEditor(from: i, to: ins > i ? ins - 1 : ins)
            } else {
                tab.windowController?.performEditorDrop()
            }
        } else {
            tab.activateEditor(i)
        }
    }

    override func otherMouseUp(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if let i = index(at: p) { tab?.editors[i].requestClose() }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        // Shown as Solanum's dropdown (see ThemedDropdown.show(_:at:in:)).
        guard let tab else { return nil }
        let p = convert(event.locationInWindow, from: nil)
        guard let i = index(at: p) else { return nil }
        let ed = tab.editors[i]
        let m = NSMenu()
        if tab.showsTerminal || tab.editors.count > 1 {
            m.addItem(ActionMenuItem("Open in Its Own Tab") { [weak tab] in tab?.windowController?.moveEditorToOwnTab(ed, from: tab) })
        }
        m.addItem(ActionMenuItem("Close") { ed.requestClose() })
        if tab.editors.count > 1 {
            m.addItem(ActionMenuItem("Close Others") { [weak tab] in
                tab?.editors.filter { $0 !== ed }.forEach { $0.requestClose() }
            })
        }
        ThemedDropdown.show(m, at: p, in: self)
        return nil
    }
}
