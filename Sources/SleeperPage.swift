import AppKit

// The Sleeper extension's page: your fantasy football leagues above the terminal where Claude runs. My Team,
// Matchup, Standings, Waivers, Trending, Activity and a page per player, with photos, projections under the
// league's own scoring, injuries, and Claude's notes (start / sit / add / drop) from its annotate tool. "Ask Claude"
// sends a ready-made question to Claude Code in this tab (starting it if needed); Claude can bring views up here
// through show_in_solanum (SleeperMCP.swift).

enum SleeperExtension {
    static let id = "sleeper"

    static let info = SolanumExtension(
        id: id,
        name: "Sleeper Fantasy Football",
        pageTitle: "Sleeper",
        publisher: "Solanum",
        version: "1.0.0",
        summary: "Track your Sleeper fantasy football leagues beside Claude Code, and let Claude help set lineups, work the waiver wire and size up trades.",
        categories: ["Sports", "MCP"],
        features: [
            "A Sleeper page beside your terminal: your team slot by slot, this week's matchup, standings, the waiver wire, trending players and league activity, with player photos and injury tags.",
            "Projections and points under each league's own scoring settings (PPR, half, superflex, bonuses), not a generic format.",
            "Ask Claude from the page: best lineup, waiver pickups with FAAB bids, matchup preview, trade targets, or any player.",
            "Claude's advice lands on the page: a summary card and start / sit / add / drop / trade tags on the players it means.",
            "Claude can open views here itself (a player, the waivers, your matchup) while you talk.",
            "Every league you're in, any week of the season; no password, just your Sleeper username.",
        ],
        mcpServer: "sleeper",
        tools: [
            ("get_context", "Who's connected, their leagues, the current week"),
            ("get_roster", "A team's starters, bench, IR with projections"),
            ("get_matchup", "Head-to-head lineups, points and projections"),
            ("get_free_agents", "The waiver wire, best projected first"),
            ("get_trending", "Most added / dropped across Sleeper"),
            ("get_transactions", "Waiver claims, adds, drops, trades"),
            ("get_player", "Bio, injury, weekly points, upcoming schedule"),
            ("compare_players", "Side by side for start/sit and trades"),
            ("get_league / get_scoreboard", "Settings, standings and every score"),
            ("annotate", "Puts Claude's advice on the Sleeper page"),
            ("show_in_solanum", "Brings a view up on the page"),
        ],
        notes: [
            "Sleeper's public API is read-only: Claude reads and advises, and you make the moves (adds, drops, trades, lineups) in the Sleeper app.",
            "Projections and stats come from the same feeds Sleeper's app uses; data refreshes every minute or so while the page is open.",
            "Your username and selected league are kept in ~/.config/solanum/extensions/sleeper.",
        ],
        drawIcon: drawIcon,
        makePage: { SleeperPageView() })

    /// Sleeper's own logo (Support/Sleeper.png), on its tile's rounded corners; a football if it's missing.
    private static let logo = Bundle.main.image(forResource: "Sleeper")

    static func drawIcon(_ r: NSRect) {
        let tile = NSBezierPath(roundedRect: r, xRadius: r.width * 0.22, yRadius: r.width * 0.22)
        guard let logo else { return drawFootball(r, tile) }
        NSGraphicsContext.saveGraphicsState()
        tile.addClip()
        logo.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        NSGraphicsContext.restoreGraphicsState()
    }

    /// A football on a field-green tile.
    private static func drawFootball(_ r: NSRect, _ tile: NSBezierPath) {
        NSGradient(starting: NSColor(srgbRed: 0.10, green: 0.42, blue: 0.30, alpha: 1), ending: NSColor(srgbRed: 0.03, green: 0.20, blue: 0.16, alpha: 1))?
            .draw(in: tile, angle: -90)
        NSGraphicsContext.saveGraphicsState()
        tile.addClip()
        // Yard lines.
        NSColor.white.withAlphaComponent(0.10).setFill()
        for i in 1..<4 { NSRect(x: r.minX + r.width * CGFloat(i) / 4 - 0.5, y: r.minY, width: 1, height: r.height).fill() }
        // The ball, tilted.
        let ctx = NSGraphicsContext.current?.cgContext
        ctx?.saveGState()
        ctx?.translateBy(x: r.midX, y: r.midY)
        ctx?.rotate(by: .pi / 5)
        let w = r.width * 0.70, h = r.height * 0.42
        let ball = NSBezierPath()
        ball.move(to: NSPoint(x: -w / 2, y: 0))
        ball.curve(to: NSPoint(x: w / 2, y: 0), controlPoint1: NSPoint(x: -w / 4, y: h * 0.95), controlPoint2: NSPoint(x: w / 4, y: h * 0.95))
        ball.curve(to: NSPoint(x: -w / 2, y: 0), controlPoint1: NSPoint(x: w / 4, y: -h * 0.95), controlPoint2: NSPoint(x: -w / 4, y: -h * 0.95))
        NSGradient(starting: NSColor(srgbRed: 0.72, green: 0.40, blue: 0.20, alpha: 1), ending: NSColor(srgbRed: 0.45, green: 0.22, blue: 0.10, alpha: 1))?
            .draw(in: ball, angle: -90)
        NSColor.white.withAlphaComponent(0.92).setStroke()
        let lace = NSBezierPath()
        lace.lineWidth = max(1, r.width * 0.025)
        lace.move(to: NSPoint(x: -w * 0.18, y: 0))
        lace.line(to: NSPoint(x: w * 0.18, y: 0))
        for i in -2...2 {
            let x = CGFloat(i) * w * 0.07
            lace.move(to: NSPoint(x: x, y: -h * 0.12))
            lace.line(to: NSPoint(x: x, y: h * 0.12))
        }
        lace.stroke()
        // The stripes near the tips.
        NSColor.white.withAlphaComponent(0.85).setStroke()
        for side: CGFloat in [-1, 1] {
            let s = NSBezierPath()
            s.lineWidth = max(1, r.width * 0.03)
            s.move(to: NSPoint(x: side * w * 0.33, y: -h * 0.30))
            s.line(to: NSPoint(x: side * w * 0.33, y: h * 0.30))
            s.stroke()
        }
        ctx?.restoreGState()
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: Messages from the MCP server

    private static var observers: [NSObjectProtocol] = []

    static func start() {
        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(forName: Sleeper.showNotification, object: nil, queue: .main) { note in
            let info = (note.userInfo as? [String: String]) ?? [:]
            guard Extensions.isInstalled(id), let page = page(near: info["ppid"]) else { return }
            if info["reload"] != nil { page.model.reloadSettings() }
            page.navigate(info)
        })
        observers.append(center.addObserver(forName: Sleeper.adviceNotification, object: nil, queue: .main) { note in
            guard Extensions.isInstalled(id) else { return }
            let info = (note.userInfo as? [String: String]) ?? [:]
            let pages = Extensions.openPages(id).compactMap { $0.editor.pageView as? SleeperPageView }
            pages.forEach { $0.model.reloadAdvice() }
            // Bring the notes up beside the Claude that wrote them.
            if let near = page(near: info["ppid"]) {
                near.model.reloadAdvice()
                near.scrollToTop()
            }
        })
    }

    /// The page in the tab of the Claude Code that sent a message (its MCP server's parent), opened there without
    /// taking the focus if need be; else any open page; else one in the frontmost tab.
    private static func page(near ppid: String?) -> SleeperPageView? {
        if let ppid, let pid = pid_t(ppid), let tab = Extensions.tab(runningPID: pid) {
            let ed = Extensions.showPage(id, in: tab, focus: false)
            return ed?.pageView as? SleeperPageView
        }
        if let open = Extensions.openPages(id).first {
            if let i = open.tab.editors.firstIndex(of: open.editor), open.tab.editor !== open.editor { open.tab.activateEditor(i, focus: false) }
            return open.editor.pageView as? SleeperPageView
        }
        return Extensions.showPage(id, in: nil, focus: false)?.pageView as? SleeperPageView
    }
}

// MARK: Model

enum SleeperSection: String, CaseIterable {
    case team, matchup, standings, waivers, trending, activity, player

    var title: String {
        switch self {
        case .team: return "My Team"
        case .matchup: return "Matchup"
        case .standings: return "Standings"
        case .waivers: return "Waivers"
        case .trending: return "Trending"
        case .activity: return "Activity"
        case .player: return "Player"
        }
    }
}

final class SleeperModel {
    var settings = Sleeper.loadSettings()
    private(set) var leagues: [SleeperLeague] = []
    private(set) var snapshot: SleeperLeagueSnapshot?
    private(set) var state: SleeperNFLState?
    /// The week shown; nil follows the current one.
    var week: Int?
    private(set) var transactions: [SleeperTransaction] = []
    private(set) var trendingAdds: [(id: String, count: Int)] = []
    private(set) var trendingDrops: [(id: String, count: Int)] = []
    private(set) var advice: Sleeper.Advice? = Sleeper.loadAdvice()
    /// The player page's data: weekly points and projections (`loaded` once they've come back, empty or not).
    private(set) var playerWeeks: (id: String, stats: [Int: SleeperStatLine], proj: [Int: SleeperStatLine], loaded: Bool)?
    /// A player page opened before the league (and so the season) was known: loaded once it is.
    private var pendingPlayer: String?
    private(set) var loading = false
    private(set) var connecting = false
    private(set) var error: String?
    /// Which team "My Team" shows (another team's, from Standings); nil for the user's.
    var viewedRoster: Int?
    var onChange: (() -> Void)?
    private var generation = 0
    private var lastLoad = Date.distantPast

    var connected: Bool { settings.userId != nil }
    var league: SleeperLeague? { snapshot?.league ?? leagues.first { $0.id == settings.leagueId } }

    func reloadSettings() {
        settings = Sleeper.loadSettings()
        load(force: true)
    }

    func reloadAdvice() {
        advice = Sleeper.loadAdvice()
        onChange?()
    }

    func dismissAdvice() {
        advice = nil
        Sleeper.saveAdvice(nil)
        onChange?()
    }

    /// Advice that belongs on this league's page (or wasn't tied to one).
    /// Claude's notes, when they're about the league and week showing (last week's "sit: bye" isn't this week's).
    var shownAdvice: Sleeper.Advice? {
        guard let a = advice else { return nil }
        if let l = a.leagueId, let cur = settings.leagueId, l != cur { return nil }
        if let w = a.week, let shown = snapshot?.week, w != shown { return nil }
        return a
    }

