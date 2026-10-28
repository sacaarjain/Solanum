import AppKit

// "Open Working Tree" from the sidebar: a git-changed file side by side, as git has it (the index: what's
// staged, else the last commit) on the left and the file on disk on the right, like VS Code's diff editor.
// Removed lines are tinted red on the left, added ones green on the right, with gaps opposite so the
// unchanged lines stay level. Both sides scroll together vertically and on their own sideways.

/// One row of a side-by-side diff: a line index on either side, nil for the gap opposite an addition or removal.
struct DiffRow {
    var left: Int?
    var right: Int?
    var changed: Bool
}

enum LineDiff {
    static func rows(old: [String], new: [String]) -> [DiffRow] {
        let diff = new.difference(from: old)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in diff {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var rows: [DiffRow] = []
        var i = 0, j = 0
        while i < old.count || j < new.count {
            if (i < old.count && removed.contains(i)) || (j < new.count && inserted.contains(j)) {
                // A run of removals and the additions that replace them share rows, like a modified block.
                var gone: [Int] = [], added: [Int] = []
                while i < old.count && removed.contains(i) { gone.append(i); i += 1 }
                while j < new.count && inserted.contains(j) { added.append(j); j += 1 }
                for k in 0..<max(gone.count, added.count) {
                    rows.append(DiffRow(left: k < gone.count ? gone[k] : nil, right: k < added.count ? added[k] : nil, changed: true))
                }
            } else {
                rows.append(DiffRow(left: i, right: j, changed: false))
                i += 1
                j += 1
            }
        }
        return rows
    }
}

/// The two sides, separated by a thin rule.
final class DiffView: NSView {
    private let left = DiffSide(isLeft: true)
    private let right = DiffSide(isLeft: false)
    private var syncing = false

    init() {
        super.init(frame: .zero)
        for side in [left, right] {
            addSubview(side.scroll)
            side.scroll.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(scrolled(_:)), name: NSView.boundsDidChangeNotification,
                                                   object: side.scroll.contentView)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    /// Takes focus so ⌘W and the other editor commands reach the editor around it.
    override var acceptsFirstResponder: Bool { true }

    /// `old` / `new`: the whole files; `language` colors both sides.
    func show(old: String, new: String, language: SyntaxLanguage?) {
        let oldLines = DiffSide.lines(of: old), newLines = DiffSide.lines(of: new)
        let rows = LineDiff.rows(old: oldLines, new: newLines)
        left.set(rows: rows, lines: oldLines, language: language)
        right.set(rows: rows, lines: newLines, language: language)
        // Start at the first change, a few lines down from the top.
        let first = rows.firstIndex(where: \.changed) ?? 0
        let y = max(0, CGFloat(first - 3) * left.lines.lineHeight)
        left.scrollToStart(y: y)
        right.scrollToStart(y: y)
    }

    /// "+3 −1": lines added and removed.
    var summary: String {
        let rows = left.lines.rows.filter(\.changed)
        return "+\(rows.filter { $0.right != nil }.count) −\(rows.filter { $0.left != nil }.count)"
    }

    func applyTheme() {
        left.applyTheme()
        right.applyTheme()
        needsDisplay = true
    }

    @objc private func scrolled(_ note: Notification) {
        guard let clip = note.object as? NSClipView else { return }
        // The gutter is pinned to the visible left edge, so sideways scrolling redraws it.
        (clip.documentView as? DiffLinesView)?.needsDisplay = true
        guard !syncing else { return }
        let other = clip === left.scroll.contentView ? right.scroll : left.scroll
        guard abs(other.contentView.bounds.origin.y - clip.bounds.origin.y) > 0.5 else { return }
        syncing = true
        other.contentView.scroll(to: NSPoint(x: other.contentView.bounds.origin.x, y: clip.bounds.origin.y))
        other.reflectScrolledClipView(other.contentView)
        syncing = false
    }

    override func layout() {
        super.layout()
        let half = ((bounds.width - 1) / 2).rounded()
        left.scroll.frame = NSRect(x: 0, y: 0, width: half, height: bounds.height)
        right.scroll.frame = NSRect(x: half + 1, y: 0, width: bounds.width - half - 1, height: bounds.height)
        left.lines.fitWidth()
        right.lines.fitWidth()
    }

    override func draw(_ dirtyRect: NSRect) {
        Config.shared.theme.border.setFill()
        NSRect(x: left.scroll.frame.maxX, y: 0, width: 1, height: bounds.height).fill()
    }
}

/// One side: a scroll view around its lines.
final class DiffSide {
    let scroll = NSScrollView()
    let lines: DiffLinesView

    init(isLeft: Bool) {
        lines = DiffLinesView(isLeft: isLeft)
        scroll.documentView = lines
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = isLeft == false
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
    }

    /// Lines without their newlines; tabs become four spaces so every column is one character wide.
    static func lines(of text: String) -> [String] {
        var t = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\t", with: "    ")
        if t.hasSuffix("\n") { t.removeLast() }
        return t.isEmpty ? [] : t.components(separatedBy: "\n")
    }

    func set(rows: [DiffRow], lines text: [String], language: SyntaxLanguage?) {
        lines.set(rows: rows, text: text, language: language)
    }

