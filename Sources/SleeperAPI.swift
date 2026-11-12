import Foundation

// Sleeper (sleeper.com) fantasy football, read through its public API (https://docs.sleeper.com): users, leagues,
// rosters, matchups, transactions, trending players and the NFL player list, plus the projections and weekly stats
// its own app uses. The API is read-only and needs no login: a username is enough. Moves (adds, drops, trades,
// lineups) are made in the Sleeper app; Solanum and Claude read, track and advise.
//
// Foundation only: the same code serves the Sleeper page (SleeperPage.swift, on background queues) and the MCP
// server Claude Code runs (`Solanum --mcp sleeper`, SleeperMCP.swift), which has no AppKit app around it.

enum SleeperError: LocalizedError {
    case http(Int, String)
    case network(String)
    case notFound(String)
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .http(let code, let url): return "Sleeper answered \(code) for \(url)."
        case .network(let m): return "Couldn't reach Sleeper: \(m)"
        case .notFound(let m), .invalid(let m): return m
        }
    }
}

// MARK: Models

struct SleeperPlayer {
    let id: String
    let first: String
    let last: String
    let position: String
    let team: String?
    let status: String?
    let injury: String?
    let injuryBody: String?
    let injuryNotes: String?
    let age: Int?
    let yearsExp: Int?
    let college: String?
    let height: String?
    let weight: String?
    let number: Int?
    let depthPosition: String?
    let depthOrder: Int?
    let searchRank: Int?
    let fantasyPositions: [String]
    let active: Bool

    var name: String {
        if position == "DEF" { return [first, last].filter { !$0.isEmpty }.joined(separator: " ") }
        return [first, last].filter { !$0.isEmpty }.joined(separator: " ")
    }
    var isDefense: Bool { position == "DEF" }
    /// "WR · KC", "DEF", "RB · FA".
    var positionTeam: String { isDefense ? "DEF" : "\(position) · \(team ?? "FA")" }

    /// Q, D, O, IR, PUP, SUS…; nil when healthy.
    var injuryShort: String? {
        guard let s = injury, !s.isEmpty else { return nil }
        switch s.lowercased() {
        case "questionable": return "Q"
        case "doubtful": return "D"
        case "out": return "O"
        case "ir": return "IR"
        case "pup": return "PUP"
        case "sus": return "SUS"
        case "cov": return "COV"
        case "na": return nil
        default: return s.uppercased()
        }
    }

    /// Headshot (or team logo, for a defense).
    var photoURL: URL? {
        isDefense ? URL(string: "https://sleepercdn.com/images/team_logos/nfl/\(id.lowercased()).png")
                  : URL(string: "https://sleepercdn.com/content/nfl/players/thumb/\(id).jpg")
    }
    var teamLogoURL: URL? { team.flatMap { URL(string: "https://sleepercdn.com/images/team_logos/nfl/\($0.lowercased()).png") } }

    /// Height in inches, as 6'2".
    var heightText: String? {
        guard let h = height, let n = Int(h), n > 0 else { return height }
        return "\(n / 12)'\(n % 12)\""
    }

    init(id: String, j: [String: Any]) {
        self.id = id
        first = j["first_name"] as? String ?? ""
        last = j["last_name"] as? String ?? ""
        position = j["position"] as? String ?? (j["fantasy_positions"] as? [String])?.first ?? ""
        team = j["team"] as? String
        status = j["status"] as? String
        injury = j["injury_status"] as? String
        injuryBody = j["injury_body_part"] as? String
        injuryNotes = j["injury_notes"] as? String
        age = Sleeper.int(j["age"])
        yearsExp = Sleeper.int(j["years_exp"])
        college = j["college"] as? String
        height = (j["height"] as? String) ?? Sleeper.int(j["height"]).map(String.init)
        weight = (j["weight"] as? String) ?? Sleeper.int(j["weight"]).map(String.init)
        number = Sleeper.int(j["number"])
        depthPosition = j["depth_chart_position"] as? String
        depthOrder = Sleeper.int(j["depth_chart_order"])
        searchRank = Sleeper.int(j["search_rank"])
        fantasyPositions = j["fantasy_positions"] as? [String] ?? []
        active = j["active"] as? Bool ?? false
    }

    /// The fields kept in the slimmed cache (the full list is ~15 MB).
    static let keptKeys = ["first_name", "last_name", "position", "team", "status", "injury_status", "injury_body_part",
                           "injury_notes", "age", "years_exp", "college", "height", "weight", "number", "depth_chart_position",
                           "depth_chart_order", "search_rank", "fantasy_positions", "active"]

