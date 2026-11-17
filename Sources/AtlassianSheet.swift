import AppKit

// Forms over the Atlassian page: a card in the middle of a dimmed page (drawn in the page itself, not a window, so it
// themes like the rest and headless runs show it). Start work, Create issue, Create pull request, Merge, comments,
// editing a ticket's summary or description, and the account's tokens.

final class AtlassianSheet: NSView {
    enum Row {
        case field(String, label: String, value: String, placeholder: String, mono: Bool)
        case secret(String, label: String, placeholder: String)
        case area(String, label: String, value: String, placeholder: String, height: CGFloat)
        case choice(String, label: String)
        case check(String, label: String, on: Bool)
        case note(String)
    }

    let title: String
    let subtitle: String?
    private(set) var rows: [Row]
    let primary: String
    let danger: Bool
    weak var page: AtlassianPageView?
    var onSubmit: ((AtlassianSheet, @escaping (String?) -> Void) -> Void)?
    /// Called when a choice changes (to load what depends on it).
    var onChoice: ((AtlassianSheet, String) -> Void)?

    private(set) var fields: [String: NSTextField] = [:]
    private(set) var areas: [String: NSTextView] = [:]
    private var areaScrolls: [String: NSScrollView] = [:]
    private(set) var options: [String: [(id: String, title: String)]] = [:]
    var choices: [String: String] = [:]
    var checks: [String: Bool] = [:]
    var busy = false { didSet { canvas.needsDisplay = true } }
    var error: String? { didSet { needsLayout = true; canvas.needsDisplay = true } }
    private let canvas = SheetCanvas()
    var devCanvas: PageCanvas { canvas }

