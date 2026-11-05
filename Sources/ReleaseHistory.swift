import AppKit

// Settings › System › Release History: every push to main, newest first, as a timeline in the theme's colors.
// Each is a commit on main's own line (a merge is one release, not each commit it brought in), with the version
// build.sh gives it (0.1.<commits>), its message, who and when; the one running is marked, and newer ones too.

struct Release: Equatable {
    let hash: String
    let version: Int
    let author: String
    let date: Date
    let subject: String
    /// The message's first paragraph after the subject (attribution lines left out).
    let summary: String

    /// main's line, newest first: hash, author, time, subject and body, then each one's commit count (its version).
    static func script(limit: Int = 150) -> String {
        """
        git fetch --quiet origin main 2>/dev/null
        ref=origin/main; git rev-parse -q --verify origin/main >/dev/null || ref=HEAD
        git log --first-parent -n \(limit) --format='%H%x1f%an%x1f%at%x1f%s%x1f%b%x1e' "$ref"
        printf '\\035'
        for h in $(git log --first-parent -n \(limit) --format=%H "$ref"); do printf '%s %s\\n' "$h" "$(git rev-list --count "$h")"; done
        printf '\\035'
        git remote get-url origin 2>/dev/null
        """
    }

    static func parse(_ out: Data) -> (releases: [Release], web: String?) {
        let parts = String(decoding: out, as: UTF8.self).components(separatedBy: "\u{1d}")
        var counts: [String: Int] = [:]
        if parts.count > 1 {
            for line in parts[1].split(separator: "\n") {
                let f = line.split(separator: " ")
                if f.count == 2, let n = Int(f[1]) { counts[String(f[0])] = n }
            }
        }
        var releases: [Release] = []
        for record in parts[0].components(separatedBy: "\u{1e}") {
            let f = record.trimmingCharacters(in: .newlines).components(separatedBy: "\u{1f}")
            guard f.count == 5 else { continue }
            releases.append(Release(hash: f[0], version: counts[f[0]] ?? 0, author: f[1],
                                    date: Date(timeIntervalSince1970: TimeInterval(f[2]) ?? 0), subject: f[3], summary: summary(f[4])))
        }
        let remote = parts.count > 2 ? parts[2].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return (releases, webURL(remote))
    }

    /// The body's first paragraph, joined onto one line; attribution trailers (Co-Authored-By:, Signed-off-by:) dropped.
    static func summary(_ body: String) -> String {
        let paragraphs = body.components(separatedBy: "\n\n").map { p in
            p.split(separator: "\n").filter { line in
                !line.lowercased().hasPrefix("co-authored-by:") && !line.lowercased().hasPrefix("signed-off-by:")
            }.joined(separator: " ")
        }
        return (paragraphs.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? "").trimmingCharacters(in: .whitespaces)
    }

    /// A GitHub (or similar) page for the repository, from its remote: https://host/owner/repo.
    static func webURL(_ remote: String) -> String? {
        var r = remote.trimmingCharacters(in: .whitespaces)
        guard !r.isEmpty else { return nil }
        if r.hasSuffix(".git") { r.removeLast(4) }
        if r.hasPrefix("git@"), let colon = r.firstIndex(of: ":") {
            return "https://" + r[r.index(r.startIndex, offsetBy: 4)..<colon] + "/" + r[r.index(after: colon)...]
        }
        if r.hasPrefix("https://") || r.hasPrefix("http://") {
            // Credentials in the URL aren't for showing.
            if let at = r.firstIndex(of: "@"), let scheme = r.range(of: "://"), at > scheme.upperBound {
                return String(r[..<scheme.upperBound]) + r[r.index(after: at)...]
            }
            return r
        }
        return nil
    }
}

