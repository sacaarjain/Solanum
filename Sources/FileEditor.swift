import AppKit

/// A plain-text editor shown to the right of a tab's panes when a file is opened from the sidebar.
/// Works on local and ssh files alike through `FileSystem`. ⌘S saves, ⌘W closes, ⌥Z toggles wrapping.
/// Images, PDFs, video and audio show as a read-only preview instead (see `MediaPreviewView`).
final class FileEditorView: NSView, NSTextViewDelegate {
    /// Where the file is. Over ssh, a lost session gives way to the next one logged in to the same host.
    private(set) var fs: FileSystem
    /// The file, or for a graph the repository's top folder.
    private(set) var path: String
    let mode: EditorMode
    /// What the sub-tab says.
    var displayName: String {
        switch mode {
        case .file: return (path as NSString).lastPathComponent
        case .diff: return (path as NSString).lastPathComponent + " (Working Tree)"
        case .stagedDiff: return (path as NSString).lastPathComponent + " (Staged)"
        case .status: return "Git Changes"
        case .commit(let hash): return "Commit \(hash.prefix(8))"
        case .commitDiff(let hash): return (path as NSString).lastPathComponent + " (\(hash.prefix(8)))"
        case .graph: return "Git Graph"
        case .preview: return "Preview " + (path as NSString).lastPathComponent
        case .extensions: return "Extensions"
        case .extensionPage(let id): return Extensions.find(id)?.pageTitle ?? id
        }
    }
    var onClose: (() -> Void)?
    /// While it's its tab's only file, with no terminal: the header's button for one (see `TabSession.arrange`).
    var onShowTerminal: (() -> Void)? { didSet { header.onShowTerminal = onShowTerminal } }
    /// What the sub-tab shows changed: the file was renamed (its name, where it lives), deleted, or saved or edited
    /// (its unsaved dot).
    var onPathChanged: (() -> Void)?
    /// The header's Preview and Working Tree buttons: this file, shown another way in another sub-tab.
    var onOpenAs: ((EditorMode) -> Void)?
    /// Git Changes: a git command to run in this tab's terminal, in `dir` (one that needs a password, say).
    var onRunInTerminal: ((_ command: String, _ dir: String) -> Void)?
    /// Git Status: another file, in a sub-tab of its own.
    var onOpenOther: ((String, EditorMode) -> Void)?

    private let header = EditorHeaderView()
    private let scroll = NSScrollView()
    private let textView: EditorTextView
    private let ruler: LineNumberRuler
    private let message = NSTextField(labelWithString: "")
    private var usesCRLF = false
    private var loaded = false
    /// `focus()` was called before the text arrived (its view is hidden until then), so it takes the focus then.
    private var focusWhenLoaded = false
    /// `reveal` was called before the text arrived.
    private var revealWhenLoaded: (line: Int, text: String)?
    private var saving = false
    /// Its sub-tab's dot goes as soon as it's saved (it waited for the pointer to pass over it before).
    private(set) var isDirty = false {
        didSet {
            header.dirty = isDirty
            if isDirty != oldValue { onPathChanged?() }
        }
    }
    /// The file is gone from disk (deleted, or moved away by something else): shown struck through, as in VS Code,
    /// and saving puts it back.
    private(set) var isDeleted = false {
        didSet {
            guard isDeleted != oldValue else { return }
            header.deleted = isDeleted
            onPathChanged?()
        }
    }
    private var existsTimer: Timer?
    private var existsTicks = 0
    private var checkingExists = false
    /// Over the file while its ssh connection is lost: Reconnect, or Close.
    private var lostBar: ConnectionLostBar?
    /// Reconnect on that bar: the tab logs back in to the host (see `TabSession.reconnect`).
    var onReconnect: ((RemoteSession) -> Void)?
    /// Too big to edit (past `maxEditableFileSize`): shown read-only, in full or (past `maxReadableFileSize`) its end.
    private var partial = false
    /// What's known of the file on disk, to follow it as it grows: its size, and its last few bytes (a change
    /// there means it was rewritten, not appended to).
    private var diskSize = 0
    private var diskTail = Data()
    /// Bytes at the end of the last read that stop partway through a character, kept for the next.
    private var carry = Data()
    /// Tail File, in the header: the end stays in view as the file grows (tail -f), even after scrolling up. Without
    /// it a growing file scrolls along only while its end is showing. Either way the file keeps up with the disk.
    /// A big file (past `windowedFileSize`), shown as `less` shows one: the text is a window of it, bytes
    /// `winStart..<diskSize`, made of whole lines, fetched and let go a piece at a time as it's scrolled through
    /// (see "Big files"). Read-only, unwrapped, and every line the same height, so text added above the view can
    /// be made up for exactly.
    private var windowed = false
    private var winStart = 0
    /// The whole file's size, as last seen (the window may end before it).
    private var fileSize = 0
    /// The pieces the window is made of, top to bottom: their bytes in the file, characters in the text, lines.
    private var winChunks: [WinChunk] = []
    private struct WinChunk { var bytes: Int; var chars: Int; var lines: Int }
    /// A piece is being fetched (one at a time).
    private var winBusy = false
    /// Bumped by a jump, so pieces fetched for the window before it are dropped.
    private var winGeneration = 0
    /// Lines let go from the top, less lines added there, since the start: to place a line count that was asked
    /// for before the window moved (see `countWindowLines`).
    private var winTopShift = 0
    private var fileScroller: FileScroller?
    /// The window reaches the end of the file (so it grows as the file does).
    private var windowAtEnd: Bool { diskSize >= fileSize }

    /// A scroll (trackpad, wheel or scroller) is under way.
    private var liveScrolling = false
    /// The file needs reading again in full, held off until the scroll under way ends (see `loadText`).
    private var reloadAfterScroll = false
    /// The last few lines are on screen.
    private var endInView: Bool {
        scroll.contentView.bounds.maxY >= textView.frame.maxY - (textView.font?.pointSize ?? 13) * 3
    }
    /// Scrolled all the way down (new lines are followed from here, without Tail File).
    /// (Less the margin below the text, which scrolling to the end leaves.)
    private var atVeryEnd: Bool { scroll.contentView.bounds.maxY >= textView.frame.maxY - textView.textContainerInset.height - 4 }
    /// Solanum moving the view (rather than the user).
    private func programmatically(_ move: () -> Void) { move() }

    /// The user scrolling up (a wheel or trackpad over the text, or ↑, Page Up or Home in it) leaves Tail File.
    /// Watched as input, not as the view moving: a long text's estimated height is revised as it's laid out, which
    /// moves the view by itself (and a wheel sends no live-scroll notifications).
    fileprivate func userInput(_ e: NSEvent) {
        guard tailing, let w = window, e.window === w else { return }
        let up: Bool
        switch e.type {
        case .scrollWheel:
            up = e.scrollingDeltaY > 0.5 && scroll.bounds.contains(scroll.convert(e.locationInWindow, from: nil))
        case .keyDown:
            up = w.firstResponder === textView && [126, 116, 115].contains(e.keyCode)
        default:
            up = false
        }
        if up { userScrolledUp() }
    }

    private func userScrolledUp() {
        guard tailing else { return }
        Diagnostics.log("tail \(diagName): the user scrolled up")
        tailing = false
    }
    private var inputMonitor: Any?
    private var tailing = false {
        didSet {
            header.tailing = tailing
            Diagnostics.log("tail \(diagName): \(tailing ? "on" : "off")")
            if tailing {
                if windowed, !windowAtEnd { jumpWindow(to: nil) } else { programmatically { textView.scrollToEndOfDocument(nil) } }
                syncWithDisk()
            }
        }
    }
    private var refreshing = false
    /// The file as last read or saved (see `LocalFileSystem.signature`, `RemoteSession.statCommand`): when what's on
    /// disk differs, something else changed it (an agent, git, a formatter) and the text catches up.
    private var diskSignature: String?
    /// On this Mac: its folder, watched while the file's open (see `DiskWatch`).
    private var diskWatch: DiskWatch.Token?
    /// Over ssh: the file, followed on the host while it's showing (see `RemoteFileWatch`).
    private var remoteWatch: RemoteFileWatch.Token?
    /// It changed on disk while there were unsaved edits here: they stay, the header says so, and saving asks first.
    private var changedOnDisk = false { didSet { header.changedOnDisk = changedOnDisk } }
    /// Saving over a file changed on disk: Compare, Overwrite or Revert (see `showConflict`).
    private var conflictBar: EditorNoticeBar?
    private var compareView: DiffView?
    /// What was to happen after the save that hit the conflict (closing the editor, say).
    private var afterConflict: (() -> Void)?
    private var wraps = false
    /// Colored as JSON, YAML, XML or a log (see SyntaxHighlighting.swift, LogFormat.swift); other files stay plain.
    private var language: SyntaxLanguage? { didSet { header.canFormat = language?.canFormat ?? false } }
    private var pendingHighlight: DispatchWorkItem?
    /// Bumped by every edit and every coloring pass, so a scan finished in the background for an older text is dropped.
    private var highlightGeneration = 0
    /// A log's coloring: the format chosen for it (an imported one, or the built-in), and the one picked from the
    /// header's menu instead, by name.
    private var logFormat: LogFormat? { didSet { header.logFormatName = logFormat?.name } }
    private var logFormatPick: String?
    /// The characters of a log already colored: a big one is colored as it scrolls into view.
    private var logPainted = IndexSet()
    private var observers: [NSObjectProtocol] = []
    private var media: MediaPreviewView?
    private var diffView: DiffView?
    private var graphView: GitGraphView?
    private var statusView: GitStatusView?
    private var statusLoading = false
    private var previewView: MarkdownPreviewView?
    /// The marketplace, or an extension's page.
    private(set) var pageView: (NSView & ExtensionPage)?
    /// A remote file's local copy for the preview; removed with the editor.
    private var mediaCopy: URL?

    init(fs: FileSystem, path: String, mode: EditorMode = .file) {
        self.fs = fs
        self.path = path
        self.mode = mode
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        layout.addTextContainer(container)
        textView = EditorTextView(frame: .zero, textContainer: container)
        ruler = LineNumberRuler(scrollView: scroll, orientation: .verticalRuler)
        super.init(frame: .zero)
        layout.delegate = textView
        language = SyntaxLanguage(path: path)
        header.canFormat = language?.canFormat ?? false

        // The file's sub-tab above carries its name; the header just shows where it lives.
        header.subtitle = location
        header.toolTip = path
        header.onClose = { [weak self] in self?.requestClose() }
        header.onSave = { [weak self] in self?.saveDocument(nil) }
        header.onFormat = { [weak self] in self?.formatDocument(nil) }
        header.canPreview = MarkdownHTML.isMarkdown(path: path)
        header.onLogFormat = { [weak self] in self?.showLogFormatMenu() }
        header.onPreview = { [weak self] in self?.onOpenAs?(.preview) }
        header.onShowChanges = { [weak self] in self?.onOpenAs?(.diff) }
        header.onToggleWrap = { [weak self] in self?.toggleWrap(nil) }
        header.onCopyPath = { [weak self] in self?.copyPath() }
        header.onToggleTail = { [weak self] in self?.tailing.toggle() }
        addSubview(header)

        textView.coveredBy = { [weak self] p in
            guard let self, let bar = self.findBar else { return false }
            return bar.bounds.contains(bar.convert(p, from: nil))
        }
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.isEditable = false
        textView.delegate = self
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]

        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        ruler.textView = textView
        addSubview(scroll)
        applyWrap()

        message.alignment = .center
        message.isHidden = true
        message.maximumNumberOfLines = 4
        addSubview(message)

