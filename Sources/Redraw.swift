import AppKit

// Output repaints only the rows it changed. Text is laid out and drawn on the CPU, and a whole window of it takes
// several milliseconds, while most updates (Claude Code's spinner, a progress bar, an echoed key) touch a row or
// two. Each row remembers what it showed when it was last drawn: its line's cells (shared with the terminal until
// it writes to them, so an untouched row compares in one pointer check) and the little that's drawn over it.
// Everything else on screen (blocks and their chrome, code boxes, thumbnails, the selection, the scrollbar…) goes
// into one key, and when that changes, as whenever anything else sets `needsDisplay`, the whole view is redrawn.

/// What a row showed when it was last drawn in full.
struct DrawnRow: Equatable {
    var line = -1
    var cells: [Cell] = []
    var extras: [Int: String]?
    /// A Claude Code prompt line, whose separator is drawn across the row above.
    var prompt = false
    /// A block's status badge, which can change by itself (a running command's time).
    var badge: String?
}

/// The cursor as last drawn.
struct DrawnCursor: Equatable {
    var row = -1
    var col = 0
    var active = false
    var shown = false
    var shape = TerminalView.CursorShape.block
}

extension TerminalView {
    /// Where row `r` is drawn.
    func rowBand(_ r: Int) -> CGRect {
        CGRect(x: 0, y: rowY(r), width: bounds.width, height: fonts.cellH)
    }

    /// After output, a blink or a key: repaints the rows that look different now, or everything when something
    /// besides the rows' own text has changed.
    func redrawChanges() {
        guard !fullRedrawPending else { return }
        guard window != nil, !isHiddenOrHasHiddenAncestor, let rows = changedRows() else {
            needsDisplay = true
            return
        }
        for r in rows { setNeedsDisplay(rowBand(r)) }
    }

    /// The rows that look different from when they were last drawn; nil when more than rows has changed.
    func changedRows() -> IndexSet? {
        computeRowMap()
        guard drawnRows.count == rowMap.count, scrollPixelShift == 0, selectedTurnLine == nil, imageChipState.popup == nil,
              frameKey(layoutChips: true) == drawnFrame else { return nil }
        let rows = currentRows()
        var dirty = IndexSet()
        for r in rows.indices where rows[r] != drawnRows[r] {
            dirty.insert(r)
            if r > 0 && (rows[r].prompt || drawnRows[r].prompt) { dirty.insert(r - 1) }
        }
        let cursor = currentCursor()
        if cursor != drawnCursor {
            if drawnCursor.row >= 0 { dirty.insert(drawnCursor.row) }
            if cursor.row >= 0 { dirty.insert(cursor.row) }
        }
        // Code boxes (with a Copy button in the row above), thumbnails and a link's card are drawn across several rows.
        for r in dirty {
            let near = rowMap[max(0, r - 1)...min(rowMap.count - 1, r + 1)]
            if codeBoxes.contains(where: { b in near.contains { $0 >= b.first - 1 && $0 <= b.last } })
                || imageChipState.strips.contains(where: { $0.area.insetBy(dx: 0, dy: -4).intersects(rowBand(r)) })
                || linkCardRect.insetBy(dx: 0, dy: -8).intersects(rowBand(r)) {
                return nil
            }
        }
        return dirty
    }

    /// What `draw` just painted: every row and the cursor after a full redraw, else the rows it covered.
    func recordDrawn(_ rects: [CGRect], full: Bool) {
        let rows = currentRows()
        let cursor = currentCursor()
        let key = frameKey(layoutChips: false)
        if full {
            drawnRows = rows
            drawnCursor = cursor
            drawnFrame = key
            return
        }
        // Something besides the rows changed without asking for a redraw: catch up on the next frame.
        guard drawnRows.count == rows.count, key == drawnFrame else { needsDisplay = true; return }
        func covered(_ r: Int) -> Bool {
            let band = rowBand(r)
            return rects.contains { $0.contains(band) }
        }
        for r in rows.indices where covered(r) { drawnRows[r] = rows[r] }
        if cursor != drawnCursor {
            if (drawnCursor.row < 0 || covered(drawnCursor.row)) && (cursor.row < 0 || covered(cursor.row)) {
                drawnCursor = cursor
            } else {
                needsDisplay = true
            }
        }
    }

