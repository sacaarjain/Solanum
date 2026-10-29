import AppKit

/// One prompt → response exchange inside an AI agent session (Claude Code) running in a block.
///
/// Agents don't emit shell-integration marks per turn, so turns are read from the transcript itself:
/// Claude Code echoes each submitted prompt as a line starting with "❯" on a shaded background,
/// while its live input box uses an unshaded "❯" between two "───" rules.
struct AgentTurn {
    /// Absolute line of the "❯" prompt line; identifies the turn.
    let promptLine: Int
    /// Last line of a multi-line prompt.
    let promptEnd: Int
    /// Last line of the response (trailing blank lines trimmed).
    let end: Int
    /// 1-based position within its session.
    let index: Int

    var hasResponse: Bool { end > promptEnd }
    var responseLineCount: Int { max(0, end - promptEnd) }
}

extension Terminal {
    private static let promptGlyphs: Set<UInt32> = [0x276F, 0x21]  // ❯, ! (bash mode)

    /// True for a submitted-prompt line: prompt glyph in column 0 on a non-default background.
    func isAgentPromptLine(_ a: Int) -> Bool {
        guard !usingAlt, let l = line(abs: a), l.cells.count > 1 else { return false }
        let c = l.cells[0], next = l.cells[1].ch
        return c.bg != 0 && Terminal.promptGlyphs.contains(c.ch) && (next == 0 || next == 0x20 || next == 0xA0)
    }

    /// Continuation line of a shaded prompt (the shading starts in column 0).
    private func isPromptContinuation(_ a: Int, bg: UInt32) -> Bool {
        guard let l = line(abs: a), let c = l.cells.first else { return false }
        return c.bg == bg && !Terminal.promptGlyphs.contains(c.ch)
    }

    /// The live input box's top rule: a long run of "─" from column 0, followed by an unshaded "❯" line.
    private func isInputBoxTop(_ a: Int) -> Bool {
        guard let l = line(abs: a), l.cells.first?.ch == 0x2500,
              let below = line(abs: a + 1), below.cells.first?.ch == 0x276F, below.cells[0].bg == 0 else { return false }
        let n = l.trimmedLength
        guard n >= min(20, cols / 2) else { return false }
        for x in 0..<n where l.cells[x].ch != 0x2500 { return false }
        return true
    }

    /// Line range a block occupies that is still in the buffer.
    private func scanRange(_ b: Block) -> ClosedRange<Int>? {
        let lo = max(b.outputLine ?? b.promptLine, firstAbs)
        let hi = min(b.lastLine(cursorAbs: cursorAbs), lastAbs)
        return lo <= hi ? lo...hi : nil
    }

    /// All agent turns inside a block, oldest first. Empty for ordinary commands.
    func agentTurns(in b: Block) -> [AgentTurn] {
        guard b.state != .prompt, let range = scanRange(b) else { return [] }
        let starts = range.filter { isAgentPromptLine($0) }
        guard !starts.isEmpty else { return [] }
        // The response to the last prompt stops at the input box (still on screen, or left behind on exit).
        var limit = range.upperBound
        if let last = starts.last, last < limit {
            for a in stride(from: limit - 1, to: last, by: -1) where isInputBoxTop(a) { limit = a - 1; break }
        }
        var turns: [AgentTurn] = []
        for (i, p) in starts.enumerated() {
            let bg = line(abs: p)?.cells[0].bg ?? 0
            var pe = p
            while pe + 1 <= limit, isPromptContinuation(pe + 1, bg: bg) { pe += 1 }
            var end = i + 1 < starts.count ? starts[i + 1] - 1 : limit
            while end > pe, line(abs: end)?.isBlank ?? true { end -= 1 }
            turns.append(AgentTurn(promptLine: p, promptEnd: pe, end: max(end, pe), index: i + 1))
        }
        return turns
    }

