import Foundation

// Jira and Bitbucket Cloud, as the Atlassian extension's page shows them: the records it reads from their REST APIs
// (parsed here from JSON), Jira's rich text (Atlassian Document Format) as blocks to draw and back, branch names for
// a ticket, and a pull request's unified diff split into files. Foundation only, so it can serve Windows later.

// MARK: Jira

struct JiraUser: Equatable {
    let accountId: String
    let displayName: String
    let avatarURL: String?

    init(accountId: String, displayName: String, avatarURL: String? = nil) {
        self.accountId = accountId
        self.displayName = displayName
        self.avatarURL = avatarURL
    }

    init?(_ j: Any?) {
        guard let j = j as? [String: Any], let id = j["accountId"] as? String else { return nil }
        accountId = id
        displayName = j["displayName"] as? String ?? "Unknown"
        let avatars = j["avatarUrls"] as? [String: Any]
        avatarURL = (avatars?["48x48"] ?? avatars?["32x32"]) as? String
    }
}

struct JiraStatus: Equatable {
    let id: String
    let name: String
    /// Jira's status category: "new" (to do), "indeterminate" (in progress) or "done".
    let category: String

    init(id: String, name: String, category: String) {
        self.id = id
        self.name = name
        self.category = category
    }

    init?(_ j: Any?) {
        guard let j = j as? [String: Any], let id = j["id"] as? String ?? (j["id"] as? NSNumber)?.stringValue else { return nil }
        self.id = id
        name = j["name"] as? String ?? id
        let cat = j["statusCategory"] as? [String: Any]
        category = cat?["key"] as? String ?? j["category"] as? String ?? "indeterminate"
    }

    var isDone: Bool { category == "done" }
}

struct JiraIssue: Equatable {
    let id: String
    let key: String
    var summary: String
    var status: JiraStatus
    let type: String
    let isSubtask: Bool
    var priority: String?
    var assignee: JiraUser?
    let reporter: JiraUser?
    let parentKey: String?
    let parentSummary: String?
    let labels: [String]
    let storyPoints: Double?
    let created: Date?
    let updated: Date?
    /// The description in Atlassian Document Format, as Jira sent it.
    let description: [DocBlock]
    let projectKey: String

    /// Fields the page asks Jira for (story points' field differs per site, so it's added by the caller).
    static let fields = ["summary", "status", "issuetype", "priority", "assignee", "reporter", "parent", "labels", "created", "updated",
                         "description", "project"]

    init?(_ j: Any?, storyPointsField: String? = nil) {
        guard let j = j as? [String: Any], let key = j["key"] as? String else { return nil }
        let f = j["fields"] as? [String: Any] ?? [:]
        id = j["id"] as? String ?? key
        self.key = key
        summary = f["summary"] as? String ?? ""
        status = JiraStatus(f["status"]) ?? JiraStatus(id: "", name: "Unknown", category: "new")
        let t = f["issuetype"] as? [String: Any]
        type = (t?["name"] as? String ?? "Task").trimmingCharacters(in: .whitespaces)
        isSubtask = t?["subtask"] as? Bool ?? false
        priority = (f["priority"] as? [String: Any])?["name"] as? String
        assignee = JiraUser(f["assignee"])
        reporter = JiraUser(f["reporter"])
        let parent = f["parent"] as? [String: Any]
        parentKey = parent?["key"] as? String
        parentSummary = (parent?["fields"] as? [String: Any])?["summary"] as? String
        labels = f["labels"] as? [String] ?? []
        storyPoints = storyPointsField.flatMap { (f[$0] as? NSNumber)?.doubleValue }
        created = JiraDate.parse(f["created"] as? String)
        updated = JiraDate.parse(f["updated"] as? String)
        description = ADF.blocks(f["description"])
        projectKey = (f["project"] as? [String: Any])?["key"] as? String ?? String(key.split(separator: "-").first ?? "")
    }

    init(key: String, summary: String, status: JiraStatus, type: String = "Task", assignee: JiraUser? = nil, priority: String? = "Medium") {
        id = key
        self.key = key
        self.summary = summary
        self.status = status
        self.type = type
        isSubtask = false
        self.priority = priority
        self.assignee = assignee
        reporter = nil
        parentKey = nil
        parentSummary = nil
        labels = []
        storyPoints = nil
        created = nil
        updated = nil
        description = []
        projectKey = String(key.split(separator: "-").first ?? "")
    }
}