    init(_ title: String, subtitle: String? = nil, rows: [Row], primary: String, danger: Bool = false, page: AtlassianPageView) {
        self.title = title
        self.subtitle = subtitle
        self.rows = rows
        self.primary = primary
        self.danger = danger
        self.page = page
        super.init(frame: .zero)
        canvas.sheet = self
        addSubview(canvas)
        build()
        // The text boxes take their colors here (the one-line fields do it themselves).
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    private func build() {
        for r in rows {
            switch r {
            case .field(let id, _, let value, let placeholder, let mono):
                let f = ThemedField(value, placeholder: placeholder, mono: mono)
                f.layer?.cornerRadius = PageCanvas.radius
                f.target = self
                f.action = #selector(submitFromField)
                fields[id] = f
                addSubview(f)
            case .secret(let id, _, let placeholder):
                let f = AtlassianSecureField()
                f.placeholderString = placeholder
                f.target = self
                f.action = #selector(submitFromField)
                fields[id] = f
                addSubview(f)
            case .area(let id, _, let value, _, _):
                let s = NSScrollView()
                s.hasVerticalScroller = true
                s.autohidesScrollers = true
                s.drawsBackground = false
                s.borderType = .noBorder
                // Its box is drawn by the form behind it (SheetCanvas): a scroll view's own layer doesn't show a fill.
                s.wantsLayer = true
                s.layer?.cornerRadius = PageCanvas.radius
                let tv = SheetTextView()
                tv.sheet = self
                tv.string = value
                tv.isRichText = false
                tv.allowsUndo = true
                tv.font = .systemFont(ofSize: 13)
                tv.textContainerInset = NSSize(width: 6, height: 7)
                tv.isAutomaticQuoteSubstitutionEnabled = false
                tv.isAutomaticDashSubstitutionEnabled = false
                tv.drawsBackground = false
                tv.isVerticallyResizable = true
                tv.autoresizingMask = [.width]
                tv.textContainer?.widthTracksTextView = true
                s.documentView = tv
                areas[id] = tv
                areaScrolls[id] = s
                addSubview(s)
            case .choice(let id, _):
                options[id] = options[id] ?? []
            case .check(let id, _, let on):
                checks[id] = on
            case .note:
                break
            }
        }
        applyTheme()
    }

    func applyTheme() {
        let th = Config.shared.theme
        for f in fields.values {
            f.textColor = th.foreground
            f.layer?.backgroundColor = th.background.withAlphaComponent(0.6).cgColor
        }
        for id in areaScrolls.keys {
            areas[id]?.textColor = th.foreground
            areas[id]?.insertionPointColor = th.foreground
        }
        canvas.needsDisplay = true
    }

    func text(_ id: String) -> String { fields[id]?.stringValue ?? areas[id]?.string ?? "" }
    func setText(_ id: String, _ s: String) { if let f = fields[id] { f.stringValue = s } else { areas[id]?.string = s } }

    func setOptions(_ id: String, _ list: [(id: String, title: String)], selected: String?) {
        options[id] = list
        if let selected, list.contains(where: { $0.id == selected }) { choices[id] = selected }
        else if choices[id] == nil || !list.contains(where: { $0.id == choices[id] }) { choices[id] = list.first?.id }
        canvas.needsDisplay = true
    }

    func replaceNote(_ index: Int, _ s: String) {
        guard index < rows.count, case .note = rows[index] else { return }
        rows[index] = .note(s)
        needsLayout = true
        canvas.needsDisplay = true
    }

    // MARK: Layout

    static let width: CGFloat = 540
    var card: NSRect {
        let w = min(Self.width, bounds.width - 32)
        let h = contentHeight
        return NSRect(x: (bounds.width - w) / 2, y: max(16, min(bounds.height * 0.12, bounds.height - h - 16)), width: w, height: h)
    }

    /// Where each row goes, from the card's top.
    var rowFrames: [NSRect] {
        let w = min(Self.width, bounds.width - 32) - 56
        var y: CGFloat = subtitle == nil ? 64 : 84
        var out: [NSRect] = []
        for r in rows {
            switch r {
            case .field, .secret, .choice: out.append(NSRect(x: 28, y: y + 18, width: w, height: 30)); y += 60
            case .area(_, _, _, _, let h): out.append(NSRect(x: 28, y: y + 18, width: w, height: h)); y += h + 30
            case .check: out.append(NSRect(x: 28, y: y, width: w, height: 22)); y += 30
            case .note(let s):
                let h = ceil((s as NSString).boundingRect(with: NSSize(width: w, height: 1000), options: [.usesLineFragmentOrigin],
                                                          attributes: [.font: NSFont.systemFont(ofSize: 12)]).height) + 4
                out.append(NSRect(x: 28, y: y, width: w, height: h)); y += h + 12
            }
        }
        return out
    }

    private var contentHeight: CGFloat {
        let last = rowFrames.last.map { $0.maxY } ?? 60
        return last + 20 + (error != nil ? 44 : 0) + 52
    }

    override func layout() {
        super.layout()
        canvas.frame = bounds
        let c = card
        for (r, f) in zip(rows, rowFrames) {
            let frame = f.offsetBy(dx: c.minX, dy: c.minY)
            switch r {
            case .field(let id, _, _, _, _), .secret(let id, _, _): fields[id]?.frame = frame
            case .area(let id, _, _, _, _):
                areaScrolls[id]?.frame = frame
                areas[id]?.frame = NSRect(x: 0, y: 0, width: frame.width, height: max(frame.height, areas[id]?.frame.height ?? 0))
            default: break
            }
        }
        canvas.needsDisplay = true
    }

    func appear() {
        needsLayout = true
        layoutSubtreeIfNeeded()
        // The first field takes the keyboard.
        for r in rows {
            switch r {
            case .field(let id, _, _, _, _), .secret(let id, _, _): window?.makeFirstResponder(fields[id]); return
            case .area(let id, _, _, _, _): window?.makeFirstResponder(areas[id]); return
            default: continue
            }
        }
        window?.makeFirstResponder(canvas)
    }

    // MARK: Acting

    @objc private func submitFromField() { submit() }

    func submit() {
        guard !busy, let onSubmit else { return }
        busy = true
        error = nil
        onSubmit(self) { [weak self] err in
            guard let self else { return }
            self.busy = false
            if let err { self.error = err } else { self.page?.closeSheet() }
        }
    }

    func cancel() { page?.closeSheet() }

    override func keyDown(with e: NSEvent) {
        if e.keyCode == 53 { return cancel() }
        super.keyDown(with: e)
    }

    override func cancelOperation(_ sender: Any?) { cancel() }

    func showChoices(_ id: String, rect: NSRect) {
        let list = options[id] ?? []
        let items = list.map { o in DropdownItem.item(o.title, checked: choices[id] == o.id) { [weak self] in
            guard let self else { return }
            self.choices[id] = o.id
            self.canvas.needsDisplay = true
            self.onChoice?(self, id)
        } }
        ThemedDropdown.show(items.isEmpty ? [.header("Loading…")] : items, under: canvas, rect: rect, minWidth: rect.width, searchable: items.count > 8)
    }

    /// Dev aid: what a test types or presses.
    func devSet(_ id: String, _ value: String) {
        if fields[id] != nil || areas[id] != nil { setText(id, value) }
        else if checks[id] != nil { checks[id] = value == "on" || value == "true" }
        else if options[id] != nil { choices[id] = value; onChoice?(self, id) }
        canvas.needsDisplay = true
    }

    var devState: String {
        let t = (fields.keys.sorted() + areas.keys.sorted()).map { "\($0)=\(text($0))" }
        let c = choices.keys.sorted().map { "\($0)=\(choices[$0] ?? "-")" }
        let k = checks.keys.sorted().map { "\($0)=\(checks[$0] == true ? "on" : "off")" }
        return "sheet \(title): " + (t + c + k).joined(separator: " ") + (error.map { " error=\($0)" } ?? "")
    }
}

/// ⌘↩ sends the form, esc closes it.
final class SheetTextView: NSTextView {
    weak var sheet: AtlassianSheet?