    func connect(_ username: String) {
        let name = username.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        connecting = true
        error = nil
        onChange?()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let u = try Sleeper.user(name)
                let state = try Sleeper.state()
                let leagues = try Sleeper.leagues(userId: u.id, season: state.season)
                var s = Sleeper.Settings(username: u.username, userId: u.id, displayName: u.displayName, avatar: u.avatar, leagueId: nil)
                s.leagueId = leagues.first?.id
                Sleeper.saveSettings(s)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.connecting = false
                    self.settings = s
                    self.leagues = leagues
                    self.load(force: true)
                }
            } catch {
                DispatchQueue.main.async {
                    self?.connecting = false
                    self?.error = error.localizedDescription
                    self?.onChange?()
                }
            }
        }
    }

    func disconnect() {
        settings = Sleeper.Settings()
        Sleeper.saveSettings(settings)
        snapshot = nil
        leagues = []
        onChange?()
    }

    func selectLeague(_ id: String) {
        guard id != settings.leagueId else { return }
        settings.leagueId = id
        Sleeper.saveSettings(settings)
        snapshot = nil
        week = nil
        viewedRoster = nil
        load(force: true)
    }

    /// Fetches everything the page shows, in the background. Without `force`, at most every 20 seconds.
    func load(force: Bool = false) {
        guard let uid = settings.userId else { onChange?(); return }
        if !force, Date().timeIntervalSince(lastLoad) < 20 { return }
        if force { Sleeper.clearCache() }
        lastLoad = Date()
        generation += 1
        let gen = generation
        loading = true
        error = nil
        onChange?()
        let leagueId = settings.leagueId, week = self.week
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let state = try Sleeper.state()
                let leagues = try Sleeper.leagues(userId: uid, season: state.season)
                let lid = leagueId.flatMap { id in leagues.contains { $0.id == id } ? id : nil } ?? leagues.first?.id
                var snap: SleeperLeagueSnapshot?
                var tx: [SleeperTransaction] = []
                if let lid {
                    let s = try SleeperLeagueSnapshot.load(leagueId: lid, week: week, userId: uid)
                    snap = s
                    for w in [s.week, s.week - 1, s.week - 2] where w >= 1 { tx += (try? Sleeper.transactions(lid, week: w)) ?? [] }
                }
                let adds = (try? Sleeper.trending("add", hours: 24, limit: 30)) ?? []
                let drops = (try? Sleeper.trending("drop", hours: 24, limit: 30)) ?? []
                DispatchQueue.main.async {
                    guard let self, gen == self.generation else { return }
                    self.state = state
                    self.leagues = leagues
                    if self.settings.leagueId != lid {
                        self.settings.leagueId = lid
                        Sleeper.saveSettings(self.settings)
                    }
                    self.snapshot = snap
                    if let p = self.pendingPlayer {
                        self.pendingPlayer = nil
                        self.playerWeeks = nil
                        self.loadPlayer(p)
                    }
                    self.transactions = tx.filter { $0.status == "complete" }.sorted { $0.created > $1.created }
                    self.trendingAdds = adds
                    self.trendingDrops = drops
                    self.loading = false
                    if leagues.isEmpty { self.error = "\(self.settings.displayName ?? "This account") isn't in any NFL leagues for \(state.season)." }
                    self.onChange?()
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self, gen == self.generation else { return }
                    self.loading = false
                    self.error = error.localizedDescription
                    self.onChange?()
                }
            }
        }
    }

    func loadPlayer(_ id: String) {
        guard playerWeeks?.id != id else { return }
        playerWeeks = (id, [:], [:], false)
        onChange?()
        let season = snapshot.map { $0.league.season.isEmpty ? $0.state.season : $0.league.season } ?? state?.season ?? ""
        // Opened before the league came in (Claude's show_in_solanum as the page opens): asking for an unknown
        // season gets nothing back, which used to leave the page loading for good.
        guard !season.isEmpty else { pendingPlayer = id; return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let stats = (try? Sleeper.playerWeeks(id, season: season, projected: false)) ?? [:]
            let proj = (try? Sleeper.playerWeeks(id, season: season, projected: true)) ?? [:]
            DispatchQueue.main.async {
                guard let self, self.playerWeeks?.id == id else { return }
                self.playerWeeks = (id, stats, proj, true)
                self.onChange?()
            }
        }
    }
}

// MARK: The page

final class SleeperPageView: NSView, ExtensionPage {
    let model = SleeperModel()
    private let header = SleeperHeader()
    private let content = SleeperContent()
    private let scroll: CanvasScroll
    private let setup = SleeperSetupView()
    private var timer: Timer?
    var onSubtitleChanged: (() -> Void)?

    var subtitle: String {
        guard model.connected else { return "Sleeper · connect your account" }
        guard let l = model.league else { return "Sleeper · \(model.settings.displayName ?? "")" }
        return "Sleeper · \(l.name) · Week \(model.snapshot?.week ?? model.state?.displayWeek ?? 1)"
    }

    var focusView: NSView { model.connected ? content : setup.field }

    override init(frame: NSRect) {
        scroll = CanvasScroll(content)
        super.init(frame: frame)
        header.page = self
        content.page = self
        setup.model = model
        addSubview(header)
        addSubview(scroll)
        addSubview(setup)
        model.onChange = { [weak self] in self?.modelChanged() }
        modelChanged()
        model.load(force: false)
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit { timer?.invalidate() }

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        timer = nil
        guard window != nil else { return }
        model.load()
        // Live scores on game days; otherwise cheap (answers are cached for a minute).
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self, NSApp.isActive, self.window?.isVisible == true, !self.isHiddenOrHasHiddenAncestor else { return }
            self.model.load()
        }
        timer?.tolerance = 10
    }

    private func modelChanged() {
        setup.isHidden = model.connected
        header.isHidden = !model.connected
        scroll.isHidden = !model.connected
        setup.needsDisplay = true
        setup.needsLayout = true
        header.needsDisplay = true
        scroll.refit()
        onSubtitleChanged?()
    }

    override func layout() {
        super.layout()
        header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: SleeperHeader.height)
        scroll.frame = NSRect(x: 0, y: header.frame.maxY, width: bounds.width, height: max(0, bounds.height - header.frame.maxY))
        setup.frame = bounds
        scroll.refit()
    }

    func applyTheme() {
        header.needsDisplay = true
        setup.applyTheme()
        scroll.refit()
    }

    func scrollToTop() { scroll.scrollToTop() }

    // MARK: Navigation

    var section: SleeperSection = .team {
        didSet {
            guard section != oldValue else { return }
            if section != .player { previous = section }
            header.needsDisplay = true
            scroll.refit()
            scroll.scrollToTop()
        }
    }
    private(set) var previous: SleeperSection = .team
    var playerId: String?
    var waiverPosition = "ALL" { didSet { scroll.refit() } }

    /// A section; the user's own team in it unless `keepRoster` (another team's matchup, from the scoreboard).
    func show(_ s: SleeperSection, keepRoster: Bool = false) {
        if !keepRoster { model.viewedRoster = nil }
        section = s
        header.needsDisplay = true
        scroll.refit()
    }

    func showPlayer(_ id: String) {
        playerId = id
        model.loadPlayer(id)
        if section == .player { scroll.refit(); scroll.scrollToTop() } else { section = .player }
    }

    func showTeam(_ rosterId: Int?) {
        model.viewedRoster = rosterId == model.snapshot?.myRosterId ? nil : rosterId
        if section == .team { scroll.refit(); scroll.scrollToTop() } else { section = .team }
    }

    func back() { section = previous }

    /// From Claude's show_in_solanum (see SleeperExtension.start).
    func navigate(_ info: [String: String]) {
        if let l = info["league_id"], l != model.settings.leagueId { model.selectLeague(l) }
        if let w = info["week"].flatMap(Int.init), w != model.snapshot?.week { model.week = w; model.load(force: true) }
        switch info["view"] ?? "" {
        case "player": if let p = info["player_id"] { showPlayer(p) }
        case "matchup":
            model.viewedRoster = info["roster_id"].flatMap(Int.init)
            show(.matchup, keepRoster: true)
        case "standings": show(.standings)
        case "waivers":
            if let pos = info["position"], ["ALL", "QB", "RB", "WR", "TE", "K", "DEF", "FLEX"].contains(pos) { waiverPosition = pos }
            show(.waivers)
        case "trending": show(.trending)
        case "activity": show(.activity)
        default: showTeam(info["roster_id"].flatMap(Int.init))
        }
    }

    // MARK: Asking Claude

    /// "“Dynasty Bros” (Sleeper league 1234…)", for prompts.
    private var leagueRef: String {
        guard let l = model.league else { return "my Sleeper league" }
        return "my Sleeper league “\(l.name)” (league_id \(l.id))"
    }
    private var weekNumber: Int { model.snapshot?.week ?? model.state?.displayWeek ?? 1 }

    func ask(_ prompt: String, submit: Bool = true) {
        ExtensionChat.ask(prompt, from: self, submit: submit)
    }

    /// The header's Ask Claude menu.
    var suggestions: [(title: String, symbol: String, prompt: String?)] {
        let w = weekNumber, ref = leagueRef
        let tail = " Use the sleeper MCP tools. When you're done, call annotate to put your recommendations on my Solanum Sleeper page"
        return [
            ("Set my best lineup for week \(w)", "list.number",
             "Set my best lineup for week \(w) in \(ref). Check projections, matchups, injuries and byes for my starters and bench, and tell me who to start and sit and why." + tail + " (tag start/sit), and show_in_solanum view=team."),
            ("Who should I pick up?", "plus.circle",
             "Look at the waiver wire in \(ref) for week \(w). Who are the best pickups for my roster's needs, who should I drop for each, and how much FAAB should I bid (or is it worth my waiver priority)?" + tail + " (tag add/drop), and show_in_solanum view=waivers."),
            ("Preview my matchup", "person.2",
             "Preview my week \(w) matchup in \(ref): compare both lineups slot by slot, the projected totals, the key players and risks, and anything I could change to improve my odds." + tail + ", and show_in_solanum view=matchup."),
            ("Find trade targets", "arrow.left.arrow.right",
             "Find realistic trade targets for me in \(ref). Look at my roster's strengths and weaknesses, other teams' needs and depth, and suggest a few specific, fair offers (who I give, who I get, why they'd accept)." + tail + " (tag trade)."),
            ("How's my team looking?", "chart.bar",
             "Give me an honest assessment of my team in \(ref): record and points vs the league, position-by-position strengths and weaknesses, injury risks, playoff outlook, and the top 3 things I should do this week." + tail + "."),
            ("Ask something else…", "text.bubble", nil),
        ]
    }

    func askPlayer(_ p: SleeperPlayer) {
        guard let s = model.snapshot else { return }
        let who = "\(p.name) (\(p.positionTeam))"
        let mine = s.myRosterId
        if let r = s.rosterOf(p.id) {
            if r.rosterId == mine {
                ask("Should I start \(who) in week \(s.week) in \(leagueRef)? Compare him with my other options at his position (projections, matchup, recent usage, injuries), then annotate the Solanum Sleeper page with start/sit tags.")
            } else {
                ask("Is \(who) worth trading for in \(leagueRef)? He's on \(s.teamName(r)). Who on my roster could I realistically offer, and what would be fair? Annotate the Solanum Sleeper page with trade tags.")
            }
        } else {
            ask("Should I pick up \(who) in \(leagueRef)? Compare him with my current players at his position, tell me who I'd drop, and how much FAAB to bid if it's a FAAB league. Annotate the Solanum Sleeper page with add/drop tags.")
        }
    }

    func askCustom() {
        ask("About \(leagueRef): ", submit: false)
    }
}

// MARK: Header