struct JiraBoard: Equatable {
    let id: Int
    let name: String
    /// "scrum", "kanban" or "simple" (team-managed).
    let type: String
    let projectKey: String?

    init?(_ j: Any?) {
        guard let j = j as? [String: Any], let id = (j["id"] as? NSNumber)?.intValue else { return nil }
        self.id = id
        name = j["name"] as? String ?? "Board \(id)"
        type = j["type"] as? String ?? "kanban"
        projectKey = (j["location"] as? [String: Any])?["projectKey"] as? String
    }
}

struct JiraColumn: Equatable {
    let name: String
    let statusIds: [String]
}

/// A board's columns, and which field holds story points.
struct JiraBoardConfig: Equatable {
    let columns: [JiraColumn]
    let storyPointsField: String?

    init(columns: [JiraColumn], storyPointsField: String? = nil) {
        self.columns = columns
        self.storyPointsField = storyPointsField
    }

    init?(_ j: Any?) {
        guard let j = j as? [String: Any], let cols = (j["columnConfig"] as? [String: Any])?["columns"] as? [[String: Any]] else { return nil }
        columns = cols.compactMap { c in
            let ids = (c["statuses"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String ?? ($0["id"] as? NSNumber)?.stringValue }
            // Jira lists an unmapped "Backlog" column with no statuses on some boards: nothing can be shown or dropped there.
            return ids.isEmpty ? nil : JiraColumn(name: c["name"] as? String ?? "", statusIds: ids)
        }
        let est = (j["estimation"] as? [String: Any])?["field"] as? [String: Any]
        storyPointsField = est?["fieldId"] as? String
    }

    /// The column an issue in `status` sits in.
    func column(of status: JiraStatus) -> Int? { columns.firstIndex { $0.statusIds.contains(status.id) } }
}

struct JiraTransition: Equatable {
    let id: String
    let name: String
    let to: JiraStatus

    init(id: String, name: String, to: JiraStatus) {
        self.id = id
        self.name = name
        self.to = to
    }

    init?(_ j: Any?) {
        guard let j = j as? [String: Any], let id = j["id"] as? String, let to = JiraStatus(j["to"]) else { return nil }
        self.id = id
        name = j["name"] as? String ?? to.name
        self.to = to
    }

    /// The transition that lands in one of `statusIds`, preferring the first of them.
    static func into(_ statusIds: [String], from list: [JiraTransition]) -> JiraTransition? {
        for s in statusIds { if let t = list.first(where: { $0.to.id == s }) { return t } }
        return nil
    }
}

struct JiraComment: Equatable {
    let id: String
    let author: JiraUser?
    let body: [DocBlock]
    let created: Date?

    init?(_ j: Any?) {
        guard let j = j as? [String: Any], let id = j["id"] as? String else { return nil }
        self.id = id
        author = JiraUser(j["author"])
        body = ADF.blocks(j["body"])
        created = JiraDate.parse(j["created"] as? String)
    }
}

/// An issue type a project offers, for creating one.
struct JiraIssueType: Equatable {
    let id: String
    let name: String
    let isSubtask: Bool

    init?(_ j: Any?) {
        guard let j = j as? [String: Any], let id = j["id"] as? String else { return nil }
        self.id = id
        name = (j["name"] as? String ?? id).trimmingCharacters(in: .whitespaces)
        isSubtask = j["subtask"] as? Bool ?? false
    }
}

/// A branch linked to a ticket: from Jira's development panel (any repository Jira knows), or one in the tab's
/// repository whose name has the ticket's key.
struct JiraBranch: Equatable {
    let name: String
    /// The repository's "workspace/slug" (or name, when Jira gives no address); nil for one only known locally.
    let repository: String?
    let url: String?
    /// In the tab's repository: a local branch, or one on its origin.
    var inRepo: Bool

