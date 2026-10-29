import AppKit

// File access for the sidebar, editor and status bar: either this Mac, or the host at the other end of an
// ssh session started in a pane. Remote commands ride the session's multiplexing socket (see
// ShellIntegration.sshWrapper), so they reuse its authentication and never prompt.

struct FileItem {
    let name: String
    let path: String
    let isDirectory: Bool
    /// A file git still tracks but that's gone from disk: listed (greyed out) so the change shows.
    var isDeleted = false
    var isHidden: Bool { name.hasPrefix(".") }
}

enum FileOp {
    case delete([String])
    case move(String, to: String)
    case copy(String, to: String)
    case makeDirectory(String)
    case makeFile(String)
}

struct FileError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

protocol FileSystem: AnyObject {
    var isRemote: Bool { get }
    /// Shown in place of local paths, e.g. "me@host".
    var hostLabel: String? { get }
    var home: String? { get }
    func list(_ dir: String, _ done: @escaping (Result<[FileItem], Error>) -> Void)
    /// Fails with "too large" past `limit` bytes.
    func read(_ path: String, limit: Int, _ done: @escaping (Result<Data, Error>) -> Void)
    /// Part of a file, and its size: from `offset` to the end (at most `tail` bytes), or with no offset, all of it
    /// when it's at most `whole` bytes and otherwise its last `tail` bytes. For big files, and for following one as
    /// it grows without reading it all again.
    func readPart(_ path: String, from offset: Int?, whole: Int, tail: Int, _ done: @escaping (Result<FilePart, Error>) -> Void)
    func write(_ data: Data, to path: String, _ done: @escaping (Error?) -> Void)
    func perform(_ op: FileOp, _ done: @escaping (Error?) -> Void)
}

extension FileSystem {
    func read(_ path: String, _ done: @escaping (Result<Data, Error>) -> Void) {
        read(path, limit: maxEditableFileSize, done)
    }
}

/// Files larger than this open read-only (see `FileEditorView`).
let maxEditableFileSize = 50 * 1024 * 1024
/// Up to this size a read-only file still opens in full (a day's log, say); past it only its end shows.
let maxReadableFileSize = 512 * 1024 * 1024
/// How much of the end of a file past `maxReadableFileSize` shows.
let fileTailSize = 10 * 1024 * 1024

/// Bytes read from a file (see `FileSystem.readPart`), and the file's whole size then.
struct FilePart {
    let size: Int
    let data: Data
}

enum FilePaths {
    static func join(_ dir: String, _ name: String) -> String {
        dir == "/" ? "/" + name : dir + "/" + name
    }

    static func parent(_ path: String) -> String {
        let p = (path as NSString).deletingLastPathComponent
        return p.isEmpty ? "/" : p
    }