    /// For a player id Sleeper doesn't know (yet).
    static func unknown(_ id: String) -> SleeperPlayer { SleeperPlayer(id: id, j: ["first_name": "Player", "last_name": id]) }

    var json: [String: Any] {
        var j: [String: Any] = ["player_id": id, "name": name, "position": position, "team": team ?? "FA"]
        if let injury { j["injury_status"] = injury }
        if let injuryBody { j["injury"] = injuryBody }
        if let injuryNotes { j["injury_notes"] = injuryNotes }
        if let status, status != "Active" { j["status"] = status }
        if let age { j["age"] = age }
        if let yearsExp { j["years_exp"] = yearsExp }
        if let depthPosition, let depthOrder { j["depth_chart"] = "\(depthPosition)\(depthOrder)" }
        return j
    }
}

struct SleeperUser {
    let id: String
    let username: String
    let displayName: String
    let avatar: String?

    init?(_ j: [String: Any]) {
        guard let id = j["user_id"] as? String else { return nil }
        self.id = id
        username = j["username"] as? String ?? ""
        displayName = j["display_name"] as? String ?? username
        avatar = j["avatar"] as? String
    }
}

struct SleeperLeague {
    let id: String
    let name: String
    let season: String
    let status: String
    let totalRosters: Int
    let rosterPositions: [String]
    let scoring: [String: Double]
    let avatar: String?
    let waiverType: Int
    let waiverBudget: Int
    let playoffWeekStart: Int
    let tradeDeadline: Int
    let reserveSlots: Int
    let taxiSlots: Int
    let previousLeagueId: String?

    init?(_ j: [String: Any]) {
        guard let id = j["league_id"] as? String else { return nil }
        self.id = id
        name = j["name"] as? String ?? "League"
        season = j["season"] as? String ?? ""
        status = j["status"] as? String ?? ""
        totalRosters = Sleeper.int(j["total_rosters"]) ?? 0
        rosterPositions = j["roster_positions"] as? [String] ?? []
        var sc: [String: Double] = [:]
        for (k, v) in j["scoring_settings"] as? [String: Any] ?? [:] { if let d = Sleeper.double(v) { sc[k] = d } }
        scoring = sc
        avatar = j["avatar"] as? String
        let s = j["settings"] as? [String: Any] ?? [:]
        waiverType = Sleeper.int(s["waiver_type"]) ?? 0
        waiverBudget = Sleeper.int(s["waiver_budget"]) ?? 0
        playoffWeekStart = Sleeper.int(s["playoff_week_start"]) ?? 15
        tradeDeadline = Sleeper.int(s["trade_deadline"]) ?? 0
        reserveSlots = Sleeper.int(s["reserve_slots"]) ?? 0
        taxiSlots = Sleeper.int(s["taxi_slots"]) ?? 0
        previousLeagueId = j["previous_league_id"] as? String
    }

    /// FAAB (a budget to bid) rather than rolling waiver order.
    var usesFAAB: Bool { waiverType == 2 }
    /// "PPR", "Half PPR", "Standard", or "0.75 PPR".
    var scoringName: String {
        switch scoring["rec"] ?? 0 {
        case 1: return "PPR"
        case 0.5: return "Half PPR"
        case 0: return "Standard"
        case let r: return "\(Sleeper.format(r)) PPR"
        }
    }
    /// Starting slots, without bench, IR and taxi.
    var starterSlots: [String] { rosterPositions.filter { !["BN", "IR", "TAXI"].contains($0) } }
    var isSuperflex: Bool { rosterPositions.contains("SUPER_FLEX") }
    var avatarURL: URL? { avatar.flatMap { URL(string: "https://sleepercdn.com/avatars/thumbs/\($0)") } }
}

struct SleeperLeagueUser {
    let id: String
    let displayName: String
    let teamName: String?
    let avatar: String?
    /// A team picture the owner uploaded (a full URL), in place of their avatar.
    let teamAvatarURL: String?

    init?(_ j: [String: Any]) {
        guard let id = j["user_id"] as? String else { return nil }
        self.id = id
        displayName = j["display_name"] as? String ?? "Owner"
        let meta = j["metadata"] as? [String: Any] ?? [:]
        let tn = (meta["team_name"] as? String)?.trimmingCharacters(in: .whitespaces)
        teamName = tn?.isEmpty == false ? tn : nil
        avatar = j["avatar"] as? String
        teamAvatarURL = (meta["avatar"] as? String).flatMap { $0.hasPrefix("http") ? $0 : nil }
    }

