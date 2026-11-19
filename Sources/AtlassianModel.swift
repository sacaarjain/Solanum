import AppKit

// The Atlassian extension: Jira and Bitbucket beside the terminal. What the marketplace says about it, and the state
// its page shows (AtlassianPage.swift draws it): the board and its columns, your issues, the issue open in the side
// panel, the tab repository's pull requests and the one open, and what "Start work" and the others are doing.

enum AtlassianExtension {
    static let id = "atlassian"

    static let info = SolanumExtension(
        id: id,
        name: "Jira & Bitbucket",
        pageTitle: "Jira",
        publisher: "Solanum",
        version: "1.0.0",
        summary: "Your Jira board and Bitbucket pull requests beside the terminal: move tickets, start work on one with its branch, review and merge.",
        categories: ["Productivity", "Git"],
        features: [
            "Your Jira board as Jira lays it out, its own columns and order: drag a ticket to another column to move it through the workflow, or up and down to rank it.",
            "Only mine, search, and every board you can see; scrum boards show their active sprint.",
            "A ticket in a side panel: its description, comments (and adding one), status, assignee and priority, and the pull requests that mention it.",
            "Start work on a ticket: a branch named for it (ABC-123-what-it-is, as your team names them) from the branch you pick, the ticket moved to In Progress and assigned to you, pushed to Bitbucket.",
            "Create tickets, with the board's project and your issue types.",
            "Pull requests for the tab's repository: reviewers and approvals, builds, the diff file by file, and comments; approve, request changes, merge or decline; check one out.",
            "Create a pull request from your branch, titled from its ticket, with the repository's default reviewers.",
            "Ask Claude about a ticket: it gets the ticket's details in this tab's Claude Code chat.",
        ],
        mcpServer: nil,
        tools: [],
        notes: [
            "Signs in with Atlassian API tokens (Atlassian's own OAuth app isn't open to other apps): a classic token for Jira, and a token made with Bitbucket scopes for Bitbucket. They're kept in a file only your account can read (extensions/atlassian/tokens.json in Solanum's settings folder).",
            "Claude Code's Atlassian connector already gives Claude Jira and Bitbucket tools, so this extension doesn't add an MCP server of its own.",
            "Pull requests and Start work use the git repository of the tab the page is in (a folder on this Mac).",
        ],
        drawIcon: drawIcon,
        makePage: { AtlassianPageView() })

    /// A board: three columns of cards on a blue tile.
    static func drawIcon(_ r: NSRect) {
        let tile = NSBezierPath(roundedRect: r, xRadius: r.width * 0.22, yRadius: r.width * 0.22)
        NSGradient(starting: NSColor(srgbRed: 0.16, green: 0.45, blue: 0.95, alpha: 1), ending: NSColor(srgbRed: 0.05, green: 0.25, blue: 0.70, alpha: 1))?
            .draw(in: tile, angle: -90)
        let pad = r.width * 0.17, gap = r.width * 0.06
        let colW = (r.width - pad * 2 - gap * 2) / 3
        let cardH = r.height * 0.13
        let heights = [3, 2, 1]
        // In AppKit's coordinates (y up) unless the view is flipped: draw from whichever edge is the top.
        let flipped = NSGraphicsContext.current?.isFlipped ?? false
        for c in 0..<3 {
            let x = r.minX + pad + CGFloat(c) * (colW + gap)
            for i in 0..<heights[c] {
                let off = pad + CGFloat(i) * (cardH + gap)
                let y = flipped ? r.minY + off : r.maxY - off - cardH
                NSColor.white.withAlphaComponent(i == 0 && c == 1 ? 1 : 0.82).setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: y, width: colW, height: cardH), xRadius: cardH * 0.3, yRadius: cardH * 0.3).fill()
            }
        }
    }

    static func start() {}
}

enum AtlassianSection: String, CaseIterable {
    case board, mine, prs

