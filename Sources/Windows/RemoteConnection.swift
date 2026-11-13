import Foundation
import WinSDK

/// The sidebar's own connection to the host a tab is ssh'd into. Windows' ssh can't share the terminal's connection, as
/// the Mac's does, so this is a second one, signed in with the same password (see Askpass) or the same key. It runs a
/// plain `sh` on the host and sends it commands, each answer ending in a marker line.
final class RemoteConnection {
    enum State: Equatable {
        case connecting, ready, failed(String)
    }

    let token = Askpass.makeToken()
    private(set) var state = State.connecting
    private(set) var home: String?
    var onChange: (() -> Void)?

    private var child: HiddenProcess?
    private let executable: String
    private let arguments: [String]
    private let environment: [String: String]
    /// What ssh said on its standard error, the last of it, to show why it failed. Never holds a password: those go
    /// through Askpass.
    private(set) var errorText = ""
    private let lock = NSLock()
    private var buffer = ""
    private var waiting: (marker: String, done: (String?, Int32) -> Void)?
    private var counter = 0
    private let queue = DispatchQueue(label: "solanum.remote")
    private let post: (@escaping () -> Void) -> Void

    /// The terminal's ssh arguments, minus what was only for an interactive session: a remote command, and -t.
    static func connectionArguments(_ args: [String]) -> [String]? {
        guard let destination = SSHHostList.destination(fromArguments: args), let at = args.firstIndex(of: destination) else { return nil }
        let options = args[..<at].filter { $0 != "-t" && $0 != "-tt" && $0 != "-T" }
        return Array(options) + [destination]
    }

    /// A string as one word for `sh`.
    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    init?(arguments: [String], askpassPipe: String, post: @escaping (@escaping () -> Void) -> Void) {
        var path = [UInt16](repeating: 0, count: Int(MAX_PATH))
        guard let target = Self.connectionArguments(arguments),
              SearchPathW(nil, Array("ssh.exe".utf16) + [0], nil, DWORD(path.count), &path, nil) > 0 else { return nil }
        self.post = post
        executable = String(decodingCString: path, as: UTF16.self)
        // The terminal's own options go first, as ssh takes the first of each. Then never a second question about the host's
        // identity, unless they said otherwise: the terminal's connection has settled that by now.
        self.arguments = ["-T"] + target.dropLast() + ["-o", "NumberOfPasswordPrompts=1", "-o", "StrictHostKeyChecking=yes",
                             "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3", target.last!, "sh"]
        var env: [String: String] = [:]
        var exe = [UInt16](repeating: 0, count: 1024)
        _ = GetModuleFileNameW(nil, &exe, DWORD(exe.count))
        env["SSH_ASKPASS"] = String(decodingCString: exe, as: UTF16.self)
        env["SSH_ASKPASS_REQUIRE"] = "force"
        env["SOLANUM_ASKPASS"] = "1"
        env["SOLANUM_ASKPASS_PIPE"] = askpassPipe
        env["SOLANUM_ASKPASS_TOKEN"] = token
        environment = env
    }

    func start() {
        // Started with no window: from Solanum, which has no console, ssh would otherwise open one of its own.
        guard let child = HiddenProcess(executable: executable, arguments: arguments, extraEnvironment: environment) else {
            return finish(.failed("Couldn't start ssh."))
        }
        child.onOutput = { [weak self] data in self?.receive(data) }
        child.onError = { [weak self] data in
            guard let self else { return }
            self.lock.lock()
            self.errorText = String((self.errorText + String(decoding: data, as: UTF8.self)).suffix(2000))
            self.lock.unlock()
        }
        child.onExit = { [weak self] status in
            guard let self else { return }
            self.lock.lock()
            let said = self.errorText.split(whereSeparator: \.isNewline).last.map(String.init)
            self.lock.unlock()
            self.finish(.failed(said ?? (status == 255 ? "Couldn't connect or sign in." : "The connection closed.")))
        }
        self.child = child
        run("printf '%s\\n' \"$HOME\"", timeout: 60) { [weak self] text, code in
            guard let self else { return }
            guard let text, code == 0, let home = text.split(separator: "\n").first.map(String.init), !home.isEmpty else {
                return self.finish(.failed("Couldn't connect or sign in."))
            }
            self.home = home
            self.set(.ready)
        }
    }

    func close() {
        child?.terminate()
    }

    deinit { close() }

    private func set(_ new: State) {
        post { [weak self] in
            guard let self, self.state != new else { return }
            self.state = new
            self.onChange?()
        }
    }

    private func finish(_ failure: State) {
        lock.lock()
        let pending = waiting
        waiting = nil
        lock.unlock()
        pending?.done(nil, -1)
        post { [weak self] in
            guard let self, case .failed = failure, self.state != failure else { return }
            if case .failed = self.state { return }
            self.state = failure
            self.onChange?()
        }
    }

