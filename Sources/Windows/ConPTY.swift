import Foundation
import WinSDK

/// A program running in a pseudoconsole: Windows' counterpart of `PTYProcess`. Its output arrives as UTF-8 on a thread
/// of its own, and everything it starts is in a job, so closing the pane stops the whole tree.
final class ConPTY {
    /// Called on the reading thread.
    var onData: ((UnsafeBufferPointer<UInt8>) -> Void)?
    /// Called on a background thread with the exit code, after the last output has been delivered.
    var onExit: ((Int32) -> Void)?

    private var console: HPCON?
    private var inputWrite: HANDLE?
    private var outputRead: HANDLE?
    private var process: HANDLE?
    private var job: HANDLE?
    private var attributes: UnsafeMutableRawPointer?
    private let writeQueue = DispatchQueue(label: "solanum.conpty.write")
    private let lock = NSLock()
    private var consoleClosed = false
    private let readingDone = DispatchSemaphore(value: 0)

    /// PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, a function-like macro in the SDK.
    private static let pseudoconsoleAttribute: DWORD_PTR = 0x0002_0016

    /// `extraEnvironment` is added to what this process has.
    init?(commandLine: String, extraEnvironment: [String: String] = [:], cwd: String? = nil, cols: Int, rows: Int) {
        var inputRead: HANDLE?, outputWrite: HANDLE?
        guard CreatePipe(&inputRead, &inputWrite, nil, 0) else { return nil }
        guard CreatePipe(&outputRead, &outputWrite, nil, 0) else {
            Self.close(&inputRead)
            Self.close(&inputWrite)
            return nil
        }
        let result = CreatePseudoConsole(Self.size(cols, rows), inputRead, outputWrite, 0, &console)
        // The console has its own copies of these ends. Holding ours would keep reads from ever ending.
        Self.close(&inputRead)
        Self.close(&outputWrite)
        guard result >= 0, launch(commandLine, extraEnvironment, cwd) else {
            shutDownAfterFailedStart()
            return nil
        }
    }

    deinit {
        Self.close(&inputWrite)
        Self.close(&outputRead)
        Self.close(&process)
        Self.close(&job)
        freeAttributes()
    }

