import Foundation

/// A log for chasing a problem the user can't reproduce on demand: what files open over ssh are doing (updates, reads,
/// scrolling), where the app is stuck when it freezes, and what happened when it crashed. Never file contents, typed
/// text or passwords: paths, sizes, timings and stacks only.
///
/// Off unless asked for, and then only for a while: `defaults write local.solanum.terminal solanum.diagnostics.until
/// -date "<when>"` (or SOLANUM_DIAGNOSTICS=1, or a folder to write to, for a dev run). Written to
/// ~/Library/Logs/Solanum/diagnostics-<day>.log. Beside it: diagnostics-<time>-hang.txt for a freeze (a `sample` of
/// the app while it's stuck), and a copy of macOS's crash report for a crash.
///
/// Every line is on disk once `log` returns (it's appended with write(2), not buffered), so whatever led up to a
/// crash is there. A crash itself is written from the signal handler, with its stack (see `installCrashHandlers`); the
/// next launch adds what macOS's crash report says, or that there wasn't one (a force quit, say).
enum Diagnostics {
    static let enabled: Bool = {
        // Never the self-test (it runs the same binary, and would write into the user's log).
        if CommandLine.arguments.contains("--selftest") { return false }
        if ProcessInfo.processInfo.environment["SOLANUM_DIAGNOSTICS"] != nil { return true }
        guard !Headless.active, let until = UserDefaults.standard.object(forKey: "solanum.diagnostics.until") as? Date else { return false }
        return until > Date()
    }()

    /// SOLANUM_DIAGNOSTICS=<folder> puts it there instead (a dev run).
    static let folder: String = {
        if let d = ProcessInfo.processInfo.environment["SOLANUM_DIAGNOSTICS"], d.hasPrefix("/") { return d }
        return NSHomeDirectory() + "/Library/Logs/Solanum"
    }()

    private static let lock = NSLock()
    /// The log, open for appending; also what the crash handler writes to (it can't open files).
    private static var fd: Int32 = -1
    private static var fdDay = ""
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static var path: String { folder + "/diagnostics-\(dayFormat.string(from: Date())).log" }

    /// One line, timestamped, on disk when this returns (the text is only built when it's on).
    static func log(_ text: @autoclosure () -> String) {
        guard enabled else { return }
        let body = text()
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        let line = "\(stamp.string(from: now)) \(Thread.isMainThread ? "" : "[bg] ")\(body)\n"
        // A new file each day.
        let day = dayFormat.string(from: now)
        if fd < 0 || day != fdDay {
            if fd >= 0 { close(fd) }
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            fd = open(folder + "/diagnostics-\(day).log", O_WRONLY | O_APPEND | O_CREAT, 0o644)
            fdDay = day
        }
        guard fd >= 0 else { return }
        line.utf8CString.withUnsafeBufferPointer { b in _ = write(fd, b.baseAddress, b.count - 1) }
    }

    /// Milliseconds since `start`, for "took N ms".
    static func ms(_ start: Date) -> Int { Int(Date().timeIntervalSince(start) * 1000) }

    /// At launch: the log opened, crashes caught, how the last session ended, and the freeze watchdog.
    static func start() {
        guard enabled else { return }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let commit = (Bundle.main.infoDictionary?["SolanumCommit"] as? String).map { String($0.prefix(7)) } ?? "?"
        log("diagnostics on: Solanum \(version) (\(commit)), pid \(getpid())")
        lastSessionCheck()
        installCrashHandlers()
        startWatchdog()
    }

    /// At a normal quit: the next launch doesn't take it for a crash.
    static func quitting() {
        guard enabled else { return }
        log("quit normally")
        try? FileManager.default.removeItem(atPath: runningMarker)
    }

    // MARK: Crashes

    private static var runningMarker: String { folder + "/.running" }