    var avatarURL: URL? {
        if let t = teamAvatarURL { return URL(string: t) }
        return avatar.flatMap { URL(string: "https://sleepercdn.com/avatars/thumbs/\($0)") }
    }
}

struct SleeperRoster {
    let rosterId: Int
    let ownerId: String?
    let coOwners: [String]
    let players: [String]
    let starters: [String]
    let reserve: [String]
    let taxi: [String]
    let wins: Int
    let losses: Int
    let ties: Int
    let pointsFor: Double
    let pointsAgainst: Double
    let maxPoints: Double
    let waiverPosition: Int?
    let waiverBudgetUsed: Int
    let streak: String?
    let record: String?

    init?(_ j: [String: Any]) {
        guard let rid = Sleeper.int(j["roster_id"]) else { return nil }
        rosterId = rid
        ownerId = j["owner_id"] as? String
        coOwners = j["co_owners"] as? [String] ?? []
        players = j["players"] as? [String] ?? []
        starters = j["starters"] as? [String] ?? []
        reserve = j["reserve"] as? [String] ?? []
        taxi = j["taxi"] as? [String] ?? []
        let s = j["settings"] as? [String: Any] ?? [:]
        func pts(_ k: String) -> Double { Double(Sleeper.int(s[k]) ?? 0) + Double(Sleeper.int(s[k + "_decimal"]) ?? 0) / 100 }
        wins = Sleeper.int(s["wins"]) ?? 0
        losses = Sleeper.int(s["losses"]) ?? 0
        ties = Sleeper.int(s["ties"]) ?? 0
        pointsFor = pts("fpts")
        pointsAgainst = pts("fpts_against")
        maxPoints = pts("ppts")
        waiverPosition = Sleeper.int(s["waiver_position"])
        waiverBudgetUsed = Sleeper.int(s["waiver_budget_used"]) ?? 0
        let meta = j["metadata"] as? [String: Any] ?? [:]
        streak = meta["streak"] as? String
        record = meta["record"] as? String
    }

    var recordText: String { ties > 0 ? "\(wins)-\(losses)-\(ties)" : "\(wins)-\(losses)" }
    var bench: [String] {
        let skip = Set(starters).union(reserve).union(taxi)
        return players.filter { !skip.contains($0) }
    }
}

struct SleeperMatchup {
    let rosterId: Int
    let matchupId: Int?
    let points: Double
    let starters: [String]
    let startersPoints: [Double]
    let playersPoints: [String: Double]

    init?(_ j: [String: Any]) {
        guard let rid = Sleeper.int(j["roster_id"]) else { return nil }
        rosterId = rid
        matchupId = Sleeper.int(j["matchup_id"])
        points = Sleeper.double(j["custom_points"]) ?? Sleeper.double(j["points"]) ?? 0
        starters = j["starters"] as? [String] ?? []
        startersPoints = (j["starters_points"] as? [Any] ?? []).map { Sleeper.double($0) ?? 0 }
        var pp: [String: Double] = [:]
        for (k, v) in j["players_points"] as? [String: Any] ?? [:] { pp[k] = Sleeper.double(v) ?? 0 }
        playersPoints = pp
    }
}

struct SleeperTransaction {
    let id: String
    let type: String
    let status: String
    let created: Date
    let adds: [String: Int]
    let drops: [String: Int]
    let rosterIds: [Int]
    let waiverBid: Int?
    let week: Int
    let draftPicks: Int
    let notes: String?

    init?(_ j: [String: Any]) {
        guard let id = j["transaction_id"] as? String else { return nil }
        self.id = id
        type = j["type"] as? String ?? ""
        status = j["status"] as? String ?? ""
        created = Date(timeIntervalSince1970: (Sleeper.double(j["status_updated"]) ?? Sleeper.double(j["created"]) ?? 0) / 1000)
        var a: [String: Int] = [:], d: [String: Int] = [:]
        for (k, v) in j["adds"] as? [String: Any] ?? [:] { if let r = Sleeper.int(v) { a[k] = r } }
        for (k, v) in j["drops"] as? [String: Any] ?? [:] { if let r = Sleeper.int(v) { d[k] = r } }
        adds = a
        drops = d
        rosterIds = (j["roster_ids"] as? [Any] ?? []).compactMap(Sleeper.int)
        waiverBid = Sleeper.int((j["settings"] as? [String: Any])?["waiver_bid"])
        week = Sleeper.int(j["leg"]) ?? 0
        draftPicks = (j["draft_picks"] as? [Any])?.count ?? 0
        notes = (j["metadata"] as? [String: Any])?["notes"] as? String
    }