        applyTheme()
        observers.append(NotificationCenter.default.addObserver(forName: .solanumConfigChanged, object: nil, queue: .main) { [weak self] _ in
            self?.updateIndentation()
            self?.applyTheme()
        })
        scroll.contentView.postsBoundsChangedNotifications = true
        // A scroll under way (trackpad, wheel, scroller) is never moved under the user: new text still arrives, but
        // the view only follows the end again once they're done (and back there), and a whole reload waits for it.
        observers.append(NotificationCenter.default.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: scroll, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.liveScrolling = true
            Diagnostics.log("scroll \(self.diagName): started at y \(Int(self.scroll.contentView.bounds.minY)) of \(Int(self.textView.frame.height)), \(self.textView.textStorage?.length ?? 0) chars")
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSScrollView.didEndLiveScrollNotification, object: scroll, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.liveScrolling = false
            Diagnostics.log("scroll \(self.diagName): ended at y \(Int(self.scroll.contentView.bounds.minY)) of \(Int(self.textView.frame.height))")
            // Scrolled away from the end: that's leaving the tail (back to the end, or the button, follows it again).
            if self.tailing, !self.endInView { self.tailing = false }
            if self.reloadAfterScroll {
                self.reloadAfterScroll = false
                self.loadText(keepPlace: true)
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
            self?.ruler.needsDisplay = true
            self?.refreshFindHighlights()
            self?.paintVisibleLog()
            self?.windowScrolled()
        })
        observers.append(NotificationCenter.default.addObserver(forName: .solanumRemoteReady, object: nil, queue: .main) { [weak self] note in
            if let session = note.object as? RemoteSession { self?.follow(session) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .solanumLogFormatsChanged, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.loaded, self.language == .log else { return }
            self.chooseLogFormat()
            self.highlightSyntax()
        })
        observers.append(NotificationCenter.default.addObserver(forName: .solanumFileRenamed, object: fs, queue: .main) { [weak self] note in
            guard let old = note.userInfo?["old"] as? String, let new = note.userInfo?["new"] as? String else { return }
            self?.followRename(from: old, to: new)
        })
        if mode == .file {
            observers.append(NotificationCenter.default.addObserver(forName: RemoteFileWatch.liveChanged, object: nil, queue: .main) { [weak self] _ in
                self?.updateWatchTag()
            })
            for name in [NSApplication.didBecomeActiveNotification, .solanumFileSaved, .solanumGitStatusChanged, .solanumFilesChanged] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                    guard let self, note.name == NSApplication.didBecomeActiveNotification || note.object as AnyObject? === self.fs else { return }
                    if note.name != .solanumFilesChanged { self.refreshGitChanges() }
                    self.checkExists()
                    // In case an event was missed.
                    if note.name == NSApplication.didBecomeActiveNotification { self.syncWithDisk() }
                })
            }
            refreshGitChanges()
        }
        if mode != .file {
            // Keep a diff or graph current: files change and commits land in other apps (or, for a diff, in this
            // file's own editor tab).
            for name in [NSApplication.didBecomeActiveNotification, .solanumFileSaved] + (mode == .status ? [.solanumGitStatusChanged] : []) {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                    guard let self, self.mode == .status || note.name != .solanumFileSaved || note.userInfo?["path"] as? String == self.path else { return }
                    self.load()
                })
            }
        }
        load()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateDiskWatch()
        if window != nil, inputMonitor == nil, mode == .file {
            inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .keyDown]) { [weak self] e in
                self?.userInput(e)
                return e
            }
        } else if window == nil, let m = inputMonitor {
            NSEvent.removeMonitor(m)
            inputMonitor = nil
        }
        // Whether the file is still there: a stat every 2 seconds here; over ssh, whether the connection is (a
        // local check, as often) and a folder listing every 16.
        existsTimer?.invalidate()
        existsTimer = nil
        if window != nil, mode == .file || fs.isRemote {
            existsTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.existsTicks += 1
                self.updateConnection()
                if !self.fs.isRemote || self.existsTicks % 8 == 0 { self.checkExists() }
                // A stat, in case the folder's events can't be had (a network drive, say).
                if !self.fs.isRemote { self.syncWithDisk() }
            }
            existsTimer?.tolerance = 0.5
            updateConnection()
            checkExists()
        }
        // Coming back to the file: catch up straight away (over ssh, the watch's first report does).
        if window != nil { syncWithDisk() }
    }

    deinit {
        if let m = inputMonitor { NSEvent.removeMonitor(m) }
        existsTimer?.invalidate()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        if let dir = mediaCopy?.deletingLastPathComponent() { try? FileManager.default.removeItem(at: dir) }
    }

    /// Whether git has changes for this file on disk, for the header's Working Tree button. Off outside a repository.
    private func refreshGitChanges() {
        guard mode == .file else { return }
        let checked = path
        let name = (checked as NSString).lastPathComponent
        GitRunner(dir: (checked as NSString).deletingLastPathComponent, remote: fs as? RemoteSession)
            .run("git status --porcelain -- \(shellQuote(":(literal)" + name))", timeout: 15) { [weak self] status, out, _ in
                guard let self, self.path == checked else { return }
                self.header.hasGitChanges = status == 0 && !out.isEmpty
            }
    }

    /// Its file (or a folder it's in) was renamed: saves go to the new name from now on, and unsaved text stays.
    private func followRename(from old: String, to new: String) {
        guard path == old || path.hasPrefix(old + "/") else { return }
        path = new + path.dropFirst(old.count)
        if !fs.isRemote { diskSignature = LocalFileSystem.signature(path) }
        updateDiskWatch()
        let wasLog = language == .log
        language = SyntaxLanguage(path: path) ?? (wasLog && textView.hidesEscapes ? .log : nil)
        if language == .log { chooseLogFormat() } else { logFormat = nil }
        header.canPreview = MarkdownHTML.isMarkdown(path: path)
        refreshGitChanges()
        header.subtitle = location
        header.toolTip = path
        if mode != .file {
            load()
        } else if loaded, let storage = textView.textStorage, storage.length <= SyntaxHighlighter.maxLength {
            // The new extension may mean another language, or none.
            if language != nil {
                highlightSyntax()
            } else {
                storage.removeAttribute(.solanumLogWash, range: NSRange(location: 0, length: storage.length))
                storage.addAttributes([.foregroundColor: Config.shared.theme.foreground, .font: FontSet.current.regular as NSFont],
                                      range: NSRange(location: 0, length: storage.length))
            }
        }
        onPathChanged?()
    }

    private var location: String {
        [fs.hostLabel, FilePaths.abbreviate(path, home: fs.home)].compactMap { $0 }.joined(separator: ":")
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: EditorHeaderView.height)
        scroll.frame = NSRect(x: 0, y: header.frame.maxY, width: bounds.width, height: bounds.height - header.frame.maxY)
        let mh: CGFloat = 60
        message.frame = NSRect(x: 20, y: header.frame.maxY + (scroll.frame.height - mh) / 2, width: bounds.width - 40, height: mh)
        if let s = fileScroller {
            s.frame = NSRect(x: scroll.frame.maxX - FileScroller.width, y: scroll.frame.minY, width: FileScroller.width,
                             height: scroll.frame.height - (scroll.hasHorizontalScroller ? 12 : 0))
        }
        media?.frame = scroll.frame
        diffView?.frame = scroll.frame
        graphView?.frame = scroll.frame
        statusView?.frame = scroll.frame
        pageView?.frame = scroll.frame
        if let bar = findBar {
            let w = min(420, bounds.width - 24)
            bar.frame = NSRect(x: bounds.width - w - 12, y: scroll.frame.minY + 6, width: w, height: bar.preferredHeight)
        }
        previewView?.frame = scroll.frame
        compareView?.frame = scroll.frame
        if let bar = conflictBar {
            let w = min(bar.preferredWidth, bounds.width - 16)
            bar.frame = NSRect(x: max(8, bounds.width - w - 12), y: bounds.height - EditorNoticeBar.height - 10, width: w, height: EditorNoticeBar.height)
        }
        if let bar = lostBar {
            let w = min(bar.preferredWidth, bounds.width - 16)
            bar.frame = NSRect(x: max(8, bounds.width - w - 12), y: bounds.height - ConnectionLostBar.height - 10, width: w, height: ConnectionLostBar.height)
        }
    }

    // MARK: Connection

    /// Shows the lost-connection bar while the file's ssh session is down.
    private func updateConnection() {
        guard !devLostBarShown else { return }
        let remote = fs as? RemoteSession
        let lost = remote.map { $0.isReady && !$0.isConnected } ?? false
        // Already logged in to that host somewhere (a restored ssh tab, another tab): carry on there.
        if lost, let host = remote?.hostLabel, let live = TabSession.liveSession(host: host) { return follow(live) }
        guard lost != (lostBar != nil) else { return }
        if lost, let remote {
            let host = remote.hostLabel ?? "the ssh host"
            let bar = ConnectionLostBar(host: host, title: remote.awaitingLogin ? "Not connected to \(host)" : nil, onReconnect: { [weak self] in
                self?.onReconnect?(remote)
            }, onClose: { [weak self] in self?.requestClose() })
            // Its own layer, or the text's (layer-backed) scroll view draws over it.
            bar.wantsLayer = true
            lostBar = bar
            addSubview(bar)
            needsLayout = true
        } else {
            lostBar?.removeFromSuperview()
            lostBar = nil
        }
    }

    /// A session logged in to the host this file's lost session was on: the file carries on there, catching up
    /// with what changed meanwhile (unsaved edits stay).
    private func follow(_ session: RemoteSession) {
        guard let old = fs as? RemoteSession, old !== session, !old.isConnected, session.isReady, session.isConnected,
              old.hostLabel == session.hostLabel else { return }
        fs = session
        updateDiskWatch()
        updateConnection()
        refreshGitChanges()
        onPathChanged?()
        switch mode {
        case .file:
            // Restored and never read: open it now.
            if media != nil || !loaded { load() } else { refreshFromDisk() }
            checkExists()
        default:
            load()
        }
    }

    var devLostBar: ConnectionLostBar? { lostBar }
    private var devLostBarShown = false

    /// Dev aid (DevTools editor-lost-bar): the bar as a lost connection to `host` shows it.
    func devShowLostBar(host: String) {
        devLostBarShown = true
        lostBar?.removeFromSuperview()
        let bar = ConnectionLostBar(host: host, onReconnect: {}, onClose: {})
        bar.wantsLayer = true
        lostBar = bar
        addSubview(bar)
        needsLayout = true
    }

    /// Search in Project Folder and file links: a line (from 1) in view, with `text` on it selected. With no such
    /// text the caret goes to the line's start, and the line flashes to show where that is.
    func reveal(line: Int, text: String) {
        guard mode == .file, media == nil else { return }
        guard loaded else {
            revealWhenLoaded = (line, text)
            return
        }
        let s = textView.string as NSString
        var start = 0, n = 1
        while n < line, start < s.length {
            start = NSMaxRange(s.lineRange(for: NSRange(location: start, length: 0)))
            n += 1
        }
        let lineRange = s.lineRange(for: NSRange(location: min(start, s.length), length: 0))
        let found = s.range(of: text, options: .caseInsensitive, range: lineRange)
        let target = found.location == NSNotFound ? NSRange(location: lineRange.location, length: 0) : found
        textView.setSelectedRange(target)
        textView.scrollRangeToVisible(target)
        if target.length > 0 {
            textView.showFindIndicator(for: target)
        } else {
            let text = s.substring(with: lineRange).trimmingCharacters(in: .newlines) as NSString
            if text.length > 0 { textView.showFindIndicator(for: NSRange(location: lineRange.location, length: text.length)) }
        }
    }

    var devHeader: EditorHeaderView { header }
    var devSelection: String { (textView.string as NSString).substring(with: textView.selectedRange()) }
    var devCaretLine: Int {
        let s = textView.string as NSString
        return s.substring(to: textView.selectedRange().location).components(separatedBy: "\n").count
    }
    /// Dev aid (DevTools editor-scroll-x): scrolls the text sideways.
    func devScroll(x: CGFloat) {
        scroll.contentView.scroll(to: NSPoint(x: x, y: scroll.contentView.bounds.minY))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    func focus() {
        if !loaded { focusWhenLoaded = true }
        window?.makeFirstResponder(media?.focusView ?? diffView ?? graphView ?? statusView ?? previewView ?? pageView?.focusView ?? textView)
    }

    private func applyTheme() {
        findBar?.applyTheme()
        refreshFindHighlights()
        let th = Config.shared.theme
        let font = FontSet.current.regular as NSFont
        textView.font = font
        textView.textColor = th.foreground
        textView.insertionPointColor = th.cursor
        textView.selectedTextAttributes = [.backgroundColor: th.selection]
        let para = NSMutableParagraphStyle()
        let space = (" " as NSString).size(withAttributes: [.font: font]).width
        para.defaultTabInterval = space * CGFloat(textView.indentation.size)
        para.tabStops = []
        if windowed {
            // Every line the same height (see `windowed`).
            para.minimumLineHeight = lineHeight
            para.maximumLineHeight = lineHeight
        }
        textView.defaultParagraphStyle = para
        textView.typingAttributes = [.font: font, .foregroundColor: th.foreground, .paragraphStyle: para]
        if let storage = textView.textStorage, storage.length > 0 {
            storage.addAttributes([.font: font, .foregroundColor: th.foreground, .paragraphStyle: para],
                                  range: NSRange(location: 0, length: storage.length))
            storage.removeAttribute(.solanumLogWash, range: NSRange(location: 0, length: storage.length))
            highlightSyntax()
        }
        message.textColor = th.dimText
        message.font = .systemFont(ofSize: 12)
        ruler.font = NSFont.monospacedDigitSystemFont(ofSize: max(9, font.pointSize - 2), weight: .regular)
        ruler.needsDisplay = true
        media?.applyTheme()
        diffView?.applyTheme()
        graphView?.applyTheme()
        statusView?.applyTheme()
        pageView?.applyTheme()
        if mode == .preview, previewView != nil { loadPreview() }
        header.needsDisplay = true
        needsDisplay = true
    }

    // MARK: Loading and saving

    private func showMessage(_ text: String) {
        message.stringValue = text
        message.isHidden = false
        scroll.isHidden = true
    }

    private func load() {
        switch mode {
        case .diff, .stagedDiff, .commitDiff: return loadDiff()
        case .commit: return loadStatus()
        default: break
        }
        if mode.isExtensionPage { return loadExtensionPage() }
        if mode == .graph { return loadGraph() }
        if mode == .status { return loadStatus() }
        if mode == .preview { return loadPreview() }
        // Restored from a saved session: there's nothing to read it through until a session to its host is in.
        if let remote = fs as? RemoteSession, remote.awaitingLogin {
            return showMessage("Waiting for a connection to \(remote.hostLabel ?? "the ssh host").\nIt opens here once a tab is logged in there again, or press Reconnect.")
        }
        if let kind = MediaKind(path: path) { return loadMedia(kind) }
        showMessage("Loading…")
        loadText(keepPlace: false)
    }

    /// The file's text: editable up to `maxEditableFileSize`; read-only past it, in full up to `maxReadableFileSize`
    /// (a big log, over ssh too) and past that its last `fileTailSize`. `keepPlace` (a reload) keeps the caret and
    /// scroll position.
    private func loadText(keepPlace: Bool) {
        if keepPlace, ProcessInfo.processInfo.environment["SOLANUM_RELOAD_DEBUG"] != nil {
            FileHandle.standardError.write("reload: whole text read again (\((path as NSString).lastPathComponent))\n".data(using: .utf8)!)
        }
        // Not under a scroll: it'd move the text the user's moving through. Once it ends.
        if keepPlace, liveScrolling {
            if !reloadAfterScroll { Diagnostics.log("load \(diagName): held until the scroll ends") }
            reloadAfterScroll = true
            return
        }
        // A big file read again (rotated, say): its window again, where it was (or at the end, following it).
        if keepPlace, windowed {
            Diagnostics.log("load \(diagName): the window again")
            let following = atVeryEnd && windowAtEnd || tailing
            return jumpWindow(to: following ? nil : visibleByte(), keepView: !following)
        }
        let asked = Date()
        Diagnostics.log("load \(diagName): reading the whole text\(keepPlace ? " again (keeping the place)" : "")")
        // Past `windowedFileSize` (a log, `windowedLogSize`), only its end: the rest comes as it's scrolled to (see
        // "Big files").
        let windowFrom = SyntaxLanguage(path: path) == .log ? windowedLogSize : windowedFileSize
        fs.readPart(path, from: nil, whole: windowFrom, tail: 4 * windowChunk) { [weak self] result in
            guard let self else { return }
            let applying = Date()
            if Diagnostics.enabled, case .success(let part) = result {
                Diagnostics.log("load \(self.diagName): \(part.data.count) of \(part.size) bytes arrived in \(Diagnostics.ms(asked)) ms")
            }
            defer { Diagnostics.log("load \(self.diagName): shown, \(Diagnostics.ms(applying)) ms on the main thread\(self.liveScrolling ? " (DURING A SCROLL)" : "")") }
            switch result {
            case .failure(let e):
                Diagnostics.log("load \(self.diagName): failed: \(e.localizedDescription)")
                if !keepPlace { self.showMessage(e.localizedDescription) }
            case .success(let part):
                // Typed into while it was read: what's typed stays (it isn't replaced under you).
                if keepPlace && self.isDirty { return }
                self.diskSignature = part.signature
                self.changedOnDisk = false
                var data = part.data
                let cut = part.size > data.count
                let partial = cut || part.size > maxEditableFileSize
                // A cut-off end starts at the first whole line.
                var dropped = 0
                if cut, let nl = data.firstIndex(of: 0x0A) {
                    dropped = nl - data.startIndex + 1
                    data = Data(data[data.index(after: nl)...])
                }
                self.windowed = cut
                self.winGeneration += 1
                if cut {
                    self.winStart = part.size - part.data.count + dropped
                    self.fileSize = part.size
                    self.winBusy = false
                    self.winTopShift = 0
                }
                if data.prefix(8000).contains(0) {
                    self.showMessage("This looks like a binary file, so it isn't shown.")
                    return
                }
                let (whole, rest) = Self.splitUTF8(data)
                let (bytes, crlf) = Self.droppingCR(whole)
                if crlf { self.usesCRLF = true }
                let text = String(decoding: bytes, as: UTF8.self)
                // The same as shown (a touch, or a save of the same text): nothing to redo, and the undo history stays.
                if keepPlace, self.loaded, !cut, !partial, text == self.textView.string {
                    self.diskSize = part.size
                    self.diskTail = Data(part.data.suffix(256))
                    self.carry = rest
                    return
                }
                // Color codes a logger wrote into the file (logback's %highlight…) are hidden and shown as colors;
                // a file with them, or one an imported log format names, is a log whatever it's called.
                let escapes = Self.hasEscapes(bytes)
                self.textView.hidesEscapes = escapes
                if self.language == nil, escapes || LogFormatStore.formats.contains(where: { $0.matches(fileName: (self.path as NSString).lastPathComponent) }) {
                    self.language = .log
                }
                // A script without an extension: what it is from its `#!` line.
                if self.language == nil, let first = text.prefix(300).split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first,
                   let sniffed = SyntaxLanguage(firstLine: first) {
                    self.language = sniffed
                }
                self.logPainted = IndexSet()
                let caret = self.textView.selectedRange()
                let origin = self.scroll.contentView.bounds.origin
                // Long texts lay out only what's on screen, estimating the rest's height from its characters. Not a big
                // file's window: where line lengths vary a lot (a log's JSON lines), each correction of the estimate as
                // more is laid out moved what was on screen, several lines at a time. The window's small enough to lay
                // out in full.
                self.textView.layoutManager?.allowsNonContiguousLayout = !cut && text.utf16.count > 100_000
                if cut, self.wraps { self.wraps = false; self.applyWrap() }
                self.textView.string = text
                if self.language == .log { self.chooseLogFormat() }
                self.findTextChanged()
                self.updateIndentation()
                self.applyTheme()
                self.partial = partial
                self.textView.isEditable = !partial
                self.header.editable = !partial
                self.header.subtitle = partial ? "\(self.location) · \(part.size >> 20) MB · read-only" : self.location
                self.textView.undoManager?.removeAllActions()
                self.diskSize = part.size
                self.diskTail = Data(part.data.suffix(256))
                self.carry = rest
                if keepPlace {
                    let n = (text as NSString).length
                    self.textView.setSelectedRange(NSRange(location: min(caret.location, n), length: 0))
                    self.programmatically {
                        self.scroll.contentView.scroll(to: origin)
                        self.scroll.reflectScrolledClipView(self.scroll.contentView)
                    }
                } else {
                    self.textView.setSelectedRange(NSRange(location: partial ? (text as NSString).length : 0, length: 0))
                    // At the very end (so new lines are followed from the start).
                    if partial { self.programmatically { self.textView.scrollToEndOfDocument(nil) } }
                }
                self.loaded = true
                self.isDirty = false
                self.updateDiskWatch()
                self.message.isHidden = true
                self.scroll.isHidden = false
                if cut {
                    self.winChunks = [WinChunk(bytes: whole.count, chars: (text as NSString).length, lines: Self.newlines(in: text))]
                    self.splitLastChunk()
                    self.ruler.lineBase = nil
                    self.countWindowLines()
                } else {
                    self.winChunks = []
                    self.ruler.lineBase = 0
                }
                self.showFileScroller(cut)
                self.ruler.invalidateLines()
                // Only if asked for: a file shown by clicking it in the sidebar leaves the focus on the sidebar.
                if self.focusWhenLoaded { self.focus() }
                self.focusWhenLoaded = false
                // Once laid out, color what a big log shows.
                if self.language == .log { DispatchQueue.main.async { [weak self] in self?.paintVisibleLog() } }
                if let r = self.revealWhenLoaded {
                    self.revealWhenLoaded = nil
                    self.reveal(line: r.line, text: r.text)
                }
            }
        }
    }

    /// `data` with each CRLF line ending made LF (saving puts them back), and whether it had any. Done on the bytes:
    /// searching a string of hundreds of MB for "\r\n" takes seconds.
    private static func droppingCR(_ data: Data) -> (Data, Bool) {
        let hasCR = data.withUnsafeBytes { raw in raw.count > 0 && memchr(raw.baseAddress, 0x0D, raw.count) != nil }
        guard hasCR else { return (data, false) }
        var out = Data(count: data.count)
        var n = 0
        out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
            data.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
                let s = src.bindMemory(to: UInt8.self), d = dst.bindMemory(to: UInt8.self)
                var i = 0
                while i < s.count {
                    let c = s[i]
                    i += 1
                    if c == 0x0D, i < s.count, s[i] == 0x0A { continue }
                    d[n] = c
                    n += 1
                }
            }
        }
        out.count = n
        return n < data.count ? (out, true) : (data, false)
    }

    /// `data` split where its last whole character ends (a read can stop partway through one).
    private static func splitUTF8(_ data: Data) -> (Data, Data) {
        var cut = data.endIndex
        var k = 0
        // Back over up to 3 continuation bytes to the lead byte; keep the character back if it's incomplete.
        while k < 4, cut > data.startIndex {
            let b = data[cut - 1]
            if b & 0xC0 == 0x80 { cut -= 1; k += 1; continue }
            if b >= 0xC0 {
                let need = b >= 0xF0 ? 4 : b >= 0xE0 ? 3 : 2
                if k + 1 < need { cut -= 1 } else { cut = data.endIndex }
            } else {
                cut = data.endIndex
            }
            break
        }
        return (Data(data[data.startIndex..<cut]), Data(data[cut...]))
    }

    @objc func toggleTail(_ sender: Any?) { tailing.toggle() }

    // MARK: Changes on disk

    /// The file is kept current, VS Code style. On this Mac, whether it's showing or not: its folder is watched, and
    /// when the file changes there it's checked (see `syncWithDisk`). Over ssh, while it's showing: the host checks
    /// it every second (see `RemoteFileWatch`), and it catches up on coming back to it. Not media.
    private func updateDiskWatch() {
        let wanted = mode == .file && media == nil && loaded
        if let remote = fs as? RemoteSession {
            diskWatch = nil
            defer { updateWatchTag() }
            guard wanted, window != nil else { remoteWatch = nil; return }
            if let t = remoteWatch, t.path == path, t.belongs(to: remote.fileWatch) { return }
            remoteWatch = remote.fileWatch.watch(path) { [weak self] sig in self?.diskSignatureNow(sig) }
            return
        }
        remoteWatch = nil
        header.watchLive = nil
        if !wanted { diskWatch = nil; return }
        guard diskWatch?.folder != DiskWatch.realPath((path as NSString).deletingLastPathComponent) else { return }
        diskWatch = DiskWatch.shared.watch(folderOf: path) { [weak self] events in self?.diskChanged(events) }
    }

    /// Something in the file's folder changed: if it's this file, see whether it really did. Renamed within its
    /// folder (the same file under a new name, by its inode): the editor follows it there.
    private func diskChanged(_ events: [DiskWatch.Event]) {
        let real = DiskWatch.realPath((path as NSString).deletingLastPathComponent) + "/" + (path as NSString).lastPathComponent
        guard events.contains(where: { $0.path == real || $0.rescan }) else { return }
        if LocalFileSystem.signature(path) == nil, let inode = diskSignature?.split(separator: " ").last,
           let moved = events.first(where: { $0.renamed && $0.path != real && LocalFileSystem.signature($0.path)?.split(separator: " ").last == inode }) {
            let folder = (moved.path as NSString).deletingLastPathComponent
            let realFolder = (real as NSString).deletingLastPathComponent
            // Named as the editor had it (/tmp, not /private/tmp) when it's the same folder.
            let to = folder == realFolder ? ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent((moved.path as NSString).lastPathComponent)
                : moved.path
            followRename(from: path, to: to)
            return
        }
        syncWithDisk()
    }

    /// Over ssh, whether the host's watch is reporting, in the header ("Live", or "Not Updating" when it isn't).
    private func updateWatchTag() {
        guard let remote = fs as? RemoteSession, let t = remoteWatch, t.belongs(to: remote.fileWatch) else {
            header.watchLive = nil
            return
        }
        header.watchLive = remote.fileWatch.live
    }

    /// On this Mac: a stat, and what it means (see `diskSignatureNow`). Over ssh the host's watch reports instead.
    func syncWithDisk() {
        guard !fs.isRemote, mode == .file, loaded, media == nil else { return }
        diskSignatureNow(LocalFileSystem.signature(path))
    }

    /// The file's signature on disk now (nil: it isn't there). If it changed from what was read or saved (its
    /// modified time, size or inode), the text catches up quietly (see `refreshFromDisk`), keeping the caret and
    /// scroll. With unsaved edits it only says so: they stay, and saving asks first.
    private func diskSignatureNow(_ sig: String?) {
        guard mode == .file, loaded, media == nil else { return }
        if sig != diskSignature, !refreshing, !saving {
            Diagnostics.log("changed \(diagName): \(sig.map { "size " + ($0.split(separator: " ").dropLast().last.map(String.init) ?? "?") } ?? "gone")\(isDirty ? " (has unsaved edits)" : "")")
        }
        // Busy reading or saving: look again in a moment (the host's watch reports a change only once).
        if refreshing || saving {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self else { return }
                self.fs.isRemote ? self.diskSignatureNow(sig) : self.syncWithDisk()
            }
            return
        }
        guard let sig else { return checkExists() }
        if isDeleted { checkExists() }
        guard sig != diskSignature else { return }
        // A big file's window: only one that reaches the end grows with it; otherwise just the scroller learns
        // the new size. Smaller than the window reaches: rotated or cut short, so the window again.
        if windowed, let size = sig.split(separator: " ").dropLast().last.flatMap({ Int($0) }) {
            let wasAtEnd = windowAtEnd
            fileSize = size
            fileScroller?.needsDisplay = true
            if size < diskSize {
                diskSignature = sig
                return loadText(keepPlace: true)
            }
            if !wasAtEnd {
                diskSignature = sig
                return
            }
        }
        if isDirty {
            changedOnDisk = true
            return
        }
        diskSignature = sig
        refreshFromDisk(changed: true)
    }

    /// The signature on disk now: a stat here, a command over ssh.
    private func currentSignature(_ done: @escaping (String?) -> Void) {
        if let remote = fs as? RemoteSession { remote.signature(path, done) } else { done(LocalFileSystem.signature(path)) }
    }

    /// Saving over a file that changed on disk since it was read: a bar over the file asks what to do.
    private func showConflict(then next: (() -> Void)?) {
        afterConflict = next
        changedOnDisk = true
        guard conflictBar == nil else { return }
        let name = (path as NSString).lastPathComponent
        let bar = EditorNoticeBar(title: "“\(name)” changed on disk", symbol: "exclamationmark.triangle.fill", actions: [
            ("Compare", { [weak self] in self?.toggleCompare() }),
            ("Overwrite", { [weak self] in self?.resolveConflict(overwrite: true) }),
            ("Revert", { [weak self] in self?.resolveConflict(overwrite: false) }),
            ("Cancel", { [weak self] in self?.endConflict() }),
        ])
        bar.toolTip = "Compare: what's on disk (left) beside your edits (right). Overwrite: save yours over it. Revert: drop yours and show what's on disk."
        bar.wantsLayer = true
        conflictBar = bar
        addSubview(bar)
        needsLayout = true
    }

    /// What's on disk on the left, the unsaved text on the right; again to go back to editing.
    private func toggleCompare() {
        if let v = compareView {
            v.removeFromSuperview()
            compareView = nil
            scroll.isHidden = false
            conflictBar?.setTitle("Compare", at: 0)
            window?.makeFirstResponder(textView)
            return
        }
        let mine = textView.string
        fs.read(path) { [weak self] result in
            guard let self, self.conflictBar != nil, self.compareView == nil else { return }
            let disk = (try? result.get()).map { String(decoding: Self.droppingCR($0).0, as: UTF8.self) } ?? ""
            let v = DiffView()
            v.show(old: disk, new: mine, language: self.language)
            self.compareView = v
            self.addSubview(v, positioned: .below, relativeTo: self.conflictBar)
            self.scroll.isHidden = true
            self.conflictBar?.setTitle("Back to Editing", at: 0)
            self.needsLayout = true
        }
    }

    private func resolveConflict(overwrite: Bool) {
        let next = afterConflict
        endConflict()
        if overwrite {
            save(force: true, then: next)
        } else {
            isDirty = false
            changedOnDisk = false
            loadText(keepPlace: true)
            next?()
        }
    }

    private func endConflict() {
        afterConflict = nil
        compareView?.removeFromSuperview()
        compareView = nil
        scroll.isHidden = false
        conflictBar?.removeFromSuperview()
        conflictBar = nil
        if window?.firstResponder == nil || window?.firstResponder === window { window?.makeFirstResponder(textView) }
    }

    /// Catches up with the file on disk: new bytes at the end are added (scrolling along if the end was in view,
    /// as with tail -f); anything else (rewritten, truncated, rotated) reloads it, keeping the place. Unsaved
    /// edits are never overwritten.
    /// `changed`: it's known to have changed (its stat did), so with nothing added at the end it's read again.
    func refreshFromDisk(changed: Bool = false) {
        guard mode == .file, loaded, media == nil, !isDirty, !refreshing, !saving else { return }
        refreshing = true
        let size = diskSize, tail = diskTail
        let from = max(0, size - tail.count)
        let asked = Date()
        fs.readPart(path, from: from, whole: 0, tail: fileTailSize) { [weak self] result in
            guard let self else { return }
            self.refreshing = false
            let applying = Date()
            guard case .success(let part) = result else {
                Diagnostics.log("update \(self.diagName): read failed after \(Diagnostics.ms(asked)) ms")
                return self.checkExists()
            }
            guard !self.isDirty else { return }
            // Reloaded while this was read (a revert, a rotated log, a save): that's newer than what this was
            // reading from, and the watch reports anything after it.
            guard self.diskSize == size, self.diskTail == tail else {
                Diagnostics.log("update \(self.diagName): dropped (reloaded while it was read)")
                return
            }
            if let sig = part.signature { self.diskSignature = sig }
            let known = size - from
            guard known >= 0, part.size >= size, part.data.count >= known, part.data.prefix(known) == tail else {
                Diagnostics.log("update \(self.diagName): the end no longer matches (size \(size) → \(part.size)): reloading the whole text")
                return self.loadText(keepPlace: true)
            }
            let added = Data(part.data.dropFirst(known).prefix(max(0, part.size - size)))
            // More arrived than one read brings: start again from the end.
            if part.size - self.diskSize > added.count {
                Diagnostics.log("update \(self.diagName): \(part.size - self.diskSize) bytes added, more than one read: reloading the whole text")
                return self.loadText(keepPlace: true)
            }
            guard !added.isEmpty else {
                // The same size and the same end: on a network drive often just its modified time catching up. Read
                // again in full only for a small file, where an edit in the middle at the same size (an agent's,
                // say) is worth catching and costs little; for a big one it'd move the view for nothing.
                guard changed, !self.windowed, part.size <= 1 << 20 else {
                    if changed { Diagnostics.log("update \(self.diagName): its time changed but not its size or end: nothing to do") }
                    return
                }
                Diagnostics.log("update \(self.diagName): changed but nothing added (size \(part.size)): reloading the whole text")
                return self.loadText(keepPlace: true)
            }
            defer {
                Diagnostics.log("update \(self.diagName): +\(added.count) bytes (now \(part.size)), read in \(Diagnostics.ms(asked)) ms, shown in \(Diagnostics.ms(applying)) ms\(self.liveScrolling ? " (DURING A SCROLL)" : "")\(self.tailing ? " tailing" : "")")
            }
            self.diskSize = part.size
            self.diskTail = Data((self.diskTail + added).suffix(256))
            let (whole, rest) = Self.splitUTF8(self.carry + added)
            self.carry = rest
            if self.windowed {
                self.fileSize = max(self.fileSize, part.size)
                if !self.winChunks.isEmpty {
                    let shown = String(decoding: Self.droppingCR(whole).0, as: UTF8.self)
                    self.winChunks[self.winChunks.count - 1].bytes += whole.count
                    self.winChunks[self.winChunks.count - 1].chars += (shown as NSString).length
                    self.winChunks[self.winChunks.count - 1].lines += Self.newlines(in: shown)
                }
            }
            let bytes = Self.droppingCR(whole).0
            let text = String(decoding: bytes, as: UTF8.self)
            guard !text.isEmpty, let storage = self.textView.textStorage else { return }
            if !self.textView.hidesEscapes, Self.hasEscapes(bytes) {
                self.textView.hidesEscapes = true
                if self.language == nil { self.language = .log; self.chooseLogFormat() }
            }
            // Whether to follow, decided before the text goes in (after, the end has moved away from the view).
            let follow = !self.liveScrolling && (self.tailing || self.atVeryEnd)
            // Not following: the line at the top stays there. In a long text only what's on screen is laid out and
            // the rest's height estimated (from its characters), so text added at the end can move what's above it
            // when lines differ a lot in length (a log's JSON lines): put the view back on that line.
            let anchor = follow ? nil : self.topAnchor()
            let end = storage.length
            storage.append(NSAttributedString(string: text, attributes: self.textView.typingAttributes))
            if self.language == .log {
                // Only what arrived (and the line it may finish) needs coloring.
                self.logPainted.remove(integersIn: max(0, end - 1)..<storage.length)
            } else if self.language != nil, storage.length <= SyntaxHighlighter.maxLength { self.highlightSyntax() }
            self.ruler.linesAppended(from: end)
            self.findTextChanged()
            // Following the end: with Tail File on, or from the very end (not a line or two above it: that's the user
            // having scrolled up, a little), and never while they're scrolling. Only their own scroll turns Tail
            // File off (see `userScrolled`).
            if follow { self.programmatically { self.textView.scrollToEndOfDocument(nil) } }
            else if let anchor { self.restoreTop(anchor, shift: 0) }
            if self.windowed {
                self.splitLastChunk()
                self.trimWindow(fromTop: true)
                self.fileScroller?.needsDisplay = true
            }
            self.paintVisibleLog()
        }
    }

    /// Local files preview in place; remote ones are copied to a temporary folder first, keeping their
    /// name so the extension still tells AppKit what they are.
    private func loadMedia(_ kind: MediaKind) {
        header.editable = false
        header.textTools = false
        guard fs.isRemote else { return showMedia(kind, URL(fileURLWithPath: path)) }
        showMessage("Loading…")
        fs.read(path, limit: maxPreviewFileSize) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let e):
                self.showMessage(e.localizedDescription)
            case .success(let data):
                let dir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("solanum-previews").appendingPathComponent(UUID().uuidString)
                let url = dir.appendingPathComponent((self.path as NSString).lastPathComponent)
                do {
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    try data.write(to: url)
                } catch {
                    return self.showMessage(error.localizedDescription)
                }
                self.mediaCopy = url
                self.showMedia(kind, url)
            }
        }
    }

    /// The left side is the index (`git show :file`: what's staged, else the last commit); a file git doesn't
    /// have yet diffs against nothing, and one deleted from disk against an empty right side. For staged changes
    /// (`.stagedDiff`) it's the last commit against the index: what committing would change.
    private func loadDiff() {
        let staged = mode == .stagedDiff
        var inCommit: String?
        if case .commitDiff(let hash) = mode { inCommit = hash }
        header.editable = false
        header.textTools = false
        if diffView == nil { showMessage("Loading…") }
        let name = (path as NSString).lastPathComponent
        let git = GitRunner(dir: (path as NSString).deletingLastPathComponent, remote: fs as? RemoteSession)
        let left = inCommit.map { "\($0)^:./" } ?? (staged ? "HEAD:./" : ":./")
        git.run("git show \(shellQuote(left + name)) 2>/dev/null") { [weak self] _, out, _ in
            guard let self else { return }
            let old = String(decoding: out, as: UTF8.self)
            func read(_ done: @escaping (Data?) -> Void) {
                if staged || inCommit != nil {
                    let right = inCommit.map { "\($0):./" } ?? ":./"
                    git.run("git show \(shellQuote(right + name)) 2>/dev/null") { status, data, _ in done(status == 0 ? data : nil) }
                } else {
                    self.fs.read(self.path) { done(try? $0.get()) }
                }
            }
            read { [weak self] data in
                guard let self else { return }
                let new = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
                let view = self.diffView ?? DiffView()
                if self.diffView == nil {
                    self.diffView = view
                    self.addSubview(view)
                    self.needsLayout = true
                    self.layoutSubtreeIfNeeded()
                }
                view.show(old: old, new: new, language: self.language)
                let sides = inCommit.map { "Parent ↔ \($0.prefix(8))" } ?? (staged ? "Last Commit ↔ Index" : "Index ↔ Working Tree")
                self.header.subtitle = "\(self.location) · \(sides) · \(view.summary)"
                self.message.isHidden = true
                self.scroll.isHidden = true
                if self.window?.firstResponder === self.window { self.focus() }
            }
        }
    }

    /// The Markdown file rendered as a page (see Markdown.swift), refreshed when it's saved.
    private func loadPreview() {
        header.editable = false
        header.textTools = false
        if previewView == nil { showMessage("Loading…") }
        fs.read(path) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let e):
                self.showMessage(e.localizedDescription)
            case .success(let data):
                let view = self.previewView ?? MarkdownPreviewView()
                if self.previewView == nil {
                    self.previewView = view
                    self.addSubview(view)
                    self.needsLayout = true
                    self.layoutSubtreeIfNeeded()
                }
                let folder = self.fs.isRemote ? nil : URL(fileURLWithPath: (self.path as NSString).deletingLastPathComponent, isDirectory: true)
                view.show(String(decoding: data, as: UTF8.self), folder: folder)
                self.message.isHidden = true
                self.scroll.isHidden = true
                if self.window?.firstResponder === self.window { self.focus() }
            }
        }
    }

    // MARK: Beautify

    /// ⌥⌘F or the header's button: JSON, YAML or XML re-indented (see `Prettifier`), as one step ⌘Z undoes.
    @objc func formatDocument(_ sender: Any?) {
        guard mode == .file, loaded, media == nil else { return NSSound.beep() }
        guard let language, language.canFormat else {
            header.status = "Can't beautify this kind of file"
            return clearStatus(after: 2.5)
        }
        let text = textView.string
        let ext = (path as NSString).pathExtension.lowercased()
        let formatted: String
        do {
            // .jsonc / .json5 allow comments and other relaxations, so they skip the strict check.
            formatted = try Prettifier.format(text, as: language, strictJSON: ext == "json" || ext == "geojson" || ext == "webmanifest")
        } catch {
            return presentAlert("Couldn't beautify “\((path as NSString).lastPathComponent)”", error.localizedDescription)
        }
        guard formatted != text else {
            header.status = "Already beautified"
            return clearStatus(after: 1.5)
        }
        let caret = textView.selectedRange().location
        let all = NSRange(location: 0, length: (text as NSString).length)
        textView.insertText(formatted, replacementRange: all)
        textView.setSelectedRange(NSRange(location: min(caret, (formatted as NSString).length), length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())
        header.status = "Beautified"
        clearStatus(after: 1.5)
    }

    private func clearStatus(after seconds: Double) {
        let shown = header.status
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            if self?.header.status == shown { self?.header.status = nil }
        }
    }

    /// The marketplace or an extension's page: made once, and kept (it loads and refreshes its own data).
    private func loadExtensionPage() {
        header.editable = false
        header.textTools = false
        // Its subtitle ("Sleeper · league · week") says where you are; there's no path to copy.
        header.onCopyPath = nil
        if pageView != nil { return }
        let page: (NSView & ExtensionPage)?
        switch mode {
        case .extensions: page = ExtensionsPageView()
        case .extensionPage(let id): page = Extensions.find(id)?.makePage()
        default: page = nil
        }
        guard let page else { return showMessage("This extension isn't available.") }
        pageView = page
        page.onSubtitleChanged = { [weak self, weak page] in
            guard let self, let page else { return }
            self.header.subtitle = page.subtitle
        }
        header.subtitle = page.subtitle
        message.isHidden = true
        scroll.isHidden = true
        addSubview(page)
        needsLayout = true
        layoutSubtreeIfNeeded()
        if window?.firstResponder === window { focus() }
    }

    /// Dev aid (DevTools hover-graph): the graph's card for `row`.
    func devHoverGraph(_ row: Int) { graphView?.devHover(row) }

    private func loadGraph() {
        header.editable = false
        header.textTools = false
        if let view = graphView { return view.reload() }
        showMessage("Loading…")
        let view = GitGraphView(runner: GitRunner(dir: path, remote: fs as? RemoteSession))
        graphView = view
        view.isHidden = true
        view.onViewChanges = { [weak self] hash in
            guard let self else { return }
            self.onOpenOther?(self.path, .commit(hash))
        }
        view.onFailed = { [weak self] message in
            guard let self, self.graphView?.isHidden != false else { return }
            self.showMessage(message)
        }
        view.onLoaded = { [weak self] count, filter in
            guard let self, let view = self.graphView else { return }
            let shown = count >= GraphCommit.limit ? "latest \(count) commits" : "\(count) commit\(count == 1 ? "" : "s")"
            let what = filter.isEmpty ? "all branches" : filter.branch.map { $0 == "HEAD" ? "HEAD" : $0 } ?? "filtered"
            self.header.subtitle = "\(self.location) · \(what) · \(shown)"
            if view.isHidden {
                view.isHidden = false
                self.message.isHidden = true
                self.scroll.isHidden = true
                if self.window?.firstResponder === self.window { self.focus() }
            }
        }
        addSubview(view)
        needsLayout = true
        layoutSubtreeIfNeeded()
        view.reload()
    }

    /// The repository's state as a page (GitStatusView.swift).
    private func loadStatus() {
        guard !statusLoading else { return }
        statusLoading = true
        header.editable = false
        header.textTools = false
        if statusView == nil { showMessage("Loading…") }
        let git = GitRunner(dir: path, remote: fs as? RemoteSession)
        var hash: String?
        if case .commit(let h) = mode { hash = h }
        git.run(hash.map(GitStatusReport.script(commit:)) ?? GitStatusReport.script, timeout: 30) { [weak self] status, out, err in
            guard let self else { return }
            self.statusLoading = false
            guard status == 0, let report = hash == nil ? GitStatusReport(output: out) : GitStatusReport(commitOutput: out) else {
                return self.showMessage(err.isEmpty ? "Couldn't read the repository's status." : err)
            }
            let view = self.statusView ?? GitStatusView(runner: git)
            if self.statusView == nil {
                self.statusView = view
                // A commit doesn't change.
                if hash == nil { view.onRefresh = { [weak self] in self?.load() } }
                view.onOpen = { [weak self] path, mode in self?.onOpenOther?(path, mode) }
                view.onRunInTerminal = { [weak self] command in
                    guard let self else { return }
                    self.onRunInTerminal?(command, self.path)
                }
                self.addSubview(view)
                self.needsLayout = true
                self.layoutSubtreeIfNeeded()
            }
            view.show(report)
            self.header.subtitle = self.location
            self.message.isHidden = true
            self.scroll.isHidden = true
            if self.window?.firstResponder === self.window { self.focus() }
        }
    }

    var devStatusView: GitStatusView? { statusView }
    var devGraphView: GitGraphView? { graphView }

    private func showMedia(_ kind: MediaKind, _ url: URL) {
        let view = MediaPreviewView(kind: kind, url: url)
        guard let info = view.info else { return showMessage("This file couldn't be opened.") }
        header.subtitle = "\(location) · \(info)"
        media = view
        message.isHidden = true
        scroll.isHidden = true
        addSubview(view)
        needsLayout = true
        if window?.firstResponder === textView || window?.firstResponder === window { focus() }
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        ruler.needsDisplay = true
    }

    func textDidChange(_ notification: Notification) {
        if loaded { isDirty = true }
        ruler.invalidateLines()
        findTextChanged()
        guard language != nil else { return }
        if language == .log { logPainted = IndexSet() }
        highlightGeneration += 1
        // Re-color once typing pauses rather than on every keystroke.
        pendingHighlight?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.highlightSyntax() }
        pendingHighlight = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// Whether these bytes hold an ANSI escape sequence (ESC [).
    private static func hasEscapes(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard var p = raw.baseAddress, raw.count > 1 else { return false }
            let end = raw.baseAddress! + raw.count
            while let hit = memchr(p, 0x1B, end - p) {
                let q = UnsafeRawPointer(hit)
                if q + 1 < end, q.load(fromByteOffset: 1, as: UInt8.self) == 0x5B { return true }
                p = q + 1
            }
            return false
        }
    }

    // MARK: Logs

    /// The format for this log: the one picked from the header's menu, else one that names the file or fits its
    /// first lines (see `LogFormats.choose`), else the built-in coloring.
    private func chooseLogFormat() {
        let formats = LogFormatStore.formats
        if let pick = logFormatPick {
            logFormat = pick == LogFormat.builtIn.name ? LogFormatStore.builtIn : formats.first { $0.name == pick }
            if logFormat != nil { return }
            logFormatPick = nil
        }
        let s = textView.textStorage?.mutableString ?? NSMutableString()
        var sample: [String] = []
        var at = 0
        while at < s.length, sample.count < 40 {
            let r = s.lineRange(for: NSRange(location: at, length: 0))
            sample.append(s.substring(with: r).trimmingCharacters(in: .newlines))
            at = NSMaxRange(r)
        }
        let chosen = LogFormats.choose(for: (path as NSString).lastPathComponent, sample: sample, among: formats)
        logFormat = chosen.file == nil ? LogFormatStore.builtIn : chosen
    }

    /// Colors the part of a log on screen (and a screen either side) that isn't yet; a smaller log all at once.
    private func paintVisibleLog() {
        guard language == .log, let format = logFormat, let storage = textView.textStorage, storage.length > 0,
              let lm = textView.layoutManager, let tc = textView.textContainer else { return }
        let target: NSRange
        if storage.length <= 300_000 {
            target = NSRange(location: 0, length: storage.length)
        } else {
            let visible = textView.visibleRect
            guard !visible.isEmpty else { return }
            let glyphs = lm.glyphRange(forBoundingRect: visible.insetBy(dx: 0, dy: -visible.height), in: tc)
            target = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        }
        guard let span = Range(target), !span.isEmpty else { return }
        let todo = IndexSet(integersIn: span).subtracting(logPainted)
        guard !todo.isEmpty else { return }
        let started = Date()
        storage.beginEditing()
        for r in todo.rangeView {
            let done = LogPainter.paint(storage, in: NSRange(r), format: format)
            if let d = Range(done) { logPainted.insert(integersIn: d) }
        }
        storage.endEditing()
        if ProcessInfo.processInfo.environment["SOLANUM_LOG_PAINT_DEBUG"] != nil {
            FileHandle.standardError.write("log paint: \(todo.count) chars in \(todo.rangeView.count) runs, \(Int(Date().timeIntervalSince(started) * 1000)) ms\n".data(using: .utf8)!)
        }
        textView.needsDisplay = true
    }

    /// The header's palette: which format colors this log, and importing another.
    private func showLogFormatMenu() {
        let menu = logFormatMenu()
        let r = header.rect(ofButton: "Log Coloring") ?? NSRect(x: header.bounds.maxX - 120, y: 0, width: 22, height: header.bounds.height)
        ThemedDropdown.show(menu, under: header, rect: r)
    }

    private func logFormatMenu() -> NSMenu {
        let menu = NSMenu()
        let auto = logFormatPick == nil
        let title = NSMenuItem(title: "Log Coloring", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(ActionMenuItem(auto ? "Automatic (\(logFormat?.name ?? LogFormat.builtIn.name))" : "Automatic", checked: auto) { [weak self] in
            self?.pickLogFormat(nil)
        })
        menu.addItem(.separator())
        for format in [LogFormat.builtIn] + LogFormatStore.formats {
            menu.addItem(ActionMenuItem(format.name, checked: !auto && logFormat?.name == format.name) { [weak self] in
                self?.pickLogFormat(format.name)
            })
        }
        menu.addItem(.separator())
        if let format = logFormat {
            LogColorMenu.add(to: menu, format: format, selection: logSelection(), window: window)
            menu.addItem(.separator())
        }
        menu.addItem(ActionMenuItem("Import Log Format…") { [weak self] in
            LogFormatStore.runImportPanel(for: self?.window) { self?.imported($0) }
        })
        menu.addItem(ActionMenuItem("Show Log Formats Folder") {
            try? FileManager.default.createDirectory(at: LogFormatStore.folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(LogFormatStore.folder)
        })
        return menu
    }

    private func pickLogFormat(_ name: String?) {
        logFormatPick = name
        chooseLogFormat()
        highlightSyntax()
    }

    /// A format was imported from this log's menu: it colors this log, picked if it wouldn't be chosen anyway.
    private func imported(_ format: LogFormat) {
        // Formats-changed has already chosen again; pick it only if that didn't land on it.
        if loaded, language == .log, logFormat?.name != format.name { pickLogFormat(format.name) }
        header.status = "Coloring with “\(format.name)”"
        clearStatus(after: 2.5)
    }

    /// The selected text, if it's short and on one line: offered as a marker.
    private func logSelection() -> String? {
        let r = textView.selectedRange()
        guard r.length > 0, r.length <= 200, let s = textView.textStorage?.mutableString, NSMaxRange(r) <= s.length else { return nil }
        let text = ANSIText.removing(s.substring(with: r)).trimmingCharacters(in: .whitespaces)
        return text.isEmpty || text.contains("\n") ? nil : text
    }

    func devEdgeDrag(fraction: CGFloat, seconds: Double) { textView.devEdgeDrag(fraction: fraction, seconds: seconds) }

    /// Dev aid: to the end, as a followed log sits.
    func devScrollToEnd() { textView.scrollToEndOfDocument(nil) }
    func devToggleTail() { tailing.toggle() }
    /// Dev aid: scrolls `steps` times by `dy` points (negative: up), as a scroll wheel would, drawing after each,
    /// and prints how long each step took.
    func devScrollSteps(_ steps: Int, _ dy: CGFloat, live: Bool = false) {
        if live { NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll) }
        // One step a frame (60 a second), as a fast trackpad scroll goes, so fetches land between them.
        var times: [Int] = []
        var left = steps
        var rows: [Int] = []
        func topRow() -> Int? {
            let t = self.devTopLine
            guard let r = t.range(of: #"row \d+"#, options: .regularExpression) else { return nil }
            return Int(t[r].dropFirst(4))
        }
        Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self, left > 0 else {
                timer.invalidate()
                if live, let self { NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: self.scroll) }
                let sorted = times.sorted()
                let deltas = zip(rows.dropFirst(), rows).map { $0 - $1 }
                let usual = deltas.isEmpty ? 0 : deltas.sorted()[deltas.count / 2]
                let odd = deltas.enumerated().filter { abs($0.element - usual) > 1 }
                FileHandle.standardError.write("scroll steps: \(times.count), median \(sorted.isEmpty ? 0 : sorted[sorted.count / 2]) ms, worst \(sorted.last ?? 0) ms, over 16 ms: \(times.filter { $0 > 16 }.count); rows per step \(usual), jumps: \(odd.count) \(odd.prefix(5).map { "step \($0.offset): \($0.element)" })\n".data(using: .utf8)!)
                return
            }
            left -= 1
            let t = Date()
            let o = self.scroll.contentView.bounds.origin
            let h0 = self.textView.frame.height, r0 = topRow()
            self.scroll.contentView.scroll(to: NSPoint(x: o.x, y: max(0, o.y + dy)))
            self.scroll.reflectScrolledClipView(self.scroll.contentView)
            let y1 = self.scroll.contentView.bounds.minY, h1 = self.textView.frame.height, r1 = topRow()
            self.window?.displayIfNeeded()
            let y2 = self.scroll.contentView.bounds.minY, h2 = self.textView.frame.height
            times.append(Int(Date().timeIntervalSince(t) * 1000))
            if let r = topRow() {
                if let prev = rows.last, r - prev > 1 || (r0 != nil && r0 != prev) {
                    FileHandle.standardError.write("jump at step \(steps - left): rows \(prev) → (before step \(r0 ?? -1)) → after scroll \(r1 ?? -1) → after display \(r); y \(Int(o.y)) → \(Int(y1)) → \(Int(y2)); height \(Int(h0)) → \(Int(h1)) → \(Int(h2))\n".data(using: .utf8)!)
                }
                rows.append(r)
            }
        }
    }

    /// Dev aid: selects `text`'s first occurrence (to offer it as a marker).
    func devSelect(_ text: String) {
        guard let s = textView.textStorage?.mutableString else { return }
        let r = s.range(of: text)
        if r.location != NSNotFound { textView.setSelectedRange(r) }
    }

    /// Dev aid (DevTools log-menu): the header's menu, or the submenu at `path` (titles joined by >), printed; an item
    /// at the end of the path that isn't a submenu is chosen.
    func devLogMenu(run path: String?) {
        var menu = logFormatMenu()
        func show(_ m: NSMenu) -> [String] { m.items.map { $0.isSeparatorItem ? "---" : ($0.state == .on ? "✓ " : "") + $0.title + ($0.submenu != nil ? " ›" : "") } }
        for part in (path ?? "").split(separator: ">").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            guard let i = menu.items.firstIndex(where: { $0.title == part || $0.title.hasPrefix(part + " (") }) ?? menu.items.firstIndex(where: {
                ($0.attributedTitle?.string ?? "").hasPrefix(part + " ")
            }) else {
                FileHandle.standardError.write("log menu: no “\(part)” in \(show(menu))\n".data(using: .utf8)!)
                return
            }
            if let sub = menu.items[i].submenu { menu = sub } else { menu.performActionForItem(at: i); return }
        }
        FileHandle.standardError.write("log menu: \(show(menu))\n".data(using: .utf8)!)
    }

    /// Dev aid: imports a format from a file, as the menu's Import does once a file is chosen.
    func devImportLogFormat(_ path: String) {
        do { imported(try LogFormatStore.importFile(URL(fileURLWithPath: path))) } catch {
            FileHandle.standardError.write("log import failed: \(error.localizedDescription)\n".data(using: .utf8)!)
        }
    }

    var devLogFormatName: String? { language == .log ? logFormat?.name : nil }

    /// The caret steps over a hidden escape sequence as over nothing, instead of seeming stuck on it.
    func textView(_ tv: NSTextView, willChangeSelectionFromCharacterRange old: NSRange, toCharacterRange new: NSRange) -> NSRange {
        guard textView.hidesEscapes, new.length == 0, let s = tv.textStorage?.mutableString, new.location < s.length,
              let r = ANSIText.escapeRange(s, around: new.location), r.location < new.location else { return new }
        return NSRange(location: new.location >= old.location ? NSMaxRange(r) : r.location, length: 0)
    }

    /// What Tab inserts here, and how wide a tab shows: the file's own indentation, else the settings (see
    /// `Indentation`); a Makefile or Go file with none yet takes tabs.
    private func updateIndentation() {
        let c = Config.shared
        let tabsByDefault = language == .code(.makefile) || (path as NSString).pathExtension.lowercased() == "go"
        textView.indentation = Indentation.detect(textView.string, spaces: c.editorInsertSpaces, size: c.editorTabSize, tabsByDefault: tabsByDefault)
    }

    private func highlightSyntax() {
        guard let language, let storage = textView.textStorage, storage.length > 0 else { return }
        if language == .log {
            logPainted = IndexSet()
            return paintVisibleLog()
        }
        highlightGeneration += 1
        let generation = highlightGeneration, theme = Config.shared.theme
        func paint(_ tokens: [(range: NSRange, token: SyntaxToken)]) {
            storage.beginEditing()
            storage.addAttribute(.foregroundColor, value: theme.foreground, range: NSRange(location: 0, length: storage.length))
            SyntaxHighlighter.paint(storage, tokens, theme: theme)
            storage.endEditing()
        }
        // A small file is scanned right here (no moment uncolored); a big one off the main thread, so typing in it
        // doesn't stall while it's scanned, and painted if nothing's changed since.
        guard storage.length > 40_000 else { return paint(SyntaxScanner.tokens(in: storage.string, as: language)) }
        let text = String(storage.string), length = storage.length
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let tokens = SyntaxScanner.tokens(in: text, as: language)
            DispatchQueue.main.async {
                guard let self, self.highlightGeneration == generation, storage.length == length else { return }
                paint(tokens)
            }
        }
    }

    @objc func saveDocument(_ sender: Any?) {
        save(then: nil)
    }

    /// `force`: save even over changes made on disk since it was read (Overwrite, from the conflict bar).
    private func save(force: Bool = false, then next: (() -> Void)?) {
        guard loaded, !saving else { return }
        // Changed on disk since it was read (not just deleted, which saving puts back): ask before writing over it.
        if !force, let known = diskSignature {
            saving = true
            currentSignature { [weak self] now in
                guard let self else { return }
                self.saving = false
                if let now, now != known { return self.showConflict(then: next) }
                self.write(then: next)
            }
            return
        }
        write(then: next)
    }

    private func write(then next: (() -> Void)?) {
        saving = true
        var text = textView.string
        if usesCRLF { text = text.replacingOccurrences(of: "\n", with: "\r\n") }
        let undoMark = textView.string
        header.status = "Saving…"
        fs.write(Data(text.utf8), to: path) { [weak self] error in
            guard let self else { return }
            if let error {
                self.saving = false
                self.header.status = nil
                self.presentAlert("Couldn't save “\((self.path as NSString).lastPathComponent)”", error.localizedDescription)
                return
            }
            // Only clean if nothing was typed while the save was in flight.
            if self.textView.string == undoMark { self.isDirty = false }
            self.isDeleted = false
            // Our own write isn't a change to catch up with.
            let saved = Data(text.utf8)
            self.diskSize = saved.count
            self.diskTail = Data(saved.suffix(256))
            self.carry = Data()
            // Our own write: its signature is what's on disk now, so the change it makes is nothing new. Still saving
            // until it's known, so the watch doesn't take the write for someone else's.
            self.currentSignature { [weak self] sig in
                self?.diskSignature = sig
                self?.saving = false
            }
            self.changedOnDisk = false
            self.endConflict()
            NotificationCenter.default.post(name: .solanumFileSaved, object: self.fs, userInfo: ["path": self.path])
            self.header.status = "Saved"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                if self?.header.status == "Saved" { self?.header.status = nil }
            }
            next?()
        }
    }

    /// Notices the file going (or coming back). Over ssh only while connected: a dropped connection isn't a deletion.
    func checkExists() {
        guard mode == .file, loaded || media != nil, !saving, !checkingExists else { return }
        let checked = path
        if !fs.isRemote {
            isDeleted = !FileManager.default.fileExists(atPath: checked)
            return
        }
        guard (fs as? RemoteSession)?.isConnected == true else { return }
        checkingExists = true
        let name = (checked as NSString).lastPathComponent
        fs.list((checked as NSString).deletingLastPathComponent) { [weak self] result in
            guard let self else { return }
            self.checkingExists = false
            guard self.path == checked, (self.fs as? RemoteSession)?.isConnected == true else { return }
            switch result {
            case .success(let items): self.isDeleted = !items.contains { $0.name == name && !$0.isDeleted }
            // The folder itself can't be listed: gone along with the file, unless the connection is what failed.
            case .failure(let e): if e.localizedDescription.lowercased().contains("no such file") { self.isDeleted = true }
            }
        }
    }

    var devIsDeleted: Bool { isDeleted }
    /// Dev aids (DevTools print-editor-text, editor-insert, editor-save, editor-conflict): the text shown, whether
    /// it's unsaved, changed on disk, can be undone, and the conflict bar; typing at the caret; saving; the bar's buttons.
    var devTextState: String {
        "\(textView.string.debugDescription.prefix(120)) dirty=\(isDirty) changedOnDisk=\(changedOnDisk) undo=\(textView.undoManager?.canUndo ?? false)"
            + " bar=\(conflictBar.map { "\($0.titles)" } ?? "none") compare=\(compareView.map { $0.summary } ?? "none") path=\(path)"
    }
    func devInsert(_ text: String) { textView.insertText(text, replacementRange: textView.selectedRange()) }
    func devSave() { save(then: nil) }

    /// Dev aid: a scroll gesture as AppKit announces one (start, a few steps up, end), as a trackpad would.
    func devLiveScroll() {
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        for _ in 0..<5 {
            let o = scroll.contentView.bounds.origin
            scroll.contentView.scroll(to: NSPoint(x: o.x, y: max(0, o.y - 200)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
            NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        }
    }

    /// For the diagnostics log: the file's name, and its host when it's over ssh.
    private var diagName: String {
        let name = (path as NSString).lastPathComponent
        return fs.isRemote ? "\(fs.hostLabel ?? "ssh"):\(name)" : name
    }
    /// Dev aid: how the text ends, and how many "line N" rows it has (to compare with the file).
    var devTextEnd: String {
        let t = textView.string
        return "ends \(String(t.suffix(60)).debugDescription), \(t.components(separatedBy: "] - line ").count - 1) appended rows, \(t.utf8.count) bytes"
    }
    /// Dev aid: a catch-up still on its way (a slow read) when the file's reloaded shorter (a rotated log).
    func devRefreshRace() {
        try? (String(repeating: "old line\n", count: 200) + "more\n").write(toFile: path, atomically: false, encoding: .utf8)
        (fs as? DevSlowFileSystem)?.slowNextRead = 1
        refreshFromDisk(changed: true)
        try? "rotated\n".write(toFile: path, atomically: false, encoding: .utf8)
        loadText(keepPlace: true)
    }
    func devConflict(_ title: String) { conflictBar?.devPress(title) }
    /// The ssh watch tag as it would show (a local file has none): "live", "off", or anything else for none.
    func devWatchTag(_ state: String) { header.watchLive = state == "live" ? true : state == "off" ? false : nil }

    /// Clicking the path in the header copies it in full (not the ~-abbreviated form shown).
    private func copyPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        guard !saving else { return }
        header.status = "Copied \(path)"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            if self?.header.status?.hasPrefix("Copied") == true { self?.header.status = nil }
        }
    }

    private func presentAlert(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        if let w = window { alert.beginSheetModal(for: w) } else { alert.runModal() }
    }

    // MARK: Closing

    /// Asks to save unsaved changes, then calls `done(true)` if the editor may go away.
    func confirmDiscard(_ done: @escaping (Bool) -> Void) {
        guard isDirty, let w = window else { return done(true) }
        let alert = NSAlert()
        alert.messageText = "Save changes to “\((path as NSString).lastPathComponent)”?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        alert.beginSheetModal(for: w) { [weak self] resp in
            switch resp {
            case .alertFirstButtonReturn: self?.save { done(true) }
            case .alertThirdButtonReturn: done(true)
            default: done(false)
            }
        }
    }

    func requestClose() {
        confirmDiscard { [weak self] ok in
            if ok { self?.onClose?() }
        }
    }

    /// ⌘W while the editor has focus closes the editor, not the terminal pane.
    @objc func closePane(_ sender: Any?) { requestClose() }

    // MARK: Find and wrap

    private var findBar: EditorFindBar?
    private var findMatches: [NSRange] = []
    private var findCapped = false
    /// Which match is current; nil with none.
    private var findIndex: Int?
    /// Where the search started, so typing more refines it from there rather than wandering down the file.
    private var findAnchor = 0
    private var findGeneration = 0
    private var pendingFind: DispatchWorkItem?
    /// What the highlights were last put on, to take them off again.
    private var highlightedRange = NSRange(location: 0, length: 0)

    /// ⌘F: the bar, with what's selected to search for, as in VS Code. Again: back to its field.
    @objc func showFind(_ sender: Any?) {
        if mode == .graph, let graphView { return graphView.focusSearch() }
        if mode == .preview, let previewView { return showPreviewFind(previewView) }
        guard mode == .file, media == nil, loaded else { return }
        let selection = textView.selectedRange()
        findAnchor = selection.location
        if findBar == nil {
            let bar = EditorFindBar()
            bar.canReplace = textView.isEditable
            bar.onQueryChange = { [weak self] in self?.scheduleFind(select: true) }
            bar.onStep = { [weak self] d in self?.stepFind(d) }
            bar.onClose = { [weak self] in self?.closeFind() }
            bar.onReplace = { [weak self] in self?.replaceCurrent() }
            bar.onReplaceAll = { [weak self] in self?.replaceAll() }
            addSubview(bar)
            findBar = bar
            needsLayout = true
            layoutSubtreeIfNeeded()
        }
        guard let bar = findBar else { return }
        if selection.length > 0, selection.length < 200 {
            let picked = (textView.string as NSString).substring(with: selection)
            if !picked.contains("\n") { bar.field.stringValue = picked }
        }
        bar.focus()
        scheduleFind(select: true, after: 0)
    }

    @objc func findNext(_ sender: Any?) { stepFromMenu(1) }
    @objc func findPrevious(_ sender: Any?) { stepFromMenu(-1) }

    /// A Markdown preview's find, with the same bar (and Aa / ab / .*) as the file's: matches marked in the page.
    private func showPreviewFind(_ preview: MarkdownPreviewView) {
        if findBar == nil {
            let bar = EditorFindBar()
            bar.canReplace = false
            bar.onQueryChange = { [weak self, weak preview] in
                guard let self, let preview, let bar = self.findBar else { return }
                let q = bar.field.stringValue
                preview.find(q, EditorFindBar.lastOptions) { [weak bar] n in
                    guard let bar else { return }
                    if q.isEmpty { return bar.setCount(nil) }
                    if n < 0 { return bar.setCount("Invalid", problem: true) }
                    if n == 0 { return bar.setCount("No results", problem: true) }
                    bar.setCount("1 of \(n)\(n >= 10000 ? "+" : "")")
                }
            }
            bar.onStep = { [weak self, weak preview] d in
                guard let preview, let bar = self?.findBar, !bar.field.stringValue.isEmpty else { return }
                let total = bar.countText.split(separator: " ").last.map(String.init) ?? ""
                preview.findStep(d) { i in if i > 0 { bar.setCount("\(i) of \(total)") } }
            }
            bar.onClose = { [weak self, weak preview] in
                preview?.clearFind()
                self?.findBar?.removeFromSuperview()
                self?.findBar = nil
                self?.window?.makeFirstResponder(preview)
            }
            addSubview(bar)
            findBar = bar
            needsLayout = true
            layoutSubtreeIfNeeded()
        }
        findBar?.focus()
        findBar?.onQueryChange?()
    }

    /// ⌘G with the bar closed opens it first.
    private func stepFromMenu(_ d: Int) {
        if mode == .preview {
            if findBar == nil { return showFind(nil) }
            return findBar?.onStep?(d) ?? ()
        }
        guard mode == .file, media == nil else { return }
        if findBar == nil { return showFind(nil) }
        stepFind(d)
    }

    private func closeFind() {
        pendingFind?.cancel()
        findGeneration += 1
        if let i = findIndex, findMatches.indices.contains(i), NSMaxRange(findMatches[i]) <= (textView.string as NSString).length {
            textView.setSelectedRange(findMatches[i])
        }
        findBar?.removeFromSuperview()
        findBar = nil
        findMatches = []
        findIndex = nil
        refreshFindHighlights()
        window?.makeFirstResponder(textView)
    }

    /// The text to search, made once and kept until the text changes.
    private var findBuffer: FindBuffer?
    /// Below this a plain search runs as the key is typed; it takes less than a frame.
    private static let instantFindLength = 2_000_000

    private func currentFindBuffer() -> FindBuffer {
        let text = textView.string as NSString
        if let b = findBuffer, b.chars.count == text.length { return b }
        let b = FindBuffer(text)
        findBuffer = b
        return b
    }

    /// The file's text changed; a search that's showing follows it.
    private func findTextChanged() {
        findBuffer = nil
        if findBar != nil { scheduleFind(select: false) }
    }

    /// A plain search on an ordinary file happens right here, so there's nothing to wait for. A big file or a regular
    /// expression (which can take any amount of time) goes off the main queue, and only the latest search counts.
    private func scheduleFind(select: Bool, after delay: TimeInterval? = nil) {
        pendingFind?.cancel()
        findGeneration += 1
        let generation = findGeneration
        guard let bar = findBar else { return }
        let query = bar.field.stringValue, options = bar.options
        guard !query.isEmpty else {
            findMatches = []
            findIndex = nil
            bar.setCount(nil)
            return refreshFindHighlights()
        }
        let plain = FindBuffer.canSearch(query, options)
        let finish: ([NSRange], Bool) -> Void = { [weak self] ranges, capped in
            guard let self, self.findGeneration == generation else { return }
            self.findMatches = ranges
            self.findCapped = capped
            // Typing: the first match from where it started. An edit in the file: the one the caret's at.
            let from = select ? self.findAnchor : self.textView.selectedRange().location
            self.findIndex = EditorFind.index(of: ranges, from: from)
            if select { self.showCurrentMatch() }
            self.updateFindCount()
            self.refreshFindHighlights()
        }
        let buffer = currentFindBuffer()
        if plain, buffer.chars.count < Self.instantFindLength {
            let (ranges, capped) = buffer.matches(of: query, options)
            return finish(ranges, capped)
        }
        let expression: NSRegularExpression?
        if plain {
            expression = nil
        } else {
            do {
                expression = try EditorFind.expression(query, options)
            } catch {
                findMatches = []
                findIndex = nil
                bar.setCount("Invalid regex", problem: true)
                return refreshFindHighlights()
            }
        }
        buffer.prepare(matchCase: options.matchCase)
        // A copy for the regex engine, which needs a string: the text view's own changes as it's edited.
        let text = expression == nil ? nil : (textView.string as NSString).copy() as? NSString
        let work = DispatchWorkItem {
            DispatchQueue.global(qos: .userInitiated).async {
                let (ranges, capped) = expression.flatMap { e in text.map { EditorFind.matches(of: e, in: $0 as String) } } ?? buffer.matches(of: query, options)
                DispatchQueue.main.async { finish(ranges, capped) }
            }
        }
        pendingFind = work
        let wait = delay ?? (plain ? 0.03 : 0.08)
        if wait == 0 { work.perform() } else { DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work) }
    }

    private func updateFindCount() {
        guard let bar = findBar else { return }
        if bar.field.stringValue.isEmpty { return bar.setCount(nil) }
        guard let i = findIndex else { return bar.setCount("No results", problem: true) }
        bar.setCount("\(i + 1) of \(findMatches.count)\(findCapped ? "+" : "")")
    }

    private func stepFind(_ d: Int) {
        guard !findMatches.isEmpty else { return }
        let i = findIndex ?? 0
        findIndex = (i + d + findMatches.count) % findMatches.count
        findAnchor = findMatches[findIndex ?? 0].location
        showCurrentMatch()
        updateFindCount()
        refreshFindHighlights()
    }

    /// In view, and selected if the focus is in the text. From the bar its highlight shows it: a selection would be
    /// drawn over that, grey in a text view without the focus. Closing the bar selects it.
    private func showCurrentMatch() {
        guard let i = findIndex, findMatches.indices.contains(i) else { return }
        if window?.firstResponder === textView { textView.setSelectedRange(findMatches[i]) }
        textView.scrollRangeToVisible(findMatches[i])
    }

    /// Every match on screen shaded, the current one brighter. Only what's on screen, which a file of very long lines
    /// can still make thousands, so only so many of those.
    private func refreshFindHighlights() {
        guard let lm = textView.layoutManager, let tc = textView.textContainer else { return }
        if highlightedRange.length > 0, NSMaxRange(highlightedRange) <= (textView.string as NSString).length {
            lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: highlightedRange)
            lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: highlightedRange)
        }
        highlightedRange = NSRange(location: 0, length: 0)
        guard findBar != nil, !findMatches.isEmpty else { return }
        let th = Config.shared.theme
        let glyphs = lm.glyphRange(forBoundingRect: textView.visibleRect, in: tc)
        let visible = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        highlightedRange = visible
        guard let first = EditorFind.index(of: findMatches, from: visible.location) else { return }
        var i = first
        // The search wraps to the start when nothing's at or past the screen's top; so must this.
        guard findMatches[i].location >= visible.location else { return }
        let stop = i + 1000
        while i < findMatches.count, i < stop, findMatches[i].location < NSMaxRange(visible) {
            let r = findMatches[i]
            let current = i == findIndex
            lm.addTemporaryAttribute(.backgroundColor, value: current ? th.accent : th.accent.withAlphaComponent(th.isDark ? 0.28 : 0.24), forCharacterRange: r)
            // On the solid accent, whichever of black and white reads.
            if current { lm.addTemporaryAttribute(.foregroundColor, value: th.accent.luminance > 0.55 ? NSColor.black : NSColor.white, forCharacterRange: r) }
            i += 1
        }
    }

    private func replaceCurrent() {
        guard let bar = findBar, textView.isEditable, let i = findIndex, findMatches.indices.contains(i),
              let e = try? EditorFind.expression(bar.field.stringValue, bar.options) else { return }
        let range = findMatches[i]
        let text = textView.string
        guard let m = e.firstMatch(in: text, range: range), m.range == range else { return scheduleFind(select: false, after: 0) }
        let new = EditorFind.replacement(bar.replaceField.stringValue, for: m, in: text, e, regex: bar.options.regex)
        textView.insertText(new, replacementRange: range)
        // On to the next match, past what was just put in.
        findAnchor = range.location + (new as NSString).length
        scheduleFind(select: true, after: 0)
        window?.makeFirstResponder(bar.replaceField)
    }

    private func replaceAll() {
        guard let bar = findBar, textView.isEditable, !findMatches.isEmpty,
              let e = try? EditorFind.expression(bar.field.stringValue, bar.options) else { return }
        let text = textView.string
        let all = NSRange(location: 0, length: (text as NSString).length)
        let template = bar.options.regex ? bar.replaceField.stringValue : NSRegularExpression.escapedTemplate(for: bar.replaceField.stringValue)
        let count = e.numberOfMatches(in: text, range: all)
        let caret = textView.selectedRange().location
        // As one step that ⌘Z undoes.
        textView.insertText(e.stringByReplacingMatches(in: text, range: all, withTemplate: template), replacementRange: all)
        textView.setSelectedRange(NSRange(location: min(caret, (textView.string as NSString).length), length: 0))
        findAnchor = textView.selectedRange().location
        header.status = "Replaced \(count)"
        clearStatus(after: 2)
        scheduleFind(select: false, after: 0)
    }

    var devFindBar: EditorFindBar? { findBar }

    /// Dev aid (DevTools editor-key): a key as the text view takes it: tab, backtab, backspace, start (caret to the
    /// very start), all (select everything).
    func devKey(_ key: String) {
        switch key {
        case "tab": textView.insertTab(nil)
        case "backtab": textView.insertBacktab(nil)
        case "backspace": textView.deleteBackward(nil)
        case "start": textView.setSelectedRange(NSRange(location: 0, length: 0))
        case "all": textView.selectAll(nil)
        default: break
        }
        FileHandle.standardError.write("editor after \(key): \(textView.string.debugDescription) indent \(textView.indentation)\n".data(using: .utf8)!)
    }
    var devFindState: String {
        let current = findIndex.map { (textView.string as NSString).substring(with: findMatches[$0]) } ?? ""
        return "count=\(findIndex.map { "\($0 + 1)" } ?? "-") of \(findMatches.count) current='\(current)'"
    }
    func devCloseFind() { closeFind() }
    /// The whole of a keystroke: search, jump, highlights and the redraw.
    func devFindLatency(_ q: String) -> String {
        guard let bar = findBar else { return "no bar" }
        bar.field.stringValue = q
        let t0 = CACurrentMediaTime()
        bar.onQueryChange?()
        let t1 = CACurrentMediaTime()
        window?.displayIfNeeded()
        let t2 = CACurrentMediaTime()
        stepFind(1)
        let t3 = CACurrentMediaTime()
        window?.displayIfNeeded()
        let t4 = CACurrentMediaTime()
        func ms(_ a: Double, _ b: Double) -> String { String(format: "%.1fms", (b - a) * 1000) }
        return "'\(q)' \(findMatches.count) matches, wraps=\(wraps): find+jump+highlight=\(ms(t0, t1)) draw=\(ms(t1, t2)) | step=\(ms(t2, t3)) draw=\(ms(t3, t4))"
    }
    func devFindMillis(_ q: String, _ o: EditorFindOptions) -> String {
        let t0 = CACurrentMediaTime()
        let b = FindBuffer((textView.string as NSString).copy() as! NSString)
        let t1 = CACurrentMediaTime()
        let plain = b.matches(of: q, o)
        let t2 = CACurrentMediaTime()
        let again = b.matches(of: q, o)
        let t3 = CACurrentMediaTime()
        let regex = (try? EditorFind.expression(q, o)).map { EditorFind.matches(of: $0, in: textView.string) }
        let t4 = CACurrentMediaTime()
        func ms(_ a: Double, _ b: Double) -> String { String(format: "%.2fms", (b - a) * 1000) }
        return "chars=\(b.chars.count) copy=\(ms(t0, t1)) plain=\(ms(t1, t2)) again=\(ms(t2, t3)) (\(again.ranges.count)) regex=\(ms(t3, t4)) (\(regex?.ranges.count ?? -1)) plainCount=\(plain.ranges.count)"
    }
    func devStepFind(_ d: Int) { stepFind(d) }
    func devReplace(all: Bool) { all ? replaceAll() : replaceCurrent() }

    @objc func toggleWrap(_ sender: Any?) {
        guard media == nil, mode == .file else { return }
        wraps.toggle()
        applyWrap()
    }

    private func applyWrap() {
        guard let container = textView.textContainer else { return }
        header.wraps = wraps
        scroll.hasHorizontalScroller = !wraps
        textView.isHorizontallyResizable = !wraps
        container.widthTracksTextView = wraps
        if wraps {
            textView.frame.size.width = scroll.contentSize.width
            container.size = NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
        } else {
            container.size = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        }
        ruler.invalidateLines()
    }
}

