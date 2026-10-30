import AppKit

protocol TabOwner: AnyObject {
    func tabDidUpdate(_ tab: TabSession)
    func tabDidClose(_ tab: TabSession)
    func isActiveTab(_ tab: TabSession) -> Bool
    /// One of the tab's panes took the keyboard (so its column is now the focused one).
    func tabDidFocus(_ tab: TabSession)
    /// A file tab closed its last file.
    func tabWantsClose(_ tab: TabSession)
}

enum PaneDirection { case left, right, up, down }

/// Browser-style tab group colors.
enum TabGroupColor: String, CaseIterable {
    case blue, red, yellow, green, pink, purple, cyan, orange, grey

    var color: NSColor {
        switch self {
        case .blue: return NSColor(hex: "#5B8DEF")
        case .red: return NSColor(hex: "#E8655F")
        case .yellow: return NSColor(hex: "#E9B949")
        case .green: return NSColor(hex: "#4FB477")
        case .pink: return NSColor(hex: "#E36FA8")
        case .purple: return NSColor(hex: "#9A7BEA")
        case .cyan: return NSColor(hex: "#3FB8C9")
        case .orange: return NSColor(hex: "#EE8B4A")
        case .grey: return NSColor(hex: "#8E949C")
        }
    }

    var title: String { rawValue.capitalized }
}

/// A named, colored run of adjacent tabs that can be collapsed, like a browser tab group.
final class TabGroup {
    var name = ""
    var color: TabGroupColor
    var collapsed = false

    init(color: TabGroupColor) { self.color = color }

    var displayName: String { name.isEmpty ? "\(color.title) group" : name }
}

/// Thin themed divider between split panes.
final class PaneSplitView: NSSplitView {
    override var dividerThickness: CGFloat { 1 }
    override var dividerColor: NSColor { Config.shared.theme.border.withAlphaComponent(0.6) }

    /// Divider positions as fractions of the split's length, applied once it has a real size (after restoring).
    var pendingFractions: [CGFloat]?

    override func layout() {
        super.layout()
        let length = isVertical ? bounds.width : bounds.height
        guard let f = pendingFractions, length > 50 else { return }
        pendingFractions = nil
        restore(f.map { $0 * length })
    }

    var dividerFractions: [CGFloat] {
        let length = isVertical ? bounds.width : bounds.height
        return length > 0 ? dividerPositions.map { $0 / length } : []
    }

    func equalize() {
        let n = arrangedSubviews.count
        guard n > 1 else { return }
        layoutSubtreeIfNeeded()
        let total = (isVertical ? bounds.width : bounds.height) - dividerThickness * CGFloat(n - 1)
        let each = total / CGFloat(n)
        for i in 0..<(n - 1) {
            setPosition(each * CGFloat(i + 1) + dividerThickness * CGFloat(i), ofDividerAt: i)
        }
    }

    var dividerPositions: [CGFloat] {
        arrangedSubviews.dropLast().map { isVertical ? $0.frame.maxX : $0.frame.maxY }
    }

    func restore(_ positions: [CGFloat]) {
        for (i, p) in positions.enumerated() where i < arrangedSubviews.count - 1 {
            setPosition(p, ofDividerAt: i)
        }
    }
}

/// Container that holds a tab's split-pane tree.
final class PaneRootView: NSView {
    override func layout() {
        super.layout()
        subviews.first?.frame = bounds
    }
}

/// A tab's content: its open files on top (EditorAreaView) and its terminal panes below, either of which
/// may be absent (no files yet; or a file tab, whose terminal is hidden).
final class TabContentView: NSSplitView {
    /// Must not be the split view itself: NSSplitView's respondsToSelector: consults its delegate, so a
    /// self-delegate recurses forever when the responder chain is probed (e.g. building the command palette).
    private let splitDelegate = Delegate()
    /// The files' share of the height, applied once the view has a real size.
    var pendingFraction: CGFloat?

    override init(frame: NSRect) {
        super.init(frame: frame)
        isVertical = false
        dividerStyle = .thin
        delegate = splitDelegate
    }

    required init?(coder: NSCoder) { fatalError() }

    override var dividerThickness: CGFloat { DividerBand.thickness }

    override func drawDivider(in rect: NSRect) {
        DividerBand.draw(in: rect, vertical: false)
    }

    override func layout() {
        super.layout()
        guard let f = pendingFraction, arrangedSubviews.count == 2, bounds.height > 120 else { return }
        pendingFraction = nil
        setPosition((bounds.height * f).rounded(), ofDividerAt: 0)
    }

    private final class Delegate: NSObject, NSSplitViewDelegate {
        func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposed: CGFloat, ofSubviewAt i: Int) -> CGFloat {
            max(proposed, 90)
        }

        func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposed: CGFloat, ofSubviewAt i: Int) -> CGFloat {
            min(proposed, splitView.bounds.height - 80)
        }
    }
}

/// A band (not a hairline) between the files and the terminal, and between the columns of a split window,
/// with a grip to show it can be dragged.
enum DividerBand {
    static let thickness: CGFloat = 6

    /// `vertical`: the band runs top to bottom (between columns); otherwise across (files over terminal).
    static func draw(in rect: NSRect, vertical: Bool) {
        let th = Config.shared.theme
        th.tabBarTint.withAlphaComponent(1).setFill()
        rect.fill()
        th.border.setFill()
        if vertical {
            NSRect(x: rect.minX, y: rect.minY, width: 1, height: rect.height).fill()
            NSRect(x: rect.maxX - 1, y: rect.minY, width: 1, height: rect.height).fill()
        } else {
            NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 1).fill()
            NSRect(x: rect.minX, y: rect.maxY - 1, width: rect.width, height: 1).fill()
        }
        th.foreground.withAlphaComponent(0.35).setFill()
        for i in -1...1 {
            let d = CGFloat(i) * 7
            let c = vertical ? NSPoint(x: rect.midX, y: rect.midY + d) : NSPoint(x: rect.midX + d, y: rect.midY)
            NSBezierPath(ovalIn: NSRect(x: c.x - 1.5, y: c.y - 1.5, width: 3, height: 3)).fill()
        }
    }
}

/// One tab: a tree of terminal panes, and the files opened in it (shown above the terminal).
final class TabSession: NSObject {
    let root = PaneRootView()
    /// What the window shows for this tab: the open files on top, `root` (the terminal) below.
    let view = TabContentView()
    /// Files open in this tab, shown one at a time under a strip of sub-tabs.
    private(set) var editors: [FileEditorView] = []
    private(set) var activeEditorIndex = 0
    var editor: FileEditorView? { editors.indices.contains(activeEditorIndex) ? editors[activeEditorIndex] : nil }
    private(set) lazy var editorArea = EditorAreaView(tab: self)
    /// False for a file tab: just its files. Its terminal starts only if it's shown.
    private(set) var showsTerminal = true
    /// For a file tab: where its file came from (this Mac, or the ssh host it was opened from) and its folder.
    /// The sidebar and status bar browse there, and showing the terminal opens a shell there.
    var fileOrigin: (fs: FileSystem, dir: String)?
    /// The folder the sidebar stays on while this tab is active, if one is pinned.
    var pinnedFolder: (fs: FileSystem, path: String)?
    /// Folders opened in the sidebar while this tab was active, by machine (see `FileSidebarView.openFolders`).
    var openFolders: [String: Set<String>] = [:]
    /// Where the sidebar was while this tab was active (see `FileSidebarView.applyTabPlace`).
    var sidebarPlace: (fs: FileSystem, root: String, followed: String?)?

    /// Where this tab's files are for the sidebar and status bar: a file tab whose terminal hasn't started yet
    /// browses its file's folder (on the ssh host it came from); otherwise the focused pane's folder.
    var browseFS: FileSystem {
        if let o = fileOrigin, !focusedPane.hasStarted { return o.fs }
        return focusedPane.fileSystem
    }

    var browseDirectory: String? {
        if let o = fileOrigin, !focusedPane.hasStarted { return o.dir }
        return focusedPane.browseDirectory
    }

    /// The ssh session this tab's sidebar shows, if any (and whether it's still logging in).
    var browseRemote: RemoteSession? { browseFS as? RemoteSession }
    /// The last file a click opened here, and when; a double-click right after moves it to a tab of its own.
    private var lastOpened: (path: String, at: Date)?
    weak var owner: TabOwner?
    var windowController: TerminalWindowController? { (owner as? TabColumn)?.owner }
    private(set) var focusedPane: TerminalView
    /// Name set by the user; nil shows the focused pane's title.
    var customTitle: String?
    var group: TabGroup?

    convenience init(cwd: String?) {
        let pane = TerminalView(cwd: cwd)
        self.init(content: pane, focus: pane)
    }

    /// `content` is a single pane or a tree of PaneSplitViews holding panes.
    init(content: NSView, focus: TerminalView) {
        focusedPane = focus
        super.init()
        content.frame = root.bounds
        content.autoresizingMask = [.width, .height]
        root.addSubview(content)
        view.addArrangedSubview(root)
        for p in panes { p.tab = self }
        updateDimming()
    }

    var panes: [TerminalView] {
        var out: [TerminalView] = []
        func walk(_ v: NSView) {
            if let t = v as? TerminalView { out.append(t); return }
            if let s = v as? NSSplitView { s.arrangedSubviews.forEach(walk) } else { v.subviews.forEach(walk) }
        }
        walk(root)
        return out
    }

    var title: String {
        if let customTitle { return customTitle }
        if !showsTerminal, let ed = editor { return ed.displayName }
        return focusedPane.displayTitle
    }
    var isRunningCommand: Bool { panes.contains { $0.isRunningCommand } }
    /// The agent in this tab needing the most attention (waiting > failed > working > done).
    var agent: AgentInfo? { panes.compactMap(\.agent).max { $0.status.urgency < $1.status.urgency } }
    var lastCommandFailed: Bool { focusedPane.terminal.blocks.last(where: { $0.state == .finished })?.failed ?? false }
    var hasRunningJobs: Bool { panes.contains { $0.hasRunningJob } }
    var isActive: Bool { owner?.isActiveTab(self) ?? false }

    func focus() {
        if !showsTerminal, let ed = editor { return ed.focus() }
        focusedPane.window?.makeFirstResponder(focusedPane)
    }

    func paneDidFocus(_ p: TerminalView) {
        focusedPane = p
        updateDimming()
        owner?.tabDidFocus(self)
        owner?.tabDidUpdate(self)
    }

    func paneTitleChanged(_ p: TerminalView) {
        owner?.tabDidUpdate(self)
    }

    /// The title only shows the last path component, so a cwd change needs its own nudge for the status bar.
    func paneCwdChanged(_ p: TerminalView) {
        owner?.tabDidUpdate(self)
    }

    func updateDimming() {
        let all = panes
        for p in all { p.dimmed = all.count > 1 && p !== focusedPane }
    }

    // MARK: Split

    func split(_ pane: TerminalView, vertical: Bool) {
        let newPane = TerminalView(cwd: pane.currentDirectory)
        newPane.tab = self
        if let parent = pane.superview as? PaneSplitView, parent.isVertical == vertical {
            let idx = parent.arrangedSubviews.firstIndex(of: pane) ?? parent.arrangedSubviews.count - 1
            parent.insertArrangedSubview(newPane, at: idx + 1)
            parent.equalize()
        } else {
            let split = PaneSplitView()
            split.isVertical = vertical
            split.dividerStyle = .thin
            let oldFrame = pane.frame
            if let parent = pane.superview as? PaneSplitView {
                let positions = parent.dividerPositions
                let idx = parent.arrangedSubviews.firstIndex(of: pane) ?? 0
                pane.removeFromSuperview()
                parent.insertArrangedSubview(split, at: idx)
                parent.restore(positions)
            } else if let container = pane.superview {
                pane.removeFromSuperview()
                split.autoresizingMask = [.width, .height]
                container.addSubview(split)
            }
            split.frame = oldFrame
            pane.autoresizingMask = []
            split.addArrangedSubview(pane)
            split.addArrangedSubview(newPane)
            split.adjustSubviews()
            split.equalize()
        }
        root.needsLayout = true
        newPane.window?.makeFirstResponder(newPane)
        updateDimming()
    }

    // MARK: Close

    /// Closes a pane, asking first if a program is still running in it.
    func requestClose(_ pane: TerminalView) {
        if pane.hasRunningJob, Config.shared.confirmQuit, let w = pane.window {
            let alert = NSAlert()
            alert.messageText = "Close this pane?"
            alert.informativeText = "“\(pane.pty?.foregroundProcessName ?? "A process")” is still running and will be terminated."
            alert.addButton(withTitle: "Close")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: w) { [weak self] resp in
                if resp == .alertFirstButtonReturn { self?.close(pane) }
            }
        } else {
            close(pane)
        }
    }

    func paneDidExit(_ pane: TerminalView) {
        close(pane)
    }

    func close(_ pane: TerminalView) {
        pane.terminate()
        let all = panes
        guard all.count > 1 else {
            pane.removeFromSuperview()
            owner?.tabDidClose(self)
            return
        }
        let idx = all.firstIndex(of: pane) ?? 0
        if let split = pane.superview as? PaneSplitView {
            pane.removeFromSuperview()
            if split.arrangedSubviews.count == 1, let remaining = split.arrangedSubviews.first {
                if let parent = split.superview as? PaneSplitView {
                    let positions = parent.dividerPositions
                    let sidx = parent.arrangedSubviews.firstIndex(of: split) ?? 0
                    remaining.removeFromSuperview()
                    split.removeFromSuperview()
                    parent.insertArrangedSubview(remaining, at: sidx)
                    parent.restore(positions)
                } else if let container = split.superview {
                    remaining.removeFromSuperview()
                    split.removeFromSuperview()
                    remaining.frame = container.bounds
                    remaining.autoresizingMask = [.width, .height]
                    container.addSubview(remaining)
                }
            } else {
                split.adjustSubviews()
                split.equalize()
            }
        } else {
            pane.removeFromSuperview()
        }
        let remainingPanes = panes
        let next = remainingPanes[min(max(0, idx - 1), remainingPanes.count - 1)]
        focusedPane = next
        next.window?.makeFirstResponder(next)
        updateDimming()
        owner?.tabDidUpdate(self)
    }

    func terminateAll() {
        panes.forEach { $0.terminate() }
    }

    // MARK: Editor

    /// Opens a file above the terminal (or switches to it if it's open already); `mode` opens its uncommitted
    /// changes, or (given a repository's top folder) its history, instead.
    func openFile(_ fs: FileSystem, _ path: String, mode: EditorMode = .file, focus: Bool = true) {
        if let i = editors.firstIndex(where: { $0.fs === fs && $0.path == path && $0.mode == mode }) { return activateEditor(i, focus: focus) }
        adoptEditor(FileEditorView(fs: fs, path: path, mode: mode), focus: focus)
        if mode == .file { lastOpened = (path, Date()) }
    }

    /// Takes in an editor (a newly opened file, or one moving here from another tab) and shows it.
    func adoptEditor(_ ed: FileEditorView, focus: Bool = true) {
        ed.onClose = { [weak self, weak ed] in
            if let self, let ed { self.closeEditor(ed) }
        }
        ed.onOpenAs = { [weak self, weak ed] mode in
            guard let self, let ed else { return }
            self.openFile(ed.fs, ed.path, mode: mode)
        }
        ed.onOpenOther = { [weak self, weak ed] path, mode in
            guard let self, let ed else { return }
            self.openFile(ed.fs, path, mode: mode)
        }
        ed.onPathChanged = { [weak self, weak ed] in
            guard let self, let ed else { return }
            if let o = self.fileOrigin, !self.showsTerminal { self.fileOrigin = (o.fs, FilePaths.parent(ed.path)) }
            self.editorArea.strip.needsDisplay = true
            self.owner?.tabDidUpdate(self)
        }
        editors.append(ed)
        activateEditor(editors.count - 1, focus: focus)
    }

    func activateEditor(_ i: Int, focus: Bool = true) {
        guard editors.indices.contains(i) else { return }
        activeEditorIndex = i
        editorArea.show(editors[i])
        arrange()
        if focus { editors[i].focus() }
        owner?.tabDidUpdate(self)
    }

    /// Removes an editor (closed after any save prompt, or moving to another tab). A file tab left with
    /// nothing closes.
    func closeEditor(_ ed: FileEditorView) {
        guard let i = editors.firstIndex(of: ed) else { return }
        editors.remove(at: i)
        ed.removeFromSuperview()
        if editors.isEmpty {
            if !showsTerminal { return owner?.tabWantsClose(self) ?? () }
            arrange()
            focus()
        } else {
            activateEditor(i < activeEditorIndex || activeEditorIndex >= editors.count ? max(0, activeEditorIndex - 1) : activeEditorIndex)
        }
        owner?.tabDidUpdate(self)
    }

    /// A double-click in the sidebar first opens the file here (the click), then asks for a tab of its own:
    /// undo the click's opening so the file isn't in both places.
    func closeEditorJustOpened(_ path: String) {
        guard let last = lastOpened, last.path == path, Date().timeIntervalSince(last.at) < 1,
              let ed = editors.first(where: { $0.path == path && $0.mode == .file }), !ed.isDirty else { return }
        closeEditor(ed)
    }

    /// Reorders the file sub-tabs (dragging one along the strip).
    func moveEditor(from: Int, to: Int) {
        guard editors.indices.contains(from), from != to else { return }
        let active = editor
        let ed = editors.remove(at: from)
        editors.insert(ed, at: min(max(to, 0), editors.count))
        activeEditorIndex = active.flatMap { editors.firstIndex(of: $0) } ?? 0
        editorArea.strip.needsDisplay = true
    }

    /// Shows or hides this tab's terminal below its files.
    func toggleTerminal() {
        guard showsTerminal == false || !editors.isEmpty else { return NSSound.beep() }
        showsTerminal.toggle()
        // First time a file tab from an ssh host shows its terminal: log back in there, in the file's folder.
        if showsTerminal, !focusedPane.hasStarted, let o = fileOrigin, let remote = o.fs as? RemoteSession {
            focusedPane.pendingCommand = remote.reconnectCommand(in: o.dir)
        }
        arrange()
        focus()
        owner?.tabDidUpdate(self)
    }

    /// Makes this a file tab: no terminal, just `ed`.
    func showFileOnly(_ ed: FileEditorView) {
        showsTerminal = false
        adoptEditor(ed)
    }

    /// Puts the files on top and the terminal below, whichever of them there are.
    private func arrange() {
        let wanted: [NSView] = (editors.isEmpty ? [] : [editorArea]) + (showsTerminal ? [root] : [])
        let current = view.arrangedSubviews
        guard current != wanted else { return }
        current.forEach { $0.removeFromSuperview() }
        wanted.forEach { view.addArrangedSubview($0) }
        // Files take a little over half the height when they first appear above the terminal.
        if wanted.count == 2 && current.count < 2 { view.pendingFraction = 0.55 }
        view.adjustSubviews()
        view.needsLayout = true
        // The terminal moves into where the files and the divider were; repaint so none of them is left behind.
        view.needsDisplay = true
        panes.forEach { $0.needsDisplay = true }
    }

    var hasUnsavedFile: Bool { editors.contains { $0.isDirty } }

    // MARK: Navigation

    func focusNeighbor(of pane: TerminalView, direction: PaneDirection) {
        guard let w = pane.window else { return }
        let from = pane.convert(pane.bounds, to: nil)
        var best: (TerminalView, CGFloat)?
        for p in panes where p !== pane {
            let r = p.convert(p.bounds, to: nil)
            let ok: Bool
            switch direction {
            case .left: ok = r.maxX <= from.minX + 2
            case .right: ok = r.minX >= from.maxX - 2
            case .up: ok = r.minY >= from.maxY - 2
            case .down: ok = r.maxY <= from.minY + 2
            }
            guard ok else { continue }
            let d = hypot(r.midX - from.midX, r.midY - from.midY)
            if best == nil || d < best!.1 { best = (p, d) }
        }
        if let b = best {
            w.makeFirstResponder(b.0)
            return
        }
        // Nothing that way in this tab: the other column of a split window, when it lies that way.
        guard let wc = w.windowController as? TerminalWindowController, wc.columns.count > 1 else { return }
        if (direction == .right && wc.focusedIndex == 0) || (direction == .left && wc.focusedIndex == 1) { wc.focusOtherColumn(nil) }
    }

    func cycleFocus(from pane: TerminalView, by d: Int) {
        let all = panes
        guard all.count > 1, let i = all.firstIndex(of: pane) else { return }
        let next = all[(i + d + all.count) % all.count]
        next.window?.makeFirstResponder(next)
    }
}