    /// The last session didn't quit normally (its marker's still there): what macOS's crash report says about it, if
    /// it wrote one (copied beside the log), or that there wasn't one. Then this session's marker.
    private static func lastSessionCheck() {
        let fm = FileManager.default
        if let marker = try? String(contentsOfFile: runningMarker, encoding: .utf8) {
            let parts = marker.split(separator: " ")
            let pid = parts.first.flatMap { Int32($0) } ?? 0
            let started = parts.dropFirst().first.flatMap { Double($0) }.map { Date(timeIntervalSince1970: $0) } ?? .distantPast
            // Still running (a second copy of the app): not a crash.
            if pid > 0, pid != getpid(), kill(pid, 0) == 0 {
                log("another Solanum (pid \(pid)) is running too")
            } else {
                let reports = NSHomeDirectory() + "/Library/Logs/DiagnosticReports"
                let found = ((try? fm.contentsOfDirectory(atPath: reports)) ?? [])
                    .filter { $0.hasPrefix("Solanum") && $0.hasSuffix(".ips") }
                    .compactMap { name -> (String, Date)? in
                        let p = reports + "/" + name
                        guard let d = (try? fm.attributesOfItem(atPath: p))?[.modificationDate] as? Date, d > started else { return nil }
                        return (p, d)
                    }
                    .sorted { $0.1 < $1.1 }
                if found.isEmpty {
                    log("LAST SESSION (pid \(pid)) didn't quit normally, and macOS wrote no crash report: it was force quit, killed, or the Mac shut down. The lines above say what it was doing.")
                }
                for (p, _) in found {
                    let copy = folder + "/" + (p as NSString).lastPathComponent
                    try? fm.removeItem(atPath: copy)
                    try? fm.copyItem(atPath: p, toPath: copy)
                    log("LAST SESSION (pid \(pid)) CRASHED. macOS's report (copied to \(copy)):\n" + summarize(report: p))
                }
            }
        }
        try? fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? "\(getpid()) \(Date().timeIntervalSince1970)".write(toFile: runningMarker, atomically: true, encoding: .utf8)
    }

