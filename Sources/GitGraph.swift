import AppKit

// "Show Git Graph" (top of the status bar's branch picker, or the command palette): the repository's history as
// a graph, as VS Code's Git Graph draws it. Each line of development gets a lane in its own color, with curves
// where branches split off and merge back, and branch and tag labels beside the commits. Hovering a commit shows
// a card with its author, date, full message and size, and buttons to copy its hash or message.

struct GraphCommit {
    let hash: String
    let parents: [String]
    let author: String
    let date: Date
    let subject: String
    /// Branches and tags pointing here, as `git log --format=%D` lists them ("HEAD -> main", "origin/main", "tag: v1").
    let refs: [String]

    static let limit = 2000
    /// HEAD's hash on the first line (empty in a repository without commits), then the newest commits on any branch.
    static let script = """
        printf '%s\\n' "$(git rev-parse HEAD 2>/dev/null)"
        git log --all --date-order -n \(limit) --format='%H%x1f%P%x1f%an%x1f%at%x1f%s%x1f%D%x1e'
        """

    static func parse(_ out: Data) -> (head: String, commits: [GraphCommit]) {
        let s = String(decoding: out, as: UTF8.self)
        guard let nl = s.firstIndex(of: "\n") else { return ("", []) }
        var commits: [GraphCommit] = []
        for record in s[s.index(after: nl)...].split(separator: "\u{1e}") {
            let f = record.trimmingCharacters(in: .newlines).components(separatedBy: "\u{1f}")
            guard f.count == 6 else { continue }
            commits.append(GraphCommit(hash: f[0], parents: f[1].split(separator: " ").map(String.init), author: f[2],
                                       date: Date(timeIntervalSince1970: TimeInterval(f[3]) ?? 0), subject: f[4],
                                       refs: f[5].isEmpty ? [] : f[5].components(separatedBy: ", ")))
        }
        return (String(s[..<nl]), commits)
    }
}

/// A commit's place in the graph: its lane, and the lines through its row.
struct GraphRow {
    enum Segment {
        /// A lane passing by, top to bottom.
        case through(Int)
        /// From a lane at the top into the commit (a branch ending here, or merging into it).
        case top(from: Int, to: Int)
        /// From the commit down to a parent's lane.
        case bottom(from: Int, to: Int)
    }

    let commit: GraphCommit
    let lane: Int
    let color: Int
    let segments: [(segment: Segment, color: Int)]
    /// Lanes in use across the row; the text starts after them.
    let width: Int
}

enum GraphLayout {
    /// Lanes are handed out left to right and kept until their line ends, so a line stays in one column for
    /// its whole length; a lane's color is picked when it starts and stays with it.
    static func rows(_ commits: [GraphCommit]) -> [GraphRow] {
        var lanes: [String?] = [], colors: [Int] = [], nextColor = 0
        func freeLane() -> Int {
            if let i = lanes.firstIndex(where: { $0 == nil }) { return i }
            lanes.append(nil)
            colors.append(0)
            return lanes.count - 1
        }
        var rows: [GraphRow] = []
        for c in commits {
            let before = lanes, beforeColors = colors
            let lane: Int
            if let i = lanes.firstIndex(of: c.hash) {
                lane = i
            } else {
                // A branch tip: nothing above leads here.
                lane = freeLane()
                lanes[lane] = c.hash
                colors[lane] = nextColor
                nextColor += 1
            }
            let color = colors[lane]
            var segments: [(GraphRow.Segment, Int)] = []
            for (i, h) in before.enumerated() {
                guard let h else { continue }
                if h == c.hash {
                    segments.append((.top(from: i, to: lane), beforeColors[i]))
                    if i != lane { lanes[i] = nil }
                } else {
                    segments.append((.through(i), beforeColors[i]))
                }
            }
            if let first = c.parents.first {
                lanes[lane] = first
                segments.append((.bottom(from: lane, to: lane), colors[lane]))
                for p in c.parents.dropFirst() {
                    let j: Int
                    if let k = lanes.firstIndex(of: p) {
                        j = k
                    } else {
                        j = freeLane()
                        lanes[j] = p
                        colors[j] = nextColor
                        nextColor += 1
                    }
                    segments.append((.bottom(from: lane, to: j), colors[j]))
                }
            } else {
                lanes[lane] = nil
            }
            while let last = lanes.last, last == nil {
                lanes.removeLast()
                colors.removeLast()
            }
            rows.append(GraphRow(commit: c, lane: lane, color: color, segments: segments, width: max(before.count, lanes.count, lane + 1)))
        }
        return rows
    }
}

