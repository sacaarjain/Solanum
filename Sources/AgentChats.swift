import AppKit

// Finished commands (what was run and what it printed) go to a coding agent's chat: one already running anywhere in
// Solanum, or a new one in a new tab. They arrive as a paste and are never submitted: the text waits in the chat's
// input box for you to add to and send. Several commands can be picked with ⌘-click and go together, oldest first.

enum AgentChats {
    /// An agent running in a pane, as the menu offers it.
    struct Chat {
        let pane: TerminalView
        let info: AgentInfo

        /// Its tab's name, without the spinner or mark agents put in front of their titles.
        var title: String {
            let t = pane.tab?.customTitle ?? pane.tab?.title ?? ""
            return String(t.drop { !$0.isLetter && !$0.isNumber })
        }
    }

    static func transcript(_ parts: [String]) -> String { parts.joined(separator: "\n\n") }

    /// Whether a chat just started can take a paste without it going astray: the agent has asked for pastes to be
    /// marked (so newlines in them don't submit), isn't asking a question (a trust prompt, say), and has stopped drawing.
    static func readyForPaste(bracketed: Bool, status: AgentStatus?, quietFor: TimeInterval) -> Bool {
        guard bracketed, let status, status != .waiting else { return false }
        return quietFor >= 0.4
    }

    /// Snapshot runs (DevTools) keep off the real clipboard.
    static let clipboard: NSPasteboard = ProcessInfo.processInfo.environment["SOLANUM_SNAPSHOT"] == nil
        ? .general : NSPasteboard(name: NSPasteboard.Name("solanum.devtools"))

    static func putOnClipboard(_ text: String) {
        clipboard.clearContents()
        clipboard.setString(text, forType: .string)
    }

    /// Agents running in any window, the sending pane's window first. An agent that has exited doesn't count.
    static func running(from pane: TerminalView) -> [Chat] {
        let windows = (NSApp.delegate as? AppDelegate)?.windows ?? []
        let ordered = windows.filter { $0.window === pane.window } + windows.filter { $0.window !== pane.window }
        return ordered.flatMap(\.allTabs).flatMap(\.panes).compactMap { p in
            p.updateAgent()
            guard let info = p.agent, p.pty?.hasForegroundJob == true else { return nil }
            return Chat(pane: p, info: info)
        }
    }

    /// The running chats, then a new chat with each agent installed on this Mac.
    static func menu(sending text: String, from pane: TerminalView) -> NSMenu {
        let menu = SendMenu()
        menu.autoenablesItems = false
        let chats = running(from: pane)
        if !chats.isEmpty { menu.addItem(.sectionHeader(title: "Active Chats")) }
        for chat in chats {
            var notes = ""
            if chat.pane === pane { notes += " (this pane)" }
            // A question on screen could take the paste as its answer.
            if chat.info.status == .waiting { notes += " · waiting for you" }
            let group = chat.pane.tab?.group
            // The mark says which agent; its name is only for a tab with no title to show.
            let title = (chat.title.isEmpty ? chat.info.kind.name : chat.title) + notes
            let item = ActionMenuItem(title) { [weak target = chat.pane, weak pane] in
                guard let target else { return NSSound.beep() }
                send(text, to: target)
                pane?.selectedBlocks = []
            }
            item.image = chat.info.kind.markImage
            item.isEnabled = chat.info.status != .waiting
            if let group { item.attributedTitle = chipTitle(group, title, enabled: item.isEnabled) }
            menu.tabs.setObject(chat.pane.tab, forKey: item)
            menu.addItem(item)
        }
        let kinds = InstalledAgents.shared.kinds
        if !menu.items.isEmpty && !kinds.isEmpty { menu.addItem(.separator()) }
        for kind in kinds {
            let item = ActionMenuItem("New \(kind.name) Chat" + (pane.remote == nil ? "" : " on This Mac")) { [weak pane] in
                guard let pane else { return NSSound.beep() }
                startChat(kind, text: text, from: pane)
                pane.selectedBlocks = []
            }
            item.image = kind.markImage
            menu.addItem(item)
        }
        if menu.items.isEmpty {
            let item = NSMenuItem(title: InstalledAgents.shared.scanned ? "No agents found" : "Looking for agents…", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        InstalledAgents.shared.refresh()
        return menu
    }

    /// "[chip] tab title", with the group's chip as it looks in the tab strip.
    private static func chipTitle(_ group: TabGroup, _ text: String, enabled: Bool) -> NSAttributedString {
        let font = NSFont.menuFont(ofSize: 0)
        // A disabled item's attributed title isn't dimmed for it.
        let attrs: [NSAttributedString.Key: Any] = enabled ? [.font: font] : [.font: font, .foregroundColor: NSColor.disabledControlTextColor]
        let chip = NSTextAttachment()
        let image = chipImage(group)
        image.accessibilityDescription = group.displayName
        chip.image = image
        // Centered on the menu row, as the agent's mark beside it is: half a point above the title's capitals.
        chip.bounds = CGRect(x: 0, y: (font.capHeight - image.size.height) / 2 + 0.5, width: image.size.width, height: image.size.height)
        let title = NSMutableAttributedString(attachment: chip)
        title.append(NSAttributedString(string: " " + text, attributes: attrs))
        title.addAttribute(.baselineOffset, value: chipTitleRaise, range: NSRange(location: 0, length: title.length))
        return title
    }

    /// A menu puts a title holding an attachment about a point lower than a plain one; this levels it with the mark.
    private static let chipTitleRaise: CGFloat = 1
    private static let chipFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    private static let chipHeight: CGFloat = 16
    /// How far above the chip's bottom its label's baseline is: capitals a little above center and lowercase a little
    /// below, so a name looks centered whichever it's mostly made of.
    private static let chipBaseline: CGFloat = 5

    /// A group's chip: its name on its color, or just a dot of that color when it has no name.
    private static func chipImage(_ group: TabGroup) -> NSImage {
        let color = group.color.color
        guard !group.name.isEmpty else {
            return NSImage(size: NSSize(width: 10, height: 10), flipped: false) { r in
                color.setFill()
                NSBezierPath(ovalIn: r).fill()
                return true
            }
        }
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        para.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: chipFont, .paragraphStyle: para,
            .foregroundColor: color.luminance > 0.6 ? NSColor(white: 0.1, alpha: 1) : NSColor.white]
        let textW = ceil((group.name as NSString).size(withAttributes: attrs).width)
        return NSImage(size: NSSize(width: min(160, textW + 12), height: chipHeight), flipped: false) { r in
            color.withAlphaComponent(0.88).setFill()
            NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).fill()
            // The text starts at the top of its rect, a line's ascent above the baseline.
            let lineH = ceil(chipFont.ascender - chipFont.descender)
            (group.name as NSString).draw(in: NSRect(x: 6, y: chipBaseline + chipFont.ascender - lineH, width: r.width - 12, height: lineH), withAttributes: attrs)
            return true
        }
    }

