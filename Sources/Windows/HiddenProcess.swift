import Foundation
import WinSDK

/// A console program run with no window and its standard handles as pipes: what Foundation's `Process` can't do from a
/// windowed app, where Windows would give each console program a console window of its own, in front of the user. It's in
/// a job, so it can't outlive Solanum, and it inherits only its three pipes.
final class HiddenProcess {
    /// Called on a thread of its own, as output comes.
    var onOutput: ((Data) -> Void)?
    var onError: ((Data) -> Void)?
    /// Called on another thread with the exit code, once its output has been read.
    var onExit: ((Int32) -> Void)?

    private var process: HANDLE?
    private var job: HANDLE?
    private var inputWrite: HANDLE?
    private var outputRead: HANDLE?
    private var errorRead: HANDLE?
    private let writeQueue = DispatchQueue(label: "solanum.hidden.write")

    /// PROC_THREAD_ATTRIBUTE_HANDLE_LIST, a function-like macro in the SDK.
    private static let handleListAttribute: DWORD_PTR = 0x0002_0002

    /// `extraEnvironment` is added to what this process has. Nil if it can't start.
    init?(executable: String, arguments: [String], extraEnvironment: [String: String]) {
        var security = SECURITY_ATTRIBUTES(nLength: DWORD(MemoryLayout<SECURITY_ATTRIBUTES>.size), lpSecurityDescriptor: nil, bInheritHandle: true)
        var inputRead: HANDLE?, outputWrite: HANDLE?, errorWrite: HANDLE?
        guard CreatePipe(&inputRead, &inputWrite, &security, 0) else { return nil }
        guard CreatePipe(&outputRead, &outputWrite, &security, 0), CreatePipe(&errorRead, &errorWrite, &security, 0) else {
            for var h in [inputRead, inputWrite, outputRead, outputWrite, errorRead] { Self.close(&h) }
            return nil
        }
        // Solanum's ends stay here.
        for h in [inputWrite, outputRead, errorRead] { _ = SetHandleInformation(h, DWORD(HANDLE_FLAG_INHERIT), 0) }
        defer { for var h in [inputRead, outputWrite, errorWrite] { Self.close(&h) } }

        let handles = UnsafeMutablePointer<HANDLE?>.allocate(capacity: 3)
        handles.initialize(from: [inputRead, outputWrite, errorWrite], count: 3)
        defer { handles.deallocate() }
        var size: SIZE_T = 0
        _ = InitializeProcThreadAttributeList(nil, 1, 0, &size)
        let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { memory.deallocate() }
        let list = OpaquePointer(memory)
        guard InitializeProcThreadAttributeList(list, 1, 0, &size) else { return nil }
        defer { DeleteProcThreadAttributeList(list) }
        guard UpdateProcThreadAttribute(list, 0, Self.handleListAttribute, handles, SIZE_T(3 * MemoryLayout<HANDLE?>.size), nil, nil) else { return nil }

        var info = STARTUPINFOEXW()
        info.StartupInfo.cb = DWORD(MemoryLayout<STARTUPINFOEXW>.size)
        info.StartupInfo.dwFlags = DWORD(STARTF_USESTDHANDLES)
        info.StartupInfo.hStdInput = inputRead
        info.StartupInfo.hStdOutput = outputWrite
        info.StartupInfo.hStdError = errorWrite
        info.lpAttributeList = list
        var command = Array(([executable] + arguments).map(Self.quote).joined(separator: " ").utf16) + [0]
        var environment = ConPTY.environmentBlock(extraEnvironment)
        let app = Array(executable.utf16) + [0]
        var created = PROCESS_INFORMATION()
        let flags = DWORD(EXTENDED_STARTUPINFO_PRESENT) | DWORD(CREATE_UNICODE_ENVIRONMENT) | DWORD(CREATE_SUSPENDED) | DWORD(CREATE_NO_WINDOW)
        let started = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: STARTUPINFOW.self, capacity: 1) { startup in
                CreateProcessW(app, &command, nil, nil, true, flags, &environment, nil, startup, &created)
            }
        }
        guard started else {
            for var h in [inputWrite, outputRead, errorRead] { Self.close(&h) }
            return nil
        }
        process = created.hProcess
        job = ConPTY.makeJob()
        if let job { _ = AssignProcessToJobObject(job, created.hProcess) }
        _ = ResumeThread(created.hThread)
        _ = CloseHandle(created.hThread)
        startThreads()
    }

    deinit {
        Self.close(&inputWrite)
        Self.close(&outputRead)
        Self.close(&errorRead)
        Self.close(&process)
        Self.close(&job)
    }

    private func startThreads() {
        let outputDone = DispatchSemaphore(value: 0)
        // Passed to the threads as a plain number: a HANDLE (a raw pointer) isn't Sendable.
        for (bits, isError) in [(UInt(bitPattern: outputRead), false), (UInt(bitPattern: errorRead), true)] {
            Thread.detachNewThread { [self] in
                let handle = HANDLE(bitPattern: bits)
                var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                while true {
                    var count: DWORD = 0
                    let read = buffer.withUnsafeMutableBytes { ReadFile(handle, $0.baseAddress, DWORD($0.count), &count, nil) }
                    guard read, count > 0 else { break }
                    let data = Data(buffer[..<Int(count)])
                    if isError { onError?(data) } else { onOutput?(data) }
                }
                if !isError { outputDone.signal() }
            }
        }
        Thread.detachNewThread { [self] in
            _ = WaitForSingleObject(process, INFINITE)
            var code: DWORD = 0
            _ = GetExitCodeProcess(process, &code)
            // What it printed last comes first, unless something it started holds the pipe open.
            _ = outputDone.wait(timeout: .now() + 2)
            onExit?(Int32(truncatingIfNeeded: code))
        }
    }

    /// Writes in order, without blocking the caller.
    func write(_ data: Data) {
        writeQueue.async { [self] in
            let bytes = [UInt8](data)
            var offset = 0
            while offset < bytes.count {
                var written: DWORD = 0
                let ok = bytes.withUnsafeBytes { WriteFile(inputWrite, $0.baseAddress! + offset, DWORD(bytes.count - offset), &written, nil) }
                guard ok, written > 0 else { return }
                offset += Int(written)
            }
        }
    }

    /// Stops it and anything it started. `onExit` follows.
    func terminate() {
        if let job { _ = TerminateJobObject(job, 1) } else if let process { _ = TerminateProcess(process, 1) }
    }

    /// One argument as the C runtime's parser reads it back: quoted when it has spaces or quotes, with backslashes
    /// doubled only before a quote.
    static func quote(_ argument: String) -> String {
        if !argument.isEmpty && !argument.contains(where: { " \t\n\u{0B}\"".contains($0) }) { return argument }
        var out = "\"", backslashes = 0
        for c in argument {
            if c == "\\" {
                backslashes += 1
                continue
            }
            out += String(repeating: "\\", count: c == "\"" ? backslashes * 2 + 1 : backslashes) + String(c)
            backslashes = 0
        }
        return out + String(repeating: "\\", count: backslashes * 2) + "\""
    }

    private static func close(_ handle: inout HANDLE?) {
        if let h = handle { _ = CloseHandle(h) }
        handle = nil
    }
}
