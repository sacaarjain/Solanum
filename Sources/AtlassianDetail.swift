import AppKit

// The Atlassian page's details: a ticket in a panel over the right of the board or list (its fields, description,
// comments and actions), and a pull request on a page of its own (reviewers, builds, the diff and comments).

extension PageCanvas {
    /// Jira's rich text (or a pull request's description, made into blocks): paragraphs, headings, lists, code.
    /// Returns the height used.
    @discardableResult
    func blocks(_ list: [DocBlock], x: CGFloat, y y0: CGFloat, width: CGFloat, size: CGFloat = 12.5) -> CGFloat {
        var y = y0
        let body = NSFont.systemFont(ofSize: size)
        for (n, b) in list.enumerated() {
            if n > 0 { y += 8 }
            switch b.kind {
            case .paragraph:
                y += paragraph(b.text, body, th.foreground.withAlphaComponent(0.92), x: x, y: y, width: width)
            case .heading(let level):
                y += 4
                y += paragraph(b.text, .systemFont(ofSize: size + CGFloat(max(0, 4 - level)) * 1.5, weight: .bold), th.foreground, x: x, y: y, width: width)
            case .item(let depth, let number):
                let indent = CGFloat(depth) * 16
                let bullet = number.map { "\($0)." } ?? "•"
                text(bullet, body, th.dimText, x: x + indent, y: y, width: 22, align: number == nil ? .center : .right)
                y += paragraph(b.text, body, th.foreground.withAlphaComponent(0.92), x: x + indent + 26, y: y, width: width - indent - 26)
                y -= 4
            case .code:
                let font = NSFont.monospacedSystemFont(ofSize: size - 1.5, weight: .regular)
                let h = paragraphHeight(b.text, font, width: width - 20)
                fill(NSRect(x: x, y: y, width: width, height: h + 16), th.background.withAlphaComponent(0.7), radius: PageCanvas.radius)
                paragraph(b.text, font, th.foreground, x: x + 10, y: y + 8, width: width - 20)
                y += h + 16
            case .quote:
                let h = paragraphHeight(b.text, body, width: width - 16)
                fill(NSRect(x: x, y: y, width: 3, height: h), th.accent.withAlphaComponent(0.6), radius: 1.5)
                paragraph(b.text, body, th.dimText, x: x + 14, y: y, width: width - 16)
                y += h
            case .rule:
                line(y + 6, from: x, to: x + width)
                y += 12
            case .media:
                symbol("paperclip", NSRect(x: x, y: y, width: 16, height: 18), th.dimText, size: 11)
                y += paragraph(b.text, body, th.dimText, x: x + 20, y: y, width: width - 20)
            }
        }
        return y - y0
    }

    /// Where an unassigned ticket's person would be: a dashed ring.
    func emptyAvatar(_ r: NSRect) {
        guard visible(r) else { return }
        let ring = NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1))
        ring.lineWidth = 1.2
        ring.setLineDash([2.5, 2.5], count: 2, phase: 0)
        th.dimText.withAlphaComponent(0.6).setStroke()
        ring.stroke()
    }

    func paragraphHeight(_ s: String, _ font: NSFont, width: CGFloat) -> CGFloat {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byWordWrapping
        p.lineSpacing = 2
        return ceil((s as NSString).boundingRect(with: NSSize(width: max(1, width), height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin],
                                                 attributes: [.font: font, .paragraphStyle: p]).height)
    }

    /// A small heading over a part of a page.
    func label(_ s: String, x: CGFloat, y: CGFloat, width: CGFloat) {
        text(s.uppercased(), .systemFont(ofSize: 10, weight: .bold), th.dimText, x: x, y: y, width: width)
    }
}

// MARK: A ticket

final class IssueDrawer: NSView {
    weak var page: AtlassianPageView? { didSet { canvas.page = page } }
    let canvas = IssueDrawerCanvas()
    private let scroll: CanvasScroll
    /// Frosted glass over what's behind (the board), tinted with the theme so it still reads as Solanum's.
    private let frost = NSVisualEffectView()
    private let tint = NSView()
    static let radius: CGFloat = PageCanvas.radius

    override init(frame: NSRect) {
        scroll = CanvasScroll(canvas)
        super.init(frame: frame)
        wantsLayer = true
        frost.material = .popover
        frost.blendingMode = .withinWindow
        frost.state = .active
        frost.wantsLayer = true
        frost.layer?.cornerRadius = Self.radius
        frost.layer?.cornerCurve = .continuous
        frost.layer?.masksToBounds = true
        frost.layer?.borderWidth = 1
        tint.wantsLayer = true
        addSubview(frost)
        frost.addSubview(tint)
        frost.addSubview(scroll)
        // A soft shadow under the card, so it floats over the board.
        layer?.shadowOpacity = 1
        layer?.shadowRadius = 22
        layer?.shadowOffset = CGSize(width: 0, height: -8)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        frost.frame = bounds
        tint.frame = frost.bounds
        // Inset from the rounded edge, so the scroller and the content keep clear of the corners.
        scroll.frame = frost.bounds.insetBy(dx: 0, dy: 6)
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: Self.radius, cornerHeight: Self.radius, transform: nil)
        scroll.refit()
    }

    func refresh() {
        let th = Config.shared.theme
        frost.appearance = NSAppearance(named: th.isDark ? .darkAqua : .aqua)
        tint.layer?.backgroundColor = th.background.mix(th.surface, 0.5).withAlphaComponent(0.68).cgColor
        frost.layer?.borderColor = th.foreground.withAlphaComponent(th.isDark ? 0.12 : 0.1).cgColor
        layer?.shadowColor = NSColor.black.withAlphaComponent(th.isDark ? 0.45 : 0.22).cgColor
        scroll.refit()
    }

    func applyTheme() { refresh() }

    func scrollToTop() { scroll.scrollToTop() }
}

final class IssueDrawerCanvas: PageCanvas, DropdownAnchor {
    weak var page: AtlassianPageView?
    var dropdownWanted: Bool { true }
    var dropdownOpen = false
    private var statusRect: NSRect = .zero
    private var assigneeRect: NSRect = .zero
    private var priorityRect: NSRect = .zero
    private var typeRect: NSRect = .zero