    private func currentRows() -> [DrawnRow] {
        var badges: [Int: String] = [:]
        for s in visibleBlockSpans() where spanStartsHere(s) {
            if let b = blockBadge(s.block) { badges[s.first] = b.text }
        }
        return rowMap.indices.map { r in
            let a = rowMap[r]
            guard a >= 0, let l = terminal.line(abs: a) else { return DrawnRow() }
            return DrawnRow(line: a, cells: l.cells, extras: l.extras, prompt: terminal.isAgentPromptLine(a), badge: badges[r])
        }
    }

    private func currentCursor() -> DrawnCursor {
        guard terminal.cursorVisible, !exited, let r = rowMap.firstIndex(of: terminal.cursorAbs) else { return DrawnCursor() }
        let active = isActiveForInput
        return DrawnCursor(row: r, col: terminal.cursorX, active: active, shown: !active || !cursorBlinks || blinkOn,
                           shape: cursorShapeValue)
    }

    /// Everything drawn besides the rows' own text and badges, and the cursor. `layoutChips` lays out the image
    /// thumbnails first (`draw` already has).
    private func frameKey(layoutChips: Bool) -> Int {
        var h = Hasher()
        h.combine(bounds.width); h.combine(bounds.height)
        h.combine(ObjectIdentifier(palette)); h.combine(ObjectIdentifier(fonts))
        h.combine(terminal.usingAlt); h.combine(terminal.reverseVideo)
        h.combine(scrollOffset); h.combine(totalDisplayLines)
        for r in hiddenRanges { h.combine(r.lowerBound); h.combine(r.upperBound) }
        h.combine(dimmed); h.combine(bellFlash)
        h.combine(selection?.start); h.combine(selection?.end); h.combine(selection?.rect)
        h.combine(markedText); h.combine(markedSelection.location); h.combine(markedSelection.length)
        h.combine(searchMatches.count); h.combine(currentMatch)
        h.combine(hoverURL?.line); h.combine(hoverURL?.start); h.combine(hoverURL?.end); h.combine(hoverLinkCard)
        for b in selectedBlocks { h.combine(b.id) }
        for b in [hoverBlock, copiedBlock] { h.combine(b?.id) }
        h.combine(hoverBlockCopy); h.combine(hoverBlockSend)
        h.combine(agent != nil)
        for s in visibleBlockSpans() {
            let b = s.block
            h.combine(b.id); h.combine(b.state); h.combine(b.failed); h.combine(b.collapsed)
            h.combine(s.first); h.combine(spanStartsHere(s))
            // How far down it goes only shows when something is drawn down its side.
            if isSelected(b) || b.failed || showsRunningBar(b) { h.combine(s.last) }
        }
        for b in codeBoxes { h.combine(b.first); h.combine(b.last); h.combine(b.indent); h.combine(b.kind == .table) }
        h.combine(copiedBox); h.combine(hoverCopyButton)
        if layoutChips { layoutImageChips() }
        let st = imageChipState
        for s in st.strips {
            h.combine(s.area.minX); h.combine(s.area.minY); h.combine(s.area.width); h.combine(s.area.height)
            h.combine(s.bottom)
            for i in s.images { h.combine(i.n) }
        }
        for k in st.hidden.keys.sorted() {
            h.combine(k)
            for r in st.hidden[k] ?? [] { h.combine(r.lowerBound); h.combine(r.upperBound) }
        }
        h.combine(st.hover); h.combine(st.popup)
        for p in collapsedTurns.sorted() { h.combine(p) }
        h.combine(scrollbarShown); h.combine(scrollbarHover); h.combine(scrollbarGrab); h.combine(hoverJumpPill)
        return h.finalize()
    }
}