    /// Jira's /rest/dev-status/latest/issue/detail answer. A repository's address can be by id
    /// ("https://bitbucket.org/{}/{uuid}"): then its name stands for it.
    static func parse(devStatus j: Any?) -> [JiraBranch] {
        let details = (j as? [String: Any])?["detail"] as? [[String: Any]] ?? []
        return details.flatMap { d in
            (d["branches"] as? [[String: Any]] ?? []).compactMap { b -> JiraBranch? in
                guard let name = b["name"] as? String, !name.isEmpty else { return nil }
                let r = b["repository"] as? [String: Any]
                var repo = (r?["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                if let u = r?["url"] as? String, let c = URLComponents(string: u) {
                    let parts = c.path.split(separator: "/").map(String.init)
                    if parts.count >= 2, !(parts[0] + parts[1]).contains("{") { repo = parts[0] + "/" + parts[1] }
                }
                return JiraBranch(name: name, repository: repo, url: b["url"] as? String, inRepo: false)
            }
        }
    }

    /// Whether `repository` (a "workspace/slug", or a bare name) is the repository `full` ("workspace/slug").
    static func same(_ repository: String, _ full: String) -> Bool {
        func norm(_ s: String) -> String { s.lowercased().replacingOccurrences(of: " ", with: "-") }
        let slug = full.split(separator: "/").last.map(String.init) ?? full
        return repository.contains("/") ? norm(repository) == norm(full) : norm(repository) == norm(slug)
    }

    /// Jira's branches plus the repository's own whose names have `key` (`names` as `git branch -a` gives them, remote
    /// ones as origin/…), the repository's first; `repo` is its "workspace/slug". One of Jira's with the name of one
    /// of the repository's is taken to be that one, unless Jira names another repository by its full name.
    static func merged(_ linked: [JiraBranch], key: String, local names: [String], repo: String?) -> [JiraBranch] {
        let mine = Set(names.map { $0.hasPrefix("origin/") ? String($0.dropFirst(7)) : $0 }
            .filter { IssueKeys.all(in: $0).contains { $0.caseInsensitiveCompare(key) == .orderedSame } })
        func elsewhere(_ b: JiraBranch) -> Bool {
            guard let r = b.repository, let repo else { return false }
            return r.contains("/") && !same(r, repo)
        }
        func here(_ b: JiraBranch) -> Bool { b.inRepo || (b.repository.map { r in repo.map { same(r, $0) } ?? false } ?? false) }
        var out: [JiraBranch] = []
        for var b in linked {
            b.inRepo = mine.contains(b.name) && !elsewhere(b)
            if out.contains(where: { $0.name == b.name && ($0.inRepo && b.inRepo || $0.repository == b.repository) }) { continue }
            out.append(b)
        }
        for n in mine.sorted() where !out.contains(where: { $0.name == n && $0.inRepo }) {
            out.append(JiraBranch(name: n, repository: repo, url: nil, inRepo: true))
        }
        return out.enumerated().sorted { a, b in
            here(a.element) != here(b.element) ? here(a.element) : a.offset < b.offset
        }.map(\.element)
    }
}

enum JiraDate {
    /// Jira's "2026-11-12T17:14:03.123-0800".
    static func parse(_ s: String?) -> Date? {
        guard let s else { return nil }
        for f in formatters { if let d = f.date(from: s) { return d } }
        return nil
    }

    private static let formatters: [DateFormatter] = ["yyyy-MM-dd'T'HH:mm:ss.SSSZ", "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX",
                                                       "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX", "yyyy-MM-dd'T'HH:mm:ssXXXXX", "yyyy-MM-dd"].map {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = $0
        return f
    }
}

// MARK: Rich text

/// A block of Jira's rich text, as the page draws it.
struct DocBlock: Equatable {
    enum Kind: Equatable {
        case paragraph
        case heading(Int)
        /// A list item, `depth` deep (0 at the top); `number` for an ordered list's.
        case item(depth: Int, number: Int?)
        case code
        case quote
        case rule
        /// A picture or file Jira keeps (shown as its name).
        case media
    }

    let kind: Kind
    let text: String
}

/// Atlassian Document Format: Jira Cloud's rich text, a tree of JSON nodes.
enum ADF {
    /// The blocks of a document (nil or plain text are taken as they come).
    static func blocks(_ doc: Any?) -> [DocBlock] {
        if let s = doc as? String { return s.isEmpty ? [] : s.components(separatedBy: "\n\n").map { DocBlock(kind: .paragraph, text: $0) } }
        guard let doc = doc as? [String: Any] else { return [] }
        var out: [DocBlock] = []
        for node in doc["content"] as? [[String: Any]] ?? [] { block(node, depth: 0, into: &out) }
        return out
    }

