import Foundation
import WinSDK

/// Where git commands run for a tab: a folder on this PC, through Git for Windows' sh (so the scripts are the Mac's),
/// or on an ssh host through the sidebar's connection.
struct GitPlace {
    let dir: String
    let remote: RemoteConnection?

    /// Tells one place from another, to drop what a place no longer shown sends back.
    var key: String { (remote.map { "\(ObjectIdentifier($0).hashValue)" } ?? "local") + "\n" + dir }
    var onHost: Bool { remote != nil }

    /// A folder as sh is given it: forward slashes, which Git for Windows' sh and git take as well as the other kind.
    static func shPath(_ path: String) -> String { AnyPath.isUnix(path) ? path : path.replacingOccurrences(of: "\\", with: "/") }

    /// A path git printed (C:/a/b), as this PC writes it, or a host's as it is.
    func localPath(_ gitPath: String) -> String { onHost ? gitPath : gitPath.replacingOccurrences(of: "/", with: "\\") }

    /// Runs a script there; `done` gets (exit status, what it printed, what it said on its standard error) on another
    /// thread. Git never prompts: there's no terminal to answer it in. On a host, standard error comes merged into the
    /// output when `errors` is set, as the connection keeps just the one stream.
    func run(_ script: String, timeout: TimeInterval = 30, errors: Bool = false, _ done: @escaping (Int32, Data, String) -> Void) {
        let full = "cd \(RemoteConnection.quote(Self.shPath(dir))) || exit 128\nexport GIT_OPTIONAL_LOCKS=0 GIT_TERMINAL_PROMPT=0\n" + script
        if let remote {
            remote.run("{ \(full)\n} \(errors ? "2>&1" : "2>/dev/null")", timeout: timeout) { text, code in
                done(text == nil ? 124 : code, Data((text ?? "").utf8), errors ? (text ?? "") : "")
            }
            return
        }
        guard let sh = GitShell.sh else { return done(127, Data(), "Git for Windows isn't installed (its sh.exe wasn't found).") }
        Thread.detachNewThread {
            let lock = NSLock(), exited = DispatchSemaphore(value: 0)
            var out = Data(), err = Data(), status: Int32 = -1
            guard let child = HiddenProcess(executable: sh, arguments: ["-c", full], extraEnvironment: ["MSYS_NO_PATHCONV": "1", "LC_ALL": "C.UTF-8"]) else {
                return done(127, Data(), "Couldn't start sh.")
            }
            child.onOutput = { d in lock.lock(); out.append(d); lock.unlock() }
            child.onError = { d in lock.lock(); err.append(d); lock.unlock() }
            child.onExit = { code in status = code; exited.signal() }
            if exited.wait(timeout: .now() + timeout) == .timedOut {
                child.terminate()
                _ = exited.wait(timeout: .now() + 2)
                return done(124, Data(), "Timed out.")
            }
            lock.lock()
            let result = (status, out, String(decoding: err, as: UTF8.self))
            lock.unlock()
            done(result.0, result.1, result.2)
        }
    }
}

enum GitShell {
    /// Git for Windows' sh.exe, found from git on the PATH (…\Git\cmd\git.exe → …\Git\bin\sh.exe), or where it installs.
    static let sh: String? = {
        let fm = FileManager.default
        var roots: [String] = []
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ";").map(String.init) {
            guard fm.fileExists(atPath: WindowsPath.join(dir, "git.exe")), let up = WindowsPath.parent(dir) else { continue }
            roots.append(up)
            // …\Git\mingw64\bin\git.exe
            if let twoUp = WindowsPath.parent(up) { roots.append(twoUp) }
        }
        for base in ["ProgramFiles", "ProgramW6432", "LOCALAPPDATA"].compactMap({ ProcessInfo.processInfo.environment[$0] }) {
            roots.append(WindowsPath.join(base, "Git"))
            roots.append(WindowsPath.join(WindowsPath.join(base, "Programs"), "Git"))
        }
        for root in roots {
            for candidate in [WindowsPath.join(WindowsPath.join(root, "bin"), "sh.exe"), WindowsPath.join(WindowsPath.join(WindowsPath.join(root, "usr"), "bin"), "sh.exe")]
            where fm.fileExists(atPath: candidate) { return candidate }
        }
        return nil
    }()
}
