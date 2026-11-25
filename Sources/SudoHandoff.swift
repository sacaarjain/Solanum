import AppKit

// Files dropped from this Mac onto an ssh host, into a shell's folder (dropped on its terminal) or a folder in the
// sidebar, when that shell may be another user's (`sudo -i -u svc`), whose folders the ssh login can't write. Solanum's
// connection is the login's, so the files go as the login into a fresh folder in /tmp; that folder is opened to the
// shell's user (an ACL for that user alone, or, on a host without ACLs, to everyone, as chmod 777 would); the shell is
// then given the copy to type itself (` cp -Ri /tmp/solanum-drop.…/. <folder>/`, -i asking before anything's
// overwritten); and once it's done (it leaves a marker) the login removes the folder from /tmp, which only its owner
// can (/tmp is sticky). Nothing's left there after ten minutes either way.

enum SudoHandoff {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// How long the folder in /tmp waits for the copy (answering cp's questions included) before it's removed anyway.
    static let waitLimit: TimeInterval = 600
    private static let pollEvery: TimeInterval = 1.5

    /// Whether a drop on this pane (or on its sidebar's folders) goes through its shell: an ssh shell at its prompt.
    static func canSend(through pane: TerminalView) -> Bool {
        pane.remote?.isReady == true && pane.terminal.atEmptyHostPrompt()
    }

    /// Sends `localPaths` (files or folders on this Mac) into `dest` on `pane`'s host, or into the folder its shell is
    /// in (nil), copied there by the shell itself. `done` once they're there (or the copy was left to finish by itself).
    static func send(_ localPaths: [String], through pane: TerminalView, into dest: String?, _ done: @escaping (Error?) -> Void) {
        guard let remote = pane.remote, remote.isReady else { return done(Failure(message: "Not connected to the host.")) }
        guard pane.terminal.atEmptyHostPrompt() else {
            return done(Failure(message: "The shell isn't at its prompt, so it can't be given the copy. Finish what's running there, then drop again."))
        }
        // The shell's user, when it isn't the login (see Follow This Shell's Folder); nil when it's the login's own.
        let user = pane.borrowedUser
        remote.run("mktemp -d /tmp/solanum-drop.XXXXXX") { status, out, err in
            let tmp = String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard status == 0, tmp.hasPrefix("/tmp/solanum-drop.") else {
                return done(Failure(message: "Couldn't make a folder in /tmp on the host. \(err)"))
            }
            let q = shellQuote(tmp)
            func removeTmp() { remote.run("rm -rf \(q)") { _, _, _ in } }
            var taken = Set<String>()
            let jobs = localPaths.map { p -> (from: String, name: String) in
                let name = FilePaths.uniqueName((p as NSString).lastPathComponent, taken: taken)
                taken.insert(name)
                return (p, name)
            }
            // The shell's user (only) may read them and leave its marker; on a host without ACLs, anyone may.
            func open() {
                guard let user else { return give() }
                let u = shellQuote(user)
                let script = "{ setfacl -R -m u:\(u):rwX \(q) && setfacl -m u:\(u):rwx \(q); } 2>/dev/null || chmod -R a+rwX \(q)"
                remote.run(script) { status, _, err in
                    guard status == 0 else {
                        removeTmp()
                        return done(Failure(message: "Couldn't let \(user) read the files in /tmp. \(err)"))
                    }
                    give()
                }
            }
            // The copy, typed into the shell (a leading space keeps it out of its history), then the marker.
            func give() {
                guard pane.terminal.atEmptyHostPrompt() else {
                    removeTmp()
                    return done(Failure(message: "The shell stopped being at its prompt while the files were on their way, so it wasn't given the copy."))
                }
                let marker = shellQuote(tmp + "/.solanum-copied")
                let into = dest.map { shellQuote($0) + "/" } ?? "./"
                pane.send("\u{15} cp -Ri \(shellQuote(tmp + "/."))" + " \(into) ; touch \(marker)\r")
                watch(since: Date())
            }
            // The marker there: the copy's over, and the folder goes. Past the limit, it goes anyway.
            func watch(since: Date) {
                let over = Date().timeIntervalSince(since) > waitLimit
                remote.run(over ? "rm -rf \(q); echo gone" : "if [ -e \(shellQuote(tmp + "/.solanum-copied")) ]; then rm -rf \(q); echo gone; fi") { _, out, _ in
                    if String(decoding: out, as: UTF8.self).contains("gone") || !remote.isConnected { return done(nil) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + pollEvery) { watch(since: since) }
                }
            }
            func upload(_ i: Int) {
                guard i < jobs.count else { return open() }
                FileTransfer.copy(jobs[i].from, from: LocalFileSystem.shared, into: tmp, as: jobs[i].name, on: remote) { error in
                    if let error { removeTmp(); return done(error) }
                    upload(i + 1)
                }
            }
            upload(0)
        }
    }
}