    /// The menu of chats, which marks the tab of the one highlighted, so you can see where the text would go.
    private final class SendMenu: NSMenu {
        let tabs = NSMapTable<NSMenuItem, TabSession>(keyOptions: .weakMemory, valueOptions: .weakMemory)
        private let preview = Preview()

        init() {
            super.init(title: "")
            preview.tabs = tabs
            delegate = preview
        }

        required init(coder: NSCoder) { fatalError() }

        /// Kept here, as a menu doesn't hold on to its delegate.
        private final class Preview: NSObject, NSMenuDelegate {
            weak var tabs: NSMapTable<NSMenuItem, TabSession>?
            private weak var marked: TabBarView?

            func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
                let tab = item.flatMap { tabs?.object(forKey: $0) }
                let bar = (tab?.owner as? TabColumn)?.tabBar
                if marked !== bar { marked?.sendTarget = nil }
                marked = bar
                bar?.sendTarget = tab
            }

            func menuDidClose(_ menu: NSMenu) { self.menu(menu, willHighlight: nil) }
        }
    }

    /// Dev aid (DevTools send-menu-mark): as the menu does when the item ending in `title` is highlighted.
    static func devMark(_ menu: NSMenu, title: String) {
        menu.delegate?.menu?(menu, willHighlight: menu.items.first { $0.title.hasSuffix(title) })
    }

    /// Pastes into a running chat and goes to it. With no way to mark the paste, its newlines would submit it line by
    /// line, so it goes on the clipboard instead.
    static func send(_ text: String, to pane: TerminalView) {
        guard pane.terminal.bracketedPaste, pane.agent?.status != .waiting else { return pane.chatPasteFailed(text) }
        pane.sendPaste(text)
        reveal(pane)
    }

    /// A new tab running the agent (through your alias for it, if you have one), in the sending pane's folder when
    /// that's on this Mac. The text follows once the agent's ready for it.
    static func startChat(_ kind: AgentKind, text: String, from pane: TerminalView) {
        let front = NSApp.keyWindow?.windowController as? TerminalWindowController
        let cwd = pane.remote == nil ? pane.currentDirectory : nil
        guard let tab = (pane.tab?.owner as? TabColumn)?.addTab(cwd: cwd) ?? front?.addTab(cwd: cwd) else { return NSSound.beep() }
        let chat = tab.focusedPane
        let alias = Config.shared.shellIntegration ? AliasStore.shared.alias(running: kind.command) : nil
        chat.pendingCommand = "\u{15}" + (alias ?? kind.command)
        chat.pasteWhenAgentReady(text)
    }

    static func reveal(_ pane: TerminalView) {
        if let tab = pane.tab, let column = tab.owner as? TabColumn, let i = column.tabs.firstIndex(of: tab), let owner = column.owner {
            owner.focus(column)
            column.select(index: i)
            owner.window?.makeKeyAndOrderFront(nil)
        }
        pane.window?.makeFirstResponder(pane)
    }
}

/// The agents you can start on this Mac: what your login shell finds on its PATH, looked for in the background at
/// launch and again when a menu opens, at most once a minute.
final class InstalledAgents {
    static let shared = InstalledAgents()
    private(set) var kinds: [AgentKind] = []
    private(set) var scanned = false
    private var lastScan: Date?

