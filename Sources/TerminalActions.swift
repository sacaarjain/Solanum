import AppKit

extension TerminalView: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)):
            return selection != nil || selectedBlock != nil
        case #selector(cut(_:)):
            return selection != nil
        case #selector(showHistory(_:)):
            return canShowHistory
        case #selector(selectPreviousBlock(_:)), #selector(selectNextBlock(_:)):
            return !terminal.usingAlt && !navStops().isEmpty
        case #selector(collapseAllBlocks(_:)), #selector(expandAllBlocks(_:)):
            return !terminal.usingAlt && terminal.blocks.contains { $0.state == .finished }
        case #selector(copyBlockCommand(_:)), #selector(copyBlockOutput(_:)), #selector(toggleBlockCollapse(_:)):
            return !terminal.usingAlt && (targetTurn != nil || targetBlock != nil)
        case #selector(sendToChat(_:)):
            return !terminal.usingAlt && selectedTurnLine == nil && targetBlock != nil
        case #selector(rerunBlockCommand(_:)), #selector(saveCommandAsSnippet(_:)):
            return !terminal.usingAlt && targetTurn == nil && targetBlock != nil
        case #selector(jumpToPrompt(_:)):
            return !terminal.usingAlt && terminal.blocks.contains { !terminal.agentTurns(in: $0).isEmpty }
        case #selector(findNext(_:)), #selector(findPrevious(_:)):
            return !searchMatches.isEmpty
        case #selector(undo(_:)):
            return canUndoInput
        case #selector(redo(_:)):
            return !redoStack.isEmpty && promptInput != nil
        default:
            return true
        }
    }

    // MARK: - Undo

    /// Full-screen programs (vim, less, …) use Ctrl-_ for other things, so only line editors get it,
    /// plus agents, whichever screen they draw on.
    var canUndoInput: Bool { !exited && (!terminal.usingAlt || agent != nil) }

    /// ⌘Z: bash/zsh's line editor and Claude Code both undo on Ctrl-_, so send that. It also brings back
    /// text removed with ⌘⌫ (sent as Ctrl-U). At a shell prompt the line is remembered first, for ⌘⇧Z.
    @objc func undo(_ sender: Any?) {
        guard canUndoInput else { return NSSound.beep() }
        let before = promptInput
        typingUndoRedo = true
        send("\u{1f}")
        typingUndoRedo = false
        if let before {
            redoStack.append(before)
            if redoStack.count > 50 { redoStack.removeFirst() }
        }
        scrollOffset = 0
    }

    /// ⌘⇧Z: the shell's line editor has no redo, so put back the line as it was before the last ⌘Z:
    /// clear it (⌃E ⌃U), type it again, and step the cursor back to where it was.
    @objc func redo(_ sender: Any?) {
        guard promptInput != nil, let state = redoStack.popLast() else { return NSSound.beep() }
        typingUndoRedo = true
        send("\u{05}\u{15}" + state.text + String(repeating: "\u{02}", count: max(0, state.text.count - state.cursor)))
        typingUndoRedo = false
        scrollOffset = 0
    }

    /// What's typed at a local shell prompt and the cursor's offset in it, read off the screen from where
    /// shell integration marked the command's start. Nil anywhere else (running programs, ssh, agents).
    var promptInput: (text: String, cursor: Int)? {
        guard !terminal.usingAlt, pty?.hasForegroundJob == false, let b = terminal.currentBlock, b.state == .prompt,
              var ln = b.commandLine else { return nil }
        var chars: [Character] = []
        var cursor: Int?
        var col = b.commandCol
        while let l = terminal.line(abs: ln) {
            let end = l.wrapped ? l.cells.count : l.trimmedLength
            for x in col..<max(col, end) {
                if ln == terminal.cursorAbs && x == terminal.cursorX { cursor = chars.count }
                let c = l.cells[x]
                if c.width == 0 { continue }
                chars.append(Character(Unicode.Scalar(c.ch == 0 ? 0x20 : c.ch) ?? " "))
            }
            // Trailing spaces before the cursor are part of the line too.
            if ln == terminal.cursorAbs, cursor == nil, terminal.cursorX >= end {
                chars += Array(repeating: " ", count: terminal.cursorX - max(col, end))
                cursor = chars.count
            }
            guard l.wrapped else { break }
            ln += 1
            col = 0
        }
        return (String(chars), cursor ?? chars.count)
    }

    // MARK: - Blocks

    var finishedBlocks: [Block] { terminal.blocks.filter { $0.state == .finished } }

    /// The selected block, or the most recent finished block.
    var targetBlock: Block? { selectedBlock ?? finishedBlocks.last }

    func blockText(_ b: Block, includeCommand: Bool) -> String {
        guard let o = b.outputLine, let e = b.endLine, e >= o else { return includeCommand ? b.command : "" }
        let out = textForRange(from: GridPos(line: o, col: 0), to: GridPos(line: e, col: terminal.cols - 1))
        let trimmed = out.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        return includeCommand ? "$ \(b.command)\n\(trimmed)" : trimmed
    }

    /// ⌘↑/⌘↓ stops: finished commands, and each prompt of an agent session in place of its whole block.
    enum NavStop {
        case block(Block)
        case turn(AgentTurn)

        var line: Int {
            switch self {
            case .block(let b): return b.promptLine
            case .turn(let t): return t.promptLine
            }
        }
    }

    func navStops() -> [NavStop] {
        var out: [NavStop] = []
        for b in terminal.blocks where b.state != .prompt {
            let turns = terminal.agentTurns(in: b)
            if !turns.isEmpty { out += turns.map { .turn($0) } } else if b.state == .finished { out.append(.block(b)) }
        }
        return out
    }

    private func currentStopIndex(_ list: [NavStop]) -> Int? {
        if let p = selectedTurnLine { return list.firstIndex { if case .turn(let t) = $0 { return t.promptLine == p }; return false } }
        if let s = selectedBlock { return list.firstIndex { if case .block(let b) = $0 { return b === s }; return false } }
        return nil
    }

    private func select(_ stop: NavStop) {
        switch stop {
        case .block(let b):
            selectedTurnLine = nil
            selectedBlock = b
        case .turn(let t):
            selectTurn(t)
        }
        scrollToAbs(stop.line)
    }

    @objc func selectPreviousBlock(_ sender: Any?) {
        let list = navStops()
        guard !list.isEmpty else { return }
        if let i = currentStopIndex(list) { select(list[max(0, i - 1)]) } else { select(list[list.count - 1]) }
        needsDisplay = true
    }

    @objc func selectNextBlock(_ sender: Any?) {
        let list = navStops()
        if let i = currentStopIndex(list), i + 1 < list.count {
            select(list[i + 1])
        } else {
            selectedBlock = nil
            selectedTurnLine = nil
            scrollOffset = 0
        }
        needsDisplay = true
    }

    @objc func copyBlockCommand(_ sender: Any?) {
        if let t = targetTurn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(terminal.agentPromptText(t), forType: .string)
            flashTurn(t)
            return
        }
        if selectedBlocks.count > 1 {
            AgentChats.putOnClipboard(chronological(selectedBlocks).map(\.command).joined(separator: "\n"))
            return
        }
        guard let b = targetBlock else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(b.command, forType: .string)
        flashBlock(b)
    }

    @objc func copyBlockOutput(_ sender: Any?) {
        if let t = targetTurn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(agentResponseText(t), forType: .string)
            flashTurn(t)
            return
        }
        if selectedBlocks.count > 1 { return copySelectedBlocks() }
        guard let b = targetBlock else { return }
        AgentChats.putOnClipboard(blockText(b, includeCommand: true))
        flashBlock(b)
    }

    @objc func rerunBlockCommand(_ sender: Any?) {
        guard let b = targetBlock, !b.command.isEmpty else { return }
        selectedBlock = nil
        send(b.command.replacingOccurrences(of: "\n", with: "\r") + "\r")
        scrollOffset = 0
        window?.makeFirstResponder(self)
    }

    @objc func toggleBlockCollapse(_ sender: Any?) {
        if let t = targetTurn {
            toggleTurnCollapse(t)
            return
        }
        guard let b = targetBlock, b.hasOutput else { return }
        b.collapsed.toggle()
        selectedBlock = b
        scrollToAbs(b.promptLine)
    }

    @objc func collapseAllBlocks(_ sender: Any?) {
        for b in finishedBlocks where b.hasOutput { b.collapsed = true }
        for b in terminal.blocks where b.state == .running {
            // The latest turn may still be streaming, so it stays open.
            for t in terminal.agentTurns(in: b).dropLast() where t.hasResponse { collapsedTurns.insert(t.promptLine) }
        }
        needsDisplay = true
    }

    @objc func expandAllBlocks(_ sender: Any?) {
        for b in terminal.blocks { b.collapsed = false }
        collapsedTurns.removeAll()
        needsDisplay = true
    }

    @objc func saveCommandAsSnippet(_ sender: Any?) {
        guard let b = targetBlock, !b.command.isEmpty, let w = window else { return }
        let alert = NSAlert()
        alert.messageText = "Save Snippet"
        alert.informativeText = b.command
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "Snippet name"
        field.stringValue = String(b.command.prefix(40))
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: w) { resp in
            guard resp == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            SnippetStore.shared.add(Snippet(name: name.isEmpty ? b.command : name, command: b.command))
        }
    }

    private func flashBlock(_ b: Block) {
        let prev = selectedBlock
        selectedBlock = b
        needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            if self.selectedBlock === b && prev !== b { self.selectedBlock = prev }
            self.needsDisplay = true
        }
    }

    private func flashTurn(_ t: AgentTurn) {
        let prev = selectedTurnLine
        selectTurn(t)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            if self.selectedTurnLine == t.promptLine && prev != t.promptLine { self.selectedTurnLine = prev }
            self.needsDisplay = true
        }
    }

    /// Types text into the shell at the prompt (used by snippets).
    func insertText(_ s: String) {
        window?.makeFirstResponder(self)
        sendPaste(s)
    }

    // MARK: - Buffer

    @objc func clearBuffer(_ sender: Any?) {
        if terminal.usingAlt {
            NSSound.beep()
            return
        }
        terminal.clearBuffer()
        selection = nil
        selectedBlock = nil
        selectedTurnLine = nil
        collapsedTurns.removeAll()
        scrollOffset = 0
        clearSearchMatches()
        needsDisplay = true
    }

    @objc func scrollToTop(_ sender: Any?) {
        computeRowMap()
        smoothScroll(to: maxScrollOffset)
    }

    @objc func scrollToBottom(_ sender: Any?) {
        smoothScroll(to: 0)
    }

    // MARK: - Panes

    @objc func splitRight(_ sender: Any?) { tab?.split(self, vertical: true) }
    @objc func splitDown(_ sender: Any?) { tab?.split(self, vertical: false) }
    @objc func closePane(_ sender: Any?) { tab?.requestClose(self) }
    @objc func focusPaneLeft(_ sender: Any?) { tab?.focusNeighbor(of: self, direction: .left) }
    @objc func focusPaneRight(_ sender: Any?) { tab?.focusNeighbor(of: self, direction: .right) }
    @objc func focusPaneUp(_ sender: Any?) { tab?.focusNeighbor(of: self, direction: .up) }
    @objc func focusPaneDown(_ sender: Any?) { tab?.focusNeighbor(of: self, direction: .down) }
    // ⌘] / ⌘[: through a tab's panes; in a tab without panes, over to the other column of a split window.
    @objc func nextPane(_ sender: Any?) { cyclePanes(1) }
    @objc func previousPane(_ sender: Any?) { cyclePanes(-1) }

    private func cyclePanes(_ d: Int) {
        if let tab, tab.panes.count > 1 { return tab.cycleFocus(from: self, by: d) }
        (window?.windowController as? TerminalWindowController)?.focusOtherColumn(nil)
    }

    // MARK: - Keep awake

    /// Types and runs `caffeinate` (display, idle and system sleep blocked for as long as Settings says). If this pane is
    /// busy (e.g. Claude Code), it runs in a new tab instead so it doesn't land in that program's input.
    @objc func keepAwake(_ sender: Any?) {
        let cmd = Config.shared.keepAwakeCommand + "\r"
        guard pty?.hasForegroundJob == true, let wc = window?.windowController as? TerminalWindowController else {
            send(cmd)
            scrollOffset = 0
            return
        }
        wc.newTab(nil)
        wc.activeTab?.focusedPane.send(cmd)
    }

    // MARK: - Find

    @objc func showFind(_ sender: Any?) {
        if let sb = searchBar {
            sb.focus()
            return
        }
        let sb = SearchBar(terminal: self)
        addSubview(sb)
        searchBar = sb
        needsLayout = true
        layoutSubtreeIfNeeded()
        sb.focus()
        if !searchQuery.isEmpty { sb.field.stringValue = searchQuery }
    }

    func closeFind() {
        searchBar?.removeFromSuperview()
        searchBar = nil
        clearSearchMatches()
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    @objc func findNext(_ sender: Any?) { stepMatch(1) }
    @objc func findPrevious(_ sender: Any?) { stepMatch(-1) }

    func clearSearchMatches() {
        searchMatches = []
        matchesByLine = [:]
        currentMatch = -1
        searchBar?.updateCount(0, 0)
    }

    func performSearch(_ query: String) {
        searchQuery = query
        clearSearchMatches()
        guard !query.isEmpty else { needsDisplay = true; return }
        let caseSensitive = query.contains { $0.isUppercase }
        let opts: NSString.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        let (commandCols, promptLines) = searchScope == .all ? ([:], []) : commandAndPromptLines()
        var a = terminal.firstAbs
        while a <= terminal.lastAbs {
            defer { a += 1 }
            let minCol: Int
            switch searchScope {
            case .all: minCol = 0
            case .commands:
                guard let c = commandCols[a] else { continue }
                minCol = c
            case .output:
                guard commandCols[a] == nil, !promptLines.contains(a) else { continue }
                minCol = 0
            }
            guard let l = terminal.line(abs: a) else { continue }
            var s = ""
            var map: [Int] = []
            for x in 0..<l.cells.count {
                let c = l.cells[x]
                if c.width == 0 { continue }
                let str = c.ch == 0 ? " " : String(Character(Unicode.Scalar(c.ch) ?? " "))
                for _ in str.utf16 { map.append(x) }
                s += str
            }
            let ns = s as NSString
            var range = NSRange(location: 0, length: ns.length)
            while range.length > 0 {
                let r = ns.range(of: query, options: opts, range: range)
                if r.location == NSNotFound { break }
                let m = SearchMatch(line: a, start: map[r.location], end: map[max(r.location, r.location + r.length - 1)])
                if m.start >= minCol {
                    matchesByLine[a, default: []].append(searchMatches.count)
                    searchMatches.append(m)
                }
                let next = r.location + max(r.length, 1)
                range = NSRange(location: next, length: ns.length - next)
            }
        }
        if !searchMatches.isEmpty {
            // Start from the match nearest the bottom of the current view.
            computeRowMap()
            let bottom = rowMap.last(where: { $0 >= 0 }) ?? terminal.lastAbs
            currentMatch = searchMatches.lastIndex(where: { $0.line <= bottom }) ?? searchMatches.count - 1
            revealMatch()
        }
        searchBar?.updateCount(currentMatch + 1, searchMatches.count)
        needsDisplay = true
    }

    /// Lines holding typed commands (shell commands and agent prompts) mapped to the column the text starts at,
    /// plus shell-prompt (PS1) lines, which count as neither commands nor output.
    private func commandAndPromptLines() -> ([Int: Int], Set<Int>) {
        var commands: [Int: Int] = [:]
        var prompts = Set<Int>()
        for b in terminal.blocks {
            guard let c = b.commandLine else {
                if b.state == .prompt { for a in b.promptLine...b.lastLine(cursorAbs: terminal.cursorAbs) { prompts.insert(a) } }
                continue
            }
            for a in stride(from: b.promptLine, to: c, by: 1) { prompts.insert(a) }
            let end = max(c, b.state == .prompt ? b.lastLine(cursorAbs: terminal.cursorAbs) : (b.outputLine ?? c + 1) - 1)
            for a in c...end { commands[a] = a == c ? b.commandCol : 0 }
            for t in terminal.agentTurns(in: b) {
                for a in t.promptLine...t.promptEnd { commands[a] = 2 }
            }
        }
        return (commands, prompts)
    }

    private func stepMatch(_ d: Int) {
        if searchMatches.isEmpty && !searchQuery.isEmpty { performSearch(searchQuery) }
        guard !searchMatches.isEmpty else { return }
        currentMatch = (currentMatch + d + searchMatches.count) % searchMatches.count
        revealMatch()
        searchBar?.updateCount(currentMatch + 1, searchMatches.count)
        needsDisplay = true
    }

    private func revealMatch() {
        guard currentMatch >= 0 && currentMatch < searchMatches.count else { return }
        let line = searchMatches[currentMatch].line
        if let b = blockAt(abs: line), b.collapsed { b.collapsed = false }
        computeRowMap()
        if !rowMap.contains(line) { scrollToAbs(line, context: terminal.rows / 2) }
    }
}

