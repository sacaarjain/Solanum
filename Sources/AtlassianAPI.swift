import AppKit
import Security

// The Atlassian extension's connection to Jira Cloud and Bitbucket Cloud: the account (site and email, in
// ~/.config/solanum/extensions/atlassian/settings.json), its API tokens (in the Keychain), the REST calls the page
// makes, and git run in the tab's repository for "Start work" and checking out a pull request.
//
// Atlassian's own VS Code extension signs in with OAuth through an app Atlassian registered for it; Solanum has none,
// so it uses API tokens: Jira takes an account's classic token, Bitbucket a token made with Bitbucket scopes (app
// passwords are gone). Both go as Basic auth with the account's email.
//
// Tests point it at a local stand-in: SOLANUM_ATLASSIAN_MOCK=http://127.0.0.1:<port> serves Jira under /jira and
// Bitbucket under /bitbucket, with made-up credentials and no Keychain.

enum AtlassianError: Error {
    case notConnected
    case http(Int, String)
    case network(String)
    case invalid(String)

    var message: String {
        switch self {
        case .notConnected: return "Not connected. Add your Atlassian email and API tokens."
        case .http(let code, let m): return m.isEmpty ? "The server answered \(code)." : m
        case .network(let m): return m
        case .invalid(let m): return m
        }
    }
}

enum AtlassianService { case jira, bitbucket }

/// Where you are and who you are: kept as JSON, apart from the tokens.
struct AtlassianSettings: Equatable {
    var site = ""
    var email = ""
    var boardId: Int?
    var onlyMine = false
    var section = "board"
    var branchPrefix: String?
    /// Create issue's "Start work on it" box, as it was last left.
    var startAfterCreate = false

    static var dir: URL { Config.shared.dir.appendingPathComponent("extensions/atlassian", isDirectory: true) }
    private static var file: URL { dir.appendingPathComponent("settings.json") }

    static func load() -> AtlassianSettings {
        var s = AtlassianSettings()
        if AtlassianClient.mock != nil { s.site = "mock.atlassian.net"; s.email = "tester@example.com" }
        guard let data = try? Data(contentsOf: file), let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return s }
        s.site = j["site"] as? String ?? s.site
        s.email = j["email"] as? String ?? s.email
        s.boardId = (j["boardId"] as? NSNumber)?.intValue
        s.onlyMine = j["onlyMine"] as? Bool ?? false
        s.section = j["section"] as? String ?? "board"
        s.branchPrefix = j["branchPrefix"] as? String
        s.startAfterCreate = j["startAfterCreate"] as? Bool ?? false
        return s
    }

    func save() {
        var j: [String: Any] = ["site": site, "email": email, "onlyMine": onlyMine, "section": section, "startAfterCreate": startAfterCreate]
        if let boardId { j["boardId"] = boardId }
        if let branchPrefix { j["branchPrefix"] = branchPrefix }
        try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: j, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: Self.file, options: .atomic)
        }
    }

    /// "acme.atlassian.net" from whatever was typed ("https://acme.atlassian.net/jira/…", "acme").
    static func normalizeSite(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for p in ["https://", "http://"] where t.hasPrefix(p) { t.removeFirst(p.count) }
        if let slash = t.firstIndex(of: "/") { t = String(t[..<slash]) }
        if !t.isEmpty, !t.contains(".") { t += ".atlassian.net" }
        return t
    }
}

/// The API tokens, in tokens.json beside the settings, readable only by you (0600, in a 0700 folder), as git's
/// credential store and the gh CLI keep theirs. Not the Keychain: Solanum builds aren't signed with a lasting identity,
/// so macOS took each rebuild for another app and asked for the login password again before handing them over.
enum AtlassianTokens {
    private static var file: URL { AtlassianSettings.dir.appendingPathComponent("tokens.json") }
    /// Read once per launch.
    private static var cache: [String: String]?

    private static func name(_ s: AtlassianService) -> String { s == .jira ? "jira" : "bitbucket" }

    static func get(_ s: AtlassianService) -> String? {
        if AtlassianClient.mock != nil { return "test-token" }
        let t = all()[name(s)]
        return t?.isEmpty == false ? t : nil
    }