/// What an editor shows: a file to edit, a file's uncommitted changes (Diff.swift), a repository's history
/// (GitGraph.swift), or a Markdown file rendered (Markdown.swift).
enum EditorMode: Equatable { case file, diff, stagedDiff, graph, status, preview
    /// One commit's files (GitStatusView.swift), and one of its files side by side.
    case commit(String), commitDiff(String)
    /// The extensions marketplace, and an installed extension's page (Extensions.swift).
    case extensions, extensionPage(String)

    var isExtensionPage: Bool {
        switch self {
        case .extensions, .extensionPage: return true
        default: return false
        }
    }
}

/// ⌥Z toggles wrapping, as in VS Code.
final class EditorTextView: NSTextView, NSLayoutManagerDelegate {
    /// The text has ANSI escape sequences (a log written with colors): they take no room and aren't drawn (the
    /// log painter shows their colors), and copying leaves them out. The file keeps them.
    var hidesEscapes = false {
        didSet {
            guard hidesEscapes != oldValue, let lm = layoutManager, let n = textStorage?.length, n > 0 else { return }
            lm.invalidateGlyphs(forCharacterRange: NSRange(location: 0, length: n), changeInLength: 0, actualCharacterRange: nil)
        }
    }

    func layoutManager(_ lm: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties props: UnsafePointer<NSLayoutManager.GlyphProperty>, characterIndexes chars: UnsafePointer<Int>,
                       font: NSFont, forGlyphRange range: NSRange) -> Int {
        guard hidesEscapes, let s = lm.textStorage?.mutableString else { return 0 }
        var changed: [NSLayoutManager.GlyphProperty]?
        for k in 0..<range.length where ANSIText.escapeStart(s, chars[k]) != nil {
            if changed == nil { changed = Array(UnsafeBufferPointer(start: props, count: range.length)) }
            changed![k] = .null
        }
        guard let changed else { return 0 }
        changed.withUnsafeBufferPointer { lm.setGlyphs(glyphs, properties: $0.baseAddress!, characterIndexes: chars, font: font, forGlyphRange: range) }
        return range.length
    }