    var title: String {
        switch self {
        case .board: return "Board"
        case .mine: return "My Issues"
        case .prs: return "Pull Requests"
        }
    }

    var symbol: String {
        switch self {
        case .board: return "rectangle.split.3x1"
        case .mine: return "person.crop.circle"
        case .prs: return "arrow.triangle.pull"
        }
    }
}

final class AtlassianModel {
    let api = AtlassianClient.shared
    var settings: AtlassianSettings {
        get { api.settings }
        set { api.settings = newValue; newValue.save() }
    }
    var onChange: (() -> Void)?

    // Connection
    var me: JiraUser?
    var bitbucketMe: BitbucketUser?
    var connecting = false
    private var fetchingMe = false, fetchingBitbucketMe = false
    var connectError: String?
    var connected: Bool { api.hasCredentials(.jira) }

    // Board
    var boards: [JiraBoard] = []
    /// The projects your assigned tickets are in, as found when choosing a first board.
    var myProjects: Set<String> = []
    var board: JiraBoard? { boards.first { $0.id == settings.boardId } ?? boards.first }
    var config: JiraBoardConfig?
    var sprintName: String?
    var issues: [JiraIssue] = []
    var loadingBoard = false
    var boardError: String?
    var search = "" { didSet { changed() } }
    /// Moves on their way to Jira: the issue's key and where it was, to put back if Jira says no.
    var pending: [String: (status: JiraStatus, index: Int)] = [:]

    // My issues
    var mine: [JiraIssue] = []
    var recent: [JiraIssue] = []
    var loadingMine = false
    var mineError: String?

    // The issue in the side panel
    var detail: JiraIssue?
    var comments: [JiraComment] = []
    var transitions: [JiraTransition] = []
    var loadingDetail = false
    /// The open ticket's branches (see `JiraBranch.merged`): Jira's, and the repository's with its key.
    var branches: [JiraBranch] { detail.map { JiraBranch.merged(linkedBranches, key: $0.key, local: repoBranches, repo: repo?.fullName) } ?? [] }
    private var linkedBranches: [JiraBranch] = []
    /// The tab repository's branches, local and on origin (as `git branch -a` names them).
    var repoBranches: [String] = []
    /// Each repository's branching model's branch types, by "workspace/slug", once asked.
    var branchTypes: [String: [BranchType]] = [:]

    // Repository and pull requests
    var repoRoot: String?
    var repo: BitbucketRepo?
    var branch: String?
    var prs: [BitbucketPullRequest] = []
    var loadingPRs = false
    var prError: String?
    var prFilter = "all" { didSet { changed() } }
    var pr: BitbucketPullRequest?
    var prFiles: [DiffFile] = []
    var prComments: [BitbucketComment] = []
    var prBuilds: [BitbucketBuild] = []
    var loadingPR = false
    var collapsedFiles: Set<String> = []

    /// A line at the bottom of the page: what just happened (true) or went wrong (false).
    var toast: (String, Bool)?
    private var toastTimer: Timer?

    func changed() { onChange?() }

    func say(_ text: String, ok: Bool = true) {
        toast = (text, ok)
        toastTimer?.invalidate()
        toastTimer = Timer.scheduledTimer(withTimeInterval: ok ? 4 : 8, repeats: false) { [weak self] _ in self?.toast = nil; self?.changed() }
        changed()
    }

    // MARK: Connecting

