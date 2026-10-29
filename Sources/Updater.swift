import AppKit

// Solanum updates itself from the repository it was built from. build.sh records that repository and the commit it
// built in Info.plist (SolanumRepo, SolanumCommit). Once a day, and from Solanum › Check for Updates…, the updater
// fetches origin/main there; when main has commits this build doesn't, a corner card lists them with an Update
// button. Updating builds origin/main in a git worktree of that repository kept in Application Support, so the
// checkout you work in (its branch, its uncommitted changes) is never touched, and installs it with build.sh. Solanum
// only restarts into it when asked: Restart Now on the "ready" card or in Settings, or a restart of your own (⇧⌘R).
// While an update waits (the cards dismissed), the flower in the tab bar shows a badge and Settings › System
// offers it. The build's output goes to ~/Library/Logs/Solanum/update.log.

extension Notification.Name {
    /// The updater's state changed (the flower's badge and Settings follow it).
    static let solanumUpdateChanged = Notification.Name("SolanumUpdateChanged")
}

final class Updater {
    static let shared = Updater()

    enum State: Equatable {
        case idle
        /// main is ahead: its new commits ("abc1234<TAB>subject"), newest first; empty when unknown.
        case available([String])
        case building
        /// Installed in ~/Applications, waiting for a restart.
        case ready
        case failed
    }

    private(set) var state = State.idle {
        didSet { if state != oldValue { NotificationCenter.default.post(name: .solanumUpdateChanged, object: nil) } }
    }

    /// Something for the user to act on: the flower shows a badge.
    var needsAttention: Bool {
        switch state {
        case .available, .ready: return true
        default: return false
        }
    }