    /// A log's error and warning tints, across the whole width, under the text and the selection.
    override func draw(_ dirtyRect: NSRect) {
        if let lm = layoutManager, let tc = textContainer, let storage = textStorage, storage.length > 0 {
            let origin = textContainerOrigin
            let glyphs = lm.glyphRange(forBoundingRect: dirtyRect.offsetBy(dx: -origin.x, dy: -origin.y), in: tc)
            let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            storage.enumerateAttribute(.solanumLogWash, in: chars) { value, r, _ in
                guard let color = value as? NSColor else { return }
                color.setFill()
                lm.enumerateLineFragments(forGlyphRange: lm.glyphRange(forCharacterRange: r, actualCharacterRange: nil)) { rect, _, _, _, _ in
                    NSRect(x: self.bounds.minX, y: rect.minY + origin.y, width: self.bounds.width, height: rect.height).fill(using: .sourceOver)
                }
            }
        }
        super.draw(dirtyRect)
    }

    // MARK: Scrolling sideways while selecting

    /// While a selection is being dragged out (NSTextView tracks it inside `mouseDown`), a timer scrolls sideways
    /// whenever the pointer is near the left or right edge (or past it), and nudges the drag along so the selection
    /// follows. AppKit's own autoscroll only goes when the pointer moves past the edge, which it can't with the
    /// window against the side of the screen.
    private var edgeTimer: Timer?
    /// Dev aid: where the pointer is (in the window) for a drag that isn't a real one.
    var devPointer: NSPoint?