    /// "Waiver", "Free Agent", "Trade", "Commissioner".
    var typeName: String {
        switch type {
        case "waiver": return "Waiver"
        case "free_agent": return "Free Agent"
        case "trade": return "Trade"
        case "commissioner": return "Commissioner"
        default: return type.capitalized
        }
    }
}

struct SleeperNFLState {
    let season: String
    let week: Int
    let displayWeek: Int
    let seasonType: String

    init(_ j: [String: Any]) {
        season = j["season"] as? String ?? String(Calendar.current.component(.year, from: Date()))
        week = max(1, Sleeper.int(j["week"]) ?? 1)
        displayWeek = max(1, Sleeper.int(j["display_week"]) ?? week)
        seasonType = j["season_type"] as? String ?? "regular"
    }
}

/// One player's projected (or actual) stat line for a week.
struct SleeperStatLine {
    let stats: [String: Double]
    let team: String?
    let opponent: String?

    /// Fantasy points under a league's scoring (Sleeper's own pts_ppr / half / std without one).
    func points(_ scoring: [String: Double]?) -> Double {
        guard let scoring, !scoring.isEmpty else { return stats["pts_ppr"] ?? 0 }
        return Sleeper.points(stats, scoring)
    }
}

// MARK: Client

enum Sleeper {
    static let base = "https://api.sleeper.app/v1"