    static func set(_ s: AtlassianService, _ token: String?) {
        var d = all()
        d[name(s)] = token?.isEmpty == false ? token : nil
        cache = d
        // Headless runs keep tokens in memory only.
        if Headless.active || AtlassianClient.mock != nil { return }
        write(d, to: file)
    }

    private static func all() -> [String: String] {
        if let cache { return cache }
        var d: [String: String] = [:]
        if !Headless.active {
            if let j = read(file) {
                d = j
            } else {
                d = KeychainLeftovers.take()
                if !d.isEmpty { write(d, to: file) }
            }
        }
        cache = d
        return d
    }

    static func read(_ file: URL) -> [String: String]? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: String]
    }

    static func write(_ d: [String: String], to file: URL) {
        let fm = FileManager.default
        let dir = file.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        guard !d.isEmpty else { try? fm.removeItem(at: file); return }
        guard let data = try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys]) else { return }
        // Made private before the tokens go in, then moved over the old file in one step.
        let tmp = dir.appendingPathComponent(".tokens.\(ProcessInfo.processInfo.processIdentifier).tmp")
        guard fm.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return }
        if rename(tmp.path, file.path) != 0 { try? fm.removeItem(at: tmp) }
    }
}

/// Tokens earlier builds kept in the Keychain (one item for both, or before that one per service): read once to move
/// them to the file (macOS may ask this one last time), then deleted.
private enum KeychainLeftovers {
    private static let service = "Solanum Atlassian"

    static func take() -> [String: String] {
        var d: [String: String] = [:]
        if let data = read("tokens"), let j = try? JSONSerialization.jsonObject(with: data) as? [String: String] { d = j }
        for a in ["jira", "bitbucket"] where d[a] == nil {
            if let data = read(a), !data.isEmpty { d[a] = String(decoding: data, as: UTF8.self) }
        }
        for a in ["tokens", "jira", "bitbucket"] {
            SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: a] as CFDictionary)
        }
        return d
    }

    private static func read(_ account: String) -> Data? {
        // Only looked for when there's one: asking for an item that isn't there costs nothing, but its data brings
        // up macOS's dialog.
        let exists: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                     kSecAttrAccount as String: account, kSecMatchLimit as String: kSecMatchLimitOne]
        guard SecItemCopyMatching(exists as CFDictionary, nil) == errSecSuccess else { return nil }
        var q = exists
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }
}

/// REST calls, answered on the main queue.
final class AtlassianClient {
    static let shared = AtlassianClient()

    /// The test stand-in's address, when one is set.
    static let mock: String? = ProcessInfo.processInfo.environment["SOLANUM_ATLASSIAN_MOCK"]