    override func mouseDown(with e: NSEvent) {
        edgeTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.edgeScrollTick() }
        // .common includes the event-tracking mode NSTextView's drag loop runs in.
        RunLoop.current.add(timer, forMode: .common)
        edgeTimer = timer
        super.mouseDown(with: e)
        // Back here once the button is up.
        edgeTimer?.invalidate()
        edgeTimer = nil
    }

    private func edgeScrollTick() {
        guard let w = window, let clip = enclosingScrollView?.contentView, isHorizontallyResizable else { return }
        let loc = devPointer ?? w.mouseLocationOutsideOfEventStream
        guard devPointer != nil || NSEvent.pressedMouseButtons & 1 != 0 else { return }
        let p = clip.convert(loc, from: nil)
        let b = clip.bounds, edge: CGFloat = 30
        func clamped(_ x: CGFloat) -> CGFloat { clip.constrainBoundsRect(NSRect(x: x, y: b.minY, width: b.width, height: b.height)).minX }
        // Faster the nearer the edge (and past it), up to a screenful a second or so.
        var dx: CGFloat = 0
        if p.x > b.maxX - edge { dx = min(60, 6 + (p.x - (b.maxX - edge)) * 1.2) }
        else if p.x < b.minX + edge { dx = -min(60, 6 + ((b.minX + edge) - p.x) * 1.2) }
        guard dx != 0 else { return }
        let x = clamped(b.minX + dx)
        guard x != b.minX else { return }
        clip.scroll(to: NSPoint(x: x, y: b.minY))
        enclosingScrollView?.reflectScrolledClipView(clip)
        // The text under the pointer changed: the drag loop extends the selection to it on its next event.
        if let ev = NSEvent.mouseEvent(with: .leftMouseDragged, location: loc, modifierFlags: NSEvent.modifierFlags,
                                       timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                                       context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
            NSApp.postEvent(ev, atStart: false)
        }
    }

    /// Dev aid (DevTools editor-edge-drag): presses at the start of the first line, holds the pointer at `fraction` of
    /// the visible width for `seconds` (through NSTextView's own drag loop), lets go, and prints where it got to.
    func devEdgeDrag(fraction: CGFloat, seconds: Double) {
        guard let clip = enclosingScrollView?.contentView, let w = window else { return }
        let b = clip.bounds
        let start = clip.convert(NSPoint(x: b.minX + 60, y: b.minY + 20), to: nil)
        let held = clip.convert(NSPoint(x: b.minX + b.width * fraction, y: b.minY + 20), to: nil)
        devPointer = held
        func event(_ type: NSEvent.EventType, _ at: NSPoint) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        if let drag = event(.leftMouseDragged, held) { NSApp.postEvent(drag, atStart: false) }
        // Lets go of the button only after the up event, as a real drag does.
        let up = Timer(timeInterval: seconds, repeats: false) { _ in if let e = event(.leftMouseUp, held) { NSApp.postEvent(e, atStart: false) } }
        RunLoop.current.add(up, forMode: .common)
        if let down = event(.leftMouseDown, start) { mouseDown(with: down) }
        devPointer = nil
        FileHandle.standardError.write("edge drag: x \(Int(clip.bounds.minX)) selected \(selectedRange().length)\n".data(using: .utf8)!)
    }

    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard hidesEscapes, let s = textStorage?.mutableString else { return super.writeSelection(to: pboard, types: types) }
        let text = selectedRanges.map { s.substring(with: $0.rangeValue) }.joined(separator: "\n")
        pboard.declareTypes([.string], owner: nil)
        return pboard.setString(ANSIText.removing(text), forType: .string)
    }

    /// Something floats over the text here (the find bar), which picks the cursor: a text view that has the focus sets
    /// its I-beam on every mouse move, wherever the mouse is.
    var coveredBy: ((NSPoint) -> Bool)?

    override func mouseMoved(with e: NSEvent) {
        if coveredBy?(e.locationInWindow) == true { return NSCursor.pointingHand.set() }
        super.mouseMoved(with: e)
    }

    override func cursorUpdate(with e: NSEvent) {
        if coveredBy?(e.locationInWindow) == true { return NSCursor.pointingHand.set() }
        super.cursorUpdate(with: e)
    }

    /// What Tab inserts and how wide a level is (see `FileEditorView.updateIndentation`).
    var indentation = Indentation(tabs: false, size: 4)

    /// The line (as a range) and its text holding `location`.
    private func line(at location: Int) -> NSRange {
        (string as NSString).lineRange(for: NSRange(location: location, length: 0))
    }

    /// Tab: spaces to the next tab stop (or a tab, in a file indented with tabs). With lines selected, they're
    /// indented a level instead, as in VS Code.
    override func insertTab(_ sender: Any?) {
        let sel = selectedRange()
        let ns = string as NSString
        if sel.length > 0, ns.substring(with: sel).contains("\n") { return shiftLines(by: 1) }
        guard !indentation.tabs else { return super.insertTab(sender) }
        let lineStart = line(at: sel.location).location
        let col = indentation.column(of: ns.substring(with: NSRange(location: lineStart, length: sel.location - lineStart)).utf16[...],
                                     upTo: sel.location - lineStart)
        insertText(indentation.spaces(at: col), replacementRange: sel)
    }

    /// ⇧Tab: the line (or every selected line) a level back.
    override func insertBacktab(_ sender: Any?) { shiftLines(by: -1) }

    /// Backspace in a line's leading spaces takes them back to the tab stop before, as Tab put them in.
    override func deleteBackward(_ sender: Any?) {
        let sel = selectedRange()
        guard !indentation.tabs, sel.length == 0, sel.location > 0 else { return super.deleteBackward(sender) }
        let ns = string as NSString
        let lineStart = line(at: sel.location).location
        let before = ns.substring(with: NSRange(location: lineStart, length: sel.location - lineStart))
        guard before.count >= 2, before.allSatisfy({ $0 == " " }) else { return super.deleteBackward(sender) }
        let n = indentation.backspace(at: before.count, spacesBefore: before.count)
        insertText("", replacementRange: NSRange(location: sel.location - n, length: n))
    }

    /// Indents (`by` 1) or outdents (-1) every line the selection touches by a level, as one step ⌘Z undoes, keeping
    /// them selected.
    private func shiftLines(by direction: Int) {
        let ns = string as NSString
        let sel = selectedRange()
        // A selection ending at a line's start doesn't take that line in.
        let endProbe = sel.length > 0 && sel.location + sel.length > 0 && ns.character(at: sel.location + sel.length - 1) == 10
            ? sel.location + sel.length - 1 : sel.location + sel.length
        let range = ns.lineRange(for: NSRange(location: sel.location, length: max(0, endProbe - sel.location)))
        let unit = indentation.tabs ? "\t" : String(repeating: " ", count: indentation.size)
        var lines = ns.substring(with: range).components(separatedBy: "\n")
        let trailing = lines.last == "" ? lines.removeLast() : nil
        var firstDelta = 0
        for (i, l) in lines.enumerated() {
            var next = l
            if direction > 0 {
                if !l.isEmpty { next = unit + l }
            } else if l.hasPrefix("\t") {
                next = String(l.dropFirst())
            } else {
                next = String(l.dropFirst(min(indentation.size, l.prefix { $0 == " " }.count)))
            }
            if i == 0 { firstDelta = (next as NSString).length - (l as NSString).length }
            lines[i] = next
        }
        let text = lines.joined(separator: "\n") + (trailing != nil ? "\n" : "")
        guard text != ns.substring(with: range), shouldChangeText(in: range, replacementString: text) else { return }
        textStorage?.replaceCharacters(in: range, with: text)
        didChangeText()
        let grown = (text as NSString).length - range.length
        if sel.length == 0 {
            setSelectedRange(NSRange(location: max(range.location, sel.location + firstDelta), length: 0))
        } else {
            setSelectedRange(NSRange(location: range.location, length: range.length + grown - (trailing != nil ? 1 : 0)))
        }
    }

    override func keyDown(with e: NSEvent) {
        if e.modifierFlags.intersection([.command, .control, .option, .shift]) == .option, e.keyCode == 6 {
            NSApp.sendAction(#selector(FileEditorView.toggleWrap(_:)), to: nil, from: self)
            return
        }
        super.keyDown(with: e)
    }

    /// Pasted or dropped text gets LF line endings, as the loaded text has (saving restores CRLF files' own).
    /// Text copied from web pages and Windows apps often ends lines with CRLF; the CR is invisible here but
    /// would be saved, e.g. trailing every value of a pasted `export AWS_…=…` list.
    override func shouldChangeText(in range: NSRange, replacementString s: String?) -> Bool {
        guard let s, s.unicodeScalars.contains("\r") else { return super.shouldChangeText(in: range, replacementString: s) }
        insertText(s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"), replacementRange: range)
        return false
    }
}

/// File name, folder, unsaved dot, and the wrap / save / close buttons.
final class EditorHeaderView: NSView {
    static let height: CGFloat = 26
    var title = "" { didSet { needsDisplay = true } }
    var subtitle = "" { didSet { needsDisplay = true } }
    var dirty = false { didSet { needsDisplay = true } }
    var wraps = false { didSet { needsDisplay = true } }
    var status: String? { didSet { needsDisplay = true } }
    /// The file is gone from disk: the header says so, and saving (which puts it back) is offered.
    var deleted = false { didSet { needsDisplay = true } }
    /// It changed on disk under unsaved edits: said in yellow, as deleted is in red.
    var changedOnDisk = false { didSet { needsDisplay = true } }
    /// Off for read-only text (the end of a big file): no save button.
    var editable = true { didSet { needsDisplay = true } }
    /// Off for previews, diffs and graphs: only the close button shows.
    var textTools = true { didSet { needsDisplay = true } }
    /// Set while this file is its tab's only one and there's no terminal (no sub-tab strip): shows one under it.
    var onShowTerminal: (() -> Void)? { didSet { if (onShowTerminal == nil) != (oldValue == nil) { needsDisplay = true } } }
    /// A format with a formatter (JSON, YAML, XML) and not read-only: the format button shows.
    var canFormat = false { didSet { needsDisplay = true } }
    /// A Markdown file: the preview button shows.
    var canPreview = false { didSet { needsDisplay = true } }
    /// A log: its coloring's palette button shows, with this format's name.
    var logFormatName: String? { didSet { needsDisplay = true } }
    var onLogFormat: (() -> Void)?
    /// Git has changes for this file: the working tree button shows.
    var hasGitChanges = false { didSet { needsDisplay = true } }
    /// Tail File is on: the file's end stays in view as it grows.
    var tailing = false { didSet { needsDisplay = true } }
    /// Over ssh: whether the host is reporting changes (a green "Live"), or not (a yellow "Not Updating"); nil: no
    /// tag (on this Mac, or starting).
    var watchLive: Bool? { didSet { if watchLive != oldValue { needsDisplay = true } } }
    var onToggleTail: (() -> Void)?
    var onClose: (() -> Void)?
    var onSave: (() -> Void)?
    var onFormat: (() -> Void)?
    var onPreview: (() -> Void)?
    var onShowChanges: (() -> Void)?
    var onToggleWrap: (() -> Void)?
    var onCopyPath: (() -> Void)?
    private var hover: Int?
    private var hoverPath = false
    private var buttonRects: [NSRect] = []
    private var pathRect = NSRect.zero

    override var isFlipped: Bool { true }

    private func symbol(_ name: String, _ color: NSColor) -> NSImage? {
        if name == Self.saveIcon { return Self.floppyDisk(color) }
        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium).applying(.init(paletteColors: [color]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
    }

    private static let saveIcon = "save"

    /// SF Symbols has no floppy disk (the nearest, square.and.arrow.down, reads as a download), so it's drawn here,
    /// its lines the weight of the symbols beside it.
    private static func floppyDisk(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 13, height: 13), flipped: true) { _ in
            color.setStroke()
            let body = NSBezierPath()
            body.move(to: NSPoint(x: 1.5, y: 2.7))
            body.appendArc(from: NSPoint(x: 1.5, y: 1.5), to: NSPoint(x: 2.7, y: 1.5), radius: 1.2)
            body.line(to: NSPoint(x: 9.3, y: 1.5))
            body.line(to: NSPoint(x: 11.5, y: 3.7))
            body.line(to: NSPoint(x: 11.5, y: 10.3))
            body.appendArc(from: NSPoint(x: 11.5, y: 11.5), to: NSPoint(x: 10.3, y: 11.5), radius: 1.2)
            body.line(to: NSPoint(x: 2.7, y: 11.5))
            body.appendArc(from: NSPoint(x: 1.5, y: 11.5), to: NSPoint(x: 1.5, y: 10.3), radius: 1.2)
            body.close()
            // The metal shutter at the top, and the label at the bottom.
            body.move(to: NSPoint(x: 4, y: 1.5))
            body.line(to: NSPoint(x: 4, y: 4.5))
            body.line(to: NSPoint(x: 8.5, y: 4.5))
            body.line(to: NSPoint(x: 8.5, y: 1.5))
            body.move(to: NSPoint(x: 3.8, y: 11.5))
            body.line(to: NSPoint(x: 3.8, y: 7.5))
            body.line(to: NSPoint(x: 9.2, y: 7.5))
            body.line(to: NSPoint(x: 9.2, y: 11.5))
            body.lineWidth = 1.1
            body.lineJoinStyle = .round
            body.stroke()
            return true
        }
    }

    /// Where the button whose tooltip starts with `tip` was last drawn.
    func rect(ofButton tip: String) -> NSRect? {
        guard let i = buttons.firstIndex(where: { $0.tip.hasPrefix(tip) }), i < buttonRects.count else { return nil }
        return buttonRects[i]
    }

    /// Dev aid (DevTools header-press, print-header): the buttons showing, and pressing one by its tooltip's start.
    var devButtons: [String] { buttons.map(\.tip) }
    func devPress(_ tip: String) { buttons.first { $0.tip.hasPrefix(tip) }?.action?() }

    /// Right to left: close, save, format, wrap, tail, working tree, preview. No action: greyed out (save, with nothing to save).
    private var buttons: [(symbol: String, tip: String, active: Bool, action: (() -> Void)?)] {
        var b: [(symbol: String, tip: String, active: Bool, action: (() -> Void)?)] = [("xmark", "Close (⌘W)", false, onClose)]
        // A tab of just this file has no sub-tab strip, whose button this is otherwise.
        if let onShowTerminal { b.append(("terminal", "Show Terminal", false, onShowTerminal)) }
        guard textTools else { return b }
        if editable {
            b.append(dirty || deleted ? (Self.saveIcon, deleted ? "Save (⌘S), Putting the Deleted File Back" : "Save (⌘S)", true, onSave)
                                      : (Self.saveIcon, "No Changes to Save", false, nil))
        }
        if editable, canFormat { b.append(("list.bullet.indent", "Beautify / Format Document (⌥⌘F)", false, onFormat)) }
        b.append(("text.word.spacing", wraps ? "Don't Wrap Lines (⌥Z)" : "Wrap Lines (⌥Z)", wraps, onToggleWrap))
        b.append(("chevron.down.2", tailing ? "Stop Tailing" : "Tail File (keep the end in view as it grows)", tailing, onToggleTail))
        if hasGitChanges { b.append(("plusminus", "Open Working Tree (this file's uncommitted changes)", false, onShowChanges)) }
        if canPreview { b.append(("doc.richtext", "Open Preview", false, onPreview)) }
        if let logFormatName { b.append(("paintpalette", "Log Coloring: \(logFormatName)", false, onLogFormat)) }
        return b
    }

    override func draw(_ dirtyRect: NSRect) {
        // On the card's own background (see `Cards`), set off from the file by one hairline, inset from the card's
        // rounded edges.
        let th = Config.shared.theme
        th.border.setFill()
        let inset: CGFloat = 12
        NSBezierPath(roundedRect: NSRect(x: inset, y: bounds.height - 1, width: max(0, bounds.width - 2 * inset), height: 1),
                     xRadius: 0.5, yRadius: 0.5).fill()

        buttonRects = []
        var right = bounds.width - 8
        for (i, b) in buttons.enumerated() {
            let r = NSRect(x: right - 22, y: (bounds.height - 22) / 2, width: 22, height: 22)
            buttonRects.append(r)
            right = r.minX - 2
            let active = b.active, enabled = b.action != nil
            if hover == i, enabled {
                th.foreground.withAlphaComponent(0.1).setFill()
                NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).fill()
            }
            let color = !enabled ? th.foreground.withAlphaComponent(0.25)
                : active ? th.accent : th.foreground.withAlphaComponent(hover == i ? 0.9 : 0.6)
            if let img = symbol(b.symbol, color) {
                img.draw(in: NSRect(x: r.midX - img.size.width / 2, y: r.midY - img.size.height / 2, width: img.size.width, height: img.size.height))
            }
        }

        var x: CGFloat = 12
        if !title.isEmpty, let icon = symbol("doc.text", th.dimText) {
            icon.draw(in: NSRect(x: x, y: (bounds.height - icon.size.height) / 2, width: icon.size.width, height: icon.size.height))
            x += icon.size.width + 7
        }
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingMiddle
        let titleAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: th.foreground, .paragraphStyle: para]
        let maxW = right - x - 8
        let tw = min((title as NSString).size(withAttributes: titleAttrs).width + 1, maxW)
        (title as NSString).draw(in: NSRect(x: x, y: bounds.midY - 8, width: tw, height: 16), withAttributes: titleAttrs)
        x += tw + 6
        if dirty {
            th.foreground.withAlphaComponent(0.8).setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: bounds.midY - 3.5, width: 7, height: 7)).fill()
            x += 13
        }
        // Gone from disk: said in red before where it was.
        if deleted, status == nil {
            let tag = editable ? "Deleted · ⌘S saves it again" : "Deleted"
            let tagAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: th.red]
            let w = (tag as NSString).size(withAttributes: tagAttrs).width + 1
            if right - x > w + 30 {
                (tag as NSString).draw(in: NSRect(x: x, y: bounds.midY - 7.5, width: w, height: 15), withAttributes: tagAttrs)
                x += w + 8
            }
        }
        if changedOnDisk, !deleted, status == nil {
            let tag = "Changed on Disk"
            let tagAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: th.yellow]
            let w = (tag as NSString).size(withAttributes: tagAttrs).width + 1
            if right - x > w + 30 {
                (tag as NSString).draw(in: NSRect(x: x, y: bounds.midY - 7.5, width: w, height: 15), withAttributes: tagAttrs)
                x += w + 8
            }
        }
        if let live = watchLive, !deleted, !changedOnDisk, status == nil {
            let tag = live ? "Live" : "Not Updating"
            let color = live ? th.green : th.yellow
            let tagAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: color]
            let w = (tag as NSString).size(withAttributes: tagAttrs).width + 1
            if right - x > w + 44 {
                color.setFill()
                NSBezierPath(ovalIn: NSRect(x: x, y: bounds.midY - 3, width: 6, height: 6)).fill()
                (tag as NSString).draw(in: NSRect(x: x + 10, y: bounds.midY - 7.5, width: w, height: 15), withAttributes: tagAttrs)
                x += w + 18
            }
        }
        let sub = status ?? subtitle
        let subAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .paragraphStyle: para,
                                                       .foregroundColor: hoverPath && status == nil ? th.foreground.withAlphaComponent(0.85) : th.dimText]
        pathRect = .zero
        if right - x > 30 {
            let w = min((sub as NSString).size(withAttributes: subAttrs).width + 1, right - x - 8)
            pathRect = NSRect(x: x, y: bounds.midY - 7.5, width: w, height: 15)
            (sub as NSString).draw(in: pathRect, withAttributes: subAttrs)
        }
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        if !pathRect.isEmpty, onCopyPath != nil { addCursorRect(pathRect, cursor: .pointingHand) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === self }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    private func button(at e: NSEvent) -> Int? {
        let p = convert(e.locationInWindow, from: nil)
        return buttonRects.firstIndex { $0.contains(p) }
    }

    override func mouseMoved(with e: NSEvent) {
        let h = button(at: e)
        // The subtitle copies the path, when there is one (not an extension's page).
        let onPath = h == nil && onCopyPath != nil && pathRect.contains(convert(e.locationInWindow, from: nil))
        if h != hover || onPath != hoverPath {
            hover = h
            hoverPath = onPath
            toolTip = h.map { buttons[$0].tip } ?? (onPath ? "Click to Copy Path" : nil)
            needsDisplay = true
        }
    }

    override func mouseExited(with e: NSEvent) {
        hover = nil
        hoverPath = false
        needsDisplay = true
    }

    override func mouseDown(with e: NSEvent) {
        if let i = button(at: e) { buttons[i].action?() }
        else if let onCopyPath, pathRect.contains(convert(e.locationInWindow, from: nil)) { onCopyPath() }
    }
}

