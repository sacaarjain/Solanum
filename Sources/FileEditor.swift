import AppKit

/// A plain-text editor shown to the right of a tab's panes when a file is opened from the sidebar.
/// Works on local and ssh files alike through `FileSystem`. ⌘S saves, ⌘W closes, ⌥Z toggles wrapping.
/// Images, PDFs, video and audio show as a read-only preview instead (see `MediaPreviewView`).
final class FileEditorView: NSView, NSTextViewDelegate {
    let fs: FileSystem
    /// The file, or for a graph the repository's top folder.
    let path: String
    let mode: EditorMode
    /// What the sub-tab says.
    var displayName: String {
        switch mode {
        case .file: return (path as NSString).lastPathComponent
        case .diff: return (path as NSString).lastPathComponent + " (Working Tree)"
        case .graph: return "Git Graph"
        case .preview: return "Preview " + (path as NSString).lastPathComponent
        }
    }
    var onClose: (() -> Void)?

    private let header = EditorHeaderView()
    private let scroll = NSScrollView()
    private let textView: EditorTextView
    private let ruler: LineNumberRuler
    private let message = NSTextField(labelWithString: "")
    private var usesCRLF = false
    private var loaded = false
    private var saving = false
    private(set) var isDirty = false { didSet { header.dirty = isDirty } }
    private var wraps = false
    /// Colored as JSON, YAML or XML (see Syntax.swift); other files stay plain.
    private let language: SyntaxLanguage?
    private var pendingHighlight: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []
    private var media: MediaPreviewView?
    private var diffView: DiffView?
    private var graphView: GitGraphView?
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
        header.onToggleWrap = { [weak self] in self?.toggleWrap(nil) }
        header.onCopyPath = { [weak self] in self?.copyPath() }
        addSubview(header)

        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
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
        })
        if mode != .file {
            // Keep a diff or graph current: files change and commits land in other apps (or, for a diff, in this
            // file's own editor tab).
            for name in [NSApplication.didBecomeActiveNotification, .solanumFileSaved] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                    guard let self, note.name != .solanumFileSaved || note.userInfo?["path"] as? String == self.path else { return }
                    self.load()
                })
            }
        }
        load()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        if let dir = mediaCopy?.deletingLastPathComponent() { try? FileManager.default.removeItem(at: dir) }
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
        previewView?.frame = scroll.frame
    }

    func focus() {
        window?.makeFirstResponder(media?.focusView ?? diffView ?? graphView ?? previewView ?? textView)
    }

    private func applyTheme() {
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
        if mode == .diff { return loadDiff() }
        if mode == .graph { return loadGraph() }
        if mode == .preview { return loadPreview() }
        if let kind = MediaKind(path: path) { return loadMedia(kind) }
        showMessage("Loading…")
        fs.read(path) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let e):
                self.showMessage(e.localizedDescription)
            case .success(let data):
                if data.prefix(8000).contains(0) {
                    self.showMessage("This looks like a binary file, so it isn't shown.")
                    return
                }
                var text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
                if text.contains("\r\n") {
                    self.usesCRLF = true
                    text = text.replacingOccurrences(of: "\r\n", with: "\n")
                }
                self.textView.string = text
                self.applyTheme()
                self.textView.isEditable = true
                self.textView.undoManager?.removeAllActions()
                self.textView.setSelectedRange(NSRange(location: 0, length: 0))
                self.loaded = true
                self.isDirty = false
                self.message.isHidden = true
                self.scroll.isHidden = false
                self.ruler.invalidateLines()
                self.focus()
            }
        }
    }

    /// Local files preview in place; remote ones are copied to a temporary folder first, keeping their
    /// name so the extension still tells AppKit what they are.
    private func loadMedia(_ kind: MediaKind) {
        header.editable = false
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
    /// have yet diffs against nothing, and one deleted from disk against an empty right side.
    private func loadDiff() {
        header.editable = false
        if diffView == nil { showMessage("Loading…") }
        let name = (path as NSString).lastPathComponent
        let git = GitRunner(dir: (path as NSString).deletingLastPathComponent, remote: fs as? RemoteSession)
        git.run("git show \(shellQuote(":./" + name)) 2>/dev/null") { [weak self] _, out, _ in
            guard let self else { return }
            let old = String(decoding: out, as: UTF8.self)
            self.fs.read(self.path) { [weak self] result in
                guard let self else { return }
                let new = (try? result.get()).map { String(decoding: $0, as: UTF8.self) } ?? ""
                let view = self.diffView ?? DiffView()
                if self.diffView == nil {
                    self.diffView = view
                    self.addSubview(view)
                    self.needsLayout = true
                    self.layoutSubtreeIfNeeded()
                }
                view.show(old: old, new: new, language: self.language)
                self.header.subtitle = "\(self.location) · Index ↔ Working Tree · \(view.summary)"
                self.message.isHidden = true
                self.scroll.isHidden = true
                if self.window?.firstResponder === self.window { self.focus() }
            }
        }
    }

    /// The Markdown file rendered as a page (see Markdown.swift), refreshed when it's saved.
    private func loadPreview() {
        header.editable = false
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

    // MARK: Format Document

    /// ⇧⌥F: JSON, YAML or XML re-indented (see `Prettifier`), as one step ⌘Z undoes.
    @objc func formatDocument(_ sender: Any?) {
        guard mode == .file, loaded, media == nil else { return NSSound.beep() }
        guard let language else {
            header.status = "No formatter for this kind of file"
            return clearStatus(after: 2.5)
        }
        let text = textView.string
        let ext = (path as NSString).pathExtension.lowercased()
        let formatted: String
        do {
            // .jsonc / .json5 allow comments and other relaxations, so they skip the strict check.
            formatted = try Prettifier.format(text, as: language, strictJSON: ext == "json" || ext == "geojson" || ext == "webmanifest")
        } catch {
            return presentAlert("Couldn't format “\((path as NSString).lastPathComponent)”", error.localizedDescription)
        }
        guard formatted != text else {
            header.status = "Already formatted"
            return clearStatus(after: 1.5)
        }
        let caret = textView.selectedRange().location
        let all = NSRange(location: 0, length: (text as NSString).length)
        textView.insertText(formatted, replacementRange: all)
        textView.setSelectedRange(NSRange(location: min(caret, (formatted as NSString).length), length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())
        header.status = "Formatted"
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

    private func finderAction(_ action: NSTextFinder.Action) {
        guard media == nil else { return }
        let item = NSMenuItem()
        item.tag = action.rawValue
        textView.performTextFinderAction(item)
    }

    @objc func showFind(_ sender: Any?) { finderAction(.showFindInterface) }
    @objc func findNext(_ sender: Any?) { finderAction(.nextMatch) }
    @objc func findPrevious(_ sender: Any?) { finderAction(.previousMatch) }

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
enum EditorMode { case file, diff, graph, preview }

/// ⌥Z toggles wrapping, as in VS Code.
final class EditorTextView: NSTextView {
    override func keyDown(with e: NSEvent) {
        if e.modifierFlags.intersection([.command, .control, .option, .shift]) == .option, e.keyCode == 6 {
            NSApp.sendAction(#selector(FileEditorView.toggleWrap(_:)), to: nil, from: self)
            return
        }
        super.keyDown(with: e)
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
    /// Off for media previews: only the close button shows.
    var editable = true { didSet { needsDisplay = true } }
    var onClose: (() -> Void)?
    var onSave: (() -> Void)?
    var onToggleWrap: (() -> Void)?
    var onCopyPath: (() -> Void)?
    private var hover: Int?
    private var hoverPath = false
    private var buttonRects: [NSRect] = []
    private var pathRect = NSRect.zero

    override var isFlipped: Bool { true }

    private func symbol(_ name: String, _ color: NSColor) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium).applying(.init(paletteColors: [color]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
    }

    private var buttons: [(symbol: String, tip: String, action: (() -> Void)?)] {
        [("xmark", "Close (⌘W)", onClose), ("square.and.arrow.down", "Save (⌘S)", onSave),
         ("text.word.spacing", wraps ? "Don't Wrap Lines (⌥Z)" : "Wrap Lines (⌥Z)", onToggleWrap)].prefix(editable ? 3 : 1).map { $0 }
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
            let active = (i == 2 && wraps) || (i == 1 && dirty)
            if hover == i {
                th.foreground.withAlphaComponent(0.1).setFill()
                NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).fill()
            }
            if let img = symbol(b.symbol, active ? th.accent : th.foreground.withAlphaComponent(hover == i ? 0.9 : 0.6)) {
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
        trackingAreas.forEach(removeTrackingArea)
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

    private func starts() -> [Int] {
        if let l = lineStarts { return l }
        var out = [0]
        let s = (textView?.string ?? "") as NSString
        let n = s.length
        var i = 0
        let buf = UnsafeMutablePointer<unichar>.allocate(capacity: 4096)
        defer { buf.deallocate() }
        while i < n {
            let len = min(4096, n - i)
            s.getCharacters(buf, range: NSRange(location: i, length: len))
            for k in 0..<len where buf[k] == 10 { out.append(i + k + 1) }
            i += len
        }
        lineStarts = out
        let digits = max(3, String(out.count).count)
        let w = (CGFloat(digits) * ("8" as NSString).size(withAttributes: [.font: font]).width + 22).rounded()
        if abs(ruleThickness - w) > 0.5 {
            reservedThicknessForMarkers = 0
            reservedThicknessForAccessoryView = 0
            ruleThickness = w
            // Make room for the new width; without a re-tile the numbers draw over the text until a resize.
            DispatchQueue.main.async { [weak self] in self?.scrollView?.tile() }
        }
        return out
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
        drawHashMarksAndLabels(in: dirtyRect)
    }
}