enum ReleaseHistoryPage {
    static func build(_ v: SettingsPageView, _ ctl: SettingsWindowController) {
        v.add(SettingsPages.linkButton("‹ System") { [weak ctl] in ctl?.showReleases(false) }, height: 18, gap: 16)
        let summary = NSTextField(wrappingLabelWithString: "Reading main's history…")
        summary.font = .systemFont(ofSize: 12.5)
        summary.textColor = Config.shared.theme.dimText
        v.add(summary, height: 18, gap: 18)
        let list = ReleaseTimelineView()
        list.built = Updater.shared.built
        v.add(list, height: { [weak list] w in list?.height(forWidth: w) ?? 60 }, gap: 26)
        guard let repo = Updater.shared.repo else {
            summary.stringValue = "This copy of Solanum doesn't know which repository it came from (build it with ./build.sh)."
            return
        }
        GitRunner(dir: repo, remote: nil).run(Release.script(), timeout: 120) { [weak list, weak summary] status, out, err in
            guard let list, let summary else { return }
            let (releases, web) = Release.parse(out)
            guard !releases.isEmpty else {
                summary.stringValue = err.isEmpty ? "Couldn't read main's history." : err
                return
            }
            list.web = web
            list.releases = releases
            let built = Updater.shared.built
            let current = releases.first { built.map($0.hash.hasPrefix) ?? false }
            let newer = current.map { c in releases.prefix { $0.hash != c.hash }.count } ?? 0
            var text = "\(releases.count) releases on main"
            if let current { text += " · running 0.1.\(current.version) (\(current.hash.prefix(7)))" }
            if newer > 0 { text += " · \(newer) newer" }
            summary.stringValue = text
            // Taller now: the page lays out again.
            list.superview?.needsLayout = true
            list.window?.contentView?.needsLayout = true
        }
    }
}

/// The releases down a line: a dot for each (filled for the one running), its version, hash and badge, the subject,
/// the summary, and who and when. Clicking one opens it on the repository's site.
final class ReleaseTimelineView: NSView {
    var releases: [Release] = [] { didSet { needsDisplay = true; invalidateIntrinsicContentSize() } }
    var built: String?
    var web: String?
    private var hovered: Int? { didSet { if hovered != oldValue { needsDisplay = true } } }
    private var frames: [NSRect] = []