final class SleeperHeader: PageCanvas, DropdownAnchor {
    static let height: CGFloat = 94
    weak var page: SleeperPageView?
    var dropdownWanted: Bool { true }
    var dropdownOpen = false { didSet { needsDisplay = true } }
    private var leagueRect: NSRect = .zero
    private var askRect: NSRect = .zero
    private var userRect: NSRect = .zero

    override func render() -> CGFloat {
        guard let page else { return 0 }
        let model = page.model
        let w = bounds.width, pad: CGFloat = 20
        // The window chrome's own tint, as the theme sets it (a fixed alpha here made it solid lavender on light themes).
        fill(NSRect(x: 0, y: 0, width: w, height: Self.height), th.tabBarTint)
        line(Self.height - 1, from: 0, to: w)

        // League: avatar, name ▾, settings.
        let l = model.league
        let av = NSRect(x: pad, y: 12, width: 38, height: 38)
        if l?.avatarURL != nil { avatar(l?.avatarURL, av, initials: PageCanvas.initials(l?.name ?? "")) }
        else if visible(av) { SleeperExtension.drawIcon(av) }
        let nameFont = NSFont.systemFont(ofSize: 15, weight: .semibold)
        let name = l?.name ?? (model.loading ? "Loading…" : "No league")
        let maxNameW = max(80, w - 520)
        let nw = min(maxNameW, PageCanvas.textWidth(name, nameFont))
        leagueRect = NSRect(x: av.maxX + 8, y: 10, width: nw + 30, height: 24)
        if hover == "league" || dropdownOpen { fill(leagueRect, th.foreground.withAlphaComponent(0.08), radius: 6) }
        text(name, nameFont, th.foreground, x: leagueRect.minX + 6, y: 13, width: nw)
        symbol("chevron.down", NSRect(x: leagueRect.minX + nw + 10, y: 13, width: 14, height: 18), th.dimText, size: 9, weight: .bold)
        if model.leagues.count > 0 { hit(leagueRect, "league") { [weak self] in self?.showLeagues() } }
        if let l {
            var parts = [l.scoringName, "\(l.totalRosters) teams"]
            if l.isSuperflex { parts.append("Superflex") }
            parts.append(l.usesFAAB ? "FAAB $\(l.waiverBudget)" : "Waiver order")
            if l.status == "in_season", let s = model.snapshot, l.playoffWeekStart > 0 {
                parts.append(s.week >= l.playoffWeekStart ? "Playoffs" : "Playoffs wk \(l.playoffWeekStart)")
            }
            text(parts.joined(separator: " · "), .systemFont(ofSize: 11.5), th.dimText, x: leagueRect.minX + 6, y: 35, width: maxNameW + 120)
        }

        // Right: Ask Claude, refresh, week.
        var x = w - pad
        let askW = button("Ask Claude", id: "ask", x: x, y: 14, height: 30, symbol: "sparkles", style: .primary, rightAligned: true) { [weak self] in
            self?.showAsk()
        }
        askRect = NSRect(x: x - askW, y: 14, width: askW, height: 30)
        x -= askW + 8
        let rw = button("", id: "refresh", x: x, y: 14, height: 30, symbol: model.loading ? "hourglass" : "arrow.clockwise", style: .secondary,
                        rightAligned: true) { [weak page] in page?.model.load(force: true) }
        x -= rw + 14
        if let s = model.snapshot {
            let font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
            let label = "Week \(s.week)"
            let lw = PageCanvas.textWidth(label, font) + 12
            let next = NSRect(x: x - 26, y: 16, width: 26, height: 26)
            let lab = NSRect(x: next.minX - lw, y: 16, width: lw, height: 26)
            let prev = NSRect(x: lab.minX - 26, y: 16, width: 26, height: 26)
            fill(NSRect(x: prev.minX, y: 16, width: next.maxX - prev.minX, height: 26), th.foreground.withAlphaComponent(0.06), radius: 7)
            for (r, sym, id, d) in [(prev, "chevron.left", "prev", -1), (next, "chevron.right", "next", 1)] {
                let enabled = (1...18).contains(s.week + d)
                if hover == id && enabled { fill(r, th.foreground.withAlphaComponent(0.08), radius: 7) }
                symbol(sym, r, enabled ? th.foreground : th.dimText.withAlphaComponent(0.4), size: 10, weight: .bold)
                if enabled { hit(r, id) { [weak page] in page?.model.week = s.week + d; page?.model.load(force: true) } }
            }
            text(label, font, s.week == s.state.displayWeek ? th.foreground : th.accent, x: lab.minX, y: lab.minY + 5, width: lab.width, align: .center)
            if s.week != s.state.displayWeek {
                hit(lab, "thisweek") { [weak page] in page?.model.week = nil; page?.model.load(force: true) }
            }
        }

        // Sections.
        var tx = pad - 6
        let ty: CGFloat = 60
        let sections = SleeperSection.allCases.filter { $0 != .player || page.section == .player }
        for s in sections {
            let font = NSFont.systemFont(ofSize: 12.5, weight: page.section == s ? .semibold : .medium)
            var title = s.title
            if s == .team, let rid = model.viewedRoster, let snap = model.snapshot, rid != snap.myRosterId {
                title = snap.teamName(rosterId: rid)
            }
            if s == .player, let id = page.playerId { title = model.snapshot?.player(id).name ?? "Player" }
            let tw = min(180, PageCanvas.textWidth(title, font)) + 20
            let r = NSRect(x: tx, y: ty, width: tw, height: 30)
            let active = page.section == s
            if hover == "tab." + s.rawValue && !active { fill(r.insetBy(dx: 0, dy: 3), th.foreground.withAlphaComponent(0.06), radius: 6) }
            text(title, font, active ? th.foreground : th.dimText, x: r.minX + 10, y: r.minY + 7, width: tw - 20)
            if active { fill(NSRect(x: r.minX + 8, y: Self.height - 3, width: tw - 16, height: 2.5), th.accent, radius: 1.25) }
            hit(r, "tab." + s.rawValue) { [weak page] in
                if s == .team { page?.showTeam(nil) } else { page?.show(s) }
            }
            tx += tw + 2
        }

        // The account, at the right of the sections.
        let uname = model.settings.displayName ?? model.settings.username ?? ""
        let uf = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        let uw = min(180, PageCanvas.textWidth(uname, uf)) + 38
        userRect = NSRect(x: w - pad - uw, y: ty + 3, width: uw, height: 24)
        if userRect.minX > tx + 8 {
            if hover == "user" { fill(userRect, th.foreground.withAlphaComponent(0.07), radius: 12) }
            avatar(model.settings.avatar.flatMap { URL(string: "https://sleepercdn.com/avatars/thumbs/\($0)") },
                   NSRect(x: userRect.minX + 3, y: userRect.minY + 3, width: 18, height: 18), initials: PageCanvas.initials(uname))
            text(uname, uf, th.dimText, x: userRect.minX + 26, y: userRect.minY + 4, width: uw - 30)
            hit(userRect, "user") { [weak self] in self?.showAccount() }
        }
        return Self.height
    }

    private func showLeagues() {
        guard let page else { return }
        let m = page.model
        let items = m.leagues.map { l in
            DropdownItem.item(l.name, checked: l.id == m.settings.leagueId, detail: "\(l.scoringName) · \(l.totalRosters) teams") { [weak page] in
                page?.model.selectLeague(l.id)
            }
        }
        ThemedDropdown.show([.header("\(m.state?.season ?? "") leagues")] + items, under: self, rect: leagueRect, minWidth: 300, placeholder: "Filter leagues",
                            searchable: items.count > 6)
    }

    private func showAsk() {
        guard let page else { return }
        var items: [DropdownItem] = [.header("Ask Claude in this tab")]
        for s in page.suggestions {
            items.append(.item(s.title, symbol: s.symbol) { [weak page] in
                if let p = s.prompt { page?.ask(p) } else { page?.askCustom() }
            })
        }
        ThemedDropdown.show(items, under: self, rect: askRect, minWidth: 280, searchable: false)
    }

    private func showAccount() {
        guard let page else { return }
        let items: [DropdownItem] = [
            .header(page.model.settings.username.map { "@" + $0 } ?? "Sleeper"),
            .item("Refresh", symbol: "arrow.clockwise") { [weak page] in page?.model.load(force: true) },
            .item("Open in Sleeper", symbol: "safari") { [weak page] in
                guard let id = page?.model.settings.leagueId, let url = URL(string: "https://sleeper.com/leagues/\(id)") else { return }
                if Headless.active { FileHandle.standardError.write("headless: open \(url)\n".data(using: .utf8)!) } else { NSWorkspace.shared.open(url) }
            },
            .separator,
            .item("Switch Account…", symbol: "person.crop.circle") { [weak page] in page?.model.disconnect() },
        ]
        ThemedDropdown.show(items, under: self, rect: userRect, minWidth: 220, searchable: false)
    }
}

// MARK: Connecting an account

final class SleeperSetupView: NSView {
    weak var model: SleeperModel?
    let field = ThemedField("", placeholder: "Sleeper username", mono: false)
    private let canvas = SetupCanvas()

    override init(frame: NSRect) {
        super.init(frame: frame)
        canvas.setup = self
        addSubview(canvas)
        addSubview(field)
        field.target = self
        field.action = #selector(connect)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    func applyTheme() {
        let th = Config.shared.theme
        field.textColor = th.foreground
        field.layer?.backgroundColor = th.background.withAlphaComponent(0.6).cgColor
        canvas.needsDisplay = true
    }

    @objc func connect() {
        model?.connect(field.stringValue)
    }

    var cardRect: NSRect {
        let w = min(520, bounds.width - 40)
        return NSRect(x: (bounds.width - w) / 2, y: max(24, bounds.height * 0.12), width: w, height: 330)
    }

    override func layout() {
        super.layout()
        canvas.frame = bounds
        let c = cardRect
        field.frame = NSRect(x: c.minX + 28, y: c.minY + 200, width: c.width - 56 - 110, height: 32)
        canvas.needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {}
}

final class SetupCanvas: PageCanvas {
    weak var setup: SleeperSetupView?