/// The graph, plus the card shown over it while a commit is hovered.
final class GitGraphView: NSView {
    private let scroll = NSScrollView()
    private let rowsView = GraphRowsView()
    private let card = CommitCard()
    private let runner: GitRunner
    private var details: [String: CommitCard.Details] = [:]
    private var cardRow: Int?
    private var cardHovered = false
    private var pendingCard: DispatchWorkItem?

    init(runner: GitRunner) {
        self.runner = runner
        super.init(frame: .zero)
        scroll.documentView = rowsView
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        addSubview(scroll)
        card.isHidden = true
        card.onHover = { [weak self] inside in
            guard let self else { return }
            self.cardHovered = inside
            if !inside {
                self.rowsView.forgetHover()
                self.scheduleCard(nil)
            }
        }
        addSubview(card)
        // Rows under the card still see the pointer; while it's on the card, the card stays.
        rowsView.onHover = { [weak self] row in
            guard let self, !self.cardHovered else { return }
            self.scheduleCard(row)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    /// Takes focus so ⌘W and the other editor commands reach the editor around it.
    override var acceptsFirstResponder: Bool { true }

    func show(head: String, commits: [GraphCommit]) {
        rowsView.head = head
        rowsView.rows = GraphLayout.rows(commits)
        rowsView.fitSize()
        if let row = cardRow, !rowsView.rows.indices.contains(row) { hideCard() }
    }

    func applyTheme() {
        rowsView.needsDisplay = true
        card.applyTheme()
    }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        rowsView.fitSize()
    }

    // MARK: Hover card

    func devHover(_ row: Int) { showCard(row) }

    /// Shows the card for `row` after a short pause (sooner when one is up already), or hides it once the
    /// pointer has left both the row and the card.
    private func scheduleCard(_ row: Int?) {
        pendingCard?.cancel()
        if row == cardRow, row != nil { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if let row { self.showCard(row) } else if !self.cardHovered { self.hideCard() }
        }
        pendingCard = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (row == nil ? 0.25 : card.isHidden ? 0.4 : 0.12), execute: work)
    }

    private func hideCard() {
        card.isHidden = true
        cardRow = nil
        rowsView.hovered = nil
    }

    private func showCard(_ row: Int) {
        guard rowsView.rows.indices.contains(row) else { return }
        let commit = rowsView.rows[row].commit
        cardRow = row
        rowsView.hovered = row
        card.set(commit, details: details[commit.hash])
        placeCard(row)
        card.isHidden = false
        guard details[commit.hash] == nil else { return }
        // The full message, and the size of the change (against the first parent, for a merge).
        let q = shellQuote(commit.hash)
        runner.run("git show --no-patch --format=%B%x00 \(q); git show --diff-merges=first-parent --shortstat --format= \(q)") { [weak self] _, out, _ in
            guard let self else { return }
            let parts = String(decoding: out, as: UTF8.self).components(separatedBy: "\0")
            let info = CommitCard.Details(message: parts[0].trimmingCharacters(in: .whitespacesAndNewlines),
                                          stats: parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : "")
            self.details[commit.hash] = info
            if self.cardRow == row {
                self.card.set(commit, details: info)
                self.placeCard(row)
            }
        }
    }

    /// Just below the row, beside the graph, kept inside the view (above the row when there's no room below).
    private func placeCard(_ row: Int) {
        let size = card.fittingSize(width: min(460, bounds.width - 24))
        let rowRect = convert(rowsView.rect(ofRow: row), from: rowsView)
        let x = min(max(12, rowsView.textX(row) + 24), bounds.width - size.width - 12)
        var y = rowRect.maxY + 2
        if y + size.height > bounds.height - 8 { y = max(8, rowRect.minY - size.height - 2) }
        card.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
    }
}