    /// ~/.config/solanum/extensions/sleeper (or under `SOLANUM_CONFIG_DIR`).
    static var dir: URL {
        let d = Config.shared.dir.appendingPathComponent("extensions/sleeper", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    // MARK: Numbers

    static func int(_ v: Any?) -> Int? {
        switch v {
        case let i as Int: return i
        case let d as Double: return Int(d)
        case let n as NSNumber: return n.intValue
        case let s as String: return Int(s)
        default: return nil
        }
    }

    static func double(_ v: Any?) -> Double? {
        switch v {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }

    /// 12.5 → "12.5", 12 → "12", 12.345 → "12.35".
    static func format(_ d: Double) -> String {
        let r = (d * 100).rounded() / 100
        if r == r.rounded() { return String(Int(r)) }
        return String(format: (r * 10).rounded() == r * 10 ? "%.1f" : "%.2f", r)
    }

    /// Points for a stat line under `scoring`. Projections give some stats in other buckets than leagues score them
    /// (field goals of 50+ yards, misses by distance), so those are matched up.
    static func points(_ stats: [String: Double], _ scoring: [String: Double]) -> Double {
        var s = stats
        if s["fgm_50_59"] == nil, let v = s["fgm_50p"] { s["fgm_50_59"] = v }
        if s["fgmiss"] == nil {
            let misses = s.filter { $0.key.hasPrefix("fgmiss_") }.values.reduce(0, +)
            if misses > 0 { s["fgmiss"] = misses }
        }
        var total = 0.0
        for (k, w) in scoring { if let v = s[k] { total += v * w } }
        return (total * 100).rounded() / 100
    }

    // MARK: HTTP

    private static let lock = NSLock()
    private static var memo: [String: (expires: Date, value: Any)] = [:]

    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 25
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.httpAdditionalHeaders = ["User-Agent": "Solanum"]
        return URLSession(configuration: c)
    }()

    /// Blocks until the answer comes back: never call it on the main thread.
    static func fetch(_ url: URL) throws -> Data {
        let sem = DispatchSemaphore(value: 0)
        var result: Result<Data, Error> = .failure(SleeperError.network("no answer"))
        session.dataTask(with: url) { data, response, error in
            if let error {
                result = .failure(SleeperError.network(error.localizedDescription))
            } else if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                result = .failure(SleeperError.http(http.statusCode, url.path))
            } else {
                result = .success(data ?? Data())
            }
            sem.signal()
        }.resume()
        sem.wait()
        return try result.get()
    }

    /// JSON at `path` (under the v1 API, or a full URL), kept for `ttl` seconds.
    static func json(_ path: String, ttl: TimeInterval = 60) throws -> Any {
        let full = path.hasPrefix("http") ? path : base + path
        lock.lock()
        if let hit = memo[full], hit.expires > Date() { lock.unlock(); return hit.value }
        lock.unlock()
        guard let url = URL(string: full) else { throw SleeperError.invalid("Bad URL: \(full)") }
        let data = try fetch(url)
        // Sleeper answers `null` for things that don't exist (an unknown user).
        let value = (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) ?? NSNull()
        lock.lock()
        memo[full] = (Date().addingTimeInterval(ttl), value)
        if memo.count > 400 { memo = memo.filter { $0.value.expires > Date() } }
        lock.unlock()
        return value
    }

    /// Forgets cached answers (Refresh), except the player list.
    static func clearCache() {
        lock.lock()
        memo = [:]
        lock.unlock()
    }

    // MARK: Endpoints

    static func state() throws -> SleeperNFLState {
        SleeperNFLState(try json("/state/nfl", ttl: 600) as? [String: Any] ?? [:])
    }

    static func user(_ nameOrId: String) throws -> SleeperUser {
        let q = nameOrId.trimmingCharacters(in: .whitespaces).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? nameOrId
        guard let j = try json("/user/\(q)", ttl: 3600) as? [String: Any], let u = SleeperUser(j) else {
            throw SleeperError.notFound("There's no Sleeper user named “\(nameOrId)”.")
        }
        return u
    }

    static func leagues(userId: String, season: String) throws -> [SleeperLeague] {
        (try json("/user/\(userId)/leagues/nfl/\(season)", ttl: 600) as? [[String: Any]] ?? []).compactMap(SleeperLeague.init)
    }

    static func league(_ id: String) throws -> SleeperLeague {
        guard let j = try json("/league/\(id)", ttl: 600) as? [String: Any], let l = SleeperLeague(j) else {
            throw SleeperError.notFound("There's no Sleeper league \(id).")
        }
        return l
    }

    static func rosters(_ leagueId: String) throws -> [SleeperRoster] {
        (try json("/league/\(leagueId)/rosters", ttl: 60) as? [[String: Any]] ?? []).compactMap(SleeperRoster.init)
    }

    static func users(_ leagueId: String) throws -> [SleeperLeagueUser] {
        (try json("/league/\(leagueId)/users", ttl: 600) as? [[String: Any]] ?? []).compactMap(SleeperLeagueUser.init)
    }

    static func matchups(_ leagueId: String, week: Int) throws -> [SleeperMatchup] {
        (try json("/league/\(leagueId)/matchups/\(week)", ttl: 45) as? [[String: Any]] ?? []).compactMap(SleeperMatchup.init)
    }

    static func transactions(_ leagueId: String, week: Int) throws -> [SleeperTransaction] {
        (try json("/league/\(leagueId)/transactions/\(week)", ttl: 120) as? [[String: Any]] ?? []).compactMap(SleeperTransaction.init)
    }

    /// Players most added (or dropped) across Sleeper lately: (player id, count).
    static func trending(_ type: String, hours: Int = 24, limit: Int = 25) throws -> [(id: String, count: Int)] {
        let t = type == "drop" ? "drop" : "add"
        let list = try json("/players/nfl/trending/\(t)?lookback_hours=\(hours)&limit=\(limit)", ttl: 600) as? [[String: Any]] ?? []
        return list.compactMap { j in (j["player_id"] as? String).map { ($0, Sleeper.int(j["count"]) ?? 0) } }
    }

    /// Every player's projected stat line for a week (Sleeper's own projections, as its app shows).
    static func projections(season: String, week: Int) throws -> [String: SleeperStatLine] {
        try weekly("https://api.sleeper.app/projections/nfl/\(season)/\(week)", ttl: 1800)
    }

    /// Every player's actual stat line for a week.
    static func stats(season: String, week: Int) throws -> [String: SleeperStatLine] {
        try weekly("https://api.sleeper.app/stats/nfl/\(season)/\(week)", ttl: 300)
    }

    private static func weekly(_ base: String, ttl: TimeInterval) throws -> [String: SleeperStatLine] {
        let positions = ["QB", "RB", "WR", "TE", "K", "DEF"].map { "position[]=\($0)" }.joined(separator: "&")
        let list = try json("\(base)?season_type=regular&\(positions)", ttl: ttl) as? [[String: Any]] ?? []
        var out: [String: SleeperStatLine] = [:]
        for j in list {
            guard let id = j["player_id"] as? String else { continue }
            var st: [String: Double] = [:]
            for (k, v) in j["stats"] as? [String: Any] ?? [:] { if let d = double(v) { st[k] = d } }
            out[id] = SleeperStatLine(stats: st, team: j["team"] as? String, opponent: j["opponent"] as? String)
        }
        return out
    }

    /// One player's stat lines (or projections) for each week of a season, by week.
    static func playerWeeks(_ id: String, season: String, projected: Bool) throws -> [Int: SleeperStatLine] {
        let kind = projected ? "projections" : "stats"
        let j = try json("https://api.sleeper.com/\(kind)/nfl/player/\(id)?season_type=regular&season=\(season)&grouping=week", ttl: 900)
        var out: [Int: SleeperStatLine] = [:]
        for (k, v) in j as? [String: Any] ?? [:] {
            guard let week = Int(k), let e = v as? [String: Any] else { continue }
            var st: [String: Double] = [:]
            for (sk, sv) in e["stats"] as? [String: Any] ?? [:] { if let d = double(sv) { st[sk] = d } }
            out[week] = SleeperStatLine(stats: st, team: e["team"] as? String, opponent: e["opponent"] as? String)
        }
        return out
    }

    // MARK: Players

    private static var playerCache: [String: SleeperPlayer]?
    private static let playerLock = NSLock()
    static var playersFile: URL { dir.appendingPathComponent("players.json") }

    /// Every NFL player Sleeper knows, by id. Downloaded once a day (about 15 MB) and kept slimmed on disk, shared
    /// by the page and the MCP server. A list from an earlier day is used straight away and replaced in the
    /// background: waiting on the download held the page at "Loading your league…" for several seconds each day.
    static func players() throws -> [String: SleeperPlayer] {
        playerLock.lock()
        defer { playerLock.unlock() }
        let file = playersFile
        let age = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { -$0.timeIntervalSinceNow }
        let fresh = age.map { $0 < 86_400 } ?? false
        if let cached = playerCache {
            if !fresh { refreshPlayersLater() }
            return cached
        }
        if let map = readPlayers(file) {
            playerCache = map
            if !fresh { refreshPlayersLater() }
            return map
        }
        // None on disk yet: this once, the download is waited for.
        let map = try downloadPlayers()
        playerCache = map
        return map
    }

    private static var refreshingPlayers = false

    /// Replaces the list in the background (once at a time); the next read gets the new one.
    private static func refreshPlayersLater() {
        guard !refreshingPlayers else { return }
        refreshingPlayers = true
        DispatchQueue.global(qos: .utility).async {
            let map = try? downloadPlayers()
            playerLock.lock()
            if let map { playerCache = map }
            refreshingPlayers = false
            playerLock.unlock()
        }
    }

    private static func readPlayers(_ file: URL) -> [String: SleeperPlayer]? {
        guard let data = try? Data(contentsOf: file), let j = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else { return nil }
        return Dictionary(uniqueKeysWithValues: j.map { ($0.key, SleeperPlayer(id: $0.key, j: $0.value)) })
    }

    /// The whole list from Sleeper, slimmed to what's used and saved for next time.
    private static func downloadPlayers() throws -> [String: SleeperPlayer] {
        let data = try fetch(URL(string: base + "/players/nfl")!)
        guard let all = try JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else {
            throw SleeperError.invalid("Sleeper's player list didn't read.")
        }
        var slim: [String: [String: Any]] = [:]
        for (id, p) in all {
            // Retired and long-gone players with no team and no fantasy position aren't worth keeping.
            guard p["fantasy_positions"] is [Any] || p["position"] as? String == "DEF" else { continue }
            var keep: [String: Any] = [:]
            for k in SleeperPlayer.keptKeys { if let v = p[k], !(v is NSNull) { keep[k] = v } }
            slim[id] = keep
        }
        if let out = try? JSONSerialization.data(withJSONObject: slim) { try? out.write(to: playersFile, options: .atomic) }
        return Dictionary(uniqueKeysWithValues: slim.map { ($0.key, SleeperPlayer(id: $0.key, j: $0.value)) })
    }

    /// Players whose name matches `query` (every word, any order), best known first.
    static func search(_ query: String, in players: [String: SleeperPlayer], position: String? = nil, limit: Int = 10) -> [SleeperPlayer] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        let pos = position?.uppercased()
        let hits = players.values.filter { p in
            if let pos, !pos.isEmpty, p.position != pos, !p.fantasyPositions.contains(pos) { return false }
            let hay = (p.name + " " + (p.team ?? "")).lowercased()
            return words.allSatisfy { hay.contains($0) }
        }
        return hits.sorted { a, b in
            if a.active != b.active { return a.active }
            if (a.team != nil) != (b.team != nil) { return a.team != nil }
            return (a.searchRank ?? 99999) < (b.searchRank ?? 99999)
        }.prefix(limit).map { $0 }
    }

