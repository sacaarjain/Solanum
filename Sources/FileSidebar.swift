import AppKit
import UniformTypeIdentifiers

/// One row in the sidebar tree. `children` is nil until the folder has been listed.
final class FileNode {
    let item: FileItem
    weak var parent: FileNode?
    var children: [FileNode]?
    /// `children` minus hidden files when those are switched off.
    var shown: [FileNode] = []

    init(_ item: FileItem, parent: FileNode?) {
        self.item = item
        self.parent = parent
    }
}

private let internalDragType = NSPasteboard.PasteboardType("local.solanum.file-path")

/// Hideable file tree on the left of a window (⌘B). It follows the focused pane's folder, on this Mac or,
/// inside an ssh session, on the remote host, unless the tab has a folder pinned (⇧⌘B, the pin button, or a
/// folder's context menu); then it stays put until unpinned. Each tab keeps its own pin. Click a file to open it in the editor; double-click a
/// folder to cd there; right-click for file operations. Files dragged between sidebars, or in from Finder,
/// move within one file system (⌥ copies) and copy between two (⌘ moves); ssh files drag out to Finder too.
final class FileSidebarView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate, NSTextFieldDelegate {
    var onOpenFile: ((FileSystem, String) -> Void)?
    /// Double-click on a file: open it in a tab of its own (no terminal).
    var onOpenFileInTab: ((FileSystem, String) -> Void)?
    /// "Open Working Tree": the file's uncommitted changes side by side.
    var onOpenDiff: ((FileSystem, String) -> Void)?
    var onChangeDirectory: ((String) -> Void)?

    /// The tree stays on the pinned folder instead of following the terminal.
    private(set) var isPinned = false
    /// The pin was set or cleared here (nil: unpinned), so the active tab can keep it.
    var onPinChanged: (((fs: FileSystem, path: String)?) -> Void)?
    /// What the terminal last asked to show, re-applied on unpin.
    private var lastFollow: (fs: FileSystem, directory: String?, status: String?)?
    /// The file open in the active tab's editor.
    private var editorFile: (fs: FileSystem, path: String)?

    /// The terminal's folder and the open file, when they're on the machine the tree shows. Their rows are
    /// highlighted (or, inside a collapsed folder, that folder is marked) and revealed when they change.
    private var terminalTarget: String? { lastFollow.flatMap { $0.fs === fs && $0.status == nil ? $0.directory : nil } }
    private var fileTarget: String? { editorFile.flatMap { $0.fs === fs ? $0.path : nil } }

    private(set) var fs: FileSystem = LocalFileSystem.shared
    private(set) var rootPath: String?
    private var rootNodes: [FileNode] = []
    private var shownRoot: [FileNode] = []
    /// The terminal folder last followed; the tree re-roots only when that changes.
    private var followed: String?
    private var loadToken = 0
    /// Folders left open in the active tab, per machine (keyed by host label, "" for this Mac), so moving to
    /// another folder and back re-opens them. Each tab keeps its own (see `applyTabOpenFolders`).
    private var openFolders: [String: Set<String>] = [:]
    private var openFoldersKey: String { fs.hostLabel ?? "" }
    /// Folders were opened or closed here, so the active tab can keep them.
    var onOpenFoldersChanged: (([String: Set<String>]) -> Void)?
    /// Shared by every sidebar, so files copied in one can be pasted in another (on another host, say).
    private static var clipboard: (fs: FileSystem, paths: [String], cut: Bool)?
    /// What this sidebar is dragging, and from where (its file system may change before the drop).
    private var dragOrigin: (fs: FileSystem, paths: [String])?
    /// Git changes under the folder shown (nil outside a repository), refreshed while the sidebar is up.
    private var gitStatus: GitTreeStatus?
    private var gitRunning = false
    private var gitAgain = false
    /// Every 10 s while on screen: ssh folders are listed again (this Mac's report changes as they happen)
    /// and git status is re-read.
    private var pollTimer: Timer?
    /// Changes on disk under a local root, as they happen.
    private var watcher: FSEventStreamRef?
    /// The root as FSEvents reports it: realpath(3), e.g. /tmp → /private/tmp (URL's symlink resolving goes the
    /// other way, dropping /private).
    private var watchedRealRoot = ""

    /// Transfers in progress ("Copying a.txt to host:~/dir"); the latest is shown in the status bar.
    private var activities: [(id: Int, text: String)] = []
    private var nextActivity = 0
    var onActivity: ((String?) -> Void)?
    private var showHidden = UserDefaults.standard.object(forKey: "solanum.sidebar.showHidden") as? Bool ?? true

    private let titleLabel = PassThroughLabel(labelWithString: "")
    private let badge = AgentBadgeView()
    private let titleEditor = NSTextField()
    /// Renames the active tab (empty: back to the default name).
    var onRenameTab: ((String) -> Void)?
    /// The active tab's own name, if it has one, and its shell's folder (the title otherwise).
    private var tabName: String?
    private var shellFolder: (path: String, home: String?)?
    private let subtitleLabel = NSTextField(labelWithString: "")
    private var buttons: [SidebarHeaderButton] = []
    private var pinButton: SidebarHeaderButton { buttons[0] }
    let outline = FileOutlineView()
    private let scroll = NSScrollView()
    private let placeholder = NSTextField(wrappingLabelWithString: "")
    static let headerHeight: CGFloat = 76