    /// Esc closes the panel.
    override func keyDown(with e: NSEvent) {
        if e.keyCode == 53, page?.model.detail != nil { page?.closeIssue(); return }
        super.keyDown(with: e)
    }

    /// The ticket last shown: drawn while the panel slides away after it's closed.
    var lastShown: JiraIssue?

    override func render() -> CGFloat {
        guard let page, let i = page.model.detail ?? lastShown else { return 0 }
        if page.model.detail != nil { lastShown = i }
        let m = page.model
        let pad: CGFloat = 20
        let w = bounds.width - pad * 2
        var y: CGFloat = 16
        // Top: type and key, link, close.
        IssueGlyph.type(i.type, NSRect(x: pad, y: y + 1, width: 18, height: 18), th)
        let kf = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
        let kw = PageCanvas.textWidth(i.key, kf)
        let kr = NSRect(x: pad + 26, y: y, width: kw + 4, height: 20)
        text(i.key, kf, hover == "key" ? th.accent : th.dimText, x: kr.minX, y: y + 2, width: kr.width)
        hit(kr, "key") { [weak m] in if let u = m?.api.browseURL(i.key) { NSWorkspace.shared.open(u) } }
        if let pk = i.parentKey {
            text("in", .systemFont(ofSize: 11.5), th.dimText, x: kr.maxX + 6, y: y + 3, width: 14)
            let pr = NSRect(x: kr.maxX + 22, y: y, width: min(w - kr.maxX, PageCanvas.textWidth(pk, kf) + 6), height: 20)
            text(pk, kf, hover == "parent" ? th.accent : th.dimText, x: pr.minX, y: y + 2, width: pr.width)
            hit(pr, "parent") { [weak page] in page?.openIssue(pk) }
        }
        // Right of the key: edit, open in Jira, close (plain icons, one size).
        var ix = bounds.width - pad + 4
        ix -= button("", id: "close", x: ix, y: y - 4, height: 26, symbol: "xmark", style: .plain, rightAligned: true) { [weak page] in
            page?.closeIssue()
        } + 2
        ix -= button("", id: "browser", x: ix, y: y - 4, height: 26, symbol: "arrow.up.right.square", style: .plain, rightAligned: true) { [weak m] in
            if let u = m?.api.browseURL(i.key) { NSWorkspace.shared.open(u) }
        } + 2
        ix -= button("", id: "editsummary", x: ix, y: y - 4, height: 26, symbol: "pencil", style: .plain, rightAligned: true) { [weak page] in
            guard let page else { return }
            AtlassianSheet.editSummary(i, on: page)
        } + 2
        if m.loadingDetail { symbol("hourglass", NSRect(x: ix - 22, y: y, width: 18, height: 20), th.dimText, size: 11) }
        y += 32
        // Summary.
        y += paragraph(i.summary, .systemFont(ofSize: 17, weight: .bold), th.foreground, x: pad, y: y, width: w)
        y += 16

        // Status and actions.
        let sf = NSFont.systemFont(ofSize: 11.5, weight: .bold)
        let sname = i.status.name.uppercased()
        let sw = PageCanvas.textWidth(sname, sf) + 34
        statusRect = NSRect(x: pad, y: y, width: sw, height: 30)
        let sc = IssueGlyph.statusColor(i.status, th)
        fill(statusRect, sc.withAlphaComponent(hover == "status" ? 0.32 : 0.2), radius: PageCanvas.radius)
        text(sname, sf, th.isDark ? sc.mix(.white, 0.3) : sc.mix(.black, 0.35), x: statusRect.minX + 10, y: AtlassianHeader.textY(sf, in: statusRect), width: sw - 30)
        symbol("chevron.down", NSRect(x: statusRect.maxX - 20, y: y, width: 14, height: 30), th.dimText, size: 9, weight: .bold)
        hit(statusRect, "status") { [weak self] in self?.showTransitions() }
        // The actions after the status, onto a second row when the panel's too narrow for them.
        var bx = statusRect.maxX + 8
        let bf = NSFont.systemFont(ofSize: 12, weight: .semibold)
        func place(_ title: String, symbol: Bool = true) -> (CGFloat, CGFloat) {
            let bw = title.isEmpty ? 28 : PageCanvas.textWidth(title, bf) + (symbol ? 40 : 24)
            if bx + bw > bounds.width - pad { bx = pad; y += 38 }
            defer { bx += bw + 6 }
            return (bx, y)
        }
        var at = place("Start work")
        button("Start work", id: "start", x: at.0, y: at.1, height: 30, symbol: "play.fill", style: .primary) { [weak page] in
            guard let page else { return }
            AtlassianSheet.startWork(i, on: page)
        }
        at = place("Ask Claude")
        button("Ask Claude", id: "askclaude", x: at.0, y: at.1, height: 30, symbol: "sparkles", style: .secondary) { [weak page] in page?.askClaude(about: i) }
        y += 48

        // Fields.
        let lw: CGFloat = 96
        func field(_ name: String, _ h: CGFloat = 24, draw: (CGFloat, CGFloat) -> Void) {
            text(name, .systemFont(ofSize: 12), th.dimText, x: pad, y: y + 4, width: lw - 8)
            draw(pad + lw, y)
            y += h + 4
        }
        field("Assignee") { x, yy in
            assigneeRect = NSRect(x: x - 4, y: yy, width: w - lw + 4, height: 24)
            if hover == "assignee" { fill(assigneeRect, th.foreground.withAlphaComponent(0.06), radius: PageCanvas.radius) }
            if let a = i.assignee {
                avatar(a.avatarURL.flatMap(URL.init(string:)), NSRect(x: x, y: yy + 1, width: 22, height: 22), initials: PageCanvas.initials(a.displayName))
                text(a.displayName, .systemFont(ofSize: 12.5), th.foreground, x: x + 30, y: yy + 4, width: w - lw - 40)
            } else {
                text("Unassigned", .systemFont(ofSize: 12.5), th.dimText, x: x, y: yy + 4, width: 100)
                if let me = m.me, hover != "assignee" {
                    _ = me
                    let tw = PageCanvas.textWidth("Unassigned", .systemFont(ofSize: 12.5))
                    button("Assign to me", id: "assignme", x: x + tw + 10, y: yy, height: 22, style: .plain) { [weak m] in m?.assign(i.key, to: m?.me) }
                }
            }
            hit(assigneeRect, "assignee") { [weak self] in self?.showAssignees() }
        }
        field("Priority") { x, yy in
            priorityRect = NSRect(x: x - 4, y: yy, width: 160, height: 24)
            if hover == "priority" { fill(priorityRect, th.foreground.withAlphaComponent(0.06), radius: PageCanvas.radius) }
            if let p = i.priority {
                IssueGlyph.priority(p, NSRect(x: x, y: yy + 4, width: 16, height: 16), th)
                text(p, .systemFont(ofSize: 12.5), th.foreground, x: x + 22, y: yy + 4, width: 130)
            } else { text("None", .systemFont(ofSize: 12.5), th.dimText, x: x, y: yy + 4, width: 130) }
            hit(priorityRect, "priority") { [weak self] in self?.showPriorities() }
        }
        field("Type") { x, yy in
            typeRect = NSRect(x: x - 4, y: yy, width: min(w - lw + 4, PageCanvas.textWidth(i.type, .systemFont(ofSize: 12.5)) + 48), height: 24)
            if hover == "type" { fill(typeRect, th.foreground.withAlphaComponent(0.06), radius: PageCanvas.radius) }
            IssueGlyph.type(i.type, NSRect(x: x, y: yy + 4, width: 16, height: 16), th)
            text(i.type, .systemFont(ofSize: 12.5), th.foreground, x: x + 22, y: yy + 4, width: w - lw - 22)
            if hover == "type" { symbol("chevron.down", NSRect(x: typeRect.maxX - 18, y: yy, width: 12, height: 24), th.dimText, size: 8, weight: .bold) }
            hit(typeRect, "type") { [weak self] in self?.showTypes() }
        }
        if let r = i.reporter {
            field("Reporter") { x, yy in
                avatar(r.avatarURL.flatMap(URL.init(string:)), NSRect(x: x, y: yy + 1, width: 22, height: 22), initials: PageCanvas.initials(r.displayName))
                text(r.displayName, .systemFont(ofSize: 12.5), th.foreground, x: x + 30, y: yy + 4, width: w - lw - 40)
            }
        }
        if let sp = i.storyPoints {
            field("Points") { x, yy in text(sp == sp.rounded() ? "\(Int(sp))" : "\(sp)", .systemFont(ofSize: 12.5, weight: .semibold), th.foreground, x: x, y: yy + 4, width: 80) }
        }
        if !i.labels.isEmpty {
            field("Labels") { x, yy in
                var lx = x
                for l in i.labels where lx < bounds.width - pad - 40 { lx += pill(l, x: lx, y: yy + 3, color: th.ansi[6]) + 4 }
            }
        }
        if let c = i.created {
            field("Created") { x, yy in
                text(PageCanvas.ago(c) + (i.updated.map { " · updated " + PageCanvas.ago($0) } ?? ""), .systemFont(ofSize: 12.5), th.foreground, x: x, y: yy + 4, width: w - lw)
            }
        }
        // Branches: Jira's development panel's, and the repository's with the key. One in the tab's repository checks
        // out; another opens in Bitbucket.
        let branches = m.branches
        if !branches.isEmpty {
            y += 10
            label("Branches", x: pad, y: y, width: w)
            y += 20
            for (n, b) in branches.enumerated() {
                let r = NSRect(x: pad, y: y, width: w, height: 30)
                let id = "branch.\(n)"
                let current = b.inRepo && b.name == m.branch
                fill(r, hover == id ? th.foreground.withAlphaComponent(0.08) : th.surface.withAlphaComponent(0.6), radius: PageCanvas.radius)
                symbol("arrow.triangle.branch", NSRect(x: r.minX + 8, y: r.minY, width: 16, height: 30), current ? th.green : th.accent, size: 11)
                let tag = current ? "checked out" : b.inRepo ? (hover == id ? "check out" : "") : (b.repository ?? "")
                let tagW = tag.isEmpty ? 0 : min(PageCanvas.textWidth(tag, .systemFont(ofSize: 11)) + 12, (r.width * 0.35).rounded())
                text(b.name, .monospacedSystemFont(ofSize: 11.5, weight: .medium), th.foreground, x: r.minX + 30, y: r.minY + 8, width: r.width - 40 - tagW)
                if !tag.isEmpty {
                    text(tag, .systemFont(ofSize: 11), current ? th.green : th.dimText, x: r.maxX - tagW - 4, y: r.minY + 8, width: tagW, align: .right)
                }
                if !current {
                    hit(r, id) { [weak m] in
                        guard let m else { return }
                        if b.inRepo { m.checkout(branch: b.name) }
                        else if let u = b.url.flatMap(URL.init(string:)) { NSWorkspace.shared.open(u) }
                    }
                }
                y += 34
            }
        }
        // Pull requests that mention it, in the tab's repository.
        let prs = m.prs(for: i.key)
        if !prs.isEmpty {
            y += 10
            label("Pull requests", x: pad, y: y, width: w)
            y += 20
            for p in prs {
                let r = NSRect(x: pad, y: y, width: w, height: 30)
                fill(r, hover == "ipr.\(p.id)" ? th.foreground.withAlphaComponent(0.08) : th.surface.withAlphaComponent(0.6), radius: PageCanvas.radius)
                symbol("arrow.triangle.pull", NSRect(x: r.minX + 8, y: r.minY, width: 16, height: 30), th.accent, size: 11)
                text("#\(p.id) \(p.title)", .systemFont(ofSize: 12, weight: .medium), th.foreground, x: r.minX + 30, y: r.minY + 7, width: r.width - 90)
                if p.approvals > 0 { pill("✓ \(p.approvals)", x: r.maxX - 8, y: r.minY + 6, color: th.green, rightAligned: true) }
                hit(r, "ipr.\(p.id)") { [weak page] in
                    page?.section = .prs
                    page?.openPR(p.id)
                }
                y += 34
            }
        }

        // Description.
        y += 14
        label("Description", x: pad, y: y, width: w)
        button("Edit", id: "editdesc", x: bounds.width - pad, y: y - 5, height: 22, style: .plain, rightAligned: true) { [weak page] in
            guard let page else { return }
            AtlassianSheet.editDescription(i, on: page)
        }
        y += 22
        if i.description.isEmpty {
            y += paragraph("No description.", .systemFont(ofSize: 12.5), th.dimText, x: pad, y: y, width: w)
        } else {
            y += blocks(i.description, x: pad, y: y, width: w)
        }

        // Comments.
        y += 24
        line(y, from: pad, to: pad + w)
        y += 14
        label("Comments · \(m.comments.count)", x: pad, y: y, width: w)
        y += 24
        let add = NSRect(x: pad, y: y, width: w, height: 34)
        fill(add, th.background.withAlphaComponent(hover == "addcomment" ? 0.9 : 0.6), radius: PageCanvas.radius)
        stroke(add, hover == "addcomment" ? th.accent.withAlphaComponent(0.6) : th.border, radius: PageCanvas.radius)
        if let me = m.me { avatar(me.avatarURL.flatMap(URL.init(string:)), NSRect(x: add.minX + 6, y: add.minY + 6, width: 22, height: 22), initials: PageCanvas.initials(me.displayName)) }
        text("Add a comment…", .systemFont(ofSize: 12.5), th.dimText, x: add.minX + 36, y: add.minY + 9, width: w - 50)
        hit(add, "addcomment") { [weak page] in
            guard let page else { return }
            AtlassianSheet.comment(i, on: page)
        }
        y += 48
        for c in m.comments.reversed() {
            let av = NSRect(x: pad, y: y, width: 26, height: 26)
            avatar(c.author?.avatarURL.flatMap(URL.init(string:)), av, initials: PageCanvas.initials(c.author?.displayName ?? "?"))
            let nf = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
            let name = c.author?.displayName ?? "Someone"
            let nw = PageCanvas.textWidth(name, nf)
            text(name, nf, th.foreground, x: pad + 36, y: y + 1, width: nw + 2)
            if let d = c.created { text(PageCanvas.ago(d), .systemFont(ofSize: 11), th.dimText, x: pad + 36 + nw + 8, y: y + 2, width: 100) }
            y += 22
            y += blocks(c.body, x: pad + 36, y: y, width: w - 36, size: 12.5) + 18
        }
        return y + 30
    }

