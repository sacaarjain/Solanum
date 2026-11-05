import AppKit

// What Git Changes can do to the repository, as VS Code's Source Control does: stage and unstage files (or all of
// them), discard changes, delete untracked files, commit (what's staged, or everything after asking), push, pull
// and publish a branch. Each is a git command run where the repository is (this Mac, or an ssh host), with the page
// read again after; when one fails, its output shows, with a way to run it in the terminal (for a password, say).

enum GitAction {
    case stage([String]), unstage([String]), discard([String]), delete([String])
    case stageAll, stageTracked, stageUntracked, unstageAll, discardAll
    case commit(message: String, all: Bool), push(upstream: Bool), pull

    /// What the status line says while it runs.
    var busy: String {
        switch self {
        case .stage, .stageAll, .stageTracked, .stageUntracked: return "Staging…"
        case .unstage, .unstageAll: return "Unstaging…"
        case .discard, .discardAll: return "Discarding…"
        case .delete: return "Deleting…"
        case .commit: return "Committing…"
        case .push(let upstream): return upstream ? "Pushing…" : "Publishing…"
        case .pull: return "Pulling…"
        }
    }

    private static func paths(_ list: [String]) -> String { list.map(shellQuote).joined(separator: " ") }

    /// The script git runs (in the repository's top folder).
    var script: String {
        switch self {
        case .stage(let p): return "git add -A -- \(Self.paths(p))"
        // `restore --staged` (git 2.23+), else reset; in a repository without commits, just untrack.
        case .unstage(let p):
            let q = Self.paths(p)
            return "git restore --staged -- \(q) 2>/dev/null || git reset -q -- \(q) 2>/dev/null || git rm -r -q --cached -- \(q)"
        case .discard(let p):
            let q = Self.paths(p)
            return "git restore -- \(q) 2>/dev/null || git checkout -- \(q)"
        case .delete(let p): return "git clean -f -d -q -- \(Self.paths(p))"
        case .stageAll: return "git add -A"
        case .stageTracked: return "git add -u"
        case .stageUntracked: return "git ls-files -z -o --exclude-standard | xargs -0 git add --"
        case .unstageAll: return "git reset -q 2>/dev/null || git rm -r -q --cached -- ."
        case .discardAll: return "git restore -- . 2>/dev/null || git checkout -- ."
        case .commit(let message, let all):
            // The message as it was typed, through a here-document whose end can't be in it.
            let end = "SOLANUM_MESSAGE_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            return (all ? "git add -A && " : "") + "git commit -q -F - <<'\(end)'\n\(message)\n\(end)"
        case .push(let upstream):
            if upstream { return "git push" }
            return """
                r=$(git remote | head -n 1)
                [ -n "$r" ] || { echo "This repository has no remote to publish to." >&2; exit 1; }
                git push -u "$r" HEAD
                """
        case .pull: return "git pull --no-edit"
        }
    }

    /// The same, as typed in a terminal (where a password or passphrase can be answered).
    var typed: String? {
        switch self {
        case .push(let upstream): return upstream ? "git push" : "git push -u origin HEAD"
        case .pull: return "git pull"
        case .commit: return nil
        default: return nil
        }
    }
}

/// Above the list of changes: the message, Commit and Commit & Push, and Pull and Push for the branch.
final class GitCommitBox: NSView, NSTextViewDelegate {
    static let height: CGFloat = 126
    private let scroll = NSScrollView()
    let text = CommitMessageView()
    private let commit = BarButton("Commit", filled: true)
    private let commitPush = BarButton("Commit & Push", filled: false)
    private let pull = BarButton("Pull", filled: false)
    private let push = BarButton("Push", filled: false)
    private let status = NSTextField(labelWithString: "")
    /// Commit (all: nothing was staged), then maybe push.
    var onCommit: ((_ push: Bool) -> Void)?
    var onPull: (() -> Void)?
    var onPush: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        text.isRichText = false
        text.allowsUndo = true
        text.font = .systemFont(ofSize: 13)
        text.textContainerInset = NSSize(width: 6, height: 7)
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.drawsBackground = false
        text.delegate = self
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.onCommitKey = { [weak self] in self?.onCommit?(false) }
        scroll.documentView = text
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        addSubview(scroll)
        commit.onPress = { [weak self] in self?.onCommit?(false) }
        commitPush.onPress = { [weak self] in self?.onCommit?(true) }
        pull.onPress = { [weak self] in self?.onPull?() }
        push.onPress = { [weak self] in self?.onPush?() }
        status.font = .systemFont(ofSize: 11.5)
        status.lineBreakMode = .byTruncatingTail
        [commit, commitPush, pull, push, status].forEach(addSubview)
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    var message: String { text.string.trimmingCharacters(in: .whitespacesAndNewlines) }

