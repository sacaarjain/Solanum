import Foundation

// Files dropped from this PC onto an ssh host, into a shell's folder (dropped on its terminal) or a folder in the
// sidebar, through that shell, as on the Mac (SudoHandoff.swift there). The shell may be another user's (`sudo -i -u
// svc`), whose folders the ssh login can't write: Solanum's connection is the login's, so the files go up as the login
// into a fresh folder in /tmp; that folder is opened to the shell's user (an ACL for that user alone, or, on a host
// without ACLs, to everyone, as chmod 777 would); the shell is then given the copy to type itself (` cp -Ri
// /tmp/solanum-drop.…/. <folder>/`, -i asking before anything's overwritten, the leading space keeping it out of its
// history); and once it's done (it leaves a marker) the login removes the folder from /tmp, which only its owner can
// (/tmp is sticky). Nothing's left there after ten minutes either way.

enum SudoHandoff {
    /// How long the folder in /tmp waits for the copy (answering cp's questions included) before it's removed anyway.
    static let waitLimit: TimeInterval = 600
    static var pollEvery: TimeInterval = 1.5

    /// Sends `localPaths` (files or folders on this PC) into `dest` on `pane`'s host, or into the folder its shell is in
    /// (nil), copied there by the shell itself. `done` on the window thread (through `post`) once they're there, or the
    /// copy was left to finish by itself, with what went wrong if it didn't.
    static func send(_ localPaths: [String], through pane: TerminalPane, into dest: String?,
                     post: @escaping (@escaping () -> Void) -> Void, _ done: @escaping (String?) -> Void) {
        guard let remote = pane.remote, remote.state == .ready else { return done("Not connected to the host.") }
        guard pane.canSendToHost else {
            return done("The shell isn't at its prompt, so it can't be given the copy. Finish what's running there, then drop again.")
        }
        // The shell's user, when it isn't the login; nil when it's the login's own.
        let user = pane.borrowedUser
        func finish(_ problem: String?) { post { done(problem) } }
        func run(_ command: String, timeout: TimeInterval = 30) -> (text: String, ok: Bool, answered: Bool) {
            let got = DispatchSemaphore(value: 0)
            var result = ("", false, false)
            remote.run(command, timeout: timeout) { text, code in
                result = (text ?? "", text != nil && code == 0, text != nil)
                got.signal()
            }
            got.wait()
            return result
        }
        startThread {
            let made = run("mktemp -d /tmp/solanum-drop.XXXXXX")
            let tmp = made.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard made.ok, tmp.hasPrefix("/tmp/solanum-drop.") else { return finish("Couldn't make a folder in /tmp on the host.") }
            let q = RemoteConnection.quote(tmp)
            func removeTmp() { _ = run("rm -rf \(q)") }
            // Up as the login.
            var taken = Set<String>()
            for path in localPaths {
                let name = FileOps.uniqueName(WindowsPath.name(path), taken: taken, caseSensitive: true)
                taken.insert(name)
                guard let data = FileOps.pack(path),
                      run(FileOps.remoteUnpack(data, item: WindowsPath.name(path), into: tmp, as: name), timeout: 600).ok else {
                    removeTmp()
                    return finish("Couldn't send “\(WindowsPath.name(path))” to the host.")
                }
            }
            // The shell's user (only) may read them and leave its marker; on a host without ACLs, anyone may.
            if let user {
                let u = RemoteConnection.quote(user)
                guard run("{ setfacl -R -m u:\(u):rwX \(q) && setfacl -m u:\(u):rwx \(q); } 2>/dev/null || chmod -R a+rwX \(q)").ok else {
                    removeTmp()
                    return finish("Couldn't let \(user) read the files in /tmp.")
                }
            }
            // The copy, typed into the shell, then the marker: on the window thread, where the shell is.
            let marker = RemoteConnection.quote(tmp + "/.solanum-copied")
            let gave = DispatchSemaphore(value: 0)
            var given = false
            post {
                if pane.canSendToHost {
                    let into = dest.map { RemoteConnection.quote($0) + "/" } ?? "./"
                    pane.typeIntoShell("\u{15} cp -Ri \(RemoteConnection.quote(tmp + "/.")) \(into) ; touch \(marker)\r")
                    given = true
                }
                gave.signal()
            }
            gave.wait()
            guard given else {
                removeTmp()
                return finish("The shell stopped being at its prompt while the files were on their way, so it wasn't given the copy.")
            }
            // The marker there: the copy's over, and the folder goes. Past the limit, it goes anyway.
            let since = Date()
            while true {
                let over = Date().timeIntervalSince(since) > waitLimit
                let check = run(over ? "rm -rf \(q); echo gone" : "if [ -e \(marker) ]; then rm -rf \(q); echo gone; fi")
                if check.text.contains("gone") || !check.answered || remote.state != .ready { break }
                Thread.sleep(forTimeInterval: pollEvery)
            }
            finish(nil)
        }
    }
}