    override func keyDown(with e: NSEvent) {
        if e.keyCode == 36, e.modifierFlags.contains(.command) { sheet?.submit(); return }
        if e.keyCode == 53 { sheet?.cancel(); return }
        super.keyDown(with: e)
    }
}

final class SheetCanvas: PageCanvas, DropdownAnchor {
    weak var sheet: AtlassianSheet?
    var dropdownWanted: Bool { true }
    var dropdownOpen = false

    override func render() -> CGFloat {
        guard let sheet else { return 0 }
        fill(bounds, NSColor.black.withAlphaComponent(th.isDark ? 0.45 : 0.25))
        let c = sheet.card
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 24
        shadow.shadowOffset = NSSize(width: 0, height: -6)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.set()
        fill(c, th.background.mix(th.surface, 0.6), radius: PageCanvas.radius)
        NSGraphicsContext.restoreGraphicsState()
        stroke(c, th.border, radius: PageCanvas.radius)
        text(sheet.title, .systemFont(ofSize: 17, weight: .bold), th.foreground, x: c.minX + 28, y: c.minY + 24, width: c.width - 56)
        if let s = sheet.subtitle { text(s, .systemFont(ofSize: 12), th.dimText, x: c.minX + 28, y: c.minY + 50, width: c.width - 56) }
        for (r, f0) in zip(sheet.rows, sheet.rowFrames) {
            let f = f0.offsetBy(dx: c.minX, dy: c.minY)
            switch r {
            case .field(_, let label, _, _, _), .secret(_, let label, _):
                text(label.uppercased(), .systemFont(ofSize: 10, weight: .bold), th.dimText, x: f.minX, y: f.minY - 17, width: f.width)
            case .area(_, let label, _, _, _):
                text(label.uppercased(), .systemFont(ofSize: 10, weight: .bold), th.dimText, x: f.minX, y: f.minY - 17, width: f.width)
                // The text box, as the one-line fields look.
                fill(f, th.background.withAlphaComponent(0.6), radius: PageCanvas.radius)
                stroke(f, th.border, radius: PageCanvas.radius)
            case .choice(let id, let label):
                text(label.uppercased(), .systemFont(ofSize: 10, weight: .bold), th.dimText, x: f.minX, y: f.minY - 17, width: f.width)
                let hot = hover == "choice." + id
                fill(f, th.background.withAlphaComponent(hot ? 0.85 : 0.6), radius: PageCanvas.radius)
                stroke(f, hot ? th.accent.withAlphaComponent(0.6) : th.border, radius: PageCanvas.radius)
                let title = sheet.options[id]?.first { $0.id == sheet.choices[id] }?.title ?? (sheet.options[id]?.isEmpty == false ? "Choose…" : "Loading…")
                text(title, .systemFont(ofSize: 13), th.foreground, x: f.minX + 10, y: f.minY + 7, width: f.width - 40)
                symbol("chevron.up.chevron.down", NSRect(x: f.maxX - 26, y: f.minY, width: 18, height: f.height), th.dimText, size: 10, weight: .semibold)
                hit(f, "choice." + id) { [weak sheet, weak self] in sheet?.showChoices(id, rect: f); self?.needsDisplay = true }
            case .check(let id, let label, _):
                let on = sheet.checks[id] == true
                let box = NSRect(x: f.minX, y: f.minY + 2, width: 18, height: 18)
                fill(box, on ? th.accent : th.background.withAlphaComponent(0.6), radius: 5)
                stroke(box, on ? th.accent : th.border, radius: 5)
                if on { symbol("checkmark", box, th.accent.luminance > 0.55 ? .black : .white, size: 10, weight: .heavy) }
                text(label, .systemFont(ofSize: 13), th.foreground, x: f.minX + 28, y: f.minY + 2, width: f.width - 28)
                hit(f, "check." + id) { [weak sheet, weak self] in
                    sheet?.checks[id] = !on
                    self?.needsDisplay = true
                }
            case .note(let s):
                paragraph(s, .systemFont(ofSize: 12), th.dimText, x: f.minX, y: f.minY, width: f.width)
            }
        }
        var by = c.maxY - 52
        if let e = sheet.error {
            by -= 0
            let er = NSRect(x: c.minX + 28, y: c.maxY - 96, width: c.width - 56, height: 36)
            fill(er, th.red.withAlphaComponent(0.12), radius: PageCanvas.radius)
            symbol("exclamationmark.triangle", NSRect(x: er.minX + 8, y: er.minY, width: 16, height: er.height), th.red, size: 11)
            paragraph(e, .systemFont(ofSize: 12), th.red, x: er.minX + 30, y: er.minY + 4, width: er.width - 40, maxLines: 2)
        }
        by = c.maxY - 48
        let pw = button(sheet.busy ? "Working…" : sheet.primary, id: "primary", x: c.maxX - 24, y: by, height: 30, style: sheet.danger ? .danger : .primary,
                        rightAligned: true, enabled: !sheet.busy) { [weak sheet] in sheet?.submit() }
        button("Cancel", id: "cancel", x: c.maxX - 24 - pw - 8, y: by, height: 30, style: .secondary, rightAligned: true) { [weak sheet] in sheet?.cancel() }
        if !sheet.busy { text("esc to close", .systemFont(ofSize: 11), th.dimText.withAlphaComponent(0.7), x: c.minX + 28, y: by + 8, width: 200) }
        // A click outside the card closes it (in mouseUp; not a hit spot, which would sit over every other one).
        return bounds.height
    }

