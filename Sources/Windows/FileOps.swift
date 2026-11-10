import Foundation
import WinSDK

/// What the sidebar does to files: on this PC through the file system, the Recycle Bin and the clipboard's list of files
/// (which Explorer shares), and on an ssh host through the sidebar's connection there, with tar and base64 carrying files
/// either way.
enum FileOps {
    // MARK: Names

    /// A name not taken in a folder: "a - Copy.txt" for a copy beside the original, as Explorer has it, else "a (2).txt".
    static func uniqueName(_ name: String, taken: Set<String>, copy: Bool = false, caseSensitive: Bool = false) -> String {
        let lowered = caseSensitive ? taken : Set(taken.map { $0.lowercased() })
        func free(_ n: String) -> Bool { !lowered.contains(caseSensitive ? n : n.lowercased()) }
        if !copy && free(name) { return name }
        let dot = name.lastIndex(of: ".").flatMap { $0 == name.startIndex ? nil : $0 }
        let stem = dot.map { String(name[..<$0]) } ?? name, ext = dot.map { String(name[$0...]) } ?? ""
        let first = copy ? "\(stem) - Copy\(ext)" : "\(stem) (2)\(ext)"
        if free(first) { return first }
        for n in 2... {
            let candidate = copy ? "\(stem) - Copy (\(n))\(ext)" : "\(stem) (\(n + 1))\(ext)"
            if free(candidate) { return candidate }
        }
        return name
    }

    /// Whether a name can be a file's: not empty, no characters Windows (or a Unix host) won't have, not "." or "..".
    static func isValidName(_ name: String, unix: Bool) -> Bool {
        guard !name.isEmpty, name != ".", name != ".." else { return false }
        let bad: Set<Character> = unix ? ["/"] : ["\\", "/", ":", "*", "?", "\"", "<", ">", "|"]
        return !name.contains(where: { bad.contains($0) }) && (unix || !name.hasSuffix(" ") && !name.hasSuffix("."))
    }