/// Draws the themed window background (solid or gradient) at the configured opacity.
final class BackgroundView: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let cfg = Config.shared
        let th = cfg.theme
        let alpha = cfg.opacity
        if let b2 = th.background2 {
            let g = NSGradient(starting: th.background.withAlphaComponent(alpha), ending: b2.withAlphaComponent(alpha))
            g?.draw(in: bounds, angle: 90)
        } else {
            th.background.withAlphaComponent(alpha).setFill()
            bounds.fill()
        }
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Bottom strip: sidebar toggle and ssh hosts buttons, the git branch / sync / changes of the active pane's
/// repository, then its folder as clickable breadcrumbs (prefixed with user@host inside an ssh session).
/// Clicking a folder lists the folders inside it; picking one cds there.
final class StatusBarView: NSView {
    static let height: CGFloat = 26

    var path: String? { didSet { if path != oldValue { toolTip = path; needsDisplay = true } } }
    /// "user@host" while the pane is in an ssh session.
    var host: String? { didSet { if host != oldValue { needsDisplay = true } } }
    /// Abbreviated to ~ in the breadcrumbs.
    var home: String? { didSet { if home != oldValue { needsDisplay = true } } }
    var showsSidebarToggle = false { didSet { needsDisplay = true } }
    var sidebarVisible = false { didSet { needsDisplay = true } }
    var onToggleFileSidebar: (() -> Void)?
    /// The right half of a split window's bar (the right column's own), drawn with a line on its left edge.
    var leadingEdge = false { didSet { needsDisplay = true } }
    /// The theme name at the right end, which the breadcrumbs stop short of.
    private var themeRect: CGRect = .null
    /// The theme's name, in capitals at the right end (not while split, where the right column's folder goes);
    /// clicking it lists the themes.
    var showsThemeName = false { didSet { needsDisplay = true } }
    var onThemeMenu: ((NSPoint) -> Void)?
    /// The right sidebar's toggle, at the far right while the window is split.
    var showsRightSidebarToggle = false { didSet { needsDisplay = true } }
    var rightSidebarVisible = false { didSet { needsDisplay = true } }
    var onToggleRightSidebar: (() -> Void)?
    /// Lists the subfolder names of a folder on the pane's machine.
    var listFolders: ((String, @escaping ([String]) -> Void) -> Void)?
    var onNavigate: ((String) -> Void)?
    /// The ssh hosts button; the point is where to pop up its menu.
    var onShowHosts: ((NSPoint) -> Void)?
    /// The focused pane's repository, when its folder is in one.
    var git: GitInfo? { didSet { needsDisplay = true } }
    /// "Pulling…" etc. while a git command runs.
    var gitBusy: String? { didSet { needsDisplay = true } }
    /// Each sidebar's file transfer in progress ("Copying a.txt to host:~/dir"), shown at the right.
    private var transfers: [ObjectIdentifier: String] = [:]
    private var transferRect: CGRect = .null
    /// A planet theme's planet, left of the theme name.
    private static let planetSide: CGFloat = 18
    /// Solanum Default's mark beside its name: the flower in outline, purple while the theme button is hovered.
    private static let flowerSide: CGFloat = 16

    private func drawFlowerOutline(x: CGFloat) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let th = Config.shared.theme
        let color = hoverButton == .theme ? (th.isDark ? SolanumArt.purple : SolanumArt.purpleOnLight) : th.dimText
        // The art is drawn y-up.
        ctx.saveGState()
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)
        let s = Self.flowerSide
        SolanumArt.drawOutline(in: ctx, rect: CGRect(x: x, y: bounds.height - centerY - s / 2, width: s, height: s),
                               color: color.cgColor, lineWidth: 1.1)
        ctx.restoreGState()
    }

    private func drawPlanet(_ planet: PlanetArt.Planet, x: CGFloat) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // The art is drawn y-up.
        ctx.saveGState()
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)
        let s = Self.planetSide
        PlanetArt.draw(planet, in: ctx, rect: CGRect(x: x, y: bounds.height - centerY - s / 2, width: s, height: s), icon: true)
        ctx.restoreGState()
    }

    var devTransfer: String? { transfers.values.sorted().first }   // dev aid (DevTools print-rows)

    func setTransfer(_ text: String?, from source: AnyObject) {
        transfers[ObjectIdentifier(source)] = text
        needsDisplay = true
    }
    var onBranch: (() -> Void)?
    var onSync: ((NSPoint) -> Void)?
    var onChanges: ((NSPoint) -> Void)?

    private enum Button { case sidebar, hosts, branch, sync, changes, rightSidebar, theme, moon }

    private var crumbs: [(rect: NSRect, path: String, label: String)] = []
    private var buttons: [(rect: NSRect, kind: Button)] = []
    private var hover: Int?
    private var hoverButton: Button?

    override var isFlipped: Bool { true }

    private func symbol(_ name: String, _ color: NSColor, size: CGFloat = 11) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .medium).applying(.init(paletteColors: [color]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }

    // Everything in the bar is centered on one line the way symbols and text share a line of text: a symbol by its
    // alignment rect (the cap-height box SF Symbols are drawn around, so a pencil poking out of a square or an
    // arrow hanging under a cloud doesn't shift the shape), a label by its capitals. No per-item nudging.
    private var centerY: CGFloat { bounds.height / 2 - 1.5 }

    /// Where to draw `img` at `x` so its alignment rect is centered on the bar's line.
    private func iconFrame(_ img: NSImage, x: CGFloat) -> NSRect {
        let a = img.alignmentRect   // in the image's own coordinates, origin at the bottom
        return NSRect(x: x, y: centerY - (img.size.height - a.maxY) - a.height / 2, width: img.size.width, height: img.size.height)
    }

    /// The box to draw one line of `font` text in at `x`, with its capitals centered on the bar's line.
    private func textFrame(_ font: NSFont, x: CGFloat, width: CGFloat) -> NSRect {
        NSRect(x: x, y: centerY + font.capHeight / 2 - font.ascender, width: width, height: ceil(font.ascender - font.descender) + 1)
    }

    /// (label, full path) for each folder from the top of `path` down.
    private func segments(_ path: String) -> [(String, String)] {
        var out: [(String, String)] = []
        var rest: Substring
        if let home, home != "/", path == home || path.hasPrefix(home + "/") {
            out.append(("~", home))
            rest = path.dropFirst(home.count)
        } else {
            out.append(("/", "/"))
            rest = Substring(path)
        }
        var cur = out[0].1
        for c in rest.split(separator: "/") {
            cur = FilePaths.join(cur, String(c))
            out.append((String(c), cur))
        }
        return out
    }

    /// Draws a hoverable icon (+ optional text) button starting at `x`; returns where the next item goes.
    /// `iconSpace` leaves that much room for an icon drawn by the caller instead of `icon` (0: no icon).
    private func drawButton(_ kind: Button, at x: CGFloat, icon: String, color: NSColor, text: String? = nil,
                            textAttrs: [NSAttributedString.Key: Any] = [:], maxTextWidth: CGFloat = 220,
                            iconSpace: CGFloat? = nil) -> CGFloat {
        let img = iconSpace == nil ? symbol(icon, color) : nil
        let iw = iconSpace ?? img?.size.width ?? 0
        let tw = text.map { min(maxTextWidth, ($0 as NSString).size(withAttributes: textAttrs).width) } ?? 0
        let gap: CGFloat = iw > 0 ? 4 : 0
        let w = text == nil ? 22 : 6 + iw + gap + tw + 7
        let r = NSRect(x: x, y: 2, width: w, height: bounds.height - 6)
        if measuring { return r.maxX + 2 }
        buttons.append((r, kind))
        if hoverButton == kind {
            Config.shared.theme.foreground.withAlphaComponent(0.1).setFill()
            NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
        }
        if let img {
            let ix = text == nil ? r.midX - iw / 2 : r.minX + 6
            img.draw(in: iconFrame(img, x: ix))
        }
        if let text {
            let para = NSMutableParagraphStyle()
            para.lineBreakMode = .byTruncatingMiddle
            var attrs = textAttrs
            attrs[.paragraphStyle] = para
            let font = textAttrs[.font] as? NSFont ?? barFont
            (text as NSString).draw(in: textFrame(font, x: r.minX + 6 + iw + gap, width: tw + 1), withAttributes: attrs)
        }
        return r.maxX + 2
    }

    override func draw(_ dirtyRect: NSRect) {
        let th = Config.shared.theme
        th.tabBarTint.setFill()
        bounds.fill()
        th.border.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        crumbs = []
        buttons = []

        if showsRightSidebarToggle {
            _ = drawButton(.rightSidebar, at: bounds.width - 30, icon: "sidebar.right", color: rightSidebarVisible ? th.accent : th.dimText)
        }
        if leadingEdge { NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill() }
        themeRect = .null
        if showsThemeName {
            let font = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .kern: 0.8,
                                                        .foregroundColor: hoverButton == .theme ? th.foreground : th.dimText]
            let name = th.name.uppercased()
            // A planet theme's planet stands in for the palette icon, centered on the label like the icon was;
            // Solanum Default gets the flower. With the theme icon off, just the name.
            let showIcon = Config.shared.themeIcon
            // The Quantum Moon may have wandered off (see QuantumMoon); its name stays.
            let planet = showIcon && !(QuantumMoon.active && !QuantumMoon.at(.home)) ? PlanetArt.planet(for: th) : nil
            let flower = showIcon && !th.isCustom && th.name == ThemeLibrary.solanumDefault.name
            let iw = !showIcon || QuantumMoon.active && planet == nil ? 0 : planet != nil ? Self.planetSide : flower ? Self.flowerSide
                : symbol("paintpalette", th.dimText)?.size.width ?? 0
            let w = 6 + iw + (iw > 0 ? 4 : 0) + min(200, (name as NSString).size(withAttributes: attrs).width) + 7
            let start = bounds.width - (showsRightSidebarToggle ? 36 : 8) - w
            _ = drawButton(.theme, at: start, icon: "paintpalette", color: hoverButton == .theme ? th.accent : th.dimText,
                           text: name, textAttrs: attrs, maxTextWidth: 200,
                           iconSpace: !showIcon || planet != nil || flower || QuantumMoon.active ? iw : nil)
            themeRect = CGRect(x: start, y: 2, width: w, height: bounds.height - 6)
            if let planet { drawPlanet(planet, x: start + 6) }
            if flower { drawFlowerOutline(x: start + 6) }
        }
        let rightItems = themeRect
        // A transfer in progress, right-aligned before the theme name or the right column's folder.
        transferRect = .null
        if let text = transfers.values.sorted().first {
            let font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
            let para = NSMutableParagraphStyle()
            para.lineBreakMode = .byTruncatingMiddle
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: th.foreground.withAlphaComponent(0.85), .paragraphStyle: para]
            let end = rightItems.isNull ? bounds.width - (showsRightSidebarToggle ? 36 : 10) : rightItems.minX - 14
            let icon = symbol("arrow.left.arrow.right", th.accent, size: 10)
            let iconW = (icon?.size.width ?? 0) + 6
            let textW = min((text as NSString).size(withAttributes: attrs).width + 2, bounds.width * 0.4)
            let start = end - textW - iconW
            transferRect = CGRect(x: start, y: 2, width: end - start, height: bounds.height - 6)
            if let icon {
                icon.draw(in: iconFrame(icon, x: start))
            }
            (text as NSString).draw(in: textFrame(font, x: start + iconW, width: textW), withAttributes: attrs)
        }
        // Clear of the window's rounded bottom-left corner.
        var x: CGFloat = 12
        if showsSidebarToggle {
            x = drawButton(.sidebar, at: x, icon: "sidebar.left", color: sidebarVisible ? th.accent : th.dimText)
        }
        if onShowHosts != nil {
            x = drawButton(.hosts, at: x, icon: "server.rack", color: th.dimText)
        }
        if !buttons.isEmpty { x += 4 }
        let rightEdge = transferRect.isNull ? rightItems : transferRect
        let limit = rightEdge.isNull ? bounds.width - (showsRightSidebarToggle ? 34 : 0) : rightEdge.minX - 16
        if mirrored {
            // From the right edge leftwards: host, git, then the folder ending against them.
            let infoW = measure { drawInfo(at: 0) }
            let infoX = (limit - 4 - infoW).rounded()
            let pathW = measure { drawPath(from: 0, avail: infoX - x - 8) }
            drawPath(from: infoX - pathW, avail: infoX - x - 8)
            drawInfo(at: infoX)
        } else {
            x = drawInfo(at: x)
            if QuantumMoon.at(.folders) {
                let r = NSRect(x: x, y: 2, width: Self.planetSide + 4, height: bounds.height - 6)
                buttons.append((r, .moon))
                if hoverButton == .moon {
                    th.foreground.withAlphaComponent(0.1).setFill()
                    NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
                }
                drawPlanet(.quantumMoon, x: x + 2)
                x = r.maxX + 4
            }
            drawPath(from: x, avail: limit - x - 12)
        }
    }

    /// The right half of a split window's bar runs right to left: its parts start at the right edge, mirroring
    /// the left half.
    var mirrored = false { didSet { needsDisplay = true } }
    /// While set, the drawing helpers only work out how wide they'd be.
    private var measuring = false

    /// The width `draw` would take (it's given x = 0), without drawing anything.
    private func measure(_ draw: () -> CGFloat) -> CGFloat {
        measuring = true
        defer { measuring = false }
        return draw()
    }

    private var barFont: NSFont { NSFont.systemFont(ofSize: 11.5, weight: .medium) }

    /// The ssh host and the git branch, sync and changes, with a divider on the folder's side (after them, or
    /// before them when mirrored). Returns where they end.
    @discardableResult
    private func drawInfo(at start: CGFloat) -> CGFloat {
        let th = Config.shared.theme
        let font = barFont
        let dim: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: th.dimText]
        var x = start
        func divider() {
            if !measuring {
                th.border.setFill()
                NSRect(x: x + 3, y: 6, width: 1, height: bounds.height - 11).fill()
            }
            x += 9
        }
        func drawHost() {
            guard let host else { return }
            if let img = symbol("network", th.accent, size: 10) {
                if !measuring {
                    img.draw(in: iconFrame(img, x: x))
                }
                x += img.size.width + 5
            }
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: th.accent]
            if !measuring { (host as NSString).draw(in: textFrame(font, x: x, width: (host as NSString).size(withAttributes: attrs).width + 1), withAttributes: attrs) }
            x += (host as NSString).size(withAttributes: attrs).width + 8
        }
        if mirrored, git != nil, path != nil { divider() }
        if !mirrored { drawHost() }
        if let git {
            let bright: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: th.foreground.withAlphaComponent(0.85)]
            x = drawButton(.branch, at: x - 4, icon: "arrow.triangle.branch", color: th.accent, text: git.branch, textAttrs: bright, maxTextWidth: 200)
            if let busy = gitBusy {
                x = drawButton(.sync, at: x, icon: "arrow.triangle.2.circlepath", color: th.dimText, text: busy, textAttrs: dim)
            } else if git.upstream != nil {
                var counts: [String] = []
                if git.behind > 0 { counts.append("\(git.behind)↓") }
                if git.ahead > 0 { counts.append("\(git.ahead)↑") }
                x = drawButton(.sync, at: x, icon: "arrow.triangle.2.circlepath", color: counts.isEmpty ? th.dimText : th.accent,
                               text: counts.isEmpty ? nil : counts.joined(separator: " "), textAttrs: bright)
            } else if !git.detached {
                x = drawButton(.sync, at: x, icon: "icloud.and.arrow.up", color: th.dimText)
            }
            if !git.changes.isEmpty {
                x = drawButton(.changes, at: x, icon: "square.and.pencil", color: th.dimText, text: "\(git.changes.count)", textAttrs: dim)
            }
            if !mirrored { divider() }
        }
        if mirrored { drawHost() }
        return x
    }

    /// The folder icon and breadcrumbs from `start`, dropping folders from the front until they fit in `avail`.
    /// Returns where they end.
    @discardableResult
    private func drawPath(from start: CGFloat, avail full: CGFloat) -> CGFloat {
        guard let path else { return start }
        let th = Config.shared.theme
        let font = barFont
        let dim: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: th.dimText]
        var x = start
        var avail = full
        // The folder icon is part of the first button after it (the first folder, or "…" for the hidden ones).
        var icon = host == nil ? symbol("folder", th.dimText) : nil
        if let icon {
            x += icon.size.width + 4
            avail -= icon.size.width + 4
        }
        /// One breadcrumb button: hover highlight, then the icon (if it's still to draw) and `label`.
        func button(_ label: String, path crumbPath: String, x: CGFloat, width w: CGFloat, bright: Bool) {
            let iconW = icon.map { $0.size.width + 4 } ?? 0
            let r = NSRect(x: x - iconW, y: 2, width: w + iconW, height: bounds.height - 6)
            let idx = crumbs.count
            crumbs.append((r, crumbPath, label))
            if hover == idx {
                th.foreground.withAlphaComponent(0.1).setFill()
                NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
            }
            let color = bright || hover == idx ? th.foreground.withAlphaComponent(0.85) : th.dimText
            if icon != nil, let lit = symbol("folder", hover == idx ? color : th.dimText) {
                lit.draw(in: iconFrame(lit, x: r.minX + 4))
                icon = nil
            }
            let para = NSMutableParagraphStyle()
            para.lineBreakMode = .byTruncatingTail
            (label as NSString).draw(in: textFrame(font, x: x + 4, width: w - 8),
                                     withAttributes: [.font: font, .paragraphStyle: para, .foregroundColor: color])
        }
        var segs = segments(path)
        let sep = " › " as NSString
        let sepW = sep.size(withAttributes: dim).width
        let widths = segs.map { ($0.0 as NSString).size(withAttributes: dim).width + 8 }
        var first = 0
        func total(_ from: Int) -> CGFloat {
            widths[from...].reduce(0, +) + CGFloat(segs.count - from - 1) * sepW + (from > 0 ? 20 + sepW : 0)
        }
        while first < segs.count - 1 && total(first) > avail { first += 1 }
        if first > 0 {
            // "…" stands for the folders left out; as a button, it opens the nearest of them.
            if !measuring { button("…", path: segs[first - 1].1, x: x, width: 20, bright: false) }
            x += 20
            if !measuring { sep.draw(in: textFrame(font, x: x, width: sepW + 1), withAttributes: dim) }
            x += sepW
        }
        segs = Array(segs[first...])
        let end = start + full
        for (i, seg) in segs.enumerated() {
            let w = min(widths[first + i], end - x)
            guard w > 10 else { break }
            let last = i == segs.count - 1
            if !measuring { button(seg.0, path: seg.1, x: x, width: w, bright: last) }
            x += w
            if !last {
                if !measuring { sep.draw(in: textFrame(font, x: x, width: sepW + 1), withAttributes: dim) }
                x += sepW
            }
        }
        // No room for any folder: the icon on its own.
        if !measuring, let icon { icon.draw(in: iconFrame(icon, x: start)) }
        return x
    }

    private func tip(for kind: Button) -> String {
        switch kind {
        case .sidebar: return sidebarVisible ? "Hide File Sidebar (⌘B)" : "Show File Sidebar (⌘B)"
        case .rightSidebar: return rightSidebarVisible ? "Hide Right Sidebar (⌥⌘B)" : "Show Right Sidebar (⌥⌘B)"
        case .theme: return "Theme: \(Config.shared.theme.name) — click to switch"
        case .moon: return "The Quantum Moon?"
        case .hosts: return "SSH Hosts"
        case .branch: return git.map { $0.detached ? "Detached at \($0.branch) — switch branch" : "On \($0.branch) — switch branch" } ?? ""
        case .sync:
            guard let git else { return "" }
            guard let up = git.upstream else { return "Publish \(git.branch)" }
            return "\(up): \(git.behind) incoming, \(git.ahead) outgoing — pull, push or fetch"
        case .changes:
            let n = git?.changes.count ?? 0
            return "\(n) changed file\(n == 1 ? "" : "s")"
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === self }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        let h = crumbs.firstIndex { $0.rect.contains(p) }
        let hb = buttons.first { $0.rect.contains(p) }?.kind
        if h != hover || hb != hoverButton {
            hover = h
            hoverButton = hb
            toolTip = hb.map(tip) ?? h.map { "Folders in \(crumbs[$0].path)" } ?? path
            needsDisplay = true
        }
        (h != nil || hb != nil ? NSCursor.pointingHand : NSCursor.arrow).set()
    }

    override func mouseExited(with e: NSEvent) {
        hover = nil
        hoverButton = nil
        NSCursor.arrow.set()
        needsDisplay = true
    }

    /// Dev aid (DevTools nomai-read): clicks the Quantum Moon when it's by the folders.
    func devClickMoon() {
        if let b = buttons.first(where: { $0.kind == .moon }) { QuantumMoon.toggleReading(from: self, moon: b.rect) }
    }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if let b = buttons.first(where: { $0.rect.contains(p) }) {
            let at = NSPoint(x: b.rect.minX, y: b.rect.minY - 2)
            switch b.kind {
            case .sidebar: onToggleFileSidebar?()
            case .rightSidebar: onToggleRightSidebar?()
            case .theme: onThemeMenu?(at)
            case .hosts: onShowHosts?(at)
            case .branch: onBranch?()
            case .sync: if gitBusy == nil { onSync?(at) }
            case .changes: onChanges?(at)
            case .moon: QuantumMoon.toggleReading(from: self, moon: b.rect)
            }
            return
        }
        guard let i = crumbs.firstIndex(where: { $0.rect.contains(p) }) else { return }
        let crumb = crumbs[i]
        // ⌃-click: the context menu (Copy Path), as a right-click shows it.
        if e.modifierFlags.contains(.control) { return super.mouseDown(with: e) }
        listFolders?(crumb.path) { [weak self] names in
            guard let self, self.window != nil else { return }
            self.folderMenu(crumb.path, label: crumb.label, names: names)
                .popUpAbove(NSPoint(x: crumb.rect.minX, y: crumb.rect.minY - 2), in: self)
        }
    }

    /// Clicking a folder in the path: opening another folder and copying this one's path, then going there or to
    /// a folder inside it.
    private func folderMenu(_ folder: String, label: String, names: [String]) -> NSMenu {
        let menu = NSMenu()
        if let controller = window?.windowController as? TerminalWindowController {
            let open = ActionMenuItem("Open Folder…") { [weak controller] in controller?.openFolder(nil) }
            open.keyEquivalent = "o"
            open.keyEquivalentModifierMask = [.command]
            menu.addItem(open)
            menu.addItem(ActionMenuItem("Go to Folder…") { [weak controller] in controller?.goToFolder(nil) })
        }
        menu.addItem(copyPathItem(folder))
        menu.addItem(.separator())
        if folder != path {
            menu.addItem(ActionMenuItem("Go to \(label)") { [weak self] in self?.onNavigate?(folder) })
            menu.addItem(.separator())
        }
        let folderIcon = symbol("folder.fill", Config.shared.theme.accent.withAlphaComponent(0.85))
        for name in names.prefix(400) {
            let full = FilePaths.join(folder, name)
            let onPath = path.map { $0 == full || $0.hasPrefix(full + "/") } ?? false
            let item = ActionMenuItem(name, checked: onPath) { [weak self] in self?.onNavigate?(full) }
            item.image = folderIcon
            menu.addItem(item)
        }
        if names.isEmpty {
            let none = NSMenuItem(title: "No folders inside", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        return menu
    }

    private func copyPathItem(_ folder: String) -> NSMenuItem {
        ActionMenuItem("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(folder, forType: .string)
        }
    }

    /// Dev aid (DevTools crumb-menu): the last folder's menu, printed, and the item called `run` chosen.
    func devFolderMenu(run: String?) {
        guard let crumb = crumbs.last else { return }
        listFolders?(crumb.path) { [weak self] names in
            guard let self else { return }
            let menu = self.folderMenu(crumb.path, label: crumb.label, names: names)
            FileHandle.standardError.write("menu: \(menu.items.map { $0.isSeparatorItem ? "---" : $0.title })\n".data(using: .utf8)!)
            if let run, let i = menu.items.firstIndex(where: { $0.title == run }) { menu.performActionForItem(at: i) }
        }
    }

    /// Right-click (or ⌃-click) on a folder in the path: copy where it is.
    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        guard let crumb = crumbs.first(where: { $0.rect.contains(p) }) else { return nil }
        let menu = NSMenu()
        menu.addItem(copyPathItem(crumb.path))
        return menu
    }
}