    /// Saves the account and checks it with Jira (and Bitbucket, when it has a token).
    func connect(site: String, email: String, jiraToken: String, bitbucketToken: String) {
        var s = settings
        s.site = AtlassianSettings.normalizeSite(site)
        s.email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.site.isEmpty, s.email.contains("@") else {
            connectError = "Enter your Jira site (yourcompany.atlassian.net) and your Atlassian account's email."
            return changed()
        }
        let jt = jiraToken.trimmingCharacters(in: .whitespacesAndNewlines), bt = bitbucketToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !jt.isEmpty { AtlassianTokens.set(.jira, jt) }
        if !bt.isEmpty { AtlassianTokens.set(.bitbucket, bt) }
        guard AtlassianTokens.get(.jira) != nil else {
            connectError = "Paste a Jira API token (id.atlassian.com › Security › API tokens)."
            return changed()
        }
        settings = s
        connecting = true
        connectError = nil
        changed()
        api.myself { [weak self] r in
            guard let self else { return }
            self.connecting = false
            switch r {
            case .success(let u):
                self.me = u
                self.load(force: true)
            case .failure(let e):
                self.connectError = e.message
            }
            self.changed()
        }
    }

    func disconnect() {
        AtlassianTokens.set(.jira, nil)
        AtlassianTokens.set(.bitbucket, nil)
        me = nil
        bitbucketMe = nil
        issues = []
        mine = []
        prs = []
        detail = nil
        pr = nil
        changed()
    }

    // MARK: Loading

    /// Everything the current section needs. `force` also refreshes what's already here.
    func load(force: Bool = false) {
        guard connected else { return changed() }
        if me == nil, !fetchingMe {
            fetchingMe = true
            api.myself { [weak self] r in
                self?.fetchingMe = false
                if case .success(let u) = r { self?.me = u; self?.changed() }
            }
        }
        if bitbucketMe == nil, !fetchingBitbucketMe, api.hasCredentials(.bitbucket) {
            fetchingBitbucketMe = true
            api.bitbucketUser { [weak self] r in
                self?.fetchingBitbucketMe = false
                if case .success(let u) = r { self?.bitbucketMe = u; self?.changed() }
            }
        }
        switch AtlassianSection(rawValue: settings.section) ?? .board {
        case .board: if force || issues.isEmpty { loadBoard() }
        case .mine: if force || mine.isEmpty { loadMine() }
        case .prs: if force || prs.isEmpty { loadPRs() }
        }
        if force, let d = detail { open(d.key) }
        if force, let p = pr { openPR(p.id) }
    }

    func loadBoard() {
        // One load at a time: opening the page asks twice (made, then shown).
        guard !loadingBoard else { return }
        loadingBoard = true
        boardError = nil
        changed()
        let go = { [weak self] in
            guard let self, let b = self.board else {
                self?.loadingBoard = false
                self?.boardError = "No boards you can see on \(self?.settings.site ?? "this site")."
                self?.changed()
                return
            }
            self.api.boardConfig(b.id) { r in
                switch r {
                case .failure(let e):
                    self.loadingBoard = false
                    self.boardError = e.message
                    self.changed()
                case .success(let c):
                    self.config = c
                    self.api.activeSprint(b.id) { sprint, name in
                        self.sprintName = name
                        self.api.boardIssues(b.id, config: c, sprint: sprint) { r in
                            self.loadingBoard = false
                            switch r {
                            case .success(let list): self.issues = list; self.pending = [:]
                            case .failure(let e): self.boardError = e.message
                            }
                            self.changed()
                        }
                    }
                }
            }
        }
        if boards.isEmpty {
            api.boards { [weak self] r in
                switch r {
                case .success(let list):
                    guard let self else { return }
                    self.boards = list
                    // The board you last had (looked up by itself when it's not among them), else one in the project
                    // your tickets are mostly in, else the first.
                    if let id = self.settings.boardId {
                        if list.contains(where: { $0.id == id }) { return go() }
                        return self.api.board(id) { r in
                            if case .success(let b) = r { self.boards.append(b) } else { self.settings.boardId = list.first?.id }
                            go()
                        }
                    }
                    self.api.search("assignee = currentUser() ORDER BY updated DESC", max: 30) { r in
                        let keys = ((try? r.get()) ?? []).map(\.projectKey)
                        let counts = Dictionary(keys.map { ($0, 1) }, uniquingKeysWith: +)
                        self.myProjects = Set(keys)
                        let pick = counts.sorted { $0.value > $1.value }.lazy.compactMap { k in list.first { $0.projectKey == k.key } }.first
                        self.settings.boardId = (pick ?? list.first)?.id
                        go()
                    }
                case .failure(let e):
                    self?.loadingBoard = false
                    self?.boardError = e.message
                    self?.changed()
                }
            }
        } else { go() }
    }