    override func mouseUp(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if let s = sheet, !s.card.contains(p), !s.busy { return s.cancel() }
        super.mouseUp(with: e)
    }

    override func keyDown(with e: NSEvent) {
        if e.keyCode == 53 { sheet?.cancel(); return }
        if e.keyCode == 36 { sheet?.submit(); return }
        super.keyDown(with: e)
    }
}

// MARK: The forms

extension AtlassianSheet {
    static func tokens(on page: AtlassianPageView) {
        let s = page.model.settings
        let sheet = AtlassianSheet("Jira & Bitbucket account", subtitle: "Blank token fields keep the tokens already saved.", rows: [
            .field("site", label: "Jira site", value: s.site, placeholder: "yourcompany.atlassian.net", mono: false),
            .field("email", label: "Atlassian account email", value: s.email, placeholder: "you@company.com", mono: false),
            .secret("jira", label: "Jira API token", placeholder: AtlassianTokens.get(.jira) == nil ? "Paste a token" : "Saved"),
            .secret("bitbucket", label: "Bitbucket API token", placeholder: AtlassianTokens.get(.bitbucket) == nil ? "Paste a token with Bitbucket scopes" : "Saved"),
        ], primary: "Save", page: page)
        sheet.onSubmit = { sh, done in
            page.model.connect(site: sh.text("site"), email: sh.text("email"), jiraToken: sh.text("jira"), bitbucketToken: sh.text("bitbucket"))
            page.model.bitbucketMe = nil
            page.model.load(force: true)
            done(page.model.connectError)
        }
        page.show(sheet)
    }

    static func confirm(_ title: String, detail: String, action: String, danger: Bool, on page: AtlassianPageView, then: @escaping (@escaping (String?) -> Void) -> Void) {
        let sheet = AtlassianSheet(title, rows: [.note(detail)], primary: action, danger: danger, page: page)
        sheet.onSubmit = { _, done in then(done) }
        page.show(sheet)
    }

    // MARK: Start work

    static func startWork(_ i: JiraIssue, on page: AtlassianPageView) {
        let m = page.model
        // The folder may have changed since the page last looked. Then what the form shows from the start: whether
        // there are uncommitted changes, and the repository's branch types (asked of Bitbucket once per repository).
        m.findRepo(page.tabFolder) {
            guard let root = m.repoRoot else { return show(i, m, page, dirty: false, types: []) }
            let group = DispatchGroup()
            var dirty = false
            var types = m.repo.flatMap { m.branchTypes[$0.fullName] }
            group.enter()
            LocalGit.run(root, ["status", "--porcelain", "--untracked-files=no"]) { o in
                dirty = o.ok && !o.out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                group.leave()
            }
            if types == nil, let repo = m.repo, m.api.hasCredentials(.bitbucket) {
                group.enter()
                m.api.branchTypes(repo) { t in
                    m.branchTypes[repo.fullName] = t
                    types = t
                    group.leave()
                }
            }
            group.notify(queue: .main) { show(i, m, page, dirty: dirty, types: types ?? []) }
        }
    }