final class GraphRowsView: NSView {
    var rows: [GraphRow] = [] { didSet { needsDisplay = true } }
    var head = ""
    var hovered: Int? { didSet { if hovered != oldValue { needsDisplay = true } } }
    var onHover: ((Int?) -> Void)?

    static let rowHeight: CGFloat = 24
    private static let laneWidth: CGFloat = 14
    private static let left: CGFloat = 16
    private static let palette: [NSColor] = ["#4C9DF3", "#E5B62C", "#E0457B", "#3FB5A6", "#B06CF0", "#E8853A", "#6CC04A", "#E05555"]
        .map { NSColor(hex: $0) }
    private let font = NSFont.systemFont(ofSize: 12.5)
    private let boldFont = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
    private let pillFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    private var lastHover: Int?

    override var isFlipped: Bool { true }

    func fitSize() {
        let size = NSSize(width: enclosingScrollView?.contentSize.width ?? 0, height: CGFloat(rows.count) * Self.rowHeight + 8)
        if size != frame.size { setFrameSize(size) }
        needsDisplay = true
    }

    static func color(_ i: Int) -> NSColor { palette[i % palette.count] }
    private func x(_ lane: Int) -> CGFloat { Self.left + CGFloat(lane) * Self.laneWidth }
    func rect(ofRow r: Int) -> NSRect { NSRect(x: 0, y: CGFloat(r) * Self.rowHeight, width: bounds.width, height: Self.rowHeight) }
    func textX(_ r: Int) -> CGFloat { x(rows[r].width) + 2 }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === self }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    override func mouseMoved(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        let r = Int(p.y / Self.rowHeight)
        let row = rows.indices.contains(r) ? r : nil
        if row != lastHover {
            lastHover = row
            onHover?(row)
        }
    }

    override func mouseExited(with e: NSEvent) {
        lastHover = nil
        onHover?(nil)
    }

    /// The next move reports its row even if it's the one last reported.
    func forgetHover() { lastHover = nil }

    override func draw(_ dirtyRect: NSRect) {
        guard !rows.isEmpty else { return }
        let th = Config.shared.theme
        let h = Self.rowHeight
        let first = max(0, Int(dirtyRect.minY / h))
        let last = min(rows.count - 1, Int(dirtyRect.maxY / h))
        guard first <= last else { return }
        for r in first...last {
            let row = rows[r]
            let y = CGFloat(r) * h
            let mid = y + h / 2
            let isHead = row.commit.hash == head
            if r == hovered || isHead {
                th.foreground.withAlphaComponent(r == hovered ? 0.07 : 0.04).setFill()
                NSRect(x: 0, y: y, width: bounds.width, height: h).fill()
            }
            // The lines, then the commit's dot over them.
            for (segment, color) in row.segments {
                let path = NSBezierPath()
                path.lineWidth = 1.6
                path.lineCapStyle = .round
                switch segment {
                case .through(let i):
                    path.move(to: NSPoint(x: x(i), y: y))
                    path.line(to: NSPoint(x: x(i), y: y + h))
                case .top(let from, let to):
                    path.move(to: NSPoint(x: x(from), y: y))
                    if from == to {
                        path.line(to: NSPoint(x: x(to), y: mid))
                    } else {
                        path.curve(to: NSPoint(x: x(to), y: mid), controlPoint1: NSPoint(x: x(from), y: mid), controlPoint2: NSPoint(x: x(from), y: mid))
                    }
                case .bottom(let from, let to):
                    path.move(to: NSPoint(x: x(from), y: mid))
                    if from == to {
                        path.line(to: NSPoint(x: x(to), y: y + h))
                    } else {
                        path.curve(to: NSPoint(x: x(to), y: y + h), controlPoint1: NSPoint(x: x(to), y: mid), controlPoint2: NSPoint(x: x(to), y: mid))
                    }
                }
                Self.color(color).setStroke()
                path.stroke()
            }
            drawNode(row, at: NSPoint(x: x(row.lane), y: mid), isHead: isHead, th: th)
            drawText(row, row: r, y: y, isHead: isHead, th: th)
        }
    }

    /// A dot for a commit, a ringed dot for a merge, a ring for HEAD (as VS Code marks them).
    private func drawNode(_ row: GraphRow, at c: NSPoint, isHead: Bool, th: Theme) {
        let color = Self.color(row.color)
        func circle(_ r: CGFloat) -> NSBezierPath { NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)) }
        if isHead || row.commit.parents.count > 1 {
            let r: CGFloat = isHead ? 6 : 4.5
            th.background.setFill()
            circle(r).fill()
            color.setStroke()
            let ring = circle(r)
            ring.lineWidth = isHead ? 2.2 : 1.6
            ring.stroke()
            if !isHead {
                color.setFill()
                circle(1.8).fill()
            }
        } else {
            color.setFill()
            circle(4).fill()
        }
    }

    /// The subject, then branch and tag labels, then the author; the subject gives way when space runs short.
    private func drawText(_ row: GraphRow, row r: Int, y: CGFloat, isHead: Bool, th: Theme) {
        let x0 = textX(r)
        let right = bounds.width - 10
        let pills = Self.labels(row.commit.refs)
        let pillWidths = pills.map { pillWidth($0) }
        let pillsW = pillWidths.reduce(0) { $0 + $1 + 5 }
        let authorAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: th.dimText]
        let authorW = (row.commit.author as NSString).size(withAttributes: authorAttrs).width
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        let subjectAttrs: [NSAttributedString.Key: Any] = [.font: isHead ? boldFont : font, .paragraphStyle: para,
                                                           .foregroundColor: th.foreground.withAlphaComponent(0.92)]
        let subjectW = (row.commit.subject as NSString).size(withAttributes: subjectAttrs).width
        let showAuthor = right - x0 - pillsW - authorW - 8 > 80
        let room = right - x0 - pillsW - (showAuthor ? authorW + 8 : 0)
        let w = max(0, min(subjectW + 1, room))
        let textY = y + (Self.rowHeight - ceil(font.ascender - font.descender)) / 2
        (row.commit.subject as NSString).draw(in: NSRect(x: x0, y: textY, width: w, height: Self.rowHeight), withAttributes: subjectAttrs)
        var x = x0 + w + 6
        for (i, label) in pills.enumerated() where x + pillWidths[i] < right {
            drawPill(label, x: x, midY: y + Self.rowHeight / 2, color: Self.color(row.color), th: th)
            x += pillWidths[i] + 5
        }
        if showAuthor {
            (row.commit.author as NSString).draw(at: NSPoint(x: x + 2, y: textY), withAttributes: authorAttrs)
        }
    }

    // MARK: Branch and tag labels

    struct Label {
        enum Kind { case branch, remote, tag, head }
        let kind: Kind
        let name: String
        /// The current branch.
        var current = false
        /// A branch whose remote twin (origin/<name>) points here too: shown as a cloud on the branch.
        var onRemote = false
    }

    static func labels(_ refs: [String]) -> [Label] {
        var out: [Label] = []
        for ref in refs {
            if ref.hasPrefix("HEAD -> ") {
                out.append(Label(kind: .branch, name: String(ref.dropFirst(8)), current: true))
            } else if ref == "HEAD" {
                out.append(Label(kind: .head, name: "HEAD"))
            } else if ref.hasPrefix("tag: ") {
                out.append(Label(kind: .tag, name: String(ref.dropFirst(5))))
            } else if ref.contains("/") {
                out.append(Label(kind: .remote, name: ref))
            } else {
                out.append(Label(kind: .branch, name: ref))
            }
        }
        for (i, l) in out.enumerated() where l.kind == .branch {
            if let r = out.firstIndex(where: { $0.kind == .remote && $0.name.split(separator: "/", maxSplits: 1).last.map(String.init) == l.name }) {
                out[i].onRemote = true
                out[r] = Label(kind: .remote, name: "")
            }
        }
        out.removeAll { $0.kind == .remote && $0.name.hasSuffix("/HEAD") || $0.name.isEmpty }
        // Current branch first, then branches, tags, and remotes last.
        let order: [Label.Kind: Int] = [.head: 0, .branch: 1, .tag: 2, .remote: 3]
        return out.enumerated().sorted { a, b in
            (a.element.current ? -1 : order[a.element.kind]!, a.offset) < (b.element.current ? -1 : order[b.element.kind]!, b.offset)
        }.map(\.element)
    }

    private func pillSymbol(_ l: Label) -> String? {
        switch l.kind {
        case .branch: return l.current ? "scope" : nil
        case .remote: return "cloud"
        case .tag: return "tag"
        case .head: return nil
        }
    }

    private func pillWidth(_ l: Label) -> CGFloat {
        var w = (l.name as NSString).size(withAttributes: [.font: pillFont]).width + 14
        if pillSymbol(l) != nil { w += 15 }
        if l.onRemote { w += 17 }
        return ceil(w)
    }

    private func drawPill(_ l: Label, x: CGFloat, midY: CGFloat, color: NSColor, th: Theme) {
        let r = NSRect(x: x, y: midY - 9, width: pillWidth(l), height: 18)
        let solid = l.kind == .branch || l.kind == .head
        let path = NSBezierPath(roundedRect: r, xRadius: 9, yRadius: 9)
        if solid {
            color.setFill()
            path.fill()
        } else {
            color.withAlphaComponent(0.14).setFill()
            path.fill()
            color.withAlphaComponent(0.8).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        let ink: NSColor = solid ? .white : color
        var tx = r.minX + 7
        if let name = pillSymbol(l), let img = symbol(name, ink) {
            img.draw(in: NSRect(x: tx, y: midY - img.size.height / 2, width: img.size.width, height: img.size.height))
            tx += 15
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: pillFont, .foregroundColor: ink]
        (l.name as NSString).draw(at: NSPoint(x: tx, y: midY - ceil(pillFont.ascender - pillFont.descender) / 2), withAttributes: attrs)
        if l.onRemote, let img = symbol("cloud.fill", ink) {
            let cx = r.maxX - 7 - img.size.width
            img.draw(in: NSRect(x: cx, y: midY - img.size.height / 2, width: img.size.width, height: img.size.height))
        }
    }

    private func symbol(_ name: String, _ color: NSColor) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9.5, weight: .semibold).applying(.init(paletteColors: [color])))
    }
}