    func selectBoard(_ id: Int) {
        // A board not among those listed (one opened by its number or address): looked up first.
        guard boards.contains(where: { $0.id == id }) else {
            return api.board(id) { [weak self] r in
                switch r {
                case .success(let b): self?.boards.append(b); self?.selectBoard(id)
                case .failure(let e): self?.say("Couldn't open board \(id): \(e.message)", ok: false)
                }
            }
        }
        settings.boardId = id
        issues = []
        config = nil
        loadBoard()
    }

    /// The projects you have tickets in (yours, the ones you've opened, the board's), for the board list to put first.
    var yourProjects: Set<String> {
        myProjects.union(mine.map(\.projectKey)).union(recent.map(\.projectKey))
    }

    func loadMine() {
        guard !loadingMine else { return }
        loadingMine = true
        mineError = nil
        changed()
        let sp = config?.storyPointsField
        api.search("assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC", storyPointsField: sp) { [weak self] r in
            guard let self else { return }
            self.loadingMine = false
            switch r {
            case .success(let l): self.mine = l
            case .failure(let e): self.mineError = e.message
            }
            self.changed()
        }
        api.search("issuekey in issueHistory() ORDER BY lastViewed DESC", max: 15, storyPointsField: sp) { [weak self] r in
            if case .success(let l) = r { self?.recent = l; self?.changed() }
        }
    }

    // MARK: The board

    /// The board's issues in column `c`, filtered, in rank order.
    func cards(in c: Int) -> [JiraIssue] {
        guard let config, c < config.columns.count else { return [] }
        let ids = Set(config.columns[c].statusIds)
        return issues.filter { ids.contains($0.status.id) && matches($0) }
    }

    func matches(_ i: JiraIssue) -> Bool {
        if settings.onlyMine, i.assignee?.accountId != me?.accountId { return false }
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        return i.key.lowercased().contains(q) || i.summary.lowercased().contains(q) || (i.assignee?.displayName.lowercased().contains(q) ?? false)
            || i.labels.contains { $0.lowercased().contains(q) }
    }

    /// Drops `key` into column `c` at `index` among that column's (shown) cards: moved there at once, then Jira's
    /// told (a transition when the column changed, a rank for the order), and put back if it says no.
    func drop(_ key: String, column c: Int, index: Int) {
        guard let config, c < config.columns.count, let from = issues.firstIndex(where: { $0.key == key }) else { return }
        var issue = issues[from]
        let oldColumn = config.column(of: issue.status)
        let shown = cards(in: c).filter { $0.key != key }
        let index = max(0, min(index, shown.count))
        // Unchanged: same column, same neighbours.
        if oldColumn == c {
            let now = cards(in: c)
            if let at = now.firstIndex(where: { $0.key == key }), at == index { return }
        }
        let before = index < shown.count ? shown[index].key : nil
        let after = before == nil ? shown.last?.key : nil
        pending[key] = (issue.status, from)
        let target = config.columns[c]
        if oldColumn != c {
            // Shown in the new column straight away, as the status Jira's likely to give it (the column's first).
            issue.status = JiraStatus(id: target.statusIds[0], name: target.name, category: issue.status.category)
        }
        issues.remove(at: from)
        let insertAt = before.flatMap { b in issues.firstIndex { $0.key == b } } ?? after.flatMap { a in issues.firstIndex { $0.key == a }.map { $0 + 1 } } ?? issues.count
        issues.insert(issue, at: insertAt)
        changed()

        let rank = { [weak self] in
            guard let self else { return }
            self.api.rank(key, before: before, after: after) { e in
                self.pending[key] = nil
                if let e { self.say("Moved, but couldn't change its order: \(e.message)", ok: false) }
                self.changed()
            }
        }
        guard oldColumn != c else { return rank() }
        api.move(key, to: target.statusIds) { [weak self] r in
            guard let self else { return }
            switch r {
            case .success(let status):
                if let i = self.issues.firstIndex(where: { $0.key == key }) { self.issues[i].status = status }
                if self.detail?.key == key { self.detail?.status = status; self.loadTransitions(key) }
                self.say("\(key) → \(status.name)")
                if before != nil || after != nil { rank() } else { self.pending[key] = nil }
            case .failure(let e):
                self.putBack(key)
                self.say(e.message, ok: false)
            }
        }
    }