    private func showTypes() {
        guard let page, let i = page.model.detail else { return }
        let m = page.model
        let rect = typeRect
        ThemedDropdown.show([.header("Loading…")], under: self, rect: rect, minWidth: 200, searchable: false)
        m.api.issueTypes(i.projectKey) { [weak self] r in
            guard let self, m.detail?.key == i.key else { return }
            // A sub-task stays one (and a ticket doesn't become one) here: that needs a parent, which Jira's move does.
            let types = ((try? r.get()) ?? []).filter { $0.isSubtask == i.isSubtask }
            let items: [DropdownItem] = types.isEmpty ? [.header("No other types")] : types.map { t in
                .item(t.name, checked: t.name.caseInsensitiveCompare(i.type) == .orderedSame) { [weak m] in
                    if t.name.caseInsensitiveCompare(i.type) != .orderedSame { m?.setType(i.key, t) }
                }
            }
            ThemedDropdown.show(items, under: self, rect: rect, minWidth: 200, searchable: false)
        }
    }

    private func showTransitions() {
        guard let page, let i = page.model.detail else { return }
        let m = page.model
        var items: [DropdownItem] = m.transitions.map { t in
            DropdownItem.item(t.name == t.to.name ? t.to.name : "\(t.name) → \(t.to.name)", checked: t.to.id == i.status.id, symbol: "circle.fill",
                              color: IssueGlyph.statusColor(t.to, th)) { [weak m] in m?.transition(i.key, t) }
        }
        if items.isEmpty { items = [.header(m.loadingDetail ? "Loading…" : "No transitions from \(i.status.name)")] }
        ThemedDropdown.show(items, under: self, rect: statusRect, minWidth: 240, placeholder: "Move to", searchable: items.count > 8)
    }

