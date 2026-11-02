import AppKit

// Session restore: windows, tabs, split layouts, working directories, tab names, groups and (optionally)
// recent scrollback are saved to ~/.config/solanum/session.json on quit and periodically, and rebuilt on
// launch with fresh shells. Running processes can't survive a quit, so only their output comes back.

struct PaneState: Codable {
    var cwd: String?
    var text: String?
    /// The coding agent running here (on this Mac), by its command; restoring continues its session (Settings › Preferences).
    var agent: String?
    /// From sessions saved before `agent`: Claude Code was running here.
    var claude: Bool?
    /// An ssh session was running here: how it was started (`ssh`'s arguments) and the folder it was in on the host.
    /// Restoring logs in again and goes back there, once the tab is first shown.
    var ssh: String?
    var remoteCwd: String?
}

indirect enum PaneNode: Codable {
    case pane(PaneState)
    case split(vertical: Bool, fractions: [Double], children: [PaneNode])
}

struct TabState: Codable {
    var title: String?
    var group: Int?
    var focused: Int
    var layout: PaneNode
    /// Local files open above the terminal, the one showing, and whether it's a file tab (terminal hidden).
    var files: [String]?
    var activeFile: Int?
    var terminalHidden: Bool?
    /// The sidebar's pinned folder for this tab (local folders only; ssh pins don't outlive the connection).
    var pinnedFolder: String?
}

struct GroupState: Codable {
    var name: String
    var color: String
    var collapsed: Bool
}

/// The right-hand column of a split window.
struct ColumnState: Codable {
    var active: Int
    var groups: [GroupState]
    var tabs: [TabState]
    /// Read from sessions saved before pins were per tab (see `TabState.pinnedFolder`).
    var pinnedFolder: String?
}

/// A window: its (left, or only) column's tabs at the top level, as before splits existed, plus the right
/// column when split.
struct WindowState: Codable {
    var frame: String?
    var active: Int
    var groups: [GroupState]
    var tabs: [TabState]
    /// Read from sessions saved before pins were per tab (see `TabState.pinnedFolder`).
    var pinnedFolder: String?
    var right: ColumnState?
    var splitFraction: Double?
    var rightSidebar: Bool?
}

struct SessionState: Codable {
    var version = 1
    var windows: [WindowState]
}

enum SessionStore {
    /// Lines of scrollback kept per pane.
    static let maxLines = 5000

    private static var env: [String: String] { ProcessInfo.processInfo.environment }

    /// SOLANUM_SESSION_FILE points tests at a scratch file; snapshot runs otherwise never touch the real session.
    static var url: URL {
        env["SOLANUM_SESSION_FILE"].map { URL(fileURLWithPath: $0) } ?? Config.shared.dir.appendingPathComponent("session.json")
    }

    /// Saved even with "Reload workspace every time" off, so the last session can still be offered at launch.
    static var enabled: Bool {
        env["SOLANUM_SNAPSHOT"] == nil || env["SOLANUM_SESSION_FILE"] != nil
    }

    private static var lastWritten: Data?

    /// Set while quitting, after the last save: what closes on the way out doesn't change what's on file.
    private static var stopped = false

    static func stopSaving() { stopped = true }

    /// Nothing comes back: the tabs were closed one by one, or Restart Fresh was asked for.
    static func forget() {
        guard enabled, !stopped else { return }
        lastWritten = nil
        try? FileManager.default.removeItem(at: url)
    }

    static func load() -> SessionState? {
        guard enabled, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SessionState.self, from: data)
    }

    /// Saves the given windows. `sync` writes before returning (used at quit); otherwise the write happens
    /// in the background.
    /// With no windows open there's nothing to save: the last ones closed stay on file, to come back.
    static func save(_ windows: [TerminalWindowController], sync: Bool = false) {
        guard enabled, !stopped, !windows.isEmpty else { return }
        let state = SessionState(windows: windows.map(\.sessionState))
        guard let data = try? JSONEncoder().encode(state), data != lastWritten else { return }
        lastWritten = data
        let target = url
        let write = {
            try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Scrollback can contain anything that was printed, so keep the file private to the user.
            if FileManager.default.createFile(atPath: target.path, contents: data, attributes: [.posixPermissions: 0o600]) == false {
                try? data.write(to: target, options: .atomic)
            }
        }
        if sync { write() } else { DispatchQueue.global(qos: .utility).async(execute: write) }
    }
}

// MARK: - Capturing state

extension TerminalWindowController {
    var sessionState: WindowState {
        let left = Self.state(of: columns[0])
        let right = columns.count > 1 ? Self.state(of: columns[1]) : nil
        return WindowState(
            frame: window.map { NSStringFromRect($0.frame) },
            active: left.active, groups: left.groups, tabs: left.tabs,
            pinnedFolder: nil,
            right: right.map { ColumnState(active: $0.active, groups: $0.groups, tabs: $0.tabs, pinnedFolder: nil) },
            splitFraction: right == nil ? nil : Double(rootView.splitFraction),
            rightSidebar: right == nil ? nil : rootView.rightSidebarVisible)
    }