    private static func show(_ i: JiraIssue, _ m: AtlassianModel, _ page: AtlassianPageView, dirty: Bool, types: [BranchType]) {
        let startIds = m.startStatusIds()
        var rows: [Row] = []
        let hasRepo = m.repoRoot != nil
        // The ticket's branches already in this repository (Jira's and those with its key): one can be picked up again.
        let existing = hasRepo ? JiraBranch.merged(m.detail?.key == i.key ? m.branches : [], key: i.key, local: m.repoBranches, repo: m.repo?.fullName)
            .filter(\.inRepo).map(\.name) : []
        // The kind of branch (its prefix), when the repository's branching model has kinds: a bug's is bugfix. Without
        // one, the team's own prefix from its branches' names, if they share one.
        let kind = BranchType.suggested(for: i.type, from: types)
        let prefix = types.isEmpty ? m.settings.branchPrefix : kind?.prefix
        let fresh = { (prefix: String?) in BranchNames.forIssue(key: i.key, summary: i.summary, prefix: prefix) }
        if hasRepo {
            let place = m.repo?.fullName ?? (m.repoRoot! as NSString).lastPathComponent
            var note = "In \(place)" + (m.branch.map { ", on \($0)" } ?? "") + "."
            if dirty { note += " You have uncommitted changes: they come along to the branch." }
            rows.append(.note(note))
            if !existing.isEmpty { rows.append(.choice("work", label: "Work on")) }
            if !types.isEmpty { rows.append(.choice("kind", label: "Branch type")) }
            rows.append(.field("branch", label: "Branch", value: existing.first ?? fresh(prefix), placeholder: "branch name", mono: true))
            rows.append(.choice("from", label: "From"))
            rows.append(.check("push", label: "Push it to origin and track it", on: true))
        } else {
            rows.append(.note("This tab isn't in a git repository on this Mac, so only the ticket changes. cd into the repository in this tab's terminal to have its branch made too."))
            rows.append(.field("branch", label: "Branch name, to copy", value: fresh(prefix), placeholder: "branch name", mono: true))
        }
        rows.append(.choice("status", label: "Status"))
        if i.assignee?.accountId != m.me?.accountId { rows.append(.check("assign", label: "Assign \(i.key) to me", on: true)) }
        let sheet = AtlassianSheet("Start work on \(i.key)", subtitle: i.summary, rows: rows, primary: hasRepo ? "Start work" : "Start", page: page)
        // Work on: a new branch, or one of the ticket's own (then that's the name, and it's switched to).
        if !existing.isEmpty {
            sheet.setOptions("work", [(id: "", title: "A new branch")] + existing.map { (id: $0, title: $0 == m.branch ? "\($0) · you're on it" : $0) },
                             selected: existing.first)
        }
        if !types.isEmpty {
            sheet.setOptions("kind", [(id: "", title: "None")] + types.map { (id: $0.prefix, title: $0.kind.capitalized + " · " + $0.prefix) },
                             selected: kind?.prefix ?? "")
        }
        sheet.onChoice = { sh, id in
            switch id {
            case "work": sh.setText("branch", sh.choices["work"].flatMap { $0.isEmpty ? nil : $0 } ?? fresh(sh.choices["kind"] ?? prefix))
            case "kind": if (sh.choices["work"] ?? "").isEmpty { sh.setText("branch", fresh(sh.choices["kind"].flatMap { $0.isEmpty ? nil : $0 })) }
            default: break
            }
        }
        // Status: where the ticket goes, the board's In Progress column by default, or nowhere.
        let statusOptions = { (list: [JiraTransition]) in
            let target = JiraTransition.into(startIds, from: list)
            let already = startIds.contains(i.status.id)
            sheet.setOptions("status", [(id: "", title: "Leave it in \(i.status.name)")] + list.map { (id: $0.id, title: "Move to \($0.to.name)") },
                             selected: already ? "" : target?.id ?? "")
        }
        if m.detail?.key == i.key, !m.transitions.isEmpty { statusOptions(m.transitions) }
        else { m.api.transitions(i.key) { r in statusOptions((try? r.get()) ?? []) } }
        if let root = m.repoRoot {
            LocalGit.branches(root) { [weak sheet] all in
                guard let sheet else { return }
                // Offer the remote's branches first (what a new branch should start from), then local ones.
                let remote = all.filter { $0.hasPrefix("origin/") }, local = all.filter { !$0.hasPrefix("origin/") }
                let list = (remote + local).map { (id: $0, title: $0) }
                // The team's naming, from its branches, unless one was chosen before or the branching model says.
                if types.isEmpty, existing.isEmpty, m.settings.branchPrefix == nil, let p = BranchNames.prefix(usedIn: all) {
                    sheet.setText("branch", fresh(p))
                }
                let head = LocalGit.runNow(root, ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"]).out.trimmingCharacters(in: .whitespacesAndNewlines)
                sheet.setOptions("from", list, selected: head.isEmpty ? nil : head)
            }
        }
        sheet.onSubmit = { sh, done in
            let branch = sh.text("branch").trimmingCharacters(in: .whitespaces)
            guard BranchNames.isValid(branch) else { return done("“\(branch)” isn't a name git takes for a branch.") }
            var steps: [String] = []
            // Jira's part, after git's (so a branch that couldn't be made leaves the ticket as it was).
            let jira = {
                let group = DispatchGroup()
                var problems: [String] = []
                if sh.checks["assign"] == true, let me = m.me {
                    group.enter()
                    m.api.assign(i.key, me.accountId) { e in
                        if let e { problems.append(e.message) } else { steps.append("assigned to you") }
                        group.leave()
                    }
                }
                if let t = sh.choices["status"], !t.isEmpty {
                    let to = sh.options["status"]?.first { $0.id == t }?.title.replacingOccurrences(of: "Move to ", with: "") ?? "its new status"
                    group.enter()
                    m.api.transition(i.key, t) { e in
                        if let e { problems.append(e.message) } else { steps.append("moved to \(to)") }
                        group.leave()
                    }
                }
                group.notify(queue: .main) {
                    m.refresh(i.key)
                    if m.repoRoot == nil {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(branch, forType: .string)
                        steps.append("branch name copied")
                    }
                    if problems.isEmpty {
                        m.say("\(i.key): " + steps.joined(separator: ", "))
                        done(nil)
                    } else {
                        m.say("\(i.key): " + (steps + problems).joined(separator: "; "), ok: false)
                        done(problems.joined(separator: " "))
                    }
                }
            }
            guard let root = m.repoRoot else { return jira() }
            let from = sh.choices["from"] ?? "HEAD"
            DispatchQueue.global(qos: .userInitiated).async {
                if from.hasPrefix("origin/") { _ = LocalGit.runNow(root, ["fetch", "origin", String(from.dropFirst(7))]) }
                // A branch that's here already is switched to; one only on origin is checked out tracking it; else
                // it's made from `from`.
                let exists = LocalGit.runNow(root, ["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"]).ok
                if !exists { _ = LocalGit.runNow(root, ["fetch", "origin", branch]) }
                let onOrigin = !exists && LocalGit.runNow(root, ["rev-parse", "--verify", "--quiet", "refs/remotes/origin/\(branch)"]).ok
                let co = exists ? LocalGit.runNow(root, ["checkout", branch])
                    : onOrigin ? LocalGit.runNow(root, ["checkout", "-b", branch, "--track", "origin/\(branch)"])
                    : LocalGit.runNow(root, ["checkout", "--no-track", "-b", branch, from])
                var pushNote: String?
                if co.ok, !onOrigin, sh.checks["push"] == true {
                    let p = LocalGit.runNow(root, ["push", "-u", "origin", branch])
                    if !p.ok { pushNote = "couldn't push (\(p.message))" }
                }
                DispatchQueue.main.async {
                    guard co.ok else { return done("git couldn't \(exists ? "switch to" : "make") \(branch): \(co.message)") }
                    m.branch = branch
                    m.loadRepoBranches()
                    steps.append(exists || onOrigin ? "switched to \(branch)" : "on new branch \(branch)")
                    if let pushNote { steps.append(pushNote) } else if sh.checks["push"] == true, !onOrigin { steps.append("pushed") }
                    jira()
                }
            }
        }
        page.show(sheet)
    }

    // MARK: Creating a ticket

    static func createIssue(on page: AtlassianPageView) {
        let m = page.model
        let project = m.board?.projectKey ?? m.detail?.projectKey ?? m.issues.first?.projectKey ?? ""
        let sheet = AtlassianSheet("Create issue", subtitle: m.board.map { "On \($0.name)" }, rows: [
            .field("project", label: "Project", value: project, placeholder: "ABC", mono: true),
            .choice("type", label: "Type"),
            .field("summary", label: "Summary", value: "", placeholder: "What needs doing", mono: false),
            .area("description", label: "Description", value: "", placeholder: "", height: 120),
            .check("assign", label: "Assign to me", on: true),
            .check("open", label: "Open it when it's made", on: true),
            .check("start", label: "Then start work on it (branch and status)", on: m.settings.startAfterCreate),
        ], primary: "Create", page: page)
        let loadTypes = { [weak sheet] (key: String) in
            guard !key.isEmpty else { return }
            m.api.issueTypes(key) { r in
                guard let sheet, case .success(let types) = r else { return }
                let list = types.filter { !$0.isSubtask }.map { (id: $0.id, title: $0.name) }
                sheet.setOptions("type", list, selected: types.first { $0.name.lowercased() == "task" }?.id)
            }
        }
        loadTypes(project)
        sheet.fields["project"]?.target = nil
        (sheet.fields["project"] as? ThemedField)?.onCommit = { loadTypes($0.uppercased()) }
        sheet.onSubmit = { sh, done in
            let key = sh.text("project").trimmingCharacters(in: .whitespaces).uppercased()
            let summary = sh.text("summary").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return done("Which project? (Its key, like ABC.)") }
            guard !summary.isEmpty else { return done("Give it a summary.") }
            guard let type = sh.choices["type"] else { loadTypes(key); return done("Pick a type (loading \(key)'s types…).") }
            m.api.create(project: key, type: type, summary: summary, description: sh.text("description"),
                         assignee: sh.checks["assign"] == true ? m.me?.accountId : nil, parent: nil) { r in
                switch r {
                case .failure(let e): done(e.message)
                case .success(let newKey):
                    m.say("Created \(newKey)")
                    m.load(force: true)
                    if m.settings.section == AtlassianSection.board.rawValue { m.loadBoard() }
                    if sh.checks["open"] == true { page.openIssue(newKey) }
                    let start = sh.checks["start"] == true
                    if start != m.settings.startAfterCreate { m.settings.startAfterCreate = start }
                    done(nil)
                    // Start work's form next, for the new ticket: the same branch, From and status choices.
                    if start {
                        m.api.issue(newKey, storyPointsField: m.config?.storyPointsField) { r in
                            switch r {
                            case .success(let i): startWork(i, on: page)
                            case .failure(let e): m.say("Created \(newKey), but couldn't start work on it: \(e.message)", ok: false)
                            }
                        }
                    }
                }
            }
        }
        page.show(sheet)
    }