/// Drag strip on a sidebar's inner edge (the right edge of the left sidebar, the left edge of the right one).
final class SidebarResizeHandle: NSView {
    var isRight = false

    override func resetCursorRects() {
        boundsOutsideOverlays.forEach { addCursorRect($0, cursor: .resizeLeftRight) }
    }

    override func mouseDragged(with e: NSEvent) {
        guard let root = superview as? WindowRootView else { return }
        let x = root.convert(e.locationInWindow, from: nil).x
        if isRight { root.rightSidebarWidth = root.bounds.width - x } else { root.sidebarWidth = x }
        root.needsLayout = true
    }

    override func mouseUp(with e: NSEvent) {
        guard let root = superview as? WindowRootView else { return }
        let (key, w) = isRight ? ("solanum.sidebar.right.width", root.rightSidebarWidth) : ("solanum.sidebar.width", root.sidebarWidth)
        UserDefaults.standard.set(Double(w), forKey: key)
    }
}

/// Shades where a dragged tab would land (half the terminals, or the other column). Clicks pass through.
final class DropPreviewView: NSView {
    var target: NSRect? { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let r = target?.insetBy(dx: 6, dy: 6) else { return }
        let th = Config.shared.theme
        let path = NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10)
        th.accent.withAlphaComponent(0.16).setFill()
        path.fill()
        th.accent.withAlphaComponent(0.8).setStroke()
        path.lineWidth = 2
        path.stroke()
    }
}

/// The band between the two columns of a split window (as between files and terminal); drag it to resize them.
final class ColumnDivider: NSView {
    override func resetCursorRects() {
        boundsOutsideOverlays.forEach { addCursorRect($0, cursor: .resizeLeftRight) }
    }

    override func draw(_ dirtyRect: NSRect) {
        DividerBand.draw(in: bounds, vertical: true)
    }

    override func mouseDragged(with e: NSEvent) {
        guard let root = superview as? WindowRootView else { return }
        let area = root.columnArea
        guard area.width > 0 else { return }
        root.splitFraction = (root.convert(e.locationInWindow, from: nil).x - area.minX) / area.width
        root.needsLayout = true
    }
}

/// A view laid over a whole window (the Quantum Moon's reading): `WindowRootView` keeps it above everything else.
protocol WindowOverlay: NSView {
    /// What it covers, in its superview: the resize strips don't show their cursor there.
    var coveredRects: [NSRect] { get }
}

extension NSView {
    /// `bounds` less what the window's overlays cover of it, as the bands left above and below each (for the
    /// tall, thin resize strips).
    var boundsOutsideOverlays: [NSRect] {
        var pieces = [bounds]
        for case let o as WindowOverlay in superview?.subviews ?? [] {
            for r in o.coveredRects.map({ convert($0, from: superview) }) {
                pieces = pieces.flatMap { p -> [NSRect] in
                    guard p.intersects(r) else { return [p] }
                    return [NSRect(x: p.minX, y: p.minY, width: p.width, height: r.minY - p.minY),
                            NSRect(x: p.minX, y: r.maxY, width: p.width, height: p.maxY - r.maxY)].filter { $0.height > 0 }
                }
            }
        }
        return pieces
    }
}

/// Root content view: blur + background + the columns (each a tab strip in the title bar over its content)
/// + the file sidebars (left, and right while split) + status bar.
final class WindowRootView: NSView {
    let effect = NSVisualEffectView()
    let background = BackgroundView()
    private(set) var columns: [TabColumn] = []
    let sidebar = FileSidebarView()
    private let sidebarHandle = SidebarResizeHandle()
    let rightSidebar = FileSidebarView()
    private let rightSidebarHandle = SidebarResizeHandle()
    private let divider = ColumnDivider()
    let statusBar = StatusBarView()
    /// The right column's own status bar while split (folder, git), beside the left column's.
    let rightStatusBar = StatusBarView()
    var tabBarHeight: CGFloat = 40
    var sidebarVisible = false {
        didSet { statusBar.sidebarVisible = sidebarVisible; slideSidebars() }
    }
    var sidebarWidth: CGFloat = 240 {
        didSet { sidebarWidth = min(max(sidebarWidth, 160), 640) }
    }
    var rightSidebarVisible = false {
        didSet { rightStatusBar.rightSidebarVisible = rightSidebarVisible; slideSidebars() }
    }

    // MARK: Sliding the sidebars

    /// How much of each sidebar is showing (0…1). The terminals glide aside with the left one, frame by frame in
    /// step with the display, but resize just once (at the start of opening, the end of closing), since each
    /// resize makes the shell and programs like Claude Code redraw. Only their position changes in between.
    private var leftShown: CGFloat = 0
    private var rightShown: CGFloat = 0
    private var slideFrom: (left: CGFloat, right: CGFloat) = (0, 0)
    private var slideStart: CFTimeInterval = 0
    private var slideLink: CADisplayLink?
    private var leftTarget: CGFloat { sidebarVisible ? 1 : 0 }
    private var rightTarget: CGFloat { columns.count > 1 && rightSidebarVisible ? 1 : 0 }

    private func slideSidebars() {
        needsLayout = true
        guard window?.isVisible == true, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            leftShown = leftTarget
            rightShown = rightTarget
            return
        }
        guard leftShown != leftTarget || rightShown != rightTarget else { return }
        slideFrom = (leftShown, rightShown)
        slideStart = CACurrentMediaTime()
        guard slideLink == nil else { return }
        let link = displayLink(target: self, selector: #selector(slideStep(_:)))
        link.add(to: .main, forMode: .common)
        slideLink = link
    }

    /// One frame of the slide, timed for when it reaches the screen. A critically damped spring: it sets off
    /// gently, carries on, and settles without overshooting, so the sidebar and terminals move as one.
    @objc private func slideStep(_ link: CADisplayLink) {
        let t = max(0, link.targetTimestamp - slideStart)
        let w = 20.0
        let done = t >= 0.4
        let e = done ? 1 : CGFloat(1 - (1 + w * t) * exp(-w * t))
        leftShown = slideFrom.left + (leftTarget - slideFrom.left) * e
        rightShown = slideFrom.right + (rightTarget - slideFrom.right) * e
        if done {
            link.invalidate()
            slideLink = nil
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
    }
    var rightSidebarWidth: CGFloat = 240 {
        didSet { rightSidebarWidth = min(max(rightSidebarWidth, 160), 640) }
    }
    /// The left column's share of the space between the sidebars.
    var splitFraction: CGFloat = 0.5 {
        didSet { splitFraction = min(max(splitFraction, 0.2), 0.8) }
    }
    /// The space the columns share (between the sidebars), for the divider's drag.
    private(set) var columnArea: NSRect = .zero
    /// Holds a lone tab in windows without columns (the Quick Terminal).
    let content = NSView()
    /// Where a tab dragged off its strip would land, shaded over the terminals.
    var dropPreview: NSRect? { didSet { if dropPreview != oldValue { dropOverlay.target = dropPreview; needsLayout = true } } }
    private let dropOverlay = DropPreviewView()
    /// Cards in the top-right corner (see `CornerNoticeView`), newest first.
    private var notices: [CornerNoticeView] = []

    func showNotice(_ notice: CornerNoticeView) {
        notice.onDismiss = { [weak self] n in
            self?.notices.removeAll { $0 === n }
            self?.needsLayout = true
        }
        notices.insert(notice, at: 0)
        addSubview(notice)
        needsLayout = true
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        effect.blendingMode = .behindWindow
        effect.material = .hudWindow
        effect.state = .active
        addSubview(effect)
        addSubview(background)
        addSubview(content)
        addSubview(sidebar)
        addSubview(sidebarHandle)
        rightSidebarHandle.isRight = true
        addSubview(rightSidebar)
        addSubview(rightSidebarHandle)
        addSubview(divider)
        addSubview(statusBar)
        rightStatusBar.leadingEdge = true
        rightStatusBar.mirrored = true
        rightStatusBar.showsRightSidebarToggle = true
        addSubview(rightStatusBar)
        addSubview(dropOverlay)
        let d = UserDefaults.standard
        if d.double(forKey: "solanum.sidebar.right.width") > 0 { rightSidebarWidth = CGFloat(d.double(forKey: "solanum.sidebar.right.width")) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// Shows these columns (one, or two side by side); the last one's strip carries the Settings flower.
    func setColumns(_ cols: [TabColumn]) {
        for c in cols {
            if c.content.superview !== self { addSubview(c.content, positioned: .below, relativeTo: sidebar) }
            if c.tabBar.superview !== self { addSubview(c.tabBar) }
            c.tabBar.showsFlower = c === cols.last
        }
        columns = cols
        // Split: each column has its half of the bar; the theme name only fits when there's one.
        rightStatusBar.isHidden = cols.count < 2
        statusBar.showsThemeName = cols.count < 2
        slideSidebars()
    }

    override func layout() {
        super.layout()
        effect.frame = bounds
        background.frame = bounds
        let barH = columns.isEmpty ? 0 : tabBarHeight
        let statusH = StatusBarView.height
        let h = bounds.height - barH - statusH
        let split = columns.count > 1
        // Leave the terminals at least ~300pt however wide the sidebars were dragged.
        // Full widths, then how much of each is on screen (sliding) and how much the terminals give up.
        let fullW = min(sidebarWidth, max(160, bounds.width - 300))
        let fullRW = min(rightSidebarWidth, max(160, bounds.width - fullW * leftTarget - 300))
        let sw = (fullW * leftShown).rounded()
        let rsw = (fullRW * rightShown).rounded()
        let contentSW = leftShown > 0 || leftTarget > 0 ? fullW : 0
        let contentRSW = rightShown > 0 || rightTarget > 0 ? fullRW : 0
        let settled = slideLink == nil
        sidebar.isHidden = sw == 0
        sidebarHandle.isHidden = sw == 0 || !settled
        sidebar.frame = NSRect(x: sw - fullW, y: barH, width: fullW, height: h)
        // Resize strips: 12pt wide, mostly over the sidebar's own edge, so a press near the line resizes
        // rather than picking up a file row.
        sidebarHandle.frame = NSRect(x: sw - 7, y: barH, width: 12, height: h)
        rightSidebar.isHidden = rsw == 0
        rightSidebarHandle.isHidden = rsw == 0 || !settled
        rightSidebar.frame = NSRect(x: bounds.width - rsw, y: barH, width: fullRW, height: h)
        rightSidebarHandle.frame = NSRect(x: bounds.width - rsw - 5, y: barH, width: 12, height: h)
        // The terminals keep their settled width while the left sidebar slides, and ride along with its edge.
        columnArea = NSRect(x: sw, y: barH, width: bounds.width - contentSW - contentRSW, height: h)
        divider.isHidden = !split
        var barSplitX = bounds.width
        if split {
            let band = DividerBand.thickness
            let leftW = ((columnArea.width - band) * splitFraction).rounded()
            let divX = columnArea.minX + leftW
            columns[0].content.frame = NSRect(x: columnArea.minX, y: barH, width: leftW, height: h)
            columns[1].content.frame = NSRect(x: divX + band, y: barH, width: columnArea.maxX - divX - band, height: h)
            divider.frame = NSRect(x: divX, y: barH, width: band, height: h)
            barSplitX = divX
            // Each column's tabs sit in the title bar directly above it.
            columns[0].tabBar.frame = NSRect(x: 0, y: 0, width: divX, height: barH)
            columns[1].tabBar.frame = NSRect(x: divX, y: 0, width: bounds.width - divX, height: barH)
        } else if let c = columns.first {
            c.content.frame = columnArea
            c.tabBar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: barH)
        }
        content.isHidden = !columns.isEmpty
        if columns.isEmpty {
            content.frame = columnArea
            content.subviews.first?.frame = content.bounds
        }
        for c in columns {
            c.content.subviews.first?.frame = c.content.bounds
            // Its tabs line up with the content (see TabBarView.computeRects), which moves with the sidebars.
            c.tabBar.needsDisplay = true
        }
        statusBar.frame = NSRect(x: 0, y: bounds.height - statusH, width: barSplitX, height: statusH)
        rightStatusBar.frame = NSRect(x: barSplitX, y: bounds.height - statusH, width: bounds.width - barSplitX, height: statusH)
        dropOverlay.frame = bounds
        var noticeY = barH + 10
        for n in notices {
            let w = min(n.preferredWidth, bounds.width - 28)
            n.frame = NSRect(x: bounds.width - w - 14, y: noticeY, width: w, height: n.preferredHeight)
            noticeY += n.preferredHeight + 8
        }
        // Keep the overlay above columns added later (but under anything floating over the whole window).
        let floating = subviews.filter { $0 is WindowOverlay }
        if subviews.last(where: { !($0 is WindowOverlay) }) !== dropOverlay {
            if let f = floating.first { addSubview(dropOverlay, positioned: .below, relativeTo: f) } else { addSubview(dropOverlay) }
        }
        // Columns are added after the resize strips; keep the strips above them so their whole width works.
        for handle in [sidebarHandle, rightSidebarHandle] {
            let at = subviews.firstIndex(of: handle) ?? 0
            if columns.contains(where: { (subviews.firstIndex(of: $0.content) ?? 0) > at }) {
                addSubview(handle, positioned: .below, relativeTo: dropOverlay)
            }
        }
        // And whatever floats over the window stays above all of it, strips and overlay included.
        for v in floating where subviews.last !== v { addSubview(v) }
        window?.invalidateCursorRects(for: sidebarHandle)
        window?.invalidateCursorRects(for: rightSidebarHandle)
        window?.invalidateCursorRects(for: divider)
    }

    func applyTheme() {
        let cfg = Config.shared
        let th = cfg.theme
        effect.isHidden = !(cfg.blur && cfg.opacity < 1)
        effect.appearance = NSAppearance(named: th.isDark ? .darkAqua : .aqua)
        window?.appearance = NSAppearance(named: th.isDark ? .darkAqua : .aqua)
        background.needsDisplay = true
        columns.forEach { $0.tabBar.needsDisplay = true }
        divider.needsDisplay = true
        statusBar.needsDisplay = true
        rightStatusBar.needsDisplay = true
        sidebar.applyTheme()
        rightSidebar.applyTheme()
    }
}

/// Main terminal window with a custom Warp-style tab bar.
final class TerminalWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    /// One column of tabs, or two side by side (⌘D). Each has its own tab strip in the title bar; the one
    /// clicked into last is focused, and the menus, shortcuts and status bar act on it.
    private(set) var columns: [TabColumn] = []
    private(set) var focusedIndex = 0
    var focused: TabColumn { columns[min(focusedIndex, columns.count - 1)] }
    var tabs: [TabSession] { focused.tabs }
    var activeIndex: Int { focused.activeIndex }
    var tabBar: TabBarView { focused.tabBar }
    var allTabs: [TabSession] { columns.flatMap(\.tabs) }
    let rootView = WindowRootView()
    var onClose: ((TerminalWindowController) -> Void)?
    private var configObserver: NSObjectProtocol?
    /// The tab each sidebar last showed (see `updateSidebar`).
    private var sidebarTabs: [ObjectIdentifier: ObjectIdentifier] = [:]
    private(set) var git: GitController?
    /// The right column's, while split.
    private(set) var rightGit: GitController?

    var activeTab: TabSession? { focused.activeTab }

    static let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]

    /// The content size a window needs for `columns` × `rows` of text at the current font and padding.
    static func contentSize(columns: Int, rows: Int) -> NSSize {
        let cfg = Config.shared, f = FontSet.current
        return NSSize(width: CGFloat(columns) * f.cellW + cfg.padding * 2, height: CGFloat(rows) * f.cellH + 16 + 40 + StatusBarView.height)
    }