    /// Scrolls to `y`, all the way left.
    func scrollToStart(y: CGFloat) {
        let clip = scroll.contentView
        var r = clip.bounds
        r.origin = NSPoint(x: 0, y: y)
        clip.scroll(to: clip.constrainBoundsRect(r).origin)
        scroll.reflectScrolledClipView(clip)
    }

    func applyTheme() {
        lines.restyle()
    }
}

/// One side's lines, with the line numbers in a gutter that stays at the left edge when scrolled sideways
/// (`-` / `+` beside changed lines, as VS Code marks them).
final class DiffLinesView: NSView {
    let isLeft: Bool
    private(set) var rows: [DiffRow] = []
    private var text: [String] = []
    private var styled: [NSAttributedString] = []
    private var language: SyntaxLanguage?
    private(set) var lineHeight: CGFloat = 17
    private var charWidth: CGFloat = 7
    private var font = FontSet.current.regular as NSFont
    private let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
    private var gutterWidth: CGFloat = 40
    /// The longest line's width; the view is at least as wide as what's on screen.
    private var contentWidth: CGFloat = 0

    init(isLeft: Bool) {
        self.isLeft = isLeft
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func set(rows: [DiffRow], text: [String], language: SyntaxLanguage?) {
        self.rows = rows
        self.text = text
        self.language = language
        restyle()
    }

    /// Fonts and colors (again, after a theme change): the lines are colored as one text, then split.
    func restyle() {
        let th = Config.shared.theme
        font = FontSet.current.regular as NSFont
        lineHeight = ceil(NSLayoutManager().defaultLineHeight(for: font))
        charWidth = ("M" as NSString).size(withAttributes: [.font: font]).width
        let whole = NSMutableAttributedString(string: text.joined(separator: "\n"), attributes: [.font: font, .foregroundColor: th.foreground])
        if let language { SyntaxHighlighter.highlight(whole, as: language) }
        styled = []
        var at = 0
        for line in text {
            let n = (line as NSString).length
            styled.append(whole.attributedSubstring(from: NSRange(location: at, length: n)))
            at += n + 1
        }
        let digits = max(3, String(text.count).count)
        gutterWidth = (CGFloat(digits + 1) * ("8" as NSString).size(withAttributes: [.font: numberFont]).width + 18).rounded()
        contentWidth = gutterWidth + CGFloat(text.map(\.count).max() ?? 0) * charWidth + 24
        fitWidth()
        needsDisplay = true
    }

    func fitWidth() {
        let size = NSSize(width: max(enclosingScrollView?.contentSize.width ?? 0, contentWidth), height: CGFloat(rows.count) * lineHeight + 8)
        if size != frame.size { setFrameSize(size) }
    }

    /// Tint for a row on this side: red / green where it changed, a faint wash in the gap opposite.
    func tint(_ row: DiffRow) -> NSColor? {
        guard row.changed else { return nil }
        let th = Config.shared.theme
        let line = isLeft ? row.left : row.right
        if line == nil { return th.foreground.withAlphaComponent(0.035) }
        return (isLeft ? th.red : th.green).withAlphaComponent(th.isDark ? 0.22 : 0.18)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !rows.isEmpty else { return }
        let th = Config.shared.theme
        let visible = visibleRect
        let gutter = NSRect(x: visible.minX, y: dirtyRect.minY, width: gutterWidth, height: dirtyRect.height)
        let first = max(0, Int(dirtyRect.minY / lineHeight))
        let last = min(rows.count - 1, Int(dirtyRect.maxY / lineHeight))
        guard first <= last else { return }
        for r in first...last {
            let row = rows[r]
            let y = CGFloat(r) * lineHeight
            if let tint = tint(row) {
                tint.setFill()
                NSRect(x: dirtyRect.minX, y: y, width: dirtyRect.width, height: lineHeight).fill()
            }
            guard let i = isLeft ? row.left : row.right else { continue }
            if styled.indices.contains(i) {
                // Text scrolled sideways passes under the gutter, not over the numbers.
                NSGraphicsContext.saveGraphicsState()
                NSRect(x: gutter.maxX, y: y, width: max(0, visible.maxX - gutter.maxX), height: lineHeight).clip()
                styled[i].draw(at: NSPoint(x: gutterWidth + 8, y: y))
                NSGraphicsContext.restoreGraphicsState()
            }
            let mark = row.changed ? (isLeft ? "−" : "+") : " "
            let attrs: [NSAttributedString.Key: Any] = [.font: numberFont,
                .foregroundColor: row.changed ? th.foreground.withAlphaComponent(0.75) : th.dimText.withAlphaComponent(0.45)]
            let label = "\(i + 1)" as NSString
            let size = label.size(withAttributes: attrs)
            let markW = (mark as NSString).size(withAttributes: attrs).width
            let ty = y + (lineHeight - size.height) / 2
            label.draw(at: NSPoint(x: gutter.maxX - size.width - markW - 10, y: ty), withAttributes: attrs)
            (mark as NSString).draw(at: NSPoint(x: gutter.maxX - markW - 6, y: ty), withAttributes: attrs)
        }
    }
}