    /// The turn whose prompt starts at the given line, if it is still a prompt line.
    func agentTurn(at promptLine: Int) -> AgentTurn? {
        guard isAgentPromptLine(promptLine), let b = blockContaining(promptLine) else { return nil }
        return agentTurns(in: b).first { $0.promptLine == promptLine }
    }

    /// The turn containing an absolute line.
    func agentTurn(containing a: Int) -> AgentTurn? {
        guard let b = blockContaining(a) else { return nil }
        return agentTurns(in: b).last { $0.promptLine <= a && a <= $0.end }
    }

    func blockContaining(_ a: Int) -> Block? {
        blocks.last { $0.promptLine <= a && a <= $0.lastLine(cursorAbs: cursorAbs) }
    }

    /// Top rule of a running agent session's live input box, if it is on screen.
    func agentInputBoxTop(_ b: Block) -> Int? {
        guard b.state == .running, !usingAlt else { return nil }
        let lo = max(b.outputLine ?? b.promptLine, screenTopAbs)
        guard lo <= lastAbs else { return nil }
        for a in stride(from: lastAbs, through: lo, by: -1) where isInputBoxTop(a) { return a }
        return nil
    }

    /// Rows of the live input box between its two rules.
    func agentInputRows(_ b: Block) -> ClosedRange<Int>? {
        guard let top = agentInputBoxTop(b), top + 1 <= lastAbs else { return nil }
        var a = top + 1
        while a + 1 <= lastAbs, line(abs: a + 1)?.cells.first?.ch != 0x2500 { a += 1 }
        return (top + 1)...a
    }