    private func putBack(_ key: String) {
        guard let (status, index) = pending[key], let now = issues.firstIndex(where: { $0.key == key }) else { return }
        var issue = issues.remove(at: now)
        issue.status = status
        issues.insert(issue, at: min(index, issues.count))
        pending[key] = nil
        changed()
    }

    // MARK: An issue

    /// The ticket on its way to the panel (one not on the page yet): the panel keeps what it shows until it lands.
    private var opening: String?

    func open(_ key: String) {
        if detail?.key != key {
            if let known = (issues + mine + recent).first(where: { $0.key == key }) {
                detail = known
                comments = []
                transitions = []
                linkedBranches = []
            } else {
                opening = key
            }
        }
        loadingDetail = true
        changed()
        api.issue(key, storyPointsField: config?.storyPointsField) { [weak self] r in
            guard let self, self.detail?.key == key || self.opening == key else { return }
            self.loadingDetail = false
            switch r {
            case .success(let i):
                if self.detail?.key != key { self.comments = []; self.transitions = []; self.linkedBranches = [] }
                self.opening = nil
                self.detail = i
                self.update(i)
                self.loadComments(key)
                self.loadTransitions(key)
                self.loadLinkedBranches(i)
            case .failure(let e):
                if self.opening == key { self.opening = nil; self.say("Couldn't open \(key): \(e.message)", ok: false) }
            }
            self.changed()
        }
        guard detail?.key == key else { return }
        loadComments(key)
        loadTransitions(key)
        if repo != nil, prs.isEmpty { loadPRs() }
    }

    /// Jira's development panel can be off, or the token without access to it: then only the repository's are shown.
    func loadLinkedBranches(_ i: JiraIssue) {
        api.linkedBranches(i.id) { [weak self] r in
            guard self?.detail?.key == i.key, case .success(let l) = r else { return }
            self?.linkedBranches = l
            self?.changed()
        }
    }

    func loadRepoBranches() {
        guard let root = repoRoot else { repoBranches = []; return changed() }
        LocalGit.branches(root) { [weak self] all in
            guard let self, self.repoRoot == root else { return }
            self.repoBranches = all
            self.changed()
        }
    }

    func loadComments(_ key: String) {
        api.comments(key) { [weak self] r in
            guard self?.detail?.key == key, case .success(let l) = r else { return }
            self?.comments = l
            self?.changed()
        }
    }

    func loadTransitions(_ key: String) {
        api.transitions(key) { [weak self] r in
            guard self?.detail?.key == key, case .success(let l) = r else { return }
            self?.transitions = l
            self?.changed()
        }
    }

    func closeDetail() {
        detail = nil
        changed()
    }

    /// An issue's new state, wherever it's listed.
    func update(_ i: JiraIssue) {
        for k in issues.indices where issues[k].key == i.key { issues[k] = i }
        for k in mine.indices where mine[k].key == i.key { mine[k] = i }
        if detail?.key == i.key { detail = i }
    }