    private func receive(_ data: Data) {
        lock.lock()
        buffer += String(decoding: data, as: UTF8.self)
        var finished: ((String?, Int32) -> Void, String, Int32)?
        // Only once the marker's whole line is here, status and all.
        if let current = waiting, let range = buffer.range(of: current.marker), let end = buffer[range.upperBound...].firstIndex(of: "\n") {
            let body = String(buffer[..<range.lowerBound])
            let code = Int32(buffer[range.upperBound..<end].trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
            buffer = String(buffer[buffer.index(after: end)...])
            waiting = nil
            finished = (current.done, body, code)
        }
        lock.unlock()
        if let finished { finished.0(finished.1, finished.2) }
    }

    /// Runs a command on the host, one at a time, and hands back what it printed and its exit status (nil if the connection
    /// failed or it took too long).
    func run(_ command: String, timeout: TimeInterval = 15, _ done: @escaping (String?, Int32) -> Void) {
        queue.async { [weak self] in
            guard let self else { return done(nil, -1) }
            let finished = DispatchSemaphore(value: 0)
            var result: (String?, Int32) = (nil, -1)
            self.lock.lock()
            self.counter += 1
            let marker = "__SOLANUM_DONE_\(self.counter)__ "
            self.waiting = (marker, { text, code in
                result = (text, code)
                finished.signal()
            })
            self.lock.unlock()
            let line = command + "; printf '\\n" + marker + "%d\\n' $?\n"
            let asked = Date()
            self.child?.write(Data(line.utf8))
            if finished.wait(timeout: .now() + timeout) == .timedOut {
                self.lock.lock()
                self.waiting = nil
                self.lock.unlock()
                Diagnostics.log("ssh: a command timed out after \(Int(timeout)) s: \(command.split(separator: " ").first ?? "")")
            } else if Diagnostics.ms(asked) > 1000 || result.1 != 0 {
                // What ran (its first word only: paths and arguments can say too much), how long, and how it ended.
                Diagnostics.log("ssh: \(command.split(separator: " ").first ?? "") took \(Diagnostics.ms(asked)) ms, exit \(result.1), \(result.0?.utf8.count ?? 0) bytes")
            }
            done(result.0, result.1)
        }
    }

    /// The folder of the terminal's shell on the host: the process carrying the session's tag (the login shell, if it can
    /// tell), or failing that the only login shell on a terminal. Nil when there's no telling, as on a host without /proc.
    func shellFolder(session: String, _ done: @escaping (String?) -> Void) {
        guard state == .ready, session.allSatisfy({ $0.isHexDigit }) else { return done(nil) }
        run(Self.shellFolderScript.replacingOccurrences(of: "@SESSION@", with: session)) { text, _ in
            let line = text?.split(separator: "\n").last.map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            done(line.flatMap { $0.hasPrefix("/") ? $0 : nil })
        }
    }

    static let shellFolderScript = #"""
    t='LC_SOLANUM_SESSION=@SESSION@'; best=; bestp=; only=; n=0
    for d in /proc/[0-9]*; do
      [ -O "$d" ] || continue
      case $(readlink "$d/fd/0" 2>/dev/null) in /dev/pts/*|/dev/pty*|/dev/cons*) ;; *) continue ;; esac
      p=${d#/proc/}
      pp=$(sed 's/.*) [A-Za-z] \([0-9]*\).*/\1/' "$d/stat" 2>/dev/null)
      case $(cat "/proc/$pp/comm" 2>/dev/null) in sshd*) login=1 ;; *) login= ;; esac
      if tr '\0' '\n' < "$d/environ" 2>/dev/null | grep -qxF "$t"; then
        c=$(readlink "$d/cwd" 2>/dev/null) || continue
        if [ -n "$login" ]; then best=$c; break; fi
        if [ -z "$bestp" ] || [ "$p" -lt "$bestp" ]; then bestp=$p; best=$c; fi
      elif [ -n "$login" ]; then
        n=$((n+1)); only=$(readlink "$d/cwd" 2>/dev/null)
      fi
    done
    if [ -n "$best" ]; then printf '%s\n' "$best"; elif [ "$n" = 1 ]; then printf '%s\n' "$only"; fi
    """#

    /// The folder's contents on the host, or nil if it can't be read.
    func list(_ folder: String, _ done: @escaping ([FileEntry]?) -> Void) {
        guard state == .ready else { return done(nil) }
        run("cd -- \(Self.quote(folder)) 2>/dev/null && LC_ALL=C ls -1ApL 2>/dev/null") { text, code in
            guard let text, code == 0 else { return done(nil) }
            done(Self.entries(fromListing: text, in: folder))
        }
    }

    /// `ls -1Ap`'s output as entries: a trailing slash marks a folder.
    static func entries(fromListing text: String, in folder: String) -> [FileEntry] {
        // By scalars: "\r\n" is one Character, which a split on "\n" would pass over.
        text.unicodeScalars.split(separator: "\n").compactMap { raw in
            let line = String(raw).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            guard !line.isEmpty else { return nil }
            let isFolder = line.hasSuffix("/")
            let name = isFolder ? String(line.dropLast()) : line
            guard name != "." && name != ".." && !name.isEmpty else { return nil }
            return FileEntry(name: name, path: AnyPath.join(folder, name), isDirectory: isFolder, isHidden: name.hasPrefix("."))
        }
    }
}