    override func render() -> CGFloat {
        guard let setup else { return 0 }
        let c = setup.cardRect
        fill(c, th.surface.withAlphaComponent(0.7), radius: 16)
        stroke(c, th.border, radius: 16)
        let icon = NSRect(x: c.minX + 28, y: c.minY + 28, width: 56, height: 56)
        if visible(icon) { SleeperExtension.drawIcon(icon) }
        text("Connect Sleeper", .systemFont(ofSize: 20, weight: .bold), th.foreground, x: icon.maxX + 16, y: c.minY + 34, width: c.width - 120)
        text("Fantasy football, beside Claude Code", .systemFont(ofSize: 12.5), th.dimText, x: icon.maxX + 16, y: c.minY + 60, width: c.width - 120)
        paragraph("Enter your Sleeper username to see your leagues, roster, matchups and the waiver wire here, and let Claude help you manage your teams. No password needed: Sleeper's API is public and read-only, so Claude advises and you make moves in the Sleeper app.",
                  .systemFont(ofSize: 12.5), th.foreground.withAlphaComponent(0.85), x: c.minX + 28, y: c.minY + 104, width: c.width - 56)
        let model = setup.model
        let busy = model?.connecting == true
        button(busy ? "Connecting…" : "Connect", id: "connect", x: c.maxX - 28, y: c.minY + 200, height: 32, style: .primary, rightAligned: true,
               enabled: !busy) { [weak setup] in setup?.connect() }
        if let e = model?.error {
            symbol("exclamationmark.triangle.fill", NSRect(x: c.minX + 28, y: c.minY + 246, width: 16, height: 16), th.red, size: 11)
            paragraph(e, .systemFont(ofSize: 12), th.red, x: c.minX + 50, y: c.minY + 246, width: c.width - 78, maxLines: 2)
        } else {
            text("Your username is in the Sleeper app under Settings › Account.", .systemFont(ofSize: 11.5), th.dimText,
                 x: c.minX + 28, y: c.minY + 248, width: c.width - 56)
        }
        if !Extensions.isInstalled(SleeperExtension.id) {
            text("Install the extension in Extensions (⇧⌘X) to give Claude its tools.", .systemFont(ofSize: 11.5), th.yellow,
                 x: c.minX + 28, y: c.minY + 290, width: c.width - 56)
        }
        return bounds.height
    }
}

// MARK: Content

final class SleeperContent: PageCanvas {
    weak var page: SleeperPageView?
    /// The page's grid: cards and rows' hover fills reach `pad` from the sides; everything in them (section labels,
    /// avatars, slot pills, separators, and every number at the right) lines up `inset` further in.
    private let pad: CGFloat = 20
    private let inset: CGFloat = 10
    private var left: CGFloat { pad + inset }
    private var rightEdge: CGFloat { bounds.width - pad - inset }

    private var model: SleeperModel? { page?.model }

    override func render() -> CGFloat {
        guard let page, let model else { return 0 }
        let w = bounds.width
        var y: CGFloat = 16
        if let e = model.error {
            let h = paragraphHeight(e, width: w - pad * 2 - 40, font: .systemFont(ofSize: 12.5)) + 20
            fill(NSRect(x: pad, y: y, width: w - pad * 2, height: h), th.red.withAlphaComponent(0.12), radius: 8)
            symbol("exclamationmark.triangle.fill", NSRect(x: pad + 10, y: y + 10, width: 16, height: 16), th.red, size: 12)
            paragraph(e, .systemFont(ofSize: 12.5), th.foreground, x: pad + 34, y: y + 10, width: w - pad * 2 - 44)
            y += h + 14
        }
        guard let s = model.snapshot else {
            text(model.loading ? "Loading your league…" : "Nothing to show yet.", .systemFont(ofSize: 13), th.dimText, x: pad, y: y + 20, width: w - pad * 2, align: .center)
            return y + 80
        }
        if page.section != .player, let a = model.shownAdvice { y = adviceCard(a, s, y: y) + 16 }
        switch page.section {
        case .team: y = team(s, y: y)
        case .matchup: y = matchup(s, y: y)
        case .standings: y = standings(s, y: y)
        case .waivers: y = waivers(s, y: y)
        case .trending: y = trending(s, y: y)
        case .activity: y = activity(s, y: y)
        case .player: y = player(s, y: y)
        }
        return y + 30
    }

    // MARK: Pieces

    static func positionColor(_ pos: String) -> NSColor {
        switch pos {
        case "QB": return NSColor(srgbRed: 0.94, green: 0.42, blue: 0.55, alpha: 1)
        case "RB": return NSColor(srgbRed: 0.20, green: 0.80, blue: 0.62, alpha: 1)
        case "WR": return NSColor(srgbRed: 0.33, green: 0.68, blue: 0.96, alpha: 1)
        case "TE": return NSColor(srgbRed: 0.96, green: 0.63, blue: 0.31, alpha: 1)
        case "K": return NSColor(srgbRed: 0.70, green: 0.56, blue: 0.96, alpha: 1)
        case "DEF": return NSColor(srgbRed: 0.68, green: 0.55, blue: 0.43, alpha: 1)
        default: return NSColor(srgbRed: 0.62, green: 0.64, blue: 0.70, alpha: 1)
        }
    }

    private func tagColor(_ tag: String) -> NSColor {
        switch tag {
        case "start": return th.green
        case "sit", "drop": return th.red
        case "add": return th.accent
        case "trade": return th.yellow
        default: return th.ansi[4]
        }
    }

    private func injuryColor(_ short: String) -> NSColor { ["Q", "D"].contains(short) ? th.yellow : th.red }

    private func sectionLabel(_ title: String, y: CGFloat, right: String? = nil) -> CGFloat {
        text(title.uppercased(), .systemFont(ofSize: 10.5, weight: .bold), th.dimText, x: left, y: y, width: rightEdge - left)
        if let right {
            text(right, .systemFont(ofSize: 10.5, weight: .semibold), th.dimText.withAlphaComponent(0.8), x: left, y: y, width: rightEdge - left, align: .right)
        }
        return y + 20
    }

    private func paragraphHeight(_ s: String, width: CGFloat, font: NSFont) -> CGFloat {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byWordWrapping
        p.lineSpacing = 2
        return ceil((s as NSString).boundingRect(with: NSSize(width: max(1, width), height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin],
                                                 attributes: [.font: font, .paragraphStyle: p]).height)
    }

    /// Claude's summary, at the top.
    private func adviceCard(_ a: Sleeper.Advice, _ s: SleeperLeagueSnapshot, y: CGFloat) -> CGFloat {
        let w = bounds.width - pad * 2
        let body = paragraphHeight(a.summary, width: w - 60, font: .systemFont(ofSize: 12.5))
        let tags = a.notes.prefix(8)
        let tagRows = tags.isEmpty ? 0 : 1
        let h = 44 + body + CGFloat(tagRows) * 30 + 12
        let r = NSRect(x: pad, y: y, width: w, height: h)
        fill(r, th.accent.withAlphaComponent(th.isDark ? 0.10 : 0.07), radius: 12)
        stroke(r, th.accent.withAlphaComponent(0.45), radius: 12)
        symbol("sparkles", NSRect(x: r.minX + 14, y: r.minY + 14, width: 18, height: 18), th.accent, size: 13, weight: .semibold)
        let title = "Claude" + (a.title.map { " · \($0)" } ?? "")
        text(title, .systemFont(ofSize: 13, weight: .semibold), th.foreground, x: r.minX + 40, y: r.minY + 14, width: w - 160)
        text(PageCanvas.ago(a.updated), .systemFont(ofSize: 11), th.dimText, x: r.maxX - 140, y: r.minY + 15, width: 100, align: .right)
        let close = NSRect(x: r.maxX - 34, y: r.minY + 10, width: 24, height: 24)
        if hover == "advice.close" { fill(close, th.foreground.withAlphaComponent(0.08), radius: 6) }
        symbol("xmark", close, th.dimText, size: 10, weight: .bold)
        hit(close, "advice.close") { [weak self] in self?.model?.dismissAdvice() }
        paragraph(a.summary, .systemFont(ofSize: 12.5), th.foreground.withAlphaComponent(0.92), x: r.minX + 40, y: r.minY + 38, width: w - 60)
        if !tags.isEmpty {
            var x = r.minX + 40
            let ty = r.minY + 44 + body + 4
            for n in tags {
                let p = s.player(n.playerId)
                let label = "\(n.tag.uppercased())  \(p.name)"
                let f = NSFont.systemFont(ofSize: 11, weight: .semibold)
                let pw = PageCanvas.textWidth(label, f) + 34
                guard x + pw < r.maxX - 10 else { break }
                let pr = NSRect(x: x, y: ty, width: pw, height: 22)
                let c = tagColor(n.tag)
                fill(pr, c.withAlphaComponent(hover == "advtag." + n.playerId ? 0.30 : 0.18), radius: 11)
                avatar(p.photoURL, NSRect(x: pr.minX + 3, y: pr.minY + 3, width: 16, height: 16), fit: p.isDefense)
                text(label, f, th.isDark ? th.foreground : c.mix(.black, 0.4), x: pr.minX + 24, y: pr.minY + 4, width: pw - 28)
                hit(pr, "advtag." + n.playerId) { [weak page] in page?.showPlayer(n.playerId) }
                x += pw + 6
            }
        }
        return y + h
    }

    /// A player row: slot, photo, name, injury, team and opponent, Claude's tag; projection and points at the right.
    private func playerRow(_ id: String, _ s: SleeperLeagueSnapshot, y: CGFloat, slot: String? = nil, points: Double? = nil,
                           extra: String? = nil, extraColor: NSColor? = nil, showProjection: Bool = true) -> CGFloat {
        let w = bounds.width
        if id == "0" || id.isEmpty {
            let r = NSRect(x: pad, y: y, width: w - pad * 2, height: 44)
            if let slot { pill(SleeperLeagueSnapshot.slotName(slot), x: left, y: y + 13, color: Self.positionColor(slot), minWidth: 44) }
            text("Empty", .systemFont(ofSize: 12.5, weight: .medium), th.red, x: left + 52 + 48, y: y + 13, width: 200)
            line(r.maxY, from: left, to: rightEdge, th.border.withAlphaComponent(0.5))
            return r.maxY + 1
        }
        let p = s.player(id)
        let note = model?.shownAdvice?.note(for: id)
        let h: CGFloat = note == nil ? 52 : 70
        let r = NSRect(x: pad, y: y, width: w - pad * 2, height: h)
        let rowId = "row.\(id).\(Int(y))"
        if hover == rowId || hover == "ask.\(id).\(Int(y))" { fill(r, th.foreground.withAlphaComponent(0.05), radius: 8) }
        hit(r, rowId) { [weak page] in page?.showPlayer(id) }
        var x = left
        if let slot {
            let c = ["QB", "RB", "WR", "TE", "K", "DEF"].contains(slot) ? Self.positionColor(slot) : Self.positionColor("FLEX")
            pill(SleeperLeagueSnapshot.slotName(slot), x: x, y: y + 17, color: c, minWidth: 44)
            x += 52
        }
        let photo = NSRect(x: x, y: y + 8, width: 36, height: 36)
        avatar(p.photoURL, photo, initials: PageCanvas.initials(p.name), fit: p.isDefense)
        // A position dot on the photo.
        let dot = NSRect(x: photo.maxX - 10, y: photo.maxY - 10, width: 12, height: 12)
        fill(dot, th.background, radius: 6)
        fill(dot.insetBy(dx: 2, dy: 2), Self.positionColor(p.position), radius: 4)
        x = photo.maxX + 12

        let right = rightEdge
        let colW: CGFloat = 58
        let nameW = right - colW * 2 - 40 - x
        let nf = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let used = text(p.name, nf, th.foreground, x: x, y: y + 9, width: nameW)
        var ix = x + used + 6
        if let inj = p.injuryShort {
            ix += pill(inj, x: ix, y: y + 10, height: 16, color: injuryColor(inj), font: .systemFont(ofSize: 9, weight: .heavy)) + 4
        }
        if let st = p.status, st != "Active", p.injuryShort == nil, !p.isDefense, st != "" {
            pill(st.uppercased(), x: ix, y: y + 10, height: 16, color: th.red, font: .systemFont(ofSize: 9, weight: .heavy))
        }
        var sub = p.positionTeam
        if let opp = s.opponent(id) { sub += " · vs \(opp)" }
        else if p.team != nil, !s.projections.isEmpty, s.projected(id) == nil { sub += " · BYE" }
        if let extra { sub += " · " + extra }
        text(sub, .systemFont(ofSize: 11.5), extraColor ?? th.dimText, x: x, y: y + 28, width: nameW + 20)

        if let note {
            let c = tagColor(note.tag)
            let tw = pill(note.tag.uppercased(), x: x, y: y + 47, height: 16, color: c, filled: true, font: .systemFont(ofSize: 9, weight: .heavy))
            text(note.reason, .systemFont(ofSize: 11.5, weight: .medium), th.isDark ? c.mix(th.foreground, 0.35) : c.mix(.black, 0.35),
                 x: x + tw + 6, y: y + 47, width: right - x - tw - 6)
        }

        // Right columns.
        if let points {
            text(Sleeper.format(points), .monospacedDigitSystemFont(ofSize: 15, weight: .bold), th.foreground, x: right - colW, y: y + 9, width: colW, align: .right)
            text("pts", .systemFont(ofSize: 10), th.dimText, x: right - colW, y: y + 29, width: colW, align: .right)
        }
        if showProjection, let proj = s.projected(id) {
            let px = points == nil ? right - colW : right - colW * 2 - 6
            text(Sleeper.format(proj), .monospacedDigitSystemFont(ofSize: points == nil ? 15 : 13, weight: points == nil ? .bold : .medium),
                 points == nil ? th.foreground : th.dimText, x: px, y: y + (points == nil ? 9 : 11), width: colW, align: .right)
            text("proj", .systemFont(ofSize: 10), th.dimText, x: px, y: y + 29, width: colW, align: .right)
        }
        // Ask Claude about him, on hover.
        let askId = "ask.\(id).\(Int(y))"
        if hover == rowId || hover == askId {
            let ar = NSRect(x: right - colW * 2 - 46, y: y + 12, width: 28, height: 28)
            fill(ar, th.accent.withAlphaComponent(hover == askId ? 0.30 : 0.16), radius: 8)
            symbol("sparkles", ar, th.accent, size: 12, weight: .semibold)
            hit(ar, askId) { [weak page] in page?.askPlayer(p) }
        } else {
            // Registered even when not drawn, so the hover can find it.
            hit(NSRect(x: right - colW * 2 - 46, y: y + 12, width: 28, height: 28), askId) { [weak page] in page?.askPlayer(p) }
        }
        line(r.maxY, from: left, to: rightEdge, th.border.withAlphaComponent(0.5))
        return r.maxY + 1
    }