/// The hover card: who and when, the full message, how much changed, and copy buttons for the hash and message.
final class CommitCard: NSView {
    struct Details {
        let message: String
        /// git's summary, e.g. "2 files changed, 122 insertions(+), 105 deletions(-)"; empty for no changes.
        let stats: String
    }

    var onHover: ((Bool) -> Void)?
    private let byline = NSTextField(labelWithString: "")
    private let message = NSTextField(wrappingLabelWithString: "")
    private let stats = NSTextField(labelWithString: "")
    private let copyHash = CardButton()
    private let copyMessage = CardButton()
    private var commit: GraphCommit?
    private var details: Details?
    private static let pad: CGFloat = 12

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        shadow = NSShadow()
        layer?.shadowOpacity = 0.35
        layer?.shadowRadius = 10
        layer?.shadowOffset = CGSize(width: 0, height: -3)
        message.maximumNumberOfLines = 12
        message.lineBreakMode = .byWordWrapping
        message.isSelectable = true
        for v in [byline, message, stats, copyHash, copyMessage] as [NSView] { addSubview(v) }
        copyHash.action = { [weak self] in
            guard let self, let c = self.commit else { return }
            self.copy(c.hash, button: self.copyHash)
        }
        copyMessage.action = { [weak self] in
            guard let self, let c = self.commit else { return }
            self.copy(self.details?.message ?? c.subject, button: self.copyMessage)
        }
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func applyTheme() {
        let th = Config.shared.theme
        layer?.backgroundColor = th.background.mix(th.isDark ? .white : .black, th.isDark ? 0.06 : 0.02).cgColor
        layer?.borderColor = th.border.cgColor
        message.textColor = th.foreground
        message.font = .systemFont(ofSize: 12.5)
        if let commit { set(commit, details: details) }
        needsDisplay = true
    }

