import AppKit

/// A divider that can be dragged: a sidebar's edge, the band between the columns, the band between a tab's files and
/// its terminal, or one between terminal panes.
struct Sash {
    /// The band, in the window's root view.
    let rect: NSRect
    /// The band runs top to bottom, so it moves left and right.
    let vertical: Bool
    /// Notes where the divider is now, and returns what moves it that far from there (in the root view's points).
    let begin: () -> (CGFloat) -> Void
    /// Once a drag is over (e.g. to remember a sidebar's width).
    var end: () -> Void = {}
}

/// Where dividers running across each other meet, as in VS Code: a column's files-over-terminal band ending at the band
/// between the columns or a sidebar's edge, or one pane split ending at another. The pointer there is the four-way move
/// cursor, and a drag moves all of them at once, in both directions.
struct SashJunction {
    var rect: NSRect
    var sashes: [Sash]

    /// How far past the bands' edges the meeting point reaches.
    static let slop: CGFloat = 2

    static func find(_ sashes: [Sash]) -> [SashJunction] {
        var out: [SashJunction] = []
        for v in sashes where v.vertical {
            for h in sashes where !h.vertical {
                let reach = v.rect.insetBy(dx: -slop, dy: -slop).intersection(h.rect.insetBy(dx: -slop, dy: -slop))
                guard !reach.isNull, reach.width > 0, reach.height > 0 else { continue }
                // The square where they cross: the upright band's width by the level one's height.
                let r = NSRect(x: v.rect.minX, y: h.rect.minY, width: v.rect.width, height: h.rect.height).insetBy(dx: -slop, dy: -slop)
                // Dividers meeting at the same spot (a band ending at the columns' divider from each side) move together.
                if let i = out.firstIndex(where: { $0.rect.intersects(r) }) {
                    out[i].rect = out[i].rect.union(r)
                    out[i].sashes += [v, h]
                } else {
                    out.append(SashJunction(rect: r, sashes: [v, h]))
                }
            }
        }
        return out
    }

    /// The four-way arrows macOS uses for moving, or a drawn one like it.
    static let cursor: NSCursor = {
        let path = "/System/Library/Frameworks/ApplicationServices.framework/Versions/A/Frameworks/HIServices.framework/Versions/A/Resources/cursors/move/cursor.pdf"
        if let image = NSImage(contentsOfFile: path), image.size.width > 0 {
            return NSCursor(image: image, hotSpot: NSPoint(x: image.size.width / 2, y: image.size.height / 2))
        }
        let image = NSImage(size: NSSize(width: 22, height: 22), flipped: false) { r in
            let c = NSPoint(x: r.midX, y: r.midY)
            let arrows = NSBezierPath()
            for k in 0..<4 {
                let a = CGFloat(k) * .pi / 2
                func pt(_ along: CGFloat, _ across: CGFloat) -> NSPoint {
                    NSPoint(x: c.x + along * cos(a) - across * sin(a), y: c.y + along * sin(a) + across * cos(a))
                }
                arrows.move(to: pt(9, 0)); arrows.line(to: pt(5, 4)); arrows.line(to: pt(5, 1.2)); arrows.line(to: pt(0, 1.2))
                arrows.line(to: pt(0, -1.2)); arrows.line(to: pt(5, -1.2)); arrows.line(to: pt(5, -4)); arrows.close()
            }
            NSColor.white.setStroke()
            arrows.lineWidth = 2
            arrows.stroke()
            NSColor.black.setFill()
            arrows.fill()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 11, y: 11))
    }()
}

extension WindowRootView {
    /// Every divider showing that can be dragged now.
    func sashes() -> [Sash] {
        var out: [Sash] = []
        if !sidebarHandle.isHidden {
            out.append(Sash(rect: sidebarHandle.frame, vertical: true, begin: { [unowned self] in
                let w = sidebarWidth
                return { [unowned self] d in sidebarWidth = w + d }
            }, end: { [unowned self] in UserDefaults.standard.set(Double(sidebarWidth), forKey: "solanum.sidebar.width") }))
        }
        if !rightSidebarHandle.isHidden {
            out.append(Sash(rect: rightSidebarHandle.frame, vertical: true, begin: { [unowned self] in
                let w = rightSidebarWidth
                return { [unowned self] d in rightSidebarWidth = w - d }
            }, end: { [unowned self] in UserDefaults.standard.set(Double(rightSidebarWidth), forKey: "solanum.sidebar.right.width") }))
        }
        if !divider.isHidden {
            out.append(Sash(rect: divider.frame, vertical: true, begin: { [unowned self] in
                let f = splitFraction, span = max(1, columnArea.width - DividerBand.thickness)
                return { [unowned self] d in splitFraction = f + d / span }
            }))
        }
        func walk(_ v: NSView) {
            guard !v.isHidden, v.frame.width > 0, v.frame.height > 0 else { return }
            guard let s = v as? NSSplitView else { v.subviews.forEach(walk); return }
            let subs = s.arrangedSubviews
            if subs.count > 1, !subs.contains(where: \.isHidden) {
                for i in 0..<(subs.count - 1) { out.append(sash(s, i)) }
            }
            subs.forEach(walk)
        }
        for c in columns { c.content.subviews.forEach(walk) }
        return out
    }