    // MARK: Editing a ticket

    static func editSummary(_ i: JiraIssue, on page: AtlassianPageView) {
        let sheet = AtlassianSheet("Edit \(i.key)", rows: [.field("summary", label: "Summary", value: i.summary, placeholder: "", mono: false)],
                                   primary: "Save", page: page)
        sheet.onSubmit = { sh, done in
            let s = sh.text("summary").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty else { return done("A summary can't be empty.") }
            page.model.api.edit(i.key, fields: ["summary": s]) { e in
                if let e { return done(e.message) }
                page.model.refresh(i.key)
                done(nil)
            }
        }
        page.show(sheet)
    }

    static func editDescription(_ i: JiraIssue, on page: AtlassianPageView) {
        let sheet = AtlassianSheet("Description of \(i.key)", subtitle: "Blank lines between paragraphs, - for bullets, ``` around code. ⌘↩ saves.", rows: [
            .area("description", label: "Description", value: ADF.plainText(i.description), placeholder: "", height: 240),
        ], primary: "Save", page: page)
        sheet.onSubmit = { sh, done in
            page.model.api.edit(i.key, fields: ["description": ADF.document(sh.text("description"))]) { e in
                if let e { return done(e.message) }
                page.model.refresh(i.key)
                done(nil)
            }
        }
        page.show(sheet)
    }