    private static func block(_ n: [String: Any], depth: Int, into out: inout [DocBlock]) {
        let kids = n["content"] as? [[String: Any]] ?? []
        switch n["type"] as? String ?? "" {
        case "paragraph":
            let t = inline(kids)
            if !t.isEmpty { out.append(DocBlock(kind: .paragraph, text: t)) }
        case "heading":
            out.append(DocBlock(kind: .heading((n["attrs"] as? [String: Any])?["level"] as? Int ?? 2), text: inline(kids)))
        case "bulletList", "orderedList":
            let ordered = n["type"] as? String == "orderedList"
            var number = ((n["attrs"] as? [String: Any])?["order"] as? Int) ?? 1
            for item in kids {
                // An item's first paragraph is its text; anything after it (a nested list) follows, one deeper.
                let parts = item["content"] as? [[String: Any]] ?? []
                var first = true
                for p in parts {
                    if first, p["type"] as? String == "paragraph" {
                        out.append(DocBlock(kind: .item(depth: depth, number: ordered ? number : nil), text: inline(p["content"] as? [[String: Any]] ?? [])))
                        first = false
                    } else {
                        block(p, depth: depth + 1, into: &out)
                    }
                }
                if first { out.append(DocBlock(kind: .item(depth: depth, number: ordered ? number : nil), text: "")) }
                number += 1
            }
        case "codeBlock":
            out.append(DocBlock(kind: .code, text: kids.compactMap { $0["text"] as? String }.joined()))
        case "blockquote", "panel":
            var inner: [DocBlock] = []
            for k in kids { block(k, depth: depth, into: &inner) }
            for b in inner { out.append(DocBlock(kind: .quote, text: b.text)) }
        case "rule":
            out.append(DocBlock(kind: .rule, text: ""))
        case "mediaSingle", "mediaGroup", "media":
            let names = media(n)
            out.append(DocBlock(kind: .media, text: names.isEmpty ? "Attachment" : names.joined(separator: ", ")))
        case "table":
            // Row by row, cells joined with " | ".
            for row in kids {
                let cells = (row["content"] as? [[String: Any]] ?? []).map { cell -> String in
                    var inner: [DocBlock] = []
                    for k in cell["content"] as? [[String: Any]] ?? [] { block(k, depth: 0, into: &inner) }
                    return inner.map(\.text).joined(separator: " ")
                }
                out.append(DocBlock(kind: .paragraph, text: cells.joined(separator: "  |  ")))
            }
        default:
            let t = inline(kids)
            if !t.isEmpty { out.append(DocBlock(kind: .paragraph, text: t)) }
        }
    }

    private static func media(_ n: [String: Any]) -> [String] {
        var names: [String] = []
        if n["type"] as? String == "media", let a = n["attrs"] as? [String: Any] { names.append(a["alt"] as? String ?? a["fileName"] as? String ?? "Attachment") }
        for k in n["content"] as? [[String: Any]] ?? [] { names += media(k) }
        return names
    }

    /// The text of inline nodes: mentions as @name, emoji as themselves, links' text (or the address), line breaks kept.
    static func inline(_ nodes: [[String: Any]]) -> String {
        var s = ""
        for n in nodes {
            let a = n["attrs"] as? [String: Any]
            switch n["type"] as? String ?? "" {
            case "text": s += n["text"] as? String ?? ""
            case "hardBreak": s += "\n"
            case "mention": s += (a?["text"] as? String).map { $0.hasPrefix("@") ? $0 : "@" + $0 } ?? "@someone"
            case "emoji": s += a?["text"] as? String ?? a?["shortName"] as? String ?? ""
            case "inlineCard", "blockCard": s += a?["url"] as? String ?? ""
            case "status": s += "[" + (a?["text"] as? String ?? "") + "]"
            case "date": s += (a?["timestamp"] as? String).flatMap(Double.init).map { ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: $0 / 1000)).prefix(10).description } ?? ""
            default: s += inline(n["content"] as? [[String: Any]] ?? [])
            }
        }
        return s
    }