    // MARK: Settings shared by the page and the MCP server

    struct Settings {
        var username: String?
        var userId: String?
        var displayName: String?
        var avatar: String?
        /// The league the page shows, and the MCP tools use when none is named.
        var leagueId: String?

        var json: [String: Any] {
            var j: [String: Any] = [:]
            if let username { j["username"] = username }
            if let userId { j["user_id"] = userId }
            if let displayName { j["display_name"] = displayName }
            if let avatar { j["avatar"] = avatar }
            if let leagueId { j["league_id"] = leagueId }
            return j
        }
    }

    static var settingsFile: URL { dir.appendingPathComponent("settings.json") }

    static func loadSettings() -> Settings {
        guard let data = try? Data(contentsOf: settingsFile),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return Settings() }
        return Settings(username: j["username"] as? String, userId: j["user_id"] as? String, displayName: j["display_name"] as? String,
                        avatar: j["avatar"] as? String, leagueId: j["league_id"] as? String)
    }

    static func saveSettings(_ s: Settings) {
        if let data = try? JSONSerialization.data(withJSONObject: s.json, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: settingsFile, options: .atomic)
        }
    }

    // MARK: Claude's notes for the page

    /// What Claude marked on the page (through the MCP server's sleeper_annotate): a summary, and players tagged
    /// start / sit / add / drop / trade / watch with a reason each.
    struct Advice {
        struct Note {
            let playerId: String
            let tag: String
            let reason: String
        }
        var leagueId: String?
        /// The NFL week it's about: shown on the page only there (a week-9 "PIT bye" isn't week 10's).
        var week: Int?
        var title: String?
        var summary: String
        var notes: [Note]
        var updated: Date

        var json: [String: Any] {
            var j: [String: Any] = ["summary": summary, "updated": updated.timeIntervalSince1970,
                                    "annotations": notes.map { ["player_id": $0.playerId, "tag": $0.tag, "reason": $0.reason] }]
            if let leagueId { j["league_id"] = leagueId }
            if let week { j["week"] = week }
            if let title { j["title"] = title }
            return j
        }

        init(leagueId: String?, week: Int?, title: String?, summary: String, notes: [Note], updated: Date = Date()) {
            self.leagueId = leagueId
            self.week = week
            self.title = title
            self.summary = summary
            self.notes = notes
            self.updated = updated
        }

        init?(_ j: [String: Any]) {
            leagueId = j["league_id"] as? String
            title = j["title"] as? String
            // Notes written before the week was kept: the "Week 9" their title has, if any.
            week = (j["week"] as? NSNumber)?.intValue ?? title.flatMap(Advice.week(in:))
            summary = j["summary"] as? String ?? ""
            notes = (j["annotations"] as? [[String: Any]] ?? []).compactMap { a in
                guard let id = a["player_id"] as? String else { return nil }
                return Note(playerId: id, tag: (a["tag"] as? String ?? "watch").lowercased(), reason: a["reason"] as? String ?? "")
            }
            updated = Date(timeIntervalSince1970: Sleeper.double(j["updated"]) ?? 0)
            if summary.isEmpty && notes.isEmpty { return nil }
        }

        func note(for playerId: String) -> Note? { notes.last { $0.playerId == playerId } }

        /// The N of "Week N" in `s`.
        static func week(in s: String) -> Int? {
            guard let r = s.range(of: #"(?i)\bweek\s+(\d{1,2})\b"#, options: .regularExpression) else { return nil }
            return Int(s[r].filter(\.isNumber))
        }
    }

    static var adviceFile: URL { dir.appendingPathComponent("advice.json") }

    static func loadAdvice() -> Advice? {
        guard let data = try? Data(contentsOf: adviceFile),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return Advice(j)
    }

    static func saveAdvice(_ a: Advice?) {
        guard let a else { try? FileManager.default.removeItem(at: adviceFile); return }
        if let data = try? JSONSerialization.data(withJSONObject: a.json, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: adviceFile, options: .atomic)
        }
    }

    // MARK: Between the MCP server and the app

    /// Posted by the MCP server (another process) for the app: show something (userInfo: view, league_id, week,
    /// player_id, roster_id, ppid), or Claude's notes changed (advice).
    static let showNotification = Notification.Name("local.solanum.sleeper.show")
    static let adviceNotification = Notification.Name("local.solanum.sleeper.advice")
}