    func set(_ c: GraphCommit, details d: Details?) {
        commit = c
        details = d
        let th = Config.shared.theme
        let line = NSMutableAttributedString()
        func icon(_ name: String) {
            let a = NSTextAttachment()
            a.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .regular).applying(.init(paletteColors: [th.dimText])))
            line.append(NSAttributedString(attachment: a))
            line.append(NSAttributedString(string: " "))
        }
        icon("person.crop.circle")
        line.append(NSAttributedString(string: c.author, attributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .semibold), .foregroundColor: th.foreground]))
        line.append(NSAttributedString(string: ",  "))
        icon("clock.arrow.circlepath")
        let when = "\(Self.relative.localizedString(for: c.date, relativeTo: Date())) (\(Self.absolute.string(from: c.date)))"
        line.append(NSAttributedString(string: when, attributes: [.font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: th.foreground.withAlphaComponent(0.85)]))
        byline.attributedStringValue = line
        message.stringValue = d?.message ?? c.subject
        stats.attributedStringValue = Self.styledStats(d.map { $0.stats.isEmpty ? "No changes" : $0.stats } ?? "Loading…", th)
        copyHash.set(symbol: "doc.on.doc", title: String(c.hash.prefix(8)))
        copyMessage.set(symbol: "doc.on.doc", title: "Message")
        needsLayout = true
    }

    /// Insertions in green and deletions in red, as git colors them.
    private static func styledStats(_ s: String, _ th: Theme) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (i, part) in s.components(separatedBy: ", ").enumerated() {
            if i > 0 { out.append(NSAttributedString(string: ", ", attributes: [.font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: th.foreground])) }
            let color = part.contains("insertion") ? th.green : part.contains("deletion") ? th.red : th.foreground
            out.append(NSAttributedString(string: part, attributes: [.font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: color]))
        }
        return out
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    private static let absolute: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .short
        return f
    }()

    func fittingSize(width: CGFloat) -> NSSize {
        let inner = width - Self.pad * 2
        let messageH = message.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: inner, height: 400)).height ?? 18
        return NSSize(width: width, height: Self.pad + 18 + 10 + messageH + 12 + 18 + 10 + 24 + 8)
    }

    override func layout() {
        super.layout()
        let inner = bounds.width - Self.pad * 2
        var y = Self.pad
        byline.frame = NSRect(x: Self.pad, y: y, width: inner, height: 18)
        y += 18 + 10
        let messageH = message.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: inner, height: 400)).height ?? 18
        message.frame = NSRect(x: Self.pad, y: y, width: inner, height: messageH)
        y += messageH + 12
        stats.frame = NSRect(x: Self.pad, y: y, width: inner, height: 18)
        y += 18 + 10
        copyHash.frame = NSRect(x: Self.pad - 4, y: y, width: copyHash.fittingWidth, height: 24)
        copyMessage.frame = NSRect(x: copyHash.frame.maxX + 10, y: y, width: copyMessage.fittingWidth, height: 24)
    }

    override func draw(_ dirtyRect: NSRect) {
        // Rules between the sections, as in VS Code's card.
        let th = Config.shared.theme
        th.border.setFill()
        for v in [message, stats] {
            NSRect(x: 0, y: v.frame.maxY + 5, width: bounds.width, height: 1).fill()
        }
    }

    private func copy(_ text: String, button: CardButton) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        button.flash("Copied")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === self }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