    private func teamHeader(_ r: SleeperRoster, _ s: SleeperLeagueSnapshot, y: CGFloat, points: Double?, projected: Double) -> CGFloat {
        let w = bounds.width
        let o = s.owner(of: r)
        let av = NSRect(x: left, y: y, width: 52, height: 52)
        avatar(o?.avatarURL, av, initials: PageCanvas.initials(s.teamName(r)))
        text(s.teamName(r), .systemFont(ofSize: 18, weight: .bold), th.foreground, x: av.maxX + 14, y: y + 4, width: w - 360)
        let rank = (s.standings.firstIndex { $0.rosterId == r.rosterId } ?? 0) + 1
        var parts = [o?.displayName ?? "", r.recordText, "\(ordinal(rank)) of \(s.rosters.count)", "PF \(Sleeper.format(r.pointsFor))"]
        if s.league.usesFAAB { parts.append("FAAB $\(s.league.waiverBudget - r.waiverBudgetUsed)") }
        else if let wp = r.waiverPosition { parts.append("Waiver #\(wp)") }
        text(parts.filter { !$0.isEmpty }.joined(separator: " · "), .systemFont(ofSize: 12), th.dimText, x: av.maxX + 14, y: y + 30, width: w - 360)
        // Totals, on the numbers' edge.
        let right = rightEdge
        if let points {
            text(Sleeper.format(points), .monospacedDigitSystemFont(ofSize: 24, weight: .bold), th.foreground, x: right - 120, y: y, width: 120, align: .right)
            text("Week \(s.week) points", .systemFont(ofSize: 11), th.dimText, x: right - 120, y: y + 32, width: 120, align: .right)
        }
        // Alone, it takes the points' place at the edge; beside them, the column before.
        let px = points == nil ? right - 120 : right - 220, pw: CGFloat = points == nil ? 120 : 90
        text(Sleeper.format(projected), .monospacedDigitSystemFont(ofSize: points == nil ? 24 : 16, weight: .bold), points == nil ? th.foreground : th.dimText,
             x: px, y: y + (points == nil ? 0 : 6), width: pw, align: .right)
        text("projected", .systemFont(ofSize: 11), th.dimText, x: px, y: y + 32, width: pw, align: .right)
        return y + 66
    }

    private func ordinal(_ n: Int) -> String {
        let suffix = (11...13).contains(n % 100) ? "th" : [1: "st", 2: "nd", 3: "rd"][n % 10] ?? "th"
        return "\(n)\(suffix)"
    }

    // MARK: My Team

    private func team(_ s: SleeperLeagueSnapshot, y y0: CGFloat) -> CGFloat {
        guard let model else { return y0 }
        let rid = model.viewedRoster ?? s.myRosterId
        guard let rid, let r = s.roster(rid) else {
            text("You don't have a team in this league. Pick one in Standings.", .systemFont(ofSize: 13), th.dimText, x: left, y: y0 + 10, width: rightEdge - left)
            return y0 + 40
        }
        var y = y0
        let m = s.matchup(for: rid)
        let starters = m?.starters.isEmpty == false ? m!.starters : r.starters
        let pts = m?.playersPoints ?? [:]
        let anyPoints = pts.values.contains { $0 != 0 }
        y = teamHeader(r, s, y: y, points: anyPoints ? m?.points : nil, projected: s.projectedTotal(starters))
        if rid != s.myRosterId, s.myRosterId != nil {
            button("Back to my team", id: "myteam", x: left - 6, y: y, height: 24, symbol: "chevron.left", style: .plain) { [weak page] in page?.showTeam(nil) }
            y += 32
        }
        let slots = s.league.starterSlots
        y = sectionLabel("Starters", y: y, right: "Week \(s.week)") + 2
        for (i, id) in starters.enumerated() {
            y = playerRow(id, s, y: y, slot: i < slots.count ? slots[i] : nil, points: anyPoints ? pts[id] : nil)
        }
        let bench = r.bench.sorted { (s.projected($0) ?? -1) > (s.projected($1) ?? -1) }
        if !bench.isEmpty {
            y = sectionLabel("Bench", y: y + 18, right: "\(bench.count)") + 2
            for id in bench { y = playerRow(id, s, y: y, slot: "BN", points: anyPoints ? pts[id] : nil) }
        }
        if !r.reserve.isEmpty {
            y = sectionLabel("Injured Reserve", y: y + 18) + 2
            for id in r.reserve { y = playerRow(id, s, y: y, slot: "IR") }
        }
        if !r.taxi.isEmpty {
            y = sectionLabel("Taxi Squad", y: y + 18) + 2
            for id in r.taxi { y = playerRow(id, s, y: y, slot: "TX") }
        }
        return y
    }

    // MARK: Matchup

    private func matchup(_ s: SleeperLeagueSnapshot, y y0: CGFloat) -> CGFloat {
        guard let model else { return y0 }
        var y = y0
        let w = bounds.width
        guard let rid = model.viewedRoster ?? s.myRosterId, let mine = s.matchup(for: rid) else {
            text(s.matchups.isEmpty ? "No matchups for week \(s.week)." : "You don't have a matchup this week.", .systemFont(ofSize: 13), th.dimText,
                 x: pad, y: y + 10, width: w - pad * 2)
            return scoreboard(s, y: y + 50, highlight: nil)
        }
        let opp = s.opponentMatchup(for: rid)
        let anyPoints = mine.points > 0 || (opp?.points ?? 0) > 0
        let myProj = s.projectedTotal(mine.starters), oppProj = opp.map { s.projectedTotal($0.starters) } ?? 0

        // Scoreboard card.
        let card = NSRect(x: pad, y: y, width: w - pad * 2, height: 128)
        fill(card, th.surface.withAlphaComponent(0.7), radius: 14)
        stroke(card, th.border, radius: 14)
        func side(_ m: SleeperMatchup?, _ proj: Double, left: Bool) {
            let half = card.width / 2
            let x0 = left ? card.minX + 20 : card.midX + 20
            guard let m, let r = s.roster(m.rosterId) else {
                text("Bye", .systemFont(ofSize: 15, weight: .semibold), th.dimText, x: x0, y: card.minY + 50, width: half - 40, align: left ? .left : .right)
                return
            }
            let o = s.owner(of: r)
            let av = NSRect(x: left ? x0 : card.maxX - 20 - 44, y: card.minY + 18, width: 44, height: 44)
            avatar(o?.avatarURL, av, initials: PageCanvas.initials(s.teamName(r)))
            let tx = left ? av.maxX + 10 : card.midX + 20
            let tw = half - 44 - 50
            text(s.teamName(r), .systemFont(ofSize: 14, weight: .semibold), th.foreground, x: tx, y: card.minY + 20, width: tw, align: left ? .left : .right)
            text("\(r.recordText) · \(o?.displayName ?? "")", .systemFont(ofSize: 11.5), th.dimText, x: tx, y: card.minY + 40, width: tw, align: left ? .left : .right)
            let big = anyPoints ? m.points : proj
            text(Sleeper.format(big), .monospacedDigitSystemFont(ofSize: 30, weight: .heavy), th.foreground, x: x0, y: card.minY + 70,
                 width: half - 40, align: left ? .left : .right)
            text(anyPoints ? "proj \(Sleeper.format(proj))" : "projected", .systemFont(ofSize: 11), th.dimText, x: x0, y: card.minY + 106,
                 width: half - 40, align: left ? .left : .right)
            hit(NSRect(x: left ? card.minX : card.midX, y: card.minY, width: half, height: 66), "mteam.\(m.rosterId)") { [weak page] in page?.showTeam(m.rosterId) }
        }
        side(mine, myProj, left: true)
        side(opp, oppProj, left: false)
        text("VS", .systemFont(ofSize: 12, weight: .heavy), th.dimText, x: card.midX - 20, y: card.minY + 30, width: 40, align: .center)
        // Win odds from the projections (a rough guide, shown as a split bar).
        if let _ = opp, myProj + oppProj > 0 {
            let share = myProj / (myProj + oppProj)
            let bar = NSRect(x: card.midX - 70, y: card.minY + 86, width: 140, height: 6)
            fill(bar, th.foreground.withAlphaComponent(0.12), radius: 3)
            fill(NSRect(x: bar.minX, y: bar.minY, width: bar.width * share, height: bar.height), th.accent, radius: 3)
            text("\(Int((share * 100).rounded()))% of projected points", .systemFont(ofSize: 10), th.dimText, x: card.midX - 90, y: card.minY + 96, width: 180, align: .center)
        }
        y = card.maxY + 18

        // Slot by slot.
        let slots = s.league.starterSlots
        y = sectionLabel("Lineups", y: y) + 2
        let n = max(mine.starters.count, opp?.starters.count ?? 0)
        for i in 0..<n {
            let a = i < mine.starters.count ? mine.starters[i] : "0"
            let b = opp.flatMap { i < $0.starters.count ? $0.starters[i] : nil } ?? "0"
            y = matchRow(a, mine, b, opp, slot: i < slots.count ? slots[i] : "", s, y: y, showPoints: anyPoints)
        }
        y += 24
        return scoreboard(s, y: y, highlight: mine.matchupId)
    }

