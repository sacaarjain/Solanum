import CCanvas
import Foundation
import WinSDK

/// One terminal: a shell, its emulator, and what's selected and being typed. A window shows one pane at a time, its tab's.
/// Everything runs on the thread with the message loop, including the emulator: output is handed over from the reading
/// thread, not fed from it.
final class TerminalPane: TerminalDelegate, Groupable {
    private static var nextID: UInt = 1
    let id: UInt
    private(set) weak var host: TerminalWindow?
    private let hwnd: HWND
    /// The window's canvas (or a snapshot's), with its terminal area set to this pane's: in a split window there are two.
    private var canvas: Canvas {
        let c = drawTarget ?? host!.canvas!
        if let area = host?.area(for: self) { c.terminalArea = area }
        return c
    }
    /// Which column of a split window the tab is in: 0, or 1 for the right one.
    var column = 0
    /// Where `drawOverlays(on:)` is drawing, when it isn't the window.
    private var drawTarget: Canvas?
    private(set) var terminal: Terminal
    private var pty: ConPTY?
    private var selection: TerminalSelection?
    private var selecting = false
    private(set) var scrollOffset = 0
    var focused = false
    /// Proves a question for a password came from ssh in this tab (see Askpass).
    let askpassToken = Askpass.makeToken()
    /// A question from ssh waiting for an answer, shown over the bottom of the terminal.
    private(set) var question: (prompt: String, field: TextFieldState, secret: Bool, reply: (String?) -> Void)?
    /// The password this tab's ssh session signed in with, for the sidebar's own connection. Only in memory, encrypted,
    /// and dropped when the session ends.
    private(set) var rememberedPassword: ProtectedSecret?
    /// The sidebar's own connection to the host this tab is ssh'd into.
    private(set) var remote: RemoteConnection?
    private var sshStartedAt: Date?
    private var remoteAttempts = 0
    private var remoteRetryAt: Date?
    /// Why the sidebar's last connection failed, and what it was asked, for tests.
    private(set) var remoteDiagnostics: [String] = []
    private var lastRemoteFailure: String?
    /// Where the terminal's shell is on the host, as the sidebar's connection last found it.
    private(set) var remoteShellFolder: String?
    private var nextShellProbe = Date.distantPast
    private var probingShell = false
    /// Asks the window to look again, as the remote connection comes and goes.
    var onRemoteChange: (() -> Void)?

    /// The session dropped (ssh's 255 after it had signed in): which host, and how to reach it again.
    private(set) var lost: (host: String, command: String, block: Block?)?
    /// Reconnect is on its way, so the bar stays hidden.
    private(set) var reconnecting = false
    /// The dropped session's password, kept (in memory, encrypted) so that Reconnect signs both connections back in
    /// without asking. Gone once used, or when the bar goes.
    private var reconnectPassword: ProtectedSecret?
    /// How many times Reconnect has answered ssh with the kept password, for tests.
    private(set) var reconnectedCount = 0
    /// Whether this session got as far as the sidebar's connection signing in, which a refused password never does.
    private var sessionSignedIn = false

    /// A command to run once the shell first reaches its prompt.
    var pendingCommand: String?
    /// A restored tab's agent or ssh session, carried on when the tab is first shown (see SavedSession).
    var resumeOnShow: String?

    /// What would carry this tab on after a restart: ssh back to its host, or the agent running here continued.
    var resumeCommand: String? {
        if let args = sshArguments, let target = RemoteConnection.connectionArguments(args), !target.isEmpty {
            return "ssh " + target.map(Self.powerShellWord).joined(separator: " ")
        }
        guard let b = terminal.currentBlock, b.state == .running else { return nil }
        // What was typed (claude, npx codex, …), or else the agent's program running under the shell (an alias for it).
        if let command = AgentResume.command(continuing: b.command) { return command }
        return ProcessTree.descendantNames(of: shellProcessID).lazy.compactMap { AgentResume.commands[$0] }.first
    }

    var group: TabGroup?
    /// A name given to the tab, in place of the one it would have.
    var customTitle: String?
    /// The git repository its folder is in, for the status bar; what git's doing for it there ("Pulling…").
    var git: GitInfo?
    var gitBusy: String?
    var gitKey: String?
    var gitCheckedAt = Date.distantPast
    /// Pages open above the terminal (Git Graph, Git Changes, a commit, a file), as on the Mac; see EditorArea.swift.
    var editors: [EditorItem] = []
    var activeEditor = 0
    /// How much of the column the pages take.
    var editorFraction: Float = 0.55
    /// Whether the terminal shows below the pages (the strip's terminal button).
    var showsTerminal = true
    /// How far its strip of sub-tabs is scrolled along, when they don't all fit.
    var stripScroll: Float = 0
    /// Whether the keyboard is with the pages rather than the terminal.
    var editorFocused = false
    /// The page showing above the terminal.
    var panel: ColumnPanel? { editors.indices.contains(activeEditor) ? editors[activeEditor].panel : nil }
    /// Where keys and typing go: the page, while it has the keyboard.
    var focusedPanel: ColumnPanel? { editorFocused ? panel : nil }
    /// Where a link under the pointer is, while Ctrl's held over it: drawn underlined.
    var hoveredLink: (line: Int, start: Int, end: Int)?
    /// Where the sidebar was while this tab was showing. Nil until it has been.
    var sidebarPlace: SidebarPlace?
    private var pendingSurrogate: UInt16?
    private var lastMouseCell: (Int, Int)?
    /// Wheel movement not yet a whole line (or, for a program reading the mouse, a whole notch), so a touchpad's small
    /// steps add up instead of each moving a full notch.
    private var wheelRemainder: Double = 0
    /// Lines a finger has scrolled not yet a wheel notch, for a program reading the mouse.
    private var touchLines = 0
    private var lastResize: Date?
    private var pendingClick: (() -> Void)?
    private var pendingClickDeadline = Date.distantPast
    private var awaitingCursorEcho = false
    static let clickTimer: UINT_PTR = 2
    private var afterSelectionDeleted: [[UInt8]]?
    private var selectionDeleteDeadline: Date?
    private var quietWork: ((Bool) -> Void)?
    private var quietStart = Date.distantPast
    private var lastOutputAt = Date.distantPast
    static let quietTimer: UINT_PTR = 3

    /// Output waiting for the message loop.
    private let inboxLock = NSLock()
    private var inbox: [UInt8] = []
    private var outputPosted = false
    /// Above this the reading thread waits, which holds back a program printing faster than can be drawn.
    private static let inboxLimit = 8 * 1024 * 1024

    /// Starts a shell. Nil if it can't.
    init?(host: TerminalWindow, commandLine: String, cols: Int, rows: Int, cwd: String? = nil, restoring text: String? = nil) {
        id = Self.nextID
        Self.nextID += 1
        self.host = host
        hwnd = host.hwnd
        terminal = Terminal(cols: cols, rows: rows, scrollbackLimit: AppSettings.shared.scrollback)
        terminal.delegate = self
        terminal.repaintedByConsole = true
        if !FileManager.default.fileExists(atPath: AliasFile.scriptURL.path) { AliasFile.save(AliasFile.load()) }
        if let text, !text.isEmpty {
            // Moved up into scrollback, since the console is about to draw on a screen it thinks is empty.
            Array((text + String(repeating: "\r\n", count: rows)).utf8).withUnsafeBufferPointer { terminal.feed($0) }
            terminal.scrollbackPushes = 0
        }
        let home = ProcessInfo.processInfo.environment["USERPROFILE"]
        var exe = [UInt16](repeating: 0, count: 1024)
        _ = GetModuleFileNameW(nil, &exe, DWORD(exe.count))
        let environment = ["TERM": "xterm-256color", "COLORTERM": "truecolor", "TERM_PROGRAM": "Solanum", "SOLANUM_ALIASES": AliasFile.scriptURL.path,
                           "SOLANUM_ASKPASS_EXE": String(decodingCString: exe, as: UTF16.self),
                           "SOLANUM_ASKPASS_PIPE": host.askpassPipeName, "SOLANUM_ASKPASS_TOKEN": askpassToken]
        guard let pty = ConPTY(commandLine: commandLine, extraEnvironment: environment, cwd: cwd ?? home, cols: cols, rows: rows) else { return nil }
        self.pty = pty
        let target = UInt(bitPattern: hwnd), id = id
        pty.onData = { [weak self] bytes in self?.receive(bytes, window: target, id: id) }
        pty.onExit = { code in
            PostMessageW(HWND(bitPattern: target), Win.WM_EXITED, WPARAM(id), LPARAM(code))
        }
    }

    func terminate() {
        question?.reply(nil)
        question = nil
        rememberedPassword = nil
        reconnectPassword = nil
        remote?.close()
        remote = nil
        pty?.terminate()
    }

    /// Its size, as the window has just changed. Later, `reanchorIfSettled` deals with what that did to the shell.
    func resize(cols: Int, rows: Int) {
        guard cols != terminal.cols || rows != terminal.rows else { return }
        // Getting shorter is what moves the console's rows without PSReadLine knowing. It deals with width by itself.
        let shorter = rows < terminal.rows
        terminal.resize(cols: cols, rows: rows)
        pty?.resize(cols: cols, rows: rows)
        scrollOffset = min(scrollOffset, terminal.scrollback.count)
        if shorter || lastResize != nil { lastResize = Date() }
    }

    func setFocused(_ on: Bool) {
        guard on != focused else { return }
        focused = on
        if terminal.focusEvents { send(on ? "\u{1b}[I" : "\u{1b}[O") }
    }

    var tabTitle: String {
        if let customTitle, !customTitle.isEmpty { return customTitle }
        // A file tab, with its terminal hidden: the file showing, as on the Mac.
        if !showsTerminal, editors.indices.contains(activeEditor) { return editors[activeEditor].title }
        // In an ssh session, the server it's connected to.
        if let sshHost { return sshHost }
        // Without the status glyph an agent puts first (Claude Code's ✳ or spinner): the tab shows its mark and status itself.
        return WindowText.tabTitle(title: terminal.title.map(AgentKind.withoutStatusGlyph), folder: terminal.cwd, home: ProcessInfo.processInfo.environment["USERPROFILE"])
    }

    /// Whether the shell is waiting at its prompt, with no program running that might want a key.
    var atPrompt: Bool { !terminal.usingAlt && terminal.currentBlock?.state == .prompt }

    // MARK: - ssh

