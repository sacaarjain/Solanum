import AppKit

// Files opened in a tab show above its terminal, VS Code style: a strip of file sub-tabs, then the active file.
// A tab can also hold just files (a "file tab", no terminal): double-click a file in the sidebar, or drag a
// sub-tab up onto the main tab strip.

/// The top part of a tab: the file sub-tabs and the active file's editor.
final class EditorAreaView: NSView {
    weak var tab: TabSession?
    let strip = FileTabStrip()
    private weak var shown: FileEditorView?

    init(tab: TabSession) {
        self.tab = tab
        super.init(frame: .zero)
        strip.tab = tab
        addSubview(strip)
        // A card (see `Cards`) from the start: becoming layer-backed later, mid-draw, can leave the file's scroll view
        // laid out without room for its line numbers.
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// Over a picture (the theme's or the desktop's), the file is on the theme's background made half again as solid
    /// as the window's, so it stands apart from the terminal below it rather than running into it, as on Windows. With
    /// no picture the window's own background shows through as before.
    override func draw(_ dirtyRect: NSRect) {
        guard let fill = Self.fill(in: self) else { return }
        fill.setFill()
        NSRect(x: 0, y: FileTabStrip.height, width: bounds.width, height: max(0, bounds.height - FileTabStrip.height)).fill()
    }

    /// What the file is drawn on, in `view`'s window: nil without a picture behind it (the window's own background).
    /// The active sub-tab is filled with it too, so it's one piece with the file it opens onto.
    static func fill(in view: NSView) -> NSColor? {
        var root = view.superview
        while let v = root, !(v is WindowRootView) { root = v.superview }
        guard let backdrop = (root as? WindowRootView)?.background.backdrop else { return nil }
        let cfg = Config.shared, base: CGFloat
        switch backdrop {
        case .none: return nil
        case .picture(_, let image): base = CGFloat(image.tint)
        case .wallpaper: base = cfg.opacity
        }
        return cfg.theme.background.withAlphaComponent(base + (1 - base) * 0.5)
    }

    func show(_ ed: FileEditorView) {
        if shown !== ed {
            shown?.removeFromSuperview()
            shown = ed
            addSubview(ed)
        }
        needsLayout = true
        strip.needsDisplay = true
    }

    override func layout() {
        super.layout()
        strip.frame = NSRect(x: 0, y: 0, width: bounds.width, height: FileTabStrip.height)
        shown?.frame = NSRect(x: 0, y: FileTabStrip.height, width: bounds.width, height: max(0, bounds.height - FileTabStrip.height))
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
        terminalRect = CGRect(x: bounds.width - 30, y: (bounds.height - 22) / 2, width: 22, height: 22)
        let limit = terminalRect.minX - 4
        let widths = tab.editors.map { ed in
            min(260, max(90, (ed.displayName as NSString).size(withAttributes: [.font: Self.font]).width + 56))
        }
        let total = widths.reduce(0, +) + CGFloat(max(0, widths.count - 1)) * 2
        if 6 + total + 4 > limit {
            let h: CGFloat = 22, y = (bounds.height - h) / 2
            leftArrowRect = CGRect(x: 4, y: y, width: 20, height: h)
            rightArrowRect = CGRect(x: limit - 20, y: y, width: 20, height: h)
            viewport = CGRect(x: leftArrowRect.maxX + 2, y: 0, width: rightArrowRect.minX - 2 - leftArrowRect.maxX - 2, height: bounds.height)
        } else {
            leftArrowRect = .null
            rightArrowRect = .null
            viewport = CGRect(x: 0, y: 0, width: max(0, limit), height: bounds.height)
        }
        // The first sub-tab starts on the card's left edge, as the main strip's first tab does on its card.
        let pad: CGFloat = leftArrowRect.isNull ? 0 : 2
        var laid: [CGRect] = []
        var x = viewport.minX + pad
        for w in widths {
            laid.append(CGRect(x: x, y: 3, width: w, height: bounds.height - 4))
            x += w + 2
        }
        maxScrollX = max(0, x - 2 + pad - viewport.maxX)
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

    /// The active sub-tab's outline, as the main tab strip draws its active tab: rounded on top, its sides running down
    /// to the strip's bottom line and curving out onto it, so it opens onto the file below. `r` is cut to the viewport.
    /// On the card's left edge (`flush`), its left side is the card's own: square at the top, running straight down,
    /// and not stroked (the card's outline is there), as the main strip's first tab does.
    private func dockPath(_ r: CGRect, closed: Bool = false) -> NSBezierPath {
        let flush = isFlush(r)
        let left = flush && closed ? 0 : r.minX.rounded() + 0.5, right = r.maxX.rounded() - 0.5
        let line = bounds.height - 0.5, top = r.minY.rounded() + 0.5, radius: CGFloat = 6, f = Self.flare
        let p = NSBezierPath()
        func quad(to end: NSPoint, via c: NSPoint) {
            let start = p.currentPoint
            p.curve(to: end, controlPoint1: NSPoint(x: start.x + (c.x - start.x) * 2 / 3, y: start.y + (c.y - start.y) * 2 / 3),
                    controlPoint2: NSPoint(x: end.x + (c.x - end.x) * 2 / 3, y: end.y + (c.y - end.y) * 2 / 3))
        }
        if flush && !closed {
            p.move(to: NSPoint(x: 0, y: top))
        } else if flush {
            p.move(to: NSPoint(x: left, y: bounds.height))
            p.line(to: NSPoint(x: left, y: top))
        } else {
            p.move(to: NSPoint(x: left - f, y: line))
            quad(to: NSPoint(x: left, y: line - f), via: NSPoint(x: left, y: line))
            p.line(to: NSPoint(x: left, y: top + radius))
            quad(to: NSPoint(x: left + radius, y: top), via: NSPoint(x: left, y: top))
        }
        p.line(to: NSPoint(x: right - radius, y: top))
        quad(to: NSPoint(x: right, y: top + radius), via: NSPoint(x: right, y: top))
        p.line(to: NSPoint(x: right, y: line - f))
        quad(to: NSPoint(x: right + f, y: line), via: NSPoint(x: right, y: line))
        if closed {
            p.line(to: NSPoint(x: right + f, y: bounds.height))
            p.line(to: NSPoint(x: flush ? left : left - f, y: bounds.height))
            p.close()
        }
        p.lineWidth = 1
        return p
    }
    private static let flare: CGFloat = 4

    /// A hovered sub-tab: rounded on top only (square on top at the left too, when `squareTopLeft`).
    private static func pill(_ r: CGRect, squareTopLeft: Bool) -> NSBezierPath {
        let p = NSBezierPath(), radius: CGFloat = 5
        p.move(to: NSPoint(x: r.minX, y: r.maxY))
        if squareTopLeft {
            p.line(to: NSPoint(x: r.minX, y: r.minY))
        } else {
            p.line(to: NSPoint(x: r.minX, y: r.minY + radius))
            p.appendArc(from: NSPoint(x: r.minX, y: r.minY), to: NSPoint(x: r.minX + radius, y: r.minY), radius: radius)
        }
        p.appendArc(from: NSPoint(x: r.maxX, y: r.minY), to: NSPoint(x: r.maxX, y: r.minY + radius), radius: radius)
        p.line(to: NSPoint(x: r.maxX, y: r.maxY))
        p.close()
        return p
    }

    /// The sub-tab is on the card's left edge (the first, not scrolled, no ‹ arrow).
    private func isFlush(_ r: CGRect) -> Bool { r.minX < 0.5 }

    override func draw(_ dirtyRect: NSRect) {
        // On the card's own background (see `Cards`). A line along the bottom, which the active file's sub-tab opens
        // onto, as the main tab strip's active tab opens onto its card.
        let th = Config.shared.theme
        layoutRects()
        guard let tab else { return }
        let docked: CGRect? = {
            guard rects.indices.contains(tab.activeEditorIndex), !(dragging && pressed == tab.activeEditorIndex) else { return nil }
            let r = rects[tab.activeEditorIndex], x0 = max(r.minX, viewport.minX), x1 = min(r.maxX, viewport.maxX)
            return x1 - x0 > 12 ? CGRect(x: x0, y: r.minY, width: x1 - x0, height: r.height) : nil
        }()
        th.border.setFill()
        // Wall to wall, but where the active sub-tab opens onto it.
        let gap = docked.map { (isFlush($0) ? 0 : $0.minX.rounded() + 0.5 - Self.flare, $0.maxX.rounded() - 0.5 + Self.flare) }
            ?? (bounds.width, bounds.width)
        for (x0, x1) in [(0, min(bounds.width, gap.0)), (max(0, gap.1), bounds.width)] where x1 > x0 {
            NSRect(x: x0, y: bounds.height - 1, width: x1 - x0, height: 1).fill()
        }
        if let d = docked {
            if let fill = EditorAreaView.fill(in: self) {
                fill.setFill()
                dockPath(d, closed: true).fill()
            }
            th.border.setStroke()
            dockPath(d).stroke()
        }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: viewport).addClip()
        // In a layer of their own, so the edges can fade the sub-tabs out (the bar behind them is see-through).
        let cg = NSGraphicsContext.current?.cgContext
        cg?.beginTransparencyLayer(auxiliaryInfo: nil)
        for (i, ed) in tab.editors.enumerated() where rects[i].maxX > viewport.minX && rects[i].minX < viewport.maxX {
            let r = rects[i]
            let active = i == tab.activeEditorIndex
            if (active && docked == nil) || (hover == i && !active) {
                // Standing on the line: square at the bottom, and at the top left too on the card's edge.
                (active ? th.surface : th.surface.withAlphaComponent(0.5)).setFill()
                Self.pill(r, squareTopLeft: isFlush(r)).fill()
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
            NSBezierPath(roundedRect: terminalRect, xRadius: 5, yRadius: 5).fill()
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
                NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).fill()
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
            tab.windowController?.editorDragOver(tab.editors[i], from: tab, at: e.locationInWindow)
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