    private func showAssignees() {
        guard let page, let i = page.model.detail else { return }
        let m = page.model
        var items: [DropdownItem] = []
        if let me = m.me { items.append(.item("Assign to me", checked: i.assignee?.accountId == me.accountId, symbol: "person.fill") { [weak m] in m?.assign(i.key, to: me) }) }
        items.append(.item("Unassigned", checked: i.assignee == nil, symbol: "person.crop.circle.badge.xmark") { [weak m] in m?.assign(i.key, to: nil) })
        // People on the board, then whoever Jira finds as you type.
        var seen = Set([m.me?.accountId ?? ""])
        let people = (m.issues.compactMap(\.assignee) + m.issues.compactMap(\.reporter)).filter { seen.insert($0.accountId).inserted }
        if !people.isEmpty { items.append(.separator) }
        for u in people.sorted(by: { $0.displayName < $1.displayName }) {
            items.append(.item(u.displayName, checked: i.assignee?.accountId == u.accountId, symbol: "person") { [weak m] in m?.assign(i.key, to: u) })
        }
        ThemedDropdown.show(items, under: self, rect: assigneeRect, minWidth: 260, placeholder: "Assign to")
    }

    private func showPriorities() {
        guard let page, let i = page.model.detail else { return }
        let m = page.model
        m.api.priorities { [weak self, weak m] r in
            guard let self, case .success(let names) = r else { return }
            let items = names.map { n in DropdownItem.item(n, checked: n == i.priority, symbol: "flag.fill", color: IssueGlyph.priorityColor(n, self.th)) { m?.setPriority(i.key, n) } }
            ThemedDropdown.show(items, under: self, rect: self.priorityRect, minWidth: 200, searchable: false)
        }
    }
}

// MARK: A pull request