    static func comment(_ i: JiraIssue, on page: AtlassianPageView) {
        let sheet = AtlassianSheet("Comment on \(i.key)", subtitle: i.summary, rows: [
            .area("text", label: "Comment", value: "", placeholder: "", height: 140),
        ], primary: "Comment", page: page)
        sheet.onSubmit = { sh, done in
            let t = sh.text("text").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return done("Write something first.") }
            page.model.addComment(i.key, t) { e in done(e?.message) }
        }
        page.show(sheet)
    }

    // MARK: Pull requests

    static func createPR(on page: AtlassianPageView) {
        let m = page.model
        m.findRepo(page.tabFolder) { createPRSheet(m, page) }
    }

    private static func createPRSheet(_ m: AtlassianModel, _ page: AtlassianPageView) {
        guard let repo = m.repo, let root = m.repoRoot else { return m.say("This tab isn't in a Bitbucket repository.", ok: false) }
        guard let branch = m.branch else { return m.say("The repository isn't on a branch (a detached HEAD).", ok: false) }
        let key = IssueKeys.first(in: branch)
        let issue = key.flatMap { k in (m.issues + m.mine + m.recent).first { $0.key == k } ?? (m.detail?.key == k ? m.detail : nil) }
        let title = key.map { k in "\(k): " + (issue?.summary ?? branchWords(branch, after: k)) } ?? branchWords(branch, after: nil)
        var desc = ""
        if let k = key, let url = m.api.browseURL(k) { desc = "[\(k)](\(url.absoluteString))" + (issue.map { ": \($0.summary)" } ?? "") + "\n\n" }
        let upstream = LocalGit.runNow(root, ["rev-parse", "--abbrev-ref", "\(branch)@{upstream}"])
        let ahead = upstream.ok ? Int(LocalGit.runNow(root, ["rev-list", "--count", "@{upstream}..HEAD"]).out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 : 0
        var rows: [Row] = [
            .note("\(repo.path): \(branch) into…"),
            .choice("into", label: "Into"),
            .field("title", label: "Title", value: title, placeholder: "", mono: false),
            .area("description", label: "Description", value: desc, placeholder: "", height: 110),
            .note("Reviewers: loading the repository's default reviewers…"),
            .check("close", label: "Delete \(branch) on Bitbucket after it's merged", on: true),
        ]
        if !upstream.ok || ahead > 0 {
            rows.append(.check("push", label: upstream.ok ? "Push the \(ahead) commit\(ahead == 1 ? "" : "s") Bitbucket doesn't have yet" : "Push \(branch) to Bitbucket first", on: true))
        }
        let sheet = AtlassianSheet("Create pull request", subtitle: branch, rows: rows, primary: "Create pull request", page: page)
        // The ticket's own summary for the title, when it isn't on the page yet (and the title hasn't been touched).
        if let k = key, issue == nil {
            m.api.issue(k) { [weak sheet] r in
                guard let sheet, case .success(let i) = r, sheet.text("title") == title else { return }
                sheet.setText("title", "\(k): \(i.summary)")
                if sheet.text("description") == desc, let url = m.api.browseURL(k) { sheet.setText("description", "[\(k)](\(url.absoluteString)): \(i.summary)\n\n") }
            }
        }
        var reviewers: [BitbucketUser] = []
        m.api.defaultReviewers(repo) { [weak sheet] r in
            if case .success(let list) = r { reviewers = list.filter { $0.uuid != m.bitbucketMe?.uuid } }
            sheet?.replaceNote(4, reviewers.isEmpty ? "No default reviewers: add them on Bitbucket afterwards." : "Reviewers: " + reviewers.map(\.displayName).joined(separator: ", ") + " (the repository's defaults).")
        }
        LocalGit.branches(root) { [weak sheet] all in
            let names = all.filter { $0.hasPrefix("origin/") }.map { String($0.dropFirst(7)) }.filter { $0 != branch }
            m.api.mainBranch(repo) { main in
                // The branch it was made from is a better guess than the main one, when git can tell.
                let list = names.map { (id: $0, title: $0) }
                sheet?.setOptions("into", list, selected: main)
            }
        }
        sheet.onSubmit = { sh, done in
            guard let into = sh.choices["into"] else { return done("Pick the branch to merge into.") }
            let title = sh.text("title").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return done("Give it a title.") }
            let create = {
                m.api.createPR(repo, title: title, description: sh.text("description"), source: branch, destination: into,
                               reviewers: reviewers.map(\.uuid), closeSource: sh.checks["close"] == true) { r in
                    switch r {
                    case .failure(let e): done(e.message)
                    case .success(let p):
                        m.say("Opened pull request #\(p.id)")
                        m.prs.insert(p, at: 0)
                        page.section = .prs
                        page.openPR(p.id)
                        done(nil)
                    }
                }
            }
            guard sh.checks["push"] == true else { return create() }
            LocalGit.run(root, ["push", "-u", "origin", branch]) { o in
                guard o.ok else { return done("Couldn't push \(branch): \(o.message)") }
                create()
            }
        }
        page.show(sheet)
    }

