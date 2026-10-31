import AppKit

/// One column of tabs. A window has one, or two side by side (⌘D, like VS Code's editor groups): each with
/// its own tabs, active tab, groups, tab strip in the title bar, and the area showing its active tab. All tab
/// and group operations live here; the window controller lays the columns out and tracks which is focused.
final class TabColumn: NSObject, TabOwner {
    private(set) var tabs: [TabSession] = []
    private(set) var activeIndex = 0
    let tabBar = TabBarView()
    /// Shows the active tab.
    let content = NSView()
    weak var owner: TerminalWindowController?

    var activeTab: TabSession? { tabs.indices.contains(activeIndex) ? tabs[activeIndex] : nil }
    var isFocused: Bool { owner?.focused === self }
    /// The first column's strip starts after the window's traffic lights.
    var isLeading: Bool { owner?.columns.first === self }
    var trafficLightInset: CGFloat { isLeading ? owner?.trafficLightInset ?? 12 : 10 }
    var window: NSWindow? { owner?.window }

    init(owner: TerminalWindowController) {
        self.owner = owner
        super.init()
        tabBar.controller = self
    }

    // MARK: Tabs

    /// Opens a tab at the end of the strip, outside any group, as Edge does (⌘T and the + button).
    @discardableResult
    func addTab(cwd: String?) -> TabSession {
        insertTab(cwd: cwd, at: tabs.count, group: nil)
    }

    /// The focused terminal's folder, when it's on this Mac (a new shell can't start in an ssh host's folder).
    var currentLocalFolder: String? {
        guard let pane = activeTab?.focusedPane, pane.remote == nil else { return nil }
        return pane.currentDirectory
    }

    /// ⌘T and the + button: a tab in the current terminal's folder, or at home (Settings › Preferences).
    @discardableResult
    func newTab() -> TabSession {
        addTab(cwd: Config.shared.newTabFolder == "home" ? nil : currentLocalFolder)
    }

    /// `openFolders`: the sidebar folders it starts with open (none: everything closed).
    @discardableResult
    func insertTab(cwd: String?, at index: Int, group: TabGroup?, openFolders: [String: Set<String>] = [:]) -> TabSession {
        let tab = TabSession(cwd: cwd)
        tab.owner = self
        tab.group = group
        tab.openFolders = openFolders
        tabs.insert(tab, at: index)
        select(index: index)
        return tab
    }

    func select(index: Int) {
        guard tabs.indices.contains(index) else { return }
        tabs[index].group?.collapsed = false
        content.subviews.forEach { $0.removeFromSuperview() }
        activeIndex = index
        let tab = tabs[index]
        tab.rang = false
        tab.view.frame = content.bounds
        tab.view.autoresizingMask = [.width, .height]
        content.addSubview(tab.view)
        tab.view.needsLayout = true
        tab.focus()
        DispatchQueue.main.async { tab.focus() }
        updateTitle()
        tabBar.needsLayout = true
        tabBar.needsDisplay = true
    }