    func transition(_ key: String, _ t: JiraTransition) {
        api.transition(key, t.id) { [weak self] e in
            guard let self else { return }
            if let e { return self.say(e.message, ok: false) }
            self.say("\(key) → \(t.to.name)")
            self.refresh(key)
        }
    }

    func assign(_ key: String, to user: JiraUser?) {
        api.assign(key, user?.accountId) { [weak self] e in
            guard let self else { return }
            if let e { return self.say(e.message, ok: false) }
            self.say(user.map { "\(key) assigned to \($0.displayName)" } ?? "\(key) unassigned")
            self.refresh(key)
        }
    }

    func setPriority(_ key: String, _ name: String) {
        api.edit(key, fields: ["priority": ["name": name]]) { [weak self] e in
            if let e { return self?.say(e.message, ok: false) ?? () }
            self?.refresh(key)
        }
    }

    func setType(_ key: String, _ type: JiraIssueType) {
        api.edit(key, fields: ["issuetype": ["id": type.id]]) { [weak self] e in
            if let e { return self?.say("Couldn't make \(key) a \(type.name): \(e.message)", ok: false) ?? () }
            self?.say("\(key) is now a \(type.name)")
            self?.refresh(key)
        }
    }

    /// Fetches `key` again and puts it everywhere it's shown.
    func refresh(_ key: String) {
        api.issue(key, storyPointsField: config?.storyPointsField) { [weak self] r in
            guard let self, case .success(let i) = r else { return }
            self.update(i)
            if self.detail?.key == key { self.loadTransitions(key) }
            self.changed()
        }
    }

    func addComment(_ key: String, _ text: String, done: @escaping (AtlassianError?) -> Void) {
        api.addComment(key, text) { [weak self] r in
            switch r {
            case .success(let c):
                if self?.detail?.key == key { self?.comments.append(c) }
                self?.changed()
                done(nil)
            case .failure(let e): done(e)
            }
        }
    }

    /// The status "Start work" moves a ticket to: the board's first in-progress column, else any in-progress status.
    func startStatusIds() -> [String] {
        if let config {
            // The column after the first that isn't done, by its statuses' category where Jira gave one.
            for col in config.columns.dropFirst() {
                let named = col.name.lowercased()
                if named.contains("progress") || named.contains("doing") { return col.statusIds }
            }
            if config.columns.count > 1 { return config.columns[1].statusIds }
        }
        return transitions.filter { $0.to.category == "indeterminate" }.map(\.to.id)
    }

    // MARK: Pull requests

    /// The repository of the tab's folder, then its pull requests.
    func findRepo(_ dir: String?, then: (() -> Void)? = nil) {
        guard let dir else { repoRoot = nil; repo = nil; branch = nil; changed(); then?(); return }
        LocalGit.repository(at: dir) { [weak self] root, repo, branch in
            guard let self else { return }
            let moved = root != self.repoRoot
            self.repoRoot = root
            self.repo = repo
            self.branch = branch
            if moved { self.prs = []; self.pr = nil }
            self.loadRepoBranches()
            self.changed()
            then?()
        }
    }

    func loadPRs() {
        guard let repo else { prError = nil; return changed() }
        guard api.hasCredentials(.bitbucket) else {
            prError = "Add a Bitbucket API token in the extension's settings to see pull requests."
            return changed()
        }
        guard !loadingPRs else { return }
        loadingPRs = true
        prError = nil
        changed()
        api.pullRequests(repo) { [weak self] r in
            guard let self else { return }
            self.loadingPRs = false
            switch r {
            case .success(let l): self.prs = l
            case .failure(let e): self.prError = e.message
            }
            self.changed()
        }
    }

    var shownPRs: [BitbucketPullRequest] {
        let me = bitbucketMe?.uuid
        switch prFilter {
        case "mine": return prs.filter { $0.author?.uuid == me }
        case "review": return prs.filter { p in p.author?.uuid != me && (p.reviewers.contains { $0.uuid == me } || p.participants.contains { $0.user.uuid == me && $0.isReviewer }) }
        default: return prs
        }
    }