final class PRCanvas: PageCanvas {
    weak var page: AtlassianPageView?
    var tab = "files"
    static let lineH: CGFloat = 18
    static let mono = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)

    override func render() -> CGFloat {
        guard let page, let p = page.model.pr else { return 0 }
        let m = page.model
        let pad: CGFloat = 14
        let w = bounds.width - pad * 2
        var y: CGFloat = 16
        button("Pull requests", id: "back", x: pad - 8, y: y, height: 26, symbol: "chevron.left", style: .plain) { [weak page] in page?.closePR() }
        if m.loadingPR { symbol("hourglass", NSRect(x: bounds.width - pad - 18, y: y + 4, width: 18, height: 18), th.dimText, size: 11) }
        y += 36
        // Title, state.
        let stateColor: NSColor = p.state == "MERGED" ? th.ansi[5] : p.state == "DECLINED" ? th.red : th.green
        let sw = pill(p.state, x: pad, y: y + 3, height: 20, color: stateColor, filled: true)
        y += paragraph(p.title, .systemFont(ofSize: 19, weight: .bold), th.foreground, x: pad + sw + 10, y: y, width: w - sw - 10) + 6
        var sx = pad
        if let a = p.author {
            avatar(a.avatarURL.flatMap(URL.init(string:)), NSRect(x: sx, y: y, width: 20, height: 20), initials: PageCanvas.initials(a.displayName))
            sx += 26
            sx += text(a.displayName, .systemFont(ofSize: 12, weight: .semibold), th.foreground, x: sx, y: y + 2, width: 200) + 8
        }
        let mono = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .medium)
        sx += pill(p.source, x: sx, y: y + 1, height: 19, color: th.accent, font: mono) + 4
        symbol("arrow.right", NSRect(x: sx, y: y, width: 16, height: 20), th.dimText, size: 10)
        sx += 20
        sx += pill(p.destination, x: sx, y: y + 1, height: 19, color: th.foreground, font: mono) + 8
        text("#\(p.id)" + (p.updated.map { " · updated " + PageCanvas.ago($0) } ?? ""), .systemFont(ofSize: 11.5), th.dimText, x: sx, y: y + 3, width: max(40, bounds.width - pad - sx))
        y += 34

        // Actions.
        let mine = p.author?.uuid == m.bitbucketMe?.uuid
        let approved = p.approved(by: m.bitbucketMe?.uuid)
        let open = p.state == "OPEN"
        var bx = pad
        if open {
            if !mine {
                bx += button(approved ? "Approved" : "Approve", id: "approve", x: bx, y: y, height: 30, symbol: approved ? "checkmark.circle" : "checkmark",
                             style: approved ? .secondary : .primary) { [weak m] in m?.approve(!approved) } + 6
                let asked = p.participants.contains { $0.user.uuid == m.bitbucketMe?.uuid && $0.state == "changes_requested" }
                bx += button(asked ? "Changes requested" : "Request changes", id: "changes", x: bx, y: y, height: 30, symbol: "exclamationmark.bubble", style: .secondary) { [weak m] in
                    m?.requestChanges(!asked)
                } + 6
            }
            bx += button("Merge", id: "merge", x: bx, y: y, height: 30, symbol: "arrow.triangle.merge", style: mine ? .primary : .secondary) { [weak page] in
                guard let page else { return }
                AtlassianSheet.merge(p, on: page)
            } + 6
        }
        if m.branch != p.source {
            bx += button("Check out", id: "checkout", x: bx, y: y, height: 30, symbol: "arrow.down.to.line", style: .secondary) { [weak m] in m?.checkout(p) } + 6
        }
        bx += button("Ask Claude to review", id: "review", x: bx, y: y, height: 30, symbol: "sparkles", style: .secondary) { [weak page] in
            guard let page else { return }
            let prompt = "Review Bitbucket pull request #\(p.id) \"\(p.title)\" (\(p.source) → \(p.destination)) in this repository. "
                + "Run `git fetch origin \(p.source) \(p.destination)` and read `git diff origin/\(p.destination)...origin/\(p.source)`; "
                + "point out bugs, risky changes and anything missing, file by file.\n\n" + (p.description.isEmpty ? "" : "Its description:\n\(p.description)\n\n")
            ExtensionChat.ask(prompt, from: page, submit: false)
        } + 6
        if let u = p.url {
            bx += button("", id: "web", x: bx, y: y, height: 30, symbol: "arrow.up.right.square", style: .secondary) {
                if let url = URL(string: u) { NSWorkspace.shared.open(url) }
            } + 6
        }
        if open && mine {
            button("Decline", id: "decline", x: bounds.width - pad, y: y, height: 30, style: .danger, rightAligned: true) { [weak page] in
                guard let page else { return }
                AtlassianSheet.confirm("Decline #\(p.id)?", detail: "Bitbucket closes the pull request without merging it.", action: "Decline", danger: true, on: page) { done in
                    page.model.decline()
                    done(nil)
                }
            }
        }
        y += 46

        // Reviewers, builds, ticket.
        let reviewers = p.participants.filter(\.isReviewer)
        if !reviewers.isEmpty || !p.reviewers.isEmpty {
            label("Reviewers", x: pad, y: y, width: 200)
            var rx = pad + 90
            let list: [(BitbucketUser, String?)] = reviewers.isEmpty ? p.reviewers.map { ($0, nil) } : reviewers.map { ($0.user, $0.approved ? "approved" : $0.state) }
            for (u, state) in list {
                let ar = NSRect(x: rx, y: y - 4, width: 22, height: 22)
                avatar(u.avatarURL.flatMap(URL.init(string:)), ar, initials: PageCanvas.initials(u.displayName))
                if state == "approved" { stroke(ar.insetBy(dx: -1.5, dy: -1.5), th.green, radius: 12, width: 2) }
                if state == "changes_requested" { stroke(ar.insetBy(dx: -1.5, dy: -1.5), th.yellow, radius: 12, width: 2) }
                rx += 30
                rx += text(u.displayName, .systemFont(ofSize: 12), th.foreground, x: rx, y: y - 1, width: 160) + 18
                if rx > bounds.width - 200 { break }
            }
            y += 28
        }
        if !m.prBuilds.isEmpty {
            label("Builds", x: pad, y: y, width: 200)
            var rx = pad + 90
            for b in m.prBuilds {
                let c: NSColor = b.state == "SUCCESSFUL" ? th.green : b.state == "FAILED" ? th.red : b.state == "INPROGRESS" ? th.yellow : th.dimText
                let sym = b.state == "SUCCESSFUL" ? "checkmark.circle" : b.state == "FAILED" ? "xmark.octagon" : b.state == "INPROGRESS" ? "clock" : "stop.circle"
                symbol(sym, NSRect(x: rx, y: y - 3, width: 16, height: 20), c, size: 12)
                let bw = text(b.name, .systemFont(ofSize: 12), th.foreground, x: rx + 20, y: y - 1, width: 220)
                if let u = b.url.flatMap(URL.init(string:)) { hit(NSRect(x: rx, y: y - 4, width: bw + 24, height: 22), "build." + b.name) { NSWorkspace.shared.open(u) } }
                rx += bw + 36
            }
            y += 28
        }
        if let key = p.issueKey {
            label("Ticket", x: pad, y: y, width: 200)
            let kw = pill(key, x: pad + 90, y: y - 3, height: 20, color: th.accent, font: .monospacedSystemFont(ofSize: 11, weight: .bold))
            hit(NSRect(x: pad + 90, y: y - 3, width: kw, height: 20), "ticket") { [weak page] in page?.openIssue(key) }
            y += 28
        }

        // Description.
        if !p.description.isEmpty {
            y += 6
            let r = NSRect(x: pad, y: y, width: w, height: 0)
            let blocks = ADF.blocks(ADF.document(p.description))
            let h = self.blocksHeight(blocks, width: w - 32)
            fill(NSRect(x: r.minX, y: y, width: w, height: h + 28), th.surface.withAlphaComponent(0.55), radius: PageCanvas.radius)
            self.blocks(blocks, x: pad + 16, y: y + 14, width: w - 32)
            y += h + 28 + 16
        }

        // Files | Comments.
        y += 4
        let general = m.prComments.filter { $0.path == nil }
        var tx = pad
        for (id, title) in [("files", "Files changed · \(m.prFiles.count)"), ("comments", "Comments · \(m.prComments.count)")] {
            let font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
            let tw = PageCanvas.textWidth(title, font) + 20
            let r = NSRect(x: tx, y: y, width: tw, height: 30)
            text(title, font, tab == id ? th.foreground : th.dimText, x: r.minX, y: r.minY + 7, width: tw, align: .center)
            if tab == id { fill(NSRect(x: r.minX + 6, y: r.maxY - 2, width: tw - 12, height: 2), th.accent, radius: 1) }
            hit(r, "tab." + id) { [weak self] in self?.tab = id; page.relayout() }
            tx += tw + 8
        }
        y += 32
        line(y, from: pad, to: pad + w)
        y += 14
        if tab == "files" {
            y = renderFiles(m, x: pad, y: y, width: w)
        } else {
            y = renderComments(m, general: general, x: pad, y: y, width: w, pr: p)
        }
        return y + 40
    }

    private func blocksHeight(_ b: [DocBlock], width: CGFloat) -> CGFloat {
        // A measuring pass draws nothing: the same layout code, so the box fits what's drawn into it.
        let was = measuringFlag
        measuringFlag = true
        let h = blocks(b, x: 0, y: 0, width: width)
        measuringFlag = was
        return h
    }

    /// Lets `blocksHeight` measure without drawing: `visible` answers false while it's set.
    private var measuringFlag = false
    override func visible(_ r: NSRect) -> Bool { !measuringFlag && super.visible(r) }

    private func renderFiles(_ m: AtlassianModel, x: CGFloat, y y0: CGFloat, width: CGFloat) -> CGFloat {
        var y = y0
        if m.prFiles.isEmpty {
            return y + paragraph(m.loadingPR ? "Loading the diff…" : "No changes.", .systemFont(ofSize: 12.5), th.dimText, x: x, y: y, width: width) + 10
        }
        let total = (m.prFiles.map(\.added).reduce(0, +), m.prFiles.map(\.removed).reduce(0, +))
        text("\(m.prFiles.count) files · +\(total.0) −\(total.1)", .systemFont(ofSize: 12), th.dimText, x: x, y: y, width: width)
        y += 24
        let inline = Dictionary(grouping: m.prComments.filter { $0.path != nil }, by: { $0.path! })
        for f in m.prFiles {
            let collapsed = m.collapsedFiles.contains(f.path)
            let hr = NSRect(x: x, y: y, width: width, height: 32)
            fill(hr, th.surface.mix(th.foreground, hover == "file." + f.path ? 0.06 : 0.02), radius: PageCanvas.radius)
            stroke(hr, th.border, radius: PageCanvas.radius)
            symbol(collapsed ? "chevron.right" : "chevron.down", NSRect(x: hr.minX + 8, y: hr.minY, width: 14, height: 32), th.dimText, size: 9, weight: .bold)
            let pathText = f.oldPath != nil && f.newPath != nil && f.oldPath != f.newPath ? "\(f.oldPath!) → \(f.newPath!)" : f.path
            text(pathText, .monospacedSystemFont(ofSize: 12, weight: .medium), th.foreground, x: hr.minX + 28, y: hr.minY + 8, width: width - 150)
            let stat = "+\(f.added) −\(f.removed)"
            let font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
            let sw = PageCanvas.textWidth(stat, font)
            text("+\(f.added)", font, th.green, x: hr.maxX - 12 - sw, y: hr.minY + 9, width: sw)
            text("−\(f.removed)", font, th.red, x: hr.maxX - 12 - PageCanvas.textWidth("−\(f.removed)", font), y: hr.minY + 9, width: sw)
            if let n = inline[f.path]?.count, n > 0 {
                symbol("bubble.left.fill", NSRect(x: hr.maxX - sw - 48, y: hr.minY, width: 16, height: 32), th.accent, size: 10)
                text("\(n)", .systemFont(ofSize: 11, weight: .semibold), th.accent, x: hr.maxX - sw - 30, y: hr.minY + 9, width: 20)
            }
            hit(hr, "file." + f.path) { [weak page] in
                guard let page else { return }
                if collapsed { page.model.collapsedFiles.remove(f.path) } else { page.model.collapsedFiles.insert(f.path) }
                page.relayout()
            }
            y += 34
            if collapsed { y += 8; continue }
            if f.isBinary {
                y += paragraph("Binary file.", .systemFont(ofSize: 12), th.dimText, x: x + 12, y: y + 4, width: width) + 14
                continue
            }
            // Lines: old and new numbers, then the text on its color.
            let numW: CGFloat = 40
            let comments = inline[f.path] ?? []
            for l in f.lines {
                let r = NSRect(x: x, y: y, width: width, height: Self.lineH)
                if visible(r) {
                    switch l.kind {
                    case .added: fill(r, th.green.withAlphaComponent(th.isDark ? 0.16 : 0.14))
                    case .removed: fill(r, th.red.withAlphaComponent(th.isDark ? 0.16 : 0.12))
                    case .hunk: fill(r, th.accent.withAlphaComponent(0.08))
                    default: break
                    }
                    if l.kind == .hunk {
                        text(l.text, Self.mono, th.dimText, x: x + numW * 2 + 10, y: y + 1, width: width - numW * 2 - 14)
                    } else {
                        if let o = l.old { text("\(o)", Self.mono, th.dimText.withAlphaComponent(0.6), x: x, y: y + 1, width: numW - 6, align: .right) }
                        if let n = l.new { text("\(n)", Self.mono, th.dimText.withAlphaComponent(0.6), x: x + numW, y: y + 1, width: numW - 6, align: .right) }
                        let mark = l.kind == .added ? "+" : l.kind == .removed ? "−" : " "
                        text(mark, Self.mono, l.kind == .added ? th.green : l.kind == .removed ? th.red : th.dimText, x: x + numW * 2, y: y + 1, width: 10)
                        text(l.text.replacingOccurrences(of: "\t", with: "    "), Self.mono, l.kind == .note ? th.dimText : th.foreground,
                             x: x + numW * 2 + 12, y: y + 1, width: width - numW * 2 - 16)
                    }
                }
                y += Self.lineH
                // Comments on this line, under it.
                if let n = l.new ?? l.old {
                    for c in comments where c.line == n && c.parent == nil && (l.kind != .removed || l.new == nil) {
                        y = inlineComment(c, replies: m.prComments.filter { $0.parent == c.id }, x: x + numW * 2 + 12, y: y + 4, width: width - numW * 2 - 24) + 6
                    }
                }
            }
            y += 16
        }
        return y
    }

    private func inlineComment(_ c: BitbucketComment, replies: [BitbucketComment], x: CGFloat, y y0: CGFloat, width: CGFloat) -> CGFloat {
        var y = y0
        let all = [c] + replies
        var h: CGFloat = 12
        for k in all { h += 20 + paragraphHeight(k.text, .systemFont(ofSize: 12), width: width - 50) + 8 }
        let box = NSRect(x: x, y: y, width: width, height: h)
        fill(box, th.surface, radius: PageCanvas.radius)
        stroke(box, th.accent.withAlphaComponent(0.4), radius: PageCanvas.radius)
        y += 8
        for k in all {
            avatar(k.user?.avatarURL.flatMap(URL.init(string:)), NSRect(x: x + 10, y: y, width: 20, height: 20), initials: PageCanvas.initials(k.user?.displayName ?? "?"))
            let nf = NSFont.systemFont(ofSize: 12, weight: .semibold)
            let nw = text(k.user?.displayName ?? "Someone", nf, th.foreground, x: x + 38, y: y + 1, width: 200)
            if let d = k.created { text(PageCanvas.ago(d), .systemFont(ofSize: 11), th.dimText, x: x + 46 + nw, y: y + 2, width: 100) }
            y += 20
            y += paragraph(k.text, .systemFont(ofSize: 12), th.foreground, x: x + 38, y: y, width: width - 50) + 8
        }
        return box.maxY
    }

    private func renderComments(_ m: AtlassianModel, general: [BitbucketComment], x: CGFloat, y y0: CGFloat, width: CGFloat, pr: BitbucketPullRequest) -> CGFloat {
        var y = y0
        let add = NSRect(x: x, y: y, width: width, height: 36)
        fill(add, th.background.withAlphaComponent(hover == "prcomment" ? 0.9 : 0.6), radius: PageCanvas.radius)
        stroke(add, hover == "prcomment" ? th.accent.withAlphaComponent(0.6) : th.border, radius: PageCanvas.radius)
        text("Add a comment…", .systemFont(ofSize: 12.5), th.dimText, x: add.minX + 14, y: add.minY + 10, width: width - 30)
        hit(add, "prcomment") { [weak page] in
            guard let page else { return }
            AtlassianSheet.prComment(pr, on: page)
        }
        y += 52
        if m.prComments.isEmpty { return y + paragraph("No comments yet.", .systemFont(ofSize: 12.5), th.dimText, x: x, y: y, width: width) }
        // Top-level comments, newest last, each with its replies; inline ones say where they are.
        for c in m.prComments where c.parent == nil {
            if let path = c.path {
                text("\(path)" + (c.line.map { ":\($0)" } ?? ""), .monospacedSystemFont(ofSize: 11, weight: .medium), th.accent, x: x, y: y, width: width)
                y += 18
            }
            y = inlineComment(c, replies: m.prComments.filter { $0.parent == c.id }, x: x, y: y, width: width) + 14
        }
        _ = general
        return y
    }
}