    private func matchRow(_ a: String, _ ma: SleeperMatchup, _ b: String, _ mb: SleeperMatchup?, slot: String, _ s: SleeperLeagueSnapshot,
                          y: CGFloat, showPoints: Bool) -> CGFloat {
        let w = bounds.width
        let h: CGFloat = 50
        let mid = w / 2
        let slotColor = ["QB", "RB", "WR", "TE", "K", "DEF"].contains(slot) ? Self.positionColor(slot) : Self.positionColor("FLEX")
        let sw: CGFloat = 46
        pill(SleeperLeagueSnapshot.slotName(slot), x: mid - sw / 2, y: y + 16, color: slotColor, minWidth: sw)
        func cell(_ id: String, _ m: SleeperMatchup?, left: Bool) {
            let x0 = left ? pad : mid + sw / 2 + 8
            let x1 = left ? mid - sw / 2 - 8 : w - pad
            guard id != "0", let m else {
                text(m == nil ? "" : "Empty", .systemFont(ofSize: 12), th.red, x: x0 + 8, y: y + 16, width: x1 - x0 - 16, align: left ? .left : .right)
                return
            }
            let p = s.player(id)
            let rid = "mrow.\(id).\(left)"
            if hover == rid { fill(NSRect(x: x0, y: y + 2, width: x1 - x0, height: h - 4), th.foreground.withAlphaComponent(0.05), radius: 8) }
            hit(NSRect(x: x0, y: y, width: x1 - x0, height: h), rid) { [weak page] in page?.showPlayer(id) }
            let photo = NSRect(x: left ? x0 + inset : x1 - inset - 32, y: y + 9, width: 32, height: 32)
            avatar(p.photoURL, photo, initials: PageCanvas.initials(p.name), fit: p.isDefense)
            let ptsW: CGFloat = 54
            let tx = left ? photo.maxX + 10 : x0 + ptsW + 8
            let tw = (x1 - x0) - 32 - 10 - ptsW - 16
            var nameLine = p.name
            if let inj = p.injuryShort { nameLine += " (\(inj))" }
            text(nameLine, .systemFont(ofSize: 12.5, weight: .semibold), p.injuryShort.map(injuryColor) ?? th.foreground, x: tx, y: y + 9, width: tw, align: left ? .left : .right)
            var sub = p.positionTeam
            if let opp = s.opponent(id) { sub += " vs \(opp)" }
            if let note = model?.shownAdvice?.note(for: id) { sub = note.tag.uppercased() + " · " + sub }
            text(sub, .systemFont(ofSize: 11), th.dimText, x: tx, y: y + 27, width: tw, align: left ? .left : .right)
            let px = left ? x1 - ptsW - 4 : x0 + 4
            let proj = s.projected(id)
            if showPoints {
                text(Sleeper.format(m.playersPoints[id] ?? 0), .monospacedDigitSystemFont(ofSize: 14, weight: .bold), th.foreground, x: px, y: y + 8, width: ptsW, align: left ? .right : .left)
                text(proj.map { "p \(Sleeper.format($0))" } ?? "", .monospacedDigitSystemFont(ofSize: 10, weight: .regular), th.dimText, x: px, y: y + 28, width: ptsW, align: left ? .right : .left)
            } else if let proj {
                text(Sleeper.format(proj), .monospacedDigitSystemFont(ofSize: 14, weight: .bold), th.foreground, x: px, y: y + 8, width: ptsW, align: left ? .right : .left)
                text("proj", .systemFont(ofSize: 10), th.dimText, x: px, y: y + 28, width: ptsW, align: left ? .right : .left)
            }
        }
        cell(a, ma, left: true)
        cell(b, mb, left: false)
        line(y + h, from: left, to: rightEdge, th.border.withAlphaComponent(0.5))
        return y + h + 1
    }

    /// Every matchup this week, small.
    private func scoreboard(_ s: SleeperLeagueSnapshot, y y0: CGFloat, highlight: Int?) -> CGFloat {
        var groups: [Int: [SleeperMatchup]] = [:]
        for m in s.matchups { if let id = m.matchupId { groups[id, default: []].append(m) } }
        guard !groups.isEmpty else { return y0 }
        var y = sectionLabel("Around the league · Week \(s.week)", y: y0) + 4
        let w = bounds.width
        let cols = w > 900 ? 3 : w > 600 ? 2 : 1
        let gap: CGFloat = 10
        let cw = (w - pad * 2 - gap * CGFloat(cols - 1)) / CGFloat(cols)
        let ch: CGFloat = 64
        for (i, key) in groups.keys.sorted().enumerated() {
            let col = i % cols, row = i / cols
            let r = NSRect(x: pad + CGFloat(col) * (cw + gap), y: y + CGFloat(row) * (ch + gap), width: cw, height: ch)
            let pair = groups[key]!.sorted { $0.rosterId < $1.rosterId }
            fill(r, key == highlight ? th.accent.withAlphaComponent(0.10) : th.surface.withAlphaComponent(0.55), radius: 10)
            let any = pair.contains { $0.points > 0 }
            for (j, m) in pair.prefix(2).enumerated() {
                let ly = r.minY + 10 + CGFloat(j) * 24
                let rr = s.roster(m.rosterId)
                avatar(rr.flatMap { s.owner(of: $0)?.avatarURL }, NSRect(x: r.minX + 10, y: ly, width: 20, height: 20),
                       initials: PageCanvas.initials(s.teamName(rosterId: m.rosterId)))
                let mine = m.rosterId == s.myRosterId
                text(s.teamName(rosterId: m.rosterId), .systemFont(ofSize: 12, weight: mine ? .bold : .medium), mine ? th.accent : th.foreground,
                     x: r.minX + 36, y: ly + 2, width: cw - 110)
                let v = any ? m.points : s.projectedTotal(m.starters)
                text(Sleeper.format(v) + (any ? "" : " p"), .monospacedDigitSystemFont(ofSize: 12.5, weight: .semibold), any ? th.foreground : th.dimText,
                     x: r.maxX - 80, y: ly + 2, width: 70, align: .right)
            }
            hit(r, "sb.\(key)") { [weak page] in
                guard let page, let first = pair.first else { return }
                page.model.viewedRoster = pair.contains { $0.rosterId == s.myRosterId } ? nil : first.rosterId
                page.show(.matchup, keepRoster: true)
            }
        }
        let rows = (groups.count + cols - 1) / cols
        y += CGFloat(rows) * (ch + gap)
        return y
    }

    // MARK: Standings

    private func standings(_ s: SleeperLeagueSnapshot, y y0: CGFloat) -> CGFloat {
        let w = bounds.width
        var y = sectionLabel("Standings · \(s.league.name)", y: y0) + 4
        let narrow = w < 640
        let right = w - pad - 10
        // Columns from the right.
        var cols: [(String, CGFloat)] = [("PF", 76)]
        if !narrow { cols.append(("PA", 76)) }
        cols.append(("W-L", 56))
        if !narrow { cols.append((s.league.usesFAAB ? "FAAB" : "WAIVER", 64)); cols.append(("STREAK", 60)) }
        // Header, placed from the right.
        var cx = right
        var xs: [String: CGFloat] = [:]
        let order = narrow ? ["W-L", "PF"] : ["W-L", "PF", "PA", s.league.usesFAAB ? "FAAB" : "WAIVER", "STREAK"]
        for name in order.reversed() {
            let cw = cols.first { $0.0 == name }?.1 ?? 60
            cx -= cw
            xs[name] = cx
            text(name, .systemFont(ofSize: 10, weight: .bold), th.dimText, x: cx, y: y, width: cw, align: .right)
        }
        text("#", .systemFont(ofSize: 10, weight: .bold), th.dimText, x: left, y: y, width: 20)
        text("TEAM", .systemFont(ofSize: 10, weight: .bold), th.dimText, x: left + 66, y: y, width: 100)
        y += 20
        let playoffTeams = s.league.totalRosters >= 10 ? 6 : 4
        for (i, r) in s.standings.enumerated() {
            let h: CGFloat = 46
            let rr = NSRect(x: pad, y: y, width: w - pad * 2, height: h)
            let mine = r.rosterId == s.myRosterId
            let id = "stand.\(r.rosterId)"
            if mine { fill(rr, th.accent.withAlphaComponent(0.10), radius: 8) }
            else if hover == id { fill(rr, th.foreground.withAlphaComponent(0.05), radius: 8) }
            hit(rr, id) { [weak page] in page?.showTeam(r.rosterId) }
            text("\(i + 1)", .monospacedDigitSystemFont(ofSize: 12.5, weight: .bold), i < playoffTeams ? th.foreground : th.dimText, x: left, y: y + 14, width: 22)
            if i < playoffTeams { fill(NSRect(x: pad + 2, y: y + 12, width: 3, height: 22), th.green.withAlphaComponent(0.8), radius: 1.5) }
            let o = s.owner(of: r)
            avatar(o?.avatarURL, NSRect(x: left + 26, y: y + 8, width: 30, height: 30), initials: PageCanvas.initials(s.teamName(r)))
            let nameW = (xs[order[0]] ?? right) - (left + 66) - 10
            text(s.teamName(r), .systemFont(ofSize: 13, weight: .semibold), mine ? th.accent : th.foreground, x: left + 66, y: y + 7, width: nameW)
            text(o?.displayName ?? "", .systemFont(ofSize: 11), th.dimText, x: left + 66, y: y + 25, width: nameW)
            func col(_ name: String, _ value: String, _ color: NSColor? = nil) {
                guard let x = xs[name], let cw = cols.first(where: { $0.0 == name })?.1 else { return }
                text(value, .monospacedDigitSystemFont(ofSize: 12.5, weight: .medium), color ?? th.foreground, x: x, y: y + 14, width: cw, align: .right)
            }
            col("W-L", r.recordText)
            col("PF", Sleeper.format(r.pointsFor))
            col("PA", Sleeper.format(r.pointsAgainst), th.dimText)
            if s.league.usesFAAB { col("FAAB", "$\(s.league.waiverBudget - r.waiverBudgetUsed)", th.dimText) }
            else { col("WAIVER", r.waiverPosition.map { "#\($0)" } ?? "", th.dimText) }
            if let st = r.streak { col("STREAK", st, st.hasSuffix("W") ? th.green : th.red) }
            y += h + 2
        }
        text("Top \(playoffTeams) marked; playoffs start week \(s.league.playoffWeekStart).", .systemFont(ofSize: 11), th.dimText, x: left, y: y + 8, width: rightEdge - left)
        return y + 30
    }

