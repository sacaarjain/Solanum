import Foundation

// The Sleeper extension's MCP server, for Claude Code: `Solanum --mcp sleeper` speaks MCP (JSON-RPC 2.0, one message
// per line) on stdin/stdout. Installing the extension registers it with Claude Code (see Extensions.swift), so
// Claude in any tab can read your leagues, rosters, matchups, waivers and players, and mark up Solanum's Sleeper
// page with its advice (start / sit / add / drop) or bring a view up there.
//
// Sleeper's API is read-only: the tools read and advise, and moves are made in the Sleeper app.

enum MCPServer {
    /// Runs the server named on the command line until stdin closes; the process's exit status.
    static func run(_ name: String) -> Int32 {
        switch name {
        case "sleeper": return serve(SleeperTools())
        default:
            FileHandle.standardError.write("Solanum: no MCP server named \(name). Known: sleeper\n".data(using: .utf8)!)
            return 2
        }
    }

    private static func serve(_ tools: SleeperTools) -> Int32 {
        setvbuf(stdout, nil, _IOLBF, 0)
        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            guard let data = trimmed.data(using: .utf8), let msg = try? JSONSerialization.jsonObject(with: data) else {
                write(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
                continue
            }
            // A batch is answered as one, too.
            if let batch = msg as? [[String: Any]] {
                let replies = batch.compactMap { handle($0, tools) }
                if !replies.isEmpty { writeAny(replies) }
            } else if let m = msg as? [String: Any], let reply = handle(m, tools) {
                write(reply)
            }
        }
        return 0
    }

    static func handle(_ m: [String: Any], _ tools: SleeperTools) -> [String: Any]? {
        let id = m["id"]
        guard let method = m["method"] as? String else { return nil }
        // Notifications (no id) get no answer.
        func reply(_ result: [String: Any]) -> [String: Any]? { id == nil ? nil : ["jsonrpc": "2.0", "id": id!, "result": result] }
        func fail(_ code: Int, _ message: String) -> [String: Any]? {
            id == nil ? nil : ["jsonrpc": "2.0", "id": id!, "error": ["code": code, "message": message]]
        }
        let params = m["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String
            let known = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
            return reply([
                "protocolVersion": asked.flatMap { known.contains($0) ? $0 : nil } ?? "2025-06-18",
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "solanum-sleeper", "title": "Sleeper Fantasy Football (Solanum)", "version": "1.0.0"],
                "instructions": SleeperTools.instructions,
            ])
        case "ping": return reply([:])
        case "tools/list": return reply(["tools": SleeperTools.definitions])
        case "tools/call":
            guard let name = params["name"] as? String else { return fail(-32602, "Missing tool name") }
            let args = params["arguments"] as? [String: Any] ?? [:]
            guard SleeperTools.definitions.contains(where: { $0["name"] as? String == name }) else {
                return fail(-32602, "Unknown tool: \(name)")
            }
            do {
                let out = try tools.call(name, args)
                return reply(["content": [["type": "text", "text": text(out)]], "isError": false])
            } catch {
                return reply(["content": [["type": "text", "text": error.localizedDescription]], "isError": true])
            }
        case "resources/list": return reply(["resources": []])
        case "prompts/list": return reply(["prompts": []])
        default:
            if method.hasPrefix("notifications/") { return nil }
            return fail(-32601, "Method not found: \(method)")
        }
    }

    /// A tool's result as text: JSON (compact, keys sorted so it reads the same each time), or a plain string.
    static func text(_ v: Any) -> String {
        if let s = v as? String { return s }
        guard JSONSerialization.isValidJSONObject(v),
              let d = try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "\(v)" }
        return String(decoding: d, as: UTF8.self)
    }

    private static func write(_ obj: [String: Any]) { writeAny(obj) }

    private static func writeAny(_ obj: Any) {
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) else { return }
        FileHandle.standardOutput.write(d)
        FileHandle.standardOutput.write("\n".data(using: .utf8)!)
    }
}