    var settings = AtlassianSettings.load()

    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        c.httpAdditionalHeaders = ["User-Agent": "Solanum"]
        return URLSession(configuration: c)
    }()

    func base(_ s: AtlassianService) -> String {
        if let m = Self.mock { return m + (s == .jira ? "/jira" : "/bitbucket") }
        return s == .jira ? "https://\(settings.site)" : "https://api.bitbucket.org/2.0"
    }

    func hasCredentials(_ s: AtlassianService) -> Bool {
        !settings.email.isEmpty && (s == .bitbucket || !settings.site.isEmpty) && token(s) != nil
    }

    /// Bitbucket's token, or Jira's when only that one was given (a token made with both products' scopes).
    private func token(_ s: AtlassianService) -> String? { AtlassianTokens.get(s) ?? (s == .bitbucket ? AtlassianTokens.get(.jira) : nil) }

    enum Body {
        case none
        case json(Any)
    }

    /// `path` under the service (or a full URL, as Bitbucket's paging gives). `raw`: the answer as text, not JSON.
    func call(_ s: AtlassianService, _ method: String = "GET", _ path: String, query: [String: String] = [:], body: Body = .none, raw: Bool = false,
              done: @escaping (Result<Any, AtlassianError>) -> Void) {
        guard let token = token(s), !settings.email.isEmpty else { return done(.failure(.notConnected)) }
        var comps = URLComponents(string: path.hasPrefix("http") ? path : base(s) + path)
        if !query.isEmpty, var c = comps {
            c.queryItems = (c.queryItems ?? []) + query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            // A literal + would be read as a space.
            let q = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
            c.percentEncodedQuery = q
            comps = c
        }
        guard let url = comps?.url else { return done(.failure(.invalid("Bad address: \(path)"))) }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Basic " + Data("\(settings.email):\(token)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        req.setValue(raw ? "text/plain" : "application/json", forHTTPHeaderField: "Accept")
        if case .json(let j) = body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: j)
        }
        session.dataTask(with: req) { data, response, error in
            let result: Result<Any, AtlassianError>
            if let error {
                result = .failure(.network(error.localizedDescription))
            } else if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                result = .failure(.http(http.statusCode, Self.errorMessage(s, http.statusCode, data)))
            } else if raw {
                result = .success(String(decoding: data ?? Data(), as: UTF8.self))
            } else if let data, !data.isEmpty {
                if let j = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) { result = .success(j) }
                else { result = .failure(.invalid("The answer wasn't JSON.")) }
            } else {
                result = .success([String: Any]())
            }
            DispatchQueue.main.async { done(result) }
        }.resume()
    }

    /// A GET.
    func call(_ s: AtlassianService, _ path: String, query: [String: String] = [:], raw: Bool = false,
              done: @escaping (Result<Any, AtlassianError>) -> Void) {
        call(s, "GET", path, query: query, body: .none, raw: raw, done: done)
    }

    /// What went wrong, in the server's words when it gave some.
    static func errorMessage(_ s: AtlassianService, _ code: Int, _ data: Data?) -> String {
        let name = s == .jira ? "Jira" : "Bitbucket"
        if code == 401 { return "\(name) didn't accept the email and API token (401). Check them in the extension's settings." }
        var parts: [String] = []
        if let data, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            parts += j["errorMessages"] as? [String] ?? []
            for (k, v) in j["errors"] as? [String: Any] ?? [:] { parts.append("\(k): \(v)") }
            if let e = j["error"] as? [String: Any], let m = e["message"] as? String { parts.append(m + ((e["detail"] as? String).map { " " + $0 } ?? "")) }
            if let m = j["message"] as? String { parts.append(m) }
        }
        if code == 403 && parts.isEmpty { return "\(name) says you don't have permission for that (403)." }
        if code == 404 && parts.isEmpty { return "\(name) couldn't find that (404)." }
        return parts.isEmpty ? "\(name) answered \(code)." : parts.joined(separator: " ")
    }

    // MARK: Jira

    func myself(done: @escaping (Result<JiraUser, AtlassianError>) -> Void) {
        call(.jira, "/rest/api/3/myself") { r in done(r.flatMap { JiraUser($0).map(Result.success) ?? .failure(.invalid("No user in the answer.")) }) }
    }

    func boards(done: @escaping (Result<[JiraBoard], AtlassianError>) -> Void) {
        call(.jira, "/rest/agile/1.0/board", query: ["maxResults": "100"]) { r in
            done(r.map { (($0 as? [String: Any])?["values"] as? [Any] ?? []).compactMap(JiraBoard.init) })
        }
    }

    func boardConfig(_ id: Int, done: @escaping (Result<JiraBoardConfig, AtlassianError>) -> Void) {
        call(.jira, "/rest/agile/1.0/board/\(id)/configuration") { r in
            done(r.flatMap { JiraBoardConfig($0).map(Result.success) ?? .failure(.invalid("The board has no columns.")) })
        }
    }

    /// Whether the board runs sprints and has one going (then the board shows that sprint, as Jira's does).
    func activeSprint(_ board: Int, done: @escaping (Int?, String?) -> Void) {
        call(.jira, "/rest/agile/1.0/board/\(board)/sprint", query: ["state": "active"]) { r in
            guard case .success(let j) = r, let first = ((j as? [String: Any])?["values"] as? [[String: Any]])?.first,
                  let id = (first["id"] as? NSNumber)?.intValue else { return done(nil, nil) }
            done(id, first["name"] as? String)
        }
    }

    /// A board's issues in its own order (rank), done ones only from the last two weeks as Jira's board shows them.
    func boardIssues(_ board: Int, config: JiraBoardConfig, sprint: Int?, done: @escaping (Result<[JiraIssue], AtlassianError>) -> Void) {
        var jql = "(statusCategory != Done OR updated >= -14d)"
        if let sprint { jql += " AND sprint = \(sprint)" }
        var fields = JiraIssue.fields
        if let sp = config.storyPointsField { fields.append(sp) }
        var all: [JiraIssue] = []
        func page(_ start: Int) {
            call(.jira, "/rest/agile/1.0/board/\(board)/issue",
                 query: ["jql": jql, "fields": fields.joined(separator: ","), "maxResults": "100", "startAt": "\(start)"]) { r in
                switch r {
                case .failure(let e): done(.failure(e))
                case .success(let j):
                    let d = j as? [String: Any] ?? [:]
                    let list = (d["issues"] as? [Any] ?? []).compactMap { JiraIssue($0, storyPointsField: config.storyPointsField) }
                    all += list
                    let total = (d["total"] as? NSNumber)?.intValue ?? 0
                    if !list.isEmpty, all.count < total, all.count < 600 { page(start + list.count) } else { done(.success(all)) }
                }
            }
        }
        page(0)
    }

    func search(_ jql: String, max: Int = 50, storyPointsField: String? = nil, done: @escaping (Result<[JiraIssue], AtlassianError>) -> Void) {
        var fields = JiraIssue.fields
        if let sp = storyPointsField { fields.append(sp) }
        call(.jira, "POST", "/rest/api/3/search/jql", body: .json(["jql": jql, "fields": fields, "maxResults": max])) { r in
            done(r.map { (($0 as? [String: Any])?["issues"] as? [Any] ?? []).compactMap { JiraIssue($0, storyPointsField: storyPointsField) } })
        }
    }

    func issue(_ key: String, storyPointsField: String? = nil, done: @escaping (Result<JiraIssue, AtlassianError>) -> Void) {
        var fields = JiraIssue.fields
        if let sp = storyPointsField { fields.append(sp) }
        call(.jira, "/rest/api/3/issue/\(key)", query: ["fields": fields.joined(separator: ",")]) { r in
            done(r.flatMap { JiraIssue($0, storyPointsField: storyPointsField).map(Result.success) ?? .failure(.invalid("No issue in the answer.")) })
        }
    }

    func comments(_ key: String, done: @escaping (Result<[JiraComment], AtlassianError>) -> Void) {
        call(.jira, "/rest/api/3/issue/\(key)/comment", query: ["maxResults": "100"]) { r in
            done(r.map { (($0 as? [String: Any])?["comments"] as? [Any] ?? []).compactMap(JiraComment.init) })
        }
    }

    func addComment(_ key: String, _ text: String, done: @escaping (Result<JiraComment, AtlassianError>) -> Void) {
        call(.jira, "POST", "/rest/api/3/issue/\(key)/comment", body: .json(["body": ADF.document(text)])) { r in
            done(r.flatMap { JiraComment($0).map(Result.success) ?? .failure(.invalid("No comment in the answer.")) })
        }
    }

    func transitions(_ key: String, done: @escaping (Result<[JiraTransition], AtlassianError>) -> Void) {
        call(.jira, "/rest/api/3/issue/\(key)/transitions") { r in
            done(r.map { (($0 as? [String: Any])?["transitions"] as? [Any] ?? []).compactMap(JiraTransition.init) })
        }
    }

    func transition(_ key: String, _ id: String, done: @escaping (AtlassianError?) -> Void) {
        call(.jira, "POST", "/rest/api/3/issue/\(key)/transitions", body: .json(["transition": ["id": id]])) { r in done(r.failureValue) }
    }

    /// Moves `key` into a status of `statusIds` by whichever transition gets there; the status it landed in.
    func move(_ key: String, to statusIds: [String], done: @escaping (Result<JiraStatus, AtlassianError>) -> Void) {
        transitions(key) { [weak self] r in
            switch r {
            case .failure(let e): done(.failure(e))
            case .success(let list):
                guard let t = JiraTransition.into(statusIds, from: list) else {
                    return done(.failure(.invalid("Jira's workflow has no way to move \(key) there from where it is.")))
                }
                self?.transition(key, t.id) { e in done(e.map { .failure($0) } ?? .success(t.to)) }
            }
        }
    }

    /// `accountId` nil unassigns.
    func assign(_ key: String, _ accountId: String?, done: @escaping (AtlassianError?) -> Void) {
        call(.jira, "PUT", "/rest/api/3/issue/\(key)/assignee", body: .json(["accountId": accountId as Any? ?? NSNull()])) { r in done(r.failureValue) }
    }

    func edit(_ key: String, fields: [String: Any], done: @escaping (AtlassianError?) -> Void) {
        call(.jira, "PUT", "/rest/api/3/issue/\(key)", body: .json(["fields": fields])) { r in done(r.failureValue) }
    }

    /// Ranks `key` just before `before` (or just after `after`) on its board.
    func rank(_ key: String, before: String?, after: String?, done: @escaping (AtlassianError?) -> Void) {
        var body: [String: Any] = ["issues": [key]]
        if let before { body["rankBeforeIssue"] = before } else if let after { body["rankAfterIssue"] = after } else { return done(nil) }
        call(.jira, "PUT", "/rest/agile/1.0/issue/rank", body: .json(body)) { r in done(r.failureValue) }
    }

    func assignable(_ key: String, query: String, done: @escaping (Result<[JiraUser], AtlassianError>) -> Void) {
        call(.jira, "/rest/api/3/user/assignable/search", query: ["issueKey": key, "query": query, "maxResults": "30"]) { r in
            done(r.map { ($0 as? [Any] ?? []).compactMap(JiraUser.init) })
        }
    }

    func priorities(done: @escaping (Result<[String], AtlassianError>) -> Void) {
        call(.jira, "/rest/api/3/priority") { r in done(r.map { ($0 as? [[String: Any]] ?? []).compactMap { $0["name"] as? String } }) }
    }

    func issueTypes(_ project: String, done: @escaping (Result<[JiraIssueType], AtlassianError>) -> Void) {
        call(.jira, "/rest/api/3/issue/createmeta/\(project)/issuetypes", query: ["maxResults": "50"]) { r in
            done(r.map { j in
                let d = j as? [String: Any] ?? [:]
                return (d["issueTypes"] as? [Any] ?? d["values"] as? [Any] ?? []).compactMap(JiraIssueType.init)
            })
        }
    }

    /// The new issue's key.
    func create(project: String, type: String, summary: String, description: String, assignee: String?, parent: String?,
                done: @escaping (Result<String, AtlassianError>) -> Void) {
        var fields: [String: Any] = ["project": ["key": project], "issuetype": ["id": type], "summary": summary]
        if !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { fields["description"] = ADF.document(description) }
        if let assignee { fields["assignee"] = ["accountId": assignee] }
        if let parent { fields["parent"] = ["key": parent] }
        call(.jira, "POST", "/rest/api/3/issue", body: .json(["fields": fields])) { r in
            done(r.flatMap { (($0 as? [String: Any])?["key"] as? String).map(Result.success) ?? .failure(.invalid("Jira didn't say the new issue's key.")) })
        }
    }

    /// The branches Jira's development panel links to the issue (`id` is its number, not its key).
    func linkedBranches(_ id: String, done: @escaping (Result<[JiraBranch], AtlassianError>) -> Void) {
        call(.jira, "/rest/dev-status/latest/issue/detail", query: ["issueId": id, "applicationType": "bitbucket", "dataType": "branch"]) { r in
            done(r.map(JiraBranch.parse(devStatus:)))
        }
    }

    func browseURL(_ key: String) -> URL? { URL(string: "https://\(settings.site)/browse/\(key)") }

    // MARK: Bitbucket

    func bitbucketUser(done: @escaping (Result<BitbucketUser, AtlassianError>) -> Void) {
        call(.bitbucket, "/user") { r in done(r.flatMap { BitbucketUser($0).map(Result.success) ?? .failure(.invalid("No user in the answer.")) }) }
    }

    private func repoPath(_ r: BitbucketRepo) -> String { "/repositories/\(r.workspace)/\(r.slug)" }

    func pullRequests(_ repo: BitbucketRepo, state: String = "OPEN", done: @escaping (Result<[BitbucketPullRequest], AtlassianError>) -> Void) {
        call(.bitbucket, repoPath(repo) + "/pullrequests",
             query: ["state": state, "pagelen": "50", "fields": "+values.participants,+values.reviewers,-values.summary,-values.rendered"]) { r in
            done(r.map { (($0 as? [String: Any])?["values"] as? [Any] ?? []).compactMap(BitbucketPullRequest.init) })
        }
    }

    func pullRequest(_ repo: BitbucketRepo, _ id: Int, done: @escaping (Result<BitbucketPullRequest, AtlassianError>) -> Void) {
        call(.bitbucket, repoPath(repo) + "/pullrequests/\(id)") { r in
            done(r.flatMap { BitbucketPullRequest($0).map(Result.success) ?? .failure(.invalid("No pull request in the answer.")) })
        }
    }

    func diff(_ repo: BitbucketRepo, _ id: Int, done: @escaping (Result<[DiffFile], AtlassianError>) -> Void) {
        call(.bitbucket, repoPath(repo) + "/pullrequests/\(id)/diff", raw: true) { r in done(r.map { DiffFile.parse($0 as? String ?? "") }) }
    }

    func prComments(_ repo: BitbucketRepo, _ id: Int, done: @escaping (Result<[BitbucketComment], AtlassianError>) -> Void) {
        call(.bitbucket, repoPath(repo) + "/pullrequests/\(id)/comments", query: ["pagelen": "100"]) { r in
            done(r.map { (($0 as? [String: Any])?["values"] as? [Any] ?? []).compactMap(BitbucketComment.init).filter { !$0.deleted } })
        }
    }

    func addPRComment(_ repo: BitbucketRepo, _ id: Int, _ text: String, done: @escaping (AtlassianError?) -> Void) {
        call(.bitbucket, "POST", repoPath(repo) + "/pullrequests/\(id)/comments", body: .json(["content": ["raw": text]])) { r in done(r.failureValue) }
    }

    func builds(_ repo: BitbucketRepo, _ id: Int, done: @escaping (Result<[BitbucketBuild], AtlassianError>) -> Void) {
        call(.bitbucket, repoPath(repo) + "/pullrequests/\(id)/statuses", query: ["pagelen": "50"]) { r in
            done(r.map { (($0 as? [String: Any])?["values"] as? [Any] ?? []).compactMap(BitbucketBuild.init) })
        }
    }

    /// Approves (or takes the approval back).
    func approve(_ repo: BitbucketRepo, _ id: Int, _ on: Bool, done: @escaping (AtlassianError?) -> Void) {
        call(.bitbucket, on ? "POST" : "DELETE", repoPath(repo) + "/pullrequests/\(id)/approve") { r in done(r.failureValue) }
    }

    func requestChanges(_ repo: BitbucketRepo, _ id: Int, _ on: Bool, done: @escaping (AtlassianError?) -> Void) {
        call(.bitbucket, on ? "POST" : "DELETE", repoPath(repo) + "/pullrequests/\(id)/request-changes") { r in done(r.failureValue) }
    }

    /// `strategy`: merge_commit, squash or fast_forward.
    func merge(_ repo: BitbucketRepo, _ id: Int, strategy: String, closeSource: Bool, done: @escaping (AtlassianError?) -> Void) {
        call(.bitbucket, "POST", repoPath(repo) + "/pullrequests/\(id)/merge",
             body: .json(["merge_strategy": strategy, "close_source_branch": closeSource])) { r in done(r.failureValue) }
    }

    func decline(_ repo: BitbucketRepo, _ id: Int, done: @escaping (AtlassianError?) -> Void) {
        call(.bitbucket, "POST", repoPath(repo) + "/pullrequests/\(id)/decline") { r in done(r.failureValue) }
    }

    func defaultReviewers(_ repo: BitbucketRepo, done: @escaping (Result<[BitbucketUser], AtlassianError>) -> Void) {
        call(.bitbucket, repoPath(repo) + "/effective-default-reviewers", query: ["pagelen": "50"]) { r in
            done(r.map { (($0 as? [String: Any])?["values"] as? [[String: Any]] ?? []).compactMap { BitbucketUser($0["user"]) } })
        }
    }

    /// The repository's branching model's branch types (none when it hasn't one, or Bitbucket can't be asked).
    func branchTypes(_ repo: BitbucketRepo, done: @escaping ([BranchType]) -> Void) {
        call(.bitbucket, repoPath(repo) + "/effective-branching-model") { r in done((try? r.get()).map(BranchType.parse(model:)) ?? []) }
    }

    func mainBranch(_ repo: BitbucketRepo, done: @escaping (String?) -> Void) {
        call(.bitbucket, repoPath(repo)) { r in
            guard case .success(let j) = r else { return done(nil) }
            done(((j as? [String: Any])?["mainbranch"] as? [String: Any])?["name"] as? String)
        }
    }

    /// The new pull request.
    func createPR(_ repo: BitbucketRepo, title: String, description: String, source: String, destination: String, reviewers: [String],
                  closeSource: Bool, done: @escaping (Result<BitbucketPullRequest, AtlassianError>) -> Void) {
        let body: [String: Any] = ["title": title, "description": description, "close_source_branch": closeSource,
                                   "source": ["branch": ["name": source]], "destination": ["branch": ["name": destination]],
                                   "reviewers": reviewers.map { ["uuid": $0] }]
        call(.bitbucket, "POST", repoPath(repo) + "/pullrequests", body: .json(body)) { r in
            done(r.flatMap { BitbucketPullRequest($0).map(Result.success) ?? .failure(.invalid("No pull request in the answer.")) })
        }
    }
}