// MARK: Dev

extension PageCanvas {
    /// Dev aid: runs what clicking the spot `id` does (after a drawing pass, so the spots are known).
    @discardableResult
    /// Presses `id` as a click at its middle would: only if that spot is the one on top there, and the window's
    /// hit-testing brings the click to this view (nothing covering it).
    func devPress(_ id: String) -> Bool {
        display()
        guard var h = hits.last(where: { $0.id == id }) else { return false }
        // Scrolled to first, as someone would.
        if !visibleRect.contains(h.rect), scrollToVisible(h.rect) {
            display()
            guard let again = hits.last(where: { $0.id == id }) else { return false }
            h = again
        }
        let p = NSPoint(x: h.rect.midX, y: h.rect.midY)
        func say(_ s: String) { FileHandle.standardError.write("atlassian: press \(id) blocked: \(s)\n".data(using: .utf8)!) }
        if let top = hits.last(where: { $0.rect.contains(p) }), top.id != id { say("spot \(top.id) is on top"); return true }
        if let root = window?.contentView?.superview ?? window?.contentView {
            let got = root.hitTest(root.convert(p, from: self))
            if got !== self { say("the click goes to \(got.map { String(describing: type(of: $0)) } ?? "nothing")"); return true }
        }
        h.action()
        return true
    }
}

