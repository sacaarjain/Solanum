import Foundation
import WinSDK

/// Runs `body` on a new thread of its own, as `Thread.detachNewThread` does, but closes the thread's handle at once.
///
/// Foundation's `Thread` on Windows never closes the handle of a thread it starts (one stays open for each, measured:
/// 200 threads, 200 handles). A thread whose handle is open stays on its process's list after it has ended, so each
/// git status, sidebar listing and hidden program left one behind: after four days a Solanum held 870,000 of them, the
/// kernel 5 GB of memory it can't page out, and every look at the running processes (which agent a tab runs, once a
/// second) went through all 870,000, holding up the window for seconds at a time.
func startThread(_ body: @escaping () -> Void) {
    let box = ThreadBody(body)
    let context = Unmanaged.passRetained(box).toOpaque()
    let handle = CreateThread(nil, 0, { raw in
        guard let raw else { return 0 }
        Unmanaged<ThreadBody>.fromOpaque(raw).takeRetainedValue().body()
        return 0
    }, context, 0, nil)
    if let handle {
        CloseHandle(handle)
    } else {
        // Couldn't start one (out of memory, say): run it on the shared pool rather than not at all.
        Unmanaged<ThreadBody>.fromOpaque(context).release()
        DispatchQueue.global().async { box.body() }
    }
}

private final class ThreadBody: @unchecked Sendable {
    let body: () -> Void
    init(_ body: @escaping () -> Void) { self.body = body }
}

/// How many handles this process has open: a check that nothing keeps them (see `startThread`).
func openHandleCount() -> Int {
    var count: DWORD = 0
    return GetProcessHandleCount(GetCurrentProcess(), &count) ? Int(count) : 0
}