    override init(frame: NSRect) {
        super.init(frame: frame)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.toolTip = "Click to rename this tab"
        titleEditor.font = .systemFont(ofSize: 13, weight: .semibold)
        titleEditor.isBordered = false
        titleEditor.focusRingType = .none
        titleEditor.drawsBackground = true
        titleEditor.isHidden = true
        titleEditor.delegate = self
        titleEditor.cell?.isScrollable = true
        addSubview(badge)
        addSubview(titleEditor)
        subtitleLabel.font = .systemFont(ofSize: 10.5)
        subtitleLabel.lineBreakMode = .byTruncatingHead
        addSubview(titleLabel)
        addSubview(subtitleLabel)
        for (symbol, tip, action) in [("pin", "Pin This Folder (⇧⌘B)", #selector(togglePinFromButton(_:))),
                                      ("arrow.up", "Parent Folder", #selector(goToParent(_:))),
                                      ("doc.badge.plus", "New File…", #selector(newFile(_:))),
                                      ("folder.badge.plus", "New Folder…", #selector(newFolder(_:))),
                                      ("arrow.clockwise", "Refresh", #selector(refresh(_:))),
                                      ("ellipsis", "More", #selector(showMoreMenu(_:)))] {
            let b = SidebarHeaderButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage(), target: self, action: action)
            b.isBordered = false
            b.toolTip = tip
            b.imageScaling = .scaleProportionallyDown
            b.symbolConfiguration = .init(pointSize: 11, weight: .medium)
            buttons.append(b)
            addSubview(b)
        }

        let column = NSTableColumn(identifier: .init("name"))
        column.resizingMask = []
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .plain
        outline.backgroundColor = .clear
        outline.rowHeight = 22
        outline.indentationPerLevel = 12
        outline.allowsMultipleSelection = true
        // Sized by `fitColumn` instead, so every row ends at the same place.
        outline.columnAutoresizingStyle = .noColumnAutoresizing
        outline.autoresizesOutlineColumn = false
        outline.focusRingType = .none
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(rowClicked(_:))
        outline.doubleAction = #selector(rowDoubleClicked(_:))
        outline.sidebar = self
        outline.menu = NSMenu()
        outline.menu?.delegate = self
        outline.registerForDraggedTypes([.fileURL, internalDragType])
        NotificationCenter.default.addObserver(self, selector: #selector(filesChanged(_:)), name: .solanumFilesChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appBecameActive(_:)), name: NSApplication.didBecomeActiveNotification, object: nil)
        outline.setDraggingSourceOperationMask([.copy, .move], forLocal: false)
        outline.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)
        scroll.documentView = outline
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        addSubview(scroll)

        placeholder.alignment = .center
        placeholder.font = .systemFont(ofSize: 11.5)
        placeholder.isHidden = true
        addSubview(placeholder)
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        // Title (with the tab's agent in front), then the buttons, then the folder shown.
        var tx: CGFloat = 12
        badge.isHidden = badge.agent == nil
        if !badge.isHidden {
            badge.frame = NSRect(x: tx, y: 8, width: badge.fittingWidth, height: 18)
            tx = badge.frame.maxX + 6
        }
        titleLabel.frame = NSRect(x: tx, y: 8, width: max(20, bounds.width - tx - 12), height: 18)
        titleEditor.frame = titleLabel.frame.insetBy(dx: -3, dy: -1)
        window?.invalidateCursorRects(for: self)
        var x: CGFloat = 7
        for b in buttons {
            b.frame = NSRect(x: x, y: 31, width: 22, height: 22)
            x += 24
        }
        subtitleLabel.frame = NSRect(x: 12, y: 57, width: bounds.width - 24, height: 14)
        scroll.frame = NSRect(x: 0, y: Self.headerHeight, width: bounds.width - 1, height: bounds.height - Self.headerHeight)
        fitColumn()
        placeholder.frame = NSRect(x: 14, y: Self.headerHeight + 20, width: bounds.width - 28, height: 80)
    }

    func applyTheme() {
        let th = Config.shared.theme
        titleLabel.textColor = th.foreground
        titleEditor.textColor = th.foreground
        titleEditor.backgroundColor = th.background
        subtitleLabel.textColor = th.dimText
        badge.needsDisplay = true
        placeholder.textColor = th.dimText
        buttons.forEach { $0.tint = th.foreground }
        updatePinButton()
        appearance = NSAppearance(named: th.isDark ? .darkAqua : .aqua)
        outline.reloadData()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let th = Config.shared.theme
        th.tabBarTint.setFill()
        bounds.fill()
        th.border.setFill()
        NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill()
        // Hovering the tab's name outlines it like a text field: clicking edits it.
        if hoverTitle && titleEditor.isHidden {
            let box = NSBezierPath(roundedRect: titleBox, xRadius: 5, yRadius: 5)
            th.background.withAlphaComponent(0.5).setFill()
            box.fill()
            th.border.setStroke()
            box.lineWidth = 1
            box.stroke()
        }
    }

    // MARK: Hovering the name

    private var hoverTitle = false
    /// Dev aid (DevTools hover-title): shows the hover outline without a pointer.
    func devHoverTitle() { hoverTitle = true; needsDisplay = true }

    /// Around the tab's name as drawn (not the label's full width).
    private var titleBox: NSRect {
        let w = min(titleLabel.intrinsicContentSize.width, titleLabel.frame.width)
        return NSRect(x: titleLabel.frame.minX - 6, y: titleLabel.frame.minY - 4, width: max(w, 40) + 14, height: titleLabel.frame.height + 8)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: NSRect(x: 0, y: 0, width: bounds.width, height: Self.headerHeight),
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways], owner: self))
    }

    override func mouseMoved(with e: NSEvent) {
        let h = titleBox.contains(convert(e.locationInWindow, from: nil))
        if h != hoverTitle {
            hoverTitle = h
            needsDisplay = true
        }
    }

    override func mouseExited(with e: NSEvent) {
        if hoverTitle {
            hoverTitle = false
            needsDisplay = true
        }
    }

    override func resetCursorRects() {
        if titleEditor.isHidden { addCursorRect(titleBox, cursor: .iBeam) }
    }

    // MARK: Following the terminal

    /// Points the tree at `directory` on `fs` (the focused pane's folder). `status` replaces the tree with a message.
    func show(fs newFS: FileSystem, directory: String?, status: String? = nil) {
        let moved = lastFollow.map { $0.fs !== newFS || $0.directory != directory } ?? true
        lastFollow = (newFS, directory, status)
        guard !isPinned else {
            if moved { reveal(terminalTarget) }
            refreshMarks()
            return
        }
        if let status {
            fs = newFS
            followed = nil
            rootPath = nil
            watchRoot()
            rootNodes = []; shownRoot = []
            outline.reloadData()
            updateHeader()
            showPlaceholder(status)
            return
        }
        let sameFS = newFS === fs
        guard !sameFS || directory != followed || rootPath == nil else { return }
        fs = newFS
        followed = directory
        setRoot(directory ?? newFS.home ?? "/")
    }

    private func setRoot(_ path: String) {
        rootPath = path
        gitStatus = nil
        updateHeader()
        reload(expanding: openFolders[openFoldersKey] ?? [], revealTargets: true)
        refreshGit()
        watchRoot()
    }

    deinit {
        if let w = watcher {
            FSEventStreamStop(w)
            FSEventStreamInvalidate(w)
            FSEventStreamRelease(w)
        }
        pollTimer?.invalidate()
    }

    /// The file open in the editor (nil when none); its row is highlighted and revealed.
    func setEditorFile(_ path: String?, fs fileFS: FileSystem?) {
        let next = path.flatMap { p in fileFS.map { ($0, p) } }
        guard next?.1 != editorFile?.path || next?.0 !== editorFile?.fs else { return }
        editorFile = next
        reveal(fileTarget)
        refreshMarks()
    }

    /// The active tab: its own name (nil if it has none), its shell's folder, and its agent.
    func setTab(name: String?, folder: String?, home: String?, agent: AgentInfo?) {
        tabName = name
        shellFolder = folder.map { ($0, home) }
        if badge.agent != agent {
            badge.agent = agent
            needsLayout = true
        }
        updateHeader()
    }

    private func updateHeader() {
        // The tab's name, or else the folder its shell is in (else the folder shown).
        defer { window?.invalidateCursorRects(for: self); if hoverTitle { needsDisplay = true } }
        if let tabName {
            titleLabel.stringValue = tabName
        } else if let (path, home) = shellFolder {
            titleLabel.stringValue = path == home ? "~" : path == "/" ? "/" : (path as NSString).lastPathComponent
        } else if let rootPath {
            titleLabel.stringValue = rootPath == fs.home ? "~" : rootPath == "/" ? "/" : (rootPath as NSString).lastPathComponent
        } else {
            titleLabel.stringValue = fs.hostLabel ?? "Files"
        }
        guard let rootPath else {
            subtitleLabel.stringValue = ""
            return
        }
        let shown = FilePaths.abbreviate(rootPath, home: fs.home)
        subtitleLabel.stringValue = (isPinned ? "Pinned · " : "") + (fs.hostLabel.map { "\($0):\(shown)" } ?? shown)
        subtitleLabel.toolTip = rootPath
    }

    // MARK: Renaming the tab

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if titleBox.contains(p) {
            hoverTitle = false
            needsDisplay = true
            beginRename()
        } else {
            super.mouseDown(with: e)
        }
    }

    private func beginRename() {
        titleEditor.stringValue = tabName ?? ""
        titleEditor.placeholderString = titleLabel.stringValue
        titleEditor.isHidden = false
        titleLabel.isHidden = true
        window?.makeFirstResponder(titleEditor)
        titleEditor.currentEditor()?.selectAll(nil)
    }

    private func endRename(commit: Bool) {
        guard !titleEditor.isHidden else { return }
        titleEditor.isHidden = true
        titleLabel.isHidden = false
        if commit { onRenameTab?(titleEditor.stringValue) }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard (obj.object as? NSTextField) === titleEditor else { return }
        endRename(commit: true)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === titleEditor, selector == #selector(cancelOperation(_:)) else { return false }
        endRename(commit: false)
        window?.makeFirstResponder(outline)
        return true
    }

    // MARK: Pinning

    /// Keeps the tree on `path` (default: the folder shown now) whatever folder the terminal moves to.
    func pin(_ path: String? = nil, fs pinFS: FileSystem? = nil) {
        guard let target = path ?? rootPath else { return NSSound.beep() }
        let changed = pinFS.map { $0 !== fs } ?? false
        if let pinFS { fs = pinFS }
        isPinned = true
        if target != rootPath || changed { setRoot(target) } else { updateHeader() }
        updatePinButton()
        onPinChanged?((fs, target))
    }

    /// Goes back to following the focused pane's folder.
    func unpin() {
        guard isPinned else { return }
        isPinned = false
        updatePinButton()
        onPinChanged?(nil)
        if let last = lastFollow {
            // Forget the pinned root so `show` re-roots even if the terminal's folder hasn't changed.
            followed = nil
            rootPath = nil
            show(fs: last.fs, directory: last.directory, status: last.status)
        } else {
            updateHeader()
        }
    }

    func togglePin() { isPinned ? unpin() : pin() }

    /// Switching tabs: shows the new tab's pin (nil: none). The `show` that follows re-roots an unpinned tree.
    func applyTabPin(_ pinned: (fs: FileSystem, path: String)?) {
        if let pinned {
            guard !isPinned || pinned.fs !== fs || pinned.path != rootPath else { return }
            isPinned = true
            fs = pinned.fs
            setRoot(pinned.path)
        } else {
            guard isPinned else { return }
            isPinned = false
            followed = nil
            rootPath = nil
        }
        updatePinButton()
    }


    /// Switching tabs: the new tab's open folders (none for a brand-new tab), re-opened in the tree shown now.
    /// If the tab is somewhere else, the `show` that follows re-roots with them.
    func applyTabOpenFolders(_ folders: [String: Set<String>]) {
        openFolders = folders
        if rootPath != nil { reload(expanding: folders[openFoldersKey] ?? []) }
    }

    @objc private func togglePinFromButton(_ sender: Any?) { togglePin() }

    private func updatePinButton() {
        let th = Config.shared.theme
        pinButton.image = NSImage(systemSymbolName: isPinned ? "pin.fill" : "pin", accessibilityDescription: "Pin")
        pinButton.tint = isPinned ? th.accent : th.foreground
        pinButton.toolTip = isPinned ? "Unpin — follow Solanum's current folder again (⇧⌘B)" : "Pin This Folder (⇧⌘B)"
        pinButton.isActive = isPinned
    }

    private func showPlaceholder(_ text: String?) {
        placeholder.stringValue = text ?? ""
        placeholder.isHidden = text == nil
    }

    // MARK: Loading

    private var expandedPaths: Set<String> {
        var out = Set<String>()
        func walk(_ nodes: [FileNode]) {
            for n in nodes where n.item.isDirectory && outline.isItemExpanded(n) {
                out.insert(n.item.path)
                walk(n.shown)
            }
        }
        walk(shownRoot)
        return out
    }

    /// Lists the root again, then re-opens the folders in `expanding` (and, after re-rooting, the folders
    /// down to the terminal's folder and the open file).
    private func reload(expanding: Set<String>, revealTargets: Bool = false) {
        guard let root = rootPath else { return }
        loadToken += 1
        let token = loadToken
        let fs = self.fs
        fs.list(root) { [weak self] result in
            guard let self, token == self.loadToken, fs === self.fs else { return }
            switch result {
            case .failure(let e):
                self.rootNodes = []; self.shownRoot = []
                self.outline.reloadData()
                self.showPlaceholder(e.localizedDescription)
            case .success(let items):
                self.rootNodes = FilePaths.sortedForDisplay(self.withDeleted(items, in: root)).map { FileNode($0, parent: nil) }
                self.shownRoot = self.filter(self.rootNodes)
                self.outline.reloadData()
                self.showPlaceholder(items.isEmpty ? "This folder is empty." : nil)
                self.reexpand(self.shownRoot, expanding, token)
                if revealTargets {
                    self.reveal(self.terminalTarget)
                    self.reveal(self.fileTarget)
                }
                self.refreshMarks()
            }
        }
    }

    private func reexpand(_ nodes: [FileNode], _ paths: Set<String>, _ token: Int) {
        for n in nodes where n.item.isDirectory && paths.contains(n.item.path) {
            loadChildren(n) { [weak self] in
                guard let self, token == self.loadToken else { return }
                self.outline.expandItem(n)
                self.reexpand(n.shown, paths, token)
            }
        }
    }

    private func loadChildren(_ node: FileNode, _ then: (() -> Void)? = nil) {
        let fs = self.fs
        fs.list(node.item.path) { [weak self] result in
            guard let self, fs === self.fs else { return }
            let items = self.withDeleted((try? result.get()) ?? [], in: node.item.path)
            node.children = FilePaths.sortedForDisplay(items).map { FileNode($0, parent: node) }
            node.shown = self.filter(node.children ?? [])
            self.outline.reloadItem(node, reloadChildren: true)
            then?()
            self.refreshMarks()
        }
    }

    private func filter(_ nodes: [FileNode]) -> [FileNode] {
        showHidden ? nodes : nodes.filter { !$0.item.isHidden }
    }

    @objc func refresh(_ sender: Any?) {
        reload(expanding: expandedPaths)
        refreshGit()
    }

    // MARK: Git status

    /// Re-reads `git status` for the folder shown (on its machine), then updates the rows' letters and tints,
    /// and adds or drops the rows of deleted files.
    private func refreshGit() {
        guard let root = rootPath else { return }
        if gitRunning { gitAgain = true; return }
        gitRunning = true
        let fs = self.fs
        GitRunner(dir: root, remote: fs as? RemoteSession).run(GitTreeStatus.script, timeout: 15) { [weak self] status, out, _ in
            guard let self else { return }
            self.gitRunning = false
            if self.gitAgain {
                self.gitAgain = false
                return self.refreshGit()
            }
            guard fs === self.fs, root == self.rootPath else { return }
            let next = status == 0 ? GitTreeStatus(output: out, root: root) : nil
            guard next != self.gitStatus else { return }
            let deletedBefore = Set(self.gitStatus?.deleted.keys.map { $0 } ?? [])
            self.gitStatus = next
            deletedBefore.union(next?.deleted.keys.map { $0 } ?? []).forEach(self.refreshFolder)
            self.refreshMarks()
        }
        if pollTimer == nil {
            pollTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
                guard let self, NSApp.isActive, self.isOnScreen else { return }
                if self.fs.isRemote { self.refreshVisible() } else { self.refreshGit() }
            }
        }
    }