// MARK: Big files

/// A file past `windowedFileSize` is shown the way `less` shows one, so it's as quick to open and move through at
/// 400 MB as at 4: the text is a window of it (`windowed`), at most `windowMax` bytes of whole lines. Coming within a
/// few screens of either edge fetches the next `windowChunk` there in the background, and the far end is let go;
/// text added above the view moves it down by exactly its lines (every line is the same height), so nothing on
/// screen moves. A scroller for the whole file (`FileScroller`) stands in for the text view's own, and dragging it
/// fetches the window there in one read. Line numbers are counted on the host. New lines at the end arrive as for any
/// file while the window reaches the end; when it doesn't, only the scroller hears the file grew.
extension FileEditorView {
    fileprivate var lineHeight: CGFloat {
        (textView.layoutManager ?? NSLayoutManager()).defaultLineHeight(for: FontSet.current.regular as NSFont)
    }

    fileprivate static func newlines(in s: String) -> Int {
        var n = 0
        for b in s.utf8 where b == 10 { n += 1 }
        return n
    }

    private func decodeWindow(_ data: Data) -> String {
        let (bytes, crlf) = Self.droppingCR(data)
        if crlf { usesCRLF = true }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Where in the file the window's character `ch` is (in proportion within its piece: close enough for a
    /// scroller, and exact at the pieces' edges).
    private func byteOffset(ofChar ch: Int) -> Int {
        var c = 0, b = winStart
        for k in winChunks {
            if ch < c + k.chars { return b + Int(Double(ch - c) / Double(max(1, k.chars)) * Double(k.bytes)) }
            c += k.chars
            b += k.bytes
        }
        return b
    }

    /// The byte at the top of the view.
    fileprivate func visibleByte() -> Int {
        guard let lm = textView.layoutManager, let tc = textView.textContainer, (textView.textStorage?.length ?? 0) > 0 else { return winStart }
        let top = max(0, scroll.contentView.bounds.minY - textView.textContainerOrigin.y)
        let g = lm.glyphIndex(for: NSPoint(x: 0, y: top), in: tc)
        return byteOffset(ofChar: lm.characterIndexForGlyph(at: g))
    }

    /// The character at the top of the view, and how far into its line the view starts: to put the view back on
    /// that same line after text is added or let go above it (`restoreTop`).
    fileprivate func topAnchor() -> (char: Int, into: CGFloat)? {
        guard let lm = textView.layoutManager, let tc = textView.textContainer, (textView.textStorage?.length ?? 0) > 0 else { return nil }
        let top = max(0, scroll.contentView.bounds.minY - textView.textContainerOrigin.y)
        let g = lm.glyphIndex(for: NSPoint(x: 0, y: top), in: tc)
        let line = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
        return (lm.characterIndexForGlyph(at: g), top - line.minY)
    }

    /// The view back on the line `anchor` named, now `shift` characters along (text was added or taken away above).
    fileprivate func restoreTop(_ anchor: (char: Int, into: CGFloat), shift: Int) {
        guard let lm = textView.layoutManager, let length = textView.textStorage?.length, length > 0 else { return }
        let ch = min(max(0, anchor.char + shift), length - 1)
        let line = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: ch), effectiveRange: nil)
        programmatically {
            scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: line.minY + anchor.into + textView.textContainerOrigin.y))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    /// About how many of the file's bytes fit on screen.
    private var visibleBytes: Int {
        let lines = max(1, winChunks.reduce(0) { $0 + $1.lines })
        let bytes = winChunks.reduce(0) { $0 + $1.bytes }
        return Int(scroll.contentView.bounds.height / max(1, lineHeight)) * max(1, bytes / lines)
    }

    /// For `FileScroller`: where the view is in the whole file, and how much of it shows, as fractions.
    fileprivate func filePosition() -> (top: Double, size: Double) {
        guard fileSize > 0 else { return (0, 1) }
        let seen = visibleBytes
        let room = max(1, fileSize - seen)
        // At the very end of a window that reaches the file's end: the bottom.
        if windowAtEnd, endInView { return (1, min(1, Double(seen) / Double(fileSize))) }
        return (min(1, Double(visibleByte()) / Double(room)), min(1, Double(seen) / Double(fileSize)))
    }

    fileprivate func showFileScroller(_ on: Bool) {
        scroll.hasVerticalScroller = !on
        if on, fileScroller == nil {
            let s = FileScroller()
            s.position = { [weak self] in self?.filePosition() ?? (0, 1) }
            s.onJump = { [weak self] f in self?.scrollerJumped(to: f) }
            s.scrollTarget = scroll
            addSubview(s, positioned: .above, relativeTo: scroll)
            fileScroller = s
            needsLayout = true
        } else if !on, let s = fileScroller {
            s.removeFromSuperview()
            fileScroller = nil
        }
    }

    private func scrollerJumped(to f: Double) {
        if f >= 0.999 {
            if windowAtEnd { textView.scrollToEndOfDocument(nil) } else { jumpWindow(to: nil) }
            return
        }
        if tailing { tailing = false }
        let target = Int(f * Double(max(0, fileSize - visibleBytes)))
        // Already held (and not at its edge): just there.
        let held = diskSize - winStart
        if target >= winStart, target < diskSize - min(held / 4, windowChunk), target >= winStart + (winStart > 0 ? min(held / 4, windowChunk) : 0) {
            scrollToByte(target)
        } else {
            jumpWindow(to: target)
        }
    }

    /// Puts the line holding byte `byte` (in the window) at the top.
    private func scrollToByte(_ byte: Int) {
        guard let lm = textView.layoutManager, let storage = textView.textStorage, storage.length > 0 else { return }
        var c = 0, b = winStart, ch = storage.length
        for k in winChunks {
            if byte < b + k.bytes { ch = c + Int(Double(byte - b) / Double(max(1, k.bytes)) * Double(k.chars)); break }
            c += k.chars
            b += k.bytes
        }
        ch = min(max(0, ch), storage.length - 1)
        let line = (storage.string as NSString).lineRange(for: NSRange(location: ch, length: 0))
        let rect = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: line.location), effectiveRange: nil)
        programmatically {
            scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: rect.minY + textView.textContainerOrigin.y))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    /// The view moved: near an edge of the window, the next piece there.
    func windowScrolled() {
        guard windowed else { return }
        fileScroller?.needsDisplay = true
        guard loaded, !winBusy else { return }
        let visible = scroll.contentView.bounds
        // A piece and a half ahead (or 8 screens, if more): a fast scroll doesn't reach the edge before the next
        // piece arrives (a read over ssh takes a few hundred ms).
        let lines = winChunks.reduce(0) { $0 + $1.lines }
        let pieceHeight = CGFloat(lines / max(1, winChunks.count)) * lineHeight
        let margin = max(max(visible.height, 200) * 8, pieceHeight * 1.5)
        if visible.minY - textView.textContainerOrigin.y < margin, winStart > 0 {
            extendWindow(up: true)
        } else if textView.frame.height - visible.maxY < margin, !windowAtEnd {
            extendWindow(up: false)
        }
    }

    /// Fetches the piece above or below the window and adds it, letting go of the far end if it's grown too big.
    private func extendWindow(up: Bool) {
        winBusy = true
        let gen = winGeneration, asked = Date()
        if up {
            let end = winStart, start = max(0, end - windowChunk)
            fs.readPart(path, from: start, whole: 0, tail: end - start) { [weak self] result in
                guard let self, gen == self.winGeneration else { return }
                self.winBusy = false
                guard self.winStart == end, case .success(let part) = result, let storage = self.textView.textStorage else { return }
                var data = part.data.prefix(end - start)
                var from = start
                // From the first whole line (a line longer than a piece comes whole).
                if start > 0, let nl = data.firstIndex(of: 0x0A), nl + 1 < data.endIndex {
                    from = start + (nl - data.startIndex) + 1
                    data = data[(nl + 1)...]
                }
                guard !data.isEmpty else { return }
                let applying = Date()
                let text = self.decodeWindow(Data(data))
                let chars = (text as NSString).length, lines = Self.newlines(in: text)
                let anchor = self.topAnchor()
                storage.insert(NSAttributedString(string: text, attributes: self.textView.typingAttributes), at: 0)
                // Every line moved along: the gutter finds them again (a scan of the window, a few ms).
                self.ruler.invalidateLines()
                self.logPainted.shift(startingAt: 0, by: chars)
                self.winStart = from
                self.winChunks.insert(WinChunk(bytes: data.count, chars: chars, lines: lines), at: 0)
                self.winTopShift -= lines
                self.ruler.lineBase = self.ruler.lineBase.map { $0 - lines }
                // What's on screen stays put: the same line at the top.
                if let anchor { self.restoreTop(anchor, shift: chars) }
                self.trimWindow(fromTop: false)
                self.windowChanged()
                Diagnostics.log("window \(self.diagName): +\(data.count >> 10) KB above (from byte \(from)), read in \(Diagnostics.ms(asked)) ms, added in \(Diagnostics.ms(applying)) ms; holding \((self.diskSize - self.winStart) >> 10) KB")
            }
        } else {
            let start = diskSize
            // From a little before the window's end, to keep the bytes that end it (`diskTail`) once it's the file's.
            let overlap = min(256, start - winStart)
            fs.readPart(path, from: start - overlap, whole: 0, tail: windowChunk + overlap) { [weak self] result in
                guard let self, gen == self.winGeneration else { return }
                self.winBusy = false
                guard self.diskSize == start, case .success(let part) = result, part.data.count >= overlap,
                      let storage = self.textView.textStorage else { return }
                self.fileSize = max(self.fileSize, part.size)
                var data = part.data.dropFirst(overlap)
                let reachedEnd = start + data.count >= part.size
                var rest = Data()
                if !reachedEnd, let nl = data.lastIndex(of: 0x0A) {
                    data = data[...nl]
                } else if reachedEnd {
                    let (whole, tail) = Self.splitUTF8(Data(data))
                    data = whole[...]
                    rest = tail
                }
                guard !data.isEmpty || !rest.isEmpty else { return }
                let applying = Date()
                let text = self.decodeWindow(Data(data))
                let before = storage.length
                storage.append(NSAttributedString(string: text, attributes: self.textView.typingAttributes))
                self.winChunks.append(WinChunk(bytes: data.count, chars: (text as NSString).length, lines: Self.newlines(in: text)))
                self.diskSize = start + data.count + rest.count
                self.carry = rest
                self.diskTail = Data(part.data.prefix(overlap + data.count + rest.count).suffix(256))
                self.ruler.linesAppended(from: before)
                self.trimWindow(fromTop: true)
                self.windowChanged()
                Diagnostics.log("window \(self.diagName): +\(data.count >> 10) KB below\(reachedEnd ? " (to the end)" : ""), read in \(Diagnostics.ms(asked)) ms, added in \(Diagnostics.ms(applying)) ms; holding \((self.diskSize - self.winStart) >> 10) KB")
            }
        }
    }

    /// The last piece split (at lines) into pieces of about `windowChunk`, so the window lets go of a piece at a
    /// time: what a load or a jump brought in one read, or new lines that kept arriving into it.
    fileprivate func splitLastChunk() {
        guard let storage = textView.textStorage else { return }
        let s = storage.string as NSString
        while var last = winChunks.last, last.bytes > windowChunk * 3 / 2, last.lines > 1 {
            let start = s.length - last.chars
            // About a piece's worth of characters in (as many as bytes, near enough), to the end of that line.
            let cut = s.lineRange(for: NSRange(location: start + min(last.chars - 1, windowChunk), length: 0))
            let firstChars = NSMaxRange(cut) - start
            guard firstChars > 0, firstChars < last.chars else { return }
            let firstText = s.substring(with: NSRange(location: start, length: firstChars))
            let firstLines = Self.newlines(in: firstText)
            let firstBytes = firstText.utf8.count + (usesCRLF ? firstLines : 0)
            last.bytes -= firstBytes
            last.chars -= firstChars
            last.lines -= firstLines
            winChunks[winChunks.count - 1] = WinChunk(bytes: firstBytes, chars: firstChars, lines: firstLines)
            winChunks.append(last)
        }
    }

    /// Lets go of whole pieces at one end while the window holds more than `windowMax`, never what's on screen or
    /// within two screens of it. `fromTop`: the top end (as the window moves down).
    fileprivate func trimWindow(fromTop: Bool) {
        guard let storage = textView.textStorage else { return }
        var total = winChunks.reduce(0) { $0 + $1.bytes }
        let h = lineHeight
        var trimmed = 0
        while total > windowMax, winChunks.count > 1 {
            let visible = scroll.contentView.bounds
            if fromTop {
                let k = winChunks[0]
                guard k.chars <= storage.length, CGFloat(k.lines) * h < visible.minY - visible.height * 2 else { break }
                let anchor = topAnchor()
                storage.deleteCharacters(in: NSRange(location: 0, length: k.chars))
                logPainted.remove(integersIn: 0..<k.chars)
                logPainted.shift(startingAt: k.chars, by: -k.chars)
                winStart += k.bytes
                winTopShift += k.lines
                ruler.lineBase = ruler.lineBase.map { $0 + k.lines }
                winChunks.removeFirst()
                if let anchor { restoreTop(anchor, shift: -k.chars) }
                total -= k.bytes
            } else {
                let k = winChunks[winChunks.count - 1]
                let keptHeight = CGFloat(winChunks.dropLast().reduce(0) { $0 + $1.lines }) * h
                guard k.chars <= storage.length, keptHeight > visible.maxY + visible.height * 2 else { break }
                storage.deleteCharacters(in: NSRange(location: storage.length - k.chars, length: k.chars))
                logPainted.remove(integersIn: storage.length..<(storage.length + k.chars))
                winChunks.removeLast()
                total -= k.bytes
                // No longer the file's end: what ended it, and any part of a character there, go too.
                diskSize = winStart + total
                carry = Data()
                diskTail = Data()
            }
            trimmed += 1
        }
        if trimmed > 0 {
            ruler.invalidateLines()
            Diagnostics.log("window \(diagName): let go of \(trimmed) piece(s) at the \(fromTop ? "top" : "bottom"); holding \((diskSize - winStart) >> 10) KB")
        }
    }

    /// The window again, around byte `byte` (its line at the top), or at the file's end (nil): one read.
    /// `keepView`: not the user's jump but the file read again; where the view is when it arrives is kept (and if
    /// they're scrolling then, it waits for them to stop).
    fileprivate func jumpWindow(to byte: Int?, keepView: Bool = false) {
        winGeneration += 1
        let gen = winGeneration, asked = Date()
        winBusy = true
        let size = fileSize
        let target = byte.map { min(max(0, $0), size) }
        let start = target.map { max(0, $0 - windowChunk) } ?? max(0, size - 2 * windowChunk)
        fs.readPart(path, from: start, whole: 0, tail: 2 * windowChunk) { [weak self] result in
            guard let self, gen == self.winGeneration else { return }
            self.winBusy = false
            guard case .success(let part) = result, let storage = self.textView.textStorage else {
                Diagnostics.log("window \(self.diagName): the read failed")
                return
            }
            if keepView, self.liveScrolling {
                Diagnostics.log("window \(self.diagName): read again during a scroll; again once it ends")
                self.reloadAfterScroll = true
                return
            }
            // Where the view is now (it may have moved since this was asked for).
            let target = keepView ? self.visibleByte() : target
            let applying = Date()
            self.fileSize = part.size
            var data = part.data[...]
            var from = start
            if start > 0, let nl = data.firstIndex(of: 0x0A), nl + 1 < data.endIndex {
                from = start + (nl - data.startIndex) + 1
                data = data[(nl + 1)...]
            }
            let reachedEnd = start + part.data.count >= part.size
            var rest = Data()
            if !reachedEnd, let nl = data.lastIndex(of: 0x0A) {
                data = data[...nl]
            } else if reachedEnd {
                let (whole, tail) = Self.splitUTF8(Data(data))
                data = whole[...]
                rest = tail
            }
            // The view moved out of what was read (scrolled on while it came): read around where it is now.
            if keepView, let t = target, t < from || t > from + data.count {
                Diagnostics.log("window \(self.diagName): the view moved on while it was read; reading there")
                return self.jumpWindow(to: t, keepView: true)
            }
            let text = self.decodeWindow(Data(data))
            storage.setAttributedString(NSAttributedString(string: text, attributes: self.textView.typingAttributes))
            self.logPainted = IndexSet()
            self.winStart = from
            self.diskSize = from + data.count + rest.count
            self.carry = rest
            self.diskTail = Data(part.data.prefix(self.diskSize - start).suffix(256))
            self.winChunks = [WinChunk(bytes: data.count, chars: (text as NSString).length, lines: Self.newlines(in: text))]
            self.splitLastChunk()
            self.ruler.lineBase = nil
            self.ruler.invalidateLines()
            self.countWindowLines()
            self.textView.setSelectedRange(NSRange(location: 0, length: 0))
            if let target, target > from { self.scrollToByte(target) }
            else if target == nil { self.programmatically { self.textView.scrollToEndOfDocument(nil) } }
            else {
                self.programmatically {
                    self.scroll.contentView.scroll(to: .zero)
                    self.scroll.reflectScrolledClipView(self.scroll.contentView)
                }
            }
            self.windowChanged()
            Diagnostics.log("window \(self.diagName): moved to \(target.map { "byte \($0)" } ?? "the end") of \(part.size), read in \(Diagnostics.ms(asked)) ms, shown in \(Diagnostics.ms(applying)) ms")
        }
    }

    /// Counts (on the host, over ssh) the lines before the window, for its line numbers.
    fileprivate func countWindowLines() {
        let gen = winGeneration, start = winStart, shift = winTopShift, asked = Date()
        fs.countLines(path, upTo: start) { [weak self] n in
            guard let self, let n, gen == self.winGeneration else { return }
            self.ruler.lineBase = n + (self.winTopShift - shift)
            Diagnostics.log("window \(self.diagName): \(n) lines before byte \(start), counted in \(Diagnostics.ms(asked)) ms")
        }
    }

    private func windowChanged() {
        findTextChanged()
        paintVisibleLog()
        fileScroller?.needsDisplay = true
        // Still near an edge (a quick scroll): the next piece too.
        DispatchQueue.main.async { [weak self] in self?.windowScrolled() }
    }

    /// Dev aid: where the window is, and what it holds.
    var devWindowState: String {
        "windowed=\(windowed) bytes \(winStart)..<\(diskSize) of \(fileSize), \(winChunks.count) pieces, \(textView.textStorage?.length ?? 0) chars, lineBase \(ruler.lineBase.map(String.init) ?? "counting"), top byte \(visibleByte()), first line \((textView.string as NSString).substring(with: (textView.string as NSString).lineRange(for: NSRange(location: min(textView.textStorage?.length ?? 0, (textView.layoutManager.flatMap { lm in textView.textContainer.map { lm.characterIndexForGlyph(at: lm.glyphIndex(for: NSPoint(x: 0, y: max(0, scroll.contentView.bounds.minY - textView.textContainerOrigin.y)), in: $0)) } }) ?? 0), length: 0))).trimmingCharacters(in: .newlines).prefix(80))"
    }
    func devJump(_ fraction: Double) { scrollerJumped(to: fraction) }
    /// Dev aid: a scroll wheel turned up over the text (what the input monitor reports), and the view moving up.
    func devWheelUp(_ points: CGFloat) {
        userScrolledUp()
        let o = scroll.contentView.bounds.origin
        scroll.contentView.scroll(to: NSPoint(x: o.x, y: max(0, o.y - points)))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
    var devView: String {
        "y \(Int(scroll.contentView.bounds.minY)) of \(Int(textView.frame.height)), \(atVeryEnd ? "at the very end" : "\(Int(textView.frame.maxY - scroll.contentView.bounds.maxY)) px above the end"), tail \(tailing ? "on" : "off"), \(devTopLine)"
    }
    /// Dev aid: the line number the gutter gives the top line on screen, and that line's text.
    var devTopLine: String {
        guard let lm = textView.layoutManager, let tc = textView.textContainer else { return "-" }
        let top = max(0, scroll.contentView.bounds.minY - textView.textContainerOrigin.y)
        let ch = lm.characterIndexForGlyph(at: lm.glyphIndex(for: NSPoint(x: 0, y: top), in: tc))
        let s = textView.string as NSString
        let before = ruler.lineIndex(ofChar: min(ch, s.length))
        let text = s.substring(with: s.lineRange(for: NSRange(location: min(ch, s.length), length: 0))).trimmingCharacters(in: .newlines)
        let row = text.range(of: #"row \d+"#, options: .regularExpression).map { String(text[$0]) } ?? String(text.prefix(40))
        return "gutter says \(ruler.lineBase.map { String($0 + before + 1) } ?? "?"), the line says \(row)"
    }
}

/// The scroller for a big file (see "Big files"): where the view is in the whole file, not just the window held.
/// Dragging it shows where it'll land and fetches there on letting go; a click on the track jumps there.
final class FileScroller: NSView {
    static let width: CGFloat = 12
    var position: () -> (top: Double, size: Double) = { (0, 1) }
    var onJump: ((Double) -> Void)?
    /// Wheel and trackpad scrolling over it go to the text.
    weak var scrollTarget: NSScrollView?
    private var drag: (grab: CGFloat, fraction: Double)?
    private var hover = false

    override var isFlipped: Bool { true }

    private func thumb(_ p: (top: Double, size: Double)) -> NSRect {
        let h = min(bounds.height, max(28, CGFloat(p.size) * bounds.height))
        return NSRect(x: 3, y: (CGFloat(p.top) * (bounds.height - h)).rounded(), width: bounds.width - 6, height: h)
    }

    private var current: (top: Double, size: Double) {
        let p = position()
        return drag.map { ($0.fraction, p.size) } ?? p
    }

    override func draw(_ dirtyRect: NSRect) {
        let th = Config.shared.theme
        if hover || drag != nil {
            th.foreground.withAlphaComponent(0.05).setFill()
            bounds.fill()
        }
        let r = thumb(current)
        th.foreground.withAlphaComponent(drag != nil ? 0.5 : hover ? 0.38 : 0.25).setFill()
        NSBezierPath(roundedRect: r, xRadius: r.width / 2, yRadius: r.width / 2).fill()
        if let d = drag {
            let label = "\(Int((d.fraction * 100).rounded()))%" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium), .foregroundColor: th.foreground]
            let size = label.size(withAttributes: attrs)
            let box = NSRect(x: -size.width - 14, y: r.midY - 9, width: size.width + 10, height: 18)
            th.background.withAlphaComponent(0.95).setFill()
            NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
            label.draw(at: NSPoint(x: box.minX + 5, y: box.midY - size.height / 2), withAttributes: attrs)
        }
    }

    // The percentage label draws to its left.
    override var wantsDefaultClipping: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === self }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with e: NSEvent) { hover = true; needsDisplay = true }
    override func mouseExited(with e: NSEvent) { hover = false; needsDisplay = true }
    override func scrollWheel(with e: NSEvent) { scrollTarget?.scrollWheel(with: e) }

    private func fraction(atThumbTop y: CGFloat, _ p: (top: Double, size: Double)) -> Double {
        let h = thumb(p).height
        return Double(min(1, max(0, y / max(1, bounds.height - h))))
    }

    override func mouseDown(with e: NSEvent) {
        let pt = convert(e.locationInWindow, from: nil)
        let p = position()
        let r = thumb(p)
        if r.contains(pt) {
            drag = (pt.y - r.minY, p.top)
        } else {
            // A click on the track: there, with the thumb centred on it.
            onJump?(fraction(atThumbTop: pt.y - r.height / 2, p))
        }
        needsDisplay = true
    }

    override func mouseDragged(with e: NSEvent) {
        guard let d = drag else { return }
        let pt = convert(e.locationInWindow, from: nil)
        drag = (d.grab, fraction(atThumbTop: pt.y - d.grab, position()))
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        guard let d = drag else { return }
        drag = nil
        needsDisplay = true
        onJump?(d.fraction)
    }
}