    /// "~/x" for paths under `home`.
    static func abbreviate(_ path: String, home: String?) -> String {
        guard let home, !home.isEmpty, home != "/" else { return path }
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// A name in `dir` that doesn't collide with `taken`: "a.txt" → "a copy.txt", "a copy 2.txt", …
    static func uniqueName(_ name: String, taken: Set<String>) -> String {
        guard taken.contains(name) else { return name }
        let ext = (name as NSString).pathExtension
        var stem = (name as NSString).deletingPathExtension
        if ext.isEmpty || stem.isEmpty { stem = name }
        let suffix = stem == name ? "" : "." + ext
        var n = 1
        while true {
            let candidate = stem + (n == 1 ? " copy" : " copy \(n)") + suffix
            if !taken.contains(candidate) { return candidate }
            n += 1
        }
    }

    static func sortedForDisplay(_ items: [FileItem]) -> [FileItem] {
        // Folders first; dotfiles after the rest so they don't crowd the top of e.g. a home folder.
        items.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            if $0.isHidden != $1.isHidden { return !$0.isHidden }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

// MARK: - Local

final class LocalFileSystem: FileSystem {
    static let shared = LocalFileSystem()
    private let queue = DispatchQueue(label: "solanum.files.local", qos: .userInitiated)

    var isRemote: Bool { false }
    var hostLabel: String? { nil }
    var home: String? { NSHomeDirectory() }

    private func async<T>(_ work: @escaping () throws -> T, _ done: @escaping (Result<T, Error>) -> Void) {
        queue.async {
            let r = Result { try work() }
            DispatchQueue.main.async { done(r) }
        }
    }

    func list(_ dir: String, _ done: @escaping (Result<[FileItem], Error>) -> Void) {
        async({
            let fm = FileManager.default
            return try fm.contentsOfDirectory(atPath: dir).map { name in
                let path = FilePaths.join(dir, name)
                var isDir: ObjCBool = false
                _ = fm.fileExists(atPath: path, isDirectory: &isDir)
                return FileItem(name: name, path: path, isDirectory: isDir.boolValue)
            }
        }, done)
    }

    func read(_ path: String, limit: Int, _ done: @escaping (Result<Data, Error>) -> Void) {
        async({
            let size = (try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue ?? 0
            guard size <= limit else { throw FileError(message: "This file is too large to open (\(size / 1_048_576) MB).") }
            return try Data(contentsOf: URL(fileURLWithPath: path))
        }, done)
    }

    func readPart(_ path: String, from offset: Int?, whole: Int, tail: Int, _ done: @escaping (Result<FilePart, Error>) -> Void) {
        async({
            let h = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            defer { try? h.close() }
            let size = Int(try h.seekToEnd())
            let start = offset.map { min($0, size) } ?? (size <= whole ? 0 : size - tail)
            try h.seek(toOffset: UInt64(start))
            return FilePart(size: size, data: try h.read(upToCount: offset == nil && size <= whole ? size : tail) ?? Data())
        }, done)
    }

    /// Not atomic, so the file keeps its permissions (e.g. an executable script stays executable).
    func write(_ data: Data, to path: String, _ done: @escaping (Error?) -> Void) {
        async({ try data.write(to: URL(fileURLWithPath: path)) }) { done($0.error) }
    }

    func perform(_ op: FileOp, _ done: @escaping (Error?) -> Void) {
        async({
            let fm = FileManager.default
            switch op {
            case .delete(let paths):
                for p in paths { try fm.trashItem(at: URL(fileURLWithPath: p), resultingItemURL: nil) }
            case .move(let from, let to):
                try fm.moveItem(atPath: from, toPath: to)
            case .copy(let from, let to):
                try fm.copyItem(atPath: from, toPath: to)
            case .makeDirectory(let p):
                try fm.createDirectory(atPath: p, withIntermediateDirectories: false)
            case .makeFile(let p):
                guard !fm.fileExists(atPath: p) else { throw FileError(message: "“\((p as NSString).lastPathComponent)” already exists.") }
                guard fm.createFile(atPath: p, contents: Data()) else { throw FileError(message: "Couldn't create “\((p as NSString).lastPathComponent)”.") }
            }
        }) { done($0.error) }
    }
}

private extension Result {
    var error: Failure? {
        if case .failure(let e) = self { return e }
        return nil
    }
}

// MARK: - Remote (ssh)

/// The remote end of an ssh session running in a pane. Created as soon as the wrapper announces the
/// control socket; the socket only appears once ssh has authenticated, so `start` waits for it.
final class RemoteSession: FileSystem {
    let controlPath: String
    private(set) var hostLabel: String?
    private(set) var home: String?
    /// The interactive remote shell's folder, when it could be found (Linux hosts, via /proc).
    private(set) var cwd: String?
    var onChange: (() -> Void)?
    private var readyTimer: Timer?
    private var probing = false
    private var probeAgain = false

    var isRemote: Bool { true }
    var isReady: Bool { hostLabel != nil }
    var isConnected: Bool { FileManager.default.fileExists(atPath: controlPath) }

    /// How the session was opened (`ssh` arguments, shell-quoted), when the shell integration reported them.
    let sshArgs: String?

    init(controlPath: String, sshArgs: String? = nil) {
        self.controlPath = controlPath
        self.sshArgs = sshArgs
    }

    /// A command that opens another shell on the same host, in `dir` (running `command` there first): the
    /// original ssh arguments again, or, if those weren't reported, a session over the original connection
    /// while it's still open.
    func reconnectCommand(in dir: String?, then command: String? = nil) -> String? {
        let first = command.map { $0 + "; " } ?? ""
        let remote = dir.map { " " + shellQuote("cd " + shellQuote($0) + " && " + first + "exec \"$SHELL\" -l") } ?? ""
        if let sshArgs, !sshArgs.isEmpty { return "ssh -t " + sshArgs + remote }
        guard isConnected else { return nil }
        return "ssh -t -S " + shellQuote(controlPath) + " -o ControlMaster=no solanum-remote" + remote
    }

    deinit { readyTimer?.invalidate() }

    func start() {
        readyTimer?.invalidate()
        readyTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            guard self.isConnected else { return }
            t.invalidate()
            self.readyTimer = nil
            self.refresh()
        }
    }

    /// Re-reads user@host, home and the remote shell's folder; calls `onChange` when any of them changed.
    func refresh() {
        guard isConnected else { return }
        if probing { probeAgain = true; return }
        probing = true
        run(Self.probeScript) { [weak self] status, out, _ in
            guard let self else { return }
            self.probing = false
            if status == 0 {
                let lines = String(decoding: out, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                let label = lines.first.flatMap { $0.isEmpty ? nil : $0 }
                let home = lines.count > 1 && !lines[1].isEmpty ? lines[1] : nil
                let cwd = lines.count > 2 && lines[2].hasPrefix("/") ? lines[2] : nil
                if label != self.hostLabel || home != self.home || (cwd != nil && cwd != self.cwd) {
                    self.hostLabel = label
                    self.home = home
                    if let cwd { self.cwd = cwd }
                    self.onChange?()
                }
            }
            if self.probeAgain {
                self.probeAgain = false
                self.refresh()
            }
        }
    }

    /// Prints user@host, $HOME, then the folder of the session's interactive shell: walk up from this
    /// command to the per-connection sshd, then take its child whose stdin is a pty.
    private static let probeScript = #"""
    h=$(hostname 2>/dev/null || uname -n)
    printf '%s@%s\n%s\n' "$(id -un 2>/dev/null)" "${h%%.*}" "$HOME"
    p=$$
    while [ "$p" -gt 1 ] 2>/dev/null; do
      case $(cat /proc/$p/comm 2>/dev/null) in sshd*) break ;; '') p=0; break ;; esac
      p=$(sed 's/.*) [A-Za-z] \([0-9]*\).*/\1/' /proc/$p/stat 2>/dev/null)
    done
    if [ "$p" -gt 1 ] 2>/dev/null; then
      kids=$(cat /proc/$p/task/*/children 2>/dev/null)
      [ -n "$kids" ] || kids=$(pgrep -P "$p" 2>/dev/null)
      for k in $kids; do
        case $(readlink /proc/$k/fd/0 2>/dev/null) in /dev/pts/*) readlink /proc/$k/cwd 2>/dev/null; break ;; esac
      done
    fi
    """#

    // MARK: Running commands

    fileprivate func sshProcess(_ script: String) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        // The host name is a placeholder: with -S the command goes straight to the existing master.
        p.arguments = ["-S", controlPath, "-o", "ControlMaster=no", "-o", "BatchMode=yes", "-o", "LogLevel=ERROR",
                       "-o", "RemoteCommand=none", "-T", "solanum-remote", "sh -c " + shellQuote(script)]
        return p
    }

    /// Runs a POSIX sh script on the host; `done` gets (exit status, stdout, stderr) on the main queue.
    func run(_ script: String, input: Data? = nil, timeout: TimeInterval = 60,
             _ done: @escaping (Int32, Data, String) -> Void) {
        guard isConnected else {
            done(255, Data(), "The ssh session has ended.")
            return
        }
        let p = sshProcess(script)
        let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        p.standardInput = inPipe
        DispatchQueue.global(qos: .userInitiated).async {
            do { try p.run() } catch {
                DispatchQueue.main.async { done(255, Data(), error.localizedDescription) }
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { p.terminate() } }
            let group = DispatchGroup()
            var out = Data(), err = Data()
            group.enter()
            DispatchQueue.global().async { out = outPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
            group.enter()
            DispatchQueue.global().async { err = errPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
            if let input { try? inPipe.fileHandleForWriting.write(contentsOf: input) }
            try? inPipe.fileHandleForWriting.close()
            group.wait()
            p.waitUntilExit()
            let status = p.terminationStatus
            let errText = String(decoding: err, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async { done(status, out, errText) }
        }
    }

    private func check(_ status: Int32, _ err: String, _ fallback: String) -> Error? {
        guard status != 0 else { return nil }
        return FileError(message: err.isEmpty ? fallback : err)
    }

    func list(_ dir: String, _ done: @escaping (Result<[FileItem], Error>) -> Void) {
        let script = """
        cd \(shellQuote(dir)) || exit 1
        for f in * .[!.]* ..?*; do
          [ -e "$f" ] || [ -L "$f" ] || continue
          if [ -d "$f" ]; then printf 'd/%s\\0' "$f"; else printf 'f/%s\\0' "$f"; fi
        done
        """
        run(script) { [weak self] status, out, err in
            if let e = self?.check(status, err, "Couldn't list \(dir).") { return done(.failure(e)) }
            let items = out.split(separator: 0).compactMap { raw -> FileItem? in
                let s = String(decoding: raw, as: UTF8.self)
                guard s.count > 2 else { return nil }
                let name = String(s.dropFirst(2))
                return FileItem(name: name, path: FilePaths.join(dir, name), isDirectory: s.hasPrefix("d"))
            }
            done(.success(items))
        }
    }

    func read(_ path: String, limit: Int, _ done: @escaping (Result<Data, Error>) -> Void) {
        let script = """
        f=\(shellQuote(path))
        [ -f "$f" ] || { echo "Not a regular file." >&2; exit 1; }
        s=$(wc -c < "$f" | tr -d ' ')
        [ "$s" -le \(limit) ] || { echo "This file is too large to open ($((s / 1048576)) MB)." >&2; exit 1; }
        cat -- "$f"
        """
        run(script) { [weak self] status, out, err in
            if let e = self?.check(status, err, "Couldn't read \(path).") { return done(.failure(e)) }
            done(.success(out))
        }
    }

    /// The size on the first line, then the bytes; only the part asked for crosses the connection.
    func readPart(_ path: String, from offset: Int?, whole: Int, tail: Int, _ done: @escaping (Result<FilePart, Error>) -> Void) {
        let part = offset.map { "tail -c +\($0 + 1) -- \"$f\" | head -c \(tail)" }
            ?? "if [ \"$s\" -le \(whole) ]; then cat -- \"$f\"; else tail -c \(tail) -- \"$f\"; fi"
        let script = """
        f=\(shellQuote(path))
        [ -f "$f" ] || { echo "Not a regular file." >&2; exit 1; }
        s=$(wc -c < "$f" | tr -d ' ')
        printf '%s\\n' "$s"
        \(part)
        """
        run(script, timeout: 600) { [weak self] status, out, err in
            if let e = self?.check(status, err, "Couldn't read \(path).") { return done(.failure(e)) }
            guard let nl = out.firstIndex(of: 0x0A), let size = Int(String(decoding: out[..<nl], as: UTF8.self)) else {
                return done(.failure(FileError(message: "Couldn't read \(path).")))
            }
            done(.success(FilePart(size: size, data: Data(out[out.index(after: nl)...]))))
        }
    }

    /// `cat >` rewrites the existing file in place, so its permissions and owner are kept.
    func write(_ data: Data, to path: String, _ done: @escaping (Error?) -> Void) {
        run("cat > \(shellQuote(path))", input: data) { [weak self] status, _, err in
            done(self?.check(status, err, "Couldn't save \(path)."))
        }
    }

    func perform(_ op: FileOp, _ done: @escaping (Error?) -> Void) {
        let noClobber: (String) -> String = { "[ -e \(shellQuote($0)) ] && { echo \(shellQuote("“\(($0 as NSString).lastPathComponent)” already exists.")) >&2; exit 1; }\n" }
        let script: String
        switch op {
        case .delete(let paths): script = "rm -rf -- " + paths.map(shellQuote).joined(separator: " ")
        case .move(let from, let to): script = noClobber(to) + "mv -- \(shellQuote(from)) \(shellQuote(to))"
        case .copy(let from, let to): script = noClobber(to) + "cp -Rp -- \(shellQuote(from)) \(shellQuote(to))"
        case .makeDirectory(let p): script = "mkdir -- \(shellQuote(p))"
        case .makeFile(let p): script = noClobber(p) + ": > \(shellQuote(p))"
        }
        run(script) { [weak self] status, _, err in
            done(self?.check(status, err, "The operation failed."))
        }
    }

}

// MARK: - Transfers between file systems

/// Copies between two file systems (this Mac and an ssh host, or two hosts) by streaming tar, so whole
/// folders go in one go. Between two hosts the files are staged on this Mac (see `relay`). The copy is unpacked in a hidden temporary folder next to its
/// destination and only then renamed into place, so a failed transfer never leaves a partial file under the
/// real name, and an existing item is never overwritten.
enum FileTransfer {
    static func copy(_ path: String, from src: FileSystem, into dir: String, as name: String, on dst: FileSystem,
                     _ done: @escaping (Error?) -> Void) {
        if src is RemoteSession, dst is RemoteSession { return relay(path, from: src, into: dir, as: name, on: dst, done) }
        let parent = FilePaths.parent(path), base = (path as NSString).lastPathComponent
        let target = FilePaths.join(dir, name)
        let unpack = """
        [ -e \(shellQuote(target)) ] && { echo \(shellQuote("“\(name)” already exists.")) >&2; exit 1; }
        t=$(mktemp -d \(shellQuote(FilePaths.join(dir, ".solanum-XXXXXX")))) || exit 1
        if tar -xf - -C "$t" && mv -- "$t/"\(shellQuote(base)) \(shellQuote(target)); then rmdir "$t"; else rm -rf "$t"; exit 1; fi
        """
        let reader: Process, writer: Process
        switch src {
        case let remote as RemoteSession:
            guard remote.isConnected else { return done(FileError(message: "The ssh session has ended.")) }
            reader = remote.sshProcess("tar -C \(shellQuote(parent)) -cf - \(shellQuote(base))")
        default:
            reader = tarProcess(["-cf", "-", "-C", parent, base])
        }
        switch dst {
        case let remote as RemoteSession:
            guard remote.isConnected else { return done(FileError(message: "The ssh session has ended.")) }
            writer = remote.sshProcess(unpack)
        default:
            writer = Process()
            writer.executableURL = URL(fileURLWithPath: "/bin/sh")
            writer.arguments = ["-c", unpack]
        }
        pipe(reader, writer, done)
    }

    /// Host to host: down into a fresh folder under the staging folder (Settings › Preferences), back up
    /// from there, then the staged copy is deleted whether or not the upload worked.
    private static func relay(_ path: String, from src: FileSystem, into dir: String, as name: String, on dst: FileSystem,
                              _ done: @escaping (Error?) -> Void) {
        let stage = Config.shared.transferStagingDir.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        } catch {
            return done(FileError(message: "Couldn't create the staging folder \(stage.deletingLastPathComponent().path): \(error.localizedDescription)"))
        }
        let base = (path as NSString).lastPathComponent
        let local = LocalFileSystem.shared
        func finish(_ error: Error?) {
            try? FileManager.default.removeItem(at: stage)
            done(error)
        }
        copy(path, from: src, into: stage.path, as: base, on: local) { error in
            if let error { return finish(error) }
            copy(FilePaths.join(stage.path, base), from: local, into: dir, as: name, on: dst, finish)
        }
    }

    /// Mac tar without the AppleDouble (._*) files and extended attributes other systems trip over.
    private static func tarProcess(_ args: [String]) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        p.arguments = ["--no-mac-metadata", "--no-xattrs"] + args
        var env = ProcessInfo.processInfo.environment
        env["COPYFILE_DISABLE"] = "1"
        p.environment = env
        return p
    }

    private static func text(_ pipe: Pipe) -> String {
        String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").filter { !$0.contains("Error exit delayed") }.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func pipe(_ from: Process, _ to: Process, _ done: @escaping (Error?) -> Void) {
        let link = Pipe(), errFrom = Pipe(), errTo = Pipe()
        from.standardOutput = link
        to.standardInput = link
        from.standardError = errFrom
        to.standardError = errTo
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try to.run()
                try from.run()
            } catch {
                if to.isRunning { to.terminate() }
                DispatchQueue.main.async { done(error) }
                return
            }
            from.waitUntilExit()
            to.waitUntilExit()
            let (readErr, writeErr) = (text(errFrom), text(errTo))
            // Whichever end failed first: if the reader just lost its pipe, the writer gave up (e.g. the name
            // was taken); otherwise the writer's complaint (an empty archive) is only a consequence.
            let readerBroke = readErr.isEmpty || readErr.contains("Write error") || readErr.contains("Broken pipe")
            let err = from.terminationStatus != 0 && !readerBroke ? readErr : writeErr.isEmpty ? readErr : writeErr
            let failed = from.terminationStatus != 0 || to.terminationStatus != 0
            DispatchQueue.main.async { done(failed ? FileError(message: err.isEmpty ? "The transfer failed." : err) : nil) }
        }
    }
}

extension Notification.Name {
    /// Posted with a `FileSystem` as the object after items were added to or removed from it outside the
    /// sidebar doing the work; sidebars showing that file system refresh.
    static let solanumFilesChanged = Notification.Name("SolanumFilesChanged")
    /// An editor saved a file: `object` is its file system, `userInfo["path"]` its path.
    static let solanumFileSaved = Notification.Name("SolanumFileSaved")
}