    func applyTheme() {
        let th = Config.shared.theme
        text.textColor = th.foreground
        text.insertionPointColor = th.accent
        text.placeholder = NSAttributedString(string: "Message (⌘↩ to commit)", attributes: [.foregroundColor: th.dimText, .font: NSFont.systemFont(ofSize: 13)])
        status.textColor = th.dimText
        subviews.forEach { $0.needsDisplay = true }
        needsDisplay = true
    }

    /// The buttons for where things stand: Commit or Commit All (nothing staged), Push ↑n or Publish Branch, Pull ↓n.
    func update(_ r: GitStatusReport, busy: String?) {
        let changes = !(r.staged.isEmpty && r.changed.isEmpty && r.untracked.isEmpty)
        let all = r.staged.isEmpty
        commit.title = all ? "Commit All" : "Commit"
        commitPush.title = all ? "Commit All & Push" : "Commit & Push"
        commit.isEnabled = changes && busy == nil
        commitPush.isEnabled = changes && busy == nil && !r.detached
        push.title = r.upstream == nil ? "Publish Branch" : r.ahead > 0 ? "Push ↑\(r.ahead)" : "Push"
        push.isEnabled = busy == nil && !r.detached
        pull.title = r.behind > 0 ? "Pull ↓\(r.behind)" : "Pull"
        pull.isEnabled = busy == nil && r.upstream != nil
        status.stringValue = busy ?? (r.conflicts.isEmpty ? (all && changes ? "Nothing staged: Commit All stages every change first." : "")
                                      : "Resolve the conflicts, then mark them resolved (+) before committing.")
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let left: CGFloat = 24, right = bounds.width - 24
        scroll.frame = NSRect(x: left, y: 12, width: right - left, height: 62)
        var x = left
        let y: CGFloat = 84, h: CGFloat = 28
        for b in [commit, commitPush] {
            b.frame = NSRect(x: x, y: y, width: b.preferredWidth, height: h)
            x += b.preferredWidth + 8
        }
        var rx = right
        for b in [push, pull] {
            rx -= b.preferredWidth
            b.frame = NSRect(x: rx, y: y, width: b.preferredWidth, height: h)
            rx -= 8
        }
        status.frame = NSRect(x: x + 6, y: y + 6, width: max(0, rx - x - 12), height: 16)
        text.frame.size.width = scroll.contentSize.width
    }

    override func draw(_ dirtyRect: NSRect) {
        let th = Config.shared.theme
        let box = NSBezierPath(roundedRect: scroll.frame.insetBy(dx: -1, dy: -1), xRadius: 8, yRadius: 8)
        th.foreground.withAlphaComponent(0.05).setFill()
        box.fill()
        (text.window?.firstResponder === text ? th.accent.withAlphaComponent(0.7) : th.border).setStroke()
        box.lineWidth = 1
        box.stroke()
        th.border.setFill()
        NSRect(x: 24, y: bounds.height - 1, width: bounds.width - 48, height: 1).fill()
    }

    func textDidBeginEditing(_ notification: Notification) { needsDisplay = true }
    func textDidEndEditing(_ notification: Notification) { needsDisplay = true }

    var devState: String { "\(commit.title)\(commit.isEnabled ? "" : " (off)") · \(push.title)\(push.isEnabled ? "" : " (off)") · \(pull.title)\(pull.isEnabled ? "" : " (off)") · \(status.stringValue)" }
    func devPress(_ title: String) { [commit, commitPush, pull, push].first { $0.title == title && $0.isEnabled }?.onPress?() }
}

/// The commit message: a placeholder while empty, ⌘↩ commits.
final class CommitMessageView: NSTextView {
    var placeholder: NSAttributedString?
    var onCommitKey: (() -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty, let placeholder {
            placeholder.draw(at: NSPoint(x: textContainerInset.width + 5, y: textContainerInset.height))
        }
    }

    override func keyDown(with e: NSEvent) {
        if e.modifierFlags.contains(.command), e.keyCode == 36 || e.keyCode == 76 { return onCommitKey?() ?? () }
        super.keyDown(with: e)
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }
}
