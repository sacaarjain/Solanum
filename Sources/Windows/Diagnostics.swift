import Foundation
import WinSDK

/// A log for chasing a problem that can't be reproduced on demand, as the Mac's: what files and ssh are doing (reads,
/// big files' windows, slow commands), when the window froze and for how long, and what happened when it crashed. Never
/// file contents, typed text or passwords: paths, sizes, timings and addresses only.
///
/// Off unless asked for, and then only for a while: the palette's "Turn On Diagnostics for a Day" (settings key
/// `diagnostics-until`), or SOLANUM_DIAGNOSTICS=1 for a dev run. Written to %LOCALAPPDATA%\Solanum\Logs\diagnostics-<day>.log.
/// Each line is handed to Windows as `log` returns, so it's on disk whatever happens to Solanum next; a crash itself is
/// written by the unhandled-exception filter, and the next launch says if the last one didn't end normally, with what
/// Windows Error Reporting kept about it.
enum Diagnostics {
    private static let lock = NSLock()
    private static var on = false
    private static var file: HANDLE?
    private static var fileDay = ""

    static var enabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return on
    }

    static var folder: String {
        let base = ProcessInfo.processInfo.environment["LOCALAPPDATA"] ?? NSTemporaryDirectory()
        return base + "\\Solanum\\Logs"
    }

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static var path: String { folder + "\\diagnostics-\(dayFormat.string(from: Date())).log" }

    /// Until when it's on, from Settings; nil when it's off.
    static var until: Date? {
        guard let text = AppSettings.shared.file["diagnostics-until"], let t = Double(text) else { return nil }
        let d = Date(timeIntervalSince1970: t)
        return d > Date() ? d : nil
    }

    /// On for `hours` from now (0 turns it off), kept in Settings, from now on in this run too.
    static func turnOn(hours: Double) {
        AppSettings.shared.set("diagnostics-until", hours > 0 ? String(Int(Date().addingTimeInterval(hours * 3600).timeIntervalSince1970)) : "")
        refresh()
        if hours > 0 { log("diagnostics on for \(Int(hours)) h") }
    }

    /// Whether it's on, looked at again (at launch, and when Settings change).
    static func refresh() {
        let args = CommandLine.arguments
        // Never the self-tests: they run the same program, and would write into the user's log.
        let testing = args.contains("--selftest") || args.contains("--window-test")
        let wanted = !testing && (ProcessInfo.processInfo.environment["SOLANUM_DIAGNOSTICS"] != nil || until != nil)
        lock.lock()
        let was = on
        on = wanted
        lock.unlock()
        if wanted && !was { started() }
    }

    /// One line, timestamped, on disk when this returns (the text is only built when it's on).
    static func log(_ text: @autoclosure () -> String) {
        guard enabled else { return }
        let body = text()
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        write("\(stamp.string(from: now)) \(Thread.isMainThread ? "" : "[bg] ")\(body)\r\n", day: dayFormat.string(from: now))
    }

    /// Appends to the day's file, opening it (a new one each day). With the lock held.
    private static func write(_ line: String, day: String) {
        if file == nil || day != fileDay {
            if let file { CloseHandle(file) }
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            let h = wide(folder + "\\diagnostics-\(day).log").withUnsafeBufferPointer {
                CreateFileW($0.baseAddress, DWORD(FILE_APPEND_DATA), DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE), nil, DWORD(OPEN_ALWAYS), DWORD(FILE_ATTRIBUTE_NORMAL), nil)
            }
            file = h == INVALID_HANDLE_VALUE ? nil : h
            fileDay = day
        }
        guard let file else { return }
        let bytes = Array(line.utf8)
        var wrote: DWORD = 0
        _ = bytes.withUnsafeBufferPointer { WriteFile(file, $0.baseAddress, DWORD($0.count), &wrote, nil) }
    }

    /// Milliseconds since `start`, for "took N ms".
    static func ms(_ start: Date) -> Int { Int(Date().timeIntervalSince(start) * 1000) }

    // MARK: Launch, quit and crashes

    private static var runningMarker: String { folder + "\\.running" }

    private static func started() {
        log("diagnostics on: Solanum for Windows, pid \(GetCurrentProcessId()), until \(until.map { "\($0)" } ?? "this run ends")")
        lastSessionCheck()
        installCrashFilter()
        startWatchdog()
    }

    /// At a normal quit: the next launch doesn't take it for a crash.
    static func quitting() {
        guard enabled else { return }
        log("quit normally")
        try? FileManager.default.removeItem(atPath: runningMarker)
    }

    /// The last session didn't quit normally (its marker's still there): what Windows Error Reporting kept of it, if
    /// anything. Then this session's marker.
    private static func lastSessionCheck() {
        let fm = FileManager.default
        if let marker = try? String(contentsOfFile: runningMarker, encoding: .utf8) {
            let parts = marker.split(separator: " ")
            let pid = parts.first.flatMap { DWORD($0) } ?? 0
            let started = parts.dropFirst().first.flatMap { Double($0) }.map { Date(timeIntervalSince1970: $0) } ?? .distantPast
            if pid != 0, pid != GetCurrentProcessId(), let h = OpenProcess(DWORD(PROCESS_QUERY_LIMITED_INFORMATION), false, pid) {
                var code: DWORD = 0
                let alive = GetExitCodeProcess(h, &code) && code == DWORD(STILL_ACTIVE)
                CloseHandle(h)
                if alive { log("another Solanum (pid \(pid)) is running too") }
            } else {
                let reports = (ProcessInfo.processInfo.environment["LOCALAPPDATA"] ?? "") + "\\Microsoft\\Windows\\WER\\ReportArchive"
                let found = ((try? fm.contentsOfDirectory(atPath: reports)) ?? [])
                    .filter { $0.lowercased().contains("solanum") }
                    .map { reports + "\\" + $0 }
                    .filter { ((try? fm.attributesOfItem(atPath: $0))?[.modificationDate] as? Date ?? .distantPast) > started }
                if found.isEmpty {
                    log("LAST SESSION (pid \(pid)) didn't quit normally, and Windows kept no crash report: it was ended from Task Manager, killed, or the PC shut down. The lines above say what it was doing.")
                }
                for dir in found {
                    let report = dir + "\\Report.wer"
                    let text = (try? String(contentsOfFile: report, encoding: .utf16LittleEndian)) ?? (try? String(contentsOfFile: report, encoding: .utf8)) ?? ""
                    let keep = text.split(whereSeparator: \.isNewline).filter { $0.hasPrefix("Sig[") || $0.hasPrefix("EventType=") }.prefix(16)
                    log("LAST SESSION (pid \(pid)) CRASHED. Windows' report (\(report)):\n      " + keep.joined(separator: "\n      "))
                }
            }
        }
        try? fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? "\(GetCurrentProcessId()) \(Date().timeIntervalSince1970)".write(toFile: runningMarker, atomically: true, encoding: .utf8)
    }

    /// A crash: its exception and where, with the stack as module+offset (to look up against the build's symbols).
    private static func installCrashFilter() {
        _ = SetUnhandledExceptionFilter { info in
            guard let record = info?.pointee.ExceptionRecord?.pointee else { return EXCEPTION_CONTINUE_SEARCH }
            var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 48)
            let n = Int(RtlCaptureStackBackTrace(0, DWORD(frames.count), &frames, nil))
            let stack = frames.prefix(n).compactMap { $0 }.map { "      " + Diagnostics.place(of: $0) }.joined(separator: "\n")
            Diagnostics.log("CRASH: exception 0x" + String(UInt32(bitPattern: Int32(bitPattern: record.ExceptionCode)), radix: 16)
                            + " at " + (record.ExceptionAddress.map { Diagnostics.place(of: $0) } ?? "?") + "\n" + stack)
            return EXCEPTION_CONTINUE_SEARCH
        }
    }

    /// An address as module+offset ("Solanum.exe+0x1a2b3c").
    static func place(of address: UnsafeMutableRawPointer) -> String {
        var module: HMODULE?
        let flags = DWORD(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT)
        guard GetModuleHandleExW(flags, address.assumingMemoryBound(to: WCHAR.self), &module), let module else { return "\(address)" }
        var name = [WCHAR](repeating: 0, count: 260)
        let length = Int(GetModuleFileNameW(module, &name, DWORD(name.count)))
        let file = String(decoding: name.prefix(length), as: UTF16.self).split(separator: "\\").last.map(String.init) ?? "?"
        let offset = UInt(bitPattern: address) &- UInt(bitPattern: UnsafeRawPointer(module))
        return "\(file)+0x\(String(offset, radix: 16))"
    }

    // MARK: Freezes

    /// When the window's thread last went round its loop (see `beat`).
    private static var lastBeat = Date()
    private static var frozenSince: Date?

    /// From the window's timer, ten times a second: still answering.
    static func beat() {
        guard enabled else { return }
        lock.lock()
        lastBeat = Date()
        let since = frozenSince
        frozenSince = nil
        lock.unlock()
        if let since { log("the window answers again, after \(ms(since)) ms stuck") }
    }

    /// A thread that notices the window's thread hasn't gone round its loop for 2 s, and says so.
    private static func startWatchdog() {
        let t = Thread {
            while true {
                Thread.sleep(forTimeInterval: 1)
                guard enabled else { continue }
                lock.lock()
                let quiet = Date().timeIntervalSince(lastBeat), already = frozenSince != nil
                if quiet > 2 && !already { frozenSince = lastBeat }
                lock.unlock()
                if quiet > 2 && !already { log("FREEZE: the window hasn't answered for \(Int(quiet * 1000)) ms") }
            }
        }
        t.name = "solanum.diagnostics.watchdog"
        t.start()
    }
}