    /// Marks each line, as shell startup files can print anything.
    private static let marker = "solanum-agent:"

    static func parse(_ output: String) -> [AgentKind] {
        let found = Set(output.split(separator: "\n").compactMap { $0.hasPrefix(marker) ? String($0.dropFirst(marker.count)) : nil })
        return AgentKind.known.filter { found.contains($0.command) }
    }

    func refresh() {
        if let last = lastScan, Date().timeIntervalSince(last) < 60 { return }
        lastScan = Date()
        let names = AgentKind.known.map(\.command).joined(separator: " ")
        let script = "for c in \(names); do command -v \"$c\" >/dev/null 2>&1 && echo \"\(Self.marker)$c\"; done"
        let shell = ShellIntegration.userShell()
        // As a Solanum tab's shell sees it: bash reads only its login files, zsh also its .zshrc.
        let flags = (shell as NSString).lastPathComponent == "zsh" ? "-lic" : "-lc"
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: shell)
            p.arguments = [flags, script]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            var found: [AgentKind]?
            if (try? p.run()) != nil {
                // A startup file that hangs shouldn't leave this waiting.
                DispatchQueue.global().asyncAfter(deadline: .now() + 15) { if p.isRunning { p.terminate() } }
                found = Self.parse(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
                p.waitUntilExit()
            }
            DispatchQueue.main.async {
                if let found { self?.kinds = found }
                self?.scanned = true
            }
        }
    }
}

extension TerminalView {
    func chronological(_ blocks: [Block]) -> [Block] { blocks.sorted { $0.id < $1.id } }

    /// The selected commands with their output, oldest first.
    var selectedTranscript: String {
        AgentChats.transcript(chronological(selectedBlocks).map { blockText($0, includeCommand: true) })
    }

    func copySelectedBlocks() { AgentChats.putOnClipboard(selectedTranscript) }

    /// ⌥⌘S: the send menu for the selected commands, or the last one to finish.
    @objc func sendToChat(_ sender: Any?) {
        guard selectedTurnLine == nil else { return NSSound.beep() }
        let blocks = selectedBlocks.isEmpty ? targetBlock.map { [$0] } ?? [] : selectedBlocks
        guard let last = chronological(blocks).last else { return NSSound.beep() }
        let row = rowMap.firstIndex(of: last.promptLine) ?? 0
        showSendMenu(for: blocks, at: NSPoint(x: padX, y: rowY(row) + fonts.cellH))
    }

    func showSendMenu(for blocks: [Block], at point: NSPoint, in view: NSView? = nil) {
        let text = AgentChats.transcript(chronological(blocks).map { blockText($0, includeCommand: true) })
        let menu = AgentChats.menu(sending: text, from: self)
        devSendMenu = menu
        menu.popUp(positioning: nil, at: point, in: view ?? self)
    }

    func updateSelectionBar() {
        guard selectedBlocks.count > 1 else {
            selectionBar?.removeFromSuperview()
            selectionBar = nil
            return
        }
        if selectionBar == nil {
            let bar = BlockSelectionBar(onCopy: { [weak self] in self?.copySelectedBlocks() }, onSend: { [weak self] button in
                guard let self else { return }
                self.showSendMenu(for: self.selectedBlocks, at: NSPoint(x: 0, y: button.bounds.maxY + 2), in: button)
            }, onClear: { [weak self] in
                self?.selectedBlocks = []
                self?.needsDisplay = true
            })
            selectionBar = bar
            addSubview(bar)
        }
        selectionBar?.count = selectedBlocks.count
        needsLayout = true
    }

    /// Pastes `text` once the agent starting in this pane is ready for it. A question it asks first (trusting the
    /// folder, say) can take as long as it takes.
    func pasteWhenAgentReady(_ text: String) {
        let timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] t in
            guard let self else { return t.invalidate() }
            self.checkChatPaste()
        }
        chatPaste = (text, Date().addingTimeInterval(45), timer)
    }

    private func checkChatPaste() {
        guard let waiting = chatPaste else { return }
        updateAgent()
        if agent?.status == .waiting { chatPaste?.deadline = Date().addingTimeInterval(45) }
        let ready = pty?.hasForegroundJob == true && AgentChats.readyForPaste(
            bracketed: terminal.bracketedPaste, status: agent?.status, quietFor: Date().timeIntervalSince(lastOutputAt))
        guard ready || exited || Date() > waiting.deadline else { return }
        waiting.timer.invalidate()
        chatPaste = nil
        if ready { sendPaste(waiting.text) } else { chatPasteFailed(waiting.text) }
    }

    /// The text would have been lost: it goes on the clipboard, and a card says so.
    func chatPasteFailed(_ text: String) {
        AgentChats.putOnClipboard(text)
        NSSound.beep()
        guard let tab else { return }
        _ = showCornerNotice(title: "Couldn't paste into the chat", symbol: ("doc.on.clipboard", Config.shared.theme.accent),
                             lines: ["It's on the clipboard, ready for ⌘V."], in: tab)
    }
}