    // MARK: Keeping up with changes on disk

    private var isOnScreen: Bool { window?.isVisible == true && !isHidden && frame.maxX > 0 }

    /// Lists the root and every open folder again, updating just the rows that changed, and re-reads git
    /// status. For coming back to a sidebar (its tab, the app, the sidebar itself) and polling ssh folders.
    func refreshVisible() {
        guard rootPath != nil else { return }
        ([rootPath].compactMap { $0 } + expandedPaths.sorted()).forEach(refreshFolder)
    }

    /// Watches a local root for changes (FSEvents, coalesced over 0.4 s); nothing for ssh, which is polled.
    private func watchRoot() {
        if let w = watcher {
            FSEventStreamStop(w)
            FSEventStreamInvalidate(w)
            FSEventStreamRelease(w)
            watcher = nil
        }
        guard !fs.isRemote, let root = rootPath else { return }
        watchedRealRoot = realpath(root, nil).map { p in defer { free(p) }; return String(cString: p) } ?? root
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, paths, _, _ in
            guard let info else { return }
            let sidebar = Unmanaged<FileSidebarView>.fromOpaque(info).takeUnretainedValue()
            sidebar.changedOnDisk(unsafeBitCast(paths, to: NSArray.self) as? [String] ?? [])
        }
        guard let stream = FSEventStreamCreate(nil, callback, &context, [root] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.4,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes)) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        watcher = stream
    }

    /// Folders that changed on disk (reported by FSEvents): those listed in the tree are re-listed in place.
    /// While the sidebar is hidden nothing happens; it catches up when shown again.
    private func changedOnDisk(_ realPaths: [String]) {
        guard isOnScreen, let root = rootPath else { return }
        var dirs = Set<String>()
        var gitChanged = false
        for p in realPaths {
            var real = p
            while real.count > 1 && real.hasSuffix("/") { real.removeLast() }
            guard real == watchedRealRoot || real.hasPrefix(watchedRealRoot + "/") else { continue }
            let dir = root + real.dropFirst(watchedRealRoot.count)
            if dir.contains("/.git/") || dir.hasSuffix("/.git") { gitChanged = true }
            // Only folders listed in the tree matter (busy hidden folders like ~/Library change constantly).
            if dir == root || loadedNode(at: dir)?.children != nil { dirs.insert(dir) }
        }
        // Listing a folder refreshes git status too; inside .git only git status can have changed (a commit).
        dirs.forEach(refreshFolder)
        if dirs.isEmpty && gitChanged { refreshGit() }
    }

    override var isHidden: Bool {
        didSet { if oldValue && !isHidden { refreshVisible() } }
    }

    @objc private func appBecameActive(_ note: Notification) {
        if isOnScreen { refreshVisible() }
    }

    /// `items` plus a row for each file git tracks in `dir` that's gone from disk.
    private func withDeleted(_ items: [FileItem], in dir: String) -> [FileItem] {
        guard let names = gitStatus?.deleted[dir] else { return items }
        let present = Set(items.map(\.name))
        return items + names.filter { !present.contains($0) }.map {
            FileItem(name: $0, path: FilePaths.join(dir, $0), isDirectory: false, isDeleted: true)
        }
    }

    @objc private func filesChanged(_ note: Notification) {
        guard (note.object as AnyObject?) === fs, (note.userInfo?["sender"] as AnyObject?) !== self else { return }
        refreshGit()
        if let dirs = note.userInfo?["dirs"] as? [String] { Set(dirs).forEach(refreshFolder) } else { refresh(nil) }
    }

    /// Re-lists one folder already in the tree and inserts / removes just the rows that changed, so open
    /// folders, the selection and the scroll position stay as they are. A folder not loaded yet needs nothing.
    private func refreshFolder(_ dir: String) {
        let parent: FileNode?
        if dir == rootPath {
            parent = nil
        } else if let n = loadedNode(at: dir), n.children != nil {
            parent = n
        } else {
            return
        }
        let fs = self.fs
        fs.list(dir) { [weak self] result in
            guard let self, fs === self.fs, let items = try? result.get() else { return }
            guard parent != nil || dir == self.rootPath else { return }
            let old = parent?.children ?? self.rootNodes
            let oldShown = parent?.shown ?? self.shownRoot
            // Rows that are still there keep their node, and with it whether they're open and what's loaded inside.
            let byName = Dictionary(old.map { ($0.item.name, $0) }, uniquingKeysWith: { a, _ in a })
            let fresh = FilePaths.sortedForDisplay(self.withDeleted(items, in: dir)).map { item -> FileNode in
                if let n = byName[item.name], n.item.isDirectory == item.isDirectory, n.item.isDeleted == item.isDeleted { return n }
                return FileNode(item, parent: parent)
            }
            let shown = self.filter(fresh)
            if let parent {
                parent.children = fresh
                parent.shown = shown
            } else {
                self.rootNodes = fresh
                self.shownRoot = shown
                self.showPlaceholder(items.isEmpty ? "This folder is empty." : nil)
            }
            let diff = shown.difference(from: oldShown) { $0 === $1 }
            self.outline.beginUpdates()
            for case .remove(let i, _, _) in diff.removals.reversed() {
                self.outline.removeItems(at: IndexSet(integer: i), inParent: parent, withAnimation: .effectFade)
            }
            for case .insert(let i, _, _) in diff.insertions {
                self.outline.insertItems(at: IndexSet(integer: i), inParent: parent, withAnimation: .effectFade)
            }
            self.outline.endUpdates()
            self.refreshMarks()
        }
        refreshGit()
    }

    /// Dev aids (DevTools sidebar-expand / sidebar-import / print-rows).
    func devExpand(_ name: String) {
        if let n = shownRoot.first(where: { $0.item.name == name }) { loadChildren(n) { [weak self] in self?.outline.expandItem(n) } }
    }
    func devImport(_ path: String) { if let root = rootPath { importFiles([path], into: root) } }
    var devRows: String {
        (0..<outline.numberOfRows).compactMap { node(at: $0) }.map {
            String(repeating: "  ", count: outline.level(forItem: $0)) + $0.item.name + (outline.isItemExpanded($0) ? "/ (open)" : "")
        }.joined(separator: "\n")
    }

    /// The node for `path` among the folders listed so far.
    private func loadedNode(at path: String) -> FileNode? {
        var nodes = rootNodes
        while let n = nodes.first(where: { path == $0.item.path || path.hasPrefix($0.item.path + "/") }) {
            if n.item.path == path { return n }
            nodes = n.children ?? []
        }
        return nil
    }

    /// Tells the other sidebars showing `fs` which folders changed.
    private func announce(_ fs: FileSystem, _ dirs: [String]) {
        NotificationCenter.default.post(name: .solanumFilesChanged, object: fs, userInfo: ["sender": self, "dirs": dirs])
    }

    private func beginActivity(_ text: String) -> Int {
        nextActivity += 1
        activities.append((nextActivity, text))
        onActivity?(text)
        return nextActivity
    }

    private func endActivity(_ id: Int) {
        activities.removeAll { $0.id == id }
        onActivity?(activities.last?.text)
    }

    private static func describe(_ paths: [String], move: Bool, into dir: String, on fs: FileSystem) -> String {
        let what = paths.count == 1 ? (paths[0] as NSString).lastPathComponent : "\(paths.count) items"
        let place = (fs.hostLabel.map { $0 + ":" } ?? "") + FilePaths.abbreviate(dir, home: fs.home)
        return "\(move ? "Moving" : "Copying") \(what) to \(place)"
    }

    // MARK: Terminal folder and open file

    /// Expands the folders down to `path` (somewhere under the root) and scrolls its row into view.
    private func reveal(_ path: String?) {
        guard let path, let root = rootPath, path != root else { return }
        let prefix = root == "/" ? "/" : root + "/"
        guard path.hasPrefix(prefix) else { return }
        let names = path.dropFirst(prefix.count).split(separator: "/").map(String.init)
        let token = loadToken
        func step(_ nodes: [FileNode], _ i: Int) {
            // Stops quietly if the tree was re-rooted meanwhile or the item is filtered out (hidden files).
            guard token == loadToken, i < names.count, let n = nodes.first(where: { $0.item.name == names[i] }) else { return }
            guard i < names.count - 1 else {
                let row = outline.row(forItem: n)
                if row >= 0 { outline.scrollRowToVisible(row) }
                refreshMarks()
                return
            }
            guard n.item.isDirectory else { return }
            let descend = { [weak self] in
                guard let self else { return }
                self.outline.expandItem(n)
                step(n.shown, i + 1)
            }
            if n.children == nil { loadChildren(n, descend) } else { descend() }
        }
        step(shownRoot, 0)
    }

    /// Called after anything that changes the rows, so it also re-fits the column.
    private func refreshMarks() {
        outline.enumerateAvailableRowViews { rowView, row in
            if let rv = rowView as? SidebarRowView, let n = node(at: row) { applyMarks(rv, n) }
        }
        fitColumn()
    }

    private func marks(_ n: FileNode) -> (terminal: SidebarRowView.Mark, file: SidebarRowView.Mark) {
        let collapsed = n.item.isDirectory && !outline.isItemExpanded(n)
        func mark(_ target: String?) -> SidebarRowView.Mark {
            guard let target else { return .none }
            if target == n.item.path { return .here }
            return collapsed && target.hasPrefix(n.item.path + "/") ? .inside : .none
        }
        return (mark(terminalTarget), mark(fileTarget))
    }

    private func applyMarks(_ rv: SidebarRowView, _ n: FileNode) {
        (rv.terminalMark, rv.fileMark) = marks(n)
        let code = n.item.isDeleted ? "D" : gitStatus?.code(for: n.item.path, isDirectory: n.item.isDirectory)
        rv.git = code.map { c in
            let b = GitTreeStatus.badge(c)
            return SidebarRowView.GitBadge(letter: b.letter, color: b.color, tinted: !n.item.isDirectory)
        }
    }

    /// Names are never cut short: the column is as wide as the longest row (scroll sideways to see it all), or the
    /// sidebar when everything fits. Rows all end at the column's edge, so the git letters line up there.
    private func fitColumn() {
        guard let column = outline.tableColumns.first else { return }
        let font = NSFont.systemFont(ofSize: 12.5)
        var widest: CGFloat = 0
        for row in 0..<outline.numberOfRows {
            guard let n = node(at: row) else { continue }
            let name = ceil((n.item.name as NSString).size(withAttributes: [.font: font]).width)
            // Room on the right for the git letter, plus the terminal glyph and open-file dot when shown.
            let m = marks(n)
            let trailing: CGFloat = 26 + (m.terminal == .none ? 0 : 18) + (m.file == .inside ? 11 : 0)
            // The cell's indent, then the icon (2 + 16 + 5) before the name.
            widest = max(widest, outline.frameOfCell(atColumn: 0, row: row).minX + 23 + name + trailing)
        }
        let width = max(scroll.contentView.bounds.width - outline.intercellSpacing.width, widest)
        if abs(column.width - width) > 0.5 { column.width = width }
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        if let n = notification.userInfo?["NSObject"] as? FileNode, openFolders[openFoldersKey]?.contains(n.item.path) != true {
            openFolders[openFoldersKey, default: []].insert(n.item.path)
            onOpenFoldersChanged?(openFolders)
        }
        refreshMarks()
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        if let n = notification.userInfo?["NSObject"] as? FileNode {
            // Folders inside close with it.
            let path = n.item.path
            openFolders[openFoldersKey] = openFolders[openFoldersKey]?.filter { $0 != path && !$0.hasPrefix(path + "/") }
            onOpenFoldersChanged?(openFolders)
        }
        refreshMarks()
    }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let n = item as? FileNode else { return shownRoot.count }
        return n.shown.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let n = item as? FileNode else { return shownRoot[index] }
        return n.shown[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileNode)?.item.isDirectory ?? false
    }

    func outlineViewItemWillExpand(_ notification: Notification) {
        guard let n = notification.userInfo?["NSObject"] as? FileNode, n.children == nil else { return }
        loadChildren(n)
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let rv = SidebarRowView()
        if let n = item as? FileNode { applyMarks(rv, n) }
        return rv
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }
        let id = NSUserInterfaceItemIdentifier("FileCell")
        let cell = (outlineView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? makeCell(id)
        let th = Config.shared.theme
        if node.item.isDeleted {
            cell.textField?.attributedStringValue = NSAttributedString(string: node.item.name, attributes: [
                .strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: th.foreground.withAlphaComponent(0.45),
                .font: cell.textField?.font ?? .systemFont(ofSize: 12.5)])
        } else {
            cell.textField?.stringValue = node.item.name
            cell.textField?.textColor = node.item.isHidden ? th.foreground.withAlphaComponent(0.55) : th.foreground.withAlphaComponent(0.9)
        }
        let symbol = node.item.isDirectory ? "folder.fill" : Self.symbol(for: node.item.name)
        let tint = node.item.isDirectory ? th.accent.withAlphaComponent(0.85) : th.dimText
        cell.imageView?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular).applying(.init(paletteColors: [tint])))
        return cell
    }

    private func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let img = NSImageView()
        let text = NSTextField(labelWithString: "")
        text.font = .systemFont(ofSize: 12.5)
        text.lineBreakMode = .byClipping
        for v in [img, text] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(v)
        }
        cell.imageView = img
        cell.textField = text
        NSLayoutConstraint.activate([
            img.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            img.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            img.widthAnchor.constraint(equalToConstant: 16),
            text.leadingAnchor.constraint(equalTo: img.trailingAnchor, constant: 5),
            // Clear of the git letter drawn at the row's right edge.
            text.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -20),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    static func symbol(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "heic", "tiff", "bmp", "webp", "svg", "ico": return "photo"
        case "zip", "gz", "tgz", "bz2", "xz", "tar", "7z", "rar": return "doc.zipper"
        case "pdf": return "doc.richtext"
        case "mp4", "m4v", "mov", "avi", "mkv", "webm": return "film"
        case "mp3", "m4a", "aac", "wav", "aiff", "aif", "flac", "caf", "ogg": return "waveform"
        case "md", "txt", "rst", "log", "csv", "tsv": return "doc.text"
        case "swift", "py", "js", "ts", "tsx", "jsx", "c", "h", "cpp", "hpp", "m", "go", "rs", "java", "kt", "rb", "php",
             "sh", "bash", "zsh", "json", "yaml", "yml", "toml", "xml", "html", "css", "sql", "r", "pl", "lua":
            return "chevron.left.forwardslash.chevron.right"
        default: return "doc"
        }
    }

    // MARK: Clicks

    private func node(at row: Int) -> FileNode? {
        row >= 0 ? outline.item(atRow: row) as? FileNode : nil
    }

    @objc private func rowClicked(_ sender: Any?) {
        let row = outline.clickedRow
        guard let n = node(at: row) else { return }
        // Clicks on the disclosure triangle already toggled the folder.
        if let e = NSApp.currentEvent, outline.frameOfOutlineCell(atRow: row).contains(outline.convert(e.locationInWindow, from: nil)) { return }
        if NSApp.currentEvent?.modifierFlags.contains(.command) == true || NSApp.currentEvent?.modifierFlags.contains(.shift) == true { return }
        if n.item.isDeleted { return }
        if n.item.isDirectory {
            outline.isItemExpanded(n) ? outline.collapseItem(n) : outline.expandItem(n)
        } else {
            onOpenFile?(fs, n.item.path)
        }
    }

    @objc private func rowDoubleClicked(_ sender: Any?) {
        guard let n = node(at: outline.clickedRow), !n.item.isDeleted else { return }
        if n.item.isDirectory { onChangeDirectory?(n.item.path) } else { onOpenFileInTab?(fs, n.item.path) }
    }

    /// Return opens the selected file or toggles the selected folder.
    func openSelection() {
        guard let n = node(at: outline.selectedRow), !n.item.isDeleted else { return }
        if n.item.isDirectory {
            outline.isItemExpanded(n) ? outline.collapseItem(n) : outline.expandItem(n)
        } else {
            onOpenFile?(fs, n.item.path)
        }
    }

    // MARK: Targets of an action

    /// The clicked row (or the selection, if the click was inside it); the keyboard selection otherwise.
    private func targetNodes(fromMenu: Bool) -> [FileNode] {
        let clicked = outline.clickedRow
        if fromMenu, clicked >= 0, !outline.selectedRowIndexes.contains(clicked) {
            return node(at: clicked).map { [$0] } ?? []
        }
        return outline.selectedRowIndexes.compactMap { node(at: $0) }
    }

    /// Folder that new or pasted items go into: the clicked folder, the clicked file's folder, or the root.
    private func destinationFolder(_ nodes: [FileNode]) -> String? {
        guard let n = nodes.first else { return rootPath }
        return n.item.isDirectory ? n.item.path : FilePaths.parent(n.item.path)
    }

    private var menuContext = false

    private func names(in dir: String, on fs: FileSystem? = nil, _ done: @escaping (Set<String>) -> Void) {
        (fs ?? self.fs).list(dir) { done(Set(((try? $0.get()) ?? []).map(\.name))) }
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let nodes = targetNodes(fromMenu: true)
        let single = nodes.count == 1 ? nodes.first : nil
        func add(_ title: String, _ action: Selector, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: enabled ? action : nil, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        menuContext = true
        if let n = single, !n.item.isDirectory {
            add("Open", #selector(openFromMenu(_:)))
            if n.item.isDeleted || gitStatus?.code(for: n.item.path, isDirectory: false) != nil {
                add("Open Working Tree", #selector(openDiffFromMenu(_:)))
            }
        }
        if let n = single, n.item.isDirectory {
            add("Open in Solanum", #selector(cdFromMenu(_:)))
            add("Pin as Sidebar Root", #selector(pinFromMenu(_:)))
        }
        if single != nil { menu.addItem(.separator()) }
        add("New File…", #selector(newFile(_:)))
        add("New Folder…", #selector(newFolder(_:)))
        menu.addItem(.separator())
        if !nodes.isEmpty {
            add("Cut", #selector(cut(_:)))
            add("Copy", #selector(copy(_:)))
        }
        add("Paste", #selector(paste(_:)), enabled: Self.clipboard != nil)
        if !nodes.isEmpty {
            add("Duplicate", #selector(duplicate(_:)))
            menu.addItem(.separator())
            add(nodes.count > 1 ? "Copy Paths" : "Copy Path", #selector(copyPath(_:)))
            if single != nil { add("Rename…", #selector(rename(_:))) }
            add(fs.isRemote ? "Delete…" : "Move to Trash", #selector(delete(_:)))
        }
        menu.addItem(.separator())
        if fs.isRemote {
            if !nodes.isEmpty { add("Download to Downloads", #selector(download(_:))) }
            add("Upload Files Here…", #selector(uploadPicker(_:)))
        } else {
            add("Reveal in Finder", #selector(revealInFinder(_:)))
            if let n = single, !n.item.isDirectory { add("Open with Default App", #selector(openExternally(_:))) }
        }
        add("Refresh", #selector(refresh(_:)))
    }

    func menuDidClose(_ menu: NSMenu) {
        // Actions run after the menu closes; let them see the clicked row first.
        DispatchQueue.main.async { self.menuContext = false }
    }

    private var targets: [FileNode] { targetNodes(fromMenu: menuContext) }

    @objc private func openFromMenu(_ sender: Any?) {
        if let n = targets.first { onOpenFile?(fs, n.item.path) }
    }

    @objc private func openDiffFromMenu(_ sender: Any?) {
        if let n = targets.first { onOpenDiff?(fs, n.item.path) }
    }

    @objc private func cdFromMenu(_ sender: Any?) {
        if let n = targets.first { onChangeDirectory?(n.item.path) }
    }

    @objc private func pinFromMenu(_ sender: Any?) {
        if let n = targets.first, n.item.isDirectory { pin(n.item.path) }
    }

    @objc private func showMoreMenu(_ sender: NSButton) {
        let menu = NSMenu()
        let hidden = ActionMenuItem("Show Hidden Files", checked: showHidden) { [weak self] in self?.toggleHidden() }
        menu.addItem(hidden)
        menu.addItem(ActionMenuItem("Collapse All") { [weak self] in self?.outline.collapseItem(nil, collapseChildren: true) })
        if let root = rootPath {
            menu.addItem(ActionMenuItem("Open This Folder in Solanum") { [weak self] in self?.onChangeDirectory?(root) })
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    private func toggleHidden() {
        showHidden.toggle()
        UserDefaults.standard.set(showHidden, forKey: "solanum.sidebar.showHidden")
        reload(expanding: expandedPaths)
    }

    @objc private func goToParent(_ sender: Any?) {
        guard let root = rootPath, root != "/" else { return }
        setRoot(FilePaths.parent(root))
    }

    // MARK: File operations

    private func fail(_ title: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        if let w = window { alert.beginSheetModal(for: w) } else { alert.runModal() }
        refresh(nil)
    }

    /// Asks for a name in a sheet; `done` is called only for a non-empty, slash-free name.
    private func askName(_ title: String, initial: String, button: String, _ done: @escaping (String) -> Void) {
        guard let w = window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = initial
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: w) { resp in
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard resp == .alertFirstButtonReturn, !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { return }
            done(name)
        }
        // Select the name without its extension, as Finder does.
        DispatchQueue.main.async {
            let stem = (initial as NSString).deletingPathExtension
            field.currentEditor()?.selectedRange = NSRange(location: 0, length: (stem.isEmpty ? initial : stem).utf16.count)
        }
    }

    @objc func newFile(_ sender: Any?) {
        guard let dir = destinationFolder(targets) else { return }
        askName("New File", initial: "", button: "Create") { [weak self] name in
            guard let self else { return }
            let path = FilePaths.join(dir, name)
            self.fs.perform(.makeFile(path)) { error in
                if let error { return self.fail("Couldn't create the file", error) }
                self.refreshShowing(dir)
                self.onOpenFile?(self.fs, path)
            }
        }
    }

    @objc func newFolder(_ sender: Any?) {
        guard let dir = destinationFolder(targets) else { return }
        askName("New Folder", initial: "", button: "Create") { [weak self] name in
            guard let self else { return }
            self.fs.perform(.makeDirectory(FilePaths.join(dir, name))) { error in
                if let error { return self.fail("Couldn't create the folder", error) }
                self.refreshShowing(dir)
            }
        }
    }

    /// Refreshes, keeping `dir` open so a newly created item is visible.
    private func refreshShowing(_ dir: String) {
        var paths = expandedPaths
        var d = dir
        while let root = rootPath, d.hasPrefix(root), d != root {
            paths.insert(d)
            d = FilePaths.parent(d)
        }
        reload(expanding: paths)
    }

    @objc func rename(_ sender: Any?) {
        guard let n = targets.first else { return }
        askName("Rename “\(n.item.name)”", initial: n.item.name, button: "Rename") { [weak self] name in
            guard let self, name != n.item.name else { return }
            let to = FilePaths.join(FilePaths.parent(n.item.path), name)
            self.fs.perform(.move(n.item.path, to: to)) { error in
                if let error { return self.fail("Couldn't rename “\(n.item.name)”", error) }
                self.refresh(nil)
            }
        }
    }

    @objc func delete(_ sender: Any?) {
        let nodes = targets
        guard !nodes.isEmpty, let w = window else { return }
        let alert = NSAlert()
        let what = nodes.count == 1 ? "“\(nodes[0].item.name)”" : "\(nodes.count) items"
        if fs.isRemote {
            alert.messageText = "Delete \(what)?"
            alert.informativeText = "This permanently deletes \(nodes.count == 1 ? "it" : "them") on \(fs.hostLabel ?? "the server"). This can't be undone."
            alert.addButton(withTitle: "Delete")
        } else {
            alert.messageText = "Move \(what) to the Trash?"
            alert.addButton(withTitle: "Move to Trash")
        }
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: w) { [weak self] resp in
            guard let self, resp == .alertFirstButtonReturn else { return }
            self.fs.perform(.delete(nodes.map(\.item.path))) { error in
                if let error { return self.fail("Couldn't delete \(what)", error) }
                self.refresh(nil)
            }
        }
    }

    @objc func copy(_ sender: Any?) { stash(cut: false) }
    @objc func cut(_ sender: Any?) { stash(cut: true) }

    private func stash(cut: Bool) {
        let paths = targets.map(\.item.path)
        guard !paths.isEmpty else { return }
        Self.clipboard = (fs, paths, cut)
        // Also put the paths on the system clipboard so they can be pasted into the terminal.
        NSPasteboard.general.clearContents()
        if fs.isRemote {
            NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
        } else {
            NSPasteboard.general.writeObjects(paths.map { URL(fileURLWithPath: $0) as NSURL })
            NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
        }
    }

    @objc func paste(_ sender: Any?) {
        guard let clip = Self.clipboard, let dir = destinationFolder(targets) else {
            NSSound.beep()
            return
        }
        copyOrMove(clip.paths, from: clip.fs, into: dir, move: clip.cut)
        if clip.cut { Self.clipboard = nil }
    }

    @objc func duplicate(_ sender: Any?) {
        let nodes = targets
        guard let first = nodes.first else { return }
        let dir = FilePaths.parent(first.item.path)
        transfer(nodes.filter { FilePaths.parent($0.item.path) == dir }.map(\.item.path), into: dir, move: false)
    }

    /// Copies or moves `paths` (on this sidebar's file system) into `dir`, renaming on collisions.
    private func transfer(_ paths: [String], into dir: String, move: Bool) {
        let fs = self.fs
        let activity = beginActivity(Self.describe(paths, move: move, into: dir, on: fs))
        let sources = move ? Array(Set(paths.map(FilePaths.parent))) : []
        names(in: dir) { [weak self] existing in
            var taken = existing
            var remaining = paths.count
            var firstError: Error?
            for p in paths {
                let name = (p as NSString).lastPathComponent
                if move && FilePaths.parent(p) == dir { remaining -= 1; continue }
                if move && (dir == p || dir.hasPrefix(p + "/")) { remaining -= 1; continue }
                let target = FilePaths.uniqueName(name, taken: taken)
                taken.insert(target)
                let to = FilePaths.join(dir, target)
                fs.perform(move ? .move(p, to: to) : .copy(p, to: to)) { error in
                    if firstError == nil { firstError = error }
                    remaining -= 1
                    if remaining == 0 { self?.finishTransfer(firstError, dir, sources, move, activity) }
                }
            }
            if remaining == 0 { self?.finishTransfer(firstError, dir, sources, move, activity) }
        }
    }

    private func finishTransfer(_ error: Error?, _ dir: String, _ sources: [String], _ move: Bool, _ activity: Int) {
        endActivity(activity)
        if let error { return fail(move ? "Couldn't move the items" : "Couldn't copy the items", error) }
        ([dir] + sources).forEach(refreshFolder)
        announce(fs, [dir] + sources)
    }

    /// Copies or moves `paths` from `src` into `dir` on `dst` (this sidebar's file system unless given).
    /// Within one file system that's a plain cp / mv; between two, each item is streamed across in turn
    /// (see `FileTransfer`) and a move deletes the originals once all of them have arrived. `then` gets
    /// the new paths.
    private func copyOrMove(_ paths: [String], from src: FileSystem, into dir: String, on dst: FileSystem? = nil,
                            move: Bool, then: (([String]) -> Void)? = nil) {
        let dst = dst ?? fs
        guard !paths.isEmpty else { return }
        if src === dst && dst === fs { return transfer(paths, into: dir, move: move) }
        let what = paths.count == 1 ? "“\((paths[0] as NSString).lastPathComponent)”" : "\(paths.count) items"
        let activity = beginActivity(Self.describe(paths, move: move, into: dir, on: dst))
        names(in: dir, on: dst) { [weak self] existing in
            var taken = existing
            let jobs = paths.map { p -> (from: String, name: String) in
                let name = FilePaths.uniqueName((p as NSString).lastPathComponent, taken: taken)
                taken.insert(name)
                return (p, name)
            }
            func finish(_ error: Error?) {
                guard let self else { return }
                self.endActivity(activity)
                self.announce(dst, [dir])
                if dst === self.fs { self.refreshFolder(dir) }
                if let error {
                    self.fail(move ? "Couldn't move \(what)" : "Couldn't copy \(what)", error)
                    return
                }
                then?(jobs.map { FilePaths.join(dir, $0.name) })
                guard move else { return }
                let sources = Array(Set(paths.map(FilePaths.parent)))
                src.perform(.delete(paths)) { [weak self] error in
                    guard let self else { return }
                    self.announce(src, sources)
                    if src === self.fs { sources.forEach(self.refreshFolder) }
                    if let error { self.fail("Copied \(what), but couldn't remove the originals", error) }
                }
            }
            func next(_ i: Int) {
                guard i < jobs.count else { return finish(nil) }
                FileTransfer.copy(jobs[i].from, from: src, into: dir, as: jobs[i].name, on: dst) { error in
                    if let error { return finish(error) }
                    next(i + 1)
                }
            }
            next(0)
        }
    }

    @objc func copyPath(_ sender: Any?) {
        let paths = targets.map(\.item.path)
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
    }

    @objc private func revealInFinder(_ sender: Any?) {
        let urls = targets.map { URL(fileURLWithPath: $0.item.path) }
        if urls.isEmpty, let root = rootPath {
            NSWorkspace.shared.open(URL(fileURLWithPath: root))
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }

    @objc private func openExternally(_ sender: Any?) {
        targets.forEach { NSWorkspace.shared.open(URL(fileURLWithPath: $0.item.path)) }
    }

    @objc private func download(_ sender: Any?) {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path ?? NSHomeDirectory()
        copyOrMove(targets.map(\.item.path), from: fs, into: downloads, on: LocalFileSystem.shared, move: false) { paths in
            NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(fileURLWithPath: $0) })
        }
    }

    @objc private func uploadPicker(_ sender: Any?) {
        guard let w = window, let dir = destinationFolder(targets) else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Upload"
        panel.message = "Upload to \(fs.hostLabel ?? "server"):\(dir)"
        panel.beginSheetModal(for: w) { [weak self] resp in
            guard resp == .OK else { return }
            self?.importFiles(panel.urls.map(\.path), into: dir)
        }
    }

    /// Files from Finder: copied (here) or uploaded (ssh).
    private func importFiles(_ localPaths: [String], into dir: String) {
        copyOrMove(localPaths, from: LocalFileSystem.shared, into: dir, move: false)
    }

    // MARK: Drag and drop

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let n = item as? FileNode, !n.item.isDeleted else { return nil }
        if let remote = fs as? RemoteSession { return RemoteFilePromise(remote, n.item) }
        let pb = NSPasteboardItem()
        pb.setString(n.item.path, forType: internalDragType)
        pb.setString(URL(fileURLWithPath: n.item.path).absoluteString, forType: .fileURL)
        pb.setString(n.item.path, forType: .string)
        return pb
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forItems draggedItems: [Any]) {
        dragOrigin = (fs, draggedItems.compactMap { ($0 as? FileNode)?.item.path })
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragOrigin = nil
    }

    private func dropFolder(_ item: Any?) -> FileNode? {
        guard let n = item as? FileNode else { return nil }
        return n.item.isDirectory ? n : n.parent
    }

    /// A drag from this or another sidebar: where it came from, and whether it moves. As in Finder, it
    /// moves within one file system and copies between two; ⌥ forces a copy, ⌘ a move.
    private func sidebarDrag(_ info: NSDraggingInfo) -> (fs: FileSystem, paths: [String], move: Bool)? {
        guard let origin = (info.draggingSource as? FileOutlineView)?.sidebar?.dragOrigin else { return nil }
        let mask = info.draggingSourceOperationMask
        let move = origin.fs === fs ? mask != .copy : mask == .generic
        return (origin.fs, origin.paths, move)
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        let target = dropFolder(item)
        outlineView.setDropItem(target, dropChildIndex: NSOutlineViewDropOnItemIndex)
        if let drag = sidebarDrag(info) {
            guard drag.move else { return .copy }
            return info.draggingSourceOperationMask.contains(.move) ? .move : .generic
        }
        return info.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ? .copy : []
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let dir = dropFolder(item)?.item.path ?? rootPath else { return false }
        if let drag = sidebarDrag(info) {
            copyOrMove(drag.paths, from: drag.fs, into: dir, move: drag.move)
            return !drag.paths.isEmpty
        }
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        importFiles(urls.map(\.path), into: dir)
        return true
    }
}

/// An ssh file or folder dragged out of the sidebar. Finder (or any app that takes file promises) gets it
/// downloaded to wherever it's dropped; the terminal and other sidebars read its path from the pasteboard.
final class RemoteFilePromise: NSFilePromiseProvider, NSFilePromiseProviderDelegate {
    private let remote: RemoteSession
    private let item: FileItem

    init(_ remote: RemoteSession, _ item: FileItem) {
        self.remote = remote
        self.item = item
        super.init()
        fileType = item.isDirectory ? UTType.folder.identifier : UTType.data.identifier
        delegate = self
    }

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        super.writableTypes(for: pasteboard) + [internalDragType, .string]
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        type == internalDragType || type == .string ? item.path : super.pasteboardPropertyList(forType: type)
    }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        item.name
    }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        let dir = url.deletingLastPathComponent().path
        let taken = Set((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
        FileTransfer.copy(item.path, from: remote, into: dir, as: FilePaths.uniqueName(url.lastPathComponent, taken: taken),
                          on: LocalFileSystem.shared, completionHandler)
    }
}

/// Keyboard shortcuts for the tree: Return opens, ⌘⌫ deletes, ⌘C / ⌘X / ⌘V copy, cut and paste.
final class FileOutlineView: NSOutlineView {
    weak var sidebar: FileSidebarView?

    // Disclosure triangles and row contents sit a little in from the edge, inside the rounded selection
    // highlight (which is inset 6pt) instead of hanging off its left end.
    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        super.frameOfOutlineCell(atRow: row).offsetBy(dx: 7, dy: 0)
    }

    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        var r = super.frameOfCell(atColumn: column, row: row)
        r.origin.x += 7
        r.size.width = max(0, r.size.width - 13)
        return r
    }

    override func keyDown(with e: NSEvent) {
        let mods = e.modifierFlags.intersection([.command, .control, .option, .shift])
        switch (e.keyCode, mods) {
        case (36, []), (76, []): sidebar?.openSelection()
        case (51, .command): sidebar?.delete(nil)
        case (7, .command): sidebar?.cut(nil)
        default: super.keyDown(with: e)
        }
    }

    @objc func copy(_ sender: Any?) { sidebar?.copy(sender) }
    @objc func paste(_ sender: Any?) { sidebar?.paste(sender) }
    @objc func cut(_ sender: Any?) { sidebar?.cut(sender) }
}

/// Selection highlight in the theme's colors, plus markers for the terminal's folder and the open file.
final class SidebarRowView: NSTableRowView {
    /// `here`: this row is it. `inside`: it's somewhere in this collapsed folder.
    enum Mark { case none, here, inside }

    var terminalMark = Mark.none { didSet { if terminalMark != oldValue { needsDisplay = true; updateTip() } } }
    var fileMark = Mark.none { didSet { if fileMark != oldValue { needsDisplay = true; updateTip() } } }

    /// Git's letter for the row (U, A, M, D, R, C), and whether the row is shaded in its color (files, not folders).
    struct GitBadge: Equatable {
        let letter: String
        let color: NSColor
        let tinted: Bool
    }
    var git: GitBadge? { didSet { if git != oldValue { needsDisplay = true } } }
    /// Made once rather than on every row redraw.
    private static let letterFont = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .semibold)

    private func updateTip() {
        var parts: [String] = []
        if terminalMark == .here { parts.append("Solanum is in this folder") }
        if terminalMark == .inside { parts.append("Solanum is in a folder inside") }
        if fileMark == .here { parts.append("Open in the editor") }
        if fileMark == .inside { parts.append("The open file is inside") }
        toolTip = parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        let th = Config.shared.theme
        let pill = bounds.insetBy(dx: 6, dy: 1)
        // A dark, muted wash in the change's color.
        if let git, git.tinted {
            git.color.withAlphaComponent(th.isDark ? 0.12 : 0.16).setFill()
            NSBezierPath(roundedRect: pill, xRadius: 5, yRadius: 5).fill()
        }
        if terminalMark == .here || fileMark == .here {
            th.accent.withAlphaComponent(0.16).setFill()
            NSBezierPath(roundedRect: pill, xRadius: 5, yRadius: 5).fill()
        }
        // Right edge: a terminal glyph where the shell is (faded on a collapsed folder it's inside), and a dot
        // on a collapsed folder holding the open file.
        var x = pill.maxX - 7
        if let git {
            let attrs: [NSAttributedString.Key: Any] = [.font: Self.letterFont, .foregroundColor: git.color.withAlphaComponent(0.9)]
            let size = (git.letter as NSString).size(withAttributes: attrs)
            (git.letter as NSString).draw(at: NSPoint(x: x - size.width, y: bounds.midY - size.height / 2), withAttributes: attrs)
            x -= size.width + 6
        }
        if terminalMark != .none {
            let color = terminalMark == .here ? th.accent : th.accent.withAlphaComponent(0.55)
            let config = NSImage.SymbolConfiguration(pointSize: 9.5, weight: .semibold).applying(.init(paletteColors: [color]))
            if let img = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                img.draw(in: NSRect(x: x - img.size.width, y: bounds.midY - img.size.height / 2, width: img.size.width, height: img.size.height))
                x -= img.size.width + 5
            }
        }
        if fileMark == .inside {
            th.accent.withAlphaComponent(0.7).setFill()
            NSBezierPath(ovalIn: NSRect(x: x - 6, y: bounds.midY - 3, width: 6, height: 6)).fill()
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        let th = Config.shared.theme
        let color = isEmphasized ? th.accent.withAlphaComponent(0.28) : th.foreground.withAlphaComponent(0.1)
        color.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 1), xRadius: 5, yRadius: 5).fill()
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}

/// Borderless icon button for the sidebar header: highlights on hover and while pressed.
final class SidebarHeaderButton: NSButton {
    var tint: NSColor = .labelColor { didSet { applyTint() } }
    /// Drawn tinted at full strength (e.g. the pin while a folder is pinned).
    var isActive = false { didSet { applyTint() } }
    private var hovering = false { didSet { applyTint(); needsDisplay = true } }

    private func applyTint() {
        contentTintColor = hovering || isActive ? tint : tint.withAlphaComponent(0.6)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        // A popped-up menu swallows the mouse-exit; re-check where the pointer ended up.
        if let w = window { hovering = bounds.contains(convert(w.mouseLocationOutsideOfEventStream, from: nil)) }
    }

    override func draw(_ dirtyRect: NSRect) {
        if hovering || isHighlighted {
            Config.shared.theme.foreground.withAlphaComponent(isHighlighted ? 0.2 : 0.1).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        }
        super.draw(dirtyRect)
    }
}

/// A label that lets clicks through to its superview (the sidebar handles double-click-to-rename).
final class PassThroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// An agent's mark and status dot in the sidebar header; hover for the status.
final class AgentBadgeView: NSView {
    var agent: AgentInfo? { didSet { if agent != oldValue { toolTip = agent?.summary; needsDisplay = true } } }
    var fittingWidth: CGFloat { 14 + 3 + 6 }

    override func draw(_ dirtyRect: NSRect) {
        agent?.draw(at: 0, midY: bounds.midY, height: 14)
    }
}
