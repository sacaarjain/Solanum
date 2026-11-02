import CCanvas
import Foundation
import WinSDK

/// A password kept only in memory, encrypted with CryptProtectMemory so that only this process can read it, and wiped
/// when it's dropped. Never written anywhere.
final class ProtectedSecret {
    private var bytes: [UInt8]
    private let length: Int

    init(_ text: String) {
        let raw = Array(text.utf8)
        length = raw.count
        // CryptProtectMemory works in blocks of 16 bytes.
        bytes = raw + [UInt8](repeating: 0, count: (16 - raw.count % 16) % 16 + (raw.isEmpty ? 16 : 0))
        _ = bytes.withUnsafeMutableBytes { sol_protect_memory($0.baseAddress, UInt32($0.count), 0) }
    }

    /// The secret, decrypted only for as long as `body` runs.
    func reveal<T>(_ body: (String) -> T) -> T {
        var copy = bytes
        _ = copy.withUnsafeMutableBytes { sol_protect_memory($0.baseAddress, UInt32($0.count), 1) }
        defer { for i in copy.indices { copy[i] = 0 } }
        return body(String(decoding: copy.prefix(length), as: UTF8.self))
    }

    deinit { for i in bytes.indices { bytes[i] = 0 } }
}

/// ssh asks for a password by running the program in SSH_ASKPASS, which the hook points at Solanum itself. That copy
/// passes the question to the running Solanum over a named pipe and prints the answer for ssh. Only a copy holding the
/// tab's random token is answered, and the pipe is this process's own, made first and named at random.
enum Askpass {
    /// The request as it travels over the pipe: the token, then the question.
    struct Request {
        let token: String
        let prompt: String
    }

    /// The helper: runs in the copy of Solanum that ssh starts. Exit code 0 with the answer on standard output, else 1.
    static func runHelper(prompt: String) -> Int32 {
        let env = ProcessInfo.processInfo.environment
        guard let pipe = env["SOLANUM_ASKPASS_PIPE"], let token = env["SOLANUM_ASKPASS_TOKEN"] else { return 1 }
        let name = wide(pipe)
        var handle: HANDLE?
        for _ in 0..<50 {
            handle = name.withUnsafeBufferPointer {
                CreateFileW($0.baseAddress, DWORD(GENERIC_READ) | DWORD(GENERIC_WRITE), 0, nil, DWORD(OPEN_EXISTING), 0, nil)
            }
            if let h = handle, h != INVALID_HANDLE_VALUE { break }
            handle = nil
            _ = name.withUnsafeBufferPointer { WaitNamedPipeW($0.baseAddress, 200) }
        }
        guard let handle else { return 1 }
        defer { CloseHandle(handle) }
        var mode = DWORD(PIPE_READMODE_MESSAGE)
        _ = SetNamedPipeHandleState(handle, &mode, nil, nil)
        let message = Array((token + "\n" + prompt).utf8)
        var written: DWORD = 0
        guard message.withUnsafeBytes({ WriteFile(handle, $0.baseAddress, DWORD($0.count), &written, nil) }) else { return 1 }
        var reply = [UInt8](repeating: 0, count: 8192)
        var read: DWORD = 0
        guard reply.withUnsafeMutableBytes({ ReadFile(handle, $0.baseAddress, DWORD($0.count), &read, nil) }), read > 0 else { return 1 }
        defer { for i in reply.indices { reply[i] = 0 } }
        // "1" and the answer, or "0" when it was cancelled.
        guard reply[0] == UInt8(ascii: "1") else { return 1 }
        let out = GetStdHandle(DWORD(bitPattern: -11))
        var answer = Array(reply[1..<Int(read)]) + [UInt8(ascii: "\n")]
        defer { for i in answer.indices { answer[i] = 0 } }
        var done: DWORD = 0
        _ = answer.withUnsafeBytes { WriteFile(out, $0.baseAddress, DWORD($0.count), &done, nil) }
        return 0
    }

    /// The running Solanum's end. Requests go to `handler` on the window's thread, which answers with nil to cancel.
    final class Server {
        let pipeName: String
        var handler: ((Request, @escaping (String?) -> Void) -> Void)?
        private let post: (@escaping () -> Void) -> Void

        init(post: @escaping (@escaping () -> Void) -> Void) {
            var random = [UInt8](repeating: 0, count: 16)
            for i in random.indices { random[i] = UInt8.random(in: 0...255) }
            pipeName = #"\\.\pipe\solanum-askpass-"# + "\(GetCurrentProcessId())-" + random.map { String(format: "%02x", $0) }.joined()
            self.post = post
            Thread.detachNewThread { [weak self] in self?.listen(first: true) }
        }

        private func listen(first: Bool) {
            let name = wide(pipeName)
            // The first instance is made with FILE_FLAG_FIRST_PIPE_INSTANCE, so another process can't have taken the name.
            let flags = DWORD(PIPE_ACCESS_DUPLEX) | (first ? DWORD(0x0008_0000) : 0)
            let pipe = name.withUnsafeBufferPointer {
                CreateNamedPipeW($0.baseAddress, flags, DWORD(PIPE_TYPE_MESSAGE) | DWORD(PIPE_READMODE_MESSAGE) | DWORD(PIPE_WAIT),
                                 DWORD(PIPE_UNLIMITED_INSTANCES), 8192, 8192, 0, nil)
            }
            guard let pipe, pipe != INVALID_HANDLE_VALUE else { return }
            let connected = ConnectNamedPipe(pipe, nil) || GetLastError() == DWORD(ERROR_PIPE_CONNECTED)
            // The next client gets the next instance, on a thread of its own.
            Thread.detachNewThread { [weak self] in self?.listen(first: false) }
            guard connected else { CloseHandle(pipe); return }
            var buffer = [UInt8](repeating: 0, count: 8192)
            var read: DWORD = 0
            guard buffer.withUnsafeMutableBytes({ ReadFile(pipe, $0.baseAddress, DWORD($0.count), &read, nil) }), read > 0 else {
                CloseHandle(pipe)
                return
            }
            let text = String(decoding: buffer.prefix(Int(read)), as: UTF8.self)
            let parts = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let request = Request(token: parts.first ?? "", prompt: parts.count > 1 ? parts[1] : "")
            let answered = DispatchSemaphore(value: 0)
            var answer: String?
            post { [weak self] in
                guard let handler = self?.handler else { answered.signal(); return }
                handler(request) { reply in
                    answer = reply
                    answered.signal()
                }
            }
            // A person may take a while to type it; ssh waits as long.
            answered.wait()
            var reply = Array(((answer == nil ? "0" : "1") + (answer ?? "")).utf8)
            var written: DWORD = 0
            _ = reply.withUnsafeBytes { WriteFile(pipe, $0.baseAddress, DWORD($0.count), &written, nil) }
            for i in reply.indices { reply[i] = 0 }
            FlushFileBuffers(pipe)
            DisconnectNamedPipe(pipe)
            CloseHandle(pipe)
        }
    }

    /// A new random token, one per tab.
    static func makeToken() -> String {
        (0..<24).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    /// Whether a question is for a secret, to be typed unseen and kept for the sidebar.
    static func isSecret(_ prompt: String) -> Bool {
        let p = prompt.lowercased()
        return p.contains("password") || p.contains("passphrase") || p.contains("pin") || p.contains("verification code")
    }

    /// Whether it's a password, which can be used again for another connection (a one-time code can't).
    static func isPassword(_ prompt: String) -> Bool { prompt.lowercased().contains("password") }
}
