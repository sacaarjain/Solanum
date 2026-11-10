import AppKit

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
        // Inside the outline drawn by drawTurnChrome, not past it.
        ctx.setFillColor(palette.theme.accent.withAlphaComponent(0.09).cgColor)
        ctx.addPath(selectionOutline(top: rowY(first) - 2, height: CGFloat(last - first + 1) * fonts.cellH + 4))
        ctx.fillPath()
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
            ctx.addPath(selectionOutline(top: top, height: height))
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