    /// Text of the prompt with the "❯ " gutter removed.
    func agentPromptText(_ t: AgentTurn) -> String {
        (t.promptLine...t.promptEnd).compactMap { line(abs: $0)?.text(from: 2) }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - View integration

extension TerminalView {
    /// The explicitly selected turn, refreshed against the current buffer.
    var selectedTurn: AgentTurn? {
        guard let p = selectedTurnLine else { return nil }
        return terminal.agentTurn(at: p)
    }

    /// The running agent session's latest turn (what ⌘⌥C etc. act on when nothing is selected).
    var liveTurn: AgentTurn? {
        guard selectedBlock == nil, let b = terminal.currentBlock, b.state == .running else { return nil }
        return terminal.agentTurns(in: b).last
    }

    /// The turn that turn-aware block actions apply to.
    var targetTurn: AgentTurn? { selectedTurnLine != nil ? selectedTurn : liveTurn }

    func selectTurn(_ t: AgentTurn?) {
        selectedTurnLine = t?.promptLine
        if t != nil { selectedBlock = nil }
        needsDisplay = true
    }

    /// Response text with Claude's two-column gutter ("⏺ " / indentation) removed.
    func agentResponseText(_ t: AgentTurn) -> String {
        guard t.hasResponse else { return "" }
        let raw = textForRange(from: GridPos(line: t.promptEnd + 1, col: 0), to: GridPos(line: t.end, col: terminal.cols - 1))
        let lines = raw.components(separatedBy: "\n").map { l -> String in
            if l.hasPrefix("⏺ ") || l.hasPrefix("● ") || l.hasPrefix("  ") { return String(l.dropFirst(2)) }
            return l == "⏺" || l == "●" ? "" : l
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Hidden line ranges for collapsed turns (response lines only; the prompt stays visible).
    func collapsedTurnRanges() -> [ClosedRange<Int>] {
        var out: [ClosedRange<Int>] = []
        for p in collapsedTurns.sorted() {
            guard let t = terminal.agentTurn(at: p) else { collapsedTurns.remove(p); continue }
            if t.hasResponse { out.append((t.promptEnd + 1)...t.end) }
        }
        return out
    }

    func toggleTurnCollapse(_ t: AgentTurn) {
        guard t.hasResponse else { return }
        if collapsedTurns.contains(t.promptLine) { collapsedTurns.remove(t.promptLine) } else { collapsedTurns.insert(t.promptLine) }
        selectTurn(t)
        scrollToAbs(t.promptLine)
    }

    /// Lists every prompt in this pane in the command palette; picking one scrolls to and selects it.
    @objc func jumpToPrompt(_ sender: Any?) {
        guard let w = window else { return }
        var items: [CommandPalette.Item] = []
        for b in terminal.blocks {
            for t in terminal.agentTurns(in: b) {
                let text = terminal.agentPromptText(t)
                let first = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? text
                let more = t.hasResponse ? "\(t.responseLineCount) lines" : "no response yet"
                items.append(CommandPalette.Item(title: first, path: "Prompt \(t.index) · \(more)", shortcut: "") { [weak self] in
                    guard let self else { return }
                    self.collapsedTurns.remove(t.promptLine)
                    self.selectTurn(t)
                    self.scrollToAbs(t.promptLine)
                    self.window?.makeFirstResponder(self)
                })
            }
        }
        guard !items.isEmpty else { NSSound.beep(); return }
        CommandPalette.show(in: w, items: items.reversed(), placeholder: "Jump to prompt…")
    }

    // MARK: Drawing

    func drawTurnBackground(_ ctx: CGContext) {
        guard let t = selectedTurn, let (first, last) = visibleRows(t) else { return }
        let rect = CGRect(x: 0, y: rowY(first) - 2, width: bounds.width, height: CGFloat(last - first + 1) * fonts.cellH + 4)
        ctx.setFillColor(palette.theme.accent.withAlphaComponent(0.09).cgColor)
        ctx.fill(rect)
    }

    /// Separators above each prompt, the selection outline, and "lines hidden" chips.
    func drawTurnChrome(_ ctx: CGContext) {
        guard !terminal.usingAlt else { return }
        let th = palette.theme
        for r in 0..<rowMap.count where r > 0 {
            let a = rowMap[r]
            guard a >= 0, terminal.isAgentPromptLine(a) else { continue }
            let y = rowY(r) - fonts.cellH * 0.5
            ctx.setFillColor(th.border.cgColor)
            ctx.fill(CGRect(x: padX, y: y - 0.5, width: bounds.width - padX * 2, height: 1))
        }
        if let t = selectedTurn, let (first, last) = visibleRows(t) {
            let top = rowY(first) - 2
            let height = CGFloat(last - first + 1) * fonts.cellH + 4
            ctx.setStrokeColor(th.accent.withAlphaComponent(0.85).cgColor)
            ctx.setLineWidth(1.5)
            let r = CGRect(x: 3, y: top + 1, width: bounds.width - 6, height: height - 2)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 6, cornerHeight: 6, transform: nil))
            ctx.strokePath()
            if rowMap[first] == t.promptLine, let b = terminal.blockContaining(t.promptLine) {
                let total = terminal.agentTurns(in: b).count
                drawBadge("Prompt \(t.index) of \(total)", color: th.accent, rightX: bounds.width - padX,
                                centerY: rowY(first) + fonts.cellH / 2, ctx)
            }
        }
        for p in collapsedTurns {
            guard let t = terminal.agentTurn(at: p), t.hasResponse,
                  let r = rowMap.firstIndex(of: t.promptEnd), let l = terminal.line(abs: t.promptEnd) else { continue }
            let x = padX + CGFloat(min(l.trimmedLength + 2, terminal.cols - 12)) * fonts.cellW
            let rect = drawChip("⋯ \(t.responseLineCount) lines hidden", x: x, centerY: rowY(r) + fonts.cellH / 2, ctx)
            collapseChips.append((rect, { [weak self] in
                self?.collapsedTurns.remove(p)
                self?.needsDisplay = true
            }))
        }
    }

    /// First/last screen rows of a turn currently on screen.
    private func visibleRows(_ t: AgentTurn) -> (Int, Int)? {
        var first: Int?, last: Int?
        for (r, a) in rowMap.enumerated() where a >= t.promptLine && a <= t.end {
            if first == nil { first = r }
            last = r
        }
        guard let f = first, let l = last else { return nil }
        return (f, l)
    }
}