    /// A document from text typed on the page: blank lines between paragraphs, "- " or "* " bullets, "1. " numbers,
    /// ``` fences around code.
    static func document(_ text: String) -> [String: Any] {
        var content: [[String: Any]] = []
        var para: [String] = []
        var bullets: [String] = [], numbers: [String] = []
        var code: [String]?
        func textNodes(_ lines: [String]) -> [[String: Any]] {
            var nodes: [[String: Any]] = []
            for (i, l) in lines.enumerated() {
                if i > 0 { nodes.append(["type": "hardBreak"]) }
                if !l.isEmpty { nodes.append(["type": "text", "text": l]) }
            }
            return nodes
        }
        func flush() {
            if !para.isEmpty { content.append(["type": "paragraph", "content": textNodes(para)]); para = [] }
            for (list, type) in [(bullets, "bulletList"), (numbers, "orderedList")] where !list.isEmpty {
                content.append(["type": type, "content": list.map { ["type": "listItem", "content": [["type": "paragraph", "content": textNodes([$0])]]] }])
            }
            bullets = []
            numbers = []
        }
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if let c = code {
                if raw.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    content.append(["type": "codeBlock", "content": c.isEmpty ? [] : [["type": "text", "text": c.joined(separator: "\n")]]])
                    code = nil
                } else { code = c + [raw] }
                continue
            }
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") { flush(); code = []; continue }
            if t.isEmpty { flush(); continue }
            if t.hasPrefix("- ") || t.hasPrefix("* ") {
                if !para.isEmpty || !numbers.isEmpty { flush() }
                bullets.append(String(t.dropFirst(2)))
                continue
            }
            if let dot = t.firstIndex(of: "."), t[..<dot].allSatisfy(\.isNumber), !t[..<dot].isEmpty, t[t.index(after: dot)...].hasPrefix(" ") {
                if !para.isEmpty || !bullets.isEmpty { flush() }
                numbers.append(String(t[t.index(dot, offsetBy: 2)...]))
                continue
            }
            if !bullets.isEmpty || !numbers.isEmpty { flush() }
            para.append(raw)
        }
        if let c = code { content.append(["type": "codeBlock", "content": c.isEmpty ? [] : [["type": "text", "text": c.joined(separator: "\n")]]]) }
        flush()
        return ["type": "doc", "version": 1, "content": content]
    }

    /// Blocks back to the text a person would type for them (for editing a description).
    static func plainText(_ blocks: [DocBlock]) -> String {
        var lines: [String] = []
        var prev: DocBlock.Kind?
        for b in blocks {
            // Items of one list go line by line; anything else (another list included) after a blank line.
            func list(_ k: DocBlock.Kind?) -> Bool? { if case .item(_, let n)? = k { return n != nil } else { return nil } }
            if !lines.isEmpty, list(b.kind) == nil || list(b.kind) != list(prev) { lines.append("") }
            switch b.kind {
            case .paragraph, .media: lines.append(b.text)
            case .heading: lines.append(b.text)
            case .item(let depth, let n): lines.append(String(repeating: "  ", count: depth) + (n.map { "\($0). " } ?? "- ") + b.text)
            case .code: lines.append("```\n" + b.text + "\n```")
            case .quote: lines.append(b.text)
            case .rule: lines.append("---")
            }
            prev = b.kind
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: Keys and branches

enum IssueKeys {
    /// The first issue key in `s` ("ABC-569-add-login" → "ABC-569"), upper case.
    static func first(in s: String) -> String? { all(in: s).first }

    static func all(in s: String) -> [String] {
        let chars = Array(s.uppercased())
        var out: [String] = []
        var i = 0
        while i < chars.count {
            // A key starts a word: a letter not after another letter or digit.
            guard chars[i].isASCII, chars[i].isLetter, i == 0 || !(chars[i - 1].isASCII && (chars[i - 1].isLetter || chars[i - 1].isNumber)) else { i += 1; continue }
            var j = i
            while j < chars.count, chars[j].isASCII, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" { j += 1 }
            guard j < chars.count, chars[j] == "-", j > i else { i = j + 1; continue }
            var k = j + 1
            while k < chars.count, chars[k].isASCII, chars[k].isNumber { k += 1 }
            let after = k < chars.count ? chars[k] : " "
            if k > j + 1, !(after.isASCII && after.isLetter) {
                let key = String(chars[i..<k])
                if !out.contains(key) { out.append(key) }
            }
            i = max(k, i + 1)
        }
        return out
    }
}

enum BranchNames {
    /// A branch for an issue, in the form this team uses ("ABC-569-add-login-page"): the key, then the summary in
    /// lower case with anything not a letter or digit as one hyphen, cut at a word to keep it short. `prefix`
    /// ("feature", "bugfix") goes first with a slash when given.
    static func forIssue(key: String, summary: String, prefix: String? = nil, maxLength: Int = 60) -> String {
        var words: [String] = []
        var cur = ""
        for ch in summary.lowercased().folding(options: .diacriticInsensitive, locale: .current) {
            if ch.isASCII && (ch.isLetter || ch.isNumber) { cur.append(ch) } else if !cur.isEmpty { words.append(cur); cur = "" }
        }
        if !cur.isEmpty { words.append(cur) }
        var name = key
        for w in words {
            if name.count + 1 + w.count > maxLength { break }
            name += "-" + w
        }
        if let p = prefix?.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")), !p.isEmpty { name = p + "/" + name }
        return name
    }

    /// Whether git takes `name` as a branch name (the rules of `git check-ref-format --branch`, roughly).
    static func isValid(_ name: String) -> Bool {
        guard !name.isEmpty, !name.hasPrefix("-"), !name.hasPrefix("/"), !name.hasSuffix("/"), !name.hasSuffix("."), !name.hasSuffix(".lock"),
              !name.contains(".."), !name.contains("//"), !name.contains("@{"), name != "@" else { return false }
        let bad = CharacterSet(charactersIn: " ~^:?*[\\").union(.controlCharacters)
        return name.unicodeScalars.allSatisfy { !bad.contains($0) } && !name.split(separator: "/").contains { $0.hasPrefix(".") }
    }

    /// A team's branch style, guessed from its branches: a prefix most of them share before a key ("feature/"), or none.
    static func prefix(usedIn branches: [String]) -> String? {
        var counts: [String: Int] = [:]
        var keyed = 0
        for b in branches {
            let name = b.hasPrefix("remotes/") ? String(b.split(separator: "/", maxSplits: 2).dropFirst(2).first ?? "") : b
            guard let key = IssueKeys.first(in: name), let r = name.uppercased().range(of: key) else { continue }
            keyed += 1
            let before = String(name[name.startIndex..<r.lowerBound])
            if !before.isEmpty { counts[before.trimmingCharacters(in: CharacterSet(charactersIn: "/")), default: 0] += 1 }
        }
        guard let top = counts.max(by: { $0.value < $1.value }), keyed > 0, Double(top.value) / Double(keyed) > 0.5 else { return nil }
        return top.key
    }
}

// MARK: Bitbucket

/// A Bitbucket Cloud repository, from a git remote's URL.
/// A kind of branch a Bitbucket repository's branching model names, with its prefix ("bugfix" → "bugfix/").
struct BranchType: Equatable {
    let kind: String
    let prefix: String

    /// Bitbucket's /effective-branching-model answer: its enabled branch types.
    static func parse(model j: Any?) -> [BranchType] {
        ((j as? [String: Any])?["branch_types"] as? [[String: Any]] ?? []).compactMap { t in
            guard t["enabled"] as? Bool ?? true, let kind = t["kind"] as? String, let prefix = t["prefix"] as? String, !prefix.isEmpty else { return nil }
            return BranchType(kind: kind, prefix: prefix)
        }
    }

    /// The kind a ticket of `issueType` gets by default: a bug's is bugfix (or hotfix), anything else's feature.
    static func suggested(for issueType: String, from types: [BranchType]) -> BranchType? {
        let bug = issueType.lowercased().contains("bug")
        let order = bug ? ["bugfix", "hotfix", "feature"] : ["feature"]
        return order.lazy.compactMap { k in types.first { $0.kind == k } }.first
    }
}

struct BitbucketRepo: Equatable {
    let workspace: String
    let slug: String
    var fullName: String { workspace + "/" + slug }

    /// "git@bitbucket.org:ws/repo.git", "https://user@bitbucket.org/ws/repo.git", "ssh://git@bitbucket.org/ws/repo".
    init?(remote: String) {
        let s = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let r = s.range(of: "bitbucket.org") else { return nil }
        var rest = String(s[r.upperBound...])
        if rest.hasPrefix(":") || rest.hasPrefix("/") { rest.removeFirst() } else { return nil }
        if rest.hasSuffix("/") { rest.removeLast() }
        if rest.hasSuffix(".git") { rest.removeLast(4) }
        let parts = rest.split(separator: "/")
        guard parts.count == 2 else { return nil }
        workspace = String(parts[0])
        slug = String(parts[1])
    }

    init(workspace: String, slug: String) {
        self.workspace = workspace
        self.slug = slug
    }

    var path: String { "\(workspace)/\(slug)" }
}

struct BitbucketUser: Equatable {
    let uuid: String
    let displayName: String
    let avatarURL: String?
    let accountId: String?

    init?(_ j: Any?) {
        guard let j = j as? [String: Any], let uuid = j["uuid"] as? String else { return nil }
        self.uuid = uuid
        displayName = j["display_name"] as? String ?? j["nickname"] as? String ?? "Unknown"
        avatarURL = ((j["links"] as? [String: Any])?["avatar"] as? [String: Any])?["href"] as? String
        accountId = j["account_id"] as? String
    }
}

struct BitbucketParticipant: Equatable {
    let user: BitbucketUser
    let isReviewer: Bool
    let approved: Bool
    /// "approved", "changes_requested", or nil.
    let state: String?

    init?(_ j: Any?) {
        guard let j = j as? [String: Any], let user = BitbucketUser(j["user"]) else { return nil }
        self.user = user
        isReviewer = j["role"] as? String == "REVIEWER"
        approved = j["approved"] as? Bool ?? false
        state = j["state"] as? String
    }
}

struct BitbucketPullRequest: Equatable {
    let id: Int
    let title: String
    let description: String
    /// OPEN, MERGED, DECLINED, SUPERSEDED.
    let state: String
    let author: BitbucketUser?
    let source: String
    let destination: String
    let sourceCommit: String?
    let created: Date?
    let updated: Date?
    let comments: Int
    let tasks: Int
    let participants: [BitbucketParticipant]
    let reviewers: [BitbucketUser]
    let url: String?
    let closeSourceBranch: Bool
    let repo: BitbucketRepo?

    init?(_ j: Any?) {
        guard let j = j as? [String: Any], let id = (j["id"] as? NSNumber)?.intValue else { return nil }
        self.id = id
        title = j["title"] as? String ?? "#\(id)"
        description = j["description"] as? String ?? (j["summary"] as? [String: Any])?["raw"] as? String ?? ""
        state = j["state"] as? String ?? "OPEN"
        author = BitbucketUser(j["author"])
        let src = j["source"] as? [String: Any], dst = j["destination"] as? [String: Any]
        source = (src?["branch"] as? [String: Any])?["name"] as? String ?? ""
        destination = (dst?["branch"] as? [String: Any])?["name"] as? String ?? ""
        sourceCommit = (src?["commit"] as? [String: Any])?["hash"] as? String
        created = JiraDate.parse(j["created_on"] as? String)
        updated = JiraDate.parse(j["updated_on"] as? String)
        comments = (j["comment_count"] as? NSNumber)?.intValue ?? 0
        tasks = (j["task_count"] as? NSNumber)?.intValue ?? 0
        participants = (j["participants"] as? [Any] ?? []).compactMap(BitbucketParticipant.init)
        reviewers = (j["reviewers"] as? [Any] ?? []).compactMap(BitbucketUser.init)
        url = ((j["links"] as? [String: Any])?["html"] as? [String: Any])?["href"] as? String
        closeSourceBranch = j["close_source_branch"] as? Bool ?? false
        let full = ((dst?["repository"] as? [String: Any])?["full_name"] as? String)?.split(separator: "/")
        repo = full.flatMap { $0.count == 2 ? BitbucketRepo(workspace: String($0[0]), slug: String($0[1])) : nil }
    }

    var approvals: Int { participants.filter(\.approved).count }
    var changesRequested: Bool { participants.contains { $0.state == "changes_requested" } }
    var issueKey: String? { IssueKeys.first(in: source) ?? IssueKeys.first(in: title) }

    /// Whether `uuid` has approved it.
    func approved(by uuid: String?) -> Bool { participants.contains { $0.user.uuid == uuid && $0.approved } }
}

struct BitbucketComment: Equatable {
    let id: Int
    let user: BitbucketUser?
    let text: String
    let created: Date?
    let path: String?
    let line: Int?
    let parent: Int?
    let deleted: Bool

    init?(_ j: Any?) {
        guard let j = j as? [String: Any], let id = (j["id"] as? NSNumber)?.intValue else { return nil }
        self.id = id
        user = BitbucketUser(j["user"])
        text = (j["content"] as? [String: Any])?["raw"] as? String ?? ""
        created = JiraDate.parse(j["created_on"] as? String)
        let inline = j["inline"] as? [String: Any]
        path = inline?["path"] as? String
        line = ((inline?["to"] ?? inline?["from"]) as? NSNumber)?.intValue
        parent = ((j["parent"] as? [String: Any])?["id"] as? NSNumber)?.intValue
        deleted = j["deleted"] as? Bool ?? false
    }
}

/// A build's result on a commit (Pipelines, or another CI reporting to Bitbucket).
struct BitbucketBuild: Equatable {
    let name: String
    /// SUCCESSFUL, FAILED, INPROGRESS, STOPPED.
    let state: String
    let url: String?

    init?(_ j: Any?) {
        guard let j = j as? [String: Any], let state = j["state"] as? String else { return nil }
        name = j["name"] as? String ?? j["key"] as? String ?? "Build"
        self.state = state
        url = j["url"] as? String
    }
}

// MARK: Diffs

/// One file's part of a unified diff.
struct DiffFile: Equatable {
    enum LineKind: Equatable { case context, added, removed, hunk, note }

    struct Line: Equatable {
        let kind: LineKind
        let text: String
        let old: Int?
        let new: Int?
    }

    let oldPath: String?
    let newPath: String?
    var lines: [Line]
    var added: Int { lines.filter { $0.kind == .added }.count }
    var removed: Int { lines.filter { $0.kind == .removed }.count }
    var path: String { newPath ?? oldPath ?? "?" }
    var isBinary: Bool { lines.contains { $0.kind == .note && $0.text.hasPrefix("Binary") } }

    /// `git diff` output, file by file.
    static func parse(_ text: String) -> [DiffFile] {
        var files: [DiffFile] = []
        var cur: DiffFile?
        var old = 0, new = 0
        func path(_ s: Substring) -> String? {
            let p = s.trimmingCharacters(in: .whitespaces)
            if p == "/dev/null" { return nil }
            return p.hasPrefix("a/") || p.hasPrefix("b/") ? String(p.dropFirst(2)) : p
        }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let l = raw.hasSuffix("\r") ? raw.dropLast() : raw
            if l.hasPrefix("diff --git ") {
                if let c = cur { files.append(c) }
                // "diff --git a/x b/x": the names, until ---/+++ say better (a rename or a new file).
                let names = l.dropFirst(11).components(separatedBy: " b/")
                let a = names.first.map { $0.hasPrefix("a/") ? String($0.dropFirst(2)) : $0 }
                cur = DiffFile(oldPath: a, newPath: names.count > 1 ? names.dropFirst().joined(separator: " b/") : a, lines: [])
                continue
            }
            guard var c = cur else { continue }
            if l.hasPrefix("--- ") && c.lines.isEmpty {
                c = DiffFile(oldPath: path(l.dropFirst(4)), newPath: c.newPath, lines: c.lines)
            } else if l.hasPrefix("+++ ") && c.lines.isEmpty {
                c = DiffFile(oldPath: c.oldPath, newPath: path(l.dropFirst(4)), lines: c.lines)
            } else if l.hasPrefix("@@") {
                // "@@ -12,7 +12,9 @@ func name()".
                let nums = l.split(separator: " ")
                if nums.count > 2 {
                    old = Int(nums[1].dropFirst().split(separator: ",").first ?? "") ?? 0
                    new = Int(nums[2].dropFirst().split(separator: ",").first ?? "") ?? 0
                }
                c.lines.append(Line(kind: .hunk, text: String(l), old: nil, new: nil))
            } else if l.hasPrefix("Binary files") {
                c.lines.append(Line(kind: .note, text: "Binary file", old: nil, new: nil))
            } else if c.lines.contains(where: { $0.kind == .hunk }) {
                if l.hasPrefix("+") { c.lines.append(Line(kind: .added, text: String(l.dropFirst()), old: nil, new: new)); new += 1 }
                else if l.hasPrefix("-") { c.lines.append(Line(kind: .removed, text: String(l.dropFirst()), old: old, new: nil)); old += 1 }
                else if l.hasPrefix("\\") { c.lines.append(Line(kind: .note, text: String(l.dropFirst(2)), old: nil, new: nil)) }
                else if l.hasPrefix(" ") || l.isEmpty { c.lines.append(Line(kind: .context, text: String(l.dropFirst()), old: old, new: new)); old += 1; new += 1 }
            }
            cur = c
        }
        if let c = cur { files.append(c) }
        return files
    }
}
