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
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

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

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    private static let font = NSFont.systemFont(ofSize: 11.5, weight: .medium)

    private func layoutRects() {
        rects = []
        closeRects = []
        guard let tab else { return }
        terminalRect = CGRect(x: bounds.width - 30, y: (bounds.height - 22) / 2, width: 22, height: 22)
        var x: CGFloat = 6
        for ed in tab.editors {
            let name = ed.displayName as NSString
            let w = min(260, max(90, name.size(withAttributes: [.font: Self.font]).width + 56))
            let r = CGRect(x: x, y: 3, width: w, height: bounds.height - 4)
            rects.append(r)
            closeRects.append(CGRect(x: r.maxX - 20, y: r.midY - 8, width: 16, height: 16))
            x += w + 2
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let th = Config.shared.theme
        layoutRects()
        th.tabBarTint.setFill()
        bounds.fill()
        th.border.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        guard let tab else { return }
        for (i, ed) in tab.editors.enumerated() where rects[i].minX < terminalRect.minX - 4 {
            let r = rects[i]
            let active = i == tab.activeEditorIndex
            if active || hover == i {
                (active ? th.surface : th.surface.withAlphaComponent(0.5)).setFill()
                NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).fill()
            }
            if active {
                th.accent.setFill()
                NSBezierPath(roundedRect: NSRect(x: r.minX + 8, y: r.maxY - 2, width: r.width - 16, height: 2), xRadius: 1, yRadius: 1).fill()
            }
            let name = ed.displayName
            if ed.mode == .file, let img = IconPacks.current?.icon(forName: name, directory: false, light: !th.isDark) {
                img.draw(in: NSRect(x: r.minX + 9, y: r.midY - 7, width: 14, height: 14))
            } else {
                drawSymbol(ed.mode, name, r, th)
            }
            let para = NSMutableParagraphStyle()
            para.lineBreakMode = .byTruncatingMiddle
            (name as NSString).draw(in: NSRect(x: r.minX + 30, y: r.midY - 7, width: r.width - 54, height: 16),
                                    withAttributes: [.font: Self.font, .paragraphStyle: para,
                                                     .foregroundColor: active ? th.foreground : th.foreground.withAlphaComponent(0.6)])
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

    /// Solanum's own tab icon: what the tab shows, or the kind of file.
    private func drawSymbol(_ mode: EditorMode, _ name: String, _ r: NSRect, _ th: Theme) {
        let symbol: String
        switch mode {
        case .diff: symbol = "plusminus"
        case .graph: symbol = "arrow.triangle.branch"
        case .preview: symbol = "eye"
        case .file: symbol = FileSidebarView.symbol(for: name)
        }
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular).applying(.init(paletteColors: [th.dimText]))
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
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
        let h = rects.firstIndex { $0.contains(p) }
        let hc = h.map { closeRects[$0].contains(p) } ?? false
        let ht = terminalRect.contains(p)
        if h != hover || hc != hoverClose || ht != hoverTerminal {
            hover = h
            hoverClose = hc
            hoverTerminal = ht
            toolTip = ht ? (tab?.showsTerminal == true ? "Hide Terminal" : "Show Terminal")
                : h.flatMap { i in tab.map { $0.editors[i].path } }
            needsDisplay = true
        }
    }

    override func mouseExited(with e: NSEvent) {
        hover = nil
        hoverClose = false
        hoverTerminal = false
        needsDisplay = true
    }

    override func mouseDown(with e: NSEvent) {
        guard let tab else { return }
        let p = convert(e.locationInWindow, from: nil)
        if terminalRect.contains(p) { return tab.toggleTerminal() }
        guard let i = rects.firstIndex(where: { $0.contains(p) }) else { return }
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
        if let i = rects.firstIndex(where: { $0.contains(p) }) { tab?.editors[i].requestClose() }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let tab else { return nil }
        let p = convert(event.locationInWindow, from: nil)
        guard let i = rects.firstIndex(where: { $0.contains(p) }) else { return nil }
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
        return m
    }
}