/// The tools themselves.
final class SleeperTools {
    static let instructions = """
    Sleeper fantasy football, through Solanum. Start with get_context: it says who's connected, their leagues and \
    the current NFL week (set_user connects a Sleeper username if nobody is). Tools default to the user's selected \
    league and the current week. Points and projections are computed with each league's own scoring settings. \
    The Sleeper API is read-only: you can analyze and advise, but adds, drops, trades and lineup changes are made \
    by the user in the Sleeper app. When you give lineup or waiver advice, also call annotate so it shows on the \
    Sleeper page in Solanum (tagging players start/sit/add/drop/trade/watch), and show_in_solanum to bring the \
    relevant view up.
    """

    static let leagueArg: [String: Any] = ["type": "string", "description": "Sleeper league id. Defaults to the league selected in Solanum."]
    static let weekArg: [String: Any] = ["type": "integer", "description": "NFL week (1-18). Defaults to the current week."]

    static func tool(_ name: String, _ title: String, _ description: String, _ props: [String: Any] = [:], required: [String] = [],
                     readOnly: Bool = true) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": props]
        if !required.isEmpty { schema["required"] = required }
        return ["name": name, "title": title, "description": description, "inputSchema": schema,
                "annotations": ["readOnlyHint": readOnly, "openWorldHint": true, "title": title]]
    }

    static let definitions: [[String: Any]] = [
        tool("get_context", "Sleeper context",
             "Who is connected, their leagues this season (ids, names, scoring), the selected league and the current NFL week. Call this first."),
        tool("set_user", "Connect Sleeper user",
             "Connect a Sleeper account by username (no password needed; Sleeper's API is public). Optionally select a league.",
             ["username": ["type": "string"], "league_id": leagueArg], required: ["username"], readOnly: false),
        tool("select_league", "Select league", "Make a league the default for the other tools and the Solanum page.",
             ["league_id": ["type": "string"]], required: ["league_id"], readOnly: false),
        tool("get_league", "League overview",
             "League settings (scoring, roster slots, waivers/FAAB, playoffs, trade deadline) and standings with every team's record, points for/against and owner.",
             ["league_id": leagueArg]),
        tool("get_roster", "Team roster",
             "A team's roster: starters by slot, bench, IR and taxi, each with position, NFL team, opponent, injury, this week's projection (league scoring) and points so far. Defaults to the user's own team.",
             ["league_id": leagueArg, "week": weekArg,
              "roster_id": ["type": "integer", "description": "Another team's roster id (see get_league)."],
              "team": ["type": "string", "description": "Another team, by team name or owner name."]]),
        tool("get_matchup", "Matchup",
             "A head-to-head matchup for a week: both lineups slot by slot with points and projections, totals and projected totals. Defaults to the user's own matchup.",
             ["league_id": leagueArg, "week": weekArg, "roster_id": ["type": "integer"]]),
        tool("get_scoreboard", "Scoreboard", "Every matchup in the league for a week, with scores and projected totals.",
             ["league_id": leagueArg, "week": weekArg]),
        tool("get_free_agents", "Free agents / waivers",
             "Players on no roster in the league (available on waivers or free agency), best projected this week first, with Sleeper-wide add trends. Also the user's waiver position or FAAB left.",
             ["league_id": leagueArg, "week": weekArg,
              "position": ["type": "string", "description": "QB, RB, WR, TE, K, DEF, FLEX or ALL."],
              "limit": ["type": "integer", "description": "How many (default 25, max 100)."]]),
        tool("get_trending", "Trending players",
             "Players most added or dropped across all of Sleeper lately, and whether each is available in the league.",
             ["type": ["type": "string", "enum": ["add", "drop"]], "hours": ["type": "integer", "description": "Look-back hours (default 24)."],
              "limit": ["type": "integer"], "league_id": leagueArg]),
        tool("get_transactions", "League transactions",
             "Recent waiver claims, free-agent moves and trades in the league for a week (default: this week and last), with teams, players and FAAB bids.",
             ["league_id": leagueArg, "week": weekArg, "type": ["type": "string", "enum": ["waiver", "free_agent", "trade"]]]),
        tool("get_player", "Player details",
             "One player: bio, team, injury and depth chart, who has him in the league, this week's matchup and projection, and his points week by week this season.",
             ["player": ["type": "string", "description": "Player id or name."], "league_id": leagueArg], required: ["player"]),
        tool("compare_players", "Compare players",
             "Side by side for start/sit or trade questions: projection and opponent this week, recent weeks' points, season average, injury, and rest-of-season projection.",
             ["players": ["type": "array", "items": ["type": "string"], "description": "Player ids or names (2-6)."], "league_id": leagueArg,
              "week": weekArg], required: ["players"]),
        tool("search_players", "Search players", "Find NFL players by name (and optionally position); ids for the other tools.",
             ["query": ["type": "string"], "position": ["type": "string"], "limit": ["type": "integer"]], required: ["query"]),
        tool("show_in_solanum", "Show in Solanum",
             "Bring up a view on the Sleeper page in Solanum, beside this chat: team, matchup, standings, waivers, trending, activity or a player.",
             ["view": ["type": "string", "enum": ["team", "matchup", "standings", "waivers", "trending", "activity", "player"]],
              "league_id": leagueArg, "week": weekArg, "player": ["type": "string", "description": "For view=player: id or name."],
              "roster_id": ["type": "integer", "description": "For view=team or matchup: another team."],
              "position": ["type": "string", "description": "For view=waivers: a position filter."]],
             required: ["view"], readOnly: false),
        tool("annotate", "Annotate the Sleeper page",
             "Put your advice on Solanum's Sleeper page: a short summary card, and tags on players (start, sit, add, drop, trade, watch) each with a one-line reason. Replaces earlier notes.",
             ["summary": ["type": "string", "description": "A few sentences, shown at the top of the page."],
              "title": ["type": "string", "description": "A short heading (\"Week 9 lineup\")."],
              "annotations": ["type": "array", "items": ["type": "object", "properties": [
                  "player": ["type": "string", "description": "Player id or name."],
                  "tag": ["type": "string", "enum": ["start", "sit", "add", "drop", "trade", "watch"]],
                  "reason": ["type": "string"]], "required": ["player", "tag"]]],
              "league_id": leagueArg], required: ["summary"], readOnly: false),
        tool("clear_annotations", "Clear annotations", "Remove your notes from the Sleeper page.", [:], readOnly: false),
    ]

    // MARK: Dispatch

    func call(_ name: String, _ a: [String: Any]) throws -> Any {
        switch name {
        case "get_context": return try context()
        case "set_user": return try setUser(a)
        case "select_league": return try selectLeague(a)
        case "get_league": return try leagueOverview(a)
        case "get_roster": return try roster(a)
        case "get_matchup": return try matchup(a)
        case "get_scoreboard": return try scoreboard(a)
        case "get_free_agents": return try freeAgents(a)
        case "get_trending": return try trending(a)
        case "get_transactions": return try transactions(a)
        case "get_player": return try player(a)
        case "compare_players": return try compare(a)
        case "search_players": return try searchPlayers(a)
        case "show_in_solanum": return try show(a)
        case "annotate": return try annotate(a)
        case "clear_annotations":
            Sleeper.saveAdvice(nil)
            post(Sleeper.adviceNotification, [:])
            return "Cleared."
        default: throw SleeperError.invalid("Unknown tool \(name)")
        }
    }

    // MARK: Helpers

    private var settings: Sleeper.Settings { Sleeper.loadSettings() }

    private func str(_ a: [String: Any], _ k: String) -> String? {
        if let s = a[k] as? String { let t = s.trimmingCharacters(in: .whitespaces); return t.isEmpty ? nil : t }
        if let i = Sleeper.int(a[k]) { return String(i) }
        return nil
    }

    private func requireUser() throws -> Sleeper.Settings {
        let s = settings
        guard s.userId != nil else {
            throw SleeperError.invalid("No Sleeper account is connected. Ask the user for their Sleeper username and call set_user.")
        }
        return s
    }

    /// The league named, else the one selected, else the user's only league this season.
    private func leagueId(_ a: [String: Any]) throws -> String {
        if let id = str(a, "league_id") { return id }
        let s = settings
        if let id = s.leagueId { return id }
        guard let uid = s.userId else {
            throw SleeperError.invalid("No league given and no Sleeper account connected. Ask for the user's Sleeper username and call set_user.")
        }
        let leagues = try Sleeper.leagues(userId: uid, season: try Sleeper.state().season)
        if leagues.count == 1 { return leagues[0].id }
        if leagues.isEmpty { throw SleeperError.notFound("\(s.username ?? "This user") has no NFL leagues this season.") }
        throw SleeperError.invalid("Several leagues; pass league_id (or call select_league): "
            + leagues.map { "\($0.name) = \($0.id)" }.joined(separator: "; "))
    }

    private func snapshot(_ a: [String: Any], projections: Bool = true) throws -> SleeperLeagueSnapshot {
        try SleeperLeagueSnapshot.load(leagueId: try leagueId(a), week: Sleeper.int(a["week"]), userId: settings.userId, withProjections: projections)
    }

    /// A player id from an id or a name ("Josh Allen", "Bills" for a defense).
    private func resolvePlayer(_ q: String, _ players: [String: SleeperPlayer]) throws -> SleeperPlayer {
        if let p = players[q] ?? players[q.uppercased()] { return p }
        guard let hit = Sleeper.search(q, in: players, limit: 1).first else { throw SleeperError.notFound("No player matches “\(q)”.") }
        return hit
    }

    /// Two decimals at most, written as such (a Double would print as 19.489999999999998).
    private func roundTo(_ d: Double?) -> Any { d.map { NSDecimalNumber(string: Sleeper.format($0)) } ?? NSNull() }

    /// A player as the tools show one, with this week's projection and points when known.
    private func row(_ id: String, _ s: SleeperLeagueSnapshot, points: Double? = nil, slot: String? = nil) -> [String: Any] {
        var j = s.player(id).json
        if let slot { j["slot"] = SleeperLeagueSnapshot.slotName(slot) }
        if let opp = s.opponent(id) { j["opponent"] = opp }
        if let proj = s.projected(id) { j["projected"] = roundTo(proj) }
        else if s.player(id).team != nil, !s.projections.isEmpty { j["projected"] = 0; j["note"] = "no projection (bye week or inactive)" }
        if let points { j["points"] = roundTo(points) }
        return j
    }

    private func teamSummary(_ r: SleeperRoster, _ s: SleeperLeagueSnapshot) -> [String: Any] {
        var j: [String: Any] = ["roster_id": r.rosterId, "team": s.teamName(r), "record": r.recordText,
                                "points_for": roundTo(r.pointsFor), "points_against": roundTo(r.pointsAgainst)]
        if let o = s.owner(of: r) { j["owner"] = o.displayName }
        if let st = r.streak { j["streak"] = st }
        if r.rosterId == s.myRosterId { j["is_user"] = true }
        return j
    }

    private func findRoster(_ a: [String: Any], _ s: SleeperLeagueSnapshot) throws -> SleeperRoster {
        if let rid = Sleeper.int(a["roster_id"]) {
            guard let r = s.roster(rid) else { throw SleeperError.notFound("No roster \(rid) in \(s.league.name).") }
            return r
        }
        if let q = str(a, "team")?.lowercased() {
            if let r = s.rosters.first(where: { s.teamName($0).lowercased().contains(q) || (s.owner(of: $0)?.displayName.lowercased().contains(q) ?? false) }) {
                return r
            }
            throw SleeperError.notFound("No team matching “\(q)” in \(s.league.name).")
        }
        guard let mine = s.myRosterId, let r = s.roster(mine) else {
            throw SleeperError.invalid("The connected user has no team in \(s.league.name); pass roster_id or team.")
        }
        return r
    }

    private func post(_ name: Notification.Name, _ info: [String: String]) {
        var i = info
        i["ppid"] = String(getppid())
        DistributedNotificationCenter.default().postNotificationName(name, object: nil, userInfo: i, deliverImmediately: true)
    }

    // MARK: Tools

    private func context() throws -> Any {
        let state = try Sleeper.state()
        var out: [String: Any] = ["nfl": ["season": state.season, "week": state.displayWeek, "season_type": state.seasonType],
                                  "api_note": "Sleeper's API is read-only: advise; the user makes moves in the Sleeper app."]
        let s = settings
        guard let uid = s.userId else {
            out["user"] = NSNull()
            out["next_step"] = "Ask for the user's Sleeper username, then call set_user."
            return out
        }
        out["user"] = ["username": s.username ?? "", "display_name": s.displayName ?? "", "user_id": uid]
        let leagues = try Sleeper.leagues(userId: uid, season: state.season)
        out["leagues"] = leagues.map { l -> [String: Any] in
            ["league_id": l.id, "name": l.name, "teams": l.totalRosters, "scoring": l.scoringName, "superflex": l.isSuperflex,
             "status": l.status, "waivers": l.usesFAAB ? "FAAB $\(l.waiverBudget)" : "rolling waivers", "selected": l.id == s.leagueId]
        }
        if s.leagueId == nil, leagues.count == 1 { out["selected_league"] = leagues[0].id }
        else if let id = s.leagueId { out["selected_league"] = id }
        return out
    }

    private func setUser(_ a: [String: Any]) throws -> Any {
        guard let name = str(a, "username") else { throw SleeperError.invalid("username is required") }
        let u = try Sleeper.user(name)
        var s = settings
        let changed = s.userId != u.id
        s.username = u.username
        s.userId = u.id
        s.displayName = u.displayName
        s.avatar = u.avatar
        if changed { s.leagueId = nil }
        if let l = str(a, "league_id") { s.leagueId = l }
        let leagues = try Sleeper.leagues(userId: u.id, season: try Sleeper.state().season)
        if s.leagueId == nil, leagues.count == 1 { s.leagueId = leagues[0].id }
        Sleeper.saveSettings(s)
        post(Sleeper.showNotification, ["view": "team", "reload": "1"])
        return try context()
    }

    private func selectLeague(_ a: [String: Any]) throws -> Any {
        guard let id = str(a, "league_id") else { throw SleeperError.invalid("league_id is required") }
        let l = try Sleeper.league(id)
        var s = settings
        s.leagueId = l.id
        Sleeper.saveSettings(s)
        post(Sleeper.showNotification, ["view": "team", "league_id": l.id, "reload": "1"])
        return "Selected \(l.name) (\(l.id))."
    }

    private func leagueOverview(_ a: [String: Any]) throws -> Any {
        let s = try snapshot(a, projections: false)
        let l = s.league
        let notable = ["rec", "pass_td", "pass_yd", "pass_int", "rush_yd", "rush_td", "rec_yd", "rec_td", "bonus_rec_te", "rush_att", "rec_fd", "rush_fd", "fum_lost"]
        var scoring: [String: Any] = [:]
        for k in notable { if let v = l.scoring[k], v != 0 { scoring[k] = roundTo(v) } }
        var settingsOut: [String: Any] = [
            "name": l.name, "season": l.season, "status": l.status, "teams": l.totalRosters, "scoring_type": l.scoringName,
            "scoring_highlights": scoring, "roster_positions": l.rosterPositions,
            "playoff_week_start": l.playoffWeekStart, "waivers": l.usesFAAB ? "FAAB, $\(l.waiverBudget) budget" : "rolling waiver order",
        ]
        if l.tradeDeadline > 0 { settingsOut["trade_deadline_week"] = l.tradeDeadline }
        return ["league": settingsOut, "current_week": s.week,
                "standings": s.standings.enumerated().map { i, r -> [String: Any] in
                    var t = teamSummary(r, s)
                    t["rank"] = i + 1
                    if l.usesFAAB { t["faab_left"] = l.waiverBudget - r.waiverBudgetUsed } else if let w = r.waiverPosition { t["waiver_position"] = w }
                    return t
                }]
    }

    private func roster(_ a: [String: Any]) throws -> Any {
        let s = try snapshot(a)
        let r = try findRoster(a, s)
        let m = s.matchup(for: r.rosterId)
        let pts = m?.playersPoints ?? [:]
        let slots = s.league.starterSlots
        // This week's lineup as set (the matchup's), else the roster's.
        let starters = m?.starters.isEmpty == false ? m!.starters : r.starters
        var out: [String: Any] = teamSummary(r, s)
        out["league"] = s.league.name
        out["week"] = s.week
        out["scoring"] = s.league.scoringName
        out["starters"] = starters.enumerated().map { i, id -> [String: Any] in
            if id == "0" { return ["slot": i < slots.count ? SleeperLeagueSnapshot.slotName(slots[i]) : "?", "empty": true] }
            return row(id, s, points: pts[id], slot: i < slots.count ? slots[i] : nil)
        }
        out["bench"] = r.bench.map { row($0, s, points: pts[$0]) }.sorted { (Sleeper.double($0["projected"]) ?? 0) > (Sleeper.double($1["projected"]) ?? 0) }
        if !r.reserve.isEmpty { out["injured_reserve"] = r.reserve.map { row($0, s) } }
        if !r.taxi.isEmpty { out["taxi"] = r.taxi.map { row($0, s) } }
        out["projected_starters_total"] = roundTo(s.projectedTotal(starters))
        if let m { out["points_this_week"] = roundTo(m.points) }
        if s.league.usesFAAB { out["faab_left"] = s.league.waiverBudget - r.waiverBudgetUsed } else if let w = r.waiverPosition { out["waiver_position"] = w }
        let flagged = (starters + r.bench).filter { s.player($0).injuryShort != nil }
        if !flagged.isEmpty { out["injury_flags"] = flagged.map { "\(s.player($0).name): \(s.player($0).injury ?? "")" } }
        return out
    }

    private func lineup(_ m: SleeperMatchup, _ s: SleeperLeagueSnapshot) -> [[String: Any]] {
        let slots = s.league.starterSlots
        return m.starters.enumerated().map { i, id -> [String: Any] in
            let slot = i < slots.count ? slots[i] : nil
            if id == "0" { return ["slot": slot.map(SleeperLeagueSnapshot.slotName) ?? "?", "empty": true] }
            return row(id, s, points: m.playersPoints[id] ?? (i < m.startersPoints.count ? m.startersPoints[i] : nil), slot: slot)
        }
    }

    private func matchup(_ a: [String: Any]) throws -> Any {
        let s = try snapshot(a)
        let rid = try Sleeper.int(a["roster_id"]) ?? findRoster(a, s).rosterId
        guard let mine = s.matchup(for: rid) else { throw SleeperError.notFound("No matchup for that team in week \(s.week).") }
        func side(_ m: SleeperMatchup) -> [String: Any] {
            var j: [String: Any] = s.roster(m.rosterId).map { teamSummary($0, s) } ?? ["roster_id": m.rosterId]
            j["points"] = roundTo(m.points)
            j["projected_total"] = roundTo(s.projectedTotal(m.starters))
            j["lineup"] = lineup(m, s)
            let bench = m.playersPointsKeysNotStarting
            if !bench.isEmpty { j["bench"] = bench.map { row($0, s, points: m.playersPoints[$0]) } }
            return j
        }
        var out: [String: Any] = ["league": s.league.name, "week": s.week, "team": side(mine)]
        if let opp = s.opponentMatchup(for: rid) { out["opponent"] = side(opp) } else { out["opponent"] = "bye or not set" }
        return out
    }

    private func scoreboard(_ a: [String: Any]) throws -> Any {
        let s = try snapshot(a)
        var groups: [Int: [SleeperMatchup]] = [:]
        for m in s.matchups { if let id = m.matchupId { groups[id, default: []].append(m) } }
        return ["league": s.league.name, "week": s.week,
                "matchups": groups.keys.sorted().map { k -> [[String: Any]] in
                    groups[k]!.map { m in
                        ["roster_id": m.rosterId, "team": s.teamName(rosterId: m.rosterId), "points": roundTo(m.points),
                         "projected_total": roundTo(s.projectedTotal(m.starters)), "is_user": m.rosterId == s.myRosterId]
                    }
                }]
    }

    private func freeAgents(_ a: [String: Any]) throws -> Any {
        let s = try snapshot(a)
        let limit = min(max(Sleeper.int(a["limit"]) ?? 25, 1), 100)
        let trend = Dictionary((try? Sleeper.trending("add", hours: 24, limit: 200)) ?? [], uniquingKeysWith: { a, _ in a })
        let fa = s.freeAgents(position: str(a, "position"), limit: limit)
        var out: [String: Any] = ["league": s.league.name, "week": s.week, "scoring": s.league.scoringName,
                                  "players": fa.map { p -> [String: Any] in
                                      var j = row(p.id, s)
                                      if let t = trend[p.id] { j["sleeper_adds_24h"] = t }
                                      return j
                                  }]
        if let mine = s.myRosterId.flatMap(s.roster) {
            out[s.league.usesFAAB ? "faab_left" : "waiver_position"] = s.league.usesFAAB ? s.league.waiverBudget - mine.waiverBudgetUsed : (mine.waiverPosition ?? 0)
        }
        return out
    }

    private func trending(_ a: [String: Any]) throws -> Any {
        let type = str(a, "type") ?? "add"
        let list = try Sleeper.trending(type, hours: min(max(Sleeper.int(a["hours"]) ?? 24, 1), 168), limit: min(max(Sleeper.int(a["limit"]) ?? 25, 1), 100))
        let players = try Sleeper.players()
        let snap = (try? leagueId(a)).flatMap { try? SleeperLeagueSnapshot.load(leagueId: $0, userId: settings.userId, withProjections: false) }
        return ["type": type, "league": snap?.league.name ?? NSNull(),
                "players": list.map { t -> [String: Any] in
                    var j = (players[t.id] ?? .unknown(t.id)).json
                    j["count"] = t.count
                    if let snap {
                        if let r = snap.rosterOf(t.id) { j["rostered_by"] = snap.teamName(r); if r.rosterId == snap.myRosterId { j["on_user_team"] = true } }
                        else { j["available"] = true }
                    }
                    return j
                }]
    }

    private func transactions(_ a: [String: Any]) throws -> Any {
        let s = try snapshot(a, projections: false)
        let weeks = Sleeper.int(a["week"]).map { [$0] } ?? [s.week, s.week - 1].filter { $0 >= 1 }
        let type = str(a, "type")
        var list: [SleeperTransaction] = []
        for w in weeks { list += (try? Sleeper.transactions(s.league.id, week: w)) ?? [] }
        list = list.filter { $0.status == "complete" && (type == nil || $0.type == type) }.sorted { $0.created > $1.created }
        let iso = ISO8601DateFormatter()
        return ["league": s.league.name, "weeks": weeks,
                "transactions": list.prefix(60).map { t -> [String: Any] in
                    var j: [String: Any] = ["type": t.type, "week": t.week, "when": iso.string(from: t.created),
                                            "teams": t.rosterIds.map { s.teamName(rosterId: $0) }]
                    if !t.adds.isEmpty { j["adds"] = t.adds.map { "\(s.player($0.key).name) (\(s.player($0.key).positionTeam)) → \(s.teamName(rosterId: $0.value))" } }
                    if !t.drops.isEmpty { j["drops"] = t.drops.map { "\(s.player($0.key).name) (\(s.player($0.key).positionTeam)) ← \(s.teamName(rosterId: $0.value))" } }
                    if let b = t.waiverBid { j["faab_bid"] = b }
                    if t.draftPicks > 0 { j["draft_picks"] = t.draftPicks }
                    return j
                }]
    }

    /// Points by week this season (league scoring), its average, and what's projected for the rest of it.
    private func history(_ p: SleeperPlayer, _ s: SleeperLeagueSnapshot) -> [String: Any] {
        let season = s.league.season.isEmpty ? s.state.season : s.league.season
        var j: [String: Any] = [:]
        if let weeks = try? Sleeper.playerWeeks(p.id, season: season, projected: false) {
            let played = weeks.filter { ($0.value.stats["gp"] ?? $0.value.stats["gms_active"] ?? 0) > 0 }
            let pts = played.keys.sorted().map { w -> [String: Any] in
                ["week": w, "points": roundTo(played[w]!.points(s.league.scoring)), "opponent": played[w]!.opponent ?? ""]
            }
            j["weekly_points"] = pts
            if !played.isEmpty {
                j["season_average"] = roundTo(played.values.map { $0.points(s.league.scoring) }.reduce(0, +) / Double(played.count))
                j["games_played"] = played.count
            }
        }
        if let proj = try? Sleeper.playerWeeks(p.id, season: season, projected: true) {
            let rest = proj.filter { $0.key >= s.week }
            if !rest.isEmpty {
                j["rest_of_season_projected"] = roundTo(rest.values.map { $0.points(s.league.scoring) }.reduce(0, +))
                j["upcoming"] = rest.keys.sorted().prefix(4).map { w -> [String: Any] in
                    ["week": w, "opponent": rest[w]!.opponent ?? "BYE", "projected": roundTo(rest[w]!.points(s.league.scoring))]
                }
            }
        }
        return j
    }

    private func player(_ a: [String: Any]) throws -> Any {
        guard let q = str(a, "player") else { throw SleeperError.invalid("player is required") }
        let s = try snapshot(a)
        let p = try resolvePlayer(q, s.players)
        var j = row(p.id, s)
        if let c = p.college { j["college"] = c }
        if let h = p.heightText { j["height"] = h }
        if let w = p.weight { j["weight_lbs"] = w }
        if let n = p.number { j["number"] = n }
        if let r = s.rosterOf(p.id) {
            j["rostered_by"] = s.teamName(r)
            if r.rosterId == s.myRosterId { j["on_user_team"] = true }
            j["starting_this_week"] = (s.matchup(for: r.rosterId)?.starters ?? r.starters).contains(p.id)
        } else {
            j["available"] = true
        }
        for (k, v) in history(p, s) { j[k] = v }
        return j
    }

    private func compare(_ a: [String: Any]) throws -> Any {
        let names = (a["players"] as? [Any] ?? []).compactMap { $0 as? String ?? Sleeper.int($0).map(String.init) }
        guard names.count >= 1 else { throw SleeperError.invalid("players: give 2-6 player ids or names") }
        let s = try snapshot(a)
        return ["week": s.week, "scoring": s.league.scoringName,
                "players": try names.prefix(6).map { q -> [String: Any] in
                    let p = try resolvePlayer(q, s.players)
                    var j = row(p.id, s)
                    if let r = s.rosterOf(p.id) { j["rostered_by"] = s.teamName(r) } else { j["available"] = true }
                    let h = history(p, s)
                    if let w = h["weekly_points"] as? [[String: Any]] { j["last_4_weeks"] = Array(w.suffix(4)) }
                    for k in ["season_average", "games_played", "rest_of_season_projected", "upcoming"] { j[k] = h[k] }
                    return j
                }]
    }

    private func searchPlayers(_ a: [String: Any]) throws -> Any {
        guard let q = str(a, "query") else { throw SleeperError.invalid("query is required") }
        let hits = Sleeper.search(q, in: try Sleeper.players(), position: str(a, "position"), limit: min(max(Sleeper.int(a["limit"]) ?? 10, 1), 50))
        return hits.map(\.json)
    }

    private func show(_ a: [String: Any]) throws -> Any {
        guard let view = str(a, "view") else { throw SleeperError.invalid("view is required") }
        var info: [String: String] = ["view": view]
        if let l = str(a, "league_id") { info["league_id"] = l }
        if let w = Sleeper.int(a["week"]) { info["week"] = String(w) }
        if let r = Sleeper.int(a["roster_id"]) { info["roster_id"] = String(r) }
        if let pos = str(a, "position") { info["position"] = pos.uppercased() }
        if let q = str(a, "player") {
            let p = try resolvePlayer(q, try Sleeper.players())
            info["player_id"] = p.id
            info["view"] = "player"
        }
        post(Sleeper.showNotification, info)
        return "Showing \(info["view"]!) in Solanum's Sleeper page. (If Solanum isn't running, nothing shows; the data tools still work.)"
    }

    private func annotate(_ a: [String: Any]) throws -> Any {
        let players = try Sleeper.players()
        var notes: [Sleeper.Advice.Note] = []
        var unknown: [String] = []
        for item in a["annotations"] as? [[String: Any]] ?? [] {
            guard let q = str(item, "player") ?? str(item, "player_id") else { continue }
            guard let p = try? resolvePlayer(q, players) else { unknown.append(q); continue }
            notes.append(.init(playerId: p.id, tag: (str(item, "tag") ?? "watch").lowercased(), reason: str(item, "reason") ?? ""))
        }
        let advice = Sleeper.Advice(leagueId: str(a, "league_id") ?? settings.leagueId, title: str(a, "title"),
                                    summary: str(a, "summary") ?? "", notes: notes)
        Sleeper.saveAdvice(advice)
        post(Sleeper.adviceNotification, [:])
        return "Annotated \(notes.count) player\(notes.count == 1 ? "" : "s") on the Sleeper page." + (unknown.isEmpty ? "" : " Not found: \(unknown.joined(separator: ", ")).")
    }
}

private extension SleeperMatchup {
    /// Players who scored (or could have) for the team this week but didn't start.
    var playersPointsKeysNotStarting: [String] {
        let s = Set(starters)
        return playersPoints.keys.filter { !s.contains($0) }.sorted { (playersPoints[$0] ?? 0) > (playersPoints[$1] ?? 0) }
    }
}