    let repo = (Bundle.main.object(forInfoDictionaryKey: "SolanumRepo") as? String).flatMap { $0.isEmpty ? nil : $0 }
    let built = (Bundle.main.object(forInfoDictionaryKey: "SolanumCommit") as? String).flatMap { $0.isEmpty ? nil : $0 }
    /// Where updates are built: a worktree of the repository, on origin/main.
    static var worktree: String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Solanum/update").path
    }
    /// build.sh installs here (see INSTALL_DIR there).
    private var installed: String { NSHomeDirectory() + "/Applications/Solanum.app" }
    static var log: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/Solanum/update.log")
    }
    private var timer: Timer?
    private var checking = false
    private weak var card: CornerNoticeView?

    private let defaults = UserDefaults.standard
    private enum Key {
        static let lastCheck = "solanum.update.lastCheck"
        /// The main the daily check last showed a card for (each is shown once).
        static let offered = "solanum.update.offered"
        /// The commit last installed by an update, until Solanum runs it.
        static let ready = "solanum.update.ready"
        /// An update was available when Solanum last ran: check again soon after launch, so the badge comes back.
        static let pending = "solanum.update.pending"
    }

    /// This build knows where it came from (it was made by build.sh in a git checkout).
    var canUpdate: Bool { repo != nil && built != nil }

    /// Picks up an update installed earlier but not restarted into, then starts the daily check: a minute after launch
    /// (sooner if one was waiting), and whenever a day has passed since the last (looked at hourly, so a Mac that was
    /// asleep catches up).
    func start() {
        guard canUpdate, ProcessInfo.processInfo.environment["SOLANUM_SNAPSHOT"] == nil else { return }
        if let ready = defaults.string(forKey: Key.ready) {
            if ready == built || installedCommit != ready {
                defaults.removeObject(forKey: Key.ready)     // running it now, or the install was replaced
            } else {
                becomeReady(showCard: true)
            }
        }
        let soon = defaults.bool(forKey: Key.pending)
        DispatchQueue.main.asyncAfter(deadline: .now() + (soon ? 15 : 60)) { [weak self] in
            guard let self else { return }
            if soon { self.check(manual: false, force: true) } else { self.checkIfDue() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in self?.checkIfDue() }
    }

    private func checkIfDue() {
        guard Config.shared.checkForUpdates else { return }
        if Date().timeIntervalSince1970 - defaults.double(forKey: Key.lastCheck) >= 24 * 3600 { check(manual: false) }
    }

    /// The commit of the Solanum installed in ~/Applications (read from disk, not the bundle cache).
    private var installedCommit: String? {
        NSDictionary(contentsOfFile: installed + "/Contents/Info.plist")?["SolanumCommit"] as? String
    }

    /// Fetches origin/main and offers it if this build doesn't have it. `manual` (the menu, Settings) reports "up to
    /// date" and errors and shows the card again; `force` checks even if the daily check is off.
    func check(manual: Bool, force: Bool = false) {
        guard let repo, let built else {
            if manual {
                alert("Updates need a build made with build.sh",
                      "This copy of Solanum doesn't know which repository it came from. Build it with ./build.sh in a clone of the repository.")
            }
            return
        }
        guard !checking, state != .building else { return }
        if state == .ready {
            if manual { showReadyCard() }
            return
        }
        checking = true
        // The new commits on main, newest first ("unknown" when this build's commit isn't in the repository).
        let script = """
            git fetch --quiet origin main || exit 3
            git rev-parse origin/main
            if git cat-file -e \(built)^{commit} 2>/dev/null; then git log --format='%h%x09%s' \(built)..origin/main; else echo unknown; fi
            """
        GitRunner(dir: repo, remote: nil).run(script, timeout: 120) { [weak self] status, out, err in
            guard let self else { return }
            self.checking = false
            guard status == 0 else {
                if manual { self.alert("Couldn't check for updates", err.isEmpty ? "git fetch from origin failed." : err) }
                return
            }
            self.defaults.set(Date().timeIntervalSince1970, forKey: Key.lastCheck)
            var lines = String(decoding: out, as: UTF8.self).split(separator: "\n").map(String.init)
            let head = lines.isEmpty ? "" : lines.removeFirst()
            let unknown = lines == ["unknown"]
            let commits = unknown ? [] : lines
            guard !head.isEmpty, head != built, unknown || !commits.isEmpty else {
                self.state = .idle
                self.defaults.removeObject(forKey: Key.pending)
                if manual { self.alert("Solanum is up to date", "This build (\(built.prefix(7))) has everything on main.") }
                return
            }
            self.state = .available(commits)
            self.defaults.set(true, forKey: Key.pending)
            // Each new main gets a card once from the daily check; after that the badge and Settings carry it.
            if manual || self.defaults.string(forKey: Key.offered) != head {
                self.defaults.set(head, forKey: Key.offered)
                self.showAvailableCard(commits)
            }
        }
    }

    // MARK: Cards

    private func showAvailableCard(_ commits: [String]) {
        let n = commits.count
        var lines = [n == 0 ? "main has moved on" : "\(n) new commit\(n == 1 ? "" : "s") on main"]
        lines += commits.prefix(3).map(Self.subject)
        if n > 3 { lines.append("and \(n - 3) more") }
        show(CornerNoticeView(title: "Solanum update", symbol: ("arrow.down.circle.fill", Config.shared.theme.accent), lines: lines,
                              button: ("Update", { [weak self] in self?.update(restart: false) }), lifetime: 6 * 3600))
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
    }

    /// Stays until acted on: Restart Now, or ✕ (the badge and Settings keep the offer).
    private func showReadyCard() {
        show(CornerNoticeView(title: "Solanum update ready", symbol: ("checkmark.circle.fill", Config.shared.theme.accent),
                              lines: ["Restart to use it; your tabs come back"],
                              button: ("Restart Now", { [weak self] in self?.restartNow() }), lifetime: 7 * 24 * 3600))
    }

    static func subject(_ line: String) -> String { line.split(separator: "\t", maxSplits: 1).last.map(String.init) ?? line }

    // MARK: Updating

    /// Builds origin/main in the worktree (made the first time) and installs it; `restart` then restarts into it,
    /// otherwise it waits for Restart Now or a restart of the user's own.
    func update(restart: Bool) {
        guard let repo, state != .building else { return }
        card?.dismiss()
        state = .building
        let progress = CornerNoticeView(title: "Updating Solanum…", symbol: ("hammer.fill", Config.shared.theme.accent),
                                        lines: ["Building the latest main, usually a minute or two"], lifetime: 1800)
        show(progress)
        let log = Self.log
        try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        let wt = shellQuote(Self.worktree)
        let script = """
            exec >\(shellQuote(log.path)) 2>&1
            set -e
            git fetch origin main
            git worktree prune
            if [ -e \(wt)/.git ]; then
              git -C \(wt) checkout --quiet --detach --force origin/main
              git -C \(wt) clean -fdq
            else
              mkdir -p "$(dirname \(wt))"
              git worktree add --detach \(wt) origin/main
            fi
            cd \(wt)
            ./build.sh
            """
        GitRunner(dir: repo, remote: nil).run(script, timeout: 1800) { [weak self] status, _, _ in
            guard let self else { return }
            progress.dismiss()
            guard status == 0, let commit = self.installedCommit else {
                self.state = .failed
                return self.show(CornerNoticeView(title: "Solanum update failed", symbol: ("xmark.octagon.fill", Config.shared.theme.red),
                                                  lines: ["Nothing was installed; see the log."],
                                                  button: ("Show Log", { NSWorkspace.shared.open(Updater.log) }), lifetime: 3600))
            }
            self.defaults.set(commit, forKey: Key.ready)
            self.defaults.removeObject(forKey: Key.pending)
            self.becomeReady(showCard: !restart)
            if restart { self.restartNow() }
        }
    }

    /// An update is installed: a restart of any kind (Restart Now, ⇧⌘R) opens it.
    private func becomeReady(showCard: Bool) {
        state = .ready
        (NSApp.delegate as? AppDelegate)?.relaunchPath = installed
        if showCard { showReadyCard() }
    }

    func restartNow() {
        (NSApp.delegate as? AppDelegate)?.restart(into: installed)
    }

    private func show(_ notice: CornerNoticeView) {
        let wc = (NSApp.keyWindow?.windowController as? TerminalWindowController)
            ?? NSApp.windows.lazy.compactMap { $0.windowController as? TerminalWindowController }.first
        card?.dismiss()
        card = notice
        wc?.rootView.showNotice(notice)
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}