/// A link-style button on the card: an icon and a title in the accent color, "Copied" for a moment after a click.
final class CardButton: NSView {
    var action: (() -> Void)?
    private var symbolName = ""
    private var title = ""
    private var shown = ""
    private var hovering = false { didSet { needsDisplay = true } }
    private let font = NSFont.systemFont(ofSize: 12.5)

    override var isFlipped: Bool { true }

    func set(symbol: String, title: String) {
        symbolName = symbol
        if shown == self.title || shown.isEmpty { shown = title }
        self.title = title
        needsDisplay = true
    }

    var fittingWidth: CGFloat { ceil((max(title, "Copied") as NSString).size(withAttributes: [.font: font]).width) + 30 }

    func flash(_ text: String) {
        shown = text
        needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self else { return }
            self.shown = self.title
            self.needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let th = Config.shared.theme
        if hovering {
            th.accent.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        }
        let color = th.accent
        if let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular).applying(.init(paletteColors: [color]))) {
            img.draw(in: NSRect(x: 4, y: (bounds.height - img.size.height) / 2, width: img.size.width, height: img.size.height))
        }
        let h = ceil(font.ascender - font.descender)
        (shown as NSString).draw(at: NSPoint(x: 22, y: (bounds.height - h) / 2), withAttributes: [.font: font, .foregroundColor: color])
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === self }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action?() }
    }
}