    /// The divider after `split`'s `i`th view. A drag keeps the views on either side of it at least a little tall or
    /// wide (as tall as dragging the files' divider itself allows: see `TabContentView`).
    private func sash(_ split: NSSplitView, _ i: Int) -> Sash {
        let a = split.arrangedSubviews[i], vertical = split.isVertical, t = split.dividerThickness
        let band = vertical ? NSRect(x: a.frame.maxX, y: 0, width: t, height: split.bounds.height)
                            : NSRect(x: 0, y: a.frame.maxY, width: split.bounds.width, height: t)
        // A level divider's y grows the other way in a view that isn't flipped as this one is.
        let sign: CGFloat = vertical || split.isFlipped == isFlipped ? 1 : -1
        return Sash(rect: convert(band, from: split), vertical: vertical, begin: { [weak split] in
            guard let split, split.arrangedSubviews.count > i + 1 else { return { _ in } }
            let a = split.arrangedSubviews[i], b = split.arrangedSubviews[i + 1]
            let start = vertical ? a.frame.maxX : a.frame.maxY
            var lo = (vertical ? a.frame.minX : a.frame.minY) + 40
            var hi = (vertical ? b.frame.maxX : b.frame.maxY) - t - 40
            if split is TabContentView { lo = 90; hi = split.bounds.height - 80 }
            return { d in split.setPosition(min(max(start + sign * d, lo), max(lo, hi)), ofDividerAt: i) }
        })
    }

    /// The meeting point of dividers under `p` (in this view), if there is one.
    func junction(at p: NSPoint) -> SashJunction? {
        guard !columns.isEmpty else { return nil }
        return SashJunction.find(sashes()).first { $0.rect.contains(p) }
    }

    /// The move cursor over a meeting point. Leaving it for one of the dividers there, that divider's own cursor (its
    /// cursor rect, which the pointer never left, won't set it again).
    func junctionHover(_ p: NSPoint) {
        if junction(at: p) != nil {
            overJunction = true
            SashJunction.cursor.set()
        } else if overJunction {
            overJunction = false
            if let s = sashes().first(where: { $0.rect.contains(p) }) {
                (s.vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set()
            } else {
                window?.invalidateCursorRects(for: self)
            }
        }
    }

    /// Follows a press on a meeting point to its release, moving each of its dividers with the pointer.
    func dragJunction(_ j: SashJunction, from e: NSEvent) {
        guard let window else { return }
        let start = convert(e.locationInWindow, from: nil)
        let moves = j.sashes.map { ($0.vertical, $0.begin()) }
        SashJunction.cursor.push()
        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: NSEvent.foreverDuration, mode: .eventTracking) { ev, stop in
            guard let ev else { return }
            if ev.type == .leftMouseUp {
                stop.pointee = true
                return
            }
            self.moveJunction(moves, by: self.convert(ev.locationInWindow, from: nil), from: start)
        }
        NSCursor.pop()
        j.sashes.forEach { $0.end() }
        window.invalidateCursorRects(for: self)
        junctionHover(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    private func moveJunction(_ moves: [(Bool, (CGFloat) -> Void)], by p: NSPoint, from start: NSPoint) {
        for (vertical, move) in moves { move(vertical ? p.x - start.x : p.y - start.y) }
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    /// Dev aid (DevTools junction-drag): the meeting point nearest (x, y) dragged by (dx, dy), and what moved printed.
    func devDragJunction(at p: NSPoint, by d: NSSize) {
        let all = SashJunction.find(sashes())
        let describe = { (j: SashJunction) in "junction \(j.rect.integral) of \(j.sashes.map { ($0.vertical ? "|" : "-") + "\($0.rect.integral)" })" }
        FileHandle.standardError.write("junctions: \(all.map(describe))\n".data(using: .utf8)!)
        guard let j = all.min(by: { hypot($0.rect.midX - p.x, $0.rect.midY - p.y) < hypot($1.rect.midX - p.x, $1.rect.midY - p.y) }) else { return }
        FileHandle.standardError.write("hit at center: \(junction(at: NSPoint(x: j.rect.midX, y: j.rect.midY)) != nil), hitTest root: \(hitTest(convert(NSPoint(x: j.rect.midX, y: j.rect.midY), to: superview)) === self)\n".data(using: .utf8)!)
        let start = NSPoint(x: j.rect.midX, y: j.rect.midY)
        let moves = j.sashes.map { ($0.vertical, $0.begin()) }
        for k in 1...4 {
            let f = CGFloat(k) / 4
            moveJunction(moves, by: NSPoint(x: start.x + d.width * f, y: start.y + d.height * f), from: start)
        }
        // Not `end`: a test run mustn't remember a sidebar width in the real defaults.
        FileHandle.standardError.write("after: \(SashJunction.find(sashes()).map(describe))\n".data(using: .utf8)!)
    }
}
