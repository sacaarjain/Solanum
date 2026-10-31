import AppKit
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    private(set) var windows: [TerminalWindowController] = []
    private var hotKey: HotKey?
    /// Its title says how long, which Settings can change.
    private weak var keepAwakeItem: NSMenuItem?
    private let themeMenu = NSMenu(title: "Theme")
    private let snippetsMenu = NSMenu(title: "Snippets")
    private var quickTerminalItem: NSMenuItem?
    private var autosaveTimer: Timer?
    /// Files handed to us (Finder "Open With") before launch finished; opened once windows exist.
    private var pendingOpens: [URL]? = []
    /// Set while ⇧⌘R is quitting so the app comes back up afterwards.
    private var restarting = false
    /// The app to open when restarting, if not this one: a freshly installed update (kept until a restart happens,
    /// so a restart postponed at the prompt still opens the new build).
    var relaunchPath: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Writes to a pipe whose reader died (e.g. an ssh helper for the file sidebar) must fail, not kill the app.
        signal(SIGPIPE, SIG_IGN)
        ShellIntegration.install()
        InstalledAgents.shared.refresh()
        Config.shared.load()
        Config.shared.startWatching()
        Tooltips.shared.start()
        SnippetStore.shared.load()
        AliasStore.shared.load()
        buildMenu()
        installTabSwitchMonitor()
        registerHotKey()
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().delegate = self
        }
        NotificationCenter.default.addObserver(forName: .solanumConfigChanged, object: nil, queue: .main) { [weak self] _ in
            self?.keepAwakeItem?.title = Config.shared.keepAwakeTitle
            self?.rebuildThemeMenu()
        }
        if Config.shared.restoreSession {
            if !restore(SessionStore.load()) { newWindow(nil) }
        } else {
            // Read before the fresh window's first autosave replaces it.
            let last = SessionStore.load()
            newWindow(nil)
            if let last, !last.windows.isEmpty { offerRestore(last) }
        }
        Updater.shared.start()
        QuantumMoon.start()
        // Saved periodically too, so a crash or force-quit loses at most a few seconds of layout.
        autosaveTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            SessionStore.save(self?.windows ?? [])
        }
        // A snapshot run (DevTools) stays behind, so it doesn't take the keyboard from whoever's typing.
        if ProcessInfo.processInfo.environment["SOLANUM_SNAPSHOT"] == nil { NSApp.activate(ignoringOtherApps: true) }
        let opens = pendingOpens ?? []
        pendingOpens = nil
        opens.forEach { openInEditor($0.path) }
        SnapshotHelper.runIfRequested()
    }

    /// Finder "Open With › Solanum", or dropping files on the Dock icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        if pendingOpens != nil { pendingOpens? += files; return }
        files.forEach { openInEditor($0.path) }
        // A snapshot run (DevTools) stays behind, so it doesn't take the keyboard from whoever's typing.
        if ProcessInfo.processInfo.environment["SOLANUM_SNAPSHOT"] == nil { NSApp.activate(ignoringOtherApps: true) }
    }

    /// Opens a local file in the editor beside the front window's panes (opening a window if there is none).
    func openInEditor(_ path: String) {
        let front = [NSApp.keyWindow, NSApp.mainWindow].lazy.compactMap { $0?.windowController as? TerminalWindowController }.first
        if front == nil && windows.isEmpty { newWindow(nil) }
        guard let wc = front ?? windows.last else { return }
        wc.window?.makeKeyAndOrderFront(nil)
        wc.activeTab?.openFile(LocalFileSystem.shared, path)
    }

    /// AppKit never matches Tab against menu key equivalents, so ⌃Tab / ⌥Tab are caught here
    /// before they reach the terminal view.
    private func installTabSwitchMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 48 else { return event }
            let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
            let action: Selector
            switch mods.subtracting(.shift) {
            case .control, .option:
                action = mods.contains(.shift) ? #selector(TerminalWindowController.selectPreviousTab(_:))
                                               : #selector(TerminalWindowController.selectNextTab(_:))
            default: return event
            }
            return NSApp.sendAction(action, to: nil, from: nil) ? nil : event
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !windows.contains(where: { $0.window?.isVisible == true }) { newWindow(nil) }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let running = windows.contains { $0.hasRunningJobs }
        guard running && Config.shared.confirmQuit else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = restarting ? "Restart Solanum?" : "Quit Solanum?"
        alert.informativeText = "Some tabs still have running processes. They will be terminated."
        alert.addButton(withTitle: restarting ? "Restart" : "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        SessionStore.save(windows, sync: true)
        for w in windows { w.tabs.forEach { $0.terminateAll() } }
        if restarting {
            // A detached shell waits for this process to exit, then opens the app again (picking up a new build).
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.1; done; open \(shellQuote(relaunchPath ?? Bundle.main.bundlePath))"]
            try? p.run()
        }
    }

    /// Quits and reopens `path` instead of this app (see Updater).
    func restart(into path: String) {
        relaunchPath = path
        restartApp(nil)
    }

    /// Solanum › Check for Updates…
    @objc func checkForUpdates(_ sender: Any?) { Updater.shared.check(manual: true) }

    /// ⇧⌘R: quit and reopen, restoring windows and tabs (and loading the installed build).
    @objc func restartApp(_ sender: Any?) {
        restarting = true
        NSApp.terminate(sender)
        // Still here: the quit was cancelled.
        restarting = false
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let m = NSMenu()
        m.addItem(withTitle: "New Window", action: #selector(newWindow(_:)), keyEquivalent: "")
        m.addItem(withTitle: "Quick Terminal", action: #selector(toggleQuickTerminal(_:)), keyEquivalent: "")
        return m
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    // MARK: - Windows

    private var focusedPane: TerminalView? {
        if let t = NSApp.keyWindow?.firstResponder as? TerminalView { return t }
        if let wc = NSApp.keyWindow?.windowController as? TerminalWindowController { return wc.activeTab?.focusedPane }
        return (NSApp.mainWindow?.windowController as? TerminalWindowController)?.activeTab?.focusedPane
    }

    @objc func newWindow(_ sender: Any?) {
        let wc = TerminalWindowController(cwd: nil)
        if let last = windows.last?.window {
            wc.window?.setFrameTopLeftPoint(NSPoint(x: last.frame.minX + 28, y: last.frame.maxY - 28))
        } else {
            wc.window?.center()
        }
        present(wc)
    }

    private func present(_ wc: TerminalWindowController) {
        wc.onClose = { [weak self] c in
            DispatchQueue.main.async { self?.windows.removeAll { $0 === c } }
        }
        windows.append(wc)
        wc.showWindow(nil)
        wc.window?.makeKeyAndOrderFront(nil)
    }

    /// Reopens the windows saved at last quit. Returns false if there was nothing to restore.
    private func restore(_ saved: SessionState?) -> Bool {
        guard let saved, !saved.windows.isEmpty else { return false }
        for w in saved.windows {
            let wc = TerminalWindowController(cwd: nil, restoring: w)
            if w.frame == nil { wc.window?.center() }
            present(wc)
        }
        return !windows.isEmpty
    }

    /// Starting fresh: offers the last session in the corner of the new window for a minute. Restoring it
    /// closes the new window too, unless something was done in it already.
    func offerRestore(_ saved: SessionState) {
        guard let wc = windows.first else { return }
        let prompt = CornerNoticeView(title: "Restore last session?", button: ("Restore", { [weak self, weak wc] in
            let untouched = wc.map { w in
                w.allTabs.count == 1 && w.allTabs[0].panes.count == 1 && w.allTabs[0].panes[0].terminal.blocks.allSatisfy { $0.command.isEmpty }
            } ?? false
            _ = self?.restore(saved)
            if untouched { wc?.window?.close() }
        }), lifetime: 60)
        wc.rootView.showNotice(prompt)
    }

    /// Fallback when ⌘T is pressed somewhere without tabs (e.g. the quick terminal).
    @objc func newTab(_ sender: Any?) {
        if let wc = windows.first(where: { $0.window?.isVisible == true }) {
            wc.newTab(nil)
            wc.window?.makeKeyAndOrderFront(nil)
        } else {
            newWindow(nil)
        }
    }

    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.present()
    }

    @objc func toggleQuickTerminal(_ sender: Any?) {
        QuickTerminalController.shared.toggle()
    }

    func registerHotKey() {
        hotKey = nil
        let spec = Config.shared.quickTerminalHotkey
        hotKey = HotKey(spec: spec) { QuickTerminalController.shared.toggle() }
        quickTerminalItem?.title = hotKey != nil ? "Quick Terminal  (\(HotKey.displayString(spec)))" : "Quick Terminal"
    }

    // MARK: - Theme / font

    @objc func selectTheme(_ sender: NSMenuItem) {
        Config.shared.themeName = sender.title
        Config.shared.commit()
    }

    @objc func increaseFontSize(_ sender: Any?) { adjustFont(1) }
    @objc func decreaseFontSize(_ sender: Any?) { adjustFont(-1) }
    @objc func resetFontSize(_ sender: Any?) {
        Config.shared.fontSize = 13
        Config.shared.commit()
    }

    private func adjustFont(_ d: CGFloat) {
        Config.shared.fontSize = min(max(Config.shared.fontSize + d, 8), 40)
        Config.shared.commit()
    }

    @objc func cycleTheme(_ sender: Any?) {
        let all = ThemeLibrary.all
        let i = all.firstIndex { $0.name == Config.shared.theme.name } ?? 0
        Config.shared.themeName = all[(i + 1) % all.count].name
        Config.shared.commit()
    }

    @objc func openConfigFile(_ sender: Any?) {
        Config.shared.save()
        openInEditor(Config.shared.fileURL.path)
    }

    @objc func reloadConfig(_ sender: Any?) {
        Config.shared.reloadFromDisk()
        SnippetStore.shared.load()
        registerHotKey()
    }

    // MARK: - Snippets

    @objc func insertSnippet(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? Snippet else { return }
        if let pane = focusedPane {
            pane.insertText(s.command)
        }
    }

    @objc func editSnippets(_ sender: Any?) {
        SnippetStore.shared.save()
        openInEditor(SnippetStore.shared.fileURL.path)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === snippetsMenu {
            SnippetStore.shared.load()
            menu.removeAllItems()
            for s in SnippetStore.shared.snippets {
                let item = NSMenuItem(title: s.name, action: #selector(insertSnippet(_:)), keyEquivalent: "")
                item.representedObject = s
                item.toolTip = s.command
                menu.addItem(item)
            }
            menu.addItem(.separator())
            menu.addItem(withTitle: "Save Command as Snippet…", action: #selector(TerminalView.saveCommandAsSnippet(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "Edit Snippets File…", action: #selector(editSnippets(_:)), keyEquivalent: "")
        } else if menu === themeMenu {
            rebuildThemeMenu()
        }
    }

    private func rebuildThemeMenu() {
        themeMenu.removeAllItems()
        let current = Config.shared.theme.name
        for t in ThemeLibrary.all {
            if t.name == ThemeLibrary.vsCode.first?.name {
                themeMenu.addItem(.separator())
                let h = NSMenuItem(title: "VS Code", action: nil, keyEquivalent: "")
                h.isEnabled = false
                themeMenu.addItem(h)
            }
            let item = NSMenuItem(title: t.name, action: #selector(selectTheme(_:)), keyEquivalent: "")
            item.state = t.name == current ? .on : .off
            themeMenu.addItem(item)
        }
        themeMenu.addItem(.separator())
        themeMenu.addItem(withTitle: "Next Theme", action: #selector(cycleTheme(_:)), keyEquivalent: "")
    }

    // MARK: - Menu bar

    private func buildMenu() {
        let main = NSMenu()

        @discardableResult func add(_ menu: NSMenu, _ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = [.command], tag: Int = 0) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            item.tag = tag
            menu.addItem(item)
            return item
        }
        // Hidden items keep working as shortcuts; AppKit ignores their key equivalents otherwise.
        func hide(_ item: NSMenuItem) {
            item.isHidden = true
            item.allowsKeyEquivalentWhenHidden = true
        }
        func top(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let m = NSMenu(title: title)
            item.submenu = m
            main.addItem(item)
            return m
        }
        let arrowUp = String(UnicodeScalar(NSUpArrowFunctionKey)!)
        let arrowDown = String(UnicodeScalar(NSDownArrowFunctionKey)!)
        let arrowLeft = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        let arrowRight = String(UnicodeScalar(NSRightArrowFunctionKey)!)
        let home = String(UnicodeScalar(NSHomeFunctionKey)!)
        let end = String(UnicodeScalar(NSEndFunctionKey)!)

        // App
        let app = top("Solanum")
        _ = add(app, "About Solanum", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), "")
        _ = add(app, "Check for Updates…", #selector(checkForUpdates(_:)), "")
        app.addItem(.separator())
        _ = add(app, "Settings…", #selector(showSettings(_:)), ",")
        _ = add(app, "Open Config File", #selector(openConfigFile(_:)), "")
        _ = add(app, "Reload Config", #selector(reloadConfig(_:)), "")
        _ = add(app, "Restart Solanum", #selector(restartApp(_:)), "r", [.command, .shift])
        app.addItem(.separator())
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        services.submenu = NSMenu(title: "Services")
        NSApp.servicesMenu = services.submenu
        app.addItem(services)
        app.addItem(.separator())
        _ = add(app, "Hide Solanum", #selector(NSApplication.hide(_:)), "h")
        _ = add(app, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        _ = add(app, "Show All", #selector(NSApplication.unhideAllApplications(_:)), "")
        app.addItem(.separator())
        _ = add(app, "Quit Solanum", #selector(NSApplication.terminate(_:)), "q")

        // Shell
        let shell = top("Shell")
        _ = add(shell, "New Window", #selector(newWindow(_:)), "n")
        _ = add(shell, "New Tab", #selector(TerminalWindowController.newTab(_:)), "t")
        _ = add(shell, "New Tab in Group", #selector(TerminalWindowController.newTabInGroup(_:)), "t", [.command, .option])
        _ = add(shell, "Reopen Closed Tab", #selector(TerminalWindowController.reopenClosedTab(_:)), "t", [.command, .shift])
        _ = add(shell, "Open Folder…", #selector(TerminalWindowController.openFolder(_:)), "o")
        _ = add(shell, "Go to Folder…", #selector(TerminalWindowController.goToFolder(_:)), "")
        _ = add(shell, "Rename Tab…", #selector(TerminalWindowController.renameCurrentTab(_:)), "i", [.command, .shift])
        shell.addItem(.separator())
        _ = add(shell, "Add Tab to New Group", #selector(TerminalWindowController.addCurrentTabToNewGroup(_:)), "g", [.command, .option])
        _ = add(shell, "Remove Tab from Group", #selector(TerminalWindowController.removeCurrentTabFromGroup(_:)), "")
        _ = add(shell, "Rename Tab Group…", #selector(TerminalWindowController.renameCurrentGroup(_:)), "")
        _ = add(shell, "Collapse Tab Group", #selector(TerminalWindowController.collapseCurrentGroup(_:)), "")
        shell.addItem(.separator())
        _ = add(shell, "Save File", #selector(FileEditorView.saveDocument(_:)), "s")
        _ = add(shell, "Beautify / Format Document", #selector(TerminalWindowController.beautifyDocument(_:)), "f", [.command, .option])
        shell.addItem(.separator())
        // Two columns, each with its own tabs (like VS Code's editor groups).
        _ = add(shell, "Split Right", #selector(TerminalWindowController.splitIntoColumns(_:)), "d")
        _ = add(shell, "Move Tab to Other Split", #selector(TerminalWindowController.moveTabToOtherColumn(_:)), "d", [.command, .shift])
        _ = add(shell, "Close Split", #selector(TerminalWindowController.closeSplit(_:)), "w", [.command, .control])
        shell.addItem(.separator())
        _ = add(shell, "Close Pane", #selector(TerminalView.closePane(_:)), "w")
        _ = add(shell, "Close Tab", #selector(TerminalWindowController.closeTab(_:)), "w", [.command, .option])
        _ = add(shell, "Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .shift])
        shell.addItem(.separator())
        keepAwakeItem = add(shell, Config.shared.keepAwakeTitle, #selector(TerminalView.keepAwake(_:)), "a", [.command, .shift])
        _ = add(shell, "Show Git Graph", #selector(TerminalWindowController.showGitGraph(_:)), "g", [.command, .control])
        _ = add(shell, "Show Git Changes", #selector(TerminalWindowController.showGitStatus(_:)), "s", [.command, .control])

        // Edit
        let edit = top("Edit")
        _ = add(edit, "Undo", Selector(("undo:")), "z")
        _ = add(edit, "Redo", Selector(("redo:")), "z", [.command, .shift])
        edit.addItem(.separator())
        _ = add(edit, "Cut", #selector(NSText.cut(_:)), "x")
        _ = add(edit, "Copy", #selector(TerminalView.copy(_:)), "c")
        _ = add(edit, "Paste", #selector(TerminalView.paste(_:)), "v")
        _ = add(edit, "Select All", #selector(NSResponder.selectAll(_:)), "a")
        edit.addItem(.separator())
        _ = add(edit, "Find…", #selector(TerminalView.showFind(_:)), "f")
        _ = add(edit, "Search in Project Folder…", #selector(TerminalWindowController.findInFolder(_:)), "f", [.command, .shift])
        _ = add(edit, "Find Next", #selector(TerminalView.findNext(_:)), "g")
        _ = add(edit, "Find Previous", #selector(TerminalView.findPrevious(_:)), "g", [.command, .shift])
        edit.addItem(.separator())
        _ = add(edit, "Clear Buffer", #selector(TerminalView.clearBuffer(_:)), "k")

        // View
        let view = top("View")
        _ = add(view, "Command Palette…", #selector(TerminalWindowController.showCommandPalette(_:)), "p", [.command, .shift])
        quickTerminalItem = add(view, "Quick Terminal", #selector(toggleQuickTerminal(_:)), "")
        _ = add(view, "Toggle File Sidebar", #selector(TerminalWindowController.toggleFileSidebar(_:)), "b")
        _ = add(view, "Pin Sidebar Folder", #selector(TerminalWindowController.togglePinnedSidebarFolder(_:)), "b", [.command, .shift])
        _ = add(view, "Toggle Right Sidebar", #selector(TerminalWindowController.toggleRightSidebar(_:)), "b", [.command, .option])
        _ = add(view, "Refresh Tab", #selector(TerminalWindowController.refreshTab(_:)), "r")
        view.addItem(.separator())
        let themeItem = NSMenuItem(title: "Theme", action: nil, keyEquivalent: "")
        themeItem.submenu = themeMenu
        themeMenu.delegate = self
        rebuildThemeMenu()
        view.addItem(themeItem)
        view.addItem(.separator())
        _ = add(view, "Bigger Text", #selector(increaseFontSize(_:)), "=")
        hide(add(view, "Bigger Text", #selector(increaseFontSize(_:)), "+"))
        _ = add(view, "Smaller Text", #selector(decreaseFontSize(_:)), "-")
        _ = add(view, "Default Text Size", #selector(resetFontSize(_:)), "0")
        view.addItem(.separator())
        // ⌘Home / ⌘End, as in Ghostty (⌥⌘ arrows move between panes).
        _ = add(view, "Scroll to Top", #selector(TerminalView.scrollToTop(_:)), home)
        _ = add(view, "Scroll to Bottom", #selector(TerminalView.scrollToBottom(_:)), end)
        view.addItem(.separator())
        _ = add(view, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])

        // Blocks
        let blocks = top("Blocks")
        _ = add(blocks, "Select Previous Block", #selector(TerminalView.selectPreviousBlock(_:)), arrowUp)
        _ = add(blocks, "Select Next Block", #selector(TerminalView.selectNextBlock(_:)), arrowDown)
        blocks.addItem(.separator())
        _ = add(blocks, "Copy Command", #selector(TerminalView.copyBlockCommand(_:)), "c", [.command, .shift])
        _ = add(blocks, "Copy Output", #selector(TerminalView.copyBlockOutput(_:)), "c", [.command, .option])
        _ = add(blocks, "Send to Chat…", #selector(TerminalView.sendToChat(_:)), "s", [.command, .option])
        _ = add(blocks, "Re-run Command", #selector(TerminalView.rerunBlockCommand(_:)), "r", [.command, .option])
        blocks.addItem(.separator())
        _ = add(blocks, "Collapse / Expand Output", #selector(TerminalView.toggleBlockCollapse(_:)), "e", [.command, .shift])
        _ = add(blocks, "Collapse All Outputs", #selector(TerminalView.collapseAllBlocks(_:)), "")
        _ = add(blocks, "Expand All Outputs", #selector(TerminalView.expandAllBlocks(_:)), "")
        blocks.addItem(.separator())
        _ = add(blocks, "Save Command as Snippet…", #selector(TerminalView.saveCommandAsSnippet(_:)), "s", [.command, .shift])
        blocks.addItem(.separator())
        _ = add(blocks, "Jump to Prompt…", #selector(TerminalView.jumpToPrompt(_:)), "j")
        // ⌃H itself is handled in TerminalView.keyDown so full-screen programs and the editor still receive it.
        _ = add(blocks, "Command History… (⌃H)", #selector(TerminalView.showHistory(_:)))

        // Snippets
        let snip = NSMenuItem(title: "Snippets", action: nil, keyEquivalent: "")
        snip.submenu = snippetsMenu
        snippetsMenu.delegate = self
        main.addItem(snip)

        // Window
        let win = top("Window")
        _ = add(win, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        _ = add(win, "Zoom", #selector(NSWindow.performZoom(_:)), "")
        win.addItem(.separator())
        _ = add(win, "Show Next Tab", #selector(TerminalWindowController.selectNextTab(_:)), "]", [.command, .shift])
        _ = add(win, "Show Previous Tab", #selector(TerminalWindowController.selectPreviousTab(_:)), "[", [.command, .shift])
        // ⇧⌘ arrows too, except while typing in a file or field (where they select to the line's end).
        hide(add(win, "Show Next Tab", #selector(TerminalWindowController.selectNextTab(_:)), arrowRight, [.command, .shift],
                 tag: TerminalWindowController.arrowTabTag))
        hide(add(win, "Show Previous Tab", #selector(TerminalWindowController.selectPreviousTab(_:)), arrowLeft, [.command, .shift],
                 tag: TerminalWindowController.arrowTabTag))
        // ⌃Tab / ⌥Tab (with ⇧ for previous) are handled in installTabSwitchMonitor().
        for n in 1...9 {
            hide(add(win, n == 9 ? "Last Tab" : "Tab \(n)", #selector(TerminalWindowController.selectTabByNumber(_:)), "\(n)", tag: n))
        }
        win.addItem(.separator())
        _ = add(win, "Next Pane", #selector(TerminalView.nextPane(_:)), "]")
        _ = add(win, "Previous Pane", #selector(TerminalView.previousPane(_:)), "[")
        _ = add(win, "Select Pane Left", #selector(TerminalView.focusPaneLeft(_:)), arrowLeft, [.command, .option])
        _ = add(win, "Select Pane Right", #selector(TerminalView.focusPaneRight(_:)), arrowRight, [.command, .option])
        _ = add(win, "Select Pane Above", #selector(TerminalView.focusPaneUp(_:)), arrowUp, [.command, .option])
        _ = add(win, "Select Pane Below", #selector(TerminalView.focusPaneDown(_:)), arrowDown, [.command, .option])
        win.addItem(.separator())
        _ = add(win, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), "")
        NSApp.windowsMenu = win

        NSApp.mainMenu = main
    }
}