// MARK: A league, all at once

/// Everything about one league for one week that the page and the tools need, fetched together.
struct SleeperLeagueSnapshot {
    let state: SleeperNFLState
    let league: SleeperLeague
    let users: [SleeperLeagueUser]
    let rosters: [SleeperRoster]
    let week: Int
    let matchups: [SleeperMatchup]
    let players: [String: SleeperPlayer]
    /// This week's projections (empty when Sleeper didn't give them).
    let projections: [String: SleeperStatLine]
    /// The roster of the signed-in user, if they're in this league.
    let myRosterId: Int?

    static func load(leagueId: String, week: Int? = nil, userId: String? = nil, withProjections: Bool = true) throws -> SleeperLeagueSnapshot {
        let state = try Sleeper.state()
        let league = try Sleeper.league(leagueId)
        let users = try Sleeper.users(leagueId)
        let rosters = try Sleeper.rosters(leagueId)
        let w = week ?? (league.season == state.season ? state.displayWeek : 1)
        let matchups = (try? Sleeper.matchups(leagueId, week: w)) ?? []
        let players = try Sleeper.players()
        let season = league.season.isEmpty ? state.season : league.season
        let projections = withProjections ? ((try? Sleeper.projections(season: season, week: w)) ?? [:]) : [:]
        let mine = userId.flatMap { uid in rosters.first { $0.ownerId == uid || $0.coOwners.contains(uid) }?.rosterId }
        return SleeperLeagueSnapshot(state: state, league: league, users: users, rosters: rosters, week: w, matchups: matchups,
                                     players: players, projections: projections, myRosterId: mine)
    }