    private static let gutter: CGFloat = 34
    private static let pad: CGFloat = 14
    private let versionFont = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .semibold)
    private let hashFont = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
    private let subjectFont = NSFont.systemFont(ofSize: 13.5, weight: .semibold)
    private let bodyFont = NSFont.systemFont(ofSize: 12.5)
    private let metaFont = NSFont.systemFont(ofSize: 11.5)
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    override var isFlipped: Bool { true }
    private static let layout = NSLayoutManager()

    private var runningIndex: Int? { built.flatMap { b in releases.firstIndex { $0.hash.hasPrefix(b) } } }

    private func textHeight(_ s: String, _ font: NSFont, width: CGFloat, lines: Int) -> CGFloat {
        guard !s.isEmpty else { return 0 }
        let h = (s as NSString).boundingRect(with: NSSize(width: width, height: 10_000), options: [.usesLineFragmentOrigin],
                                             attributes: [.font: font]).height
        return min(ceil(h), ceil(Self.layout.defaultLineHeight(for: font) * CGFloat(lines)))
    }

    /// Each entry's card: the header line, the subject (up to 2 lines), the summary (up to 3), the byline.
    private func layoutEntries(width: CGFloat) -> [NSRect] {
        var y: CGFloat = 0
        let textW = max(100, width - Self.gutter - Self.pad * 2)
        return releases.map { r in
            let h = Self.pad + 18 + 6 + textHeight(r.subject, subjectFont, width: textW, lines: 2)
                + (r.summary.isEmpty ? 0 : 4 + textHeight(r.summary, bodyFont, width: textW, lines: 3)) + 8 + 15 + Self.pad
            defer { y += h + 10 }
            return NSRect(x: Self.gutter, y: y, width: width - Self.gutter, height: h)
        }
    }

    func height(forWidth w: CGFloat) -> CGFloat {
        guard !releases.isEmpty else { return 40 }
        return (layoutEntries(width: w).last?.maxY ?? 0) + 4
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === self }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate],
                                       owner: self))
    }

    private func entry(at e: NSEvent) -> Int? {
        let p = convert(e.locationInWindow, from: nil)
        return frames.firstIndex { $0.contains(p) }
    }

    override func mouseMoved(with e: NSEvent) { hovered = entry(at: e) }
    override func mouseExited(with e: NSEvent) { hovered = nil }
    override func cursorUpdate(with e: NSEvent) { (web != nil && entry(at: e) != nil ? NSCursor.pointingHand : NSCursor.arrow).set() }
    override func mouseDown(with e: NSEvent) {
        guard let i = entry(at: e), let web, let url = URL(string: "\(web)/commit/\(releases[i].hash)") else { return }
        NSWorkspace.shared.open(url)
    }

    override func draw(_ dirtyRect: NSRect) {
        let th = Config.shared.theme
        frames = layoutEntries(width: bounds.width)
        guard !releases.isEmpty else { return }
        let running = runningIndex
        // The line down the left, from the first dot to the last.
        let lineX: CGFloat = 12
        if let first = frames.first, let last = frames.last {
            th.foreground.withAlphaComponent(0.14).setFill()
            NSRect(x: lineX - 1, y: first.minY + Self.pad + 9, width: 2, height: last.minY - first.minY).fill()
        }
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping
        for (i, r) in releases.enumerated() {
            let f = frames[i]
            guard f.insetBy(dx: -40, dy: -10).intersects(dirtyRect) else { continue }
            let isRunning = i == running
            let isNew = running.map { i < $0 } ?? false
            // The card.
            let card = NSBezierPath(roundedRect: f, xRadius: 10, yRadius: 10)
            th.surface.withAlphaComponent(hovered == i ? 0.85 : isRunning ? 0.75 : 0.5).setFill()
            card.fill()
            (isRunning ? th.accent.withAlphaComponent(0.6) : th.border).setStroke()
            card.lineWidth = isRunning ? 1.5 : 1
            card.stroke()
            // Its dot on the line.
            let dotY = f.minY + Self.pad + 9
            let dot = NSRect(x: lineX - 6, y: dotY - 6, width: 12, height: 12)
            th.background.setFill()
            NSBezierPath(ovalIn: dot.insetBy(dx: -2, dy: -2)).fill()
            if isRunning {
                th.accent.setFill()
                NSBezierPath(ovalIn: dot).fill()
            } else {
                let ring = NSBezierPath(ovalIn: dot.insetBy(dx: 1, dy: 1))
                ring.lineWidth = 2
                (isNew ? th.accent : th.foreground.withAlphaComponent(0.35)).setStroke()
                ring.stroke()
            }
            // Version, hash, badge; the date at the right.
            var x = f.minX + Self.pad
            let top = f.minY + Self.pad
            let version = "0.1.\(r.version)" as NSString
            version.draw(at: NSPoint(x: x, y: top), withAttributes: [.font: versionFont, .foregroundColor: th.accent])
            x += version.size(withAttributes: [.font: versionFont]).width + 10
            let hash = String(r.hash.prefix(7)) as NSString
            hash.draw(at: NSPoint(x: x, y: top + 1), withAttributes: [.font: hashFont, .foregroundColor: th.dimText])
            x += hash.size(withAttributes: [.font: hashFont]).width + 10
            if isRunning || isNew {
                drawBadge(isRunning ? "Installed" : "New", at: NSPoint(x: x, y: top - 1), color: isRunning ? th.green : th.accent, th: th)
            }
            let date = Self.dateFormatter.string(from: r.date) as NSString
            let dateW = date.size(withAttributes: [.font: metaFont]).width
            date.draw(at: NSPoint(x: f.maxX - Self.pad - dateW, y: top + 1), withAttributes: [.font: metaFont, .foregroundColor: th.dimText])
            // Subject and summary.
            let textW = f.width - Self.pad * 2
            var y = top + 18 + 6
            let subjectH = textHeight(r.subject, subjectFont, width: textW, lines: 2)
            (r.subject as NSString).draw(with: NSRect(x: f.minX + Self.pad, y: y, width: textW, height: subjectH),
                                         options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                         attributes: [.font: subjectFont, .foregroundColor: th.foreground, .paragraphStyle: para])
            y += subjectH
            if !r.summary.isEmpty {
                y += 4
                let bodyH = textHeight(r.summary, bodyFont, width: textW, lines: 3)
                (r.summary as NSString).draw(with: NSRect(x: f.minX + Self.pad, y: y, width: textW, height: bodyH),
                                             options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                             attributes: [.font: bodyFont, .foregroundColor: th.foreground.withAlphaComponent(0.7), .paragraphStyle: para])
                y += bodyH
            }
            ("by \(r.author)" as NSString).draw(at: NSPoint(x: f.minX + Self.pad, y: y + 8),
                                               withAttributes: [.font: metaFont, .foregroundColor: th.dimText])
        }
    }

    private func drawBadge(_ text: String, at p: NSPoint, color: NSColor, th: Theme) {
        let font = NSFont.systemFont(ofSize: 10.5, weight: .bold)
        let size = (text as NSString).size(withAttributes: [.font: font])
        let r = NSRect(x: p.x, y: p.y, width: size.width + 14, height: 18)
        color.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: r, xRadius: 9, yRadius: 9).fill()
        (text as NSString).draw(at: NSPoint(x: r.minX + 7, y: r.midY - size.height / 2), withAttributes: [.font: font, .foregroundColor: color])
    }

    var devSummary: String { releases.prefix(3).map { "0.1.\($0.version) \($0.hash.prefix(7)) \($0.subject.prefix(30))" }.joined(separator: " | ") }
}
