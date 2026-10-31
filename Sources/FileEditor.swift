import AppKit

/// A plain-text editor shown to the right of a tab's panes when a file is opened from the sidebar.
/// Works on local and ssh files alike through `FileSystem`. ⌘S saves, ⌘W closes, ⌥Z toggles wrapping.
/// Images, PDFs, video and audio show as a read-only preview instead (see `MediaPreviewView`).
final class FileEditorView: NSView, NSTextViewDelegate {
    let fs: FileSystem
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
        }
    }
    var onClose: (() -> Void)?
    /// The file was renamed, so what the sub-tab says and where it lives changed.
    var onPathChanged: (() -> Void)?
    /// The header's Preview and Working Tree buttons: this file, shown another way in another sub-tab.
    var onOpenAs: ((EditorMode) -> Void)?
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
    private(set) var isDirty = false { didSet { header.dirty = isDirty } }
    /// Too big to edit (past `maxEditableFileSize`): shown read-only, in full or (past `maxReadableFileSize`) its end.
    private var partial = false
    /// What's known of the file on disk, to follow it as it grows: its size, and its last few bytes (a change
    /// there means it was rewritten, not appended to).
    private var diskSize = 0
    private var diskTail = Data()
    /// Bytes at the end of the last read that stop partway through a character, kept for the next.
    private var carry = Data()
    /// The eye in the header: re-read the file every 5 seconds while it's on screen (and on coming back to it).
    private var watching = false { didSet { header.watching = watching; updateWatchTimer() } }
    private var watchTimer: Timer?
    private var refreshing = false
    private var wraps = false
    /// Colored as JSON, YAML or XML (see Syntax.swift); other files stay plain.
    private var language: SyntaxLanguage?
    private var pendingHighlight: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []
    private var media: MediaPreviewView?
    private var diffView: DiffView?
    private var graphView: GitGraphView?
    private var statusView: GitStatusView?
    private var statusLoading = false
    private var previewView: MarkdownPreviewView?
    /// A remote file's local copy for the preview; removed with the editor.
    private var mediaCopy: URL?

    init(fs: FileSystem, path: String, mode: EditorMode = .file) {
        self.fs = fs
        self.path = path
        self.mode = mode
        language = SyntaxLanguage(path: path)
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        layout.addTextContainer(container)
        textView = EditorTextView(frame: .zero, textContainer: container)
        ruler = LineNumberRuler(scrollView: scroll, orientation: .verticalRuler)
        super.init(frame: .zero)

        // The file's sub-tab above carries its name; the header just shows where it lives.
        header.subtitle = location
        header.toolTip = path
        header.onClose = { [weak self] in self?.requestClose() }
        header.onSave = { [weak self] in self?.saveDocument(nil) }
        header.onFormat = { [weak self] in self?.formatDocument(nil) }
        header.canFormat = language != nil
        header.canPreview = MarkdownHTML.isMarkdown(path: path)
        header.onPreview = { [weak self] in self?.onOpenAs?(.preview) }
        header.onShowChanges = { [weak self] in self?.onOpenAs?(.diff) }
        header.onToggleWrap = { [weak self] in self?.toggleWrap(nil) }
        header.onCopyPath = { [weak self] in self?.copyPath() }
        header.onToggleWatch = { [weak self] in self?.watching.toggle() }
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
            self?.applyTheme()
        })
        scroll.contentView.postsBoundsChangedNotifications = true
        observers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
            self?.ruler.needsDisplay = true
            self?.refreshFindHighlights()
        })
        observers.append(NotificationCenter.default.addObserver(forName: .solanumFileRenamed, object: fs, queue: .main) { [weak self] note in
            guard let old = note.userInfo?["old"] as? String, let new = note.userInfo?["new"] as? String else { return }
            self?.followRename(from: old, to: new)
        })
        if mode == .file {
            for name in [NSApplication.didBecomeActiveNotification, .solanumFileSaved, .solanumGitStatusChanged] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                    guard let self, note.name == NSApplication.didBecomeActiveNotification || note.object as AnyObject? === self.fs else { return }
                    self.refreshGitChanges()
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
        updateWatchTimer()
        // Coming back to a watched file: catch up straight away.
        if watching, window != nil { refreshFromDisk() }
    }

    deinit {
        watchTimer?.invalidate()
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
        language = SyntaxLanguage(path: path)
        header.canFormat = language != nil
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
                storage.addAttribute(.foregroundColor, value: Config.shared.theme.foreground, range: NSRange(location: 0, length: storage.length))
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
        media?.frame = scroll.frame
        diffView?.frame = scroll.frame
        graphView?.frame = scroll.frame
        statusView?.frame = scroll.frame
        if let bar = findBar {
            let w = min(420, bounds.width - 24)
            bar.frame = NSRect(x: bounds.width - w - 12, y: scroll.frame.minY + 6, width: w, height: bar.preferredHeight)
        }
        previewView?.frame = scroll.frame
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
        window?.makeFirstResponder(media?.focusView ?? diffView ?? graphView ?? statusView ?? previewView ?? textView)
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
        para.defaultTabInterval = space * 4
        para.tabStops = []
        textView.defaultParagraphStyle = para
        textView.typingAttributes = [.font: font, .foregroundColor: th.foreground, .paragraphStyle: para]
        if let storage = textView.textStorage, storage.length > 0 {
            storage.addAttributes([.font: font, .foregroundColor: th.foreground, .paragraphStyle: para],
                                  range: NSRange(location: 0, length: storage.length))
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
        if mode == .preview, previewView != nil { loadPreview() }
        header.needsDisplay = true
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let th = Config.shared.theme
        th.border.setFill()
        NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
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
        if mode == .graph { return loadGraph() }
        if mode == .status { return loadStatus() }
        if mode == .preview { return loadPreview() }
        if let kind = MediaKind(path: path) { return loadMedia(kind) }
        showMessage("Loading…")
        loadText(keepPlace: false)
    }

    /// The file's text: editable up to `maxEditableFileSize`; read-only past it, in full up to `maxReadableFileSize`
    /// (a big log, over ssh too) and past that its last `fileTailSize`. `keepPlace` (a reload) keeps the caret and
    /// scroll position.
    private func loadText(keepPlace: Bool) {
        fs.readPart(path, from: nil, whole: maxReadableFileSize, tail: fileTailSize) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let e):
                if !keepPlace { self.showMessage(e.localizedDescription) }
            case .success(let part):
                var data = part.data
                let cut = part.size > data.count
                let partial = part.size > maxEditableFileSize
                // A cut-off end starts at the first whole line.
                if cut, let nl = data.firstIndex(of: 0x0A) { data = Data(data[data.index(after: nl)...]) }
                if data.prefix(8000).contains(0) {
                    self.showMessage("This looks like a binary file, so it isn't shown.")
                    return
                }
                let (whole, rest) = Self.splitUTF8(data)
                let (bytes, crlf) = Self.droppingCR(whole)
                if crlf { self.usesCRLF = true }
                let text = String(decoding: bytes, as: UTF8.self)
                let caret = self.textView.selectedRange()
                let origin = self.scroll.contentView.bounds.origin
                // Long texts lay out only what's on screen.
                self.textView.layoutManager?.allowsNonContiguousLayout = text.utf16.count > 100_000
                self.textView.string = text
                self.findTextChanged()
                self.applyTheme()
                self.partial = partial
                self.textView.isEditable = !partial
                self.header.editable = !partial
                self.header.subtitle = cut ? "\(self.location) · last \(fileTailSize >> 20) MB of \(part.size >> 20) MB · read-only"
                    : partial ? "\(self.location) · \(part.size >> 20) MB · read-only" : self.location
                self.textView.undoManager?.removeAllActions()
                self.diskSize = part.size
                self.diskTail = Data(part.data.suffix(256))
                self.carry = rest
                if keepPlace {
                    let n = (text as NSString).length
                    self.textView.setSelectedRange(NSRange(location: min(caret.location, n), length: 0))
                    self.scroll.contentView.scroll(to: origin)
                    self.scroll.reflectScrolledClipView(self.scroll.contentView)
                } else {
                    self.textView.setSelectedRange(NSRange(location: partial ? (text as NSString).length : 0, length: 0))
                    if partial { self.textView.scrollRangeToVisible(self.textView.selectedRange()) }
                }
                self.loaded = true
                self.isDirty = false
                self.message.isHidden = true
                self.scroll.isHidden = false
                self.ruler.invalidateLines()
                // Only if asked for: a file shown by clicking it in the sidebar leaves the focus on the sidebar.
                if self.focusWhenLoaded { self.focus() }
                self.focusWhenLoaded = false
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

    // MARK: Watching

    @objc func toggleWatch(_ sender: Any?) { watching.toggle() }

    /// Every 5 seconds while watched and on screen (a tab not in front, or a file sub-tab not showing, has no window).
    private func updateWatchTimer() {
        let wanted = watching && window != nil && mode == .file
        if wanted, watchTimer == nil {
            watchTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refreshFromDisk() }
        } else if !wanted {
            watchTimer?.invalidate()
            watchTimer = nil
        }
    }

    /// Catches up with the file on disk: new bytes at the end are added (scrolling along if the end was in view,
    /// as with tail -f); anything else (rewritten, truncated, rotated) reloads it, keeping the place. Unsaved
    /// edits are never overwritten.
    func refreshFromDisk() {
        guard mode == .file, loaded, media == nil, !isDirty, !refreshing, !saving else { return }
        refreshing = true
        let from = max(0, diskSize - diskTail.count)
        fs.readPart(path, from: from, whole: 0, tail: fileTailSize) { [weak self] result in
            guard let self else { return }
            self.refreshing = false
            guard case .success(let part) = result, !self.isDirty else { return }
            let known = self.diskSize - from
            guard part.size >= self.diskSize, part.data.count >= known, part.data.prefix(known) == self.diskTail else {
                return self.loadText(keepPlace: true)
            }
            let added = Data(part.data.dropFirst(known))
            // More arrived than one read brings: start again from the end.
            if part.size - self.diskSize > added.count { return self.loadText(keepPlace: true) }
            guard !added.isEmpty else { return }
            self.diskSize = part.size
            self.diskTail = Data((self.diskTail + added).suffix(256))
            let (whole, rest) = Self.splitUTF8(self.carry + added)
            self.carry = rest
            let text = String(decoding: Self.droppingCR(whole).0, as: UTF8.self)
            guard !text.isEmpty, let storage = self.textView.textStorage else { return }
            let visible = self.scroll.contentView.bounds
            let atEnd = visible.maxY >= self.textView.frame.maxY - (self.textView.font?.pointSize ?? 13) * 3
            let end = storage.length
            storage.append(NSAttributedString(string: text, attributes: self.textView.typingAttributes))
            if self.language != nil, storage.length <= SyntaxHighlighter.maxLength { self.highlightSyntax() }
            self.ruler.linesAppended(from: end)
            self.findTextChanged()
            if atEnd { self.textView.scrollToEndOfDocument(nil) }
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
        guard let language else {
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

    /// Dev aid (DevTools hover-graph): the graph's card for `row`.
    func devHoverGraph(_ row: Int) { graphView?.devHover(row) }

    private func loadGraph() {
        header.editable = false
        header.textTools = false
        if graphView == nil { showMessage("Loading…") }
        let git = GitRunner(dir: path, remote: fs as? RemoteSession)
        git.run(GraphCommit.script, timeout: 60) { [weak self] status, out, err in
            guard let self else { return }
            let (head, commits) = GraphCommit.parse(out)
            guard !commits.isEmpty else {
                return self.showMessage(status == 0 ? "No commits yet." : err.isEmpty ? "Couldn't read the history." : err)
            }
            let view = self.graphView ?? GitGraphView(runner: git)
            if self.graphView == nil {
                self.graphView = view
                view.onViewChanges = { [weak self] hash in
                    guard let self else { return }
                    self.onOpenOther?(self.path, .commit(hash))
                }
                self.addSubview(view)
                self.needsLayout = true
                self.layoutSubtreeIfNeeded()
            }
            view.show(head: head, commits: commits)
            let count = commits.count >= GraphCommit.limit ? "latest \(commits.count) commits" : "\(commits.count) commit\(commits.count == 1 ? "" : "s")"
            self.header.subtitle = "\(self.location) · all branches · \(count)"
            self.message.isHidden = true
            self.scroll.isHidden = true
            if self.window?.firstResponder === self.window { self.focus() }
        }
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
        // Re-color once typing pauses rather than on every keystroke.
        pendingHighlight?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.highlightSyntax() }
        pendingHighlight = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func highlightSyntax() {
        guard let language, let storage = textView.textStorage, storage.length > 0 else { return }
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: Config.shared.theme.foreground, range: NSRange(location: 0, length: storage.length))
        SyntaxHighlighter.highlight(storage, as: language)
        storage.endEditing()
    }

    @objc func saveDocument(_ sender: Any?) {
        save(then: nil)
    }

    private func save(then next: (() -> Void)?) {
        guard loaded, !saving else { return }
        saving = true
        var text = textView.string
        if usesCRLF { text = text.replacingOccurrences(of: "\n", with: "\r\n") }
        let undoMark = textView.string
        header.status = "Saving…"
        fs.write(Data(text.utf8), to: path) { [weak self] error in
            guard let self else { return }
            self.saving = false
            if let error {
                self.header.status = nil
                self.presentAlert("Couldn't save “\((self.path as NSString).lastPathComponent)”", error.localizedDescription)
                return
            }
            // Only clean if nothing was typed while the save was in flight.
            if self.textView.string == undoMark { self.isDirty = false }
            // Our own write isn't a change to catch up with.
            let saved = Data(text.utf8)
            self.diskSize = saved.count
            self.diskTail = Data(saved.suffix(256))
            self.carry = Data()
            NotificationCenter.default.post(name: .solanumFileSaved, object: self.fs, userInfo: ["path": self.path])
            self.header.status = "Saved"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                if self?.header.status == "Saved" { self?.header.status = nil }
            }
            next?()
        }
    }

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

    /// ⌘G with the bar closed opens it first.
    private func stepFromMenu(_ d: Int) {
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
                let (ranges, capped) = expression.flatMap { e in text.map { EditorFind.matches(of: e, in: $0) } } ?? buffer.matches(of: query, options)
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
        let regex = (try? EditorFind.expression(q, o)).map { EditorFind.matches(of: $0, in: textView.string as NSString) }
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
}

/// ⌥Z toggles wrapping, as in VS Code.
final class EditorTextView: NSTextView {
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
    /// Off for read-only text (the end of a big file): no save button.
    var editable = true { didSet { needsDisplay = true } }
    /// Off for previews, diffs and graphs: only the close button shows.
    var textTools = true { didSet { needsDisplay = true } }
    /// A format with a formatter (JSON, YAML, XML) and not read-only: the format button shows.
    var canFormat = false { didSet { needsDisplay = true } }
    /// A Markdown file: the preview button shows.
    var canPreview = false { didSet { needsDisplay = true } }
    /// Git has changes for this file: the working tree button shows.
    var hasGitChanges = false { didSet { needsDisplay = true } }
    /// The eye is on: the file is re-read every few seconds.
    var watching = false { didSet { needsDisplay = true } }
    var onToggleWatch: (() -> Void)?
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

    /// Dev aid (DevTools header-press, print-header): the buttons showing, and pressing one by its tooltip's start.
    var devButtons: [String] { buttons.map(\.tip) }
    func devPress(_ tip: String) { buttons.first { $0.tip.hasPrefix(tip) }?.action?() }

    /// Right to left: close, save, format, wrap, watch, working tree, preview. No action: greyed out (save, with nothing to save).
    private var buttons: [(symbol: String, tip: String, active: Bool, action: (() -> Void)?)] {
        var b: [(symbol: String, tip: String, active: Bool, action: (() -> Void)?)] = [("xmark", "Close (⌘W)", false, onClose)]
        guard textTools else { return b }
        if editable { b.append((Self.saveIcon, dirty ? "Save (⌘S)" : "No Changes to Save", dirty, dirty ? onSave : nil)) }
        if editable, canFormat { b.append(("list.bullet.indent", "Beautify / Format Document (⌥⌘F)", false, onFormat)) }
        b.append(("text.word.spacing", wraps ? "Don't Wrap Lines (⌥Z)" : "Wrap Lines (⌥Z)", wraps, onToggleWrap))
        b.append((watching ? "eye.fill" : "eye",
                  watching ? "Stop Watching for Changes" : "Watch for Changes (re-reads the file every 5 seconds while it's showing)",
                  watching, onToggleWatch))
        if hasGitChanges { b.append(("plusminus", "Open Working Tree (this file's uncommitted changes)", false, onShowChanges)) }
        if canPreview { b.append(("doc.richtext", "Open Preview", false, onPreview)) }
        return b
    }

    override func draw(_ dirtyRect: NSRect) {
        let th = Config.shared.theme
        th.tabBarTint.setFill()
        bounds.fill()
        th.border.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()

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
        if !pathRect.isEmpty { addCursorRect(pathRect, cursor: .pointingHand) }
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
        let onPath = h == nil && pathRect.contains(convert(e.locationInWindow, from: nil))
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
        else if pathRect.contains(convert(e.locationInWindow, from: nil)) { onCopyPath?() }
    }
}

/// Line numbers in the editor's gutter.
final class LineNumberRuler: NSRulerView {
    weak var textView: NSTextView?
    var font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    /// UTF-16 offsets where each line starts; rebuilt lazily after edits.
    private var lineStarts: [Int]?

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
        let digits = max(3, String(lines).count)
        let w = (CGFloat(digits) * ("8" as NSString).size(withAttributes: [.font: font]).width + 22).rounded()
        if abs(ruleThickness - w) > 0.5 {
            reservedThicknessForMarkers = 0
            reservedThicknessForAccessoryView = 0
            ruleThickness = w
            // Make room for the new width; without a re-tile the numbers draw over the text until a resize.
            DispatchQueue.main.async { [weak self] in self?.scrollView?.tile() }
        }
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        let th = Config.shared.theme
        guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        let lines = starts()
        let visible = tv.visibleRect
        let glyphs = lm.glyphRange(forBoundingRect: visible, in: tc)
        let firstChar = lm.characterIndexForGlyph(at: glyphs.location)
        let caret = tv.selectedRange().location
        // Binary search for the first line on screen.
        var lo = 0, hi = lines.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lines[mid] <= firstChar { lo = mid } else { hi = mid - 1 }
        }
        let length = (tv.string as NSString).length
        let originY = tv.textContainerOrigin.y
        var line = lo
        while line < lines.count {
            let start = lines[line]
            let frag: NSRect
            if start >= length {
                // Empty last line after a trailing newline.
                guard start == length, length > 0 else { break }
                frag = lm.extraLineFragmentRect
            } else {
                frag = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: start), effectiveRange: nil)
            }
            let y = convert(NSPoint(x: 0, y: frag.minY + originY), from: tv).y
            if y > bounds.height { break }
            let isCaretLine = caret >= start && (line + 1 >= lines.count || caret < lines[line + 1])
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: isCaretLine ? th.foreground.withAlphaComponent(0.85) : th.dimText.withAlphaComponent(0.45)]
            let label = "\(line + 1)" as NSString
            let size = label.size(withAttributes: attrs)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 12, y: y + (frag.height - size.height) / 2), withAttributes: attrs)
            line += 1
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        // Scrolled sideways, the text passes under the bar: a solid, darker background keeps the numbers readable.
        if let tv = textView, tv.visibleRect.minX > 0 {
            let th = Config.shared.theme
            (th.background.usingColorSpace(.sRGB)?.blended(withFraction: 0.25, of: .black) ?? th.background).withAlphaComponent(1).setFill()
            bounds.fill()
            th.border.setFill()
            NSRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height).fill()
        }
        drawHashMarksAndLabels(in: dirtyRect)
    }
}