    func player(_ id: String) -> SleeperPlayer { players[id] ?? SleeperPlayer.unknown(id) }
    func roster(_ id: Int) -> SleeperRoster? { rosters.first { $0.rosterId == id } }
    func owner(of r: SleeperRoster) -> SleeperLeagueUser? { r.ownerId.flatMap { id in users.first { $0.id == id } } }
    func teamName(_ r: SleeperRoster) -> String {
        if let o = owner(of: r) { return o.teamName ?? o.displayName }
        return "Team \(r.rosterId)"
    }
    func teamName(rosterId: Int) -> String { roster(rosterId).map(teamName) ?? "Team \(rosterId)" }

    /// The roster a player is on, if any.
    func rosterOf(_ playerId: String) -> SleeperRoster? { rosters.first { $0.players.contains(playerId) } }
    var rostered: Set<String> { Set(rosters.flatMap(\.players)) }

    func projected(_ playerId: String) -> Double? {
        projections[playerId].map { $0.points(league.scoring) }
    }
    func opponent(_ playerId: String) -> String? { projections[playerId]?.opponent }

    func matchup(for rosterId: Int) -> SleeperMatchup? { matchups.first { $0.rosterId == rosterId } }
    func opponentMatchup(for rosterId: Int) -> SleeperMatchup? {
        guard let m = matchup(for: rosterId), let mid = m.matchupId else { return nil }
        return matchups.first { $0.matchupId == mid && $0.rosterId != rosterId }
    }

    /// Standings: wins, then points for.
    var standings: [SleeperRoster] {
        rosters.sorted { a, b in
            let pa = Double(a.wins) + Double(a.ties) / 2, pb = Double(b.wins) + Double(b.ties) / 2
            return pa != pb ? pa > pb : a.pointsFor > b.pointsFor
        }
    }

    /// Projected points for a lineup (starters only).
    func projectedTotal(_ starters: [String]) -> Double {
        starters.filter { $0 != "0" }.reduce(0) { $0 + (projected($1) ?? 0) }
    }

    /// Players on no roster here, who could be picked up: best projected this week first.
    func freeAgents(position: String? = nil, limit: Int = 40) -> [SleeperPlayer] {
        let taken = rostered
        let pos = position?.uppercased()
        let flex: Set<String>? = pos == "FLEX" ? ["RB", "WR", "TE"] : nil
        let pool = players.values.filter { p in
            guard p.active || p.isDefense, p.team != nil, !taken.contains(p.id) else { return false }
            if let flex { return flex.contains(p.position) }
            if let pos, !pos.isEmpty, pos != "ALL" { return p.position == pos }
            // Kickers and defenses have their own filters; among everyone they'd crowd out the skill players.
            return ["QB", "RB", "WR", "TE"].contains(p.position)
        }
        return pool.sorted { a, b in
            let pa = projected(a.id) ?? -1, pb = projected(b.id) ?? -1
            if pa != pb { return pa > pb }
            return (a.searchRank ?? 99999) < (b.searchRank ?? 99999)
        }.prefix(limit).map { $0 }
    }

    /// A slot's name as shown: SUPER_FLEX → SF, WRRB_FLEX → W/R, REC_FLEX → W/T, IDP_FLEX → IDP.
    static func slotName(_ slot: String) -> String {
        switch slot {
        case "SUPER_FLEX": return "SF"
        case "FLEX": return "FLEX"
        case "WRRB_FLEX": return "W/R"
        case "REC_FLEX": return "W/T"
        case "IDP_FLEX": return "IDP"
        default: return slot
        }
    }
}