    /// The exception, and the crashed thread's stack, from a macOS crash report (.ips: a JSON header line, then JSON).
    static func summarize(report path: String) -> String {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8), let nl = raw.firstIndex(of: "\n"),
              let body = try? JSONSerialization.jsonObject(with: Data(raw[raw.index(after: nl)...].utf8)) as? [String: Any] else {
            return "    (couldn't read it)"
        }
        var out: [String] = []
        if let e = body["exception"] as? [String: Any] {
            out.append("    exception: \(e["type"] ?? "?") \(e["signal"] ?? "") \(e["subtype"] ?? "")")
        }
        if let t = body["termination"] as? [String: Any], let why = t["indicator"] ?? t["reasons"] { out.append("    termination: \(why)") }
        if let info = body["asi"] { out.append("    message: \(info)") }
        let images = body["usedImages"] as? [[String: Any]] ?? []
        if let threads = body["threads"] as? [[String: Any]] {
            let n = body["faultingThread"] as? Int ?? 0
            if threads.indices.contains(n), let frames = threads[n]["frames"] as? [[String: Any]] {
                out.append("    crashed thread \(n)\((threads[n]["queue"] as? String).map { " (\($0))" } ?? ""):")
                for f in frames.prefix(25) {
                    let image = (f["imageIndex"] as? Int).flatMap { images.indices.contains($0) ? images[$0]["name"] as? String : nil } ?? "?"
                    let symbol = f["symbol"] as? String ?? "0x" + String(f["imageOffset"] as? Int ?? 0, radix: 16)
                    out.append("      \(image)  \(symbol)")
                }
            }
        }
        return out.joined(separator: "\n")
    }

    private static let fatalSignals: [Int32] = [SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGABRT, SIGFPE]

    /// A crash (a Swift runtime trap is SIGTRAP, a bad memory access SIGSEGV or SIGBUS, an abort SIGABRT) writes its
    /// signal and stack to the log before the app goes; then macOS's own crash reporting carries on as usual. And an
    /// Objective-C exception nobody caught, with its message.
    private static func installCrashHandlers() {
        // Its own stack, so a stack overflow can still be reported.
        let size = 128 * 1024
        var alt = stack_t(ss_sp: UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16), ss_size: size, ss_flags: 0)
        sigaltstack(&alt, nil)
        for sig in fatalSignals {
            var action = sigaction()
            action.__sigaction_u.__sa_handler = { sig in Diagnostics.crashed(signal: sig) }
            action.sa_flags = SA_ONSTACK
            sigemptyset(&action.sa_mask)
            sigaction(sig, &action, nil)
        }
        NSSetUncaughtExceptionHandler { e in
            Diagnostics.log("CRASH: an uncaught exception, \(e.name.rawValue): \(e.reason ?? "")\n" + e.callStackSymbols.prefix(30).map { "      " + $0 }.joined(separator: "\n"))
        }
    }

    /// In the signal handler: only async-signal-safe calls (write, backtrace_symbols_fd), to the already open log.
    private static func crashed(signal sig: Int32) {
        let f = fd
        if f >= 0 {
            let name: StaticString
            switch sig {
            case SIGTRAP: name = "\nCRASH: SIGTRAP (a Swift runtime check failed: see the stack, and macOS's report on the next launch)\n"
            case SIGSEGV: name = "\nCRASH: SIGSEGV (a bad memory access)\n"
            case SIGBUS: name = "\nCRASH: SIGBUS (a bad memory access)\n"
            case SIGABRT: name = "\nCRASH: SIGABRT (aborted)\n"
            case SIGILL: name = "\nCRASH: SIGILL\n"
            default: name = "\nCRASH: a fatal signal\n"
            }
            _ = write(f, name.utf8Start, name.utf8CodeUnitCount)
            var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 64)
            let n = backtrace(&frames, 64)
            backtrace_symbols_fd(&frames, n, f)
        }
        // On to the default: the crash goes on as it would have (and macOS reports it).
        signal(sig, SIG_DFL)
        raise(sig)
    }

    // MARK: Freezes

    private static let beatLock = NSLock()
    private static var lastBeat = Date()
    private static var lastSample = Date.distantPast

    /// Watches the main thread from another: a stall past 250 ms is logged when it ends, and one past 1.5 s is sampled
    /// while it's still going (at most once a minute), which shows exactly what it's stuck in.
    private static func startWatchdog() {
        let t = Thread {
            var stalledSince: Date?
            var sampled = false
            while true {
                beatLock.lock(); let beat = lastBeat; beatLock.unlock()
                let gap = Date().timeIntervalSince(beat)
                if gap > 0.25 {
                    if stalledSince == nil { stalledSince = beat; sampled = false }
                    if gap > 1.5, !sampled, Date().timeIntervalSince(lastSample) > 60 {
                        sampled = true
                        lastSample = Date()
                        sample()
                    }
                } else if let since = stalledSince {
                    log("FREEZE: the app didn't respond for \(Int(beat.timeIntervalSince(since) * 1000 + 100)) ms")
                    stalledSince = nil
                }
                DispatchQueue.main.async {
                    beatLock.lock(); lastBeat = Date(); beatLock.unlock()
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        t.name = "solanum.diagnostics.watchdog"
        t.start()
    }

    /// 3 seconds of `sample` on this process, while it's frozen.
    private static func sample() {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        let out = folder + "/diagnostics-\(f.string(from: Date()))-hang.txt"
        log("FREEZE: stuck for over 1.5 s; sampling it to \(out)")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        p.arguments = [String(getpid()), "3", "-file", out]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }
}

/// `SOLANUM_TRACE_STARTUP=1`: how long each launch step took, to stderr.
enum StartupTrace {
    private static let on = ProcessInfo.processInfo.environment["SOLANUM_TRACE_STARTUP"] != nil
    private static var last = ProcessInfo.processInfo.systemUptime
    static func mark(_ step: String) {
        guard on else { return }
        let now = ProcessInfo.processInfo.systemUptime
        FileHandle.standardError.write(String(format: "startup %6.1f ms  %@\n", (now - last) * 1000, step).data(using: .utf8)!)
        last = now
    }
}