    /// Pull requests in the tab's repository that mention `key` (its branch or title).
    func prs(for key: String) -> [BitbucketPullRequest] { prs.filter { $0.issueKey == key || $0.title.uppercased().contains(key) } }

    func openPR(_ id: Int) {
        guard let repo else { return }
        if pr?.id != id {
            pr = prs.first { $0.id == id }
            prFiles = []
            prComments = []
            prBuilds = []
            collapsedFiles = []
        }
        loadingPR = true
        changed()
        api.pullRequest(repo, id) { [weak self] r in
            guard let self, self.pr == nil || self.pr?.id == id else { return }
            self.loadingPR = false
            switch r {
            case .success(let p):
                self.pr = p
                if let i = self.prs.firstIndex(where: { $0.id == id }) { self.prs[i] = p }
            case .failure(let e): self.say(e.message, ok: false)
            }
            self.changed()
        }
        api.diff(repo, id) { [weak self] r in
            guard self?.pr?.id == id, case .success(let files) = r else { return }
            self?.prFiles = files
            // Big files start folded, so the page opens on what's worth reading.
            self?.collapsedFiles = Set(files.filter { $0.lines.count > 400 || $0.isBinary }.map(\.path))
            self?.changed()
        }
        api.prComments(repo, id) { [weak self] r in
            guard self?.pr?.id == id, case .success(let l) = r else { return }
            self?.prComments = l
            self?.changed()
        }
        api.builds(repo, id) { [weak self] r in
            guard self?.pr?.id == id, case .success(let l) = r else { return }
            self?.prBuilds = l
            self?.changed()
        }
    }

    func closePR() {
        pr = nil
        changed()
    }

    func approve(_ on: Bool) {
        guard let repo, let p = pr else { return }
        api.approve(repo, p.id, on) { [weak self] e in
            if let e { return self?.say(e.message, ok: false) ?? () }
            self?.say(on ? "Approved #\(p.id)" : "Approval taken back")
            self?.openPR(p.id)
        }
    }

    func requestChanges(_ on: Bool) {
        guard let repo, let p = pr else { return }
        api.requestChanges(repo, p.id, on) { [weak self] e in
            if let e { return self?.say(e.message, ok: false) ?? () }
            self?.say(on ? "Changes requested on #\(p.id)" : "Request for changes taken back")
            self?.openPR(p.id)
        }
    }

    func decline() {
        guard let repo, let p = pr else { return }
        api.decline(repo, p.id) { [weak self] e in
            if let e { return self?.say(e.message, ok: false) ?? () }
            self?.say("Declined #\(p.id)")
            self?.pr = nil
            self?.loadPRs()
        }
    }

    /// Fetches the pull request's branch and switches the repository to it.
    func checkout(_ p: BitbucketPullRequest) { checkout(branch: p.source) }

    /// Switches the tab's repository to `name`: the local branch, else one made from origin's (fetched first).
    func checkout(branch name: String) {
        guard let root = repoRoot else { return }
        say("Checking out \(name)…")
        LocalGit.run(root, ["fetch", "origin", name]) { [weak self] f in
            let exists = LocalGit.runNow(root, ["rev-parse", "--verify", "--quiet", "refs/heads/\(name)"]).ok
            let args = exists ? ["checkout", name] : ["checkout", "-b", name, "--track", "origin/\(name)"]
            LocalGit.run(root, args) { o in
                guard let self else { return }
                if o.ok {
                    self.branch = name
                    self.say("On \(name)" + (f.ok ? "" : " (couldn't fetch: \(f.message))"))
                    self.loadRepoBranches()
                } else {
                    self.say("Couldn't check out \(name): \(o.message)", ok: false)
                }
            }
        }
    }
}