    static func names(in folder: String) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [])
    }

    // MARK: This PC

    static func createFile(_ path: String) -> Bool {
        guard !FileManager.default.fileExists(atPath: path) else { return false }
        return FileManager.default.createFile(atPath: path, contents: Data())
    }

    static func createFolder(_ path: String) -> Bool {
        (try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)) != nil
    }

    static func rename(_ path: String, to name: String) -> String? {
        guard let parent = WindowsPath.parent(path) else { return nil }
        let target = WindowsPath.join(parent, name)
        // Only the case changing is still a rename on Windows, where the old name counts as taken.
        if target.lowercased() != path.lowercased() && FileManager.default.fileExists(atPath: target) { return nil }
        return (try? FileManager.default.moveItem(atPath: path, toPath: target)) != nil ? target : nil
    }

    /// Copies or moves items into a folder, each under a name not taken there. The paths they end up at.
    static func transfer(_ paths: [String], into folder: String, move: Bool) -> [String] {
        var taken = names(in: folder)
        var out: [String] = []
        for path in paths {
            let name = WindowsPath.name(path)
            // Moving something to where it already is does nothing.
            if move, WindowsPath.parent(path)?.lowercased() == folder.lowercased() { out.append(path); continue }
            // Nor into itself.
            if path.lowercased() == folder.lowercased() || folder.lowercased().hasPrefix(path.lowercased() + "\\") { continue }
            let sameFolder = WindowsPath.parent(path)?.lowercased() == folder.lowercased()
            let target = WindowsPath.join(folder, uniqueName(name, taken: taken, copy: sameFolder && !move))
            let ok = move ? (try? FileManager.default.moveItem(atPath: path, toPath: target)) != nil
                          : (try? FileManager.default.copyItem(atPath: path, toPath: target)) != nil
            if ok {
                taken.insert(WindowsPath.name(target))
                out.append(target)
            }
        }
        return out
    }

    /// To the Recycle Bin, where they can be brought back from.
    static func recycle(_ paths: [String]) -> Bool {
        guard !paths.isEmpty else { return true }
        var list: [UInt16] = paths.flatMap { Array($0.utf16) + [0] } + [0]
        return list.withUnsafeMutableBufferPointer { from -> Bool in
            var op = SHFILEOPSTRUCTW()
            op.wFunc = UINT(FO_DELETE)
            op.pFrom = UnsafePointer(from.baseAddress)
            op.fFlags = FILEOP_FLAGS(FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_SILENT | FOF_NOERRORUI)
            return SHFileOperationW(&op) == 0 && !op.fAnyOperationsAborted.boolValue
        }
    }

    /// Explorer, with the item picked out.
    static var onReveal: (String) -> Void = { path in
        _ = wide("explorer.exe").withUnsafeBufferPointer { exe in
            wide("/select,\"\(path)\"").withUnsafeBufferPointer { args in ShellExecuteW(nil, nil, exe.baseAddress, args.baseAddress, nil, 1) }
        }
    }

    static var downloadsFolder: String {
        if let test = ProcessInfo.processInfo.environment["SOLANUM_DOWNLOADS"] { return test }
        return WindowsPath.join(ProcessInfo.processInfo.environment["USERPROFILE"] ?? #"C:\"#, "Downloads")
    }

    // MARK: The clipboard's files

    private static let hdropFormat = UINT(15)  // CF_HDROP
    private static var dropEffectFormat: UINT { RegisterClipboardFormatW(wide("Preferred DropEffect")) }

    /// A list of files as Explorer passes them around (DROPFILES): a header, then the paths, each ending in a NUL, then
    /// another NUL. In memory Windows can own.
    static func dropList(_ paths: [String]) -> HGLOBAL? {
        let units: [UInt16] = paths.flatMap { Array($0.utf16) + [0] } + [0]
        let header = 20
        guard let memory = GlobalAlloc(UINT(GMEM_MOVEABLE | GMEM_ZEROINIT), SIZE_T(header + units.count * 2)),
              let raw = GlobalLock(memory) else { return nil }
        raw.storeBytes(of: UInt32(header), toByteOffset: 0, as: UInt32.self)  // pFiles
        raw.storeBytes(of: Int32(1), toByteOffset: 16, as: Int32.self)        // fWide
        units.withUnsafeBytes { (raw + header).copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        GlobalUnlock(memory)
        return memory
    }

    /// Puts files on the clipboard for pasting here or in Explorer: cut ones move when pasted, as there.
    @discardableResult
    static func putOnClipboard(_ paths: [String], cut: Bool, owner: HWND?) -> Bool {
        guard OpenClipboard(owner) else { return false }
        defer { CloseClipboard() }
        EmptyClipboard()
        guard let list = dropList(paths), SetClipboardData(hdropFormat, list) != nil else { return false }
        if let effect = GlobalAlloc(UINT(GMEM_MOVEABLE), 4), let raw = GlobalLock(effect) {
            raw.storeBytes(of: UInt32(cut ? 2 : 5), as: UInt32.self)  // DROPEFFECT_MOVE, or COPY | LINK as Explorer puts it
            GlobalUnlock(effect)
            _ = SetClipboardData(dropEffectFormat, effect)
        }
        return true
    }

    /// The paths in a list of dropped or pasted files.
    static func paths(in drop: HDROP) -> [String] {
        let count = DragQueryFileW(drop, 0xFFFF_FFFF, nil, 0)
        return (0..<count).compactMap { i in
            let length = DragQueryFileW(drop, i, nil, 0)
            guard length > 0 else { return nil }
            var buffer = [UInt16](repeating: 0, count: Int(length) + 1)
            _ = DragQueryFileW(drop, i, &buffer, UINT(buffer.count))
            return String(decodingCString: buffer, as: UTF16.self)
        }
    }

    /// Files on the clipboard, from Solanum or Explorer, and whether they were cut.
    static func clipboardFiles(owner: HWND?) -> (paths: [String], cut: Bool)? {
        guard IsClipboardFormatAvailable(hdropFormat), OpenClipboard(owner) else { return nil }
        defer { CloseClipboard() }
        guard let handle = GetClipboardData(hdropFormat) else { return nil }
        let paths = Self.paths(in: HDROP(OpaquePointer(handle)))
        var cut = false
        if let effect = GetClipboardData(dropEffectFormat), let raw = GlobalLock(effect) {
            cut = raw.load(as: UInt32.self) & 2 != 0
            GlobalUnlock(effect)
        }
        return paths.isEmpty ? nil : (paths, cut)
    }

    // MARK: Programs

    /// Runs a program with no window and waits for it, for its output. Off the message loop.
    static func runProgram(_ exe: String, _ arguments: [String]) -> (output: Data, status: Int32) {
        guard let child = HiddenProcess(executable: exe, arguments: arguments, extraEnvironment: [:]) else { return (Data(), -1) }
        let lock = NSLock(), done = DispatchSemaphore(value: 0)
        var output = Data(), status: Int32 = -1
        child.onOutput = { data in lock.lock(); output.append(data); lock.unlock() }
        child.onExit = { code in status = code; done.signal() }
        done.wait()
        lock.lock()
        defer { lock.unlock() }
        return (output, status)
    }

    /// Windows' own tar, which has come with it since Windows 10.
    static var tarExe: String { WindowsPath.join(WindowsPath.join(ProcessInfo.processInfo.environment["SystemRoot"] ?? #"C:\Windows"#, "System32"), "tar.exe") }

    // MARK: An ssh host

    /// A shell script's word for a path or name.
    static func q(_ s: String) -> String { RemoteConnection.quote(s) }

    static func remoteCreate(_ path: String, folder: Bool) -> String {
        folder ? "mkdir -- \(q(path))" : "[ ! -e \(q(path)) ] && : > \(q(path))"
    }

    static func remoteRename(_ path: String, to target: String) -> String { "[ ! -e \(q(target)) ] && mv -- \(q(path)) \(q(target))" }

    static func remoteTransfer(_ pairs: [(from: String, to: String)], move: Bool) -> String {
        pairs.map { "\(move ? "mv" : "cp -R") -- \(q($0.from)) \(q($0.to))" }.joined(separator: " && ")
    }

    static func remoteDelete(_ paths: [String]) -> String { "rm -rf -- " + paths.map(q).joined(separator: " ") }

    /// Takes a tar of `name` (inside `parent`) out of the host, as base64.
    static func remotePack(_ path: String) -> String {
        "cd -- \(q(AnyPath.parent(path) ?? "/")) && tar -cf - -- \(q(AnyPath.name(path))) | base64"
    }

    /// Unpacks a tar (as base64) of one item into the host's `folder`, under `name`: through a folder of its own, so
    /// nothing already there is touched.
    static func remoteUnpack(_ base64: String, item: String, into folder: String, as name: String) -> String {
        let tag = "__SOLANUM_DATA__"
        return "{ d=$(mktemp -d) && base64 -d <<'\(tag)' | tar -C \"$d\" -xf - && mv -- \"$d\"/\(q(item)) \(q(AnyPath.join(folder, name))); r=$?; rm -rf \"$d\"; (exit $r)\n"
            + base64 + "\n\(tag)\n}"
    }

    /// A tar of one item on this PC, as base64 lines.
    static func pack(_ path: String) -> String? {
        guard let parent = WindowsPath.parent(path) else { return nil }
        let (data, status) = runProgram(tarExe, ["-cf", "-", "-C", parent, WindowsPath.name(path)])
        return status == 0 ? data.base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed]) : nil
    }

    /// Unpacks a tar (as base64) of one item into a folder on this PC, under a name not taken there. Where it went.
    static func unpack(_ base64: String, item: String, into folder: String) -> String? {
        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else { return nil }
        let temp = WindowsPath.join(NSTemporaryDirectory().replacingOccurrences(of: "/", with: "\\"), "solanum-\(UUID().uuidString)")
        guard createFolder(temp) else { return nil }
        defer { try? FileManager.default.removeItem(atPath: temp) }
        let archive = WindowsPath.join(temp, "transfer.tar"), out = WindowsPath.join(temp, "out")
        guard FileManager.default.createFile(atPath: archive, contents: data), createFolder(out),
              runProgram(tarExe, ["-xf", archive, "-C", out]).status == 0 else { return nil }
        return transfer([WindowsPath.join(out, item)], into: folder, move: true).first
    }
}