extension Result {
    var failureValue: Failure? { if case .failure(let e) = self { return e } else { return nil } }
}

// MARK: git in the tab's repository

/// git run in a repository on this Mac, off the main thread; answers on the main queue.
enum LocalGit {
    struct Output {
        let status: Int32
        let out: String
        let err: String
        var ok: Bool { status == 0 }
        /// What to show when it failed: git's last words.
        var message: String {
            let t = (err.isEmpty ? out : err).trimmingCharacters(in: .whitespacesAndNewlines)
            return t.split(separator: "\n").suffix(3).joined(separator: " ")
        }
    }

    static func run(_ dir: String, _ args: [String], done: @escaping (Output) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let o = runNow(dir, args)
            DispatchQueue.main.async { done(o) }
        }
    }

    static func runNow(_ dir: String, _ args: [String]) -> Output {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir] + args
        var env = ProcessInfo.processInfo.environment
        // Never stop to ask for a password or passphrase on a terminal nobody's watching.
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_SSH_COMMAND"] = env["GIT_SSH_COMMAND"] ?? "ssh -o BatchMode=yes"
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return Output(status: -1, out: "", err: error.localizedDescription) }
        let group = DispatchGroup()
        var o = Data(), e = Data()
        group.enter()
        DispatchQueue.global().async { o = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        e = err.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        p.waitUntilExit()
        return Output(status: p.terminationStatus, out: String(decoding: o, as: UTF8.self), err: String(decoding: e, as: UTF8.self))
    }

    /// The repository holding `dir`: its top folder and its Bitbucket repo (from origin).
    static func repository(at dir: String, done: @escaping (String?, BitbucketRepo?, String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let top = runNow(dir, ["rev-parse", "--show-toplevel"])
            guard top.ok else { return DispatchQueue.main.async { done(nil, nil, nil) } }
            let root = top.out.trimmingCharacters(in: .whitespacesAndNewlines)
            // As written in the config (get-url would apply url.*.insteadOf rewrites).
            let remote = runNow(root, ["config", "--get", "remote.origin.url"]).out
            let branch = runNow(root, ["branch", "--show-current"]).out.trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async { done(root, BitbucketRepo(remote: remote), branch.isEmpty ? nil : branch) }
        }
    }

    /// Local and remote branch names, newest first.
    static func branches(_ root: String, done: @escaping ([String]) -> Void) {
        run(root, ["branch", "-a", "--sort=-committerdate", "--format=%(refname:short)"]) { o in
            done(o.out.split(separator: "\n").map(String.init).filter { !$0.hasSuffix("/HEAD") && $0 != "origin" })
        }
    }
}