/// Line numbers in the editor's gutter.
final class LineNumberRuler: NSRulerView {
    weak var textView: NSTextView?
    var font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    /// UTF-16 offsets where each line starts; rebuilt lazily after edits.
    private var lineStarts: [Int]?
    /// Lines in the file before the text shown (a big file shows a window of itself); nil while that's being
    /// counted, when no numbers show.
    var lineBase: Int? = 0 {
        didSet {
            guard lineBase != oldValue else { return }
            if let l = lineStarts { fitWidth(lines: l.count) }
            needsDisplay = true
        }
    }

    override var isFlipped: Bool { true }

    func invalidateLines() {
        lineStarts = nil
        _ = starts()
        needsDisplay = true
    }

    /// Text was added at the end (a watched file grew): only the new part is scanned for lines, not all of a
    /// file that may be hundreds of MB.
    func linesAppended(from start: Int) {
        guard var out = lineStarts else { return invalidateLines() }
        let s = (textView?.string ?? "") as NSString
        guard start <= s.length else { return invalidateLines() }
        Self.scan(s, from: start, into: &out)
        lineStarts = out
        fitWidth(lines: out.count)
        needsDisplay = true
    }

    /// Adds where each line after a newline in `s` (from `start`) begins.
    private static func scan(_ s: NSString, from start: Int, into out: inout [Int]) {
        let n = s.length
        var i = start
        let buf = UnsafeMutablePointer<unichar>.allocate(capacity: 4096)
        defer { buf.deallocate() }
        while i < n {
            let len = min(4096, n - i)
            s.getCharacters(buf, range: NSRange(location: i, length: len))
            for k in 0..<len where buf[k] == 10 { out.append(i + k + 1) }
            i += len
        }
    }

