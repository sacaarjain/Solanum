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

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
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
        process.executableURL = URL(fileURLWithPath: String(decodingCString: path, as: UTF16.self))
        // Never a second question about the host's identity: the terminal's connection has settled that by now.
        process.arguments = ["-T", "-o", "BatchMode=no", "-o", "NumberOfPasswordPrompts=1", "-o", "StrictHostKeyChecking=yes",
                             "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3"] + target + ["sh"]
        var env = ProcessInfo.processInfo.environment
        var exe = [UInt16](repeating: 0, count: 1024)
        _ = GetModuleFileNameW(nil, &exe, DWORD(exe.count))
        env["SSH_ASKPASS"] = String(decodingCString: exe, as: UTF16.self)
        env["SSH_ASKPASS_REQUIRE"] = "force"
        env["SOLANUM_ASKPASS"] = "1"
        env["SOLANUM_ASKPASS_PIPE"] = askpassPipe
        env["SOLANUM_ASKPASS_TOKEN"] = token
        process.environment = env
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] proc in
            self?.finish(.failed(proc.terminationStatus == 255 ? "Couldn't connect or sign in." : "The connection closed."))
        }
    }

    func start() {
        do { try process.run() } catch {
            finish(.failed("Couldn't start ssh."))
            return
        }
        Thread.detachNewThread { [weak self] in self?.read() }
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
        if process.isRunning { process.terminate() }
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

    private func read() {
        let handle = output.fileHandleForReading
        while true {
            let data = handle.availableData
            if data.isEmpty { break }
            lock.lock()
            buffer += String(decoding: data, as: UTF8.self)
            var finished: ((String?, Int32) -> Void, String, Int32)?
            if let current = waiting, let range = buffer.range(of: current.marker) {
                let body = String(buffer[..<range.lowerBound])
                let rest = buffer[range.upperBound...]
                let line = rest.prefix { $0 != "\n" }
                let code = Int32(line.trimmingCharacters(in: .whitespaces)) ?? -1
                buffer = rest.contains("\n") ? String(rest[rest.index(after: rest.firstIndex(of: "\n")!)...]) : ""
                waiting = nil
                finished = (current.done, body, code)
            }
            lock.unlock()
            if let finished { finished.0(finished.1, finished.2) }
        }
    }

    /// Runs a command on the host, one at a time, and hands back what it printed and its exit status (nil if the connection
    /// failed or it took too long).
    private func run(_ command: String, timeout: TimeInterval = 15, _ done: @escaping (String?, Int32) -> Void) {
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
            self.input.fileHandleForWriting.write(Data(line.utf8))
            if finished.wait(timeout: .now() + timeout) == .timedOut {
                self.lock.lock()
                self.waiting = nil
                self.lock.unlock()
            }
            done(result.0, result.1)
        }
    }

    /// The folder's contents on the host, or nil if it can't be read.
    func list(_ folder: String, _ done: @escaping ([FileEntry]?) -> Void) {
        guard state == .ready else { return done(nil) }
        run("cd -- \(Self.quote(folder)) 2>/dev/null && LC_ALL=C ls -1Ap 2>/dev/null") { text, code in
            guard let text, code == 0 else { return done(nil) }
            done(Self.entries(fromListing: text, in: folder))
        }
    }

    /// `ls -1Ap`'s output as entries: a trailing slash marks a folder.
    static func entries(fromListing text: String, in folder: String) -> [FileEntry] {
        text.split(separator: "\n").compactMap { raw in
            let line = String(raw).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            guard !line.isEmpty else { return nil }
            let isFolder = line.hasSuffix("/")
            let name = isFolder ? String(line.dropLast()) : line
            guard name != "." && name != ".." && !name.isEmpty else { return nil }
            return FileEntry(name: name, path: AnyPath.join(folder, name), isDirectory: isFolder, isHidden: name.hasPrefix("."))
        }
    }
}