    /// The whole window's size for `columns` × `rows` of text (Settings › Preferences › Window Size).
    static func frameSize(columns: Int, rows: Int) -> NSSize {
        NSWindow.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize(columns: columns, rows: rows)), styleMask: styleMask).size
    }

    /// The columns × rows of text a window of this size holds: the inverse of `frameSize`.
    static func grid(fitting frame: NSSize) -> (columns: Int, rows: Int) {
        let cfg = Config.shared, f = FontSet.current
        let content = NSWindow.contentRect(forFrameRect: NSRect(origin: .zero, size: frame), styleMask: styleMask).size
        return (Int(((content.width - cfg.padding * 2) / f.cellW).rounded()),
                Int(((content.height - 16 - 40 - StatusBarView.height) / f.cellH).rounded()))
    }

    init(cwd: String?, restoring saved: WindowState? = nil) {
        let cfg = Config.shared
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.contentSize(columns: cfg.windowColumns, rows: cfg.windowRows)),
                              styleMask: Self.styleMask, backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .clear
        window.minSize = NSSize(width: 420, height: 240)
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary]
        window.contentView = rootView
        super.init(window: window)
        installToolbar()
        window.delegate = self
        columns = [TabColumn(owner: self)]
        rootView.setColumns(columns)
        rootView.tabBarHeight = titlebarHeight
        setUpFileBrowsing()
        if let saved, restore(saved) {
            // Each restored column focuses its tab asynchronously; start in the left one once they have.
            if columns.count > 1 { DispatchQueue.main.async { [weak self] in self.map { $0.focus($0.columns[0]) } } }
        } else {
            columns[0].addTab(cwd: cwd)
        }
        rootView.applyTheme()
        configObserver = NotificationCenter.default.addObserver(forName: .solanumConfigChanged, object: nil, queue: .main) { [weak self] _ in
            self?.rootView.applyTheme()
            self?.rootView.needsLayout = true
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let o = configObserver { NotificationCenter.default.removeObserver(o) }
    }

    /// Rebuilds the window's columns from a saved session. Returns false if nothing usable was saved.
    private func restore(_ saved: WindowState) -> Bool {
        guard columns[0].restore(tabs: saved.tabs, groups: saved.groups, active: saved.active) else { return false }
        if let r = saved.right {
            addColumn()
            if !columns[1].restore(tabs: r.tabs, groups: r.groups, active: r.active) { removeColumn(columns[1]) }
            // Sessions from before pins were per tab: the column's pin goes to its active tab.
            if let pinned = r.pinnedFolder, columns.count > 1, let tab = columns[1].activeTab, tab.pinnedFolder == nil {
                tab.pinnedFolder = (LocalFileSystem.shared, pinned)
            }
        }
        if let f = saved.splitFraction { rootView.splitFraction = CGFloat(f) }
        if let rs = saved.rightSidebar { rootView.rightSidebarVisible = rs }
        // Back where it was, at the size set in Settings › Preferences › Window Size, kept on its screen.
        if let r = saved.frame.map(NSRectFromString), let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(r) }) {
            let vis = screen.visibleFrame
            let size = Self.frameSize(columns: Config.shared.windowColumns, rows: Config.shared.windowRows)
            let w = min(size.width, vis.width), h = min(size.height, vis.height)
            let x = min(max(r.midX - w / 2, vis.minX), vis.maxX - w), y = min(max(r.midY - h / 2, vis.minY), vis.maxY - h)
            window?.setFrame(NSRect(x: x, y: y, width: w, height: h), display: false)
        }
        if let pinned = saved.pinnedFolder, let tab = columns[0].activeTab, tab.pinnedFolder == nil {
            tab.pinnedFolder = (LocalFileSystem.shared, pinned)
        }
        focusedIndex = 0
        return true
    }

    private var titlebarHeight: CGFloat {
        guard let w = window else { return 40 }
        let h = w.frame.height - w.contentLayoutRect.height
        return w.styleMask.contains(.fullScreen) ? 36 : max(32, h)
    }

    var trafficLightInset: CGFloat {
        guard let w = window, !w.styleMask.contains(.fullScreen), let zoom = w.standardWindowButton(.zoomButton) else { return 12 }
        return zoom.frame.maxX + 14
    }

    // MARK: Files

    private func setUpFileBrowsing() {
        let d = UserDefaults.standard
        rootView.sidebarVisible = d.bool(forKey: "solanum.sidebar.visible")
        if d.double(forKey: "solanum.sidebar.width") > 0 { rootView.sidebarWidth = CGFloat(d.double(forKey: "solanum.sidebar.width")) }
        let bar = rootView.statusBar
        bar.showsSidebarToggle = true
        bar.onToggleFileSidebar = { [weak self] in self?.toggleFileSidebar(nil) }
        bar.onShowHosts = { [weak self] at in self?.showHostsMenu(at: at) }
        bar.showsThemeName = true
        bar.onThemeMenu = { [weak bar] at in
            guard let bar else { return }
            let menu = NSMenu()
            let current = Config.shared.theme.name
            for t in ThemeLibrary.all {
                if t.name == ThemeLibrary.vsCode.first?.name {
                    menu.addItem(.separator())
                    let h = NSMenuItem(title: "VS Code", action: nil, keyEquivalent: "")
                    h.isEnabled = false
                    menu.addItem(h)
                }
                menu.addItem(ActionMenuItem(t.name, checked: t.name == current) {
                    Config.shared.themeName = t.name
                    Config.shared.commit()
                })
            }
            menu.addItem(.separator())
            menu.addItem(ActionMenuItem("Theme Settings…") { SettingsWindowController.shared.present(.appearance) })
            menu.popUpAbove(at, in: bar)
        }
        rootView.rightStatusBar.onToggleRightSidebar = { [weak self] in self?.toggleRightSidebar(nil) }
        // Each half of the bar (the whole bar, unless split) follows its column: breadcrumbs and git.
        git = followColumn(0, with: bar)
        rightGit = followColumn(1, with: rootView.rightStatusBar)
        // The left sidebar belongs to the left (or only) column, the right sidebar to the right column.
        for (sidebar, i) in [(rootView.sidebar, 0), (rootView.rightSidebar, 1)] {
            let column = { [weak self] () -> TabColumn? in
                guard let self, self.columns.indices.contains(i) else { return nil }
                return self.columns[i]
            }
            sidebar.onOpenFile = { fs, path in column()?.activeTab?.openFile(fs, path) }
            sidebar.onShowFile = { fs, path in column()?.activeTab?.openFile(fs, path, focus: false) }
            sidebar.onOpenDiff = { fs, path in column()?.activeTab?.openFile(fs, path, mode: .diff) }
            sidebar.onOpenPreview = { fs, path in column()?.activeTab?.openFile(fs, path, mode: .preview) }
            sidebar.onSearchFolder = { [weak self] fs, path in self?.searchFolder(fs: fs, path, in: column()) }
            sidebar.onOpenFileInTab = { fs, path in
                guard let c = column() else { return }
                c.activeTab?.closeEditorJustOpened(path)
                c.addFileTab(FileEditorView(fs: fs, path: path))
            }
            sidebar.onRenameTab = { name in
                guard let c = column(), let tab = c.activeTab else { return }
                c.renameTab(tab, to: name)
                tab.focus()
            }
            sidebar.onChangeDirectory = { dir in column()?.activeTab?.focusedPane.changeDirectory(to: dir) }
            sidebar.onPinChanged = { pinned in column()?.activeTab?.pinnedFolder = pinned }
            sidebar.onOpenFoldersChanged = { folders in column()?.activeTab?.openFolders = folders }
            sidebar.onPlaceChanged = { fs, root, followed in column()?.activeTab?.sidebarPlace = (fs, root, followed) }
            sidebar.onActivity = { [weak self, weak sidebar] text in
                guard let self, let sidebar else { return }
                (i == 0 ? self.rootView.statusBar : self.rootView.rightStatusBar).setTransfer(text, from: sidebar)
            }
        }
        rootView.rightSidebarVisible = d.bool(forKey: "solanum.sidebar.right.visible")
    }

    /// Breadcrumbs and git for column `i` on `bar`: its active tab's focused pane's folder, branch and changes.
    private func followColumn(_ i: Int, with bar: StatusBarView) -> GitController {
        let column = { [weak self] () -> TabColumn? in
            guard let self, self.columns.indices.contains(i) else { return nil }
            return self.columns[i]
        }
        bar.onNavigate = { dir in column()?.activeTab?.focusedPane.changeDirectory(to: dir) }
        bar.listFolders = { dir, done in
            guard let fs = column()?.activeTab?.browseFS else { return }
            fs.list(dir) { result in
                let names = ((try? result.get()) ?? []).filter { $0.isDirectory && !$0.isHidden }.map(\.name)
                done(names.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
            }
        }
        let git = GitController(bar: bar, pane: { column()?.activeTab?.focusedPane },
                                openFile: { fs, path in column()?.activeTab?.openFile(fs, path) },
                                openGraph: { fs, root in column()?.activeTab?.openFile(fs, root, mode: .graph) },
                                openStatus: { fs, root in column()?.activeTab?.openFile(fs, root, mode: .status) },
                                newTab: { cwd in column()?.addTab(cwd: cwd).focusedPane })
        bar.onBranch = { [weak git] in git?.showBranches() }
        bar.onSync = { [weak git, weak bar] at in if let bar { git?.showSyncMenu(at: at, in: bar) } }
        bar.onChanges = { [weak git, weak bar] at in if let bar { git?.showChangesMenu(at: at, in: bar) } }
        return git
    }

    /// Points the status bar and sidebar at the focused pane's folder (local, or remote inside ssh).
    private func updateFileChrome() {
        let bars = [rootView.statusBar, rootView.rightStatusBar]
        for (i, bar) in bars.enumerated() {
            guard columns.indices.contains(i), let tab = columns[i].activeTab else { bar.path = nil; continue }
            let fs = tab.browseFS
            let remote = tab.browseRemote
            let connecting = remote.map { !$0.isReady } ?? false
            bar.host = remote.map { $0.hostLabel ?? "ssh" }
            bar.home = fs.home
            bar.path = connecting ? nil : tab.browseDirectory
        }
        git?.update()
        rightGit?.update()
        if rootView.sidebarVisible { updateSidebar(rootView.sidebar, for: columns[0]) }
        if columns.count > 1 && rootView.rightSidebarVisible { updateSidebar(rootView.rightSidebar, for: columns[1]) }
    }

    /// Points a sidebar at its column's active tab: header, open file, and folder (local, or remote inside ssh).
    private func updateSidebar(_ sidebar: FileSidebarView, for column: TabColumn) {
        guard let tab = column.activeTab else { return }
        // Switching to a tab catches its sidebar up with changes made while it was in the background.
        let switched = sidebarTabs[ObjectIdentifier(sidebar)] != ObjectIdentifier(tab)
        sidebarTabs[ObjectIdentifier(sidebar)] = ObjectIdentifier(tab)
        defer { if switched { sidebar.refreshVisible() } }
        let fs = tab.browseFS
        let connecting = tab.browseRemote.map { !$0.isReady } ?? false
        sidebar.setTab(name: tab.customTitle, folder: connecting ? nil : tab.browseDirectory, home: fs.home)
        sidebar.setEditorFile(tab.editor?.path, fs: tab.editor?.fs)
        if switched {
            sidebar.applyTabOpenFolders(tab.openFolders)
            if tab.pinnedFolder == nil, !connecting {
                sidebar.applyTabPlace(tab.sidebarPlace, fs: fs, directory: tab.browseDirectory)
            }
        }
        sidebar.applyTabPin(tab.pinnedFolder)
        if connecting {
            sidebar.show(fs: fs, directory: nil, status: "Connecting to the ssh session…\nFiles appear here once you're logged in.")
        } else {
            sidebar.show(fs: fs, directory: tab.browseDirectory)
        }
    }

    /// ⌥⌘B: the folder sidebar on the right edge, for the right column (only while split).
    /// ⌘R: every pane in the tab (and its open file) repaints, and the programs in them redraw — for when the
    /// screen got garbled. Claude Code, ssh sessions and running commands carry on untouched.
    @objc func refreshTab(_ sender: Any?) {
        guard let tab = activeTab else { return }
        tab.panes.forEach { $0.refreshDisplay(nil) }
        tab.view.needsDisplay = true
        tab.editor?.needsDisplay = true
    }

    @objc func toggleRightSidebar(_ sender: Any?) {
        guard columns.count > 1 else { return NSSound.beep() }
        rootView.rightSidebarVisible.toggle()
        UserDefaults.standard.set(rootView.rightSidebarVisible, forKey: "solanum.sidebar.right.visible")
        updateFileChrome()
    }

    // MARK: SSH hosts

    private func showHostsMenu(at point: NSPoint) {
        let bar = rootView.statusBar
        let (configured, known) = SSHHosts.load()
        let menu = NSMenu()
        let dim: [NSAttributedString.Key: Any] = [.font: NSFont.menuFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
        func addHost(_ h: SSHHost, to menu: NSMenu) {
            let item = ActionMenuItem(h.title) { [weak self] in self?.connect(h) }
            if let detail = h.detail {
                let t = NSMutableAttributedString(string: h.title + "  ", attributes: [.font: NSFont.menuFont(ofSize: 13)])
                t.append(NSAttributedString(string: detail, attributes: dim))
                item.attributedTitle = t
            }
            item.image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: nil)
            item.keyEquivalentModifierMask = []
            menu.addItem(item)
            // Hold ⌥ to connect in the focused pane instead of a new tab.
            let here = ActionMenuItem("\(h.title) — in This Pane") { [weak self] in self?.connect(h, inNewTab: false) }
            here.isAlternate = true
            here.keyEquivalentModifierMask = [.option]
            menu.addItem(here)
        }
        let header = NSMenuItem(title: configured.isEmpty ? "No hosts in ~/.ssh/config" : "Connect in a new tab (⌥: this pane)",
                                action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        configured.forEach { addHost($0, to: menu) }
        if !known.isEmpty {
            let sub = NSMenu()
            known.prefix(200).forEach { addHost($0, to: sub) }
            let item = NSMenuItem(title: "Known Hosts", action: nil, keyEquivalent: "")
            item.submenu = sub
            menu.addItem(.separator())
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Edit SSH Config…") { [weak self] in
            SSHHosts.ensureConfigExists()
            self?.activeTab?.openFile(LocalFileSystem.shared, SSHHosts.configPath)
        })
        menu.popUpAbove(point, in: bar)
    }

    private func connect(_ host: SSHHost, inNewTab: Bool = true) {
        let command = "ssh " + host.target
        if inNewTab {
            let tab = focused.addTab(cwd: nil)
            tab.focusedPane.pendingCommand = command
        } else if let pane = activeTab?.focusedPane, !pane.exited, !pane.terminal.usingAlt, pane.remote == nil, !pane.hasRunningJob {
            pane.send("\u{15}" + command + "\r")
            window?.makeFirstResponder(pane)
        } else {
            NSSound.beep()
        }
    }

    /// ⇧⌘B: pins the sidebar to the folder it shows (opening the sidebar if needed), or unpins it.
    @objc func togglePinnedSidebarFolder(_ sender: Any?) {
        if !rootView.sidebarVisible {
            toggleFileSidebar(nil)
            if !rootView.sidebar.isPinned { rootView.sidebar.pin() }
            return
        }
        rootView.sidebar.togglePin()
    }

    @objc func toggleFileSidebar(_ sender: Any?) {
        rootView.sidebarVisible.toggle()
        UserDefaults.standard.set(rootView.sidebarVisible, forKey: "solanum.sidebar.visible")
        updateFileChrome()
    }

    var hasRunningJobs: Bool { allTabs.contains { $0.hasRunningJobs } }

    // MARK: Actions

    @objc func newTab(_ sender: Any?) {
        focused.newTab()
    }

    /// ⌥⌘T: a new tab in the current tab's group (or a new group with the current tab).
    @objc func newTabInGroup(_ sender: Any?) { focused.newTabInGroup() }

    /// ⌘O: picks folders in the open panel, starting from the terminal's folder; each opens in a new tab.
    @objc func openFolder(_ sender: Any?) {
        guard let w = window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Open"
        panel.message = "Open folders in new tabs"
        if let dir = focused.currentLocalFolder { panel.directoryURL = URL(fileURLWithPath: dir) }
        panel.beginSheetModal(for: w) { [weak self] resp in
            guard let self, resp == .OK else { return }
            panel.urls.forEach { self.addTab(cwd: $0.path) }
        }
    }

    /// ⌥⌘F: on the window rather than the editor, so it works (and the palette lists it) wherever the focus is,
    /// such as on the sidebar after clicking a file.
    @objc func beautifyDocument(_ sender: Any?) { activeTab?.editor?.formatDocument(sender) }

    /// ⇧⌘F, Search in Project Folder: searches the text of the files in the folder the sidebar is on (the focused column's, if it's open), else
    /// the pinned or current folder. Choosing a result opens the file there.
    @objc func findInFolder(_ sender: Any?) { findInFolder(query: "") }

    func findInFolder(query: String) {
        guard let w = window, let tab = activeTab else { return }
        let left = focusedIndex == 0
        let sidebar = left ? rootView.sidebar : rootView.rightSidebar
        let open = left ? rootView.sidebarVisible : rootView.rightSidebarVisible
        let scope = (open ? sidebar.shownFolder : nil) ?? tab.pinnedFolder ?? tab.browseDirectory.map { (tab.browseFS, $0) }
        guard let (fs, folder) = scope else { return NSSound.beep() }
        searchFolder(fs: fs, folder, in: focused, query: query, window: w)
    }

    /// Choosing a result opens the file in `column`'s active tab.
    private func searchFolder(fs: FileSystem, _ folder: String, in column: TabColumn?, query: String = "", window: NSWindow? = nil) {
        guard let w = window ?? self.window else { return }
        CommandPalette.findInFolder(in: w, fs: fs, folder: folder, query: query) { [weak column] path, line, text in
            guard let tab = column?.activeTab else { return }
            tab.openFile(fs, path)
            tab.editor?.reveal(line: line, text: text)
        }
    }

    /// The palette with "Go to: " typed in, for a folder whose path you know (see `CommandPalette.goToItems`).
    @objc func goToFolder(_ sender: Any?) {
        guard let w = window else { return }
        CommandPalette.show(in: w, items: CommandPalette.collectItems(), tracksRecents: true, query: CommandPalette.goToPrefix)
    }

    /// The focused column's repository history, as a graph above its terminal.
    @objc func showGitGraph(_ sender: Any?) {
        guard let controller = focusedIndex == 0 ? git : rightGit, controller.showGraph() else { return NSSound.beep() }
    }

    /// The focused column's repository status, as a page above its terminal.
    @objc func showGitStatus(_ sender: Any?) {
        guard let controller = focusedIndex == 0 ? git : rightGit, controller.showStatus() else { return NSSound.beep() }
    }

    // MARK: Reopening closed tabs

    private struct ClosedTab {
        let state: TabState
        let column: Int
        let index: Int
        weak var group: TabGroup?
    }

    /// Recently closed tabs, newest last.
    private var closedTabs: [ClosedTab] = []

    func rememberClosed(_ tab: TabSession, from column: TabColumn, at index: Int) {
        // A file tab whose last file was closed has nothing left to bring back.
        guard tab.showsTerminal || !tab.editors.isEmpty else { return }
        closedTabs.append(ClosedTab(state: tab.savedState(group: nil), column: columns.firstIndex(of: column) ?? 0,
                                    index: index, group: tab.group))
        if closedTabs.count > 25 { closedTabs.removeFirst() }
    }

    /// ⇧⌘T: reopens the most recently closed tab: a fresh shell in its folder with its old output above, its
    /// name, group and open files, back in its column and spot. (Programs that were running can't come back.)
    @objc func reopenClosedTab(_ sender: Any?) {
        guard let c = closedTabs.popLast() else { return NSSound.beep() }
        let column = columns.indices.contains(c.column) ? columns[c.column] : focused
        column.reopen(c.state, at: c.index, group: c.group)
        focus(column)
    }

    @objc func closeTab(_ sender: Any?) { focused.closeTab(at: focused.activeIndex) }

    @objc func selectNextTab(_ sender: Any?) { focused.stepTab(1) }

    @objc func selectPreviousTab(_ sender: Any?) { focused.stepTab(-1) }

    @objc func renameCurrentTab(_ sender: Any?) {
        if let t = activeTab { tabBar.beginEditing(tab: t) }
    }

    @objc func addCurrentTabToNewGroup(_ sender: Any?) {
        if let t = activeTab { focused.addToNewGroup(t) }
    }

    @objc func removeCurrentTabFromGroup(_ sender: Any?) {
        if let t = activeTab { focused.removeFromGroup(t) }
    }

    @objc func renameCurrentGroup(_ sender: Any?) {
        if let g = activeTab?.group { tabBar.beginEditing(group: g) }
    }

    @objc func collapseCurrentGroup(_ sender: Any?) {
        if let g = activeTab?.group { focused.setCollapsed(g, true) }
    }

    // Shortcuts for the focused column (DevTools and the rest of the app address the window).
    @discardableResult
    func addTab(cwd: String?) -> TabSession { focused.addTab(cwd: cwd) }
    func select(index: Int) { focused.select(index: index) }
    func closeTab(at index: Int) { focused.closeTab(at: index) }
    func renameTab(_ tab: TabSession, to name: String) { (tab.owner as? TabColumn ?? focused).renameTab(tab, to: name) }
    var groups: [TabGroup] { focused.groups }

    // MARK: Split (two columns)

    /// ⌘D: opens a second column to the right with a new tab in the current folder; with the split already
    /// open, a new tab in the right column.
    @objc func splitIntoColumns(_ sender: Any?) {
        let pane = activeTab?.focusedPane
        let cwd = pane?.remote == nil ? pane?.currentDirectory : nil
        if columns.count == 1 { addColumn() }
        columns[1].addTab(cwd: cwd)
        focus(columns[1])
    }

    /// Moves the current tab to the other column, opening the split if there's only one.
    @objc func moveTabToOtherColumn(_ sender: Any?) {
        guard let tab = activeTab else { return }
        move(tab, from: focused)
    }

    func move(_ tab: TabSession, from source: TabColumn) {
        if columns.count == 1 {
            guard source.tabs.count > 1 else { return NSSound.beep() }
            addColumn()
        }
        guard let target = columns.first(where: { $0 !== source }) else { return }
        source.detach(tab)
        target.adopt(tab)
        focus(target)
    }

    /// ⌃⌘W: closes the right column, moving its tabs to the left one (nothing running in them is lost).
    @objc func closeSplit(_ sender: Any?) {
        guard columns.count == 2 else { return NSSound.beep() }
        let right = columns[1], left = columns[0]
        let moving = right.tabs
        removeColumn(right)
        for t in moving { left.adopt(t, keepGroup: true) }
        focus(left)
    }

    /// Closes the right column's tabs (asking first if any are busy); the split goes away with the last one.
    func closeSplitAndTabs() {
        guard columns.count == 2 else { return }
        columns[1].closeTabs(columns[1].tabs)
    }

    @objc func focusOtherColumn(_ sender: Any?) {
        guard columns.count == 2 else { return NSSound.beep() }
        focus(columns[focusedIndex == 0 ? 1 : 0])
    }

    @discardableResult
    private func addColumn(at index: Int? = nil) -> TabColumn {
        let c = TabColumn(owner: self)
        columns.insert(c, at: min(index ?? columns.count, columns.count))
        rootView.setColumns(columns)
        relayoutChrome()
        return c
    }

    // MARK: Dragging a file's sub-tab onto a tab strip

    private enum EditorDrop { case ownTab(TabColumn), into(TabSession, TabColumn) }
    private var pendingEditorDrop: (editor: FileEditorView, from: TabSession, target: EditorDrop)?

    /// A file sub-tab dragged to `windowPoint`. Over a column's tab strip, the strip lights up and dropping gives
    /// the file a tab of its own there. Over the other column's terminal, that column lights up and dropping opens
    /// the file above its terminal (not if that terminal is in an ssh session).
    func editorDragOver(_ ed: FileEditorView, from tab: TabSession, at windowPoint: NSPoint) {
        let p = rootView.convert(windowPoint, from: nil)
        let source = tab.owner as? TabColumn
        var target: EditorDrop?, preview: NSRect?
        if let c = columns.first(where: { $0.tabBar.frame.contains(p) }) {
            // A file tab's only file is already in a tab of its own.
            if tab.showsTerminal || tab.editors.count > 1 || c !== source {
                target = .ownTab(c)
                preview = c.tabBar.frame
            }
        } else if let c = columns.first(where: { $0 !== source && $0.content.frame.contains(p) }),
                  let dest = c.activeTab, dest.focusedPane.remote == nil {
            target = .into(dest, c)
            preview = c.content.frame
        }
        pendingEditorDrop = target.map { (ed, tab, $0) }
        rootView.dropPreview = preview
    }

    func clearEditorDrop() {
        pendingEditorDrop = nil
        rootView.dropPreview = nil
    }

    func performEditorDrop() {
        rootView.dropPreview = nil
        guard let d = pendingEditorDrop else { return }
        pendingEditorDrop = nil
        d.from.closeEditor(d.editor)
        switch d.target {
        case .ownTab(let c):
            c.addFileTab(d.editor)
            focus(c)
        case .into(let dest, let c):
            dest.adoptEditor(d.editor)
            columnDidFocus(c)
        }
    }

    /// "Open in Its Own Tab" on a file sub-tab.
    func moveEditorToOwnTab(_ ed: FileEditorView, from tab: TabSession?) {
        guard let tab, let column = tab.owner as? TabColumn else { return }
        tab.closeEditor(ed)
        column.addFileTab(ed)
    }

    // MARK: Dragging a tab into the terminals

    private enum TabDrop { case newColumn(left: Bool), into(TabColumn) }
    private var pendingTabDrop: (tab: TabSession, from: TabColumn, target: TabDrop)?
    var hasPendingTabDrop: Bool { pendingTabDrop != nil }

    /// A tab dragged off its strip, now over `windowPoint`. With one column, the half of the terminals under the
    /// pointer lights up: dropping there splits the window with the tab on that side. With two, the other column
    /// lights up (its terminals or its strip) and takes the tab. Returns whether there's somewhere to drop.
    @discardableResult
    func tabDragOver(_ tab: TabSession, from source: TabColumn, at windowPoint: NSPoint) -> Bool {
        let p = rootView.convert(windowPoint, from: nil)
        var target: TabDrop?, preview: NSRect?
        if columns.count == 1 {
            let a = rootView.columnArea
            if a.contains(p), source.tabs.count > 1 {
                let left = p.x < a.midX
                target = .newColumn(left: left)
                preview = NSRect(x: left ? a.minX : a.midX, y: a.minY, width: a.width / 2, height: a.height)
            }
        } else if let other = columns.first(where: { $0 !== source }), other.content.frame.union(other.tabBar.frame).contains(p) {
            target = .into(other)
            preview = other.content.frame
        }
        pendingTabDrop = target.map { (tab, source, $0) }
        rootView.dropPreview = preview
        return target != nil
    }

    func clearTabDrop() {
        pendingTabDrop = nil
        rootView.dropPreview = nil
    }

    func performTabDrop() {
        guard let d = pendingTabDrop else { return }
        clearTabDrop()
        let target: TabColumn
        switch d.target {
        case .into(let c): target = c
        case .newColumn(let left): target = addColumn(at: left ? 0 : 1)
        }
        d.from.detach(d.tab)
        target.adopt(d.tab)
        focus(target)
        updateFileChrome()
    }

    private func removeColumn(_ c: TabColumn) {
        guard columns.count > 1, let i = columns.firstIndex(of: c) else { return }
        columns.remove(at: i)
        c.tabBar.removeFromSuperview()
        c.content.removeFromSuperview()
        focusedIndex = 0
        rootView.setColumns(columns)
        relayoutChrome()
        updateFileChrome()
    }

    func focus(_ c: TabColumn) {
        c.activeTab?.focus()
        columnDidFocus(c)
    }

    // Called by columns.

    func columnDidFocus(_ c: TabColumn) {
        guard let i = columns.firstIndex(of: c), i != focusedIndex else { return }
        focusedIndex = i
        columns.forEach { $0.tabBar.needsDisplay = true }
        columnDidChange(c)
    }

    func columnDidChange(_ c: TabColumn) {
        if c === focused { window?.title = activeTab?.title ?? "Solanum" }
        updateFileChrome()
    }

    /// A column's last tab closed: the split closes, or with one column, the window.
    func columnDidEmpty(_ c: TabColumn) {
        if columns.count > 1 {
            removeColumn(c)
            focus(columns[0])
        } else {
            window?.close()
        }
    }

    /// Tag of the ⇧⌘←/→ tab items, which give way to text selection in an editor or field.
    static let arrowTabTag = 900

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.tag == Self.arrowTabTag, let text = window?.firstResponder as? NSTextView, text.isEditable { return false }
        switch item.action {
        case #selector(removeCurrentTabFromGroup(_:)), #selector(renameCurrentGroup(_:)), #selector(collapseCurrentGroup(_:)):
            return activeTab?.group != nil
        case #selector(togglePinnedSidebarFolder(_:)):
            item.title = rootView.sidebar.isPinned ? "Unpin Sidebar Folder" : "Pin Sidebar Folder"
            return true
        case #selector(reopenClosedTab(_:)):
            return !closedTabs.isEmpty
        case #selector(beautifyDocument(_:)):
            return activeTab?.editor?.mode == .file
        case #selector(closeSplit(_:)), #selector(focusOtherColumn(_:)), #selector(toggleRightSidebar(_:)):
            return columns.count > 1
        case #selector(moveTabToOtherColumn(_:)):
            item.title = columns.count > 1 ? "Move Tab to Other Split" : "Move Tab to New Split"
            return columns.count > 1 || tabs.count > 1
        default:
            return true
        }
    }

    @objc func selectTabByNumber(_ sender: NSMenuItem) {
        let n = sender.tag
        select(index: n == 9 ? tabs.count - 1 : n - 1)
    }

    @objc func showCommandPalette(_ sender: Any?) {
        guard let w = window else { return }
        CommandPalette.toggle(in: w)
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let unsaved = allTabs.contains { $0.hasUnsavedFile }
        guard unsaved || hasRunningJobs && Config.shared.confirmQuit else { return true }
        let alert = NSAlert()
        alert.messageText = "Close this window?"
        alert.informativeText = unsaved ? "A file open in the editor has unsaved changes, which will be lost."
                                        : "Processes are still running in this window and will be terminated."
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: sender) { resp in
            if resp == .alertFirstButtonReturn {
                self.allTabs.forEach { $0.terminateAll() }
                sender.close()
            }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        allTabs.forEach { $0.terminateAll() }
        onClose?(self)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        columns.forEach { $0.tabBar.needsDisplay = true }
        git?.refresh(now: true)
        rightGit?.refresh(now: true)
    }

    // The empty toolbar only exists to make the windowed titlebar taller. In full screen AppKit moves it into
    // its own always-visible window that covers the tab bar, so drop it there and put it back on the way out.
    func windowWillEnterFullScreen(_ notification: Notification) { window?.toolbar = nil }
    func windowDidEnterFullScreen(_ notification: Notification) { relayoutChrome() }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) { installToolbar(); relayoutChrome() }
    func windowDidExitFullScreen(_ notification: Notification) { installToolbar(); relayoutChrome() }

    private func installToolbar() {
        guard let w = window, w.toolbar == nil else { return }
        w.toolbar = NSToolbar(identifier: "SolanumToolbar")
        w.toolbarStyle = .unifiedCompact
    }

    private func relayoutChrome() {
        rootView.tabBarHeight = titlebarHeight
        rootView.needsLayout = true
        for c in columns {
            c.tabBar.needsLayout = true
            c.tabBar.needsDisplay = true
        }
    }
}