    // MARK: Waivers

    private func waivers(_ s: SleeperLeagueSnapshot, y y0: CGFloat) -> CGFloat {
        guard let page, let model else { return y0 }
        var y = y0
        let w = bounds.width
        // Your waiver standing.
        if let mine = s.myRosterId.flatMap(s.roster) {
            let info = s.league.usesFAAB
                ? "You have $\(s.league.waiverBudget - mine.waiverBudgetUsed) of $\(s.league.waiverBudget) FAAB left."
                : "You're #\(mine.waiverPosition ?? 0) in the waiver order."
            symbol("dollarsign.circle", NSRect(x: left, y: y, width: 16, height: 18), th.accent, size: 13)
            text(info + " Claims are made in the Sleeper app.", .systemFont(ofSize: 12.5), th.foreground, x: left + 22, y: y + 1, width: rightEdge - left - 22)
            y += 28
        }
        // Position chips.
        var x = left
        for pos in ["ALL", "QB", "RB", "WR", "TE", "FLEX", "K", "DEF"] {
            let on = page.waiverPosition == pos
            let f = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
            let cw = PageCanvas.textWidth(pos, f) + 22
            let r = NSRect(x: x, y: y, width: cw, height: 26)
            let c = pos == "ALL" || pos == "FLEX" ? th.accent : Self.positionColor(pos)
            fill(r, on ? c.withAlphaComponent(0.85) : hover == "pos." + pos ? th.foreground.withAlphaComponent(0.10) : th.foreground.withAlphaComponent(0.05), radius: 13)
            text(pos, f, on ? (c.luminance > 0.55 ? .black : .white) : th.foreground, x: r.minX, y: r.minY + 5, width: cw, align: .center)
            hit(r, "pos." + pos) { [weak page] in page?.waiverPosition = pos }
            x += cw + 6
        }
        y += 40
        let trend = Dictionary(model.trendingAdds.map { ($0.id, $0.count) }, uniquingKeysWith: { a, _ in a })
        let list = s.freeAgents(position: page.waiverPosition, limit: 40)
        y = sectionLabel("Available · best projected for week \(s.week)", y: y, right: "\(list.count) shown") + 2
        if list.isEmpty {
            text(s.projections.isEmpty ? "No projections for this week yet." : "Nobody available at \(page.waiverPosition).", .systemFont(ofSize: 12.5), th.dimText,
                 x: left, y: y + 8, width: rightEdge - left)
            y += 36
        }
        for p in list {
            let extra = trend[p.id].map { "▲ \(compact($0)) adds" }
            y = playerRow(p.id, s, y: y, extra: extra, extraColor: nil)
        }
        // Recent claims in the league.
        let claims = model.transactions.filter { $0.type == "waiver" }.prefix(8)
        if !claims.isEmpty {
            y = sectionLabel("Recent waiver claims", y: y + 22) + 4
            for t in claims { y = transactionRow(t, s, y: y) }
        }
        return y
    }

    /// `s`, cut short with … to fit a pill's text in `width`.
    private func fitted(_ s: String, _ width: CGFloat) -> String {
        let f = NSFont.systemFont(ofSize: 10, weight: .bold)
        guard PageCanvas.textWidth(s, f) > width else { return s }
        var t = s
        while !t.isEmpty, PageCanvas.textWidth(t + "…", f) > width { t.removeLast() }
        return t.trimmingCharacters(in: .whitespaces) + "…"
    }

    private func compact(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1_000_000) : n >= 1000 ? "\(n / 1000)K" : "\(n)"
    }

    // MARK: Trending