    /// "ABC-569-add-login-page" → "Add login page".
    static func branchWords(_ branch: String, after key: String?) -> String {
        var s = branch.split(separator: "/").last.map(String.init) ?? branch
        if let key, let r = s.uppercased().range(of: key) { s = String(s[r.upperBound...]) }
        let words = s.split { $0 == "-" || $0 == "_" }.map(String.init)
        guard let first = words.first else { return branch }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + words.dropFirst()).joined(separator: " ")
    }

    static func merge(_ p: BitbucketPullRequest, on page: AtlassianPageView) {
        guard let repo = page.model.repo else { return }
        let sheet = AtlassianSheet("Merge #\(p.id)", subtitle: "\(p.source) → \(p.destination)", rows: [
            .choice("strategy", label: "How"),
            .check("close", label: "Delete \(p.source) after merging", on: p.closeSourceBranch),
            .note(p.approvals == 0 ? "Nobody has approved it yet." : "\(p.approvals) approval\(p.approvals == 1 ? "" : "s")."),
        ], primary: "Merge", page: page)
        sheet.setOptions("strategy", [(id: "merge_commit", title: "Merge commit"), (id: "squash", title: "Squash"), (id: "fast_forward", title: "Fast forward")], selected: "merge_commit")
        sheet.onSubmit = { sh, done in
            page.model.api.merge(repo, p.id, strategy: sh.choices["strategy"] ?? "merge_commit", closeSource: sh.checks["close"] == true) { e in
                if let e { return done(e.message) }
                page.model.say("Merged #\(p.id) into \(p.destination)")
                page.model.loadPRs()
                page.model.openPR(p.id)
                done(nil)
            }
        }
        page.show(sheet)
    }

    static func prComment(_ p: BitbucketPullRequest, on page: AtlassianPageView) {
        guard let repo = page.model.repo else { return }
        let sheet = AtlassianSheet("Comment on #\(p.id)", subtitle: p.title, rows: [.area("text", label: "Comment", value: "", placeholder: "", height: 140)],
                                   primary: "Comment", page: page)
        sheet.onSubmit = { sh, done in
            let t = sh.text("text").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return done("Write something first.") }
            page.model.api.addPRComment(repo, p.id, t) { e in
                if let e { return done(e.message) }
                page.model.openPR(p.id)
                done(nil)
            }
        }
        page.show(sheet)
    }
}
