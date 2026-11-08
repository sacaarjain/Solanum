import CoreServices
import Foundation

/// Tells open files on this Mac when they change on disk, as VS Code does: one FSEvents stream for every folder
/// with a file open, not a watch per file. A watch on the file itself would go deaf after the first save by a tool
/// that writes a new file and renames it over the old one (most editors, and agents), since the path then names a
/// different file; a folder's events name paths, whatever file is there now. Folders are added and dropped as
/// editors come and go (the stream is made again with the new set; FSEvents can't change one in place).
final class DiskWatch {
    static let shared = DiskWatch()

    struct Event {
        /// As FSEvents names it: the real path (no symlinks, /private/tmp for /tmp).
        let path: String
        let flags: FSEventStreamEventFlags
        var renamed: Bool { flags & UInt32(kFSEventStreamEventFlagItemRenamed) != 0 }
        /// Events were dropped or merged under it: anything in it may have changed.
        var rescan: Bool {
            flags & UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
                           | kFSEventStreamEventFlagRootChanged) != 0
        }
    }

    /// Keeps a folder watched until it's let go of.
    final class Token {
        fileprivate let id = UUID()
        /// The folder, as a real path.
        let folder: String
        fileprivate init(folder: String) { self.folder = folder }
        deinit { let id = id; DispatchQueue.main.async { DiskWatch.shared.remove(id) } }
    }

    private var handlers: [UUID: (folder: String, call: ([Event]) -> Void)] = [:]
    private var stream: FSEventStreamRef?
    private var folders: Set<String> = []
    private var restartQueued = false

    /// Calls `handler` (on the main queue, events 150 ms apart coalesced) with what changed in the folder `path` is
    /// in, along with every rename in the batch (where a file moved to), while the token is kept.
    func watch(folderOf path: String, _ handler: @escaping ([Event]) -> Void) -> Token {
        let token = Token(folder: Self.realPath((path as NSString).deletingLastPathComponent))
        handlers[token.id] = (token.folder, handler)
        queueRestart()
        return token
    }

    fileprivate func remove(_ id: UUID) {
        guard handlers.removeValue(forKey: id) != nil else { return }
        queueRestart()
    }

    /// The path with symlinks resolved, as FSEvents reports it; as given when it can't be resolved.
    static func realPath(_ path: String) -> String {
        guard let r = realpath(path, nil) else { return path }
        defer { free(r) }
        return String(cString: r)
    }

    /// Changes come in bursts (several editors opening at once): the stream is made again once for all of them.
    private func queueRestart() {
        guard !restartQueued else { return }
        restartQueued = true
        DispatchQueue.main.async { [self] in
            restartQueued = false
            restart()
        }
    }

    private func restart() {
        let wanted = Set(handlers.values.map(\.folder))
        guard wanted != folders else { return }
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            stream = nil
        }
        folders = wanted
        guard !wanted.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watch = Unmanaged<DiskWatch>.fromOpaque(info).takeUnretainedValue()
            let names = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            watch.deliver((0..<min(count, names.count)).map { Event(path: names[$0], flags: flags[$0]) })
        }
        let options = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
        guard let s = FSEventStreamCreate(nil, callback, &context, Array(wanted) as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                          0.15, options) else { return }
        FSEventStreamSetDispatchQueue(s, .main)
        FSEventStreamStart(s)
        stream = s
    }

    /// Streams are recursive; only a watched folder's own files (and renames, wherever they went) are passed on.
    private func deliver(_ events: [Event]) {
        var byFolder: [String: [Event]] = [:]
        var rescans: [Event] = []
        for e in events {
            if e.rescan { rescans.append(e); continue }
            let folder = (e.path as NSString).deletingLastPathComponent
            if folders.contains(folder) { byFolder[folder, default: []].append(e) }
        }
        let renames = events.filter(\.renamed)
        for h in handlers.values {
            let mine = byFolder[h.folder] ?? []
            let rescan = rescans.filter { h.folder == $0.path || h.folder.hasPrefix($0.path.hasSuffix("/") ? $0.path : $0.path + "/") }
            guard !mine.isEmpty || !rescan.isEmpty else { continue }
            h.call(mine + rescan + renames.filter { r in !mine.contains { $0.path == r.path } })
        }
    }
}