/// Text field cell that centers its single line vertically, for the inline tab/group name editors.
final class CenteredTextFieldCell: NSTextFieldCell {
    /// Padding left and right of the text.
    var horizontalInset: CGFloat = 0
    /// Called with the editor AppKit puts in the field, whenever it does.
    var onEditorSetUp: ((NSTextView) -> Void)?

    // The editor AppKit puts in the field while typing paints its own background over just the text's rect,
    // which showed as a second, darker box inside the field. The field's own background is enough.
    override func setUpFieldEditorAttributes(_ textObj: NSText) -> NSText {
        let t = super.setUpFieldEditorAttributes(textObj)
        t.drawsBackground = false
        (t as? NSTextView)?.backgroundColor = .clear
        if let view = t as? NSTextView { onEditorSetUp?(view) }
        return t
    }

    override func titleRect(forBounds r: NSRect) -> NSRect {
        let inner = r.insetBy(dx: horizontalInset, dy: 0)
        let h = min(inner.height, cellSize(forBounds: inner).height)
        return NSRect(x: inner.minX, y: inner.minY + ((inner.height - h) / 2).rounded(), width: inner.width, height: h)
    }

    override func drawInterior(withFrame frame: NSRect, in view: NSView) {
        super.drawInterior(withFrame: titleRect(forBounds: frame), in: view)
    }

    override func edit(withFrame r: NSRect, in v: NSView, editor: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: titleRect(forBounds: r), in: v, editor: editor, delegate: delegate, event: event)
    }

    override func select(withFrame r: NSRect, in v: NSView, editor: NSText, delegate: Any?, start: Int, length: Int) {
        super.select(withFrame: titleRect(forBounds: r), in: v, editor: editor, delegate: delegate, start: start, length: length)
    }
}

/// Menu item that runs a closure (for context menus built on the fly).
extension NSMenu {
    /// Pops up with its bottom-left corner at `point` (menus from the status bar, at the window's bottom edge),
    /// where `popUp(positioning:at:in:)` would hang it down from there and squeeze it against the screen's edge.
    /// It's hung from its last row: then a menu taller than the room above (a long ssh host list) fills that
    /// room and scrolls, its bottom still at `point`, instead of being pushed down over it.
    func popUpAbove(_ point: NSPoint, in view: NSView) {
        guard let last = items.last(where: { !$0.isHidden && !$0.isAlternate }) else { return }
        let up = rowAndPadding(below: last)
        popUp(positioning: last, at: NSPoint(x: point.x, y: point.y + (view.isFlipped ? -up : up)), in: view)
    }

    /// How far the menu reaches below the top of `item`'s row when it's the last one: its height plus the menu's
    /// bottom padding, measured on menus of one and two copies of it.
    private func rowAndPadding(below item: NSMenuItem) -> CGFloat {
        func height(_ n: Int) -> CGFloat {
            let m = NSMenu()
            m.font = font
            for _ in 0..<n {
                let copy = item.isSeparatorItem ? NSMenuItem.separator() : NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
                copy.image = item.image
                if let t = item.attributedTitle { copy.attributedTitle = t }
                m.addItem(copy)
            }
            return m.size.height
        }
        let one = height(1), row = height(2) - one
        return row + (one - row) / 2
    }
}

final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, checked: Bool = false, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        state = checked ? .on : .off
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}

