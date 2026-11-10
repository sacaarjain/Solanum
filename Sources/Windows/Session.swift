import Foundation
import WinSDK

/// What a window had open, kept in %APPDATA%\Solanum\session.json: its tabs (folder, name, column, group, and what they
/// showed), its groups, the split, and where the window was. Closing the last window saves it and the next launch brings
/// it back, as does Restart (Ctrl+Shift+R); closing the tabs one by one, or Restart Fresh, starts over. Tests never touch it.
struct SavedSession: Codable {
    struct Tab: Codable {
        var folder: String?
        var title: String?
        var column: Int
        var group: Int?
        /// Its scrollback and screen, with their colors, shown again above the new shell's prompt.
        var text: String
        /// What carries on where it was, run when the tab is first shown, as on the Mac: the agent that was running
        /// (`claude -c`, `codex resume --last`, …), or ssh to the host it was on.
        var resume: String?
        /// A file tab (its terminal hidden) on this PC: the file it showed, which it comes back showing. Read from sessions
        /// saved before `pages`.
        var file: String?
        /// The files on this PC open above its terminal (or alone, in a file tab), and their previews, in order.
        var pages: [Page]?
        /// Which of them was showing.
        var activePage: Int?
        /// A file tab: just its files, the terminal hidden.
        var terminalHidden: Bool?
        /// How much of the tab its files took.
        var editorFraction: Float?
        /// Its shell (see Shells), when it isn't the default one.
        var shell: String?
    }
    struct Page: Codable {
        var path: String
        /// A Markdown file's preview, rather than the file.
        var preview: Bool?
    }
    struct Group: Codable {
        var name: String
        var color: String
        var collapsed: Bool
    }

    var tabs: [Tab]
    var groups: [Group] = []
    var active = 0
    var splitFraction: Float = 0.5
    /// The window's frame (left, top, right, bottom) when it isn't maximized.
    var frame: [Int32]?
    var maximized = false

    /// Lines of each tab's scrollback kept.
    static let lines = 5000

    static var file: URL? {
        guard !CommandLine.arguments.contains("--window-test"), let appData = ProcessInfo.processInfo.environment["APPDATA"] else { return nil }
        return URL(fileURLWithPath: appData).appendingPathComponent("Solanum").appendingPathComponent("session.json")
    }

    static func load() -> SavedSession? {
        guard let url = file, let data = try? Data(contentsOf: url), let session = try? JSONDecoder().decode(SavedSession.self, from: data),
              !session.tabs.isEmpty else { return nil }
        return session
    }

    func save() {
        guard let url = Self.file, let data = try? JSONEncoder().encode(self) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    static func clear() {
        guard let url = file else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

/// The programs running under a tab's shell, for knowing which agent is running there when what was typed doesn't say
/// (an alias, a script).
enum ProcessTree {
    /// The names of every process descended from `root`, without ".exe", in lowercase.
    static func descendantNames(of root: DWORD) -> [String] { descendants(of: root).map(\.name) }

    /// Every process descended from `root`, nearest first: its ID and its name (without ".exe", in lowercase).
    static func descendants(of root: DWORD) -> [(pid: DWORD, name: String)] {
        guard root != 0 else { return [] }
        let snapshot = CreateToolhelp32Snapshot(DWORD(TH32CS_SNAPPROCESS), 0)
        guard let snapshot, snapshot != INVALID_HANDLE_VALUE else { return [] }
        defer { CloseHandle(snapshot) }
        var entry = PROCESSENTRY32W()
        entry.dwSize = DWORD(MemoryLayout<PROCESSENTRY32W>.size)
        var all: [(pid: DWORD, parent: DWORD, name: String)] = []
        guard Process32FirstW(snapshot, &entry) else { return [] }
        repeat {
            let name = withUnsafeBytes(of: entry.szExeFile) { raw -> String in
                let units = raw.bindMemory(to: WCHAR.self)
                let length = units.firstIndex(of: 0) ?? units.count
                return String(decoding: units[..<length], as: UTF16.self)
            }
            all.append((entry.th32ProcessID, entry.th32ParentProcessID, name))
        } while Process32NextW(snapshot, &entry)
        var family: Set<DWORD> = [root], found: [(pid: DWORD, name: String)] = [], grew = true
        while grew {
            grew = false
            for p in all where !family.contains(p.pid) && family.contains(p.parent) && p.pid != 0 {
                family.insert(p.pid)
                var name = p.name.lowercased()
                if name.hasSuffix(".exe") { name.removeLast(4) }
                found.append((p.pid, name))
                grew = true
            }
        }
        return found
    }
}

enum AppRestart {
    /// Solanum.exe beside this program. A build moves a running Solanum.exe aside (to Solanum.old.exe) to put the new one
    /// in its place, so this is the newest build whichever of them is running.
    static var appPath: String {
        var buffer = [WCHAR](repeating: 0, count: 4096)
        let n = Int(GetModuleFileNameW(nil, &buffer, DWORD(buffer.count)))
        let me = String(decoding: buffer[..<n], as: UTF16.self)
        return WindowsPath.join(WindowsPath.parent(me) ?? ".", "Solanum.exe")
    }

    /// Starts Solanum again. False if it couldn't.
    static func launch() -> Bool {
        let ok = wide(appPath).withUnsafeBufferPointer { path in
            wide("open").withUnsafeBufferPointer { verb in ShellExecuteW(nil, verb.baseAddress, path.baseAddress, nil, nil, 1) }
        }
        return Int(bitPattern: ok) > 32
    }

    /// `Solanum.exe --restart-running` (what `build.ps1 -Restart` runs): asks the Solanum already running to restart into
    /// the new build, keeping everything it has open.
    static func askRunningToRestart() -> Int32 {
        let found = wide("SolanumTerminalWindow").withUnsafeBufferPointer { FindWindowW($0.baseAddress, nil) }
        guard let hwnd = found else {
            // Nothing running: just start it.
            return launch() ? 0 : 1
        }
        PostMessageW(hwnd, Win.WM_RESTART, 0, 0)
        return 0
    }
}
