import AppKit
import UserNotifications

struct GridPos: Comparable, Hashable {
    var line: Int
    var col: Int
    static func < (a: GridPos, b: GridPos) -> Bool { a.line != b.line ? a.line < b.line : a.col < b.col }
}

struct Selection {
    enum Mode { case char, word, line }
    var mode: Mode
    var aStart: GridPos, aEnd: GridPos
    var hStart: GridPos, hEnd: GridPos
    var start: GridPos { min(aStart, hStart) }
    var end: GridPos { max(aEnd, hEnd) }
    /// Top rule of Claude Code's input box, when the selection lies inside it: the box is redrawn lower down
    /// whenever Claude prints above it, and the selection moves with it (see `followInputBox`).
    var inputBoxTop: Int?
}

struct SearchMatch {
    var line: Int
    var start: Int
    var end: Int
}

/// Which part of the transcript ⌘F searches.
enum SearchScope: Int, CaseIterable {
    case all, commands, output

    var title: String {
        switch self {
        case .all: return "All"
        case .commands: return "Commands"
        case .output: return "Output"
        }
    }
}

/// Pre-resolved CGColors for the current theme.
final class RenderPalette {
    let theme: Theme
    let fg: CGColor
    let bg: CGColor
    let cursor: CGColor
    let cursorText: CGColor
    let selection: CGColor
    let accent: CGColor
    let match: CGColor
    let matchCurrent: CGColor
    let matchText: CGColor
    let ansi: [CGColor]
    let boldIsBright: Bool
    private var rgbCache: [UInt32: CGColor] = [:]
    /// Text too faint against its background is adjusted (see `readable`): light themes only, since programs
    /// mostly pick their colors for dark backgrounds.
    let adjustsContrast: Bool
    /// What default-background text is measured against: on a gradient, its end closest to the text, the hardest to read on.
    private let contrastBase: CGColor
    private struct ContrastKey: Hashable {
        let fg: ObjectIdentifier, bg: ObjectIdentifier?, dim: Bool
    }
    /// The colors are kept alongside the result so their identities in the key stay theirs.
    private var contrastCache: [ContrastKey: (fg: CGColor, bg: CGColor?, out: CGColor)] = [:]

    init(theme: Theme, boldIsBright: Bool) {
        self.theme = theme
        self.boldIsBright = boldIsBright
        adjustsContrast = Config.shared.minimumContrast && !theme.isDark
        contrastBase = (theme.background2.map { $0.luminance < theme.background.luminance ? $0 : theme.background } ?? theme.background).cgColor
        fg = theme.foreground.cgColor
        bg = theme.background.cgColor
        cursor = theme.cursor.cgColor
        cursorText = theme.background.cgColor
        selection = theme.selection.cgColor
        accent = theme.accent.cgColor
        match = theme.yellow.withAlphaComponent(0.35).cgColor
        matchCurrent = NSColor(hex: "#FF9F1C").cgColor
        matchText = NSColor.black.cgColor
        ansi = (0..<256).map { theme.paletteColor($0).cgColor }
    }

    /// `fg`, darkened or lightened just enough to read over `bg` (nil: the window's background), its hue kept.
    /// Text the same color as its background stays that way: that's how programs hide it. `dim` text is drawn at
    /// half strength (so asks less of the color, and is measured as it'll look).
    func readable(_ fg: CGColor, over bg: CGColor?, dim: Bool) -> CGColor {
        let key = ContrastKey(fg: ObjectIdentifier(fg), bg: bg.map { ObjectIdentifier($0) }, dim: dim)
        if let hit = contrastCache[key] { return hit.out }
        let out = Self.adjusted(fg, over: bg ?? contrastBase, minimum: dim ? Self.minimumDimContrast : Self.minimumContrast, dim: dim)
        if contrastCache.count > 4096 { contrastCache.removeAll() }
        contrastCache[key] = (fg, bg, out)
        return out
    }

    static let minimumContrast: CGFloat = 4.5
    static let minimumDimContrast: CGFloat = 3