    private func launch(_ commandLine: String, _ extra: [String: String], _ cwd: String?) -> Bool {
        var size: SIZE_T = 0
        _ = InitializeProcThreadAttributeList(nil, 1, 0, &size)
        let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        attributes = memory
        let list = OpaquePointer(memory)
        guard InitializeProcThreadAttributeList(list, 1, 0, &size),
              UpdateProcThreadAttribute(list, 0, Self.pseudoconsoleAttribute, console,
                                        SIZE_T(MemoryLayout<HPCON>.size), nil, nil) else { return false }

        var info = STARTUPINFOEXW()
        info.StartupInfo.cb = DWORD(MemoryLayout<STARTUPINFOEXW>.size)
        info.lpAttributeList = list
        var created = PROCESS_INFORMATION()
        var command = Array(commandLine.utf16) + [0]
        var environment = Self.environmentBlock(extra)
        // Suspended until it's in the job, so nothing it starts can slip out.
        let flags = DWORD(EXTENDED_STARTUPINFO_PRESENT) | DWORD(CREATE_UNICODE_ENVIRONMENT) | DWORD(CREATE_SUSPENDED)
        let started = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: STARTUPINFOW.self, capacity: 1) { startup in
                let directory = cwd.map { Array($0.utf16) + [0] }
                return directory.withOptionalPointer { dir in
                    CreateProcessW(nil, &command, nil, nil, false, flags, &environment, dir, startup, &created)
                }
            }
        }
        guard started else { return false }
        process = created.hProcess
        job = Self.makeJob()
        if let job { _ = AssignProcessToJobObject(job, created.hProcess) }
        _ = ResumeThread(created.hThread)
        _ = CloseHandle(created.hThread)
        startThreads()
        return true
    }

    private func startThreads() {
        Thread.detachNewThread { [self] in
            var buffer = [UInt8](repeating: 0, count: 256 * 1024)
            while true {
                var count: DWORD = 0
                let read = buffer.withUnsafeMutableBytes { ReadFile(outputRead, $0.baseAddress, DWORD($0.count), &count, nil) }
                guard read, count > 0 else { break }
                buffer.withUnsafeBufferPointer { onData?(UnsafeBufferPointer(rebasing: $0[..<Int(count)])) }
            }
            readingDone.signal()
        }
        Thread.detachNewThread { [self] in
            _ = WaitForSingleObject(process, INFINITE)
            var code: DWORD = 0
            _ = GetExitCodeProcess(process, &code)
            // Closing the console flushes what it still holds and then ends the reads.
            closeConsole()
            readingDone.wait()
            onExit?(Int32(truncatingIfNeeded: code))
        }
    }

    /// Writes in order, without blocking the caller when the program isn't reading.
    func write(_ bytes: [UInt8]) {
        writeQueue.async { [self] in
            var offset = 0
            while offset < bytes.count {
                var written: DWORD = 0
                let ok = bytes.withUnsafeBytes {
                    WriteFile(inputWrite, $0.baseAddress! + offset, DWORD(bytes.count - offset), &written, nil)
                }
                guard ok, written > 0 else { return }
                offset += Int(written)
            }
        }
    }

    func resize(cols: Int, rows: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard !consoleClosed, let console else { return }
        _ = ResizePseudoConsole(console, Self.size(cols, rows))
    }

    /// Stops the program and everything it started. `onExit` follows.
    func terminate() {
        if let job {
            _ = TerminateJobObject(job, 1)
        } else if let process {
            _ = TerminateProcess(process, 1)
        }
    }

    private func closeConsole() {
        lock.lock()
        defer { lock.unlock() }
        guard !consoleClosed else { return }
        consoleClosed = true
        if let console { ClosePseudoConsole(console) }
        console = nil
    }

    private func shutDownAfterFailedStart() {
        closeConsole()
        freeAttributes()
    }

    private func freeAttributes() {
        guard let attributes else { return }
        DeleteProcThreadAttributeList(OpaquePointer(attributes))
        attributes.deallocate()
        self.attributes = nil
    }

    private static func size(_ cols: Int, _ rows: Int) -> COORD {
        COORD(X: SHORT(clamping: max(cols, 1)), Y: SHORT(clamping: max(rows, 1)))
    }

    private static func close(_ handle: inout HANDLE?) {
        if let h = handle { _ = CloseHandle(h) }
        handle = nil
    }

    /// A job whose programs stop when its last handle closes, so they can't outlive Solanum.
    private static func makeJob() -> HANDLE? {
        guard let job = CreateJobObjectW(nil, nil) else { return nil }
        var limits = JOBOBJECT_EXTENDED_LIMIT_INFORMATION()
        limits.BasicLimitInformation.LimitFlags = DWORD(JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE)
        _ = SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits,
                                    DWORD(MemoryLayout<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>.size))
        return job
    }

    /// NUL-separated KEY=value pairs in the case-insensitive order Windows expects, ending in an extra NUL.
    private static func environmentBlock(_ extra: [String: String]) -> [UInt16] {
        var merged: [String: (key: String, value: String)] = [:]
        for (k, v) in ProcessInfo.processInfo.environment { merged[k.uppercased()] = (k, v) }
        for (k, v) in extra { merged[k.uppercased()] = (k, v) }
        var block: [UInt16] = []
        for name in merged.keys.sorted() {
            let entry = merged[name]!
            block += Array("\(entry.key)=\(entry.value)".utf16) + [0]
        }
        return block + [0]
    }
}

private extension Optional where Wrapped == [UInt16] {
    func withOptionalPointer<R>(_ body: (UnsafePointer<UInt16>?) -> R) -> R {
        switch self {
        case .some(let array): return array.withUnsafeBufferPointer { body($0.baseAddress) }
        case .none: return body(nil)
        }
    }
}