    private static func state(of c: TabColumn) -> (active: Int, groups: [GroupState], tabs: [TabState]) {
        let groups = c.groups
        return (c.activeIndex,
                groups.map { GroupState(name: $0.name, color: $0.color.rawValue, collapsed: $0.collapsed) },
                c.tabs.map { t in t.savedState(group: t.group.flatMap { g in groups.firstIndex { $0 === g } }) })
    }
}

extension TabSession {
    /// Everything needed to bring this tab back (panes, folders, scrollback, name, open files), with `group` as
    /// an index into the saved groups.
    func savedState(group: Int?) -> TabState {
        // Diffs and graphs aren't files to reopen; ssh files can't come back without their connection.
        let kept = editors.filter { !$0.fs.isRemote && $0.mode == .file }
        return TabState(title: customTitle, group: group,
                 focused: panes.firstIndex(of: focusedPane) ?? 0,
                 layout: root.subviews.first.flatMap(TabSession.node) ?? .pane(PaneState()),
                 files: kept.isEmpty ? nil : kept.map(\.path),
                 activeFile: kept.isEmpty ? nil : editor.flatMap { kept.firstIndex(of: $0) } ?? 0,
                 terminalHidden: showsTerminal ? nil : true,
                 pinnedFolder: pinnedFolder.flatMap { $0.fs.isRemote ? nil : $0.path })
    }

    fileprivate static func node(_ v: NSView) -> PaneNode? {
        if let t = v as? TerminalView {
            // Not shown since it was restored: saved again as it came back, its agent and ssh session included.
            if !t.hasStarted, var saved = t.restoredFrom {
                saved.cwd = t.currentDirectory
                if !Config.shared.restoreScrollback { saved.text = nil }
                return .pane(saved)
            }
            let text = Config.shared.restoreScrollback ? t.terminal.restorableText(maxLines: SessionStore.maxLines) : nil
            let ssh = t.remote != nil ? t.terminal.sshArgs.flatMap { $0.isEmpty ? nil : $0 } : nil
            // Also while the agent's continue command is still waiting for the new shell's first prompt.
            let waiting = t.pendingCommand != nil ? t.restoredFrom.flatMap { $0.agent ?? ($0.claude == true ? "claude" : nil) } : nil
            return .pane(PaneState(cwd: t.currentDirectory, text: text?.isEmpty == false ? text : nil,
                                   agent: t.pty?.foregroundAgent?.command ?? waiting,
                                   ssh: ssh, remoteCwd: ssh == nil ? nil : t.browseDirectory))
        }
        if let s = v as? PaneSplitView {
            let children = s.arrangedSubviews.compactMap(node)
            let fractions = (s.pendingFractions ?? s.dividerFractions).map(Double.init)
            return children.count == 1 ? children[0] : .split(vertical: s.isVertical, fractions: fractions, children: children)
        }
        return v.subviews.first.flatMap(node)
    }

    /// Rebuilds a tab's pane tree. Shells start when each pane is first shown, so background tabs stay idle.
    convenience init(restoring saved: TabState) {
        var panes: [TerminalView] = []
        func build(_ n: PaneNode) -> NSView {
            switch n {
            case .pane(let p):
                let v = TerminalView(cwd: p.cwd.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil })
                v.restoredFrom = p
                if let text = p.text { v.restoredText = text + TabSession.restoredBanner }
                if let command = TabSession.continueCommand(agent: p.agent ?? (p.claude == true ? "claude" : nil)) { v.pendingCommand = command }
                if let ssh = p.ssh, let login = RemoteSession(controlPath: "", sshArgs: ssh).reconnectCommand(in: p.remoteCwd) {
                    v.pendingCommand = "\u{15}" + login
                }
                panes.append(v)
                return v
            case .split(let vertical, let fractions, let children):
                let s = PaneSplitView()
                s.isVertical = vertical
                s.dividerStyle = .thin
                for c in children { s.addArrangedSubview(build(c)) }
                s.pendingFractions = fractions.map { CGFloat($0) }
                return s
            }
        }
        let content = build(saved.layout)
        let focus = panes.indices.contains(saved.focused) ? panes[saved.focused] : panes[0]
        self.init(content: content, focus: focus)
    }

    /// What continues an agent's session, through the user's alias for it when they have one (aliases need shell
    /// integration); nil when it's not to be continued.
    private static func continueCommand(agent: String?) -> String? {
        guard Config.shared.continueAgents, let kind = agent.flatMap(AgentKind.named) else { return nil }
        let command = Config.shared.continueCommand(for: kind)
        guard !command.isEmpty else { return nil }
        let alias = Config.shared.shellIntegration ? AliasStore.shared.alias(running: kind.command) : nil
        // ⌃U first clears anything already sitting on the new shell's prompt line.
        return "\u{15}" + kind.throughAlias(command, alias: alias)
    }

    private static let restoredBanner: String = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return "\u{1b}[0m\r\n\u{1b}[2m── restored · \(f.string(from: Date())) ──\u{1b}[0m\r\n"
    }()
}

// MARK: - Serializing a buffer