    static func rgb(_ c: CGColor) -> (r: CGFloat, g: CGFloat, b: CGFloat)? {
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB), let p = c.converted(to: srgb, intent: .defaultIntent, options: nil)?.components,
              p.count >= 3 else { return nil }
        return (p[0], p[1], p[2])
    }

    /// WCAG relative luminance.
    private static func luminance(_ c: (r: CGFloat, g: CGFloat, b: CGFloat)) -> CGFloat {
        func lin(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }

    /// WCAG contrast ratio, from 1 (the same) to 21 (black on white).
    static func contrast(_ a: CGColor, _ b: CGColor) -> CGFloat {
        guard let x = rgb(a), let y = rgb(b) else { return 21 }
        let l1 = luminance(x), l2 = luminance(y)
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    static func adjusted(_ fg: CGColor, over bg: CGColor, minimum: CGFloat, dim: Bool) -> CGColor {
        guard let f = rgb(fg), let b = rgb(bg), f != b else { return fg }
        // Toward black on a light background, white on a dark one; the least mix that's enough.
        let to: CGFloat = luminance(b) > 0.18 ? 0 : 1
        func color(_ t: CGFloat) -> (r: CGFloat, g: CGFloat, b: CGFloat) { (f.r + (to - f.r) * t, f.g + (to - f.g) * t, f.b + (to - f.b) * t) }
        func ratio(_ c: (r: CGFloat, g: CGFloat, b: CGFloat)) -> CGFloat {
            // Dim text is drawn at half strength over its background.
            let shown = dim ? (r: (c.r + b.r) / 2, g: (c.g + b.g) / 2, b: (c.b + b.b) / 2) : c
            let l1 = luminance(shown), l2 = luminance(b)
            return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
        }
        guard ratio(f) < minimum else { return fg }
        var lo: CGFloat = 0, hi: CGFloat = 1
        for _ in 0..<12 {
            let t = (lo + hi) / 2
            if ratio(color(t)) < minimum { lo = t } else { hi = t }
        }
        let c = color(hi)
        return CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
    }

    @inline(__always) func color(_ code: UInt32, bold: Bool = false) -> CGColor {
        switch code >> 24 {
        case 1:
            var i = Int(code & 0xFF)
            if bold && boldIsBright && i < 8 { i += 8 }
            return ansi[i]
        case 2:
            if let c = rgbCache[code] { return c }
            let c = CGColor(srgbRed: CGFloat((code >> 16) & 0xFF) / 255, green: CGFloat((code >> 8) & 0xFF) / 255,
                            blue: CGFloat(code & 0xFF) / 255, alpha: 1)
            if rgbCache.count > 4096 { rgbCache.removeAll() }
            rgbCache[code] = c
            return c
        default:
            return fg
        }
    }
}

final class TerminalView: NSView, TerminalDelegate {
    let terminal: Terminal
    private(set) var pty: PTYProcess?
    /// Whether its shell has been started (a hidden file tab's terminal starts only when shown).
    var hasStarted: Bool { started }
    weak var tab: TabSession?
    private let initialDirectory: String?
    private var started = false
    private(set) var exited = false

    var fonts = FontSet.current
    var palette = RenderPalette(theme: Config.shared.theme, boldIsBright: Config.shared.boldIsBright)
    var padX: CGFloat { Config.shared.padding }
    let padTop: CGFloat = 10
    let padBottom: CGFloat = 6

    // View state
    var scrollOffset = 0 {
        // Anything else moving the view (typing, the wheel, the scrollbar) ends a glide in progress.
        // (Re-assigning the same value, as clamping on every redraw does, isn't moving it.)
        didSet { if scrollOffset != oldValue && !glideIsSetting && scrollGlide != nil { endGlide() } }
    }
    /// A programmatic scroll gliding to `to` (lines from the bottom; fractional while moving).
    private var scrollGlide: (from: CGFloat, to: CGFloat, start: CFTimeInterval, duration: CFTimeInterval)?
    private var scrollGlideTimer: Timer?
    private var glideIsSetting = false
    /// While a glide is between whole lines, the content is drawn this far (points) above where `scrollOffset`
    /// puts it.
    private(set) var scrollPixelShift: CGFloat = 0
    var scrollAccum: CGFloat = 0
    var selection: Selection? {
        didSet {
            guard !followingInputBox else { return }
            let anchor = selection.flatMap(inputBoxAnchor)
            selection?.inputBoxTop = anchor
        }
    }
    private var followingInputBox = false
    var selectedBlock: Block?
    /// Prompt line of the selected agent turn (see AgentTurns.swift).
    var selectedTurnLine: Int?
    /// Prompt lines of agent turns whose responses are collapsed.
    var collapsedTurns = Set<Int>()
    var hoverBlock: Block?
    var rowMap: [Int] = []
    var hiddenRanges: [ClosedRange<Int>] = []
    var searchMatches: [SearchMatch] = []
    var matchesByLine: [Int: [Int]] = [:]
    var currentMatch = -1
    var searchQuery = ""
    var searchScope = SearchScope.all
    var searchBar: SearchBar?
    var dimmed = false { didSet { if dimmed != oldValue { needsDisplay = true } } }
    var blinkOn = true
    private var blinkTimer: Timer?
    private var titleTimer: Timer?
    var lastScrollTime = Date.distantPast
    /// The scrollbar widens under the pointer and can be dragged; `scrollbarGrab` is where the thumb was
    /// grabbed (0…1 down its height) while a drag is on.
    var scrollbarHover = false
    var scrollbarGrab: CGFloat?
    var hoverJumpPill = false
    var bellFlash: CGFloat = 0
    var jumpPillRect: CGRect = .zero
    var collapseChips: [(CGRect, () -> Void)] = []
    var hoverURL: (line: Int, start: Int, end: Int)?
    private(set) var remote: RemoteSession?
    private var remoteSyncWork: DispatchWorkItem?
    private var lastTitle = ""
    private var observers: [NSObjectProtocol] = []
    private var windowObservers: [NSObjectProtocol] = []

    // Mouse interaction state (used by the input extension)
    var mouseAnchor: GridPos?
    /// The input box's top when `mouseAnchor` was pressed inside Claude Code's input box (it follows the box too).
    var mouseAnchorBoxTop: Int?
    /// The screen cell under the pointer at the last drag event: the selection only changes when the pointer
    /// moves to another cell, not when the text moves under a still pointer.
    var lastDragCell: (col: Int, row: Int)?
    var didDrag = false
    var reportingMouse = false
    var lastReportedCell: (Int, Int)?
    /// A click waiting for the screen to settle before it's interpreted (see `whenCursorSettled`).
    var pendingClick: (() -> Void)?
    var pendingClickDeadline = Date.distantPast
    var pendingClickTimer: Timer?
    /// Arrow keys were sent to move the cursor and the program hasn't redrawn since.
    var awaitingCursorEcho = false
    /// While a selection in Claude Code's box is being removed: what follows it, keys typed meanwhile included.
    var afterSelectionDeleted: [() -> Void]?
    var selectionDeleteGeneration = 0
    /// Output from a previous session, replayed above the new shell's first prompt.
    var restoredText: String?
    /// When the program last printed anything (see `whenOutputQuiet`).
    var lastOutputAt = Date.distantPast
    /// The coding agent running here and what it's doing (see AgentStatus.swift); nil when none.
    private(set) var agent: AgentInfo?
    /// The agent last seen running, and one that exited with an error (shown as failed until another command runs).
    private var runningAgent: AgentKind?
    private var failedAgent: AgentKind?
    /// When the agent started its current stretch of work, and the pending check that it has really stopped.
    private var agentWorkingSince: Date?
    private var agentStopCheck: DispatchWorkItem?
    /// Code blocks and tables from Claude Code's replies, boxed with a Copy button (see CodeBoxes.swift).
    var codeBoxes: [CodeBox] = []
    /// Thumbnails over Claude Code's "[Image #N]" (see ImageChips.swift).
    let imageChipState = ImageChipState()
    /// Copy buttons drawn this frame, by index into `codeBoxes`.
    var codeCopyButtons: [(CGRect, Int)] = []
    var hoverCopyButton: Int?
    /// The box whose button shows "Copied" for a moment.
    var copiedBox: Int?
    /// "Copy output" on the hovered command's first line, and the block it just copied.
    var blockCopyButton: (rect: CGRect, block: Block)?
    var hoverBlockCopy = false
    var copiedBlock: Block?
    /// Transcript sizes + screen extent at the last scan; a scan only runs when this changes.
    private var boxScanKey = ""
    private var boxScanGeneration = 0
    /// ⌘⇧Z: the shell prompt's line (text, cursor offset) as it was before each ⌘Z, newest last. Memory only,
    /// and dropped as soon as anything else is sent to the shell (see `send`).
    var redoStack: [(text: String, cursor: Int)] = []
    /// Set while undo/redo is typing, so its own keystrokes don't clear `redoStack`.
    var typingUndoRedo = false
    /// What each row and the cursor showed when last drawn, and a key of everything else drawn (see Redraw.swift).
    var drawnRows: [DrawnRow] = []
    var drawnCursor = DrawnCursor()
    var drawnFrame: Int?
    /// The whole view is to be redrawn anyway, so there's no need to work out which rows changed.
    var fullRedrawPending = true
    /// Typed (with ↩) once the shell shows its first prompt, e.g. `ssh host` for a tab opened from the hosts menu.
    var pendingCommand: String?
    /// False: `pendingCommand` is only typed, waiting for Return.
    var pendingCommandRuns = true

    init(cwd: String?) {
        initialDirectory = cwd
        terminal = Terminal(cols: 80, rows: 24, scrollbackLimit: Config.shared.scrollback)
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.isOpaque = false
        terminal.delegate = self
        registerForDraggedTypes([.fileURL])
        observers.append(NotificationCenter.default.addObserver(forName: .solanumConfigChanged, object: nil, queue: .main) { [weak self] _ in
            self?.applyConfig()
        })
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        (observers + windowObservers).forEach { NotificationCenter.default.removeObserver($0) }
        blinkTimer?.invalidate()
        titleTimer?.invalidate()
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var needsDisplay: Bool {
        get { super.needsDisplay }
        set {
            super.needsDisplay = newValue
            if newValue { fullRedrawPending = true }
        }
    }
    override var isOpaque: Bool { false }

    func applyConfig() {
        fonts = FontSet.current
        palette = RenderPalette(theme: Config.shared.theme, boldIsBright: Config.shared.boldIsBright)
        terminal.setScrollbackLimit(Config.shared.scrollback)
        updateBlinkTimer()
        needsLayout = true
        needsDisplay = true
    }

    // MARK: - Process lifecycle

    private func startIfNeeded() {
        guard !started, bounds.width > 50, bounds.height > 30 else { return }
        started = true
        let (cols, rows) = gridSize()
        terminal.resize(cols: cols, rows: rows)
        if let text = restoredText {
            restoredText = nil
            Array(text.utf8).withUnsafeBufferPointer { terminal.feed($0) }
        }
        let cmd = ShellIntegration.launchCommand()
        guard let p = PTYProcess(executable: cmd.exe, args: cmd.args, env: cmd.env, cwd: initialDirectory, cols: cols, rows: rows) else {
            let msg = "\r\n  Solanum could not start \(cmd.exe)\r\n"
            Array(msg.utf8).withUnsafeBufferPointer { terminal.feed($0) }
            return
        }
        p.onData = { [weak self] data in self?.receive(data) }
        p.onExit = { [weak self] in self?.processExited() }
        pty = p
        p.start()
        // Without shell integration there's no prompt mark to wait for, so it goes in as typeahead.
        if !Config.shared.shellIntegration, let c = pendingCommand {
            pendingCommand = nil
            send(c + (pendingCommandRuns ? "\r" : ""))
        }
        updatePTYSize()
        updateBlinkTimer()
        titleTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.refreshTitle() }
    }

    private func receive(_ data: Data) {
        Self.recording?.write(data)
        lastOutputAt = Date()
        data.withUnsafeBytes { raw in
            terminal.feed(raw.bindMemory(to: UInt8.self))
        }
        let pushed = terminal.scrollbackPushes
        terminal.scrollbackPushes = 0
        if pushed > 0, var g = scrollGlide {
            // New output pushed lines into the scrollback mid-glide: keep the glide pointed at the same content.
            g.from += CGFloat(pushed)
            if g.to > 0 { g.to += CGFloat(pushed) }
            scrollGlide = g
            glideIsSetting = true
            if scrollOffset > 0 { scrollOffset += pushed }
            glideIsSetting = false
        } else if scrollOffset > 0 && pushed > 0 {
            scrollOffset += pushed
        }
        if !terminal.syncOutput {
            followInputBox()
            // Lines scrolled off the top move every row; otherwise only the rows that changed are repainted.
            if pushed > 0 { needsDisplay = true } else { redrawChanges() }
        }
        if terminal.cursorVisible { awaitingCursorEcho = false }
        if pendingClick != nil { runPendingClick() }
        if let c = pendingCommand, terminal.currentBlock?.state == .prompt, terminal.currentBlock?.commandLine != nil {
            pendingCommand = nil
            send(c + (pendingCommandRuns ? "\r" : ""))
        }
    }

    /// Development aid: SOLANUM_RECORD=/path appends everything programs print to that file, to study how they draw.
    private static let recording: FileHandle? = ProcessInfo.processInfo.environment["SOLANUM_RECORD"].flatMap { path in
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }

    /// Where Claude Code's input box starts, if `s` lies entirely inside it.
    private func inputBoxAnchor(_ s: Selection) -> Int? {
        inputBoxAnchor(s.start, s.end)
    }

    func inputBoxAnchor(_ start: GridPos, _ end: GridPos) -> Int? {
        guard let b = terminal.currentBlock, let rows = terminal.agentInputRows(b),
              rows.contains(start.line), rows.contains(end.line) else { return nil }
        return terminal.agentInputBoxTop(b)
    }

    /// Keeps a selection in Claude Code's input box on the same text when Claude prints above the box: it
    /// erases the box, writes the new output there and draws the box again lower down.
    private func followInputBox() {
        guard selection?.inputBoxTop != nil || mouseAnchorBoxTop != nil,
              let b = terminal.currentBlock, let top = terminal.agentInputBoxTop(b) else { return }
        if var s = selection, let old = s.inputBoxTop, top != old {
            let d = top - old
            s.aStart.line += d; s.aEnd.line += d; s.hStart.line += d; s.hEnd.line += d
            s.inputBoxTop = top
            followingInputBox = true
            selection = s
            followingInputBox = false
        }
        // Pressed in the box, not dragged yet: where the drag will start from moves too.
        if let old = mouseAnchorBoxTop, top != old, var a = mouseAnchor {
            a.line += top - old
            mouseAnchor = a
            mouseAnchorBoxTop = top
        }
    }

    private func processExited() {
        guard !exited else { return }
        exited = true
        blinkTimer?.invalidate()
        titleTimer?.invalidate()
        pendingClickTimer?.invalidate()
        tab?.paneDidExit(self)
    }

    func terminate() {
        exited = true
        blinkTimer?.invalidate()
        titleTimer?.invalidate()
        pty?.terminate()
    }

    func send(_ bytes: [UInt8]) {
        if !typingUndoRedo && !redoStack.isEmpty { redoStack.removeAll() }
        pty?.write(bytes)
        // A command was entered in an ssh session: look up the remote shell's folder once it has had a moment to cd.
        if remote != nil, !terminal.usingAlt, bytes.contains(13) {
            remoteSyncWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.remote?.refresh() }
            remoteSyncWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
        }
    }

    func send(_ s: String) { send(Array(s.utf8)) }

    var currentDirectory: String? {
        terminal.cwd ?? pty?.currentDirectory ?? initialDirectory
    }

    /// Where this pane's files live: the ssh host while a session is running in it, otherwise this Mac.
    var fileSystem: FileSystem { remote ?? LocalFileSystem.shared }

    /// The folder the shell is in, on whichever machine `fileSystem` points at.
    var browseDirectory: String? {
        guard let remote else { return currentDirectory }
        return terminal.remoteCwd ?? remote.cwd ?? remote.home
    }

    /// Types a `cd` at the prompt (local, or inside a running ssh session).
    @discardableResult
    func changeDirectory(to path: String) -> Bool {
        guard !exited, !terminal.usingAlt, remote != nil || !hasRunningJob else {
            NSSound.beep()
            return false
        }
        send("\u{15}cd \(shellQuote(path))\r")
        window?.makeFirstResponder(self)
        return true
    }

    private func updateRemoteSession() {
        guard terminal.sshControlPath != remote?.controlPath else { return }
        remoteSyncWork?.cancel()
        remote = terminal.sshControlPath.map { RemoteSession(controlPath: $0, sshArgs: terminal.sshArgs) }
        remote?.onChange = { [weak self] in
            guard let self else { return }
            self.tab?.paneCwdChanged(self)
        }
        remote?.start()
    }

    /// True when something other than the shell is running in the foreground.
    var hasRunningJob: Bool {
        guard let pty, !exited else { return false }
        return pty.hasForegroundJob
    }

    var isRunningCommand: Bool { terminal.currentBlock?.state == .running }

    var displayTitle: String {
        if let t = terminal.title, !t.isEmpty { return Self.withoutStatusGlyph(t) }
        if let pty, pty.hasForegroundJob {
            // Prefer the command line typed at the prompt; fall back to the process name.
            if let b = terminal.currentBlock, b.state == .running, !b.command.isEmpty {
                let cmd = b.command.replacingOccurrences(of: "\n", with: " ")
                return cmd.count > 48 ? String(cmd.prefix(47)) + "…" : cmd
            }
            if let name = pty.foregroundProcessName { return name }
        }
        if let dir = currentDirectory {
            let home = NSHomeDirectory()
            if dir == home { return "~" }
            return (dir as NSString).lastPathComponent
        }
        return pty?.shellName ?? "Solanum"
    }

    /// Claude Code puts a status glyph before its title ("✳ Claude Code" when idle, a spinner such as "◐" while
    /// working); the tab already shows the agent's own mark and state, so the title goes without it. (Agent
    /// detection still reads the raw title.)
    static func withoutStatusGlyph(_ title: String) -> String {
        let scalars = title.unicodeScalars
        guard let first = scalars.first, scalars.dropFirst().first == " " else { return title }
        let v = first.value
        let isGlyph = (0x2800...0x28FF).contains(v)       // braille spinners
            || (0x25A0...0x25FF).contains(v)              // geometric shapes: ◐ ◓ ◑ ◒ ● ○
            || (0x2700...0x27BF).contains(v)              // dingbats: ✳ ✶ ✻ ✽ ✢
            || "·*+".unicodeScalars.contains(first)
        guard isGlyph else { return title }
        let rest = String(scalars.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? title : rest
    }

    func refreshTitle() {
        let t = displayTitle
        if t != lastTitle {
            lastTitle = t
            tab?.paneTitleChanged(self)
        }
        updateAgent()
    }

    /// Re-reads which agent is in the foreground and its state (called every second with the title).
    func updateAgent() {
        var next: AgentInfo?
        // Over ssh the foreground process is ssh itself; Claude Code still shows through its window title.
        let kind = pty?.foregroundAgent ?? (pty?.foregroundProcessName == "ssh" ? AgentKind.fromTitle(terminal.title) : nil)
        if let kind, !exited {
            runningAgent = kind
            failedAgent = nil
            next = AgentInfo(kind: kind, status: terminal.agentScreenStatus())
        } else if let f = failedAgent {
            if pty?.hasForegroundJob == true { failedAgent = nil } else { next = AgentInfo(kind: f, status: .failed) }
        }
        if next != agent {
            let old = agent
            agent = next
            agentChanged(from: old)
            tab?.paneTitleChanged(self)
        }
        refreshCodeBoxes()
    }

    /// An agent that worked at least "Notify after" seconds and then stopped (done, or waiting on you) in a tab
    /// you're not watching gets a corner card, as a long command does. It counts as stopped only after a few
    /// seconds without working again, so pauses between an agent's steps don't each make a card.
    private func agentChanged(from old: AgentInfo?) {
        if agent?.status == .working {
            agentStopCheck?.cancel()
            agentStopCheck = nil
            if agentWorkingSince == nil { agentWorkingSince = Date() }
            return
        }
        guard old?.status == .working, let since = agentWorkingSince else { return }
        let stoppedAt = Date()
        let check = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.agentStopCheck = nil
            self.agentWorkingSince = nil
            guard let a = self.agent, a.status == .done || a.status == .waiting else { return }
            let threshold = Config.shared.notifyAfterSeconds
            let d = stoppedAt.timeIntervalSince(since)
            guard threshold > 0, d >= threshold, !self.isWatched, let tab = self.tab else { return }
            let th = Config.shared.theme
            let prompt = self.terminal.currentBlock.flatMap { self.terminal.agentTurns(in: $0).last }
                .map { self.terminal.agentPromptText($0).split(whereSeparator: \.isNewline).joined(separator: " ") }
            self.showCornerNotice(title: a.kind.name + (a.status == .done ? " finished" : " needs your input"),
                                  symbol: a.status == .done ? ("checkmark.circle.fill", th.ansi[2]) : ("questionmark.circle.fill", a.status.color),
                                  lines: [Self.place(of: tab)] + (prompt.map { ["❯ " + $0] } ?? []) + ["Worked \(TerminalView.formatDuration(d))"],
                                  in: tab)
            if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
        }
        agentStopCheck = check
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: check)
    }

    /// The pane is on screen in front of the user: Solanum active, its window key, its tab showing.
    private var isWatched: Bool {
        NSApp.isActive && (window?.isKeyWindow ?? false) && (tab?.isActive ?? true)
    }

    /// "Group › Tab" for a tab in a group, else the tab's name.
    private static func place(of tab: TabSession) -> String {
        tab.group.map { "\($0.displayName) › \(tab.title)" } ?? tab.title
    }

    /// Re-finds Claude's code blocks and tables on screen whenever its transcript or the screen has moved on.
    /// Skipped while it's working (the screen churns and the reply isn't in the transcript yet).
    func refreshCodeBoxes() {
        let before = codeBoxes.count
        codeBoxes.removeAll { !terminal.stillShows($0) }
        if codeBoxes.count != before { needsDisplay = true }
        guard let agent, agent.kind == .claude, agent.status != .working, remote == nil,
              let pid = pty?.foregroundPID, let cwd = PTYProcess.directory(of: pid) else { return }
        ClaudeTranscript.codeBlocks(cwd: cwd) { [weak self] blocks, signature in
            guard let self else { return }
            let key = "\(signature)|\(self.terminal.firstAbs)|\(self.terminal.lastAbs)|\(self.terminal.cols)|\(self.terminal.cursorAbs)"
            guard key != self.boxScanKey else { return }
            self.boxScanKey = key
            // The scan reads the whole scrollback, so it runs on a copy, off the main thread. A newer scan
            // supersedes it; boxes the screen no longer shows by the time it's done are dropped.
            self.boxScanGeneration += 1
            let generation = self.boxScanGeneration
            let lines = self.terminal.snapshot()
            LineSnapshot.scanQueue.async {
                let boxes = lines.findBoxes(code: blocks)
                DispatchQueue.main.async { [weak self] in
                    guard let self, generation == self.boxScanGeneration else { return }
                    self.codeBoxes = boxes.filter { self.terminal.stillShows($0) }
                    self.needsDisplay = true
                }
            }
        }
    }

    // MARK: - Layout

    func gridSize() -> (Int, Int) {
        let cols = Int((bounds.width - 2 * padX) / fonts.cellW)
        let rows = Int((bounds.height - padTop - padBottom) / fonts.cellH)
        return (max(cols, 10), max(rows, 3))
    }

    override func layout() {
        super.layout()
        if !started {
            startIfNeeded()
        } else {
            let (c, r) = gridSize()
            if c != terminal.cols || r != terminal.rows {
                terminal.resize(cols: c, rows: r)
                selection = nil
                clearSearchMatches()
                updatePTYSize()
                needsDisplay = true
            }
        }
        if let sb = searchBar {
            sb.frame = NSRect(x: bounds.width - sb.frame.width - 12, y: 8, width: sb.frame.width, height: sb.frame.height)
        }
    }

    /// Repaints this pane, and gets whatever runs in it to repaint too: the size is reported one column narrower
    /// for a moment and then restored, and shells, Claude Code, vim… (over ssh as well) redraw on a resize.
    /// Nothing is restarted or interrupted.
    @objc func refreshDisplay(_ sender: Any?) {
        needsDisplay = true
        guard let pty, !exited else { return }
        let scale = window?.backingScaleFactor ?? 2
        pty.resize(cols: max(1, terminal.cols - 1), rows: terminal.rows,
                   pixelWidth: Int(CGFloat(terminal.cols - 1) * fonts.cellW * scale), pixelHeight: Int(CGFloat(terminal.rows) * fonts.cellH * scale))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.updatePTYSize()
            self?.needsDisplay = true
        }
    }

    private func updatePTYSize() {
        let scale = window?.backingScaleFactor ?? 2
        pty?.resize(cols: terminal.cols, rows: terminal.rows,
                    pixelWidth: Int(CGFloat(terminal.cols) * fonts.cellW * scale),
                    pixelHeight: Int(CGFloat(terminal.rows) * fonts.cellH * scale))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
        windowObservers = []
        guard let w = window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: w, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.blinkOn = true
                self.needsDisplay = true
            })
        }
        needsLayout = true
    }

    // MARK: - Cursor blink

    func updateBlinkTimer() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        blinkOn = true
        guard cursorBlinks else { return }
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.55, repeats: true) { [weak self] _ in
            guard let self, self.isActiveForInput else { return }
            self.blinkOn.toggle()
            self.redrawChanges()
        }
    }

    var cursorBlinks: Bool {
        if let s = terminal.cursorShape { return s % 2 == 1 }
        return Config.shared.cursorBlink
    }

    enum CursorShape { case block, bar, underline }
    var cursorShapeValue: CursorShape {
        if let s = terminal.cursorShape {
            switch s {
            case 3, 4: return .underline
            case 5, 6: return .bar
            default: return .block
            }
        }
        switch Config.shared.cursorStyle {
        case "block": return .block
        case "underline": return .underline
        default: return .bar
        }
    }

    var isActiveForInput: Bool {
        guard let w = window else { return false }
        return w.isKeyWindow && w.firstResponder === self
    }

    func resetBlink() {
        blinkOn = true
        if cursorBlinks {
            blinkTimer?.fireDate = Date().addingTimeInterval(0.55)
        }
    }

    // MARK: - TerminalDelegate

    // Replies to the program's queries aren't typing, so they bypass `send` (and keep the redo history).
    func terminalSend(_ bytes: [UInt8]) { pty?.write(bytes) }
    func terminalTitleChanged(_ t: Terminal) { refreshTitle() }
    func terminalCwdChanged(_ t: Terminal) {
        updateRemoteSession()
        refreshTitle()
        tab?.paneCwdChanged(self)
    }

    func terminalBell(_ t: Terminal) {
        bellFlash = 1
        animateBell()
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
    }

    private func animateBell() {
        Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.bellFlash -= 0.08
            if self.bellFlash <= 0 { self.bellFlash = 0; timer.invalidate() }
            self.needsDisplay = true
        }
    }

    func terminalBlockFinished(_ t: Terminal, block: Block) {
        if let k = runningAgent {
            runningAgent = nil
            // Ctrl-C (130) is the usual way out, not a failure.
            if let code = block.exitCode, code != 0, code != 130 { failedAgent = k }
            updateAgent()
        }
        tab?.paneTitleChanged(self)
        CommandHistory.shared.record(block.command)
        let threshold = Config.shared.notifyAfterSeconds
        guard threshold > 0, let d = block.duration, d >= threshold else { return }
        guard !isWatched, let tab else { return }
        let ok = (block.exitCode ?? 0) == 0
        let th = Config.shared.theme
        let took = "Took \(TerminalView.formatDuration(d))" + (ok ? "" : " · exit \(block.exitCode ?? -1)")
        showCornerNotice(title: ok ? "Command finished" : "Command failed",
                         symbol: ok ? ("checkmark.circle.fill", th.ansi[2]) : ("xmark.octagon.fill", th.red),
                         lines: [Self.place(of: tab), block.command, took], in: tab)
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
    }

    /// A card in the top-right corner of the window being looked at (else the tab's own), for 30 seconds unless
    /// said otherwise. Clicking it goes to the tab.
    private func showCornerNotice(title: String, symbol: (name: String, color: NSColor), lines: [String], in tab: TabSession,
                                  button: (title: String, action: () -> Void)? = nil, lifetime: TimeInterval = 30) {
        guard let wc = (NSApp.keyWindow?.windowController as? TerminalWindowController) ?? tab.windowController else { return }
        let notice = CornerNoticeView(title: title, symbol: symbol, lines: lines, button: button, lifetime: lifetime)
        notice.onClick = { [weak tab] in
            guard let tab, let column = tab.owner as? TabColumn, let i = column.tabs.firstIndex(of: tab), let owner = column.owner else { return }
            owner.focus(column)
            column.select(index: i)
            owner.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        wc.rootView.showNotice(notice)
    }

    /// ssh exits with 255 when the connection drops (a network change, the Mac sleeping, the server going down).
    /// If the session had logged in, offers to log back in, in this pane, in the folder it was in.
    func terminalSSHExited(_ t: Terminal, status: Int) {
        guard status == 255, let remote, remote.isReady, let tab,
              let command = remote.reconnectCommand(in: terminal.remoteCwd ?? remote.cwd) else { return }
        let host = remote.hostLabel ?? "the ssh host"
        let th = Config.shared.theme
        showCornerNotice(title: "Lost connection to \(host)", symbol: ("wifi.exclamationmark", th.red),
                         lines: [Self.place(of: tab), terminal.remoteCwd ?? remote.cwd ?? ""].filter { !$0.isEmpty }, in: tab,
                         button: ("Reconnect", { [weak self] in self?.reconnect(command) }), lifetime: 600)
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
    }

    /// Runs `command` at this pane's prompt (once the shell is back at one); not while something else has the pane.
    private func reconnect(_ command: String) {
        guard !exited, terminal.sshControlPath == nil, !terminal.usingAlt, !hasRunningJob else { return NSSound.beep() }
        if terminal.currentBlock?.state == .prompt {
            send("\u{15}" + command + "\r")
        } else {
            pendingCommand = command
            pendingCommandRuns = true
        }
        window?.makeFirstResponder(self)
    }

    func terminalOpenSettings(_ t: Terminal) {
        SettingsWindowController.shared.present()
    }

    func terminalClipboardWrite(_ t: Terminal, text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func terminalScreenSwitched(_ t: Terminal) {
        selection = nil
        scrollOffset = 0
        clearSearchMatches()
        needsDisplay = true
    }

    func terminalSyncEnded(_ t: Terminal) { redrawChanges() }

    func terminalColor(_ t: Terminal, code: Int) -> (UInt8, UInt8, UInt8) {
        let th = palette.theme
        switch code {
        case 10: return th.foreground.rgbBytes
        case 11: return th.background.rgbBytes
        case 12: return th.cursor.rgbBytes
        default: return th.paletteColor(max(0, min(255, code - 256))).rgbBytes
        }
    }

    func terminalPixelSize(_ t: Terminal) -> (width: Int, height: Int) {
        (Int(CGFloat(terminal.cols) * fonts.cellW), Int(CGFloat(terminal.rows) * fonts.cellH))
    }

    static func formatDuration(_ d: TimeInterval) -> String {
        if d < 1 { return "\(Int(d * 1000))ms" }
        if d < 60 { return String(format: "%.1fs", d) }
        let m = Int(d) / 60, s = Int(d) % 60
        if m < 60 { return "\(m)m \(s)s" }
        return "\(m / 60)h \(m % 60)m"
    }

    // MARK: - Display mapping (scrollback + collapsed blocks)

    func computeRowMap() {
        let rows = terminal.rows
        if rowMap.count != rows { rowMap = Array(repeating: -1, count: rows) }
        if terminal.usingAlt {
            hiddenRanges = []
            for r in 0..<rows { rowMap[r] = r }
            return
        }
        let first = terminal.firstAbs
        var ranges: [ClosedRange<Int>] = []
        for b in terminal.blocks where b.collapsed && b.state == .finished {
            guard let o = b.outputLine, let e = b.endLine, e >= o else { continue }
            let lo = max(o, first)
            guard e >= lo, (ranges.last?.upperBound ?? Int.min) < lo else { continue }
            ranges.append(lo...e)
        }
        ranges += collapsedTurnRanges()
        ranges = ranges.filter { $0.upperBound >= first }.map { max($0.lowerBound, first)...$0.upperBound }.sorted { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<Int>] = []
        for r in ranges {
            if let last = merged.last, r.lowerBound <= last.upperBound + 1 {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, r.upperBound)
            } else {
                merged.append(r)
            }
        }
        hiddenRanges = merged
        let total = totalDisplayLines
        scrollOffset = max(0, min(scrollOffset, total - rows))
        let top = max(0, total - rows - scrollOffset)
        for r in 0..<rows {
            let d = top + r
            rowMap[r] = d < total ? displayToAbs(d) : -1
        }
    }

    var totalDisplayLines: Int {
        if terminal.usingAlt { return terminal.rows }
        return terminal.scrollback.count + terminal.rows - hiddenRanges.reduce(0) { $0 + $1.count }
    }

    var maxScrollOffset: Int { max(0, totalDisplayLines - terminal.rows) }

    /// The scrollbar's track and thumb, when there's scrollback to move through.
    func scrollbarGeometry() -> (track: CGRect, thumb: CGRect)? {
        let total = totalDisplayLines, rows = terminal.rows
        guard total > rows else { return nil }
        let w: CGFloat = scrollbarHover || scrollbarGrab != nil ? 9 : 4
        let trackH = bounds.height - 16
        let thumbH = max(24, trackH * CGFloat(rows) / CGFloat(total))
        let top = CGFloat(total - rows - scrollOffset) / CGFloat(max(1, total - rows))
        let x = bounds.width - w - 3
        return (CGRect(x: x, y: 8, width: w, height: trackH), CGRect(x: x, y: 8 + (trackH - thumbH) * top, width: w, height: thumbH))
    }

    /// The strip along the right edge where the pointer works the scrollbar.
    func inScrollbarZone(_ p: NSPoint) -> Bool {
        scrollbarGeometry() != nil && p.x >= bounds.width - 14 && p.x <= bounds.width && p.y >= 4 && p.y <= bounds.height - 4
    }

    /// Scrolls so the thumb, held at `scrollbarGrab`, sits under the pointer's `y`.
    func dragScrollbar(to y: CGFloat) {
        guard let g = scrollbarGeometry() else { return }
        let thumbTop = y - (scrollbarGrab ?? 0.5) * g.thumb.height
        let travel = max(1, g.track.height - g.thumb.height)
        let frac = min(max((thumbTop - g.track.minY) / travel, 0), 1)
        let target = Int(((1 - frac) * CGFloat(maxScrollOffset)).rounded())
        if target != scrollOffset {
            scrollOffset = target
            needsDisplay = true
        }
        lastScrollTime = Date()
    }

    func displayToAbs(_ d: Int) -> Int {
        var a = terminal.firstAbs + d
        for h in hiddenRanges {
            if h.lowerBound <= a { a += h.count } else { break }
        }
        return a
    }

    func absToDisplay(_ a: Int) -> Int {
        var hidden = 0
        for h in hiddenRanges {
            if h.upperBound < a { hidden += h.count }
            else if h.lowerBound <= a { return h.lowerBound - 1 - terminal.firstAbs - hidden }
            else { break }
        }
        return a - terminal.firstAbs - hidden
    }

    /// Scrolls so that the given absolute line is visible, `context` rows from the top.
    func scrollToAbs(_ a: Int, context: Int = 1) {
        computeRowMap()
        let d = absToDisplay(a)
        let want = totalDisplayLines - terminal.rows - (d - context)
        smoothScroll(to: want)
    }

    // MARK: - Blocks

    func blockAt(abs a: Int) -> Block? {
        let blocks = terminal.blocks
        var lo = 0, hi = blocks.count - 1, found = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if blocks[mid].promptLine <= a { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        guard found >= 0 else { return nil }
        let b = blocks[found]
        return a <= b.lastLine(cursorAbs: terminal.cursorAbs) ? b : nil
    }

    /// Visible blocks with the first/last screen row they occupy.
    func visibleBlockSpans() -> [(block: Block, first: Int, last: Int)] {
        guard !terminal.usingAlt else { return [] }
        var result: [(Block, Int, Int)] = []
        var cur: Block?
        var first = 0
        for r in 0..<rowMap.count {
            let a = rowMap[r]
            let b = a >= 0 ? blockAt(abs: a) : nil
            if b !== cur {
                if let c = cur { result.append((c, first, r - 1)) }
                cur = b
                first = r
            }
        }
        if let c = cur { result.append((c, first, rowMap.count - 1)) }
        return result.filter { $0.0.state != .prompt }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        fullRedrawPending = false
        computeRowMap()
        var list: UnsafePointer<NSRect>?
        var count = 0
        getRectsBeingDrawn(&list, count: &count)
        let rects = count > 0 ? list.map { Array(UnsafeBufferPointer(start: $0, count: count)) } ?? [dirtyRect] : [dirtyRect]
        let full = rects.contains { $0.contains(bounds) }
        drawingRects = rects
        // Only some rows are being repainted: start them from clear, as a whole redraw does.
        if !full { rects.forEach { ctx.clear($0) } }
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.setShouldSmoothFonts(false)

        let spans = visibleBlockSpans()
        // Mid-glide the content sits part of a line up; the scrollbar and buttons in drawOverlays don't move.
        ctx.saveGState()
        if scrollPixelShift != 0 { ctx.translateBy(x: 0, y: -scrollPixelShift) }
        drawBlockBackgrounds(ctx, spans)
        drawTurnBackground(ctx)
        drawCodeBoxes(ctx)
        layoutImageChips()
        drawCells(ctx)
        drawImageChips(ctx)
        drawCursor(ctx)
        drawBlockChrome(ctx, spans)
        drawCopyButtons(ctx)
        drawTurnChrome(ctx)
        ctx.restoreGState()
        drawOverlays(ctx)
        drawImagePreview(ctx)
        recordDrawn(rects, full: full)
    }

    // MARK: - Smooth scrolling

    /// Glides to `target` lines from the bottom (jump to bottom, ⌘↑/⌘↓, jump to prompt, Home/End…) instead of
    /// jumping: eased over 0.2–0.35s, longer for longer trips. Scrolling by hand stays direct.
    func smoothScroll(to target: Int) {
        computeRowMap()
        let target = max(0, min(target, maxScrollOffset))
        let current = glidePosition
        lastScrollTime = Date()
        guard abs(CGFloat(target) - current) >= 1, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            endGlide()
            scrollOffset = target
            needsDisplay = true
            return
        }
        let duration = min(0.35, 0.2 + Double(abs(CGFloat(target) - current)) * 0.002)
        scrollGlide = (current, CGFloat(target), CACurrentMediaTime(), duration)
        guard scrollGlideTimer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.stepGlide() }
        RunLoop.main.add(t, forMode: .common)
        scrollGlideTimer = t
        stepGlide()
    }

    /// Where the view is now, in lines from the bottom (between lines while gliding).
    private var glidePosition: CGFloat { CGFloat(scrollOffset) - scrollPixelShift / fonts.cellH }

    private func stepGlide() {
        guard let g = scrollGlide else { return endGlide() }
        let p = min(1, (CACurrentMediaTime() - g.start) / g.duration)
        let e = CGFloat(1 - pow(1 - p, 3))
        let pos = max(0, g.from + (g.to - g.from) * e)
        // Rows for the line above the position; the content is then drawn shifted up by the remainder.
        glideIsSetting = true
        scrollOffset = min(Int(pos.rounded(.up)), maxScrollOffset)
        glideIsSetting = false
        scrollPixelShift = max(0, (CGFloat(scrollOffset) - pos) * fonts.cellH)
        lastScrollTime = Date()
        needsDisplay = true
        if p >= 1 {
            glideIsSetting = true
            scrollOffset = Int(g.to)
            glideIsSetting = false
            endGlide()
        }
    }

    private func endGlide() {
        scrollGlideTimer?.invalidate()
        scrollGlideTimer = nil
        scrollGlide = nil
        if scrollPixelShift != 0 {
            scrollPixelShift = 0
            needsDisplay = true
        }
    }

    func rowY(_ r: Int) -> CGFloat { padTop + CGFloat(r) * fonts.cellH }

    /// Screen rows (first, last) a box occupies, if any of it is visible.
    private func visibleRows(_ b: CodeBox) -> (Int, Int)? {
        guard let r0 = rowMap.firstIndex(where: { b.contains(line: $0) }),
              let r1 = rowMap.lastIndex(where: { b.contains(line: $0) }) else { return nil }
        return (r0, r1)
    }

    /// A tinted, outlined panel behind each code block (tables already have their own border).
    private func drawCodeBoxes(_ ctx: CGContext) {
        let th = palette.theme
        for b in codeBoxes where b.kind == .code {
            guard let (r0, r1) = visibleRows(b) else { continue }
            let x = max(2, padX + CGFloat(b.indent) * fonts.cellW - 9)
            let rect = CGRect(x: x, y: rowY(r0) - 1, width: bounds.width - padX + 6 - x, height: CGFloat(r1 - r0 + 1) * fonts.cellH + 2)
            let path = CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil)
            ctx.setFillColor(th.foreground.withAlphaComponent(0.045).cgColor)
            ctx.addPath(path)
            ctx.fillPath()
            ctx.setStrokeColor(th.border.cgColor)
            ctx.setLineWidth(1)
            ctx.addPath(path)
            ctx.strokePath()
        }
    }

    /// "Copy" at the top right of each box whose first line is on screen.
    private func drawCopyButtons(_ ctx: CGContext) {
        codeCopyButtons = []
        let th = palette.theme
        for (i, b) in codeBoxes.enumerated() {
            guard let r = rowMap.firstIndex(of: b.first) else { continue }
            let copied = copiedBox == i
            // Above the box when the line there is empty (Claude leaves one), so it never covers a long first line.
            let roomAbove = b.kind == .code && r > 0 && rowMap[r - 1] == b.first - 1 && (terminal.line(abs: b.first - 1)?.isBlank ?? false)
            let rect = drawCopyPill(copied ? "Copied" : b.kind == .table ? "Copy table" : "Copy", copied: copied, hover: hoverCopyButton == i,
                                    rightX: bounds.width - padX + 2,
                                    top: { roomAbove ? self.rowY(r) - $0 - 1 : self.rowY(r) + (self.fonts.cellH - $0) / 2 }, ctx)
            codeCopyButtons.append((rect, i))
        }
    }

    /// A small "⧉ Copy…" button ending at `rightX`; `top` gives its top edge from its height. Returns its rect.
    private func drawCopyPill(_ text: String, copied: Bool, hover: Bool, rightX: CGFloat, top: (CGFloat) -> CGFloat,
                              _ ctx: CGContext) -> CGRect {
        let th = palette.theme
        let font = NSFont.systemFont(ofSize: max(10, fonts.size - 2.5), weight: .medium)
        let color = copied ? th.green : hover ? th.foreground : th.dimText
        let label = NSAttributedString(string: copied ? "✓ " + text : text, attributes: [.font: font, .foregroundColor: color])
        let icon = copied ? nil : NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: font.pointSize - 1, weight: .medium).applying(.init(paletteColors: [color])))
        let size = label.size()
        let w = size.width + 16 + (icon.map { $0.size.width + 4 } ?? 0)
        let h = size.height + 4
        let rect = CGRect(x: rightX - w, y: top(h), width: w, height: h)
        let pill = CGPath(roundedRect: rect, cornerWidth: 5, cornerHeight: 5, transform: nil)
        ctx.setFillColor(th.surface.cgColor)
        ctx.addPath(pill)
        ctx.fillPath()
        if hover || copied {
            ctx.setFillColor(th.foreground.withAlphaComponent(0.08).cgColor)
            ctx.addPath(pill)
            ctx.fillPath()
        }
        ctx.setStrokeColor(th.border.cgColor)
        ctx.addPath(pill)
        ctx.strokePath()
        var tx = rect.minX + 8
        if let icon {
            NSGraphicsContext.saveGraphicsState()
            let flipped = NSGraphicsContext(cgContext: ctx, flipped: true)
            NSGraphicsContext.current = flipped
            icon.draw(in: CGRect(x: tx, y: rect.midY - icon.size.height / 2, width: icon.size.width, height: icon.size.height))
            NSGraphicsContext.restoreGraphicsState()
            tx += icon.size.width + 4
        }
        drawLabel(label, at: CGPoint(x: tx, y: rect.minY + 2), ctx)
        return rect
    }

    /// Copies a command's output (as ⌘⌥C does) and shows "Copied" on its button for a moment.
    func copyOutput(of b: Block) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(blockText(b, includeCommand: false), forType: .string)
        copiedBlock = b
        needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.copiedBlock === b else { return }
            self.copiedBlock = nil
            self.needsDisplay = true
        }
    }

    func copyBox(_ i: Int) {
        guard codeBoxes.indices.contains(i) else { return }
        codeBoxes[i].copy()
        copiedBox = i
        needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.copiedBox == i else { return }
            self.copiedBox = nil
            self.needsDisplay = true
        }
    }

    /// The rounded outline around a selected block or prompt, whose tint fills exactly this shape.
    func selectionOutline(top: CGFloat, height: CGFloat) -> CGPath {
        CGPath(roundedRect: CGRect(x: 3, y: top + 1, width: bounds.width - 6, height: height - 2), cornerWidth: 6, cornerHeight: 6, transform: nil)
    }

    private func drawBlockBackgrounds(_ ctx: CGContext, _ spans: [(block: Block, first: Int, last: Int)]) {
        let th = palette.theme
        for s in spans {
            let top = rowY(s.first) - 2, height = CGFloat(s.last - s.first + 1) * fonts.cellH + 4
            if s.block === selectedBlock {
                // Inside its outline (drawn with the block's chrome), not past it.
                ctx.setFillColor(th.accent.withAlphaComponent(0.11).cgColor)
                ctx.addPath(selectionOutline(top: top, height: height))
                ctx.fillPath()
            } else if s.block.failed {
                ctx.setFillColor(th.red.withAlphaComponent(0.07).cgColor)
                ctx.fill(CGRect(x: 0, y: top, width: bounds.width, height: height))
            }
        }
    }

    private func selectionCols(forLine a: Int) -> ClosedRange<Int>? {
        guard let s = selection else { return nil }
        let st = s.start, en = s.end
        guard a >= st.line && a <= en.line else { return nil }
        let lo = a == st.line ? st.col : 0
        let hi = a == en.line ? en.col : terminal.cols - 1
        return lo <= hi ? lo...hi : nil
    }

    // Reused per-row buffers
    /// The parts of the view being repainted this frame.
    private var drawingRects: [CGRect] = []
    private var rowFG: [CGColor] = []
    private var rowBG: [CGColor?] = []

    private func drawCells(_ ctx: CGContext) {
        let cols = terminal.cols
        let cw = fonts.cellW, ch = fonts.cellH
        if rowFG.count != cols {
            rowFG = Array(repeating: palette.fg, count: cols)
            rowBG = Array(repeating: nil, count: cols)
        }
        let reverse = terminal.reverseVideo

        for r in 0..<rowMap.count {
            let a = rowMap[r]
            // Rows being repainted, and their neighbours for any glyph reaching into them.
            let band = rowBand(r).insetBy(dx: 0, dy: -3)
            guard a >= 0, drawingRects.contains(where: { $0.intersects(band) }), let line = terminal.line(abs: a) else { continue }
            let y = rowY(r)
            let n = min(line.cells.count, cols)
            let sel = selectionCols(forLine: a)
            let lineMatches = matchesByLine[a]
            // "[Image #N]" with its picture drawn there instead (see ImageChips.swift).
            let hiddenText = imageChipState.hidden[a]
            // A scrollback line stops at its last character; a selection still highlights to the end of the row.
            let nb = sel != nil ? cols : n

            // Resolve colors
            for x in 0..<nb {
                let c = line.cell(x)
                let bold = c.flags.contains(.bold)
                var fg = c.fg == 0 ? palette.fg : palette.color(c.fg, bold: bold)
                var bg: CGColor? = c.bg == 0 ? nil : palette.color(c.bg)
                if c.flags.contains(.inverse) != reverse {
                    let f = fg
                    fg = bg ?? palette.bg
                    bg = f
                }
                // Block characters (a progress bar, a Powerline arrow) are shapes, not text: their colors stay.
                if palette.adjustsContrast, c.ch > 32, !(c.ch >= 0x2580 && c.ch <= 0x259F), !(c.ch >= 0xE0B0 && c.ch <= 0xE0B6) {
                    fg = palette.readable(fg, over: bg, dim: c.flags.contains(.dim))
                }
                if c.flags.contains(.dim) { fg = fg.copy(alpha: 0.5) ?? fg }
                if let lm = lineMatches {
                    for mi in lm {
                        let m = searchMatches[mi]
                        if x >= m.start && x <= m.end {
                            if mi == currentMatch { bg = palette.matchCurrent; fg = palette.matchText } else { bg = palette.match }
                        }
                    }
                }
                if let sel, sel.contains(x) { bg = palette.selection }
                if let hiddenText, hiddenText.contains(where: { $0.contains(x) }) { fg = .clear }
                rowFG[x] = fg
                rowBG[x] = bg
            }

            // Backgrounds (merged runs)
            var x = 0
            while x < nb {
                guard let bg = rowBG[x] else { x += 1; continue }
                var e = x + 1
                while e < nb, let b2 = rowBG[e], b2 === bg || b2 == bg { e += 1 }
                ctx.setFillColor(bg)
                ctx.fill(CGRect(x: padX + CGFloat(x) * cw, y: y, width: CGFloat(e - x) * cw, height: ch))
                x = e
            }

            // Text
            let baseY = y + fonts.baseline
            var run = String.UnicodeScalarView()
            var runStart = 0
            var runStyle = -1
            var runColor: CGColor = palette.fg
            func flush() {
                if !run.isEmpty {
                    drawString(String(run), style: runStyle, color: runColor, x: padX + CGFloat(runStart) * cw, baseline: baseY, ctx)
                    run.removeAll(keepingCapacity: true)
                }
                runStyle = -1
            }
            for x in 0..<n {
                let c = line.cells[x]
                if c.width == 0 { continue }
                let v = c.ch
                if v == 0 || v == 32 || c.flags.contains(.invisible) { flush(); continue }
                let style = fonts.styleIndex(c.flags)
                let fg = rowFG[x]
                let isBox = (v >= 0x2500 && v <= 0x259F) || (v >= 0xE0B0 && v <= 0xE0B6)
                if isBox, drawBoxChar(v, x: padX + CGFloat(x) * cw, y: y, w: cw, h: ch, color: fg, ctx) {
                    flush()
                    continue
                }
                let simple = c.width == 1 && fonts.hasGlyph(v) && line.extras?[x] == nil
                if simple {
                    if runStyle == style && run.count > 0 && (runColor === fg || runColor == fg) {
                        run.append(Unicode.Scalar(v)!)
                    } else {
                        flush()
                        runStyle = style
                        runColor = fg
                        runStart = x
                        run.append(Unicode.Scalar(v) ?? " ")
                    }
                } else {
                    flush()
                    if c.width == 1, line.extras?[x] == nil, let sym = fonts.symbol(v, style: style) {
                        drawSymbol(sym, color: fg, x: padX + CGFloat(x) * cw, baseline: baseY, ctx)
                        continue
                    }
                    let s = line.string(at: x)
                    let cellsWide = CGFloat(c.width == 2 ? 2 : 1)
                    drawString(s, style: style, color: fg, x: padX + CGFloat(x) * cw, baseline: baseY, ctx, fitWidth: cellsWide * cw)
                }
            }
            flush()

            // Decorations
            for x in 0..<n {
                let c = line.cells[x]
                guard !c.flags.intersection([.underline, .doubleUnderline, .curlyUnderline, .strike]).isEmpty else { continue }
                let w = CGFloat(c.width == 2 ? 2 : 1) * cw
                let x0 = padX + CGFloat(x) * cw
                ctx.setFillColor(rowFG[x])
                let lw = fonts.lineWidth
                let uy = baseY + fonts.underlineOffset
                if c.flags.contains(.underline) { ctx.fill(CGRect(x: x0, y: uy, width: w, height: lw)) }
                if c.flags.contains(.doubleUnderline) {
                    ctx.fill(CGRect(x: x0, y: uy - lw, width: w, height: lw))
                    ctx.fill(CGRect(x: x0, y: uy + lw * 1.5, width: w, height: lw))
                }
                if c.flags.contains(.curlyUnderline) {
                    ctx.setStrokeColor(rowFG[x])
                    ctx.setLineWidth(lw)
                    let path = CGMutablePath()
                    path.move(to: CGPoint(x: x0, y: uy))
                    path.addCurve(to: CGPoint(x: x0 + w, y: uy), control1: CGPoint(x: x0 + w / 3, y: uy - 2.5), control2: CGPoint(x: x0 + 2 * w / 3, y: uy + 2.5))
                    ctx.addPath(path)
                    ctx.strokePath()
                }
                if c.flags.contains(.strike) {
                    ctx.fill(CGRect(x: x0, y: y + fonts.baseline - fonts.ascent * 0.32, width: w, height: lw))
                }
            }

            // ⌘-hover link underline
            if let hu = hoverURL, hu.line == a {
                ctx.setFillColor(palette.accent)
                ctx.fill(CGRect(x: padX + CGFloat(hu.start) * cw, y: baseY + fonts.underlineOffset,
                                width: CGFloat(hu.end - hu.start + 1) * cw, height: fonts.lineWidth))
            }
        }
    }

    func drawString(_ s: String, style: Int, color: CGColor, x: CGFloat, baseline: CGFloat, _ ctx: CGContext, fitWidth: CGFloat? = nil) {
        let attr = NSAttributedString(string: s, attributes: fonts.attrs[max(0, style)])
        let line = CTLineCreateWithAttributedString(attr)
        var dx: CGFloat = 0
        if let fit = fitWidth {
            let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            if w < fit { dx = (fit - w) / 2 }
        }
        ctx.setFillColor(color)
        ctx.textPosition = CGPoint(x: x + dx, y: baseline)
        CTLineDraw(line, ctx)
    }

    /// A fallback symbol, sized to the capitals and centered on them and in its cell (see FontSet.symbol).
    func drawSymbol(_ s: FontSet.Symbol, color: CGColor, x: CGFloat, baseline: CGFloat, _ ctx: CGContext) {
        ctx.saveGState()
        ctx.setFillColor(color)
        ctx.translateBy(x: x + fonts.cellW / 2, y: baseline - fonts.capHeight / 2)
        ctx.scaleBy(x: s.scale, y: s.scale)
        // Glyph positions are in text space, from the text position (where the last string ended) and through the
        // flipped text matrix: zero, and the ink's middle negated, put that middle at the cell's.
        ctx.textPosition = .zero
        var glyph = s.glyph
        var at = CGPoint(x: -s.ink.midX, y: -s.ink.midY)
        CTFontDrawGlyphs(s.font, &glyph, &at, 1, ctx)
        ctx.restoreGState()
    }

    private func drawCursor(_ ctx: CGContext) {
        guard terminal.cursorVisible, !exited else { return }
        let ca = terminal.cursorAbs
        guard let r = rowMap.firstIndex(of: ca), let line = terminal.line(abs: ca) else { return }
        let cx = min(terminal.cursorX, line.cells.count - 1)
        let cell = line.cells[cx]
        let w = CGFloat(cell.width == 2 ? 2 : 1) * fonts.cellW
        let x = padX + CGFloat(cx) * fonts.cellW
        let y = rowY(r)
        let color = palette.cursor
        if !isActiveForInput {
            ctx.setStrokeColor(color.copy(alpha: 0.7) ?? color)
            ctx.setLineWidth(1)
            ctx.stroke(CGRect(x: x + 0.5, y: y + 0.5, width: w - 1, height: fonts.cellH - 1))
            return
        }
        if cursorBlinks && !blinkOn { return }
        let glyphH = ceil(fonts.ascent + fonts.descent)
        let glyphTop = y + fonts.baseline - fonts.ascent
        switch cursorShapeValue {
        case .block:
            ctx.setFillColor(color)
            ctx.fill(CGRect(x: x, y: y, width: w, height: fonts.cellH))
            if cell.ch != 0 && cell.ch != 32 {
                drawString(line.string(at: cx), style: fonts.styleIndex(cell.flags), color: palette.cursorText,
                           x: x, baseline: y + fonts.baseline, ctx)
            }
        case .bar:
            ctx.setFillColor(color)
            let path = CGPath(roundedRect: CGRect(x: x, y: glyphTop - 1, width: 2, height: glyphH + 2), cornerWidth: 1, cornerHeight: 1, transform: nil)
            ctx.addPath(path)
            ctx.fillPath()
        case .underline:
            ctx.setFillColor(color)
            ctx.fill(CGRect(x: x, y: y + fonts.baseline + fonts.underlineOffset, width: w, height: 2))
        }
    }

    private func drawBlockChrome(_ ctx: CGContext, _ spans: [(block: Block, first: Int, last: Int)]) {
        let th = palette.theme
        collapseChips = []
        blockCopyButton = nil
        for s in spans {
            let b = s.block
            let top = rowY(s.first) - 2
            let height = CGFloat(s.last - s.first + 1) * fonts.cellH + 4
            let startsHere = spanStartsHere(s)

            if startsHere && s.first > 0 {
                ctx.setFillColor(th.border.cgColor)
                ctx.fill(CGRect(x: 0, y: top - 0.5, width: bounds.width, height: 1))
            }
            if b === selectedBlock {
                ctx.setStrokeColor(th.accent.withAlphaComponent(0.85).cgColor)
                ctx.setLineWidth(1.5)
                ctx.addPath(selectionOutline(top: top, height: height))
                ctx.strokePath()
            } else if b.failed {
                ctx.setFillColor(th.red.cgColor)
                ctx.addPath(CGPath(roundedRect: CGRect(x: 3, y: top + 3, width: 3, height: height - 6), cornerWidth: 1.5, cornerHeight: 1.5, transform: nil))
                ctx.fillPath()
            } else if showsRunningBar(b), height > 6 {
                ctx.setFillColor(th.accent.withAlphaComponent(0.8).cgColor)
                ctx.addPath(CGPath(roundedRect: CGRect(x: 3, y: top + 3, width: 2, height: height - 6), cornerWidth: 1, cornerHeight: 1, transform: nil))
                ctx.fillPath()
            }

            // Status badge on the block's first line.
            var badgeRect: CGRect?
            if startsHere, let badge = blockBadge(b) {
                badgeRect = drawBadge(badge.text, color: badge.color, rightX: bounds.width - padX, centerY: rowY(s.first) + fonts.cellH / 2, ctx)
            }

            // "Copy output" beside the badge while the pointer is over a finished command that printed something.
            if startsHere, b === hoverBlock || b === copiedBlock, b.state == .finished, !b.isAgentSession,
               let o = b.outputLine, let e = b.endLine, e >= o {
                let right = (badgeRect?.minX ?? bounds.width - padX) - 6
                let rect = drawCopyPill(b === copiedBlock ? "Copied" : "Copy output", copied: b === copiedBlock, hover: hoverBlockCopy,
                                        rightX: right, top: { self.rowY(s.first) + (self.fonts.cellH - $0) / 2 }, ctx)
                blockCopyButton = (rect, b)
            }

            // "⋯ N lines" chip for collapsed blocks, after the command text.
            if b.collapsed, let o = b.outputLine, let e = b.endLine, e >= o {
                let cmdLine = o - 1
                if let r = rowMap.firstIndex(of: cmdLine), let l = terminal.line(abs: cmdLine) {
                    let len = l.text().count
                    let x = padX + CGFloat(min(len + 2, terminal.cols - 12)) * fonts.cellW
                    let rect = drawChip("⋯ \(e - o + 1) lines hidden", x: x, centerY: rowY(r) + fonts.cellH / 2, ctx)
                    collapseChips.append((rect, { [weak self] in
                        b.collapsed = false
                        self?.needsDisplay = true
                    }))
                }
            }
        }
    }

    /// Whether a block's first row on screen is its real start (its separator and badge go there).
    func spanStartsHere(_ s: (block: Block, first: Int, last: Int)) -> Bool {
        rowMap[s.first] == s.block.promptLine && headerIntact(s.block)
    }

    /// A running command gets a bar down its left; an agent chat (Claude Code, also when started through an
    /// alias) goes without one.
    func showsRunningBar(_ b: Block) -> Bool {
        b.state == .running && !(b.isAgentSession || terminal.agentInputBoxTop(b) != nil || (b === terminal.currentBlock && agent != nil))
    }

    /// The status badge on a block's first line, if it shows one.
    func blockBadge(_ b: Block) -> (text: String, color: NSColor)? {
        guard let d = b.duration, b === selectedBlock || b === hoverBlock || b.failed || b.state == .running else { return nil }
        let th = palette.theme
        switch b.state {
        case .running:
            guard d > 1 && !b.isAgentSession else { return nil }
            return ("● running  \(TerminalView.formatDuration(d))", th.accent)
        default:
            if b.failed { return ("✕ exit \(b.exitCode ?? -1)  ·  \(TerminalView.formatDuration(d))", th.red) }
            return ("✓ \(TerminalView.formatDuration(d))", th.green)
        }
    }

    /// False when the block's command line has since been overwritten (e.g. a full-screen program
    /// redrew over it), so its start marker would land in unrelated output.
    private func headerIntact(_ b: Block) -> Bool {
        let cmd = b.command.split(separator: "\n").first.map { String($0.prefix(24)) } ?? ""
        guard !cmd.isEmpty else { return true }
        let first = b.commandLine ?? b.promptLine
        let last = (b.outputLine ?? first + 1) - 1
        return (first...max(first, last)).contains { terminal.line(abs: $0)?.text().contains(cmd) ?? false }
    }

    @discardableResult
    func drawBadge(_ text: String, color: NSColor, rightX: CGFloat, centerY: CGFloat, _ ctx: CGContext) -> CGRect {
        let font = NSFont.systemFont(ofSize: max(10, fonts.size - 2.5), weight: .medium)
        let attr = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let size = attr.size()
        let rect = CGRect(x: rightX - size.width - 14, y: centerY - size.height / 2 - 2, width: size.width + 14, height: size.height + 4)
        ctx.setFillColor(palette.theme.background.withAlphaComponent(0.85).cgColor)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: rect.height / 2, cornerHeight: rect.height / 2, transform: nil))
        ctx.fillPath()
        ctx.setFillColor(color.withAlphaComponent(0.14).cgColor)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: rect.height / 2, cornerHeight: rect.height / 2, transform: nil))
        ctx.fillPath()
        drawLabel(attr, at: CGPoint(x: rect.minX + 7, y: rect.minY + 2), ctx)
        return rect
    }

    func drawChip(_ text: String, x: CGFloat, centerY: CGFloat, _ ctx: CGContext) -> CGRect {
        let th = palette.theme
        let font = NSFont.systemFont(ofSize: max(10, fonts.size - 2.5), weight: .medium)
        let attr = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: th.dimText])
        let size = attr.size()
        let rect = CGRect(x: x, y: centerY - size.height / 2 - 2, width: size.width + 14, height: size.height + 4)
        ctx.setFillColor(th.surface.cgColor)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 5, cornerHeight: 5, transform: nil))
        ctx.fillPath()
        drawLabel(attr, at: CGPoint(x: rect.minX + 7, y: rect.minY + 2), ctx)
        return rect
    }

    /// Draws UI text (not terminal text) in the flipped context.
    func drawLabel(_ attr: NSAttributedString, at p: CGPoint, _ ctx: CGContext) {
        NSGraphicsContext.saveGraphicsState()
        attr.draw(at: p)
        NSGraphicsContext.restoreGraphicsState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    }

    /// The scrollbar shows while scrolled up, for a moment after scrolling, and under the pointer.
    var scrollbarShown: Bool {
        totalDisplayLines > terminal.rows
            && (scrollOffset > 0 || Date().timeIntervalSince(lastScrollTime) < 1.2 || scrollbarHover || scrollbarGrab != nil)
    }

    private func drawOverlays(_ ctx: CGContext) {
        let th = palette.theme
        // Scroll indicator
        let recentlyScrolled = Date().timeIntervalSince(lastScrollTime) < 1.2
        let active = scrollbarHover || scrollbarGrab != nil
        if scrollbarShown, let g = scrollbarGeometry() {
            if active {
                ctx.setFillColor(th.foreground.withAlphaComponent(0.07).cgColor)
                ctx.addPath(CGPath(roundedRect: g.track, cornerWidth: g.track.width / 2, cornerHeight: g.track.width / 2, transform: nil))
                ctx.fillPath()
            }
            ctx.setFillColor(th.foreground.withAlphaComponent(scrollbarGrab != nil ? 0.55 : active ? 0.4 : 0.25).cgColor)
            ctx.addPath(CGPath(roundedRect: g.thumb, cornerWidth: g.thumb.width / 2, cornerHeight: g.thumb.width / 2, transform: nil))
            ctx.fillPath()
            if recentlyScrolled && scrollOffset == 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [weak self] in self?.needsDisplay = true }
            }
        }
        // Jump-to-bottom pill
        if scrollOffset > 0 {
            let size: CGFloat = 30
            let rect = CGRect(x: bounds.width - padX - size - 6, y: bounds.height - size - 14, width: size, height: size)
            jumpPillRect = rect
            ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: 8, color: NSColor.black.withAlphaComponent(0.35).cgColor)
            ctx.setFillColor((hoverJumpPill ? th.accent.blended(withFraction: 0.18, of: .white) ?? th.accent : th.accent).cgColor)
            ctx.fillEllipse(in: rect)
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(2)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            let cx = rect.midX, cy = rect.midY
            ctx.move(to: CGPoint(x: cx, y: cy - 7)); ctx.addLine(to: CGPoint(x: cx, y: cy + 6))
            ctx.move(to: CGPoint(x: cx - 5, y: cy + 1)); ctx.addLine(to: CGPoint(x: cx, y: cy + 6)); ctx.addLine(to: CGPoint(x: cx + 5, y: cy + 1))
            ctx.strokePath()
        } else {
            jumpPillRect = .zero
        }
        if dimmed {
            ctx.setFillColor(th.background.withAlphaComponent(0.38).cgColor)
            ctx.fill(bounds)
        }
        if bellFlash > 0 {
            ctx.setFillColor(th.foreground.withAlphaComponent(0.10 * bellFlash).cgColor)
            ctx.fill(bounds)
        }
    }

    // MARK: - Box drawing

    private static let boxTable: [UInt32: (u: UInt8, d: UInt8, l: UInt8, r: UInt8)] = {
        var t: [UInt32: (UInt8, UInt8, UInt8, UInt8)] = [:]
        // (up, down, left, right): 1 = light, 2 = heavy
        let specs: [(UInt32, UInt8, UInt8, UInt8, UInt8)] = [
            (0x2500, 0, 0, 1, 1), (0x2501, 0, 0, 2, 2), (0x2502, 1, 1, 0, 0), (0x2503, 2, 2, 0, 0),
            (0x2504, 0, 0, 1, 1), (0x2505, 0, 0, 2, 2), (0x2506, 1, 1, 0, 0), (0x2507, 2, 2, 0, 0),
            (0x2508, 0, 0, 1, 1), (0x2509, 0, 0, 2, 2), (0x250A, 1, 1, 0, 0), (0x250B, 2, 2, 0, 0),
            (0x250C, 0, 1, 0, 1), (0x250D, 0, 1, 0, 2), (0x250E, 0, 2, 0, 1), (0x250F, 0, 2, 0, 2),
            (0x2510, 0, 1, 1, 0), (0x2511, 0, 1, 2, 0), (0x2512, 0, 2, 1, 0), (0x2513, 0, 2, 2, 0),
            (0x2514, 1, 0, 0, 1), (0x2515, 1, 0, 0, 2), (0x2516, 2, 0, 0, 1), (0x2517, 2, 0, 0, 2),
            (0x2518, 1, 0, 1, 0), (0x2519, 1, 0, 2, 0), (0x251A, 2, 0, 1, 0), (0x251B, 2, 0, 2, 0),
            (0x251C, 1, 1, 0, 1), (0x251D, 1, 1, 0, 2), (0x251E, 2, 1, 0, 1), (0x251F, 1, 2, 0, 1),
            (0x2520, 2, 2, 0, 1), (0x2521, 2, 1, 0, 2), (0x2522, 1, 2, 0, 2), (0x2523, 2, 2, 0, 2),
            (0x2524, 1, 1, 1, 0), (0x2525, 1, 1, 2, 0), (0x2526, 2, 1, 1, 0), (0x2527, 1, 2, 1, 0),
            (0x2528, 2, 2, 1, 0), (0x2529, 2, 1, 2, 0), (0x252A, 1, 2, 2, 0), (0x252B, 2, 2, 2, 0),
            (0x252C, 0, 1, 1, 1), (0x252D, 0, 1, 2, 1), (0x252E, 0, 1, 1, 2), (0x252F, 0, 1, 2, 2),
            (0x2530, 0, 2, 1, 1), (0x2531, 0, 2, 2, 1), (0x2532, 0, 2, 1, 2), (0x2533, 0, 2, 2, 2),
            (0x2534, 1, 0, 1, 1), (0x2535, 1, 0, 2, 1), (0x2536, 1, 0, 1, 2), (0x2537, 1, 0, 2, 2),
            (0x2538, 2, 0, 1, 1), (0x2539, 2, 0, 2, 1), (0x253A, 2, 0, 1, 2), (0x253B, 2, 0, 2, 2),
            (0x253C, 1, 1, 1, 1), (0x253D, 1, 1, 2, 1), (0x253E, 1, 1, 1, 2), (0x253F, 1, 1, 2, 2),
            (0x2540, 2, 1, 1, 1), (0x2541, 1, 2, 1, 1), (0x2542, 2, 2, 1, 1), (0x2543, 2, 1, 2, 1),
            (0x2544, 2, 1, 1, 2), (0x2545, 1, 2, 2, 1), (0x2546, 1, 2, 1, 2), (0x2547, 2, 1, 2, 2),
            (0x2548, 1, 2, 2, 2), (0x2549, 2, 2, 2, 1), (0x254A, 2, 2, 1, 2), (0x254B, 2, 2, 2, 2),
            (0x254C, 0, 0, 1, 1), (0x254D, 0, 0, 2, 2), (0x254E, 1, 1, 0, 0), (0x254F, 2, 2, 0, 0),
            (0x2574, 0, 0, 1, 0), (0x2575, 1, 0, 0, 0), (0x2576, 0, 0, 0, 1), (0x2577, 0, 1, 0, 0),
            (0x2578, 0, 0, 2, 0), (0x2579, 2, 0, 0, 0), (0x257A, 0, 0, 0, 2), (0x257B, 0, 2, 0, 0),
            (0x257C, 0, 0, 1, 2), (0x257D, 1, 2, 0, 0), (0x257E, 0, 0, 2, 1), (0x257F, 2, 1, 0, 0),
        ]
        for s in specs { t[s.0] = (s.1, s.2, s.3, s.4) }
        return t
    }()

    /// Draws box-drawing, block-element and powerline glyphs procedurally so they join seamlessly.
    private func drawBoxChar(_ v: UInt32, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, color: CGColor, _ ctx: CGContext) -> Bool {
        let light = fonts.lineWidth
        let heavy = light * 2
        let cx = (x + w / 2).rounded(.down) + 0.5 * (light.truncatingRemainder(dividingBy: 2))
        let cy = (y + h / 2).rounded(.down)
        ctx.setFillColor(color)

        if let s = TerminalView.boxTable[v] {
            func t(_ k: UInt8) -> CGFloat { k == 2 ? heavy : light }
            let hw = max(t(s.u), t(s.d), t(s.l), t(s.r)) / 2
            if s.l > 0 { ctx.fill(CGRect(x: x, y: cy - t(s.l) / 2, width: cx - x + hw, height: t(s.l))) }
            if s.r > 0 { ctx.fill(CGRect(x: cx - hw, y: cy - t(s.r) / 2, width: x + w - cx + hw, height: t(s.r))) }
            if s.u > 0 { ctx.fill(CGRect(x: cx - t(s.u) / 2, y: y, width: t(s.u), height: cy - y + hw)) }
            if s.d > 0 { ctx.fill(CGRect(x: cx - t(s.d) / 2, y: cy - hw, width: t(s.d), height: y + h - cy + hw)) }
            return true
        }
        switch v {
        case 0x256D...0x2570: // rounded corners
            ctx.setStrokeColor(color)
            ctx.setLineWidth(light)
            let r = min(w, h) / 2
            let p = CGMutablePath()
            switch v {
            case 0x256D: p.move(to: CGPoint(x: cx, y: y + h)); p.addLine(to: CGPoint(x: cx, y: cy + r)); p.addQuadCurve(to: CGPoint(x: cx + r, y: cy), control: CGPoint(x: cx, y: cy)); p.addLine(to: CGPoint(x: x + w, y: cy))
            case 0x256E: p.move(to: CGPoint(x: cx, y: y + h)); p.addLine(to: CGPoint(x: cx, y: cy + r)); p.addQuadCurve(to: CGPoint(x: cx - r, y: cy), control: CGPoint(x: cx, y: cy)); p.addLine(to: CGPoint(x: x, y: cy))
            case 0x256F: p.move(to: CGPoint(x: cx, y: y)); p.addLine(to: CGPoint(x: cx, y: cy - r)); p.addQuadCurve(to: CGPoint(x: cx - r, y: cy), control: CGPoint(x: cx, y: cy)); p.addLine(to: CGPoint(x: x, y: cy))
            default: p.move(to: CGPoint(x: cx, y: y)); p.addLine(to: CGPoint(x: cx, y: cy - r)); p.addQuadCurve(to: CGPoint(x: cx + r, y: cy), control: CGPoint(x: cx, y: cy)); p.addLine(to: CGPoint(x: x + w, y: cy))
            }
            ctx.addPath(p)
            ctx.strokePath()
            return true
        case 0x2580: ctx.fill(CGRect(x: x, y: y, width: w, height: h / 2)); return true
        case 0x2581...0x2587:
            let f = CGFloat(v - 0x2580) / 8
            ctx.fill(CGRect(x: x, y: y + h * (1 - f), width: w, height: h * f)); return true
        case 0x2588: ctx.fill(CGRect(x: x, y: y, width: w, height: h)); return true
        case 0x2589...0x258F:
            let f = CGFloat(0x2590 - v) / 8
            ctx.fill(CGRect(x: x, y: y, width: w * f, height: h)); return true
        case 0x2590: ctx.fill(CGRect(x: x + w / 2, y: y, width: w / 2, height: h)); return true
        case 0x2591, 0x2592, 0x2593:
            let a: CGFloat = v == 0x2591 ? 0.25 : (v == 0x2592 ? 0.5 : 0.75)
            ctx.setFillColor(color.copy(alpha: a) ?? color)
            ctx.fill(CGRect(x: x, y: y, width: w, height: h)); return true
        case 0x2594: ctx.fill(CGRect(x: x, y: y, width: w, height: h / 8)); return true
        case 0x2595: ctx.fill(CGRect(x: x + w * 7 / 8, y: y, width: w / 8, height: h)); return true
        case 0x2596...0x259F:
            let masks: [UInt8] = [4, 8, 1, 13, 9, 7, 11, 2, 6, 14]
            let m = masks[Int(v - 0x2596)]
            if m & 1 != 0 { ctx.fill(CGRect(x: x, y: y, width: w / 2, height: h / 2)) }
            if m & 2 != 0 { ctx.fill(CGRect(x: x + w / 2, y: y, width: w / 2, height: h / 2)) }
            if m & 4 != 0 { ctx.fill(CGRect(x: x, y: y + h / 2, width: w / 2, height: h / 2)) }
            if m & 8 != 0 { ctx.fill(CGRect(x: x + w / 2, y: y + h / 2, width: w / 2, height: h / 2)) }
            return true
        case 0xE0B0, 0xE0B2:
            ctx.beginPath()
            if v == 0xE0B0 {
                ctx.move(to: CGPoint(x: x, y: y)); ctx.addLine(to: CGPoint(x: x + w, y: y + h / 2)); ctx.addLine(to: CGPoint(x: x, y: y + h))
            } else {
                ctx.move(to: CGPoint(x: x + w, y: y)); ctx.addLine(to: CGPoint(x: x, y: y + h / 2)); ctx.addLine(to: CGPoint(x: x + w, y: y + h))
            }
            ctx.closePath()
            ctx.fillPath()
            return true
        case 0xE0B1, 0xE0B3:
            ctx.setStrokeColor(color)
            ctx.setLineWidth(light)
            ctx.beginPath()
            if v == 0xE0B1 {
                ctx.move(to: CGPoint(x: x, y: y)); ctx.addLine(to: CGPoint(x: x + w, y: y + h / 2)); ctx.addLine(to: CGPoint(x: x, y: y + h))
            } else {
                ctx.move(to: CGPoint(x: x + w, y: y)); ctx.addLine(to: CGPoint(x: x, y: y + h / 2)); ctx.addLine(to: CGPoint(x: x + w, y: y + h))
            }
            ctx.strokePath()
            return true
        case 0xE0B4, 0xE0B6:
            ctx.beginPath()
            if v == 0xE0B4 {
                ctx.move(to: CGPoint(x: x, y: y))
                ctx.addArc(center: CGPoint(x: x, y: y + h / 2), radius: h / 2, startAngle: -.pi / 2, endAngle: .pi / 2, clockwise: false)
            } else {
                ctx.move(to: CGPoint(x: x + w, y: y))
                ctx.addArc(center: CGPoint(x: x + w, y: y + h / 2), radius: h / 2, startAngle: -.pi / 2, endAngle: .pi / 2, clockwise: true)
            }
            ctx.closePath()
            ctx.fillPath()
            return true
        default:
            return false
        }
    }
}
