import Foundation

/// The sidebar's git letters, as the Mac's (GitTreeStatus there): which of the folder's files are changed, and each
/// folder holding changes, by the most serious change inside. Read from `git status` in the sidebar's folder, on this
/// PC or the ssh host it shows.
struct SidebarGitStatus: Equatable {
    /// Changed files and folders holding changes, by path as the sidebar lists them (lowercased on this PC, whose
    /// paths don't care about case).
    private var files: [String: Character] = [:]
    private var folders: [String: Character] = [:]
    /// Untracked folders (git reports them whole): everything inside is untracked too.
    private var untrackedDirs: [String] = []
    private var unix = false

    /// The folder's path inside its repository on the first line, then the changes, repository-relative.
    static let script = "p=$(git rev-parse --show-prefix) || exit 1; printf '%s\\n' \"$p\"; git status --porcelain=v2 -z"

    /// Paths are relative to the repository root, so `root`'s place in it (the first line) maps them onto `root`.
    /// Changes outside `root` are left out.
    init?(output: Data, root: String) {
        let s = String(decoding: output, as: UTF8.self)
        guard let nl = s.firstIndex(of: "\n") else { return nil }
        let prefix = String(s[..<nl])
        guard let changes = GitInfo(statusOutput: Data(("/\n" + s[s.index(after: nl)...]).utf8))?.changes else { return nil }
        let unix = AnyPath.isUnix(root), base = Self.key(root, unix: unix)
        var files: [String: Character] = [:], folders: [String: Character] = [:], untracked: [String] = []
        for c in changes where c.path.hasPrefix(prefix) {
            let rel = String(c.path.dropFirst(prefix.count))
            let isDir = rel.hasSuffix("/")
            let path = Self.join(base, isDir ? String(rel.dropLast()) : rel, unix: unix)
            if isDir {
                untracked.append(path)
                folders[path] = c.code
            } else {
                files[path] = c.code
            }
            var dir = Self.parent(path, unix: unix)
            while dir.count > base.count && dir.hasPrefix(base) {
                if let old = folders[dir], Self.rank(old) >= Self.rank(c.code) { break }
                folders[dir] = c.code
                dir = Self.parent(dir, unix: unix)
            }
        }
        self.files = files
        self.folders = folders
        self.untrackedDirs = untracked
        self.unix = unix
    }

    private static func separator(_ unix: Bool) -> String { unix ? "/" : "\\" }
    private static func key(_ path: String, unix: Bool) -> String { unix ? path : path.lowercased() }
    private static func join(_ base: String, _ rel: String, unix: Bool) -> String {
        let r = key(unix ? rel : rel.replacingOccurrences(of: "/", with: "\\"), unix: unix), sep = separator(unix)
        return base.hasSuffix(sep) ? base + r : base + sep + r
    }
    private static func parent(_ path: String, unix: Bool) -> String {
        guard let cut = path.range(of: separator(unix), options: .backwards) else { return "" }
        return String(path[..<cut.lowerBound])
    }

    /// The change to show for a row, if any.
    func code(for path: String, isDirectory: Bool) -> Character? {
        let k = Self.key(path, unix: unix), sep = Self.separator(unix)
        if let c = isDirectory ? folders[k] : files[k] { return c }
        return untrackedDirs.contains { k.hasPrefix($0 + sep) } ? "?" : nil
    }

    /// Which change a folder shows when it holds several: conflicts and deletions over edits over additions.
    static func rank(_ c: Character) -> Int {
        switch c {
        case "U": return 4
        case "D": return 3
        case "M", "T": return 2
        default: return 1
        }
    }

    /// The letter shown (untracked as U, a conflict as C), and its color: green added, orange modified, red deleted or
    /// conflicted, all muted, as on the Mac.
    static func badge(_ c: Character) -> (letter: String, color: UInt32) {
        let green: UInt32 = 0x73BD78, orange: UInt32 = 0xE09C54, red: UInt32 = 0xE06B6B
        switch c {
        case "?": return ("U", green)
        case "A", "C": return ("A", green)
        case "R": return ("R", green)
        case "M", "T": return ("M", orange)
        case "D": return ("D", red)
        case "U": return ("C", red)
        default: return (String(c), orange)
        }
    }
}