    func closeTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        closeTabs([tabs[index]])
    }

    /// Closes tabs, asking first if any of them still has a running process.
    func closeTabs(_ list: [TabSession]) {
        guard !list.isEmpty else { return }
        let close = { [weak self] in
            for t in list { t.terminateAll(); self?.tabDidClose(t) }
        }
        let unsaved = list.contains { $0.hasUnsavedFile }
        guard unsaved || list.contains(where: { $0.hasRunningJobs }) && Config.shared.confirmQuit, let w = owner?.window else { return close() }
        let alert = NSAlert()
        alert.messageText = list.count == 1 ? "Close this tab?" : "Close \(list.count) tabs?"
        alert.informativeText = unsaved ? "A file open in the editor has unsaved changes, which will be lost."
                              : list.count == 1 ? "A process is still running in this tab and will be terminated."
                                                : "Processes are still running in these tabs and will be terminated."
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: w) { resp in
            if resp == .alertFirstButtonReturn { close() }
        }
    }

    func moveTab(from: Int, to: Int) {
        guard from != to, tabs.indices.contains(from), tabs.indices.contains(to) else { return }
        let t = tabs.remove(at: from)
        tabs.insert(t, at: to)
        if activeIndex == from { activeIndex = to }
        else if from < activeIndex && to >= activeIndex { activeIndex -= 1 }
        else if from > activeIndex && to <= activeIndex { activeIndex += 1 }
        // Dropped between two tabs of a group: join it. Dragged clear of its own group: leave it.
        let left = to > 0 ? tabs[to - 1].group : nil
        let right = to + 1 < tabs.count ? tabs[to + 1].group : nil
        if let l = left, l === right { t.group = l }
        else if let g = t.group, g !== left, g !== right { t.group = nil }
        refreshTabBar()
    }

    // MARK: Names & groups

    func renameTab(_ tab: TabSession, to name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        tab.customTitle = n.isEmpty ? nil : n
        tabDidUpdate(tab)
    }

    /// Groups in tab-bar order.
    var groups: [TabGroup] {
        var out: [TabGroup] = []
        for t in tabs { if let g = t.group, !out.contains(where: { $0 === g }) { out.append(g) } }
        return out
    }

    func tabs(in g: TabGroup) -> [TabSession] { tabs.filter { $0.group === g } }

    /// Moves a whole group, in one piece, in front of the tab at `index` (tabs.count = the end).
    func moveGroup(_ g: TabGroup, before index: Int) {
        let members = tabs(in: g)
        guard !members.isEmpty else { return }
        let anchor = index < tabs.count ? tabs[index] : nil
        guard anchor?.group !== g else { return }
        let active = activeTab
        var rest = tabs.filter { $0.group !== g }
        rest.insert(contentsOf: members, at: anchor.flatMap { rest.firstIndex(of: $0) } ?? rest.count)
        tabs = rest
        activeIndex = active.flatMap { tabs.firstIndex(of: $0) } ?? 0
        refreshTabBar()
    }

    /// Gathers several tabs (in their tab-bar order) into a new group where the first of them is, then opens
    /// its name for editing. Tabs are pulled out of any group they were in; no other group is split.
    func addToNewGroup(_ list: [TabSession]) {
        let picked = tabs.filter { list.contains($0) }
        guard let first = picked.first, let firstIndex = tabs.firstIndex(of: first) else { return }
        let active = activeTab
        var rest = tabs.filter { !picked.contains($0) }
        var at = tabs[..<firstIndex].filter { !picked.contains($0) }.count
        // Landing inside another group would split it; go after that group instead.
        while at > 0, at < rest.count, let g = rest[at].group, rest[at - 1].group === g { at += 1 }
        rest.insert(contentsOf: picked, at: at)
        tabs = rest
        let g = makeGroup()
        picked.forEach { $0.group = g }
        activeIndex = active.flatMap { tabs.firstIndex(of: $0) } ?? 0
        refreshTabBar()
        tabBar.beginEditing(group: g)
    }

    func addTabs(_ list: [TabSession], to g: TabGroup) {
        tabs.filter { list.contains($0) }.forEach { addTab($0, to: g) }
    }

    /// Moves `tab` to `index` (in the array without it), keeping the active tab selected.
    private func reposition(_ tab: TabSession, to index: (([TabSession]) -> Int)) {
        guard let from = tabs.firstIndex(of: tab) else { return }
        let active = activeTab
        tabs.remove(at: from)
        tabs.insert(tab, at: min(index(tabs), tabs.count))
        activeIndex = active.flatMap { tabs.firstIndex(of: $0) } ?? 0
    }

    /// Starts a new group with this tab (in an unused color) and opens its name for editing.
    func addToNewGroup(_ tab: TabSession) {
        if tab.group != nil { removeFromGroup(tab) }
        let g = makeGroup()
        tab.group = g
        refreshTabBar()
        tabBar.beginEditing(group: g)
    }

    func makeGroup() -> TabGroup {
        let used = Set(groups.map(\.color))
        return TabGroup(color: TabGroupColor.allCases.first { !used.contains($0) } ?? .grey)
    }

    /// Dropping a tab onto another puts it right after the target in the target's group, or starts a new
    /// group holding both and opens its name for editing.
    func groupTab(_ tab: TabSession, with target: TabSession) {
        guard tab !== target, tab.group == nil || tab.group !== target.group else { return }
        let g = target.group ?? makeGroup()
        let isNew = target.group == nil
        reposition(tab) { rest in (rest.firstIndex(of: target) ?? rest.count - 1) + 1 }
        tab.group = g
        target.group = g
        refreshTabBar()
        if isNew { tabBar.beginEditing(group: g) }
    }

    func addTab(_ tab: TabSession, to g: TabGroup) {
        guard tab.group !== g else { return }
        reposition(tab) { rest in (rest.lastIndex { $0.group === g } ?? rest.count - 1) + 1 }
        tab.group = g
        if tab === activeTab { g.collapsed = false }
        refreshTabBar()
    }

    /// Takes a tab out of its group, placing it just after the group.
    func removeFromGroup(_ tab: TabSession) {
        guard let g = tab.group else { return }
        let from = tabs.firstIndex(of: tab) ?? 0
        reposition(tab) { rest in rest.lastIndex { $0.group === g }.map { $0 + 1 } ?? from }
        tab.group = nil
        refreshTabBar()
    }

    func ungroup(_ g: TabGroup) {
        tabs(in: g).forEach { $0.group = nil }
        refreshTabBar()
    }

    func newTab(in g: TabGroup, cwd: String? = nil, openFolders: [String: Set<String>] = [:]) {
        let end = (tabs.lastIndex { $0.group === g } ?? tabs.count - 1) + 1
        insertTab(cwd: cwd, at: end, group: g, openFolders: openFolders)
    }

    /// Collapsing hides a group's tabs; if the active tab is among them, the nearest visible tab takes over.
    func setCollapsed(_ g: TabGroup, _ collapsed: Bool) {
        g.collapsed = collapsed
        if collapsed, let active = activeTab, active.group === g {
            let order = tabs.indices.sorted { abs($0 - activeIndex) < abs($1 - activeIndex) }
            if let i = order.first(where: { tabs[$0].group?.collapsed != true }) {
                select(index: i)
            } else {
                insertTab(cwd: nil, at: tabs.count, group: nil)
            }
        }
        refreshTabBar()
    }

    func refreshTabBar() {
        updateTitle()
        tabBar.needsLayout = true
        tabBar.needsDisplay = true
    }

    func tabDidUpdate(_ tab: TabSession) {
        if tab === activeTab { updateTitle() }
        tabBar.needsDisplay = true
    }

    func isActiveTab(_ tab: TabSession) -> Bool { tab === activeTab && (owner?.window?.isKeyWindow ?? false) }

    func tabDidFocus(_ tab: TabSession) { owner?.columnDidFocus(self) }

    func tabWantsClose(_ tab: TabSession) { closeTabs([tab]) }

    /// A file tab (just the file, no terminal) right after the active tab.
    func addFileTab(_ ed: FileEditorView) {
        let tab = TabSession(cwd: ed.fs.isRemote ? nil : FilePaths.parent(ed.path))
        tab.fileOrigin = (ed.fs, FilePaths.parent(ed.path))
        tab.owner = self
        tabs.insert(tab, at: min(activeIndex + 1, tabs.count))
        tab.showFileOnly(ed)
        select(index: tabs.firstIndex(of: tab) ?? tabs.count - 1)
    }

    /// Goes to the tab in this window that has the file open, or opens it in a new file tab.
    @discardableResult
    func showInOwnTab(_ fs: FileSystem, _ path: String) -> FileEditorView {
        for c in owner?.columns ?? [self] {
            for (t, tab) in c.tabs.enumerated() {
                guard let i = tab.editors.firstIndex(where: { $0.fs === fs && $0.path == path && $0.mode == .file }) else { continue }
                c.select(index: t)
                tab.activateEditor(i)
                owner?.columnDidFocus(c)
                return tab.editors[i]
            }
        }
        let ed = FileEditorView(fs: fs, path: path, mode: .file)
        addFileTab(ed)
        return ed
    }

    func tabDidClose(_ tab: TabSession) {
        guard let idx = tabs.firstIndex(of: tab) else { return }
        owner?.rememberClosed(tab, from: self, at: idx)
        tabs.remove(at: idx)
        if tabs.isEmpty {
            owner?.columnDidEmpty(self)
            return
        }
        let next = idx < activeIndex ? activeIndex - 1 : min(activeIndex, tabs.count - 1)
        activeIndex = -1
        select(index: next)
    }

    /// The window shows the focused column's tab in its title, status bar and sidebars.
    private func updateTitle() { owner?.columnDidChange(self) }

    // MARK: Moving tabs between columns

    /// Takes a tab out of this column without closing it (it's moving to the other column).
    func detach(_ tab: TabSession) {
        guard let idx = tabs.firstIndex(of: tab) else { return }
        tab.view.removeFromSuperview()
        tabs.remove(at: idx)
        tabBar.clearTabSelection()
        if tabs.isEmpty { return owner?.columnDidEmpty(self) ?? () }
        let next = idx < activeIndex ? activeIndex - 1 : min(activeIndex, tabs.count - 1)
        activeIndex = -1
        select(index: next)
    }

    /// Takes in a tab from the other column, at the end of the strip (outside any group), and shows it.
    func adopt(_ tab: TabSession, keepGroup: Bool = false) {
        tab.owner = self
        if !keepGroup { tab.group = nil }
        tabs.append(tab)
        select(index: tabs.count - 1)
    }

    /// Rebuilds this column's tabs and groups from a saved session. Returns false if nothing usable was saved.
    func restore(tabs saved: [TabState], groups savedGroups: [GroupState], active: Int) -> Bool {
        let groups = savedGroups.map { gs -> TabGroup in
            let g = TabGroup(color: TabGroupColor(rawValue: gs.color) ?? .grey)
            g.name = gs.name
            g.collapsed = gs.collapsed
            return g
        }
        tabs = saved.map { makeTab($0, group: $0.group.flatMap { groups.indices.contains($0) ? groups[$0] : nil }) }
        guard !tabs.isEmpty else { return false }
        select(index: min(max(active, 0), tabs.count - 1))
        return true
    }

    /// A tab rebuilt from saved state: fresh shells in the saved folders with the old output above, its name,
    /// group, and open files (local ones); a file tab comes back as one.
    private func makeTab(_ ts: TabState, group: TabGroup?) -> TabSession {
        let t = TabSession(restoring: ts)
        t.owner = self
        t.customTitle = ts.title
        t.group = group
        t.pinnedFolder = ts.pinnedFolder.map { (LocalFileSystem.shared, $0) }
        let files = (ts.files ?? []).filter { FileManager.default.fileExists(atPath: $0) }
        if ts.terminalHidden == true, let first = files.first {
            t.fileOrigin = (LocalFileSystem.shared, FilePaths.parent(first))
            t.showFileOnly(FileEditorView(fs: LocalFileSystem.shared, path: first))
            files.dropFirst().forEach { t.openFile(LocalFileSystem.shared, $0, focus: false) }
        } else {
            files.forEach { t.openFile(LocalFileSystem.shared, $0, focus: false) }
        }
        if let a = ts.activeFile { t.activateEditor(a, focus: false) }
        return t
    }

    /// ⇧⌘T: brings a closed tab back where it was (in its group, if that's still around).
    func reopen(_ state: TabState, at index: Int, group: TabGroup?) {
        let g = group.flatMap { g in tabs.contains { $0.group === g } ? g : nil }
        let t = makeTab(state, group: g)
        var i = min(index, tabs.count)
        if let g, let first = tabs.firstIndex(where: { $0.group === g }), let last = tabs.lastIndex(where: { $0.group === g }) {
            i = min(max(i, first), last + 1)
        } else {
            // Not into the middle of some other group.
            while i > 0, i < tabs.count, let og = tabs[i].group, tabs[i - 1].group === og { i += 1 }
        }
        tabs.insert(t, at: i)
        select(index: i)
    }

    // MARK: Actions (the window's menu commands land here for the focused column)

    /// ⌥⌘T: a new tab at the end of the current tab's group; with no group, the current tab and a new one right
    /// after it become a new group, whose name field opens. The new tab starts where the current one is: the
    /// terminal's folder (on this Mac) and the same sidebar folders open.
    func newTabInGroup() {
        guard let current = activeTab, let i = tabs.firstIndex(of: current) else { addTab(cwd: nil); return }
        let cwd = currentLocalFolder
        if let g = current.group { return newTab(in: g, cwd: cwd, openFolders: current.openFolders) }
        let g = makeGroup()
        current.group = g
        insertTab(cwd: cwd, at: i + 1, group: g, openFolders: current.openFolders)
        // After the new tab's own (async) focus, or that would take the keyboard from the name field.
        DispatchQueue.main.async { [weak self] in self?.tabBar.beginEditing(group: g) }
    }

    /// Next/previous tab, skipping tabs hidden in collapsed groups.
    func stepTab(_ d: Int) {
        guard tabs.count > 1 else { return }
        var i = activeIndex
        for _ in 1..<tabs.count {
            i = (i + d + tabs.count) % tabs.count
            if tabs[i].group?.collapsed != true { return select(index: i) }
        }
    }

    var hasRunningJobs: Bool { tabs.contains { $0.hasRunningJobs } }
}