/// Floating find bar shown in the top-right of a terminal pane.
final class SearchBar: NSView, NSTextFieldDelegate {
    let field = NSTextField()
    private let scopeButton = NSPopUpButton(frame: .zero, pullsDown: false)
    private let countLabel = NSTextField(labelWithString: "")
    private weak var terminal: TerminalView?

    init(terminal: TerminalView) {
        self.terminal = terminal
        super.init(frame: NSRect(x: 0, y: 0, width: 432, height: 36))
        wantsLayer = true
        let th = Config.shared.theme
        layer?.backgroundColor = th.surface.cgColor
        layer?.cornerRadius = 9
        layer?.borderWidth = 1
        layer?.borderColor = th.border.cgColor
        shadow = NSShadow()
        layer?.shadowOpacity = 0.35
        layer?.shadowRadius = 10
        layer?.shadowOffset = CGSize(width: 0, height: -3)

        let icon = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = th.dimText
        icon.frame = NSRect(x: 10, y: 10, width: 16, height: 16)
        addSubview(icon)

        // VS Code-style scope dropdown: search everything, only typed commands/prompts, or only output.
        scopeButton.frame = NSRect(x: 30, y: 6, width: 100, height: 24)
        scopeButton.isBordered = false
        scopeButton.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        scopeButton.contentTintColor = th.foreground.withAlphaComponent(0.75)
        scopeButton.addItems(withTitles: SearchScope.allCases.map(\.title))
        scopeButton.selectItem(at: terminal.searchScope.rawValue)
        scopeButton.target = self
        scopeButton.action = #selector(scopeChanged)
        addSubview(scopeButton)

        let divider = NSView(frame: NSRect(x: 132, y: 9, width: 1, height: 18))
        divider.wantsLayer = true
        divider.layer?.backgroundColor = th.border.cgColor
        addSubview(divider)

        field.frame = NSRect(x: 142, y: 8, width: 160, height: 20)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = NSFont.systemFont(ofSize: 13)
        field.textColor = th.foreground
        field.delegate = self
        field.cell?.isScrollable = true
        addSubview(field)

        updatePlaceholder()

        countLabel.frame = NSRect(x: 304, y: 10, width: 50, height: 16)
        countLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countLabel.textColor = th.dimText
        countLabel.alignment = .right
        addSubview(countLabel)

        let buttons: [(String, Selector)] = [("chevron.up", #selector(prev)), ("chevron.down", #selector(next)), ("xmark", #selector(close))]
        for (i, (sym, sel)) in buttons.enumerated() {
            let b = NSButton(image: NSImage(systemSymbolName: sym, accessibilityDescription: nil) ?? NSImage(), target: self, action: sel)
            b.isBordered = false
            b.contentTintColor = th.foreground.withAlphaComponent(0.75)
            b.frame = NSRect(x: 358 + CGFloat(i) * 23, y: 7, width: 22, height: 22)
            addSubview(b)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func focus() {
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func updateCount(_ i: Int, _ n: Int) {
        countLabel.stringValue = field.stringValue.isEmpty ? "" : (n == 0 ? "0/0" : "\(i)/\(n)")
        countLabel.textColor = (n == 0 && !field.stringValue.isEmpty) ? Config.shared.theme.red : Config.shared.theme.dimText
    }

    func controlTextDidChange(_ obj: Notification) {
        terminal?.performSearch(field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) {
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { prev() } else { next() }
            return true
        }
        if sel == #selector(NSResponder.cancelOperation(_:)) {
            close()
            return true
        }
        return false
    }

    private func updatePlaceholder() {
        let th = Config.shared.theme
        let scope = terminal?.searchScope ?? .all
        let text = scope == .all ? "Find" : "Find in \(scope.title.lowercased())"
        field.placeholderAttributedString = NSAttributedString(string: text, attributes: [.foregroundColor: th.dimText, .font: NSFont.systemFont(ofSize: 13)])
    }

    @objc private func scopeChanged() {
        guard let t = terminal, let scope = SearchScope(rawValue: scopeButton.indexOfSelectedItem) else { return }
        t.searchScope = scope
        updatePlaceholder()
        t.performSearch(field.stringValue)
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectedRange = NSRange(location: field.stringValue.utf16.count, length: 0)
    }

    // Its own cursor, not the terminal's I-beam underneath: a hand over the buttons (and the scope menu), an
    // I-beam in the field, an arrow elsewhere.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === self }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func cursorUpdate(with event: NSEvent) { updateCursor(event) }
    override func mouseMoved(with event: NSEvent) { updateCursor(event) }

    private func updateCursor(_ e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        let over = subviews.first { !$0.isHidden && $0.frame.contains(p) }
        (over is NSButton ? NSCursor.pointingHand : over === field ? NSCursor.iBeam : NSCursor.arrow).set()
    }

    @objc func prev() { terminal?.findPrevious(nil) }
    @objc func next() { terminal?.findNext(nil) }
    @objc func close() { terminal?.closeFind() }
}