    private func starts() -> [Int] {
        if let l = lineStarts { return l }
        var out = [0]
        Self.scan((textView?.string ?? "") as NSString, from: 0, into: &out)
        lineStarts = out
        fitWidth(lines: out.count)
        return out
    }

    /// Wide enough for the largest line number.
    private func fitWidth(lines: Int) {
        let digits = max(3, String(lines + (lineBase ?? 0)).count)
        let w = (CGFloat(digits) * ("8" as NSString).size(withAttributes: [.font: font]).width + 22).rounded()
        if abs(ruleThickness - w) > 0.5 {
            reservedThicknessForMarkers = 0
            reservedThicknessForAccessoryView = 0
            ruleThickness = w
            // Make room for the new width; without a re-tile the numbers draw over the text until a resize.
            DispatchQueue.main.async { [weak self] in self?.scrollView?.tile() }
        }
    }

    /// The index of the line holding character `ch` (from 0, in the text shown).
    func lineIndex(ofChar ch: Int) -> Int {
        let lines = starts()
        var lo = 0, hi = lines.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lines[mid] <= ch { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// Only the lines on screen, as already laid out to show them: asking where any other line is would make AppKit
    /// lay out (and in a long text, generate glyphs for) everything up to it, which in a text of many MB with the
    /// caret at its end froze the app for seconds on every scroll.
    override func drawHashMarksAndLabels(in rect: NSRect) {
        let th = Config.shared.theme
        guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer, let base = lineBase else { return }
        let lines = starts()
        let visible = tv.visibleRect
        let glyphs = lm.glyphRange(forBoundingRect: visible, in: tc)
        let caret = tv.selectedRange().location
        let caretLine = lineIndex(ofChar: caret)
        let originY = tv.textContainerOrigin.y
        let length = (tv.string as NSString).length
        func label(_ line: Int, at fragment: NSRect) {
            let y = convert(NSPoint(x: 0, y: fragment.minY + originY), from: tv).y
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: line == caretLine ? th.foreground.withAlphaComponent(0.85) : th.dimText.withAlphaComponent(0.45)]
            let text = "\(base + line + 1)" as NSString
            let size = text.size(withAttributes: attrs)
            text.draw(at: NSPoint(x: ruleThickness - size.width - 12, y: y + (fragment.height - size.height) / 2), withAttributes: attrs)
        }
        if glyphs.length > 0 {
            lm.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, range, _ in
                let ch = lm.characterIndexForGlyph(at: range.location)
                let line = self.lineIndex(ofChar: ch)
                // A wrapped line's later parts get no number.
                guard lines[line] == ch else { return }
                label(line, at: fragment)
            }
        }
        // The empty last line after a final newline.
        if length > 0, NSMaxRange(glyphs) >= lm.numberOfGlyphs, lines.last == length {
            let extra = lm.extraLineFragmentRect
            if !extra.isEmpty { label(lines.count - 1, at: extra) }
        } else if length == 0 {
            label(0, at: lm.extraLineFragmentRect)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        // Scrolled sideways, the text passes under the bar: a solid, darker background keeps the numbers readable, from
        // the first point it's moved (the text view starts at the bar's right edge, which on today's macOS is past
        // the scroll's left inset, so its visible rect starts below 0 until the text is well under the bar).
        if let tv = textView, tv.convert(NSPoint(x: bounds.maxX, y: 0), from: self).x > 0.5 {
            let th = Config.shared.theme
            (th.background.usingColorSpace(.sRGB)?.blended(withFraction: 0.25, of: .black) ?? th.background).withAlphaComponent(1).setFill()
            bounds.fill()
            th.border.setFill()
            NSRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height).fill()
        }
        drawHashMarksAndLabels(in: dirtyRect)
    }
}