/// Custom-drawn tab strip that sits in the (transparent) titlebar. Groups show as a colored chip
/// before their tabs with a matching line along their top; clicking the chip collapses the group. The active
/// tab opens onto the terminal below it, like a folder tab.
final class TabBarView: NSView, NSTextFieldDelegate {
    /// The column whose tabs this strip shows.
    weak var controller: TabColumn?
    /// Redraws the flower's update badge when the updater's state changes.
    private var updateObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard updateObserver == nil, window != nil else { return }
        updateObserver = NotificationCenter.default.addObserver(forName: .solanumUpdateChanged, object: nil, queue: .main) { [weak self] _ in
            self?.needsDisplay = true
        }
    }
    /// Only the rightmost strip carries the Settings flower.
    var showsFlower = true { didSet { needsLayout = true; needsDisplay = true } }
    /// On the right column's strip: closes the split (its tabs move to the left column).
    private var closeSplitRect: CGRect = .null
    private var hoverCloseSplit = false
    private var tabRects: [CGRect] = []          // .null for tabs hidden in a collapsed group
    private var closeRects: [CGRect] = []
    private var chips: [(group: TabGroup, rect: CGRect)] = []
    var firstChipRect: CGRect? { chips.first?.rect }   // dev aid (DevTools chip-menu-rename)
    /// Dev aid (DevTools print-anim): how far through a slide, and each tab / ghost as drawn now (x+width).
    var animSummary: String {
        guard let c = controller else { return "" }
        let p = String(format: "%.2f", animProgress)
        let tabs = c.tabs.map { t in shownRect(ObjectIdentifier(t)).map { "\(t.customTitle ?? "?")@\(Int($0.minX))+\(Int($0.width))" } ?? "\(t.customTitle ?? "?")@-" }
        let gone = ghosts.map { "ghost \($0.tab.customTitle ?? "?")+\(Int($0.rect.width * (1 - animProgress)))" }
        let plus = shownRect(Self.plusKey).map { "plus@\(Int($0.minX))" } ?? ""
        return "p=\(p) " + (tabs + gone + [plus]).joined(separator: " ")
    }

    /// Dev aid (DevTools print-tabs): each tab's name, group and span, then the chips.
    var layoutSummary: String {
        guard let c = controller else { return "" }
        var out = c.tabs.indices.map { i in
            let r = tabRects[i]
            return "tab\(i) \(c.tabs[i].customTitle ?? "-") group=\(c.tabs[i].group?.name ?? "-") x=\(r.isNull ? "hidden" : "\(Int(r.minX))-\(Int(r.maxX))")\(selectedTabs.contains(c.tabs[i]) ? " PICKED" : "")"
        }
        out += chips.map { "chip \($0.group.name) x=\(Int($0.rect.minX))-\(Int($0.rect.maxX))" }
        return out.joined(separator: "\n")
    }
    private var plusRect: CGRect = .zero
    /// When the tabs don't fit at their minimum width the strip scrolls sideways: `viewport` is the part of the
    /// bar they show in, `scrollX` how far along they're scrolled, and ‹ › buttons sit at either end.
    private var viewport: CGRect = .zero
    private var scrollX: CGFloat = 0
    private var maxScrollX: CGFloat = 0
    private var tabSlide: (from: CGFloat, to: CGFloat, start: CFTimeInterval)?
    private var tabSlideLink: CADisplayLink?
    private var leftArrowRect: CGRect = .null
    private var rightArrowRect: CGRect = .null
    private var hoverArrow: Int?                 // -1 left, 1 right
    /// The tab last scrolled into view; a different active tab gets scrolled to.
    private weak var revealedTab: TabSession?
    private static let minTabWidth: CGFloat = 120
    private static let maxTabWidth: CGFloat = 230

    /// Layout animation: where each tab, chip and the "+" belongs (content coordinates, i.e. ignoring the
    /// scroll), where they're sliding from, and closed tabs shrinking away. Any change to the layout (tabs
    /// opened, closed, moved, grouped, collapsed) slides everything from where it was drawn to its new place.
    private var targets: [AnyHashable: CGRect] = [:]
    private var animFrom: [AnyHashable: CGRect] = [:]
    private var animStart: CFTimeInterval = 0
    private var animTimer: Timer?
    private var ghosts: [(tab: TabSession, rect: CGRect)] = []
    private var knownTabs: [ObjectIdentifier: TabSession] = [:]
    private var lastLayoutWidth: CGFloat = 0
    private static let animDuration: CFTimeInterval = 0.2
    private static let plusKey: AnyHashable = "plus"
    /// The Solanum flower in the top-right corner; clicking it opens Settings.
    private var flowerRect: CGRect = .zero
    private var hoverFlower = false
    private static let flower = SolanumArt.flowerImage(size: 22)
    private var hoverIndex: Int?
    private var hoverChip: Int?
    private var hoverClose = false
    private var hoverPlus = false
    private var dragIndex: Int?
    private var dragStartX: CGFloat = 0
    /// Where the press was, so a drag counts in any direction (straight down off the strip, too).
    private var dragStartY: CGFloat = 0
    /// While a tab is being dragged: the pointer's x, where on the tab it was grabbed, and the tab it would
    /// land in front of (tabs.count = the end). The tab follows the pointer; a line marks the landing spot.
    private var dragging = false
    private var dragX: CGFloat = 0
    private var grabOffset: CGFloat = 0
    private var insertBefore: Int?
    /// While a group's chip is being dragged, the group (chip and tabs) follows the pointer like a dragged tab;
    /// `groupInsertBefore` is the tab it would land in front of (tabs.count = the end).
    private var dragGroup: TabGroup?
    private var dragGroupMoved = false
    private var groupInsertBefore: Int?
    /// Tabs picked with ⌘-click / ⇧-click; right-clicking one of them acts on all (e.g. group them).
    private(set) var selectedTabs: [TabSession] = []
    private var dropTab: Int?                    // tab under a dragged tab that it would group with
    private var dropChip: TabGroup?              // group chip under a dragged tab that it would join

    private enum EditTarget { case tab(TabSession), group(TabGroup) }
    private var editing: EditTarget?
    private var editor: NSTextField?

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func layout() {
        super.layout()
        computeRects()
    }

    private static let chipFont = NSFont.systemFont(ofSize: 11.5, weight: .semibold)

    /// The tab / chip under `p`, ignoring parts scrolled out of view.
    private func tabIndex(at p: NSPoint) -> Int? {
        viewport.contains(p) ? tabRects.firstIndex { $0.contains(p) } : nil
    }

    private func chipIndex(at p: NSPoint) -> Int? {
        viewport.contains(p) ? chips.firstIndex { $0.rect.contains(p) } : nil
    }

    /// Returns how far the tabs actually moved.
    @discardableResult
    private func scrollTabs(by dx: CGFloat) -> CGFloat {
        stopTabSlide()
        let next = min(max(scrollX + dx, 0), maxScrollX)
        let moved = next - scrollX
        guard moved != 0 else { return 0 }
        scrollX = next
        computeRects()
        needsDisplay = true
        return moved
    }

    /// The ‹ › buttons: the tabs slide there rather than jump. Pressing again on the way carries on from where it was
    /// heading.
    private func slideTabs(by dx: CGFloat) {
        let to = min(max((tabSlide?.to ?? scrollX) + dx, 0), maxScrollX)
        guard to != scrollX else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            scrollTabs(by: to - scrollX)
            return
        }
        tabSlide = (scrollX, to, CACurrentMediaTime())
        if tabSlideLink == nil {
            let link = displayLink(target: self, selector: #selector(tabSlideStep))
            link.add(to: .main, forMode: .common)
            tabSlideLink = link
        }
    }

    @objc private func tabSlideStep() {
        guard let s = tabSlide, window != nil else { return stopTabSlide() }
        let t = min(1, (CACurrentMediaTime() - s.start) / 0.24)
        let eased = 1 - pow(1 - t, 3)
        scrollX = s.from + (s.to - s.from) * CGFloat(eased)
        computeRects()
        needsDisplay = true
        if t >= 1 { stopTabSlide() }
    }

    private func stopTabSlide() {
        tabSlideLink?.invalidate()
        tabSlideLink = nil
        tabSlide = nil
    }

    /// Dev aids (DevTools tab-arrow, print-tab-scroll).
    func devPressArrow(_ dir: Int) { slideTabs(by: CGFloat(dir) * viewport.width * 0.75) }
    var devScrollState: String { "scroll=\(Int(scrollX)) of \(Int(maxScrollX)) sliding=\(tabSlide != nil)" }

    /// Dragging a tab or group near either end of a scrolling strip scrolls it, to carry it past tabs out of view.
    private func autoScrollWhileDragging(_ p: NSPoint) {
        guard maxScrollX > 0 else { return }
        let step: CGFloat = p.x < viewport.minX + 28 ? -14 : p.x > viewport.maxX - 28 ? 14 : 0
        guard step != 0 else { return }
        // The lifted group is drawn relative to where it was grabbed, which scrolls with the tabs.
        dragStartX -= scrollTabs(by: step)
    }

    override func scrollWheel(with e: NSEvent) {
        guard maxScrollX > 0 else { return super.scrollWheel(with: e) }
        // Sideways swipes, or an ordinary mouse wheel, move the tabs.
        let d = abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY) ? e.scrollingDeltaX : e.scrollingDeltaY
        scrollTabs(by: -(e.hasPreciseScrollingDeltas ? d : d * 24))
    }

    private func chipLabel(_ g: TabGroup) -> String {
        guard g.collapsed, let n = controller?.tabs(in: g).count else { return g.name }
        return g.name.isEmpty ? "\(n)" : "\(g.name)  \(n)"
    }

    private func chipWidth(_ g: TabGroup) -> CGFloat {
        // While renaming, the chip grows to hold the editor so it never covers the tabs.
        if case .group(let eg) = editing, eg === g, let f = editor {
            let text = f.stringValue.isEmpty ? f.placeholderAttributedString?.string ?? f.placeholderString ?? "" : f.stringValue
            let w = (text as NSString).size(withAttributes: [.font: f.font ?? Self.chipFont]).width
            return min(200, max(90, ceil(w) + 26))
        }
        let label = chipLabel(g)
        guard !label.isEmpty else { return 20 }
        let w = (label as NSString).size(withAttributes: [.font: Self.chipFont]).width
        return min(160, ceil(w) + 18)
    }

    private func computeRects() {
        guard let c = controller else { return }
        // Tabs stay over the column's own content, not the sidebars beside it, so the active tab opens onto
        // its terminal. Beside the file sidebar they start right on its border line, which carries on up as the
        // first tab's edge.
        let content = c.content.frame.offsetBy(dx: -frame.minX, dy: 0)
        sidebarEdge = content.isEmpty || content.minX < 1 ? nil : content.minX - 1
        let left = max(c.trafficLightInset, sidebarEdge ?? 0)
        let plusW: CGFloat = 30
        // Each group gets a chip where it starts; tabs in collapsed groups take no space.
        var chipSpace: CGFloat = 0, visible = 0
        var prev: TabGroup?
        for t in c.tabs {
            if let g = t.group, g !== prev { chipSpace += chipWidth(g) + 6 }
            prev = t.group
            if t.group?.collapsed != true { visible += 1 }
        }
        flowerRect = showsFlower ? CGRect(x: bounds.width - 38, y: (bounds.height - 26) / 2, width: 26, height: 26) : .null
        var rightLimit = showsFlower ? flowerRect.minX - 6 : bounds.width - 6
        if !content.isEmpty { rightLimit = min(rightLimit, content.maxX - 6) }
        if c.isLeading {
            closeSplitRect = .null
        } else {
            closeSplitRect = CGRect(x: rightLimit - 26, y: (bounds.height - 24) / 2, width: 24, height: 24)
            rightLimit = closeSplitRect.minX - 4
        }
        let available = rightLimit - left - plusW - 10 - chipSpace
        let gaps = CGFloat(max(visible - 1, 0)) * 4
        let fitW = (available - gaps) / CGFloat(max(visible, 1))
        let overflow = fitW < Self.minTabWidth
        let w = overflow ? Self.minTabWidth : min(Self.maxTabWidth, fitW)
        let h: CGFloat = 28
        let y = (bounds.height - h) / 2
        let arrowW: CGFloat = 22
        if overflow {
            // Arrows at both ends, "+" pinned beside the flower; the tabs scroll between the arrows.
            plusRect = CGRect(x: rightLimit - 4 - 26, y: (bounds.height - 26) / 2, width: 26, height: 26)
            leftArrowRect = CGRect(x: left, y: (bounds.height - 24) / 2, width: arrowW, height: 24)
            rightArrowRect = CGRect(x: plusRect.minX - 6 - arrowW, y: (bounds.height - 24) / 2, width: arrowW, height: 24)
            viewport = CGRect(x: leftArrowRect.maxX + 2, y: 0, width: rightArrowRect.minX - 2 - leftArrowRect.maxX - 2, height: bounds.height)
            maxScrollX = max(0, chipSpace + CGFloat(visible) * w + gaps + 4 - viewport.width)
        } else {
            leftArrowRect = .null
            rightArrowRect = .null
            viewport = CGRect(x: left, y: 0, width: max(0, rightLimit - left), height: bounds.height)
            maxScrollX = 0
        }
        scrollX = min(max(scrollX, 0), maxScrollX)
        var x = viewport.minX - scrollX
        tabRects = []
        chips = []
        prev = nil
        for t in c.tabs {
            if let g = t.group, g !== prev {
                let cw = chipWidth(g)
                chips.append((g, CGRect(x: x, y: bounds.height / 2 - 10, width: cw, height: 20)))
                x += cw + 6
            }
            prev = t.group
            if t.group?.collapsed == true {
                tabRects.append(.null)
            } else {
                tabRects.append(CGRect(x: x, y: y, width: w, height: h))
                x += w + 4
            }
        }
        closeRects = tabRects.map { $0.isNull ? .null : CGRect(x: $0.maxX - 24, y: $0.midY - 9, width: 18, height: 18) }
        if !overflow { plusRect = CGRect(x: x + 2, y: (bounds.height - 26) / 2, width: 26, height: 26) }
        // Bring a newly active tab into view (switching tabs, opening one); otherwise leave the scroll alone.
        if let active = c.activeTab, active !== revealedTab, let i = c.tabs.firstIndex(of: active), !tabRects[i].isNull {
            revealedTab = active
            let r = tabRects[i]
            var shift: CGFloat = 0
            if r.minX < viewport.minX { shift = r.minX - viewport.minX - 8 }
            else if r.maxX > viewport.maxX { shift = r.maxX - viewport.maxX + 8 }
            if shift != 0, maxScrollX > 0 {
                stopTabSlide()
                scrollX = min(max(scrollX + shift, 0), maxScrollX)
                return computeRects()
            }
        }
        positionEditor()
        updateTargets(c, overflow: !leftArrowRect.isNull)
    }

    // MARK: Layout animation

    /// 0…1 through the current slide (eased), 1 when nothing is moving.
    private var animProgress: CGFloat {
        guard animTimer != nil else { return 1 }
        let t = min(1, (CACurrentMediaTime() - animStart) / Self.animDuration)
        return CGFloat(1 - pow(1 - t, 3))
    }

    private static func lerp(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(x: a.minX + (b.minX - a.minX) * t, y: a.minY + (b.minY - a.minY) * t,
               width: a.width + (b.width - a.width) * t, height: a.height + (b.height - a.height) * t)
    }

    /// Where `key` is drawn right now, in content coordinates.
    private func contentRect(_ key: AnyHashable) -> CGRect? {
        guard let to = targets[key] else { return nil }
        let p = animProgress
        guard p < 1, let from = animFrom[key] else { return to }
        return Self.lerp(from, to, p)
    }

    /// Where `key` is drawn right now, in view coordinates (nil: not laid out).
    private func shownRect(_ key: AnyHashable) -> CGRect? {
        if key == Self.plusKey && targets[key] == nil { return plusRect }
        return contentRect(key)?.offsetBy(dx: key == Self.plusKey && !leftArrowRect.isNull ? 0 : -scrollX, dy: 0)
    }

    /// Records the new layout; if it differs from the last one, starts sliding from what's on screen now.
    private func updateTargets(_ c: TabColumn, overflow: Bool) {
        var next: [AnyHashable: CGRect] = [:]
        var tabsNow: [ObjectIdentifier: TabSession] = [:]
        for (i, t) in c.tabs.enumerated() {
            tabsNow[ObjectIdentifier(t)] = t
            var r = tabRects[i]
            // A tab in a collapsed group folds into the right edge of its chip.
            if r.isNull, let g = t.group, let chip = chips.first(where: { $0.group === g })?.rect {
                r = CGRect(x: chip.maxX, y: (bounds.height - 28) / 2, width: 0, height: 28)
            }
            if !r.isNull { next[ObjectIdentifier(t)] = r.offsetBy(dx: scrollX, dy: 0) }
        }
        for ch in chips { next[ObjectIdentifier(ch.group)] = ch.rect.offsetBy(dx: scrollX, dy: 0) }
        if !overflow { next[Self.plusKey] = plusRect.offsetBy(dx: scrollX, dy: 0) }

        let changed = next.count != targets.count || next.contains { k, r in
            guard let old = targets[k] else { return true }
            return abs(old.minX - r.minX) > 0.5 || abs(old.width - r.width) > 0.5
        }
        let animate = changed && !targets.isEmpty && bounds.width == lastLayoutWidth
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if animate {
            var from: [AnyHashable: CGRect] = [:]
            for (k, r) in next { if let cur = contentRect(k) { from[k] = cur } }
            // New tabs grow out of the right edge of the tab before them (as drawn now); new chips out of the left
            // edge of their first tab. Growing in place would overlap neighbors that are still sliding over.
            func grow(_ k: AnyHashable, at x: CGFloat?) {
                guard from[k] == nil, let r = next[k] else { return }
                from[k] = CGRect(x: x ?? r.minX, y: r.minY, width: 0, height: r.height)
            }
            for (i, t) in c.tabs.enumerated() {
                let before = i > 0 ? contentRect(ObjectIdentifier(c.tabs[i - 1])).flatMap { $0.width > 1 ? $0.maxX + 4 : nil } : nil
                grow(ObjectIdentifier(t), at: before)
            }
            for ch in chips {
                let first = c.tabs.first { $0.group === ch.group }.flatMap { contentRect(ObjectIdentifier($0)) }
                grow(ObjectIdentifier(ch.group), at: first?.minX)
            }
            for k in next.keys { grow(k, at: nil) }
            let stillShrinking = ghosts.filter { tabsNow[ObjectIdentifier($0.tab)] == nil }
            ghosts = stillShrinking.map { ($0.tab, CGRect(x: $0.rect.minX, y: $0.rect.minY, width: $0.rect.width * (1 - animProgress), height: $0.rect.height)) }
            for (id, tab) in knownTabs where tabsNow[id] == nil {
                if let r = contentRect(id), r.width > 1 { ghosts.append((tab, r)) }
            }
            animFrom = from
            animStart = CACurrentMediaTime()
            if animTimer == nil {
                let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] t in
                    guard let self else { return t.invalidate() }
                    if CACurrentMediaTime() - self.animStart >= Self.animDuration {
                        t.invalidate()
                        self.animTimer = nil
                        self.ghosts = []
                    }
                    self.needsDisplay = true
                }
                RunLoop.main.add(timer, forMode: .common)
                animTimer = timer
            }
        }
        targets = next
        knownTabs = tabsNow
        lastLayoutWidth = bounds.width
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let c = controller else { return }
        computeRects()
        let th = Config.shared.theme
        let liftedGroup = dragGroupMoved ? dragGroup : nil
        // The active tab, where it sits (not while it's dragged), cut to the part scrolled into view.
        var docked: CGRect?
        if c.tabs.indices.contains(c.activeIndex), !(dragging && dragIndex == c.activeIndex),
           liftedGroup == nil || c.tabs[c.activeIndex].group !== liftedGroup,
           let r = shownRect(ObjectIdentifier(c.tabs[c.activeIndex])) ?? (tabRects[c.activeIndex].isNull ? nil : tabRects[c.activeIndex]) {
            let x0 = max(r.minX, viewport.minX), x1 = min(r.maxX, viewport.maxX)
            if x1 - x0 > 20 { docked = CGRect(x: x0, y: r.minY, width: x1 - x0, height: r.height) }
        }
        // The strip's tint and bottom edge leave the active tab out, so it shows the terminal's own background.
        th.tabBarTint.setFill()
        let tint = NSBezierPath(rect: bounds)
        if let d = docked {
            tint.append(dockPath(d, closed: true))
            tint.windingRule = .evenOdd
        }
        tint.fill()
        th.border.setFill()
        let gap = docked.map { d -> (CGFloat, CGFloat) in
            let (l, r) = dockEdges(d)
            return (dockFlush(d) ? l - 0.5 : l - Self.dockFlare, r + Self.dockFlare)
        } ?? (bounds.width, bounds.width)
        NSRect(x: 0, y: bounds.height - 1, width: gap.0, height: 1).fill()
        NSRect(x: gap.1, y: bounds.height - 1, width: max(0, bounds.width - gap.1), height: 1).fill()
        // The right column's strip starts with the line between the columns.
        if !c.isLeading { NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill() }
        if let d = docked {
            th.border.setStroke()
            let edge = dockPath(d, closed: false)
            edge.lineWidth = 1
            edge.stroke()
        }

        // The active tab of a column that isn't focused is drawn as in an inactive window.
        let keyWindow = (window?.isKeyWindow ?? false) && c.isFocused

        // Tabs and chips are clipped to the viewport (they scroll under the arrows).
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: viewport).addClip()

        // Group chips, plus a line in the group's color along the top of the chip and its tabs.
        for (ci, chip) in chips.enumerated() where chip.group !== liftedGroup {
            let g = chip.group
            let r = shownRect(ObjectIdentifier(g)) ?? chip.rect
            // The line runs to the right edge of the group's last tab as drawn (shorter while they fold away).
            let ends = c.tabs.filter { $0.group === g }.compactMap { shownRect(ObjectIdentifier($0)) }.filter { $0.width > 1 }
            if let end = ends.map(\.maxX).max(), end > r.maxX {
                drawGroupLine(g, from: r.minX, to: end, y: groupLineY)
            }
            drawChip(g, in: r, hovered: hoverChip == ci)
            if dropChip === g {
                th.foreground.withAlphaComponent(0.85).setStroke()
                let ring = NSBezierPath(roundedRect: r.insetBy(dx: -2.5, dy: -2.5), xRadius: 8, yRadius: 8)
                ring.lineWidth = 1.5
                ring.stroke()
            }
        }

        selectedTabs.removeAll { !c.tabs.contains($0) }
        for i in c.tabs.indices {
            guard let r = shownRect(ObjectIdentifier(c.tabs[i])) ?? (tabRects[i].isNull ? nil : tabRects[i]), r.width > 2 else { continue }
            if dragging && i == dragIndex { continue }
            if let g = liftedGroup, c.tabs[i].group === g { continue }
            drawTab(c.tabs[i], at: i, in: r, active: i == c.activeIndex, hovered: !dragging && hoverIndex == i,
                    picked: selectedTabs.contains(c.tabs[i]), keyWindow: keyWindow, docked: docked != nil)
        }
        drawSeparators(c, lifted: liftedGroup)
        // Closed tabs shrink and fade out where they were.
        if !ghosts.isEmpty, let ctx = NSGraphicsContext.current?.cgContext {
            let p = animProgress
            for g in ghosts where g.rect.width * (1 - p) > 2 {
                let r = CGRect(x: g.rect.minX - scrollX, y: g.rect.minY, width: g.rect.width * (1 - p), height: g.rect.height)
                ctx.saveGState()
                ctx.setAlpha(1 - p)
                ctx.clip(to: r)
                drawTab(g.tab, at: -1, in: r, active: false, hovered: false, keyWindow: keyWindow)
                ctx.restoreGState()
            }
        }

        NSGraphicsContext.restoreGraphicsState()
        drawScrollArrows()

        // "+" new tab button (slides along after the last tab)
        let pr = shownRect(Self.plusKey) ?? plusRect
        if hoverPlus {
            th.surface.withAlphaComponent(0.7).setFill()
            NSBezierPath(roundedRect: pr, xRadius: 6, yRadius: 6).fill()
        }
        th.foreground.withAlphaComponent(hoverPlus ? 0.9 : 0.55).setStroke()
        let plus = NSBezierPath()
        plus.lineWidth = 1.5
        plus.lineCapStyle = .round
        plus.move(to: NSPoint(x: pr.midX - 5.5, y: pr.midY)); plus.line(to: NSPoint(x: pr.midX + 5.5, y: pr.midY))
        plus.move(to: NSPoint(x: pr.midX, y: pr.midY - 5.5)); plus.line(to: NSPoint(x: pr.midX, y: pr.midY + 5.5))
        plus.stroke()

        if !closeSplitRect.isNull {
            if hoverCloseSplit {
                th.surface.withAlphaComponent(0.7).setFill()
                NSBezierPath(roundedRect: closeSplitRect, xRadius: 6, yRadius: 6).fill()
            }
            let color = th.foreground.withAlphaComponent(hoverCloseSplit ? 0.9 : 0.5)
            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium).applying(.init(paletteColors: [color]))
            if let img = NSImage(systemSymbolName: "rectangle.righthalf.inset.filled.arrow.right", accessibilityDescription: "Close Split")?
                .withSymbolConfiguration(config) ?? NSImage(systemSymbolName: "xmark.square", accessibilityDescription: "Close Split")?.withSymbolConfiguration(config) {
                img.draw(in: NSRect(x: closeSplitRect.midX - img.size.width / 2, y: closeSplitRect.midY - img.size.height / 2,
                                    width: img.size.width, height: img.size.height))
            }
        }

        if showsFlower && hoverFlower {
            th.surface.withAlphaComponent(0.7).setFill()
            NSBezierPath(roundedRect: flowerRect, xRadius: 6, yRadius: 6).fill()
        }
        if showsFlower {
            if QuantumMoon.at(.flower) {
                QuantumMoon.draw(in: flowerRect.insetBy(dx: 3, dy: 3), viewHeight: bounds.height)
            } else {
                Self.flower.draw(in: flowerRect.insetBy(dx: 2, dy: 2))
            }
        }
        // An update waiting (its card dismissed): a "1" on the flower; clicking it opens it in Settings.
        if showsFlower, Updater.shared.needsAttention {
            let badge = CGRect(x: flowerRect.maxX - 9, y: flowerRect.minY - 2, width: 13, height: 13)
            th.accent.setFill()
            NSBezierPath(ovalIn: badge).fill()
            let one = NSAttributedString(string: "1", attributes: [.font: NSFont.systemFont(ofSize: 9, weight: .bold), .foregroundColor: NSColor.white])
            let s = one.size()
            one.draw(at: NSPoint(x: badge.midX - s.width / 2, y: badge.midY - s.height / 2))
        }

        if let g = liftedGroup { drawLiftedGroup(g, in: c, keyWindow: keyWindow) }

        if dragging, let di = dragIndex, c.tabs.indices.contains(di), !tabRects[di].isNull {
            // The dragged tab, lifted and slightly see-through, under the pointer.
            let r = floatingRect(di)
            let ctx = NSGraphicsContext.current?.cgContext
            ctx?.setAlpha(0.8)
            ctx?.beginTransparencyLayer(auxiliaryInfo: nil)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            shadow.shadowBlurRadius = 8
            shadow.shadowOffset = NSSize(width: 0, height: -2)
            shadow.set()
            th.surface.setFill()
            NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7).fill()
            NSGraphicsContext.restoreGraphicsState()
            drawTab(c.tabs[di], at: di, in: r, active: true, hovered: false, keyWindow: keyWindow)
            ctx?.endTransparencyLayer()
            ctx?.setAlpha(1)
            // The landing line goes on top so the floating tab never hides it.
            if let ins = insertBefore, let x = insertionX(ins, dragged: di) {
                let color = c.tabs[di].group?.color.color ?? th.accent
                // Taller than the tabs, so it reads as a marker even where it crosses the floating tab.
                let bar = NSBezierPath(roundedRect: NSRect(x: x - 1.5, y: bounds.midY - 17, width: 3, height: 34), xRadius: 1.5, yRadius: 1.5)
                th.background.withAlphaComponent(0.8).setStroke()
                bar.lineWidth = 2
                bar.stroke()
                color.setFill()
                bar.fill()
            }
        }
    }

    /// `picked`: one of several ⌘/⇧-picked tabs, shaded like a hovered tab (but without its close button).
    /// `docked`: the active tab is drawn in place, opening onto the terminal (the strip already left it clear);
    /// otherwise (dragged, lifted with its group) it's a raised pill.
    private func drawTab(_ tab: TabSession, at i: Int, in r: CGRect, active: Bool, hovered: Bool, picked: Bool = false,
                         keyWindow: Bool, docked: Bool = false) {
        let th = Config.shared.theme
        let groupColor = tab.group?.color.color
        let path = NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7)
        if active && docked {
            if !keyWindow {
                th.background.withAlphaComponent(0.25).setFill()
                dockPath(r, closed: true).fill()
            }
        } else if active {
            th.surface.withAlphaComponent(keyWindow ? 1 : 0.7).setFill()
            path.fill()
            th.border.setStroke()
            path.lineWidth = 1
            path.stroke()
        } else if hovered || picked {
            th.surface.withAlphaComponent(0.55).setFill()
            path.fill()
        }
        if dropTab == i {
            let dc = groupColor ?? th.accent
            dc.withAlphaComponent(0.18).setFill()
            path.fill()
            dc.setStroke()
            path.lineWidth = 1.5
            path.stroke()
        }

        // An agent's mark and status, or a dot for a running (accent) / failed (red) command.
        var textX = r.minX + 12
        if let agent = tab.agent {
            textX += agent.draw(at: textX, midY: r.midY) + 6
        } else if tab.isRunningCommand || tab.lastCommandFailed {
            (tab.isRunningCommand ? th.accent : th.red).setFill()
            NSBezierPath(ovalIn: NSRect(x: textX, y: r.midY - 3, width: 6, height: 6)).fill()
            textX += 12
        }

        let showClose = (hovered || active) && !dragging && !dragGroupMoved && r.width >= 60
        let titleColor = active ? th.foreground : th.foreground.withAlphaComponent(0.55)
        // The title is laid out the same whether the tab is active, hovered or neither (one weight, and no room
        // kept for the close button), so it never moves; the close button fades out whatever runs under it.
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingMiddle
        para.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: titleColor, .paragraphStyle: para]
        let titleRect = NSRect(x: textX, y: r.midY - 8, width: r.maxX - textX - 12, height: 16)
        if !isEditing(tab) {
            let tw = min(titleRect.width, ceil((tab.title as NSString).size(withAttributes: attrs).width))
            let fadeEnd = r.maxX - 26, fadeStart = fadeEnd - 14
            if showClose, titleRect.midX + tw / 2 > fadeStart, let ctx = NSGraphicsContext.current?.cgContext {
                ctx.saveGState()
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                (tab.title as NSString).draw(in: titleRect, withAttributes: attrs)
                ctx.setBlendMode(.destinationOut)
                let clear = CGColor(gray: 0, alpha: 0), solid = CGColor(gray: 0, alpha: 1)
                if let fade = CGGradient(colorsSpace: nil, colors: [clear, solid] as CFArray, locations: [0, 1]) {
                    ctx.saveGState()
                    ctx.clip(to: CGRect(x: fadeStart, y: r.minY, width: fadeEnd - fadeStart, height: r.height))
                    ctx.drawLinearGradient(fade, start: CGPoint(x: fadeStart, y: 0), end: CGPoint(x: fadeEnd, y: 0), options: [])
                    ctx.restoreGState()
                }
                ctx.setFillColor(solid)
                ctx.fill(CGRect(x: fadeEnd, y: r.minY, width: r.maxX - fadeEnd, height: r.height))
                ctx.endTransparencyLayer()
                ctx.restoreGState()
            } else {
                (tab.title as NSString).draw(in: titleRect, withAttributes: attrs)
            }
        }

        if showClose {
            // From `r`, not closeRects, so it stays on the tab wherever the tab is drawn.
            let cr = CGRect(x: r.maxX - 24, y: r.midY - 9, width: 18, height: 18)
            if hoverClose && hovered {
                th.foreground.withAlphaComponent(0.12).setFill()
                NSBezierPath(roundedRect: cr, xRadius: 4, yRadius: 4).fill()
            }
            th.foreground.withAlphaComponent(0.6).setStroke()
            let x = NSBezierPath()
            x.lineWidth = 1.3
            x.lineCapStyle = .round
            let inset: CGFloat = 5.5
            x.move(to: NSPoint(x: cr.minX + inset, y: cr.minY + inset)); x.line(to: NSPoint(x: cr.maxX - inset, y: cr.maxY - inset))
            x.move(to: NSPoint(x: cr.maxX - inset, y: cr.minY + inset)); x.line(to: NSPoint(x: cr.minX + inset, y: cr.maxY - inset))
            x.stroke()
        }
    }

    /// ‹ and ›, when the tabs scroll: bright when there's more that way, faint at the end.
    private func drawScrollArrows() {
        let th = Config.shared.theme
        for (dir, r) in [(-1, leftArrowRect), (1, rightArrowRect)] where !r.isNull {
            let more = dir < 0 ? scrollX > 0.5 : scrollX < maxScrollX - 0.5
            if more && hoverArrow == dir {
                th.surface.withAlphaComponent(0.7).setFill()
                NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
            }
            let color = th.foreground.withAlphaComponent(more ? (hoverArrow == dir ? 0.95 : 0.7) : 0.18)
            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold).applying(.init(paletteColors: [color]))
            if let img = NSImage(systemSymbolName: dir < 0 ? "chevron.left" : "chevron.right", accessibilityDescription: nil)?
                .withSymbolConfiguration(config) {
                img.draw(in: NSRect(x: r.midX - img.size.width / 2, y: r.midY - img.size.height / 2, width: img.size.width, height: img.size.height))
            }
        }
    }

    /// Edge-style hairlines between neighboring tabs (and before the first and after the last), left out beside the active, hovered
    /// or picked tab, whose own background already sets it apart.
    private func drawSeparators(_ c: TabColumn, lifted: TabGroup?) {
        let shown: [(i: Int, r: CGRect)] = c.tabs.indices.compactMap { i in
            guard !(dragging && i == dragIndex), lifted == nil || c.tabs[i].group !== lifted,
                  let r = shownRect(ObjectIdentifier(c.tabs[i])) ?? (tabRects[i].isNull ? nil : tabRects[i]), r.width > 20 else { return nil }
            return (i, r)
        }
        func quiet(_ i: Int) -> Bool {
            i == c.activeIndex || (!dragging && hoverIndex == i) || selectedTabs.contains(c.tabs[i]) || dropTab == i
        }
        Config.shared.theme.foreground.withAlphaComponent(0.18).setFill()
        // One before the first tab, too, unless it starts on the sidebar's border line.
        if let first = shown.first, !quiet(first.i), sidebarEdge.map({ abs(first.r.minX - $0) >= 0.5 }) ?? true {
            // On the tab's own left edge: just outside it would be clipped off the start of the strip.
            NSRect(x: first.r.minX.rounded(), y: first.r.midY - 8, width: 1, height: 16).fill()
        }
        for (k, t) in shown.enumerated() {
            let next = k + 1 < shown.count ? shown[k + 1] : nil
            if let n = next, n.r.minX - t.r.maxX > 12 { continue }  // a group chip sits between them
            if quiet(t.i) || next.map({ quiet($0.i) }) == true { continue }
            let x = next.map { ((t.r.maxX + $0.r.minX) / 2).rounded() } ?? t.r.maxX + 2
            NSRect(x: x - 0.5, y: t.r.midY - 8, width: 1, height: 16).fill()
        }
    }

    /// Just above the tabs, so a group stays within the same height as ungrouped tabs.
    private var groupLineY: CGFloat { (bounds.height - 28) / 2 - 4 }

    /// How far the active tab's foot curves out on each side.
    private static let dockFlare: CGFloat = 5

    /// Where the file sidebar's border line meets the strip, when the tabs start on it (see computeRects).
    private var sidebarEdge: CGFloat?

    /// Whether the active tab's left side is the sidebar's border carried on up: it runs straight down,
    /// without curving out.
    private func dockFlush(_ r: CGRect) -> Bool {
        sidebarEdge.map { abs(r.minX - $0) < 0.5 } ?? false
    }

    /// The active tab's left and right edges, on half points so its 1pt outline covers whole pixels instead of
    /// smearing across two.
    private func dockEdges(_ r: CGRect) -> (CGFloat, CGFloat) {
        (r.minX.rounded() + 0.5, r.maxX.rounded() - 0.5)
    }

    /// The active tab's outline: rounded on top, running down to the strip's bottom border, where its sides
    /// curve out to end exactly on the border's centre line. `closed` also takes in the border underneath (for
    /// filling and for cutting the tint); open, it's the edge to stroke.
    private func dockPath(_ r: CGRect, closed: Bool) -> NSBezierPath {
        let (left, right) = dockEdges(r)
        let line = bounds.height - 0.5, top = r.minY.rounded() + 0.5, radius: CGFloat = 8, f = Self.dockFlare
        let flush = dockFlush(r)
        let p = NSBezierPath()
        func quad(to end: NSPoint, via c: NSPoint) {
            let start = p.currentPoint
            p.curve(to: end, controlPoint1: NSPoint(x: start.x + (c.x - start.x) * 2 / 3, y: start.y + (c.y - start.y) * 2 / 3),
                    controlPoint2: NSPoint(x: end.x + (c.x - end.x) * 2 / 3, y: end.y + (c.y - end.y) * 2 / 3))
        }
        if flush {
            p.move(to: NSPoint(x: left, y: bounds.height))
        } else {
            p.move(to: NSPoint(x: left - f, y: line))
            quad(to: NSPoint(x: left, y: line - f), via: NSPoint(x: left, y: line))
        }
        p.line(to: NSPoint(x: left, y: top + radius))
        quad(to: NSPoint(x: left + radius, y: top), via: NSPoint(x: left, y: top))
        p.line(to: NSPoint(x: right - radius, y: top))
        quad(to: NSPoint(x: right, y: top + radius), via: NSPoint(x: right, y: top))
        p.line(to: NSPoint(x: right, y: line - f))
        quad(to: NSPoint(x: right + f, y: line), via: NSPoint(x: right, y: line))
        if closed {
            p.line(to: NSPoint(x: right + f, y: bounds.height))
            p.line(to: NSPoint(x: flush ? left : left - f, y: bounds.height))
            p.close()
        }
        return p
    }

    private func drawGroupLine(_ g: TabGroup, from x0: CGFloat, to x1: CGFloat, y: CGFloat) {
        g.color.color.withAlphaComponent(0.85).setFill()
        NSBezierPath(roundedRect: NSRect(x: x0, y: y, width: x1 - x0, height: 2), xRadius: 1, yRadius: 1).fill()
    }

    private func drawChip(_ g: TabGroup, in r: CGRect, hovered: Bool) {
        let color = g.color.color
        let label = chipLabel(g)
        var naming = false
        if case .group(let eg) = editing, eg === g { naming = true }
        if label.isEmpty && !naming {
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: r.midX - 6, y: r.midY - 6, width: 12, height: 12)).fill()
            if hovered {
                Config.shared.theme.foreground.withAlphaComponent(0.12).setFill()
                NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
            }
            return
        }
        color.withAlphaComponent(hovered ? 1 : 0.88).setFill()
        NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        para.alignment = .center
        let text: NSColor = color.luminance > 0.6 ? NSColor(white: 0.1, alpha: 1) : .white
        (label as NSString).draw(in: NSRect(x: r.minX + 6, y: r.midY - 7.5, width: r.width - 12, height: 15),
                                 withAttributes: [.font: Self.chipFont, .foregroundColor: text, .paragraphStyle: para])
    }

    /// The whole group being dragged by its chip, lifted and slightly see-through, shifted with the pointer,
    /// plus the line where it will land.
    private func drawLiftedGroup(_ g: TabGroup, in c: TabColumn, keyWindow: Bool) {
        let th = Config.shared.theme
        guard let chip = chips.first(where: { $0.group === g })?.rect else { return }
        let members = c.tabs.indices.filter { c.tabs[$0].group === g && !tabRects[$0].isNull }
        let right = members.last.map { tabRects[$0].maxX } ?? chip.maxX
        let lo = viewport.minX
        let hi = max(lo, min(plusRect.maxX, viewport.maxX) - (right - chip.minX))
        let dx = min(max(chip.minX + dragX - dragStartX, lo), hi) - chip.minX
        let ctx = NSGraphicsContext.current?.cgContext
        ctx?.setAlpha(0.96)
        ctx?.beginTransparencyLayer(auxiliaryInfo: nil)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 8
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.set()
        // Opaque backing so nothing underneath shows through the lifted tabs.
        th.background.withAlphaComponent(1).blended(withFraction: 0.5, of: th.surface.withAlphaComponent(1))?.setFill()
        NSBezierPath(roundedRect: NSRect(x: chip.minX + dx - 3, y: 4, width: right - chip.minX + 6, height: bounds.height - 8), xRadius: 8, yRadius: 8).fill()
        NSGraphicsContext.restoreGraphicsState()
        drawChip(g, in: chip.offsetBy(dx: dx, dy: 0), hovered: true)
        for i in members {
            drawTab(c.tabs[i], at: i, in: tabRects[i].offsetBy(dx: dx, dy: 0), active: i == c.activeIndex, hovered: false,
                    picked: true, keyWindow: keyWindow)
        }
        if let last = members.last {
            drawGroupLine(g, from: chip.minX + dx, to: right + dx, y: tabRects[last].minY - 4)
        }
        ctx?.endTransparencyLayer()
        ctx?.setAlpha(1)
        if let ins = groupInsertBefore, let x = groupInsertionX(ins, dragging: g) {
            let bar = NSBezierPath(roundedRect: NSRect(x: x - 1.5, y: bounds.midY - 17, width: 3, height: 34), xRadius: 1.5, yRadius: 1.5)
            th.background.withAlphaComponent(0.8).setStroke()
            bar.lineWidth = 2
            bar.stroke()
            g.color.color.setFill()
            bar.fill()
        }
    }

    /// Places a dragged group can land: in front of each loose tab or other group, as (first tab index, its span).
    private func groupLandingSpots(excluding g: TabGroup) -> [(start: Int, rect: CGRect)] {
        guard let c = controller else { return [] }
        var out: [(Int, CGRect)] = []
        var i = 0
        while i < c.tabs.count {
            let t = c.tabs[i]
            if t.group === g { i += 1; continue }
            if let h = t.group, let chip = chips.first(where: { $0.group === h })?.rect {
                var r = chip
                var j = i
                while j < c.tabs.count, c.tabs[j].group === h {
                    if !tabRects[j].isNull { r = r.union(tabRects[j]) }
                    j += 1
                }
                out.append((i, r))
                i = j
            } else {
                out.append((i, tabRects[i]))
                i += 1
            }
        }
        return out
    }

    /// x of the landing line for a group dropped in front of `ins`; nil when it would stay where it is.
    private func groupInsertionX(_ ins: Int, dragging g: TabGroup) -> CGFloat? {
        guard let c = controller, let lastG = c.tabs.lastIndex(where: { $0.group === g }) else { return nil }
        let after = c.tabs.indices.first { $0 > lastG } ?? c.tabs.count
        if ins == after { return nil }
        let spots = groupLandingSpots(excluding: g)
        if let s = spots.first(where: { $0.start == ins }) { return s.rect.minX - 3 }
        return spots.last.map { $0.rect.maxX + 3 }
    }

    /// Where the dragged tab is drawn: under the pointer, kept within the strip.
    private func floatingRect(_ di: Int) -> CGRect {
        let r = tabRects[di]
        let lo = viewport.minX
        let hi = max(lo, min(plusRect.maxX, viewport.maxX) - r.width)
        return CGRect(x: min(max(dragX - grabOffset, lo), hi), y: r.minY, width: r.width, height: r.height)
    }

    /// The group a tab would end up in if dropped in front of `ins` (mirrors `moveTab`'s rule).
    private func groupAfterDrop(_ di: Int, before ins: Int) -> TabGroup? {
        guard let c = controller else { return nil }
        let others = c.tabs.indices.filter { $0 != di }
        let left = others.last { $0 < ins }.map { c.tabs[$0].group } ?? nil
        let right = ins < c.tabs.count ? c.tabs[ins].group : nil
        let own = c.tabs[di].group
        if let l = left, l === right { return l }
        if let g = own, g === left || g === right { return g }
        return nil
    }

    /// x of the landing line for a drop in front of `ins`; nil when the tab would stay where it is.
    private func insertionX(_ ins: Int, dragged di: Int) -> CGFloat? {
        guard let c = controller else { return nil }
        let to = ins > di ? ins - 1 : ins
        if to == di && groupAfterDrop(di, before: ins) === c.tabs[di].group { return nil }
        if ins >= c.tabs.count {
            guard let last = tabRects.indices.last(where: { $0 != di && !tabRects[$0].isNull }) else { return nil }
            return tabRects[last].maxX + 2
        }
        let r = tabRects[ins]
        // In front of a group's first tab but not joining it: the line goes before the group's chip.
        if let g = c.tabs[ins].group, groupAfterDrop(di, before: ins) !== g,
           let chip = chips.first(where: { $0.group === g })?.rect, c.tabs.firstIndex(where: { $0.group === g }) == ins {
            return chip.minX - 3
        }
        return r.minX - 2
    }

    // MARK: Inline rename

    func beginEditing(tab: TabSession) {
        beginEditing(.tab(tab), text: tab.customTitle ?? tab.title, placeholder: tab.focusedPane.displayTitle)
    }

    func beginEditing(group: TabGroup) {
        group.collapsed = false
        beginEditing(.group(group), text: group.name, placeholder: nextProjectName())
    }

    private func beginEditing(_ target: EditTarget, text: String, placeholder: String) {
        endEditing(commit: true)
        let th = Config.shared.theme
        let f = NSTextField(string: text)
        f.cell = CenteredTextFieldCell(textCell: text)
        // A fresh cell is neither editable nor selectable, so without these the field refuses focus.
        f.isEditable = true
        f.isSelectable = true
        f.placeholderString = placeholder
        f.isBordered = false
        // The background is on the layer (the field editor inside draws none).
        f.drawsBackground = false
        f.textColor = th.foreground
        f.font = .systemFont(ofSize: 12, weight: .medium)
        f.alignment = .center
        f.focusRingType = .none
        f.usesSingleLineMode = true
        f.cell?.isScrollable = true
        f.cell?.wraps = false
        f.wantsLayer = true
        f.layer?.cornerRadius = 5
        f.layer?.borderWidth = 1
        f.layer?.backgroundColor = th.background.cgColor
        f.layer?.borderColor = th.accent.withAlphaComponent(0.8).cgColor
        if case .group(let g) = target {
            // A group's name is typed right on its chip: the chip's color, with text that reads on it.
            let color = g.color.color
            let ink: NSColor = color.luminance > 0.6 ? NSColor(white: 0.1, alpha: 1) : .white
            f.layer?.backgroundColor = color.cgColor
            f.layer?.borderColor = color.blended(withFraction: 0.25, of: .black)?.cgColor ?? color.cgColor
            f.textColor = ink
            f.font = Self.chipFont
            // Typed from the left, over a faint suggested name that typing replaces.
            f.alignment = .left
            (f.cell as? CenteredTextFieldCell)?.horizontalInset = 8
            f.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
                .foregroundColor: ink.withAlphaComponent(0.4), .font: Self.chipFont])
        }
        f.delegate = self
        editing = target
        editor = f
        addSubview(f)
        needsLayout = true
        layoutSubtreeIfNeeded()
        computeRects()
        window?.makeFirstResponder(f)
        f.currentEditor()?.selectAll(nil)
        needsDisplay = true
    }

    private func isEditing(_ tab: TabSession) -> Bool {
        if case .tab(let t) = editing { return t === tab }
        return false
    }

    private func positionEditor() {
        guard let f = editor, let target = editing, let c = controller else { return }
        switch target {
        case .tab(let t):
            guard let i = c.tabs.firstIndex(of: t), !tabRects[i].isNull else { return endEditing(commit: false) }
            f.frame = tabRects[i].insetBy(dx: 10, dy: 5)
        case .group(let g):
            guard let r = chips.first(where: { $0.group === g })?.rect else { return endEditing(commit: false) }
            f.frame = r.insetBy(dx: 0, dy: -1)
        }
    }

    /// "Project 1", "Project 2", …: the first number no group in the window uses yet.
    private func nextProjectName() -> String {
        let names = Set((controller?.owner?.columns ?? []).flatMap(\.groups).map(\.name))
        var n = 1
        while names.contains("Project \(n)") { n += 1 }
        return "Project \(n)"
    }

    private func endEditing(commit: Bool) {
        guard let f = editor, let target = editing else { return }
        editing = nil
        editor = nil
        if commit {
            let text = f.stringValue
            switch target {
            case .tab(let t): controller?.renameTab(t, to: text)
            case .group(let g):
                // Return on a new group's empty field keeps the suggested "Project N"; clearing a name leaves it unnamed.
                let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
                g.name = name.isEmpty && g.name.isEmpty ? f.placeholderAttributedString?.string ?? "" : name
            }
        }
        f.removeFromSuperview()
        controller?.activeTab?.focus()
        needsLayout = true
        needsDisplay = true
    }

    func controlTextDidChange(_ obj: Notification) {
        if case .group = editing { needsLayout = true; needsDisplay = true }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        endEditing(commit: true)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        guard sel == #selector(NSResponder.cancelOperation(_:)) else { return false }
        endEditing(commit: false)
        return true
    }

    // MARK: Context menus

    private func swatch(_ color: TabGroupColor) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { r in
            color.color.setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }

    private func menu(forTab tab: TabSession) -> NSMenu {
        let m = NSMenu()
        guard let c = controller else { return m }
        m.addItem(ActionMenuItem("Rename Tab…") { [weak self] in self?.beginEditing(tab: tab) })
        if tab.customTitle != nil { m.addItem(ActionMenuItem("Reset Tab Name") { [weak c] in c?.renameTab(tab, to: "") }) }
        m.addItem(.separator())
        m.addItem(ActionMenuItem("Add Tab to New Group") { [weak c] in c?.addToNewGroup(tab) })
        let others = c.groups.filter { $0 !== tab.group }
        if !others.isEmpty {
            let sub = NSMenu()
            for g in others {
                let item = ActionMenuItem(g.displayName) { [weak c] in c?.addTab(tab, to: g) }
                item.image = swatch(g.color)
                sub.addItem(item)
            }
            let item = NSMenuItem(title: "Add Tab to Group", action: nil, keyEquivalent: "")
            item.submenu = sub
            m.addItem(item)
        }
        if tab.group != nil { m.addItem(ActionMenuItem("Remove from Group") { [weak c] in c?.removeFromGroup(tab) }) }
        m.addItem(.separator())
        if let w = c.owner, w.columns.count > 1 || c.tabs.count > 1 {
            m.addItem(ActionMenuItem(w.columns.count > 1 ? "Move to Other Split" : "Move to New Split") { [weak w, weak c] in
                if let c { w?.move(tab, from: c) }
            })
            m.addItem(.separator())
        }
        m.addItem(ActionMenuItem("Close Tab") { [weak c] in c?.closeTabs([tab]) })
        if c.tabs.count > 1 {
            m.addItem(ActionMenuItem("Close Other Tabs") { [weak c] in c?.closeTabs(c?.tabs.filter { $0 !== tab } ?? []) })
        }
        if let i = c.tabs.firstIndex(of: tab), i < c.tabs.count - 1 {
            m.addItem(ActionMenuItem("Close Tabs to the Right") { [weak c] in
                guard let c, let i = c.tabs.firstIndex(of: tab) else { return }
                c.closeTabs(Array(c.tabs[(i + 1)...]))
            })
        }
        return m
    }

    private func menu(forGroup g: TabGroup) -> NSMenu {
        let m = NSMenu()
        guard let c = controller else { return m }
        m.addItem(ActionMenuItem("Rename Group…") { [weak self] in self?.beginEditing(group: g) })
        m.addItem(.separator())
        for color in TabGroupColor.allCases {
            let item = ActionMenuItem(color.title, checked: g.color == color) { [weak self] in
                g.color = color
                self?.needsDisplay = true
            }
            item.image = swatch(color)
            m.addItem(item)
        }
        m.addItem(.separator())
        m.addItem(ActionMenuItem("New Tab in Group") { [weak c] in c?.newTab(in: g) })
        m.addItem(ActionMenuItem(g.collapsed ? "Expand Group" : "Collapse Group") { [weak c] in c?.setCollapsed(g, !g.collapsed) })
        m.addItem(ActionMenuItem("Ungroup") { [weak c] in c?.ungroup(g) })
        m.addItem(ActionMenuItem("Close Group") { [weak c] in c?.closeTabs(c?.tabs(in: g) ?? []) })
        return m
    }

    /// Right-clicking one of several ⌘/⇧-picked tabs: actions on all of them.
    private func menu(forTabs list: [TabSession]) -> NSMenu {
        let m = NSMenu()
        guard let c = controller else { return m }
        let n = list.count
        m.addItem(ActionMenuItem("Add \(n) Tabs to New Group") { [weak self, weak c] in
            c?.addToNewGroup(list)
            self?.clearTabSelection()
        })
        if !c.groups.isEmpty {
            let sub = NSMenu()
            for g in c.groups {
                let item = ActionMenuItem(g.displayName) { [weak self, weak c] in
                    c?.addTabs(list, to: g)
                    self?.clearTabSelection()
                }
                item.image = swatch(g.color)
                sub.addItem(item)
            }
            let item = NSMenuItem(title: "Add \(n) Tabs to Group", action: nil, keyEquivalent: "")
            item.submenu = sub
            m.addItem(item)
        }
        if list.contains(where: { $0.group != nil }) {
            m.addItem(ActionMenuItem("Remove from Group") { [weak self, weak c] in
                list.forEach { c?.removeFromGroup($0) }
                self?.clearTabSelection()
            })
        }
        m.addItem(.separator())
        m.addItem(ActionMenuItem("Close \(n) Tabs") { [weak self, weak c] in
            c?.closeTabs(list)
            self?.clearTabSelection()
        })
        return m
    }

    func clearTabSelection() {
        guard !selectedTabs.isEmpty else { return }
        selectedTabs = []
        needsDisplay = true
    }

    private func showContextMenu(_ e: NSEvent) {
        guard let c = controller else { return }
        let p = convert(e.locationInWindow, from: nil)
        let menu: NSMenu
        if let ci = chipIndex(at: p) {
            menu = self.menu(forGroup: chips[ci].group)
        } else if let i = tabIndex(at: p) {
            if selectedTabs.count > 1 && selectedTabs.contains(c.tabs[i]) {
                menu = self.menu(forTabs: c.tabs.filter { selectedTabs.contains($0) })
            } else {
                clearTabSelection()
                menu = self.menu(forTab: c.tabs[i])
            }
        } else {
            // Empty space on the strip.
            menu = NSMenu()
            menu.addItem(ActionMenuItem("New Tab") { [weak c] in c?.newTab() })
            if let w = c.owner, w.columns.count > 1 {
                menu.addItem(.separator())
                menu.addItem(ActionMenuItem("Close Split (Tabs Move to the Left)") { [weak w] in w?.closeSplit(nil) })
                menu.addItem(ActionMenuItem("Close Split and Its Tabs") { [weak w] in w?.closeSplitAndTabs() })
            }
        }
        NSMenu.popUpContextMenu(menu, with: e, for: self)
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === self }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate],
                                       owner: self))
    }

    /// A pointing hand over the flower (it opens Settings), the arrow elsewhere: without this the strip keeps
    /// whatever cursor the view below set, such as the terminal's I-beam.
    private func updateCursor(at p: NSPoint) {
        if let ed = editor, ed.frame.contains(p) { return }  // renaming a tab: the field's I-beam
        (flowerRect.contains(p) ? NSCursor.pointingHand : NSCursor.arrow).set()
    }

    override func cursorUpdate(with e: NSEvent) { updateCursor(at: convert(e.locationInWindow, from: nil)) }

    /// The strip lives under the titlebar/toolbar, which the window server treats as a drag region, so a
    /// press there would move the window before we ever see mouseDragged. Make the window immovable while
    /// the pointer is over something interactive; empty space keeps native window dragging.
    private func updateWindowMovable(at p: NSPoint?) {
        guard let w = window else { return }
        let overControl = p.map { p in
            tabIndex(at: p) != nil || chipIndex(at: p) != nil || plusRect.contains(p) || flowerRect.contains(p) || closeSplitRect.contains(p)
                || leftArrowRect.contains(p) || rightArrowRect.contains(p)
        } ?? false
        if w.isMovable == overControl { w.isMovable = !overControl }
    }

    override func mouseMoved(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        updateWindowMovable(at: p)
        updateCursor(at: p)
        let idx = tabIndex(at: p)
        let hc = idx.map { closeRects[$0].contains(p) } ?? false
        let hp = plusRect.contains(p)
        let hch = chipIndex(at: p)
        let ha = leftArrowRect.contains(p) ? -1 : rightArrowRect.contains(p) ? 1 : nil
        if ha != hoverArrow {
            hoverArrow = ha
            needsDisplay = true
        }
        let hf = flowerRect.contains(p)
        let hcs = closeSplitRect.contains(p)
        if hcs != hoverCloseSplit {
            hoverCloseSplit = hcs
            toolTip = hcs ? "Close Split (⌃⌘W): its tabs move to the left side" : nil
            needsDisplay = true
        }
        if hf != hoverFlower {
            hoverFlower = hf
            toolTip = hf ? "Solanum Settings" : nil
            needsDisplay = true
        }
        if idx != hoverIndex, !hf {
            toolTip = idx.flatMap { i in controller.flatMap { $0.tabs.indices.contains(i) ? $0.tabs[i].agent?.summary : nil } }
        }
        if idx != hoverIndex || hc != hoverClose || hp != hoverPlus || hch != hoverChip {
            hoverIndex = idx
            hoverClose = hc
            hoverPlus = hp
            hoverChip = hch
            needsDisplay = true
        }
    }

    override func mouseExited(with e: NSEvent) {
        updateWindowMovable(at: nil)
        hoverIndex = nil
        hoverClose = false
        hoverPlus = false
        hoverChip = nil
        hoverFlower = false
        hoverArrow = nil
        hoverCloseSplit = false
        needsDisplay = true
    }

    override func mouseDown(with e: NSEvent) {
        guard let c = controller else { return }
        if e.modifierFlags.contains(.control) { return showContextMenu(e) }
        let p = convert(e.locationInWindow, from: nil)
        if plusRect.contains(p) { c.newTab(); return }
        if closeSplitRect.contains(p) { c.owner?.closeSplit(nil); return }
        if flowerRect.contains(p) { SettingsWindowController.shared.present(Updater.shared.needsAttention ? .system : nil); return }
        if leftArrowRect.contains(p) { slideTabs(by: -viewport.width * 0.75); return }
        if rightArrowRect.contains(p) { slideTabs(by: viewport.width * 0.75); return }
        if let g = chipIndex(at: p).map({ chips[$0].group }) {
            // A click toggles collapse on mouse-up unless the chip was dragged; renaming is in the chip's right-click menu.
            clearTabSelection()
            dragGroup = g
            dragGroupMoved = false
            dragStartX = p.x
            dragX = p.x
            return
        }
        if let i = tabIndex(at: p) {
            if closeRects[i].contains(p) && (hoverIndex == i || i == c.activeIndex) {
                c.closeTab(at: i)
                return
            }
            // ⌘-click adds or removes a tab, ⇧-click picks the run from the current tab; right-click acts on them all.
            let mods = e.modifierFlags
            if mods.contains(.command) || mods.contains(.shift) {
                let tab = c.tabs[i]
                if mods.contains(.shift) {
                    let a = min(c.activeIndex, i), b = max(c.activeIndex, i)
                    selectedTabs = (a...b).filter { !tabRects[$0].isNull }.map { c.tabs[$0] }
                } else {
                    if selectedTabs.isEmpty, let active = c.activeTab { selectedTabs = [active] }
                    if let k = selectedTabs.firstIndex(of: tab) { selectedTabs.remove(at: k) } else { selectedTabs.append(tab) }
                }
                needsDisplay = true
                return
            }
            clearTabSelection()
            if e.clickCount == 2 { return beginEditing(tab: c.tabs[i]) }
            // Selected on release, and only if it wasn't dragged: dragging a tab doesn't switch to it.
            dragIndex = i
            dragStartX = p.x
            dragStartY = p.y
            grabOffset = p.x - tabRects[i].minX
            return
        }
        if e.clickCount == 2 {
            window?.performZoom(nil)
        } else {
            updateWindowMovable(at: p)
            window?.performDrag(with: e)
        }
    }

    override func rightMouseDown(with e: NSEvent) {
        showContextMenu(e)
    }

    override func mouseDragged(with e: NSEvent) {
        guard let c = controller else { return }
        if let g = dragGroup {
            let p = convert(e.locationInWindow, from: nil)
            if dragGroupMoved { autoScrollWhileDragging(p) }
            return dragChip(g, to: p)
        }
        guard let di = dragIndex else { return }
        let p = convert(e.locationInWindow, from: nil)
        guard dragging || hypot(p.x - dragStartX, p.y - dragStartY) > 6 else { return }
        if dragging { autoScrollWhileDragging(p) }
        if !dragging { NSCursor.closedHand.push() }
        dragging = true
        // Off the strip, over the terminals or the other column: the window shows where a drop would split.
        if !bounds.contains(p), c.tabs.indices.contains(di), let w = c.owner, w.tabDragOver(c.tabs[di], from: c, at: e.locationInWindow) {
            dragX = p.x
            dropTab = nil
            dropChip = nil
            insertBefore = nil
            needsDisplay = true
            return
        }
        c.owner?.clearTabDrop()
        dragTab(di, to: p, in: c)
    }

    /// The tab follows the pointer and nothing moves until release. Over the middle of another tab (outside
    /// the dragged tab's group) or a group's chip, the target is highlighted and releasing groups the tab;
    /// anywhere else a line shows where it will land, in front of the first tab whose middle is past the pointer.
    private func dragTab(_ di: Int, to p: NSPoint, in c: TabColumn) {
        dragX = p.x
        var overTab: Int?, overChip: TabGroup?, insert: Int?
        let visible = c.tabs.indices.filter { $0 != di && !tabRects[$0].isNull }
        if let t = visible.first(where: { p.x >= tabRects[$0].minX && p.x <= tabRects[$0].maxX }) {
            let r = tabRects[t], edge = r.width / 4
            if p.x > r.minX + edge && p.x < r.maxX - edge, c.tabs[t].group == nil || c.tabs[t].group !== c.tabs[di].group {
                overTab = t
            }
        } else if let g = chips.first(where: { p.x >= $0.rect.minX && p.x <= $0.rect.maxX })?.group, g !== c.tabs[di].group {
            overChip = g
        }
        if overTab == nil && overChip == nil {
            insert = visible.first { tabRects[$0].midX > p.x } ?? c.tabs.count
        }
        dropTab = overTab
        dropChip = overChip
        insertBefore = insert
        needsDisplay = true
    }

    /// Dragging a chip lifts its whole group, which follows the pointer while nothing else moves (as with a
    /// dragged tab). A line shows where it lands: in front of the first loose tab or other group whose middle is
    /// past the pointer. It never lands inside another group.
    private func dragChip(_ g: TabGroup, to p: NSPoint) {
        guard let c = controller, dragGroupMoved || abs(p.x - dragStartX) > 6 else { return }
        if !dragGroupMoved { NSCursor.closedHand.push() }
        dragGroupMoved = true
        dragX = p.x
        groupInsertBefore = groupLandingSpots(excluding: g).first { $0.rect.midX > p.x }?.start ?? c.tabs.count
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        if let g = dragGroup, !dragGroupMoved { controller?.setCollapsed(g, !g.collapsed) }
        if let g = dragGroup, dragGroupMoved {
            NSCursor.pop()
            if let ins = groupInsertBefore, groupInsertionX(ins, dragging: g) != nil { controller?.moveGroup(g, before: ins) }
        }
        if let c = controller, let di = dragIndex, c.tabs.indices.contains(di) {
            if !dragging {
                c.select(index: di)
            } else if let w = c.owner, w.hasPendingTabDrop {
                w.performTabDrop()
            } else if let t = dropTab, c.tabs.indices.contains(t) {
                c.groupTab(c.tabs[di], with: c.tabs[t])
            } else if let g = dropChip {
                c.addTab(c.tabs[di], to: g)
            } else if let ins = insertBefore, insertionX(ins, dragged: di) != nil {
                c.moveTab(from: di, to: ins > di ? ins - 1 : ins)
            }
        }
        controller?.owner?.clearTabDrop()
        if dragging { NSCursor.pop() }
        needsDisplay = true
        dragging = false
        insertBefore = nil
        dropTab = nil
        dropChip = nil
        dragGroup = nil
        dragGroupMoved = false
        groupInsertBefore = nil
        dragIndex = nil
        // Tabs may have moved or closed under the pointer without a mouseMoved.
        updateWindowMovable(at: convert(e.locationInWindow, from: nil))
    }

    override func otherMouseUp(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if let i = tabIndex(at: p) { controller?.closeTab(at: i) }
    }
}
