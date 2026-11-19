import Foundation

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
    /// A running agent can park the cursor mid-screen (on the focused option of a question), so its range runs to the bottom.
    private func scanRange(_ b: Block) -> ClosedRange<Int>? {
        let lo = max(b.outputLine ?? b.promptLine, firstAbs)
        let hi = b.state == .running ? lastAbs : min(b.lastLine(cursorAbs: cursorAbs), lastAbs)
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

// MARK: - Edit diffs

extension Terminal {
    /// The diff Claude Code prints under each finished edit in an agent session's block: after "⏺ Update(a.swift)" and
    /// "  ⎿  Added 2 lines", the file's changed lines, numbered. Hidden when Settings says so (the pill's panel, "Files
    /// changed this prompt", shows them instead); the edit's own two lines stay. An edit waiting for your approval has no
    /// "⎿" line yet, so its diff stays, and nothing in the live input box at the bottom is touched.
    func agentEditDiffRanges(in b: Block) -> [ClosedRange<Int>] {
        guard b.state != .prompt, let range = scanRange(b) else { return [] }
        var limit = range.upperBound
        if let top = agentInputBoxTop(b) { limit = min(limit, top - 1) }
        var out: [ClosedRange<Int>] = []
        var a = range.lowerBound
        while a + 1 < limit {
            guard isAgentEditHeader(a), isAgentEditSummary(a + 1) else { a += 1; continue }
            var e = a + 1
            while e + 1 <= limit, isAgentEditBody(e + 1) { e += 1 }
            if e > a + 1 { out.append((a + 2)...e) }
            a = e + 1
        }
        return out
    }

    /// "⏺ Update(path)", "⏺ Write(path)" and the like (⏺ or ●, as fonts differ).
    private func isAgentEditHeader(_ a: Int) -> Bool {
        guard let l = line(abs: a), let c = l.cells.first?.ch, c == 0x23FA || c == 0x25CF else { return false }
        let t = l.text(from: 2)
        return ["Update(", "Write(", "Edit(", "MultiEdit(", "Create(", "NotebookEdit("].contains { t.hasPrefix($0) }
    }

    /// "  ⎿  Added 2 lines", "  ⎿  Wrote 7 lines to …": the edit went through.
    private func isAgentEditSummary(_ a: Int) -> Bool {
        guard let l = line(abs: a) else { return false }
        let t = l.text().trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("⎿") else { return false }
        let rest = t.dropFirst().trimmingCharacters(in: .whitespaces)
        return ["Added", "Removed", "Wrote", "Updated", "Created"].contains { rest.hasPrefix($0) }
    }

    /// A line of the diff: indented past the "⎿" (numbered lines, their wrapped rest, "… +12 lines"), not blank.
    private func isAgentEditBody(_ a: Int) -> Bool {
        guard let l = line(abs: a), !l.isBlank, l.cells.count > 3 else { return false }
        return l.cells[0..<3].allSatisfy { $0.ch == 0x20 || $0.ch == 0 }
    }
}
