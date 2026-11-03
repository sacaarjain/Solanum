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

    var group: TabGroup?
    /// A name given to the tab, in place of the one it would have.
    var customTitle: String?
    /// The git repository its folder is in, for the status bar; what git's doing for it there ("Pulling…").
    var git: GitInfo?
    var gitBusy: String?
    var gitKey: String?
    var gitCheckedAt = Date.distantPast
    /// Git Changes or Git Graph, over the terminal while it's open.
    var panel: ColumnPanel?
    /// Where a link under the pointer is, while Ctrl's held over it: drawn underlined.
    var hoveredLink: (line: Int, start: Int, end: Int)?
    /// Where the sidebar was while this tab was showing. Nil until it has been.
    var sidebarPlace: SidebarPlace?
    private var pendingSurrogate: UInt16?
    private var lastMouseCell: (Int, Int)?
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
        // In an ssh session, the server it's connected to.
        if let sshHost { return sshHost }
        return WindowText.tabTitle(title: terminal.title, folder: terminal.cwd, home: ProcessInfo.processInfo.environment["USERPROFILE"])
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
        lost = (sshHost ?? "the ssh host", "ssh " + target.map(Self.powerShellWord).joined(separator: " "), terminal.currentBlock)
        if let password = rememberedPassword { reconnectPassword = password }
        if !(host?.isFocused ?? false) { FlashWindow(hwnd, true) }
        invalidate()
    }

    func terminalBlockFinished(_ t: Terminal, block: Block) {
        // A commit, a checkout, an edit: git's state may have changed.
        host?.paneCommandFinished(self)
        // Something else run here since: the bar's question has gone away.
        if let lost, block !== lost.block, terminal.sshControlPath == nil, !reconnecting, !block.command.isEmpty { clearLost() }
    }

    private func clearLost() {
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
    func tick() {
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
        renderer.focused = focused
        renderer.cursorShown = cursorShown
        renderer.cursorStyle = style
        renderer.drawContents()
        // The link under the pointer, while Ctrl's held.
        if let h = hoveredLink {
            let row = h.line - (terminal.screenTopAbs - scrollOffset), m = canvas.metrics
            if row >= 0 && row < terminal.rows {
                sol_canvas_fill_rect(canvas.raw, canvas.contentX + Float(h.start) * m.cellWidth, canvas.contentY + Float(row + 1) * m.cellHeight - max(m.lineThickness, 1),
                                     Float(h.end - h.start + 1) * m.cellWidth, max(m.lineThickness, 1), TerminalPalette.accent, 1)
            }
        }
        drawLostBar()
        drawQuestion()
    }

    /// What's drawn over the terminal (the lost connection bar, ssh's question), on another canvas: for snapshots.
    func drawOverlays(on target: Canvas) {
        drawTarget = target
        defer { drawTarget = nil }
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

    func keyDown(_ key: Int32, shift: Bool, ctrl: Bool, alt: Bool) -> Bool {
        if key == Win.VK_F4 && alt { return false }

        // Plain Ctrl+C, V and X act on the clipboard where that can't take anything from the program.
        if ctrl && !shift && !alt {
            switch key {
            case 0x43:
                // With nothing selected it's the program's interrupt. Copying clears the selection, so a second one is too.
                guard let chosen = selection, !chosen.isEmpty else { break }
                copySelection()
                selection = nil
                invalidate()
                return true
            case 0x56:
                // Full-screen programs have their own use for it (vim's block selection, nano's page down), and Claude
                // Code reads an image off the clipboard itself. Ctrl+Shift+V still pastes in both.
                if terminal.usingAlt || (agentInputActive && IsClipboardFormatAvailable(Win.CF_DIB)) { break }
                paste()
                return true
            case 0x58:
                if let chosen = selection, !chosen.isEmpty, replaceSelectedInput(with: []) {
                    setClipboard(chosen.text(in: terminal))
                    return true
                }
            default: break
            }
        }

        // Ctrl+Shift is what's left for the app: on its own, Ctrl+C and Ctrl+V belong to the shell.
        if ctrl && shift && !alt {
            switch key {
            case 0x43:
                copySelection()
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
        case Win.VK_RETURN: out = alt ? "\u{1b}\r" : "\r"
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
        pty?.write(terminal.win32InputMode ? Win32Input.encode(bytes) : bytes)
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

    func mouse(_ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) {
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
            if let chosen = selection, !chosen.isEmpty, AppSettings.shared.copyOnSelect { setClipboard(chosen.text(in: terminal)) }
            if selection?.isEmpty == true {
                selection = nil
                whenCursorSettled { [weak self] in self?.placeCursor(line: abs, col: col) }
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
        let up = delta > 0
        let notches = max(abs(delta) / Win.WHEEL_DELTA, 1)
        if terminal.mouseMode != .none {
            // The wheel's position is in screen coordinates.
            var point = POINT(x: LONG(Int16(truncatingIfNeeded: lParam & 0xFFFF)), y: LONG(Int16(truncatingIfNeeded: (lParam >> 16) & 0xFFFF)))
            ScreenToClient(hwnd, &point)
            let (col, row) = cell(at: LPARAM(point.x & 0xFFFF) | (LPARAM(point.y & 0xFFFF) << 16))
            for _ in 0..<notches { report(button: up ? 64 : 65, col: col, row: row, press: true) }
        } else if terminal.usingAlt {
            if terminal.altScroll {
                let key = terminal.appCursorKeys ? (up ? "\u{1b}OA" : "\u{1b}OB") : (up ? "\u{1b}[A" : "\u{1b}[B")
                send(String(repeating: key, count: notches * 3))
            }
        } else {
            scroll(by: (up ? 1 : -1) * notches * 3)
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

    private func placeCursor(line: Int, col: Int) {
        guard !terminal.usingAlt, terminal.mouseMode == .none, let block = terminal.currentBlock else { return }
        let col = min(col, terminal.cols - 1)
        if block.state == .running {
            guard let rows = terminal.agentInputRows(block), rows.contains(line), rows.contains(terminal.cursorAbs) else { return }
            placeAgentCursor(row: line - rows.lowerBound, col: col, sentVertical: false)
        } else if let arrows = terminal.shellCursorArrows(block, line: line, col: col) {
            sendArrows(arrows, back: "D", forward: "C")
        }
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
        setClipboard(selection.text(in: terminal))
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

    func setClipboard(_ text: String) {
        let units = wide(text)
        let bytes = units.count * MemoryLayout<UInt16>.size
        guard openClipboard() else { return }
        defer { CloseClipboard() }
        EmptyClipboard()
        guard let memory = GlobalAlloc(Win.GMEM_MOVEABLE, SIZE_T(bytes)), let pointer = GlobalLock(memory) else { return }
        units.withUnsafeBytes { pointer.copyMemory(from: $0.baseAddress!, byteCount: bytes) }
        GlobalUnlock(memory)
        SetClipboardData(Win.CF_UNICODETEXT, memory)
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
        input(Array((terminal.bracketedPaste ? "\u{1b}[200~" + text + "\u{1b}[201~" : text).utf8), replacesSelection: true)
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