/// The Atlassian page's actions for snapshot runs (DevTools), printed or acted on as the actions list says.
enum AtlassianDev {
    static func run(_ action: String, in c: TerminalWindowController) {
        func page() -> AtlassianPageView? {
            if !Extensions.isInstalled(AtlassianExtension.id) { Extensions.install(AtlassianExtension.id) }
            return Extensions.showPage(AtlassianExtension.id, in: c.activeTab)?.pageView as? AtlassianPageView
        }
        func say(_ s: String) { FileHandle.standardError.write("atlassian: \(s)\n".data(using: .utf8)!) }
        let arg = action.split(separator: ":", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
        let head = String(action.split(separator: ":").first ?? "")
        guard let p = page() else { return say("no page") }
        switch head {
        case "atlassian":
            if let s = AtlassianSection(rawValue: arg) { p.section = s }
        case "atlassian-open": p.openIssue(arg)
        case "atlassian-pr": if let id = Int(arg) { p.section = .prs; p.openPR(id) }
        case "atlassian-drag", "atlassian-drag-hold":
            let parts = arg.split(separator: ":").map(String.init)
            guard parts.count == 3, let col = Int(parts[1]), let idx = Int(parts[2]) else { return say("drag needs key:column:index") }
            p.board.display()
            p.board.devDrag(parts[0], column: col, index: idx, hold: head == "atlassian-drag-hold")
        case "atlassian-sheet":
            switch arg {
            case "start": if let i = p.model.detail { AtlassianSheet.startWork(i, on: p) }
            case "create": AtlassianSheet.createIssue(on: p)
            case "comment": if let i = p.model.detail { AtlassianSheet.comment(i, on: p) }
            case "desc": if let i = p.model.detail { AtlassianSheet.editDescription(i, on: p) }
            case "newpr": AtlassianSheet.createPR(on: p)
            case "merge": if let pr = p.model.pr { AtlassianSheet.merge(pr, on: p) }
            case "tokens": AtlassianSheet.tokens(on: p)
            default: say("no sheet \(arg)")
            }
        case "atlassian-set":
            let parts = arg.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2 { p.sheet?.devSet(parts[0], parts[1]) }
        case "atlassian-submit": p.sheet?.submit()
        case "atlassian-scroll": if let y = Double(arg) { p.setup.devScroll(CGFloat(y)) }
        case "atlassian-press":
            // The spot on whichever part of the page has it: a sheet first, then the panel, the pull request, the header.
            let canvases: [PageCanvas] = (p.sheet.map { [$0.devCanvas] } ?? []) + [p.drawer.canvas, p.prPage, p.list, p.board, p.setup.canvas] + p.subviews.compactMap { $0 as? PageCanvas }
            if !canvases.contains(where: { $0.devPress(arg) }) { say("nothing to press called \(arg); there are: \(canvases.flatMap { $0.hits.map(\.id) }.filter { !$0.hasPrefix("card.") })") }
        case "atlassian-bleed":
            // The board told of the pointer as its tracking area tells it: over each of its cards, under the ticket
            // panel or not. Its hover should follow only the uncovered ones.
            guard let w = p.window else { break }
            var out: [String] = []
            for h in p.board.hits where h.id.hasPrefix("card.") {
                let wp = p.board.convert(NSPoint(x: h.rect.midX, y: h.rect.midY), to: nil)
                guard let e = NSEvent.mouseEvent(with: .mouseMoved, location: wp, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber,
                                                 context: nil, eventNumber: 0, clickCount: 0, pressure: 0) else { continue }
                p.board.mouseMoved(with: e)
                let covered = !p.drawer.isHidden && p.drawer.frame.contains(p.convert(wp, from: nil))
                out.append("\(h.id.dropFirst(5))\(covered ? "(under panel)" : "")→\(p.board.hover ?? "-")")
            }
            say("bleed " + out.joined(separator: " "))
        case "atlassian-outside":
            // Which clicks close the ticket's panel: on the board's background, on a card, in the panel, on the header.
            func at(_ v: NSView, _ q: NSPoint) -> NSPoint { v.convert(q, to: nil) }
            var out: [String] = []
            if let card = p.board.hits.first(where: { $0.id.hasPrefix("card.") }) { out.append("card=\(p.closesPanel(clickAt: at(p.board, NSPoint(x: card.rect.midX, y: card.rect.midY))))") }
            if let last = p.board.hits.filter({ $0.id.hasPrefix("card.") }).map(\.rect).min(by: { $0.minX < $1.minX }) {
                out.append("background=\(p.closesPanel(clickAt: at(p.board, NSPoint(x: last.midX, y: p.board.visibleRect.maxY - 20))))")
            }
            out.append("panel=\(p.closesPanel(clickAt: at(p.drawer, NSPoint(x: p.drawer.bounds.midX, y: p.drawer.bounds.midY))))")
            out.append("header=\(p.closesPanel(clickAt: at(p, NSPoint(x: 30, y: 30))))")
            say("outside " + out.joined(separator: " "))
            if arg == "close", let last = p.board.hits.filter({ $0.id.hasPrefix("card.") }).map(\.rect).min(by: { $0.minX < $1.minX }) {
                let wp = at(p.board, NSPoint(x: last.midX, y: p.board.visibleRect.maxY - 20))
                if let e = NSEvent.mouseEvent(with: .leftMouseDown, location: wp, modifierFlags: [], timestamp: 0, windowNumber: p.window?.windowNumber ?? 0,
                                              context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { NSApp.sendEvent(e) }
            }
        case "atlassian-slide":
            // Where the panel is on screen right now (mid-animation, its layer's presentation), and where it's headed.
            let d = p.drawer
            let shown = d.layer?.presentation()?.frame ?? d.layer?.frame ?? .zero
            say("slide hidden=\(d.isHidden) to x=\(Int(d.frame.minX)) now x=\(Int(shown.minX)) alpha=\(String(format: "%.2f", d.layer?.presentation()?.opacity ?? Float(d.alphaValue)))")
        case "atlassian-probe":
            // What a click at points down the middle of the ticket panel would reach.
            guard let root = p.window?.contentView?.superview else { break }
            let d = p.drawer
            var out: [String] = []
            for y in stride(from: CGFloat(10), to: d.bounds.height, by: 40) {
                let w = d.convert(NSPoint(x: d.bounds.midX, y: y), to: nil)
                let v = root.hitTest(root.convert(w, from: nil))
                out.append("\(Int(y))=\(v.map { String(describing: type(of: $0)) } ?? "-")")
            }
            say("panel \(Int(d.frame.width))x\(Int(d.frame.height)) canvas=\(Int(d.canvas.frame.height)) " + out.joined(separator: " "))
        case "atlassian-print":
            say(p.devState())
            if let s = p.sheet { say(s.devState) }
        default: say("unknown \(action)")
        }
    }
}