    /// The ssh session running in this tab: what it was started with, and the host it went to.
    var sshArguments: [String]? {
        guard terminal.sshControlPath != nil else { return nil }
        return terminal.sshArgs.map { $0.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init) } ?? []
    }

    var sshHost: String? {
        guard let args = sshArguments else { return nil }
        return SSHHostList.destination(fromArguments: args).map(SSHHostList.hostLabel) ?? "ssh"
    }

    /// ssh asks a question: shown over the terminal, typed unseen when it's for a secret.
    func ask(_ prompt: String, reply: @escaping (String?) -> Void) {
        question?.reply(nil)
        question = (prompt.trimmingCharacters(in: .whitespacesAndNewlines), TextFieldState(""), Askpass.isSecret(prompt), reply)
        invalidate()
    }

    private func answer(_ text: String?) {
        guard let current = question else { return }
        question = nil
        if let text, Askpass.isPassword(current.prompt), !current.prompt.hasPrefix("For the sidebar: "), AppSettings.shared.rememberSSHPasswords {
            rememberedPassword = ProtectedSecret(text)
        }
        lastAnswerLength = text?.count
        current.reply(text)
        invalidate()
    }

    /// How long the last answer was, never what it was: for tests to check what went to ssh.
    private(set) var lastAnswerLength: Int?

    var hasQuestion: Bool { question != nil }
    var questionPrompt: String? { question?.prompt }
    var hasRememberedPassword: Bool { rememberedPassword != nil }

    /// A key while ssh's question is showing. True if it's dealt with; characters come through `questionTyped`.
    func questionKey(_ key: Int32, ctrl: Bool) -> Bool {
        guard var current = question else { return false }
        switch key {
        case Win.VK_RETURN: answer(current.field.text); return true
        case Win.VK_ESCAPE: answer(nil); return true
        case Win.VK_BACK: current.field.deleteBackward(word: ctrl && !current.secret)
        case Win.VK_DELETE: current.field.deleteForward()
        case Win.VK_LEFT: current.field.move(by: -1)
        case Win.VK_RIGHT: current.field.move(by: 1)
        case 0x56 where ctrl:
            if let pasted = clipboardText() { current.field.insert(pasted) }
        default: return false
        }
        question = current
        invalidate()
        return true
    }

    func questionTyped(_ unit: UInt16) {
        guard var current = question, unit >= 0x20, unit != 0x7F, let scalar = Unicode.Scalar(unit) else { return }
        current.field.insert(String(Character(scalar)))
        question = current
        invalidate()
    }

    /// The session has started or ended. Ending it forgets its password, closes the sidebar's connection, and drops any
    /// question it left unanswered.
    private func sshChanged() {
        if terminal.sshControlPath == nil {
            rememberedPassword = nil
            if question != nil { answer(nil) }
            remote?.close()
            remote = nil
            sshStartedAt = nil
            remoteAttempts = 0
            remoteRetryAt = nil
            lastRemoteFailure = nil
            sessionSignedIn = false
            remoteShellFolder = nil
            onRemoteChange?()
        } else if sshStartedAt == nil {
            sshStartedAt = Date()
        }
    }

    /// Opens the sidebar's connection once the terminal has signed in: straight after a password is answered, or a few
    /// seconds in when there was no question (a key). A failed one is tried again a couple of times, quietly.
    private func manageRemote() {
        guard let args = sshArguments, let started = sshStartedAt, let host else { return }
        probeShellFolder()
        if let remote, case .failed(let why) = remote.state {
            lastRemoteFailure = why
            remoteDiagnostics.append("failed: " + remote.errorText.suffix(400))
            self.remote = nil
            remoteRetryAt = remoteAttempts < 3 ? Date().addingTimeInterval(5) : nil
            onRemoteChange?()
        }
        guard remote == nil, !hasQuestion else { return }
        let signedIn = rememberedPassword != nil || Date().timeIntervalSince(started) > 3
        guard signedIn, remoteAttempts < 3, Date() >= (remoteRetryAt ?? .distantPast) else { return }
        remoteAttempts += 1
        guard let connection = RemoteConnection(arguments: args, askpassPipe: host.askpassPipeName, post: { [weak host] work in host?.runOnWindowThreadPublic(work) }) else { return }
        connection.onChange = { [weak self] in
            guard let self else { return }
            if connection.state == .ready {
                self.remoteAttempts = 0
                self.sessionSignedIn = true
                // Back in: whatever was lost is found.
                self.clearLost()
            }
            self.onRemoteChange?()
        }
        remote = connection
        connection.start()
        onRemoteChange?()
    }

    /// Every couple of seconds, where the terminal's shell is on the host: the remote shell may say itself (OSC 7), but
    /// most don't.
    private func probeShellFolder() {
        guard let remote, remote.state == .ready, !probingShell, Date() >= nextShellProbe, let session = terminal.sshControlPath else { return }
        probingShell = true
        remote.shellFolder(session: session) { [weak self, weak remote] folder in
            self?.host?.runOnWindowThreadPublic {
                guard let self, let remote, remote === self.remote else { return }
                self.probingShell = false
                self.nextShellProbe = Date().addingTimeInterval(2)
                if let folder, folder != self.remoteShellFolder {
                    self.remoteShellFolder = folder
                    self.onRemoteChange?()
                }
            }
        }
    }

    /// Where the terminal is on the host, when that's known.
    var remoteTerminalFolder: String? { terminal.remoteCwd ?? remoteShellFolder }

    /// Where the sidebar should go on the host: the terminal's folder there, else home.
    var remoteFolder: String? {
        guard let remote, remote.state == .ready else { return nil }
        return remoteTerminalFolder ?? remote.home
    }

    /// Whether a `cd` can be typed into the ssh session: outside full-screen programs, as on the Mac, since its prompt
    /// can't be seen from here.
    var canChangeRemoteFolder: Bool { sshArguments != nil && !terminal.usingAlt && !hasQuestion }

    /// What the sidebar says while there's nothing to list from the host.
    var remoteStatus: String? {
        guard sshArguments != nil, let host = sshHost else { return nil }
        switch remote?.state {
        case .ready: return nil
        case .failed(let why)?: return why
        case .connecting?: return "Connecting to \(host)…"
        case nil:
            guard remoteAttempts >= 3 else { return "Connecting to \(host)…" }
            return "Couldn't connect to \(host) for the sidebar." + (lastRemoteFailure.map { "\n" + $0 } ?? "")
        }
    }

    /// An answer for the sidebar's connection: the remembered password, when that's what it asks for. Anything else (a
    /// one-time code) is asked here, marked as for the sidebar.
    func answerForRemote(_ prompt: String, reply: @escaping (String?) -> Void) {
        remoteDiagnostics.append("asked: " + prompt + (rememberedPassword == nil ? " (nothing remembered)" : ""))
        if Askpass.isPassword(prompt), let password = rememberedPassword {
            password.reveal { reply($0) }
            return
        }
        ask("For the sidebar: " + prompt, reply: reply)
    }

    /// ssh's own question for the terminal: answered with the dropped session's password straight after Reconnect,
    /// else asked here.
    func answerForTerminal(_ prompt: String, reply: @escaping (String?) -> Void) {
        if Askpass.isPassword(prompt), let password = reconnectPassword {
            reconnectedCount += 1
            reconnectPassword = nil
            rememberedPassword = password
            lastAnswerLength = nil
            password.reveal { reply($0) }
            return
        }
        ask(prompt, reply: reply)
    }

    // MARK: - Lost connection

    func terminalSSHExited(_ t: Terminal, status: Int) {
        remoteDiagnostics.append("ssh exited \(status), signed in: \(sessionSignedIn), arguments: \(sshArguments ?? [])")
        let wasReconnecting = reconnecting
        reconnecting = false
        lost?.block = terminal.currentBlock
        guard status == 255, sessionSignedIn || wasReconnecting, let args = sshArguments,
              let target = RemoteConnection.connectionArguments(args) else {
            if lost != nil { invalidate() }
            return
        }
        let name = sshHost ?? "the ssh host"
        lost = (name, "ssh " + target.map(Self.powerShellWord).joined(separator: " "), terminal.currentBlock)
        if let password = rememberedPassword { reconnectPassword = password }
        // A card, as on the Mac, with Reconnect, up for ten minutes unless it's dealt with.
        lostNotice?.dismiss()
        noticeReconnect = nil
        lostNotice = TerminalWindow.postNotice(NoticeRules.lostConnection(host: name, place: noticePlace, folder: terminal.remoteCwd), about: self,
                                               button: ("Reconnect", { [weak self] in self?.reconnectFromNotice(host: name) }),
                                               keepsOpen: true, lifetime: 600)
        if !(host?.isFocused ?? false) { FlashWindow(hwnd, true) }
        invalidate()
    }

    func terminalBlockFinished(_ t: Terminal, block: Block) {
        // A commit, a checkout, an edit: git's state may have changed.
        host?.paneCommandFinished(self)
        // A long command in a tab you're not watching: a card when it's done.
        if !isWatched, let card = NoticeRules.commandFinished(command: block.command, duration: block.duration, exitCode: block.exitCode,
                                                              threshold: AppSettings.shared.notifyAfterSeconds, place: noticePlace) {
            TerminalWindow.postNotice(card, about: self)
        }
        // Something else run here since: the bar's question has gone away.
        if let lost, block !== lost.block, terminal.sshControlPath == nil, !reconnecting, !block.command.isEmpty { clearLost() }
    }

    private func clearLost() {
        // Back in (or moved on): the card's question has gone away.
        lostNotice?.dismiss()
        lostNotice = nil
        noticeReconnect = nil
        guard lost != nil || reconnectPassword != nil else { return }
        lost = nil
        reconnecting = false
        reconnectPassword = nil
        invalidate()
    }

    /// A word for PowerShell, quoted when it needs to be.
    static func powerShellWord(_ word: String) -> String {
        let plain = !word.isEmpty && word.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "@._:=/-+,".unicodeScalars.contains($0) }
        return plain && !word.hasPrefix("@") ? word : "'" + word.replacingOccurrences(of: "'", with: "''") + "'"
    }

    /// The bar's Reconnect: ssh again, at the prompt once the shell is at one.
    func reconnect() {
        guard let lost, terminal.sshControlPath == nil, !terminal.usingAlt else { _ = MessageBeep(UINT(bitPattern: -1)); return }
        reconnecting = true
        pendingCommand = lost.command
        invalidate()
    }

    /// The bar's Close: lets go of the kept password; the window closes the tab.
    func dismissLost() { clearLost() }

    var showsLostBar: Bool { lost != nil && terminal.sshControlPath == nil && !reconnecting }

    enum LostBarButton { case reconnect, close }

    /// Where the bar and its two buttons are: in the terminal's top right corner, as on the Mac.
    func lostBarLayout() -> (box: UIRect, reconnect: UIRect, close: UIRect)? {
        guard showsLostBar, let lost, let area = canvas.terminalArea else { return nil }
        let s = Float(GetDpiForWindow(hwnd)) / 96
        func width(_ text: String, _ semibold: Bool) -> Float {
            let u = Array(text.utf16)
            return sol_canvas_measure_label(canvas.raw, u, Int32(u.count), 12 * s, semibold ? 1 : 0).rounded(.up)
        }
        let reconnectW = width("Reconnect", true) + 12 * s, closeW = width("Close", true) + 12 * s
        let labelW = min(width("Lost connection to \(lost.host)", true), 320 * s)
        let w = min(32 * s + labelW + 8 * s + reconnectW + 4 * s + closeW + 8 * s, area.width - 24 * s), h = 32 * s
        let box = UIRect(x: area.maxX - 12 * s - w, y: area.y + 10 * s, width: w, height: h)
        let close = UIRect(x: box.maxX - 8 * s - closeW, y: box.y + 5 * s, width: closeW, height: h - 10 * s)
        let reconnect = UIRect(x: close.x - 4 * s - reconnectW, y: close.y, width: reconnectW, height: close.height)
        return (box, reconnect, close)
    }

    func lostBarButton(atX x: Float, y: Float) -> LostBarButton? {
        guard let l = lostBarLayout(), l.box.contains(x, y) else { return nil }
        if l.reconnect.contains(x, y) { return .reconnect }
        if l.close.contains(x, y) { return .close }
        return nil
    }

    func lostBarContains(x: Float, y: Float) -> Bool { lostBarLayout()?.box.contains(x, y) ?? false }

    private func drawLostBar() {
        guard let l = lostBarLayout(), let lost else { return }
        let s = Float(GetDpiForWindow(hwnd)) / 96, fg = TerminalPalette.foreground, b = l.box
        sol_canvas_fill_rounded(canvas.raw, b.x, b.y + 2 * s, b.width, b.height, 8 * s, 0x000000, 0.25)
        sol_canvas_fill_rounded(canvas.raw, b.x, b.y, b.width, b.height, 8 * s, TerminalPalette.mix(TerminalPalette.surface, TerminalPalette.chrome, 0.75), 1)
        sol_canvas_stroke_rounded(canvas.raw, b.x + 0.5, b.y + 0.5, b.width - 1, b.height - 1, 8 * s, TerminalPalette.foreground, 0.15, 1)
        sol_canvas_draw_icon(canvas.raw, b.x + 8 * s, b.y, 20 * s, b.height, 0xE7BA, 12 * s, TerminalPalette.ansi[1], 1)
        let text = Array("Lost connection to \(lost.host)".utf16)
        sol_canvas_draw_label(canvas.raw, b.x + 32 * s, b.y, l.reconnect.x - b.x - 40 * s, b.height, text, Int32(text.count), 12 * s, 1, fg, 0.9)
        for (title, r) in [("Reconnect", l.reconnect), ("Close", l.close)] {
            if hoveredLostButton == (title == "Reconnect" ? .reconnect : .close) {
                sol_canvas_fill_rounded(canvas.raw, r.x, r.y, r.width, r.height, 5 * s, fg, 0.08)
            }
            let u = Array(title.utf16)
            sol_canvas_draw_label(canvas.raw, r.x + 6 * s, r.y, r.width - 12 * s, r.height, u, Int32(u.count), 12 * s, 1, TerminalPalette.accent, 1)
        }
    }

    var hoveredLostButton: LostBarButton?

    /// Timed work that doesn't depend on being the pane on screen.
    // MARK: - Coding agents

    /// The coding agent running here and what it's doing (see Core/AgentState.swift), as on the Mac; nil when none.
    private(set) var agent: AgentInfo?
    /// Images pasted into Claude Code, drawn where it lists them (see ImageChips).
    let imageChips = ImageChips()
    /// The shell it runs, when it's one Solanum knows (see Shells).
    var shell: ShellOption?

    // MARK: Claude's code boxes (see Core's CodeBoxFinder)

    /// Code blocks, tables and quotes in Claude's replies on screen, each with a Copy button, as on the Mac.
    private(set) var codeBoxes: [CodeBox] = []
    /// What the last scan looked at (the transcripts and the screen), so an unchanged one isn't done again.
    private var boxScanKey: String?
    private var boxScanning = false
    /// The Copy buttons drawn this frame, by index into `codeBoxes`; the one hovered; the one saying "Copied".
    private var copyButtons: [(rect: UIRect, box: Int)] = []
    private var hoverCopyButton: Int?
    private var copiedBox: (box: Int, until: Date)?

    /// Re-finds Claude's code blocks, tables and quotes whenever its transcript or the screen has moved on. Skipped while
    /// it's working (the screen churns, and the reply isn't in the transcript yet). Code blocks come from Claude's
    /// transcript, which is only here for Claude on this PC; tables and quotes are found from the screen alone, so over
    /// ssh they still get theirs.
    private func refreshCodeBoxes() {
        let before = codeBoxes.count
        codeBoxes.removeAll { !terminal.stillShows($0) }
        if codeBoxes.count != before { invalidate() }
        guard let agent, agent.kind == .claude, agent.status != .working, !boxScanning, let host else { return }
        boxScanning = true
        let cwd = sshArguments == nil ? terminal.cwd : nil
        let home = ProcessInfo.processInfo.environment["USERPROFILE"] ?? ""
        DispatchQueue.global(qos: .utility).async { [weak self, weak host] in
            let found: (blocks: [String], signature: String) = cwd.map { ClaudeTranscript.codeBlocks(cwd: $0, home: home) } ?? ([], "screen")
            host?.runOnWindowThreadPublic {
                guard let self else { return }
                let t = self.terminal
                let key = "\(found.signature)|\(t.firstAbs)|\(t.lastAbs)|\(t.cols)|\(t.cursorAbs)"
                guard key != self.boxScanKey else { self.boxScanning = false; return }
                self.boxScanKey = key
                // The scan reads the whole scrollback, so it runs on a copy, off the window's thread.
                let lines = t.snapshot()
                LineSnapshot.scanQueue.async { [weak self, weak host] in
                    let boxes = lines.findBoxes(code: found.blocks)
                    host?.runOnWindowThreadPublic {
                        guard let self else { return }
                        self.boxScanning = false
                        self.codeBoxes = boxes.filter { self.terminal.stillShows($0) }
                        self.copiedBox = nil
                        self.invalidate()
                    }
                }
            }
        }
    }

    /// A selection's text: inside a code block or quote, that stretch of the original (no indentation, no line breaks
    /// where the screen wrapped a long line); anywhere else, what's on screen.
    private func selectedText(_ s: TerminalSelection) -> String {
        let o = s.ordered
        if let box = codeBoxes.first(where: { $0.kind != .table && $0.contains(line: o.start.line) && $0.contains(line: o.end.line) }),
           let text = box.sourceText(from: GridPos(line: o.start.line, col: o.start.col), to: GridPos(line: o.end.line, col: o.end.col), columns: terminal.cols) {
            return text
        }
        return s.text(in: terminal)
    }

    /// Copy on a box: the original code, the quote's text, or the table as markdown (and as HTML, so Word, Excel, Teams
    /// and the like paste a real table). "Copied" shows on its button for a moment.
    private func copyBox(_ i: Int) {
        guard codeBoxes.indices.contains(i) else { return }
        let box = codeBoxes[i]
        setClipboard(box.copyText, html: box.html)
        copiedBox = (i, Date().addingTimeInterval(1.5))
        invalidate()
    }

    private var dpiScale: Float { Float(GetDpiForWindow(hwnd)) / 96 }

    private func drawCodeBoxes(top: Int) {
        CodeBoxView(canvas: canvas, terminal: terminal, boxes: codeBoxes, top: top, scale: dpiScale).drawPanels()
    }

    private func drawCopyButtons(top: Int) {
        if let copied = copiedBox, Date() >= copied.until { copiedBox = nil }
        copyButtons = CodeBoxView(canvas: canvas, terminal: terminal, boxes: codeBoxes, top: top, scale: dpiScale)
            .drawButtons(hover: hoverCopyButton, copied: copiedBox?.box)
    }

    /// Whether a point is on a Copy button: the pointer becomes a hand there.
    func isOverCopyButton(x: Float, y: Float) -> Bool { copyButtons.contains { $0.rect.contains(x, y) } }

    // MARK: Corner cards (see CornerNotices and Core's NoticeRules)

    /// The agent working and stopping, for a card once it's stopped a while.
    private var agentWatch = AgentStopWatch()
    /// The lost-connection card, while it's up.
    private weak var lostNotice: CornerNotice?
    /// Reconnect pressed on that card: when, and whether a password has gone from it since.
    private var noticeReconnect: (host: String, at: Date, sent: Bool)?

    /// "Group › Tab", for a card's first line.
    private var noticePlace: String { NoticeRules.place(tab: tabTitle, group: group?.name) }

    private var isWatched: Bool { host?.isWatching(self) ?? false }

    /// An agent that worked at least "Notify after" seconds and then stopped (done, or waiting on you) in a tab you're
    /// not watching gets a card, as a long command does.
    private func checkAgentStopped() {
        let stopped = agent?.status == .done || agent?.status == .waiting
        guard let worked = agentWatch.settled(stillStopped: stopped), let a = agent else { return }
        let threshold = AppSettings.shared.notifyAfterSeconds
        guard threshold > 0, worked >= threshold, !isWatched else { return }
        let prompt = terminal.currentBlock.flatMap { terminal.agentTurns(in: $0).last }.map { terminal.agentPromptText($0) }
        TerminalWindow.postNotice(NoticeRules.agentStopped(agent: a.kind.name, waiting: a.status == .waiting, worked: worked,
                                                           prompt: prompt, place: noticePlace), about: self)
    }

    /// Reconnect on the lost-connection card: logs back in here without leaving the tab you're in; if the host asks
    /// for a password, the card asks for it.
    private func reconnectFromNotice(host name: String) {
        reconnect()
        guard reconnecting || pendingCommand != nil, let notice = lostNotice else { return }
        notice.hideButton()
        notice.setTitle("Reconnecting to \(name)\u{2026}")
        noticeReconnect = (name, Date(), false)
    }

    /// For five minutes after Reconnect on the card, or until logged in (the card goes then): ssh's password question
    /// is asked in the card too; a wrong password's "try again" asks again.
    private func watchNoticeSecret() {
        guard let watch = noticeReconnect else { return }
        guard let notice = lostNotice, !notice.isGone, Date().timeIntervalSince(watch.at) < 300 else {
            noticeReconnect = nil
            lostNotice?.endSecret()
            return
        }
        if let q = question, q.secret {
            guard !notice.hasSecret else { return }
            notice.setTitle(watch.sent ? "Try again: \(watch.host)" : "Log in to \(watch.host)")
            notice.askSecret(q.prompt) { [weak self] secret in self?.answerFromNotice(secret) }
        } else if notice.hasSecret {
            // Answered in the tab instead, or ssh stopped asking.
            notice.endSecret()
        }
    }

    /// Only into the question the card asked: if that's gone, the password isn't sent anywhere.
    private func answerFromNotice(_ secret: String) {
        guard let watch = noticeReconnect, let notice = lostNotice else { return }
        notice.endSecret()
        guard let q = question, q.secret else {
            notice.setTitle("\(watch.host) stopped asking; open the tab to log in")
            return
        }
        answer(secret)
        noticeReconnect?.sent = true
        notice.setTitle("Logging in to \(watch.host)\u{2026}")
    }
    /// The agent last seen running, and one that exited with an error (shown as failed until another command runs).
    private var runningAgent: AgentKind?
    private var failedAgent: AgentKind?
    private var agentCheckedAt = Date.distantPast

    /// Looks again, at most once a second, at which agent is running and its state. True if what's shown changed.
    private func updateAgent() -> Bool {
        guard Date().timeIntervalSince(agentCheckedAt) >= 1 else { return false }
        agentCheckedAt = Date()
        defer { refreshCodeBoxes() }
        // Something's running (or, without shell integration to say, may be).
        let busy = terminal.currentBlock.map { $0.state == .running } ?? true
        var kind: AgentKind?
        if busy {
            // Claude Code's title (also over ssh), else what was typed (an agent's command, or through npx and the like),
            // else the agent's program running under the shell (an alias for it, a script).
            kind = AgentKind.fromTitle(terminal.title)
            if kind == nil, let b = terminal.currentBlock, let continuing = AgentResume.command(continuing: b.command) {
                kind = continuing.split(separator: " ").first.flatMap { AgentKind.named(String($0)) }
            }
            if kind == nil {
                kind = ProcessTree.descendantNames(of: shellProcessID).lazy.compactMap { AgentKind.detect(name: $0, path: "", args: []) }.first
            }
        }
        var next: AgentInfo?
        if let kind {
            runningAgent = kind
            failedAgent = nil
            next = AgentInfo(kind: kind, status: terminal.agentScreenStatus())
        } else {
            if let r = runningAgent {
                runningAgent = nil
                if terminal.blocks.last(where: { $0.state == .finished })?.failed == true { failedAgent = r }
            }
            if busy && terminal.currentBlock != nil { failedAgent = nil }
            if let f = failedAgent { next = AgentInfo(kind: f, status: .failed) }
        }
        guard next != agent else { return false }
        agentWatch.update(working: next?.status == .working)
        agent = next
        return true
    }

    /// Ten times a second or so, from the window's timer. True when something the tab shows has changed.
    @discardableResult
    func tick() -> Bool {
        let agentChanged = updateAgent()
        tickWork()
        checkAgentStopped()
        watchNoticeSecret()
        // An image Claude Code hasn't finished writing yet: look again.
        // "Copied" on a code box's button has had its moment.
        let copiedDone = copiedBox.map { Date() >= $0.until } ?? false
        return agentChanged || imageChips.wantsRetry || copiedDone
    }

    private func tickWork() {
        manageRemote()
        if let command = pendingCommand, atPrompt {
            pendingCommand = nil
            write(Array((command + "\r").utf8))
        }
        // Should the cursor never get there (the box closed, say), what's waiting still goes.
        if let deadline = selectionDeleteDeadline, Date() > deadline { endDeletingSelection() }
        reanchorIfSettled()
    }

    func draw(cursorShown: Bool = true, style: Int = 6) {
        var renderer = TerminalRenderer(canvas: canvas, terminal: terminal)
        renderer.scrollOffset = scrollOffset
        renderer.selection = selection
        renderer.findMatches = findBar?.cells ?? [:]
        renderer.focused = focused
        renderer.cursorShown = cursorShown
        renderer.cursorStyle = style
        let dpiScale = Float(GetDpiForWindow(hwnd)) / 96
        if agent != nil && !terminal.usingAlt {
            imageChips.layout(terminal: terminal, top: terminal.screenTopAbs - scrollOffset, canvas: canvas, shell: shellProcessID, scale: dpiScale)
            renderer.hiddenText = imageChips.hidden
        } else {
            imageChips.clear()
        }
        let screenTop = terminal.screenTopAbs - scrollOffset
        drawCodeBoxes(top: screenTop)
        renderer.drawContents()
        drawCopyButtons(top: screenTop)
        imageChips.draw(on: canvas, scale: dpiScale)
        // The link under the pointer, while Ctrl's held.
        if let h = hoveredLink {
            let row = h.line - (terminal.screenTopAbs - scrollOffset), m = canvas.metrics
            if row >= 0 && row < terminal.rows {
                sol_canvas_fill_rect(canvas.raw, canvas.contentX + Float(h.start) * m.cellWidth, canvas.contentY + Float(row + 1) * m.cellHeight - max(m.lineThickness, 1),
                                     Float(h.end - h.start + 1) * m.cellWidth, max(m.lineThickness, 1), TerminalPalette.accent, 1)
            }
        }
        drawSelectedStop()
        drawLostBar()
        drawQuestion()
        if let findBar, let area = canvas.terminalArea { findBar.draw(on: canvas, in: area, scale: Float(GetDpiForWindow(hwnd)) / 96) }
    }

    // MARK: - Find (Ctrl+F), as the Mac's ⌘F

    private(set) var findBar: TerminalFindBar?
    /// The find bar has the keyboard.
    var findFocused: Bool { findBar?.focused == true }
    /// Opens the scope's menu under a rectangle (the window's menus).
    var showFindScopeMenu: (_ items: [MenuItem], _ under: UIRect) -> Void = { _, _ in }

    /// Ctrl+F: the bar, its text selected to type over; again, back to it.
    func showFind() {
        if findBar == nil {
            findBar = TerminalFindBar()
            runFind()
        }
        findBar?.focused = true
        findBar?.fieldSelected = true
        invalidate()
    }

    func closeFind() {
        findBar = nil
        invalidate()
    }

    /// Searches again, from the last match at or above the bottom of what's showing, and shows it.
    private func runFind() {
        guard let bar = findBar else { return }
        bar.search(terminal, bottomLine: terminal.screenTopAbs - scrollOffset + terminal.rows - 1)
        revealFindMatch()
        invalidate()
    }

    func stepFind(_ d: Int) {
        guard let bar = findBar else { return }
        if bar.matches.isEmpty && !bar.field.text.isEmpty { bar.search(terminal, bottomLine: terminal.screenTopAbs - scrollOffset + terminal.rows - 1) }
        else { bar.step(d) }
        revealFindMatch()
        invalidate()
    }

    /// The current match in view: scrolled so it's in the middle, when it isn't showing.
    private func revealFindMatch() {
        guard let line = findBar?.currentLine else { return }
        let top = terminal.screenTopAbs - scrollOffset
        guard line < top || line >= top + terminal.rows else { return }
        scrollOffset = min(max(terminal.screenTopAbs - (line - terminal.rows / 2), 0), max(terminal.screenTopAbs - terminal.firstAbs, 0))
    }

    /// A key while the bar has the keyboard; nil for those that go on as usual (the app's Ctrl keys).
    func findKey(_ key: Int32, shift: Bool, ctrl: Bool) -> Bool? {
        guard let bar = findBar else { return nil }
        switch key {
        case Win.VK_ESCAPE: closeFind()
        case Win.VK_RETURN, 0x72: stepFind(shift ? -1 : 1)
        case Win.VK_UP, Win.VK_DOWN, Win.VK_PRIOR, Win.VK_NEXT, Win.VK_TAB: break
        case 0x41 where ctrl: bar.fieldSelected = true
        case 0x43 where ctrl: setClipboard(bar.field.text)
        case 0x56 where ctrl:
            if let text = clipboardText()?.split(whereSeparator: \.isNewline).first.map(String.init) {
                bar.type(text)
                runFind()
            }
        case 0x46 where ctrl: bar.fieldSelected = true
        default:
            if ctrl { return nil }
            if bar.edit(key, ctrl: ctrl) { runFind() }
            invalidate()
            // Characters come as WM_CHAR.
            return [Win.VK_BACK, Win.VK_DELETE, Win.VK_LEFT, Win.VK_RIGHT, Win.VK_HOME, Win.VK_END].contains(key)
        }
        invalidate()
        return true
    }

    func findTyped(_ unit: UInt16) {
        guard let bar = findBar, unit >= 0x20, unit != 0x7F, let scalar = Unicode.Scalar(unit) else { return }
        bar.type(String(Character(scalar)))
        runFind()
    }

    /// The pointer over the bar: true when it's taken. A press elsewhere in the terminal gives it the keyboard back.
    func findMouse(_ message: UINT, x: Float, y: Float) -> Bool {
        guard let bar = findBar else { return false }
        let part = bar.part(atX: x, y: y)
        if part != bar.hovered { bar.hovered = part; invalidate() }
        guard let part else {
            if message == Win.WM_LBUTTONDOWN && bar.focused { bar.focused = false; invalidate() }
            return false
        }
        if message == Win.WM_LBUTTONDOWN {
            bar.focused = true
            if part == .field { bar.fieldSelected = false; bar.field.move(to: bar.field.text.count) }
            invalidate()
        }
        if message == Win.WM_LBUTTONDBLCLK && part == .field { bar.fieldSelected = true; invalidate() }
        if message == Win.WM_LBUTTONUP {
            switch part {
            case .previous: stepFind(-1)
            case .next: stepFind(1)
            case .close: closeFind()
            case .scope:
                if let r = bar.rect(.scope) {
                    let items = SearchScope.allCases.map { scope in
                        MenuItem(title: scope.title, isChecked: scope == bar.scope) { [weak self, weak bar] in
                            bar?.scope = scope
                            bar?.focused = true
                            self?.runFind()
                        }
                    }
                    showFindScopeMenu(items, r)
                }
            default: break
            }
        }
        return true
    }

    /// What's drawn over the terminal (the lost connection bar, ssh's question), on another canvas: for snapshots.
    func drawOverlays(on target: Canvas) {
        drawTarget = target
        defer { drawTarget = nil }
        drawSelectedStop()
        drawLostBar()
        drawQuestion()
    }

    /// ssh's question, in a box along the bottom of the terminal, with a lock for a secret.
    private func drawQuestion() {
        guard let current = question, let area = canvas.terminalArea else { return }
        let s = Float(GetDpiForWindow(hwnd)) / 96, fg = TerminalPalette.foreground
        let box = UIRect(x: area.x + 16 * s, y: area.maxY - 64 * s, width: max(area.width - 32 * s, 200 * s), height: 48 * s)
        sol_canvas_fill_rounded(canvas.raw, box.x, box.y + 2 * s, box.width, box.height, 10 * s, 0x000000, 0.25)
        sol_canvas_fill_rounded(canvas.raw, box.x, box.y, box.width, box.height, 10 * s, TerminalPalette.mix(TerminalPalette.surface, TerminalPalette.chrome, 0.75), 1)
        sol_canvas_stroke_rounded(canvas.raw, box.x + 0.5, box.y + 0.5, box.width - 1, box.height - 1, 10 * s, TerminalPalette.accent, 0.8, 1)
        sol_canvas_draw_icon(canvas.raw, box.x + 10 * s, box.y, 24 * s, box.height, current.secret ? 0xE72E : 0xE897, 13 * s, TerminalPalette.accent, 1)
        let prompt = Array(current.prompt.utf16)
        let promptWidth = min(sol_canvas_measure_label(canvas.raw, prompt, Int32(prompt.count), 12.5 * s, 0), box.width * 0.55)
        sol_canvas_draw_label(canvas.raw, box.x + 40 * s, box.y, promptWidth + 2, box.height, prompt, Int32(prompt.count), 12.5 * s, 0, fg, 0.8)
        let fieldX = box.x + 48 * s + promptWidth, field = UIRect(x: fieldX, y: box.y + 9 * s, width: box.maxX - 12 * s - fieldX, height: 30 * s)
        sol_canvas_fill_rounded(canvas.raw, field.x, field.y, field.width, field.height, 5 * s, TerminalPalette.mix(0x000000, TerminalPalette.background, 0.3), 1)
        let shown = current.secret ? String(repeating: "•", count: current.field.text.count) : current.field.text
        let caretText = current.secret ? String(repeating: "•", count: current.field.caret) : current.field.beforeCaret
        let units = Array(shown.utf16), before = Array(caretText.utf16)
        sol_canvas_draw_label(canvas.raw, field.x + 8 * s, field.y, field.width - 16 * s, field.height, units, Int32(units.count), 13 * s, 0, fg, 1)
        let caretX = field.x + 8 * s + sol_canvas_measure_label(canvas.raw, before, Int32(before.count), 13 * s, 0)
        sol_canvas_fill_rect(canvas.raw, caretX.rounded(), field.y + 7 * s, max(s.rounded(), 1), field.height - 14 * s, TerminalPalette.accent, 1)
    }

    // MARK: - Output

    /// On the reading thread.
    private func receive(_ bytes: UnsafeBufferPointer<UInt8>, window: UInt, id: UInt) {
        while true {
            inboxLock.lock()
            if inbox.count < Self.inboxLimit { break }
            inboxLock.unlock()
            Thread.sleep(forTimeInterval: 0.002)
        }
        inbox.append(contentsOf: bytes)
        let post = !outputPosted
        outputPosted = true
        inboxLock.unlock()
        if post { PostMessageW(HWND(bitPattern: window), Win.WM_OUTPUT, WPARAM(id), 0) }
    }

    func drainOutput() {
        inboxLock.lock()
        let bytes = inbox
        inbox = []
        outputPosted = false
        inboxLock.unlock()
        bytes.withUnsafeBufferPointer { terminal.feed($0) }
        lastOutputAt = Date()
        awaitingCursorEcho = false
        runPendingClick()
        if scrollOffset > 0 { scrollOffset += terminal.scrollbackPushes }
        terminal.scrollbackPushes = 0
        scrollOffset = min(scrollOffset, terminal.scrollback.count)
        guard !terminal.syncOutput else { return }
        host?.paneChanged(self)
    }

    private func invalidate() { host?.paneChanged(self) }

    /// Once the window has stopped changing size and the console has redrawn (see `PowerShellIntegration.reanchorKey`).
    func reanchorIfSettled() {
        guard let last = lastResize, Date().timeIntervalSince(last) > 0.25 else { return }
        lastResize = nil
        if terminal.currentBlock?.state == .prompt { pty?.write(PowerShellIntegration.reanchorKey) }
    }

    // MARK: - Keyboard

    private func isDown(_ key: Int32) -> Bool { GetKeyState(key) < 0 }

    /// Keys that don't type a character. True if it's dealt with, and shouldn't go on to become one.
    func keyDown(_ key: Int32) -> Bool {
        keyDown(key, shift: isDown(Win.VK_SHIFT), ctrl: isDown(Win.VK_CONTROL), alt: isDown(Win.VK_MENU))
    }

    /// A picture on the clipboard (a screenshot, an image copied from a page) and no text with it.
    private static var clipboardHasOnlyImage: Bool {
        let image = IsClipboardFormatAvailable(Win.CF_DIB) || IsClipboardFormatAvailable(2) || IsClipboardFormatAvailable(17)
            || IsClipboardFormatAvailable(RegisterClipboardFormatW(wide("PNG")))
        return image && !IsClipboardFormatAvailable(13)
    }

    func keyDown(_ key: Int32, shift: Bool, ctrl: Bool, alt: Bool) -> Bool {
        if key == Win.VK_F4 && alt { return false }

        // Plain Ctrl+C, V and X act on the clipboard where that can't take anything from the program.
        if ctrl && !shift && !alt {
            switch key {
            case 0x41:
                // Ctrl+A in Claude Code's prompt box: all that's typed there, which typing or Backspace then replaces.
                // Elsewhere it's the program's (PowerShell selects its line itself).
                guard let block = terminal.currentBlock, block.state == .running, let rows = terminal.agentInputRows(block),
                      rows.contains(terminal.cursorAbs) else { break }
                let end = terminal.agentTextEnd(rows.upperBound)
                guard rows.lowerBound < rows.upperBound || end > 2 else { break }
                selection = TerminalSelection(anchor: (rows.lowerBound, 2), head: (rows.upperBound, end))
                selecting = false
                invalidate()
                return true
            case 0x43:
                // With nothing selected it's the program's interrupt. Copying clears the selection, so a second one is too.
                guard let chosen = selection, !chosen.isEmpty else { break }
                copySelection()
                selection = nil
                invalidate()
                return true
            case 0x56:
                // An image on the clipboard goes to a coding agent the way it takes one: on Windows Claude Code reads it
                // off the clipboard on Alt+V (Ctrl+V only ever brings it text), so that's what it's sent, as on the Mac
                // where Ctrl+V does it.
                if (agent != nil || agentInputActive) && Self.clipboardHasOnlyImage {
                    typed(0x76, meta: true)
                    return true
                }
                // Full-screen programs have their own use for it (vim's block selection, nano's page down). Ctrl+Shift+V
                // still pastes there.
                if terminal.usingAlt { break }
                paste()
                return true
            case 0x58:
                if let chosen = selection, !chosen.isEmpty, replaceSelectedInput(with: []) {
                    setClipboard(selectedText(chosen))
                    return true
                }
            default: break
            }
        }

        // Ctrl+Shift is what's left for the app: on its own, Ctrl+C and Ctrl+V belong to the shell.
        if ctrl && shift && !alt {
            switch key {
            case 0x43:
                // A selection, or with none the picked (or last) command or prompt, as the Mac's Shift-Command-C.
                if let chosen = selection, !chosen.isEmpty { copySelection() } else { copyStopCommand() }
                return true
            case 0x56:
                paste()
                return true
            case 0x58:
                cutSelection()
                return true
            default: break
            }
        }
        if shift && !ctrl && !alt {
            switch key {
            case Win.VK_INSERT:
                paste()
                return true
            case Win.VK_PRIOR, Win.VK_NEXT:
                guard !terminal.usingAlt else { break }
                scroll(by: (key == Win.VK_PRIOR ? 1 : -1) * max(terminal.rows - 1, 1))
                return true
            default: break
            }
        }

        // Ctrl+Up and Down step through commands and prompts, Ctrl+Alt+C copies one with its output and Ctrl+Alt+R runs it
        // again, as the Mac's Command-Up and Down, Option-Command-C and R. Full-screen programs keep them.
        if ctrl && !shift && !alt && (key == Win.VK_UP || key == Win.VK_DOWN) && !terminal.usingAlt {
            if key == Win.VK_UP { selectPreviousStop() } else { selectNextStop() }
            return true
        }
        if ctrl && alt && !shift && key == 0x43 { copyStopWithOutput(); return true }
        if ctrl && alt && !shift && key == 0x52 { rerunStop(); return true }
        // Esc puts away a picked command first.
        if key == Win.VK_ESCAPE && !ctrl && !alt && selectedStop != nil {
            selectedStop = nil
            invalidate()
            return true
        }

        // Backspace or Delete takes out text selected in the line being typed, whatever else is held.
        if (key == Win.VK_BACK || key == Win.VK_DELETE) && selection != nil && replaceSelectedInput(with: []) { return true }
        // PSReadLine undoes on Ctrl+Z itself. Claude Code's undo is Ctrl+_.
        if key == 0x5A && ctrl && !shift && !alt && agentInputActive {
            input([0x1F])
            return true
        }

        let mod = 1 + (shift ? 1 : 0) + (alt ? 2 : 0) + (ctrl ? 4 : 0)
        func csi(_ s: String) -> String { "\u{1b}[" + s }
        func letter(_ c: String) -> String {
            if mod > 1 { return csi("1;\(mod)\(c)") }
            return terminal.appCursorKeys ? "\u{1b}O" + c : csi(c)
        }
        func tilde(_ n: Int) -> String { mod > 1 ? csi("\(n);\(mod)~") : csi("\(n)~") }
        func function(_ c: String) -> String { mod > 1 ? csi("1;\(mod)\(c)") : "\u{1b}O" + c }

        var out: String?
        switch key {
        case Win.VK_UP: out = letter("A")
        case Win.VK_DOWN: out = letter("B")
        case Win.VK_RIGHT: out = letter("C")
        case Win.VK_LEFT: out = letter("D")
        case Win.VK_HOME: out = letter("H")
        case Win.VK_END: out = letter("F")
        case Win.VK_INSERT: out = tilde(2)
        case Win.VK_DELETE: out = tilde(3)
        case Win.VK_PRIOR: out = tilde(5)
        case Win.VK_NEXT: out = tilde(6)
        case Win.VK_BACK: out = alt ? "\u{1b}\u{7f}" : (ctrl ? "\u{08}" : "\u{7f}")
        case Win.VK_RETURN:
            // Shift+Enter: a new line instead of sending, in Claude Code (as on the Mac) and at a shell's prompt alike. Both
            // take a line feed (Ctrl+J) for it; a plain Enter sends. Full-screen programs get Enter as ever.
            if shift && !alt && !ctrl && !terminal.usingAlt {
                out = "\n"
            } else {
                out = alt ? "\u{1b}\r" : "\r"
            }
        case Win.VK_ESCAPE: out = "\u{1b}"
        case Win.VK_TAB:
            if ctrl { return false }
            out = shift ? csi("Z") : "\t"
        case Win.VK_SPACE:
            if ctrl { out = alt ? "\u{1b}\u{00}" : "\u{00}" }
        case Win.VK_F1...Win.VK_F12:
            let table = ["P", "Q", "R", "S", "15", "17", "18", "19", "20", "21", "23", "24"]
            let code = table[Int(key - Win.VK_F1)]
            out = key < Win.VK_F1 + 4 ? function(code) : tilde(Int(code)!)
        default: break
        }
        guard let out else { return false }
        input(Array(out.utf8))
        return true
    }

    /// A character from the keyboard or an input method, which arrives in UTF-16 units.
    func typed(_ unit: UInt16, meta: Bool) {
        if UTF16.isLeadSurrogate(unit) {
            pendingSurrogate = unit
            return
        }
        var units = [unit]
        if let lead = pendingSurrogate, UTF16.isTrailSurrogate(unit) { units = [lead, unit] }
        pendingSurrogate = nil
        // Anything that prints replaces a selection, space included. Control characters go through as usual.
        let prints = !meta && unit >= 0x20 && unit != 0x7F
        input((meta ? [0x1B] : []) + Array(String(decoding: units, as: UTF16.self).utf8), replacesSelection: prints)
    }

    /// Input from the person: shows the live screen again, as typing does in any terminal.
    private func input(_ bytes: [UInt8], replacesSelection: Bool = false) {
        scrollOffset = 0
        selectedStop = nil
        host?.restartBlink()
        invalidate()
        if afterSelectionDeleted != nil {
            // Keys typed while a selection is still going follow it, in order.
            afterSelectionDeleted?.append(bytes)
        } else if !replacesSelection || !replaceSelectedInput(with: bytes) {
            selection = nil
            write(bytes)
        }
    }

    private func write(_ bytes: [UInt8]) {
        let encoded = terminal.win32InputMode ? Win32Input.encode(bytes) : bytes
        // A big paste goes in pieces, so Windows 10's console host takes it all.
        if encoded.count > 512 { pty?.writePaced(encoded) } else { pty?.write(encoded) }
    }

    private func send(_ text: String) { pty?.write(Array(text.utf8)) }

    // MARK: - Mouse

    private func cell(at lParam: LPARAM) -> (col: Int, row: Int) {
        let m = canvas.metrics
        let x = Float(Int16(truncatingIfNeeded: lParam & 0xFFFF)) - canvas.contentX
        let y = Float(Int16(truncatingIfNeeded: (lParam >> 16) & 0xFFFF)) - canvas.contentY
        return (min(max(Int(x / m.cellWidth + 0.5), 0), terminal.cols), min(max(Int(y / m.cellHeight), 0), terminal.rows - 1))
    }

    private func report(button: Int, col: Int, row: Int, press: Bool, motion: Bool = false) {
        let col = min(col, terminal.cols - 1)
        var code = button + (motion ? 32 : 0)
        if isDown(Win.VK_SHIFT) { code += 4 }
        if isDown(Win.VK_MENU) { code += 8 }
        if isDown(Win.VK_CONTROL) { code += 16 }
        if terminal.mouseSGR {
            send("\u{1b}[<\(code);\(col + 1);\(row + 1)\(press ? "M" : "m")")
        } else {
            if !press { code = 3 + (code & ~3 & ~64) }
            pty?.write([0x1B, 0x5B, 0x4D, UInt8(min(255, 32 + code)), UInt8(min(255, 33 + col)), UInt8(min(255, 33 + row))])
        }
    }

    /// A text line's height, which a finger moves the terminal by.
    var lineHeight: Float { canvas.metrics.cellHeight }

    /// A finger dragged on the terminal (see `TouchScroll`): up for positive, by lines, or for a program reading the
    /// mouse, a wheel notch per 3 lines. `position` is in the window's client coordinates.
    func touchScroll(lines: Int, at position: LPARAM) {
        guard terminal.mouseMode != .none else { return scrollLines(lines, at: position) }
        if touchLines != 0 && (touchLines > 0) != (lines > 0) { touchLines = 0 }
        touchLines += lines
        let notches = touchLines / 3
        touchLines -= notches * 3
        if notches != 0 { scrollLines(notches, at: position) }
    }

    func mouse(_ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) {
        // Pasted images' thumbnails: hover rings one, a click shows it larger, a click on that opens it.
        let px = Float(Int16(truncatingIfNeeded: lParam & 0xFFFF)), py = Float(Int16(truncatingIfNeeded: (lParam >> 16) & 0xFFFF))
        // Claude's code boxes: a Copy button copies its box.
        let onCopy = copyButtons.first { $0.rect.contains(px, py) }?.box
        if message == Win.WM_MOUSEMOVE, !selecting, onCopy != hoverCopyButton { hoverCopyButton = onCopy; invalidate() }
        if message == Win.WM_LBUTTONDOWN, let onCopy { copyBox(onCopy); return }
        if message == Win.WM_MOUSEMOVE, !selecting, imageChips.hovered(atX: px, y: py) { invalidate() }
        if message == Win.WM_LBUTTONDOWN {
            let result = imageChips.click(atX: px, y: py)
            if result.changed { invalidate() }
            if result.used { return }
        }
        let (col, row) = cell(at: lParam)
        if terminal.mouseMode != .none && !isDown(Win.VK_SHIFT) {
            reportMouse(message, wParam, col: col, row: row)
            return
        }
        let abs = terminal.screenTopAbs - scrollOffset + row
        // Ctrl over a link underlines it, and Ctrl+click opens it.
        if message == Win.WM_MOUSEMOVE || message == Win.WM_LBUTTONDOWN {
            let found = isDown(Win.VK_CONTROL) && !selecting ? link(atLine: abs, col: col) : nil
            let shown = found.map { (abs, $0.start, $0.end) }
            if shown?.0 != hoveredLink?.line || shown?.1 != hoveredLink?.start || shown?.2 != hoveredLink?.end {
                hoveredLink = shown
                invalidate()
            }
            if message == Win.WM_LBUTTONDOWN, let found {
                host?.openLink(found.target, isURL: found.isURL)
                return
            }
        }
        switch message {
        case Win.WM_LBUTTONDOWN:
            selection = TerminalSelection(anchor: (abs, col), head: (abs, col))
            selecting = true
            SetCapture(hwnd)
        case Win.WM_LBUTTONDBLCLK:
            selection = wordSelection(line: abs, col: col)
            selecting = false
        case Win.WM_MOUSEMOVE:
            guard selecting else { return }
            selection?.head = (abs, col)
        case Win.WM_LBUTTONUP:
            guard selecting else { return }
            selecting = false
            ReleaseCapture()
            if let chosen = selection, !chosen.isEmpty, AppSettings.shared.copyOnSelect { setClipboard(selectedText(chosen)) }
            if selection?.isEmpty == true {
                selection = nil
                whenCursorSettled { [weak self] in self?.clicked(line: abs, col: col) }
            }
        case Win.WM_RBUTTONUP:
            // As in Windows consoles: right-click copies a selection, and pastes when there isn't one.
            if selection != nil {
                copySelection()
                selection = nil
            } else {
                paste()
            }
        default:
            return
        }
        invalidate()
    }

    private func reportMouse(_ message: UINT, _ wParam: WPARAM, col: Int, row: Int) {
        switch message {
        case Win.WM_LBUTTONDOWN, Win.WM_LBUTTONDBLCLK:
            SetCapture(hwnd)
            report(button: 0, col: col, row: row, press: true)
        case Win.WM_MBUTTONDOWN: report(button: 1, col: col, row: row, press: true)
        case Win.WM_RBUTTONDOWN: report(button: 2, col: col, row: row, press: true)
        case Win.WM_LBUTTONUP:
            ReleaseCapture()
            report(button: 0, col: col, row: row, press: false)
        case Win.WM_MBUTTONUP: report(button: 1, col: col, row: row, press: false)
        case Win.WM_RBUTTONUP: report(button: 2, col: col, row: row, press: false)
        case Win.WM_MOUSEMOVE:
            if let last = lastMouseCell, last == (col, row) { return }
            lastMouseCell = (col, row)
            let held = wParam & Win.MK_LBUTTON != 0 ? 0 : (wParam & Win.MK_MBUTTON != 0 ? 1 : (wParam & Win.MK_RBUTTON != 0 ? 2 : 3))
            guard terminal.mouseMode == .any || (terminal.mouseMode == .button && held != 3) else { return }
            report(button: held, col: col, row: row, press: true, motion: true)
        default: break
        }
    }

    func wheel(_ wParam: WPARAM, _ lParam: LPARAM) {
        let delta = Int(Int16(truncatingIfNeeded: (wParam >> 16) & 0xFFFF))
        guard delta != 0 else { return }
        // Turning back starts afresh, so a little left over one way doesn't swallow the first step the other.
        if wheelRemainder != 0 && (wheelRemainder > 0) != (delta > 0) { wheelRemainder = 0 }
        // In lines, at the speed set (3 a notch unless it's changed); a touchpad's small steps add up.
        wheelRemainder += Double(delta) / Double(Win.WHEEL_DELTA) * AppSettings.shared.scrollSpeed
        // A program reading the mouse gets wheel notches instead, one per 3 lines' worth.
        let unit: Double = terminal.mouseMode != .none ? 3 : 1
        let steps = Int(wheelRemainder / unit)
        guard steps != 0 else { return }
        wheelRemainder -= Double(steps) * unit
        // The wheel's position is in screen coordinates.
        var point = POINT(x: LONG(Int16(truncatingIfNeeded: lParam & 0xFFFF)), y: LONG(Int16(truncatingIfNeeded: (lParam >> 16) & 0xFFFF)))
        ScreenToClient(hwnd, &point)
        scrollLines(steps, at: LPARAM(point.x & 0xFFFF) | (LPARAM(point.y & 0xFFFF) << 16))
    }

    /// Scrolls up (positive) or down, from the wheel or a finger: the scrollback by lines; a program on the other screen
    /// by as many arrow keys; or, for a program reading the mouse, by as many wheel notches.
    private func scrollLines(_ amount: Int, at position: LPARAM) {
        let up = amount > 0
        if terminal.mouseMode != .none {
            let (col, row) = cell(at: position)
            for _ in 0..<abs(amount) { report(button: up ? 64 : 65, col: col, row: row, press: true) }
        } else if terminal.usingAlt {
            if terminal.altScroll {
                let key = terminal.appCursorKeys ? (up ? "\u{1b}OA" : "\u{1b}OB") : (up ? "\u{1b}[A" : "\u{1b}[B")
                send(String(repeating: key, count: abs(amount)))
            }
        } else {
            scroll(by: amount)
        }
    }

    /// Sends the shell to a folder, when it's waiting at its prompt. Quotes are doubled, the way PowerShell escapes them.
    func changeDirectory(to path: String) {
        if AnyPath.isUnix(path) {
            guard canChangeRemoteFolder else { _ = MessageBeep(UINT(bitPattern: -1)); return }
            selection = nil
            // Ctrl+U first clears whatever's half typed at the remote prompt.
            write(Array(("\u{15}cd -- " + RemoteConnection.quote(path) + "\r").utf8))
            nextShellProbe = Date().addingTimeInterval(0.4)
            return
        }
        guard atPrompt else { return }
        selection = nil
        write(Array("cd -LiteralPath '\(path.replacingOccurrences(of: "'", with: "''"))'\r".utf8))
    }

    /// Types a command at the prompt and runs it: over ssh whenever the session's at one, as far as can be told (Ctrl+U
    /// clears what's half typed there first), and here when the shell is. False if it can't.
    @discardableResult
    func typeCommand(_ command: String) -> Bool {
        if sshArguments != nil {
            guard canChangeRemoteFolder else { return false }
            write(Array(("\u{15}" + command + "\r").utf8))
            return true
        }
        guard atPrompt else { return false }
        selection = nil
        write(Array((command + "\r").utf8))
        return true
    }

    // MARK: - Links

    /// A link at a cell: a program's own (OSC 8), a web address, or a file on this PC that the text names. Where it is
    /// on that line.
    func link(atLine line: Int, col: Int) -> (target: String, isURL: Bool, start: Int, end: Int)? {
        guard let here = terminal.line(abs: line), col < here.cells.count else { return nil }
        if let url = here.links?[col] {
            var a = col, b = col
            while a > 0, here.links?[a - 1] == url { a -= 1 }
            while b + 1 < here.cells.count, here.links?[b + 1] == url { b += 1 }
            return (url, true, a, b)
        }
        // The whole of a line the screen wrapped, and the cell each UTF-16 unit of it came from.
        var first = line, last = line
        while first > terminal.firstAbs, terminal.line(abs: first - 1)?.wrapped == true { first -= 1 }
        while last < terminal.lastAbs, terminal.line(abs: last)?.wrapped == true { last += 1 }
        var text = "", map: [(line: Int, col: Int)] = []
        for a in first...last {
            guard let l = terminal.line(abs: a) else { continue }
            let n = l.wrapped ? l.cells.count : l.trimmedLength
            for c in 0..<n where l.cells[c].width != 0 {
                let ch = l.cells[c].ch == 0 ? 32 : l.cells[c].ch
                guard let scalar = Unicode.Scalar(ch) else { continue }
                for _ in String(Character(scalar)).utf16 { map.append((a, c)) }
                text.unicodeScalars.append(scalar)
            }
        }
        guard let at = map.firstIndex(where: { $0.line == line && $0.col == col }) else { return nil }
        func span(_ r: NSRange) -> (Int, Int)? {
            guard r.location <= at, at < r.location + r.length else { return nil }
            let cells = map[r.location..<(r.location + r.length)].filter { $0.line == line }.map(\.col)
            return cells.min().flatMap { a in cells.max().map { (a, $0) } }
        }
        for (r, url) in TextLinks.urls(in: text) {
            if let (a, b) = span(r) { return (url.absoluteString, true, a, b) }
        }
        // Files: only this PC's, which can be opened from here.
        guard sshArguments == nil, let cwd = terminal.cwd else { return nil }
        let ns = NSString(string: text)
        var candidates: [(NSRange, String)] = TextLinks.mentions(in: text).map { ($0.range, $0.path) }
        if let re = Self.windowsPath {
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) { candidates.insert((m.range(at: 1), ns.substring(with: m.range(at: 1))), at: 0) }
        }
        for (r, raw) in candidates {
            guard let (a, b) = span(r) else { continue }
            let path = raw.replacingOccurrences(of: "/", with: "\\")
            let full = path.dropFirst().hasPrefix(":") ? path : WindowsPath.join(cwd, path.hasPrefix(".\\") ? String(path.dropFirst(2)) : path)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue { return (full, false, a, b) }
        }
        return nil
    }

    /// Windows paths: from a drive (C:\a\b.txt), or relative with backslashes (src\a.c), and a line number after.
    private static let windowsPath = try? NSRegularExpression(pattern: #"((?:[A-Za-z]:\\|\.\\)?(?:[\w.~@+-]+\\)+[\w.~@+-]+|[A-Za-z]:\\[\w.~@+-]+)(?::\d+)?"#)

    func scrollToTop() {
        scrollOffset = terminal.usingAlt ? 0 : terminal.scrollback.count
        invalidate()
    }

    func scrollToBottom() {
        scrollOffset = 0
        invalidate()
    }

    private func scroll(by lines: Int) {
        scrollOffset = min(max(scrollOffset + lines, 0), terminal.scrollback.count)
        invalidate()
    }

    // MARK: - Command blocks

    /// Where Ctrl+Up and Ctrl+Down stop, as the Mac's Command-Up and Down do: finished commands, and each prompt of an agent
    /// session (Claude Code) in place of its whole block. A block is known by its id, as its lines move when the screen
    /// reflows; a prompt by its line.
    enum BlockStop: Equatable {
        case block(id: Int, line: Int)
        case turn(line: Int)
        var line: Int {
            switch self {
            case .block(_, let line), .turn(let line): return line
            }
        }
    }

    /// The command or prompt picked with Ctrl+Up and Down, drawn outlined.
    private(set) var selectedStop: BlockStop?

    func blockStops() -> [BlockStop] {
        guard !terminal.usingAlt else { return [] }
        var out: [BlockStop] = []
        for b in terminal.blocks where b.state != .prompt {
            let turns = terminal.agentTurns(in: b)
            if !turns.isEmpty {
                out += turns.map { .turn(line: $0.promptLine) }
            } else if b.state == .finished {
                out.append(.block(id: b.id, line: b.promptLine))
            }
        }
        return out
    }

    private var selectedBlock: Block? {
        guard case .block(let id, _)? = selectedStop else { return nil }
        return terminal.blocks.first { $0.id == id }
    }

    private var selectedTurn: AgentTurn? {
        guard case .turn(let line)? = selectedStop else { return nil }
        return terminal.agentTurn(at: line)
    }

    private func currentStopIndex(_ list: [BlockStop]) -> Int? {
        switch selectedStop {
        case .block(let id, _)?: return list.firstIndex { if case .block(let other, _) = $0 { return other == id }; return false }
        case .turn(let line)?: return list.firstIndex { $0 == .turn(line: line) }
        case nil: return nil
        }
    }

    /// Ctrl+Up: the command or prompt before the one picked, or the last one.
    func selectPreviousStop() {
        let list = blockStops()
        guard !list.isEmpty else { return }
        select(list[currentStopIndex(list).map { max($0 - 1, 0) } ?? list.count - 1])
    }

    /// Ctrl+Down: the one after, or past the last, nothing picked and the live screen.
    func selectNextStop() {
        let list = blockStops()
        if let i = currentStopIndex(list), i + 1 < list.count {
            select(list[i + 1])
        } else {
            selectedStop = nil
            scrollOffset = 0
            invalidate()
        }
    }

    func select(_ stop: BlockStop) {
        selectedStop = stop
        selection = nil
        reveal(line: stop.line)
        invalidate()
    }

    /// Scrolls so a line shows, a row below the top, unless it's on screen already.
    private func reveal(line a: Int) {
        let top = terminal.screenTopAbs - scrollOffset
        guard a < top || a >= top + terminal.rows else { return }
        scrollOffset = min(max(terminal.screenTopAbs - a + 1, 0), terminal.scrollback.count)
    }

    /// The picked command or prompt, or else the last command that finished.
    private var targetBlock: Block? { selectedBlock ?? terminal.blocks.last { $0.state == .finished } }

    private func text(lines from: Int, _ to: Int) -> String {
        guard to >= from else { return "" }
        let chosen = TerminalSelection(anchor: (from, 0), head: (to, terminal.cols))
        return chosen.text(in: terminal).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
    }

    /// What a command printed, or what Claude said to a prompt.
    private func outputText(_ b: Block) -> String {
        guard let o = b.outputLine, let e = b.endLine, e >= o else { return "" }
        return text(lines: o, e)
    }

    private func responseText(_ t: AgentTurn) -> String { t.hasResponse ? text(lines: t.promptEnd + 1, t.end) : "" }

    /// Ctrl+Shift+C with nothing selected, as the Mac's Shift-Command-C: the command, or the prompt. False if there's none.
    @discardableResult
    func copyStopCommand() -> Bool {
        if let t = selectedTurn {
            setClipboard(terminal.agentPromptText(t))
            return true
        }
        guard let b = targetBlock, !b.command.isEmpty else { return false }
        setClipboard(b.command)
        return true
    }

    /// Ctrl+Alt+C, as the Mac's Option-Command-C: the command and what it printed, or the prompt and Claude's reply.
    @discardableResult
    func copyStopWithOutput() -> Bool {
        if let t = selectedTurn {
            let reply = responseText(t)
            setClipboard(terminal.agentPromptText(t) + (reply.isEmpty ? "" : "\n\n" + reply))
            return true
        }
        guard let b = targetBlock else { return false }
        let out = outputText(b)
        setClipboard("$ \(b.command)" + (out.isEmpty ? "" : "\n" + out))
        return true
    }

    /// Ctrl+Alt+R, as the Mac's Option-Command-R: runs the picked (or last) command again, at a prompt.
    func rerunStop() {
        guard atPrompt, let b = targetBlock, !b.command.isEmpty else { return }
        selectedStop = nil
        input(Array((b.command.replacingOccurrences(of: "\n", with: "\r") + "\r").utf8))
    }

    /// The picked block or prompt, outlined in the accent color over its lines, as on the Mac.
    private func drawSelectedStop() {
        guard let stop = selectedStop, !terminal.usingAlt else { return }
        let first: Int, last: Int
        switch stop {
        case .block:
            guard let b = selectedBlock else { return }
            (first, last) = (b.promptLine, b.lastLine(cursorAbs: terminal.cursorAbs))
        case .turn:
            guard let t = selectedTurn else { return }
            (first, last) = (t.promptLine, t.end)
        }
        let top = terminal.screenTopAbs - scrollOffset
        let a = max(first - top, 0), z = min(last - top, terminal.rows - 1)
        guard a <= z else { return }
        let m = canvas.metrics, s = Float(GetDpiForWindow(hwnd)) / 96
        let x = canvas.contentX - 4 * s, y = canvas.contentY + Float(a) * m.cellHeight - 2 * s
        let w = Float(terminal.cols) * m.cellWidth + 8 * s, h = Float(z - a + 1) * m.cellHeight + 4 * s
        sol_canvas_fill_rounded(canvas.raw, x, y, w, h, 6 * s, TerminalPalette.accent, 0.09)
        sol_canvas_stroke_rounded(canvas.raw, x + 0.5, y + 0.5, w - 1, h - 1, 6 * s, TerminalPalette.accent, 0.85, max(1, s.rounded()))
        // A prompt's place among its session's, "Prompt 3 of 7", at the right of its first line, as on the Mac.
        if case .turn = stop, let t = selectedTurn, first - top == a, let b = terminal.blockContaining(t.promptLine) {
            let text = "Prompt \(t.index) of \(terminal.agentTurns(in: b).count)", units = Array(text.utf16)
            let pixels = max(10 * s, m.cellHeight * 0.62)
            let tw = sol_canvas_measure_label(canvas.raw, units, Int32(units.count), pixels, 1)
            let ph = (pixels * 1.45).rounded(), pw = (tw + 14 * s).rounded()
            let px = (x + w - 6 * s - pw).rounded(), py = (canvas.contentY + Float(a) * m.cellHeight + (m.cellHeight - ph) / 2).rounded()
            sol_canvas_fill_rounded(canvas.raw, px, py, pw, ph, ph / 2, TerminalPalette.background, 0.85)
            sol_canvas_fill_rounded(canvas.raw, px, py, pw, ph, ph / 2, TerminalPalette.accent, 0.14)
            sol_canvas_draw_label(canvas.raw, px + 7 * s, py, tw + 2, ph, units, Int32(units.count), pixels, 1, TerminalPalette.accent, 1)
        }
    }

    /// The prompts sent to agents in this tab, oldest first: each one's text, its number and how long the reply is.
    func sentPrompts() -> [(stop: BlockStop, text: String, detail: String)] {
        var out: [(BlockStop, String, String)] = []
        for b in terminal.blocks {
            for t in terminal.agentTurns(in: b) {
                let text = terminal.agentPromptText(t)
                out.append((.turn(line: t.promptLine), text, "Prompt \(t.index) · " + (t.hasResponse ? "\(t.responseLineCount) lines" : "no response yet")))
            }
        }
        return out
    }

    /// The commands run in this tab that have finished, oldest first.
    func finishedCommands() -> [(stop: BlockStop, command: String, failed: Bool)] {
        terminal.blocks.filter { $0.state == .finished && !$0.command.isEmpty }.map { (.block(id: $0.id, line: $0.promptLine), $0.command, $0.failed) }
    }

    // MARK: - Click to place the cursor

    /// Runs `work` once the screen has settled: the program has finished redrawing (Claude Code hides the cursor and
    /// parks it below its interface mid-frame) and has echoed arrow keys sent for an earlier click. Reading the cursor
    /// before that is what makes clicks miss. Waits a short while at most; a newer request replaces an older one.
    private func whenCursorSettled(timeout: TimeInterval = 0.3, _ work: @escaping () -> Void) {
        pendingClick = work
        pendingClickDeadline = Date().addingTimeInterval(timeout)
        runPendingClick()
        if pendingClick != nil { _ = SetTimer(hwnd, Self.clickTimer, 20, nil) }
    }

    func runPendingClick() {
        guard let work = pendingClick else { return }
        let settled = terminal.usingAlt || terminal.mouseMode != .none || (terminal.cursorVisible && !awaitingCursorEcho)
        guard settled || Date() >= pendingClickDeadline else { return }
        pendingClick = nil
        KillTimer(hwnd, Self.clickTimer)
        awaitingCursorEcho = false
        work()
    }

    private func sendArrows(_ count: Int, back: String, forward: String) {
        guard count != 0 else { return }
        let key = (terminal.appCursorKeys ? "\u{1b}O" : "\u{1b}[") + (count < 0 ? back : forward)
        send(String(repeating: key, count: abs(count)))
        awaitingCursorEcho = true
    }

    /// A plain click, as on the Mac: in the line being typed it moves the cursor there; otherwise it picks the prompt or
    /// finished command under it (outlined, as Ctrl+Up and Down pick them), or puts that one down again if it's picked
    /// already; anywhere else, nothing stays picked.
    private func clicked(line: Int, col: Int) {
        if placeCursor(line: line, col: col) {
            if selectedStop != nil { selectedStop = nil; invalidate() }
            return
        }
        guard !terminal.usingAlt else { return }
        if let t = terminal.agentTurn(containing: line) {
            let stop = BlockStop.turn(line: t.promptLine)
            selectedStop = selectedStop == stop ? nil : stop
        } else if let b = terminal.blockContaining(line), b.state == .finished {
            if case .block(let id, _)? = selectedStop, id == b.id { selectedStop = nil } else { selectedStop = .block(id: b.id, line: b.promptLine) }
        } else {
            selectedStop = nil
        }
        invalidate()
    }

    /// Moves the cursor to a click in the line being typed. False if the click wasn't there.
    @discardableResult
    private func placeCursor(line: Int, col: Int) -> Bool {
        guard !terminal.usingAlt, terminal.mouseMode == .none, let block = terminal.currentBlock else { return false }
        let col = min(col, terminal.cols - 1)
        if block.state == .running {
            guard let rows = terminal.agentInputRows(block), rows.contains(line), rows.contains(terminal.cursorAbs) else { return false }
            placeAgentCursor(row: line - rows.lowerBound, col: col, sentVertical: false)
            return true
        } else if let arrows = terminal.shellCursorArrows(block, line: line, col: col) {
            sendArrows(arrows, back: "D", forward: "C")
            return true
        }
        return false
    }

    /// Claude Code word-wraps its input box itself, so cells don't map linearly to text. Up or down to the row first
    /// (it moves by visual row), wait for the redraw, then fix the column.
    private func placeAgentCursor(row: Int, col: Int, sentVertical: Bool, giveUpAt: Date = .distantFuture, then: (() -> Void)? = nil) {
        guard let block = terminal.currentBlock, block.state == .running else { return }
        func again(_ deadline: Date) {
            awaitingCursorEcho = true
            whenCursorSettled { [weak self] in self?.placeAgentCursor(row: row, col: col, sentVertical: true, giveUpAt: deadline, then: then) }
        }
        guard let rows = terminal.agentInputRows(block), rows.contains(terminal.cursorAbs) else {
            // Caught partway through a redraw after our arrows, with the box not all there: look again in a moment.
            if sentVertical, Date() < giveUpAt { again(giveUpAt) }
            return
        }
        let target = rows.lowerBound + row
        guard rows.contains(target) else { return }
        if terminal.cursorAbs == target {
            sendArrows(terminal.agentCursorArrows(toCol: col), back: "D", forward: "C")
            then?()
        } else if sentVertical {
            // An unrelated redraw (the spinner, say) can land before the echo of our arrows: wait for the next one.
            if Date() < giveUpAt { again(giveUpAt) }
        } else {
            sendArrows(target - terminal.cursorAbs, back: "A", forward: "B")
            again(Date().addingTimeInterval(2))
        }
    }

    // MARK: - Replacing selected input

    /// Whether the cursor is in Claude Code's input box.
    private var agentInputActive: Bool {
        guard !terminal.usingAlt, let block = terminal.currentBlock, block.state == .running,
              let rows = terminal.agentInputRows(block) else { return false }
        return rows.contains(terminal.cursorAbs)
    }

    /// Replaces the selection, when it's in the line being typed, with `bytes` (nothing: just takes it out), as a text
    /// box does. False when it isn't, and nothing has happened.
    @discardableResult
    private func replaceSelectedInput(with bytes: [UInt8]) -> Bool {
        guard let chosen = selection, !chosen.isEmpty, !terminal.usingAlt, terminal.mouseMode == .none,
              let block = terminal.currentBlock else { return false }
        let (start, end) = chosen.trimmed(cols: terminal.cols)
        if let picked = terminal.shellSelection(block, start: start, end: end) {
            // Selecting with PSReadLine's own Shift+Left, rather than backspacing, makes it one step for Ctrl+Z.
            sendArrows(picked.to - picked.cursor, back: "D", forward: "C")
            send(String(repeating: "\u{1b}[1;2D", count: picked.to - picked.from))
            write(bytes.isEmpty ? [0x7F] : bytes)
        } else if !replaceAgentSelection(block, start: start, end: end, with: bytes) {
            return false
        }
        selection = nil
        invalidate()
        return true
    }

    /// Any number of rows of Claude Code's input box, the selection clipped to the box's text. Keys are worked through
    /// in order, so within a row arrows, backspaces and the replacement could all go at once. Across rows it re-wraps
    /// as characters go, and the breaks between rows may or may not be characters, so those are counted and topped up
    /// after it's redrawn. Anything typed meanwhile waits in `afterSelectionDeleted`.
    private func replaceAgentSelection(_ block: Block, start: (line: Int, col: Int), end: (line: Int, col: Int), with bytes: [UInt8]) -> Bool {
        guard block.state == .running, let rows = terminal.agentInputRows(block), rows.contains(terminal.cursorAbs),
              end.line >= rows.lowerBound, start.line <= rows.upperBound else { return false }
        let first = max(start.line, rows.lowerBound), last = min(end.line, rows.upperBound)
        let startCol = first == start.line ? max(2, min(start.col, terminal.agentTextEnd(first))) : 2
        let endCol = last == end.line ? min(end.col, terminal.agentTextEnd(last)) : terminal.agentTextEnd(last)
        guard last > first || endCol > startCol else { return false }
        let targetOffset = terminal.agentInputOffset(rows, line: first, col: startCol)
        let count = (first...last).reduce(0) { n, a in
            n + terminal.charCount(a, from: a == first ? startCol : 2, to: a == last ? endCol : terminal.agentTextEnd(a))
        }
        // In the queue from the start, so it goes even if the cursor can't be placed.
        afterSelectionDeleted = bytes.isEmpty ? [] : [bytes]
        selectionDeleteDeadline = Date().addingTimeInterval(6)
        placeAgentCursor(row: last - rows.lowerBound, col: endCol, sentVertical: false) { [weak self] in
            guard let self else { return }
            self.send(String(repeating: "\u{7f}", count: count))
            if first == last {
                self.endDeletingSelection()
            } else {
                // Only the breaks between rows can be left over, and only one each.
                self.backspaceAgentInput(toOffset: targetOffset, atMost: last - first)
            }
        }
        return true
    }

    /// Tops up what the first backspaces left: from the cursor back to `target` characters into the input, measured
    /// after each redraw, since it re-wraps as characters go (text before the target never moves). Measuring before
    /// the program has answered would count everything again, so it waits for the answer, and `atMost` caps the total
    /// so that a bad reading can't eat into the text before the selection.
    private func backspaceAgentInput(toOffset target: Int, atMost: Int) {
        whenOutputQuiet { [weak self] answered in
            guard let self, self.afterSelectionDeleted != nil else { return }
            guard answered, atMost > 0, let block = self.terminal.currentBlock, let rows = self.terminal.agentInputRows(block),
                  rows.contains(self.terminal.cursorAbs) else { return self.endDeletingSelection() }
            let left = self.terminal.agentInputOffset(rows, line: self.terminal.cursorAbs, col: self.terminal.cursorX) - target
            guard left > 0 else { return self.endDeletingSelection() }
            let count = min(left, atMost)
            self.send(String(repeating: "\u{7f}", count: count))
            self.backspaceAgentInput(toOffset: target, atMost: atMost - count)
        }
    }

    func endDeletingSelection() {
        guard let waiting = afterSelectionDeleted else { return }
        afterSelectionDeleted = nil
        selectionDeleteDeadline = nil
        waiting.forEach(write)
    }

    /// Runs `work` once the program has answered and stopped drawing for a moment, since it may take several frames to
    /// work through a burst of keys. `work` gets false if nothing arrived within two seconds.
    private func whenOutputQuiet(_ work: @escaping (Bool) -> Void) {
        quietWork = work
        quietStart = Date()
        _ = SetTimer(hwnd, Self.quietTimer, 20, nil)
    }

    func runQuietWork() {
        guard let work = quietWork else { return }
        let answered = lastOutputAt > quietStart && Date().timeIntervalSince(lastOutputAt) >= 0.15 && terminal.cursorVisible
        let late = Date().timeIntervalSince(quietStart) > 2
        guard answered || late else { return }
        quietWork = nil
        KillTimer(hwnd, Self.quietTimer)
        work(answered)
    }

    private func wordSelection(line: Int, col: Int) -> TerminalSelection? {
        guard let l = terminal.line(abs: line) else { return nil }
        func isWord(_ x: Int) -> Bool {
            let ch = l.cell(x).ch
            return ch != 0 && ch != 32
        }
        let col = min(col, terminal.cols - 1)
        guard isWord(col) else { return nil }
        var start = col, end = col
        while start > 0, isWord(start - 1) { start -= 1 }
        while end + 1 < terminal.cols, isWord(end + 1) { end += 1 }
        return TerminalSelection(anchor: (line, start), head: (line, end + 1))
    }

    // MARK: - Clipboard

    private func copySelection() {
        guard let selection, !selection.isEmpty else { return }
        // It stays selected, as in a text box: what's typed or pasted next can replace it.
        setClipboard(selectedText(selection))
    }

    private func cutSelection() {
        guard let selection, !selection.isEmpty else { return }
        let text = selection.text(in: terminal)
        if replaceSelectedInput(with: []) { setClipboard(text) }
    }

    /// How many times the clipboard was found busy, for the window test to report.
    private(set) static var clipboardBusyCount = 0

    /// Only one program can have the clipboard open at a time, and others look at it the moment it changes: clipboard
    /// history, cloud clipboards, password managers. So a failure is usually only a moment's wait.
    private func openClipboard() -> Bool {
        for attempt in 0..<20 {
            if OpenClipboard(hwnd) { return true }
            if attempt == 0 { Self.clipboardBusyCount += 1 }
            Sleep(10)
        }
        return false
    }

    func setClipboard(_ text: String) { setClipboard(text, html: nil) }

    /// Text, and with `html` that too, in Windows' "HTML Format" (what Word, Excel, Outlook and Teams paste from).
    func setClipboard(_ text: String, html: String?) {
        let units = wide(text)
        let bytes = units.count * MemoryLayout<UInt16>.size
        guard openClipboard() else { return }
        defer { CloseClipboard() }
        EmptyClipboard()
        guard let memory = GlobalAlloc(Win.GMEM_MOVEABLE, SIZE_T(bytes)), let pointer = GlobalLock(memory) else { return }
        units.withUnsafeBytes { pointer.copyMemory(from: $0.baseAddress!, byteCount: bytes) }
        GlobalUnlock(memory)
        SetClipboardData(Win.CF_UNICODETEXT, memory)
        guard let html else { return }
        let payload = Array(Self.clipboardHTML(html).utf8) + [0]
        let format = wide("HTML Format").withUnsafeBufferPointer { RegisterClipboardFormatW($0.baseAddress) }
        guard format != 0, let block = GlobalAlloc(Win.GMEM_MOVEABLE, SIZE_T(payload.count)), let p = GlobalLock(block) else { return }
        payload.withUnsafeBytes { p.copyMemory(from: $0.baseAddress!, byteCount: payload.count) }
        GlobalUnlock(block)
        SetClipboardData(format, block)
    }

    /// HTML wrapped as Windows' clipboard wants it: a header giving where the document and the fragment start and end,
    /// in bytes of UTF-8.
    static func clipboardHTML(_ fragment: String) -> String {
        let before = "<html><body><!--StartFragment-->", after = "<!--EndFragment--></body></html>"
        let header = "Version:0.9\r\nStartHTML:0000000000\r\nEndHTML:0000000000\r\nStartFragment:0000000000\r\nEndFragment:0000000000\r\n"
        let startHTML = header.utf8.count, startFragment = startHTML + before.utf8.count
        let endFragment = startFragment + fragment.utf8.count, endHTML = endFragment + after.utf8.count
        func n(_ v: Int) -> String { String(format: "%010d", v) }
        return "Version:0.9\r\nStartHTML:\(n(startHTML))\r\nEndHTML:\(n(endHTML))\r\nStartFragment:\(n(startFragment))\r\nEndFragment:\(n(endFragment))\r\n"
            + before + fragment + after
    }

    func clipboardText() -> String? {
        guard openClipboard() else { return nil }
        defer { CloseClipboard() }
        guard let memory = GetClipboardData(Win.CF_UNICODETEXT), let pointer = GlobalLock(memory) else { return nil }
        defer { GlobalUnlock(memory) }
        return String(decodingCString: pointer.assumingMemoryBound(to: UInt16.self), as: UTF16.self)
    }

    func paste() {
        guard let text = clipboardText(), !text.isEmpty else { return }
        pasteText(text)
    }

    /// Text as a paste: bracketed when the program asked, so it isn't run as it arrives.
    func pasteText(_ raw: String) {
        var text = raw
        text = text.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
        // Pasted text could otherwise end the bracketing early, and run what follows.
        text = text.replacingOccurrences(of: "\u{1b}", with: "")
        // Coding agents always take a bracketed paste (Claude Code shows "[Pasted text +N lines]" for one), but Windows 10's
        // console host doesn't pass on their asking for it, so for them it's bracketed regardless.
        let bracketed = terminal.bracketedPaste || agent != nil
        input(Array((bracketed ? "\u{1b}[200~" + text + "\u{1b}[201~" : text).utf8), replacesSelection: true)
    }

    // MARK: - For tests

    func type(_ text: String) {
        for unit in text.utf16 { PostMessageW(hwnd, Win.WM_CHAR, WPARAM(unit), 0) }
    }

    /// A plain click on a cell of the screen.
    func click(col: Int, row: Int) {
        let m = canvas.metrics
        let x = Int(canvas.contentX + (Float(col) + 0.1) * m.cellWidth), y = Int(canvas.contentY + (Float(row) + 0.5) * m.cellHeight)
        let position = LPARAM(x & 0xFFFF) | (LPARAM(y & 0xFFFF) << 16)
        _ = SendMessageW(hwnd, Win.WM_LBUTTONDOWN, 1, position)
        _ = SendMessageW(hwnd, Win.WM_LBUTTONUP, 0, position)
    }

    /// Drags the mouse from one cell to another, selecting what's between.
    func drag(fromCol: Int, fromRow: Int, toCol: Int, toRow: Int) {
        let m = canvas.metrics
        func position(_ col: Int, _ row: Int) -> LPARAM {
            let x = Int(canvas.contentX + (Float(col) + 0.1) * m.cellWidth), y = Int(canvas.contentY + (Float(row) + 0.5) * m.cellHeight)
            return LPARAM(x & 0xFFFF) | (LPARAM(y & 0xFFFF) << 16)
        }
        _ = SendMessageW(hwnd, Win.WM_LBUTTONDOWN, Win.MK_LBUTTON, position(fromCol, fromRow))
        _ = SendMessageW(hwnd, Win.WM_MOUSEMOVE, Win.MK_LBUTTON, position(toCol, toRow))
        _ = SendMessageW(hwnd, Win.WM_LBUTTONUP, 0, position(toCol, toRow))
    }

    func drag(fromCol: Int, toCol: Int, row: Int) { drag(fromCol: fromCol, fromRow: row, toCol: toCol, toRow: row) }

    func pressEscape() { PostMessageW(hwnd, Win.WM_KEYDOWN, WPARAM(Win.VK_ESCAPE), 0) }

    var hasSelection: Bool { selection != nil }

    func pressBackspace() { PostMessageW(hwnd, Win.WM_KEYDOWN, WPARAM(Win.VK_BACK), 0) }

    var shellProcessID: DWORD { pty?.processID ?? 0 }

    func pressEnter() { PostMessageW(hwnd, Win.WM_KEYDOWN, WPARAM(Win.VK_RETURN), 0) }

    var isSettlingResize: Bool { lastResize != nil }

    /// The row the cursor is on, as far as what's on screen goes.
    var cursorRowText: String { terminal.screen[terminal.cursorY].text() }

    /// The text as it was written, with lines the window wrapped joined up again.
    var logicalText: String {
        var out = ""
        for line in terminal.scrollback.toArray() + terminal.screen {
            out += line.text(trim: !line.wrapped)
            if !line.wrapped { out += "\n" }
        }
        return out
    }

    var visibleText: String {
        (terminal.scrollback.toArray().map { $0.text() } + terminal.screen.map { $0.text() }).joined(separator: "\n")
    }

    // MARK: - TerminalDelegate

    func terminalSend(_ bytes: [UInt8]) { pty?.write(bytes) }

    func terminalTitleChanged(_ t: Terminal) { host?.paneDetailsChanged(self) }

    func terminalCwdChanged(_ t: Terminal) {
        sshChanged()
        host?.paneDetailsChanged(self)
    }

    func terminalBell(_ t: Terminal) {
        if !(host?.isFocused ?? false) { FlashWindow(hwnd, true) }
        if AppSettings.shared.audibleBell { MessageBeep(0) }
    }

    func terminalClipboardWrite(_ t: Terminal, text: String) { setClipboard(text) }
    func terminalScreenSwitched(_ t: Terminal) { scrollOffset = 0 }
    func terminalSyncEnded(_ t: Terminal) { invalidate() }

    func terminalColor(_ t: Terminal, code: Int) -> (UInt8, UInt8, UInt8) {
        switch code {
        case 10: return TerminalPalette.tuple(TerminalPalette.foreground)
        case 11: return TerminalPalette.tuple(TerminalPalette.background)
        case 12: return TerminalPalette.tuple(TerminalPalette.cursor)
        default: return TerminalPalette.tuple(TerminalPalette.indexed(min(max(code - 256, 0), 255)))
        }
    }

    func terminalPixelSize(_ t: Terminal) -> (width: Int, height: Int) {
        let m = canvas.metrics
        return (Int(Float(t.cols) * m.cellWidth), Int(Float(t.rows) * m.cellHeight))
    }
}