    private func trending(_ s: SleeperLeagueSnapshot, y y0: CGFloat) -> CGFloat {
        guard let model else { return y0 }
        let w = bounds.width
        let twoCols = w >= 860
        let colW = twoCols ? (w - pad * 2 - 20) / 2 : w - pad * 2
        func list(_ title: String, _ items: [(id: String, count: Int)], x: CGFloat, y y1: CGFloat, add: Bool) -> CGFloat {
            var y = y1
            text(title.uppercased(), .systemFont(ofSize: 10.5, weight: .bold), th.dimText, x: x + inset, y: y, width: colW - inset * 2)
            y += 22
            if items.isEmpty { text("Nothing yet.", .systemFont(ofSize: 12), th.dimText, x: x + inset, y: y, width: colW - inset * 2); return y + 24 }
            let maxCount = Double(items.map(\.count).max() ?? 1)
            for (i, t) in items.prefix(25).enumerated() {
                let p = s.player(t.id)
                let h: CGFloat = 46
                let r = NSRect(x: x, y: y, width: colW, height: h)
                let id = "trend.\(add).\(t.id)"
                if hover == id { fill(r, th.foreground.withAlphaComponent(0.05), radius: 8) }
                hit(r, id) { [weak page] in page?.showPlayer(t.id) }
                text("\(i + 1)", .monospacedDigitSystemFont(ofSize: 11.5, weight: .bold), th.dimText, x: x + 4, y: y + 15, width: 22, align: .right)
                avatar(p.photoURL, NSRect(x: x + 34, y: y + 7, width: 32, height: 32), initials: PageCanvas.initials(p.name), fit: p.isDefense)
                let tx = x + 76
                let chipW: CGFloat = 110
                text(p.name, .systemFont(ofSize: 12.5, weight: .semibold), th.foreground, x: tx, y: y + 6, width: colW - 76 - chipW - 70)
                text(p.positionTeam + (p.injuryShort.map { " · \($0)" } ?? ""), .systemFont(ofSize: 11), th.dimText, x: tx, y: y + 24, width: colW - 76 - chipW - 70)
                // Count with a bar.
                let bx = r.maxX - chipW - 70
                let bar = NSRect(x: bx, y: y + 30, width: 60, height: 4)
                fill(bar, th.foreground.withAlphaComponent(0.08), radius: 2)
                fill(NSRect(x: bar.minX, y: bar.minY, width: bar.width * CGFloat(Double(t.count) / maxCount), height: 4), add ? th.green : th.red, radius: 2)
                text((add ? "+" : "−") + compact(t.count), .monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold), add ? th.green : th.red, x: bx, y: y + 9, width: 60, align: .right)
                // Where he is in this league.
                if let rr = s.rosterOf(t.id) {
                    let mine = rr.rosterId == s.myRosterId
                    pill(mine ? "Yours" : fitted(s.teamName(rr), chipW - 16), x: r.maxX - inset, y: y + 14, color: mine ? th.accent : th.foreground, rightAligned: true)
                } else {
                    pill("Available", x: r.maxX - inset, y: y + 14, color: th.green, filled: false, rightAligned: true)
                }
                y += h + 1
            }
            return y
        }
        var y = sectionLabel("Across all of Sleeper · last 24 hours", y: y0) + 6
        if twoCols {
            let a = list("Most added", model.trendingAdds, x: pad, y: y, add: true)
            let b = list("Most dropped", model.trendingDrops, x: pad + colW + 20, y: y, add: false)
            y = max(a, b)
        } else {
            y = list("Most added", model.trendingAdds, x: pad, y: y, add: true) + 20
            y = list("Most dropped", model.trendingDrops, x: pad, y: y, add: false)
        }
        return y
    }

    // MARK: Activity

    private func transactionRow(_ t: SleeperTransaction, _ s: SleeperLeagueSnapshot, y: CGFloat) -> CGFloat {
        let w = bounds.width
        let lines = t.adds.count + t.drops.count + (t.draftPicks > 0 ? 1 : 0)
        let h = max(54, 30 + CGFloat(lines) * 20 + 8)
        let r = NSRect(x: pad, y: y, width: w - pad * 2, height: h)
        fill(r, th.surface.withAlphaComponent(0.45), radius: 10)
        let (sym, color): (String, NSColor) = {
            switch t.type {
            case "trade": return ("arrow.left.arrow.right.circle.fill", th.yellow)
            case "waiver": return ("clock.badge.checkmark.fill", th.accent)
            default: return ("plus.circle.fill", th.green)
            }
        }()
        symbol(sym, NSRect(x: r.minX + 10, y: r.minY + 10, width: 22, height: 22), color, size: 16)
        let teams = t.rosterIds.map { s.teamName(rosterId: $0) }.joined(separator: " ⇄ ")
        text(teams, .systemFont(ofSize: 12.5, weight: .semibold), th.foreground, x: r.minX + 42, y: r.minY + 9, width: r.width - 220)
        var meta = t.typeName
        if let bid = t.waiverBid { meta += " · $\(bid)" }
        meta += " · " + PageCanvas.ago(t.created)
        text(meta, .systemFont(ofSize: 11), th.dimText, x: r.maxX - 220, y: r.minY + 10, width: 208, align: .right)
        var ly = r.minY + 32
        func entry(_ id: String, _ rid: Int, add: Bool) {
            let p = s.player(id)
            symbol(add ? "plus" : "minus", NSRect(x: r.minX + 42, y: ly, width: 12, height: 16), add ? th.green : th.red, size: 9, weight: .heavy)
            avatar(p.photoURL, NSRect(x: r.minX + 58, y: ly, width: 16, height: 16), fit: p.isDefense)
            var label = "\(p.name)  \(p.positionTeam)"
            if t.type == "trade" { label += add ? "  → \(s.teamName(rosterId: rid))" : "" }
            let id2 = "tx.\(t.id).\(id).\(add)"
            let lw = text(label, .systemFont(ofSize: 12), hover == id2 ? th.accent : th.foreground.withAlphaComponent(0.9), x: r.minX + 80, y: ly, width: r.width - 100)
            hit(NSRect(x: r.minX + 40, y: ly - 2, width: lw + 44, height: 20), id2) { [weak page] in page?.showPlayer(id) }
            ly += 20
        }
        for (id, rid) in t.adds.sorted(by: { $0.key < $1.key }) { entry(id, rid, add: true) }
        if t.type != "trade" { for (id, rid) in t.drops.sorted(by: { $0.key < $1.key }) { entry(id, rid, add: false) } }
        if t.draftPicks > 0 {
            text("+ \(t.draftPicks) draft pick\(t.draftPicks == 1 ? "" : "s")", .systemFont(ofSize: 12), th.dimText, x: r.minX + 58, y: ly, width: 300)
        }
        return r.maxY + 8
    }

    private func activity(_ s: SleeperLeagueSnapshot, y y0: CGFloat) -> CGFloat {
        guard let model else { return y0 }
        var y = y0
        let list = model.transactions
        if list.isEmpty {
            _ = sectionLabel("League activity", y: y)
            text("No moves in the last three weeks.", .systemFont(ofSize: 12.5), th.dimText, x: left, y: y + 28, width: rightEdge - left)
            return y + 60
        }
        var lastWeek = -1
        for t in list.prefix(80) {
            if t.week != lastWeek {
                y = sectionLabel("Week \(t.week)", y: y + (lastWeek == -1 ? 0 : 14)) + 4
                lastWeek = t.week
            }
            y = transactionRow(t, s, y: y)
        }
        return y
    }

    // MARK: Player

    private func player(_ s: SleeperLeagueSnapshot, y y0: CGFloat) -> CGFloat {
        guard let page, let model, let id = page.playerId else { return y0 }
        let w = bounds.width
        let p = s.player(id)
        var y = y0
        button("Back", id: "back", x: left - 6, y: y, height: 24, symbol: "chevron.left", style: .plain) { [weak page] in page?.back() }
        y += 34
        // Card: photo, name, team.
        let photo = NSRect(x: left, y: y, width: 104, height: 104)
        avatar(p.photoURL, photo, initials: PageCanvas.initials(p.name), fit: p.isDefense)
        stroke(photo, Self.positionColor(p.position), radius: 52, width: 3)
        let tx = photo.maxX + 20
        var ny = y + 6
        text(p.name, .systemFont(ofSize: 24, weight: .bold), th.foreground, x: tx, y: ny, width: w - tx - 200)
        ny += 34
        var px = tx
        px += pill(p.position, x: px, y: ny, height: 20, color: Self.positionColor(p.position), filled: true) + 6
        if let team = p.team {
            if let logo = p.teamLogoURL { avatar(logo, NSRect(x: px, y: ny - 1, width: 22, height: 22), fit: true, bg: .clear); px += 26 }
            px += text(team, .systemFont(ofSize: 13, weight: .semibold), th.foreground, x: px, y: ny + 2, width: 60) + 8
        } else {
            px += pill("Free agent", x: px, y: ny, height: 20, color: th.dimText) + 6
        }
        if let n = p.number { px += text("#\(n)", .systemFont(ofSize: 13, weight: .medium), th.dimText, x: px, y: ny + 2, width: 50) + 8 }
        if let inj = p.injuryShort { px += pill("\(p.injury ?? inj)" + (p.injuryBody.map { " · \($0)" } ?? ""), x: px, y: ny, height: 20, color: injuryColor(inj)) + 6 }
        ny += 30
        var bio: [String] = []
        if let a = p.age { bio.append("Age \(a)") }
        if let h = p.heightText { bio.append(h + (p.weight.map { ", \($0) lb" } ?? "")) }
        if let e = p.yearsExp { bio.append(e == 0 ? "Rookie" : "\(e) yr\(e == 1 ? "" : "s") exp") }
        if let c = p.college { bio.append(c) }
        if let d = p.depthPosition, let o = p.depthOrder { bio.append("Depth chart: \(d)\(o)") }
        text(bio.joined(separator: " · "), .systemFont(ofSize: 12), th.dimText, x: tx, y: ny, width: rightEdge - 220 - tx)
        ny += 22
        // Who has him.
        if let r = s.rosterOf(id) {
            let mine = r.rosterId == s.myRosterId
            let label = mine ? "On your team" : "On \(s.teamName(r))"
            let starting = (s.matchup(for: r.rosterId)?.starters ?? r.starters).contains(id)
            text(label + (starting ? " · starting" : " · bench"), .systemFont(ofSize: 12.5, weight: .semibold), mine ? th.accent : th.foreground, x: tx, y: ny, width: rightEdge - 220 - tx)
        } else {
            text("Available in \(s.league.name)", .systemFont(ofSize: 12.5, weight: .semibold), th.green, x: tx, y: ny, width: rightEdge - 220 - tx)
        }
        // This week, at the right (on the numbers' edge).
        let right = rightEdge
        if let proj = s.projected(id) {
            text(Sleeper.format(proj), .monospacedDigitSystemFont(ofSize: 30, weight: .heavy), th.foreground, x: right - 160, y: y + 4, width: 160, align: .right)
            text("projected · week \(s.week)" + (s.opponent(id).map { " vs \($0)" } ?? ""), .systemFont(ofSize: 11.5), th.dimText, x: right - 220, y: y + 42, width: 220, align: .right)
        } else if p.team != nil {
            text("BYE", .systemFont(ofSize: 22, weight: .heavy), th.dimText, x: right - 160, y: y + 6, width: 160, align: .right)
            text("no game in week \(s.week)", .systemFont(ofSize: 11.5), th.dimText, x: right - 220, y: y + 38, width: 220, align: .right)
        }
        button("Ask Claude about \(p.first.isEmpty ? p.name : p.first)", id: "askplayer", x: right, y: y + 70, height: 30, symbol: "sparkles", style: .primary,
               rightAligned: true) { [weak page] in page?.askPlayer(p) }
        y = max(photo.maxY, ny + 20) + 20

        if let note = model.shownAdvice?.note(for: id) {
            let c = tagColor(note.tag)
            let hgt = paragraphHeight(note.reason, width: w - pad * 2 - 110, font: .systemFont(ofSize: 12.5)) + 22
            let r = NSRect(x: pad, y: y, width: w - pad * 2, height: hgt)
            fill(r, c.withAlphaComponent(0.12), radius: 10)
            pill(note.tag.uppercased(), x: r.minX + 12, y: r.minY + 11, height: 18, color: c, filled: true)
            symbol("sparkles", NSRect(x: r.minX + 74, y: r.minY + 11, width: 16, height: 18), th.accent, size: 11)
            paragraph(note.reason, .systemFont(ofSize: 12.5), th.foreground, x: r.minX + 96, y: r.minY + 11, width: w - pad * 2 - 110)
            y = r.maxY + 18
        }

        if let notes = p.injuryNotes, !notes.isEmpty {
            y = sectionLabel("Injury", y: y)
            y += paragraph(notes, .systemFont(ofSize: 12.5), th.foreground, x: pad, y: y, width: w - pad * 2) + 18
        }

        // Week by week.
        guard let weeks = model.playerWeeks, weeks.id == id else { return y }
        let season = s.state.displayWeek
        let played = weeks.stats.filter { ($0.value.stats["gp"] ?? $0.value.stats["gms_active"] ?? 0) > 0 }
        if weeks.stats.isEmpty && weeks.proj.isEmpty {
            text(weeks.loaded ? "No games or projections for him this season." : "Loading his season…", .systemFont(ofSize: 12.5), th.dimText,
                 x: left, y: y, width: rightEdge - left)
            return y + 30
        }
        let pts = played.mapValues { $0.points(s.league.scoring) }
        let avg = pts.isEmpty ? nil : pts.values.reduce(0, +) / Double(pts.count)
        y = sectionLabel("Season · \(s.league.scoringName) points", y: y,
                         right: avg.map { "\(pts.count) games · \(Sleeper.format($0)) avg" }) + 6
        // Bars: actual for weeks played, projected (outlined) for weeks to come.
        let weeksShown = Array(1...18)
        let chartH: CGFloat = 130
        let gap: CGFloat = 4
        let barW = max(8, (rightEdge - left - gap * CGFloat(weeksShown.count - 1)) / CGFloat(weeksShown.count))
        var maxV = 1.0
        for wk in weeksShown {
            if let v = pts[wk] { maxV = max(maxV, v) }
            if wk >= season, let pr = weeks.proj[wk] { maxV = max(maxV, pr.points(s.league.scoring)) }
        }
        let base = y + chartH
        if let avg {
            let ay = base - CGFloat(avg / maxV) * (chartH - 16)
            fill(NSRect(x: left, y: ay, width: rightEdge - left, height: 1), th.accent.withAlphaComponent(0.35))
        }
        for (i, wk) in weeksShown.enumerated() {
            let x = left + CGFloat(i) * (barW + gap)
            if let v = pts[wk] {
                let h = max(2, CGFloat(v / maxV) * (chartH - 16))
                let r = NSRect(x: x, y: base - h, width: barW, height: h)
                let good = avg.map { v >= $0 } ?? true
                fill(r, (good ? th.accent : th.accent.withAlphaComponent(0.55)), radius: min(4, barW / 3))
                if barW >= 22 { text(Sleeper.format((v * 10).rounded() / 10), .monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold), th.foreground, x: x - 4, y: r.minY - 14, width: barW + 8, align: .center) }
            } else if wk >= season, let pr = weeks.proj[wk] {
                let v = pr.points(s.league.scoring)
                let h = max(2, CGFloat(v / maxV) * (chartH - 16))
                let r = NSRect(x: x, y: base - h, width: barW, height: h)
                stroke(r, th.dimText.withAlphaComponent(0.6), radius: min(4, barW / 3), width: 1)
                if barW >= 22 { text(Sleeper.format((v * 10).rounded() / 10), .monospacedDigitSystemFont(ofSize: 9.5, weight: .regular), th.dimText, x: x - 4, y: r.minY - 14, width: barW + 8, align: .center) }
            } else if wk < season {
                text("–", .systemFont(ofSize: 10), th.dimText.withAlphaComponent(0.5), x: x, y: base - 14, width: barW, align: .center)
            }
            let wkColor = wk == s.week ? th.accent : th.dimText
            text("\(wk)", .monospacedDigitSystemFont(ofSize: 9.5, weight: wk == s.week ? .bold : .regular), wkColor, x: x - 2, y: base + 4, width: barW + 4, align: .center)
            let opp = weeks.stats[wk]?.opponent ?? weeks.proj[wk]?.opponent
            if barW >= 26, let opp { text(opp, .systemFont(ofSize: 8.5), th.dimText.withAlphaComponent(0.8), x: x - 4, y: base + 17, width: barW + 8, align: .center) }
        }
        line(base, from: left, to: rightEdge, th.border)
        y = base + 36
        // Legend.
        fill(NSRect(x: left, y: y + 3, width: 10, height: 10), th.accent, radius: 2)
        text("Points", .systemFont(ofSize: 11), th.dimText, x: left + 16, y: y, width: 60)
        stroke(NSRect(x: left + 74, y: y + 3, width: 10, height: 10), th.dimText, radius: 2)
        text("Projected", .systemFont(ofSize: 11), th.dimText, x: left + 90, y: y, width: 80)
        if avg != nil {
            fill(NSRect(x: left + 170, y: y + 8, width: 14, height: 1), th.accent.withAlphaComponent(0.6))
            text("Average", .systemFont(ofSize: 11), th.dimText, x: left + 190, y: y, width: 80)
        }
        y += 30

        // Next games.
        let upcoming = weeks.proj.keys.filter { $0 >= s.week }.sorted().prefix(4)
        if !upcoming.isEmpty {
            y = sectionLabel("Coming up", y: y) + 4
            let cw = min(180, (w - pad * 2 - 30) / 4)
            for (i, wk) in upcoming.enumerated() {
                let r = NSRect(x: pad + CGFloat(i) * (cw + 10), y: y, width: cw, height: 58)
                fill(r, th.surface.withAlphaComponent(0.55), radius: 10)
                let pr = weeks.proj[wk]!
                text("Week \(wk)", .systemFont(ofSize: 11, weight: .semibold), th.dimText, x: r.minX + 12, y: r.minY + 9, width: cw - 24)
                text(pr.opponent.map { "vs \($0)" } ?? "BYE", .systemFont(ofSize: 13, weight: .semibold), th.foreground, x: r.minX + 12, y: r.minY + 29, width: cw - 70)
                text(Sleeper.format(pr.points(s.league.scoring)), .monospacedDigitSystemFont(ofSize: 15, weight: .bold), th.foreground, x: r.maxX - 70, y: r.minY + 27, width: 58, align: .right)
            }
            y += 72
        }
        return y
    }
}
