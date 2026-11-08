import CCanvas
import Foundation
import WinSDK

/// A file open above the terminal, as on the Mac's editor (FileEditor.swift there): its text, to edit and save, with the
/// header's buttons from left to right: Open Preview (Markdown), Tail File (the double chevron: the end stays in view as
/// the file grows), wrap lines, Beautify (JSON, YAML, XML), Save (dimmed until there's something to save) and close.
/// Images show fitted to the page. Ctrl+S saves, Alt+Z wraps, Shift+Alt+F beautifies.
///
/// The file keeps up with the disk, as VS Code's do (see Core's FileSync): on this PC it's looked at every second, open
/// or not; over ssh, every second while it's showing, with "Live" or "Not Updating" in the header. Unsaved edits are
/// never replaced: the header says "Changed on Disk", and saving over a change asks: Compare, Overwrite, Revert or Cancel.
final class FileEditorPanel: ColumnPanel {
    enum Content: Equatable {
        case loading
        case text
        case image(Data)
        case binary(Int)
        case failed(String)
    }

    struct Pos: Equatable, Comparable {
        var line: Int, col: Int
        static func < (a: Pos, b: Pos) -> Bool { a.line < b.line || (a.line == b.line && a.col < b.col) }
    }

    enum Button: String, CaseIterable { case preview, tail, wrap, beautify, save, close }

    let path: String
    let name: String
    let folder: String
    let isLocal: Bool
    /// Reads the file (up to `limit` bytes): its bytes and whether there was more. Writes it, `done` with what went wrong.
    private let read: (_ limit: Int, _ done: @escaping (Data?, Bool) -> Void) -> Void
    private let write: (_ data: Data, _ done: @escaping (String?) -> Void) -> Void
    /// The file's signature on disk now (see FileSync): `answered` false when there was no telling (the ssh connection
    /// down or hung), else the signature, nil when the file isn't there.
    private let signature: (_ done: @escaping (_ answered: Bool, _ signature: String?) -> Void) -> Void
    /// On this PC: the bytes from an offset to the end, and the file's size, for following a file that grows.
    private let readFrom: ((_ offset: Int, _ done: @escaping (Data?, Int) -> Void) -> Void)?
    private(set) var content: Content = .loading
    let language: SyntaxLanguage?
    var isMarkdown: Bool { MarkdownDoc.isMarkdown(path: path) }

    // The text, as lines, and how it's written back.
    private(set) var lines: [String] = [""]
    private var lineEnding = "\n"
    private var encoding: String.Encoding = .utf8
    private var byteOrderMark = false
    /// Cut short (too big to have all of): shown, not edited.
    private(set) var readOnly = false
    private var original = Data()

    // Editing.
    private(set) var caret = Pos(line: 0, col: 0)
    private var anchor: Pos?
    /// The column the caret goes back to moving up and down past shorter lines.
    private var goalColumn: Int?
    private var undoStack: [(lines: [String], caret: Pos)] = []
    private var redoStack: [(lines: [String], caret: Pos)] = []
    private enum EditKind { case typing, other }
    private var lastEdit: EditKind?
    private var version = 0, savedVersion = 0
    var hasUnsavedChanges: Bool { version != savedVersion }

    // View.
    private(set) var wraps = false
    /// Tail File: the end stays in view as the file grows (tail -f), even after scrolling up. Without it a growing file
    /// scrolls along only while its end is showing. Either way the file keeps up with the disk.
    private(set) var tailing = false
    private var reading = false
    /// The file as last read or saved: when what's on disk differs, something else changed it (an agent, git, a formatter).
    private var diskSignature: String?
    /// It changed on disk while there were unsaved edits: they stay, the header says so, and saving asks first.
    private(set) var changedOnDisk = false
    /// Gone from disk: the header says so, and saving puts it back.
    private(set) var deletedOnDisk = false
    private var syncing = false, saving = false
    private var lastSync = Date.distantPast
    /// Over ssh: whether the host is answering (a green "Live"), or not (a yellow "Not Updating"); nil on this PC, or
    /// before the first answer.
    private(set) var watchLive: Bool?
    private var lastHeard: Date?
    /// Saving hit a change on disk: the bar over the file asks what to do, and what was to happen after the save.
    private var conflict: ((Bool) -> Void)?
    /// Compare, from that bar: what's on disk on the left beside the unsaved text on the right.
    private var compareRows: [TextDiff.Row]?
    private var compareScroll = 0
    private var hoveredBarButton: Int?
    private var scrollRow = 0, scrollColumn = 0
    private var visibleRows = 20, columns = 80
    /// Where each line's first wrapped row is, while wrapping, and the total.
    private var rowStarts: [Int] = [0]
    private var builtFor: (version: Int, columns: Int, wraps: Bool) = (-1, 0, false)
    private var selecting = false
    private var hovered: Button?
    private var lastArea = UIRect(x: 0, y: 0, width: 0, height: 0)
    private var lastScale: Float = 1
    /// A line marked (a search's match), and one to scroll to once the text is in.
    private(set) var markedLine: Int?
    private var pendingLine: Int?
    /// Said for a moment in the header: "Saved", or what went wrong.
    private var note: (text: String, problem: Bool, at: Date)?
    private var images: [OpaquePointer: (id: Int32, width: Int32, height: Int32)] = [:]
    /// Syntax colors for JSON, YAML and XML (SyntaxScanner, shared with the Mac): for each line, a color for each cell
    /// as drawn (a tab's four), or none for plain text; worked out again after each edit.
    private var lineColors: [[UInt32]] = []
    private var colorsBuilt = -1

    var invalidate: () -> Void = {}
    var close: () -> Void = {}
    var post: (@escaping () -> Void) -> Void = { $0() }
    var copy: (String) -> Void = { _ in }
    var paste: () -> String? = { nil }
    var openPreview: () -> Void = {}
    var cellSize: (width: Float, height: Float) = (8, 16)

    static let textLimit = 50 * 1024 * 1024
    static let imageLimit = 40 * 1024 * 1024
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "bmp", "ico", "tif", "tiff", "webp", "jfif"]
    var isImage: Bool { Self.imageExtensions.contains(name.split(separator: ".").last.map { $0.lowercased() } ?? "") }

    init(path: String, name: String, folder: String, isLocal: Bool,
         read: @escaping (_ limit: Int, _ done: @escaping (Data?, Bool) -> Void) -> Void,
         write: @escaping (_ data: Data, _ done: @escaping (String?) -> Void) -> Void,
         signature: @escaping (_ done: @escaping (_ answered: Bool, _ signature: String?) -> Void) -> Void = { $0(false, nil) },
         readFrom: ((_ offset: Int, _ done: @escaping (Data?, Int) -> Void) -> Void)? = nil) {
        self.path = path
        self.name = name
        self.folder = folder
        self.isLocal = isLocal
        self.read = read
        self.write = write
        self.signature = signature
        self.readFrom = readFrom
        language = SyntaxLanguage(path: path)
    }

    deinit {
        for (raw, image) in images { sol_canvas_free_image(raw, image.id) }
    }

    // MARK: Reading and saving

    /// Reads the file again. Edits not saved stay: it's only read again over them when there are none.
    func reload() {
        guard !reading, !hasUnsavedChanges else { return }
        reading = true
        // Its signature first: should it change while it's read, the next look sees a difference.
        signature { [weak self] answered, sig in
            self?.post {
                guard let self else { return }
                if answered { self.diskSignature = sig }
                self.readNow()
            }
        }
    }

    private func readNow() {
        let image = isImage
        // A file on this PC that only grew (a log): just what was added, when the end of what's here is still there.
        if !image, let readFrom, case .text = content, !readOnly, original.count > 0 {
            let keep = min(256, original.count), from = original.count - keep
            readFrom(from) { [weak self] data, size in
                self?.post {
                    guard let self else { return }
                    guard let data, size >= self.original.count, data.count >= keep, data.prefix(keep) == self.original.suffix(keep),
                          self.original.count + data.count - keep <= Self.textLimit else { return self.readWhole(image) }
                    self.reading = false
                    guard !self.hasUnsavedChanges else { return }
                    let grown = self.original + data.dropFirst(keep)
                    if grown != self.original { self.load(grown, cut: false) }
                    self.changedOnDisk = false
                    self.deletedOnDisk = false
                    self.invalidate()
                }
            }
            return
        }
        readWhole(image)
    }

    private func readWhole(_ image: Bool) {
        read(image ? Self.imageLimit : Self.textLimit) { [weak self] data, cut in
            self?.post {
                guard let self else { return }
                self.reading = false
                guard !self.hasUnsavedChanges else { return }
                if data != nil { self.changedOnDisk = false; self.deletedOnDisk = false }
                guard let data else {
                    if case .loading = self.content { self.content = .failed("Couldn't read this file.") }
                    return self.invalidate()
                }
                if image {
                    if case .image(let old) = self.content, old == data { return }
                    for (raw, i) in self.images { sol_canvas_free_image(raw, i.id) }
                    self.images = [:]
                    self.content = .image(data)
                } else {
                    guard data != self.original || self.content == .loading else { return }
                    self.load(data, cut: cut)
                }
                self.invalidate()
            }
        }
    }

    private func load(_ data: Data, cut: Bool) {
        let head = data.prefix(8192)
        var text: String?
        byteOrderMark = false
        if head.starts(with: [0xFF, 0xFE]) {
            encoding = .utf16LittleEndian
            text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian)
            byteOrderMark = true
        } else if head.starts(with: [0xFE, 0xFF]) {
            encoding = .utf16BigEndian
            text = String(data: data.dropFirst(2), encoding: .utf16BigEndian)
            byteOrderMark = true
        } else if head.contains(0) {
            content = .binary(data.count)
            return
        } else {
            byteOrderMark = head.starts(with: [0xEF, 0xBB, 0xBF])
            if let t = String(data: byteOrderMark ? data.dropFirst(3) : data, encoding: .utf8) {
                encoding = .utf8
                text = t
            } else if cut {
                encoding = .utf8
                text = String(decoding: data, as: UTF8.self)
            } else {
                encoding = .windowsCP1252
                text = String(data: data, encoding: .windowsCP1252)
            }
        }
        guard let text else {
            content = .binary(data.count)
            return
        }
        original = data
        lineEnding = text.contains("\r\n") ? "\r\n" : "\n"
        // Tailing, or with the end showing: the end stays in view as it grows, as tail -f does.
        let wasText = content == .text
        rebuildRows()
        let followingEnd = wasText && (tailing || scrollRow + visibleRows >= rowCount)
        lines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }).map(String.init)
        if lines.isEmpty { lines = [""] }
        readOnly = cut
        content = .text
        caret = clamp(caret)
        anchor = anchor.map(clamp)
        version += 1
        savedVersion = version
        undoStack = []
        redoStack = []
        if followingEnd { scrollToEnd() }
        applyPendingLine()
    }

    /// The text as it's written to the file: its own line endings and encoding.
    private func encoded() -> Data? {
        let text = lines.joined(separator: lineEnding)
        guard var data = text.data(using: encoding) else { return nil }
        if byteOrderMark {
            switch encoding {
            case .utf16LittleEndian: data = Data([0xFF, 0xFE]) + data
            case .utf16BigEndian: data = Data([0xFE, 0xFF]) + data
            default: data = Data([0xEF, 0xBB, 0xBF]) + data
            }
        }
        return data
    }

    func save(_ done: @escaping (Bool) -> Void = { _ in }) { save(force: false, done) }

    /// `force`: save even over changes made on disk since it was read (Overwrite, from the conflict bar).
    private func save(force: Bool, _ done: @escaping (Bool) -> Void) {
        guard case .text = content, !readOnly else { return done(false) }
        guard hasUnsavedChanges || deletedOnDisk else { return done(true) }
        // Changed on disk since it was read (not just deleted, which saving puts back): ask before writing over it.
        if !force, let known = diskSignature, !saving {
            saving = true
            signature { [weak self] answered, now in
                self?.post {
                    guard let self else { return }
                    self.saving = false
                    if answered, let now, now != known { return self.showConflict(then: done) }
                    self.writeNow(done)
                }
            }
            return
        }
        writeNow(done)
    }

    private func writeNow(_ done: @escaping (Bool) -> Void) {
        guard let data = encoded() else {
            say("Can't write it in \(encoding == .windowsCP1252 ? "Windows-1252" : "its encoding"): it has characters that can't be", problem: true)
            return done(false)
        }
        let savingVersion = version
        saving = true
        write(data) { [weak self] problem in
            self?.post {
                guard let self else { return }
                if let problem {
                    self.saving = false
                    self.say("Couldn't save: \(problem)", problem: true)
                    return done(false)
                }
                self.original = data
                self.savedVersion = savingVersion
                self.changedOnDisk = false
                self.deletedOnDisk = false
                self.endConflict()
                // Our own write: its signature is what's on disk now, so the change it makes is nothing new. Still saving
                // until it's known, so the watch doesn't take the write for someone else's.
                self.signature { [weak self] answered, sig in
                    self?.post {
                        if answered { self?.diskSignature = sig }
                        self?.saving = false
                    }
                }
                self.say("Saved", problem: false)
                done(true)
            }
        }
    }

    // MARK: Changes on disk

    /// About once a second, from the window's timer: the signature on disk, and what it means. On this PC whether it's
    /// showing or not; over ssh only while it's showing (it catches up on coming back to it).
    func syncTick(showing: Bool) {
        if !isLocal, showing, let heard = lastHeard, Date().timeIntervalSince(heard) > 5, watchLive != false {
            watchLive = false
            invalidate()
        }
        guard content != .loading, !syncing, !saving, !reading, isLocal || showing, Date().timeIntervalSince(lastSync) >= 1 else { return }
        lastSync = Date()
        syncing = true
        signature { [weak self] answered, sig in
            self?.post {
                guard let self else { return }
                self.syncing = false
                if !self.isLocal, answered {
                    self.lastHeard = Date()
                    if self.watchLive != true { self.watchLive = true; self.invalidate() }
                }
                if answered { self.signatureNow(sig) }
            }
        }
    }

    /// If it changed from what was read or saved, the text catches up quietly, keeping the caret and scroll. With
    /// unsaved edits it only says so: they stay, and saving asks first.
    private func signatureNow(_ sig: String?) {
        guard !reading, !saving else { return }
        switch FileSync.action(known: diskSignature, now: sig, hasUnsavedEdits: hasUnsavedChanges) {
        case .nothing:
            if deletedOnDisk { deletedOnDisk = false; invalidate() }
        case .reload:
            reload()
        case .changedUnderEdits:
            if !changedOnDisk { changedOnDisk = true; invalidate() }
        case .deleted:
            if !deletedOnDisk { deletedOnDisk = true; invalidate() }
        }
    }

    func toggleTail() {
        tailing.toggle()
        if tailing { scrollToEnd(); lastSync = .distantPast }
        invalidate()
    }

    private func scrollToEnd() {
        guard case .text = content else { return }
        rebuildRows()
        // Only the view moves, as the Mac's scrollToEndOfDocument does: the caret stays where it is.
        scrollRow = max(rowCount - visibleRows, 0)
    }

    /// Saving over a file changed on disk: a bar over the file asks what to do.
    private func showConflict(then done: @escaping (Bool) -> Void) {
        conflict = done
        changedOnDisk = true
        invalidate()
    }

    private static let barTitles = ["Compare", "Overwrite", "Revert", "Cancel"]

    private func pressBar(_ i: Int) {
        switch i {
        case 0: toggleCompare()
        case 1:
            let done = conflict
            endConflict()
            save(force: true, done ?? { _ in })
        case 2:
            // Drop the edits and show what's on disk.
            let done = conflict
            endConflict()
            savedVersion = version
            changedOnDisk = false
            content = .loading
            original = Data()
            reload()
            done?(true)
        default:
            let done = conflict
            endConflict()
            done?(false)
        }
        invalidate()
    }

    /// What's on disk on the left, the unsaved text on the right; again to go back to editing.
    private func toggleCompare() {
        if compareRows != nil {
            compareRows = nil
            return invalidate()
        }
        let mine = lines
        read(Self.textLimit) { [weak self] data, _ in
            self?.post {
                guard let self, self.conflict != nil else { return }
                let disk = String(decoding: data ?? Data(), as: UTF8.self)
                    .split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }).map(String.init)
                self.compareRows = TextDiff.rows(old: disk, new: mine)
                self.compareScroll = 0
                self.invalidate()
            }
        }
    }

    private func endConflict() {
        conflict = nil
        compareRows = nil
        hoveredBarButton = nil
    }

    private func say(_ text: String, problem: Bool) {
        note = (text, problem, Date())
        invalidate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.6) { [weak self] in self?.post { self?.invalidate() } }
    }

    /// Shift+Alt+F, as the Mac's Option-Command-F: re-indents JSON, YAML or XML, as one step to undo.
    func beautify() {
        guard case .text = content, !readOnly else { return }
        guard let language else { return say("Beautify works on JSON, YAML and XML", problem: true) }
        do {
            // Strict for plain JSON, as on the Mac; JSON with comments (.jsonc, .json5) is re-indented as it is.
            let ext = path.split(separator: ".").last.map { $0.lowercased() } ?? ""
            var formatted = try Prettifier.format(lines.joined(separator: "\n"), as: language, strictJSON: ext == "json" || ext == "geojson" || ext == "webmanifest")
            if formatted.hasSuffix("\n") { formatted.removeLast() }
            let new = formatted.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard new != lines else { return say("Already tidy", problem: false) }
            edit(.other) { $0 = new }
            caret = clamp(caret)
            anchor = nil
        } catch {
            say("Couldn't beautify: \(error.localizedDescription)", problem: true)
        }
    }

    func toggleWrap() {
        wraps.toggle()
        scrollColumn = 0
        builtFor = (-1, 0, false)
        revealCaret()
        invalidate()
    }

    /// While it's showing (the window's timer); `syncTick` does the work.
    func tick() { syncTick(showing: true) }

    // MARK: Lines and positions

    private func clamp(_ p: Pos) -> Pos {
        let line = min(max(p.line, 0), lines.count - 1)
        return Pos(line: line, col: min(max(p.col, 0), lines[line].count))
    }

    /// How many cells the first `col` characters of a line take: a tab four.
    private func cells(_ line: Int, upTo col: Int) -> Int {
        var n = 0
        for (i, ch) in lines[line].enumerated() where i < col { n += ch == "\t" ? 4 : 1 }
        return n
    }

    /// The character at a cell of a line, rounding to the nearer side.
    private func col(_ line: Int, atCell cell: Int) -> Int {
        var n = 0
        for (i, ch) in lines[line].enumerated() {
            let w = ch == "\t" ? 4 : 1
            if cell < n + (w + 1) / 2 { return i }
            n += w
        }
        return lines[line].count
    }

    private func shown(_ line: Int) -> String { lines[line].replacingOccurrences(of: "\t", with: "    ") }

    private func rebuildRows() {
        guard builtFor.version != version || builtFor.columns != columns || builtFor.wraps != wraps else { return }
        builtFor = (version, columns, wraps)
        rowStarts = [0]
        rowStarts.reserveCapacity(lines.count + 1)
        var row = 0
        for i in lines.indices {
            row += wraps ? max(1, (cells(i, upTo: lines[i].count) + columns - 1) / max(columns, 1)) : 1
            rowStarts.append(row)
        }
    }

    private var rowCount: Int { rowStarts.last ?? lines.count }

    /// The line a row is part of, and which of its rows it is.
    private func line(ofRow row: Int) -> (line: Int, sub: Int) {
        var lo = 0, hi = lines.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if rowStarts[mid] <= row { lo = mid } else { hi = mid - 1 }
        }
        return (lo, row - rowStarts[lo])
    }

    /// Where a position is drawn: its row and cell.
    private func place(_ p: Pos) -> (row: Int, cell: Int) {
        let c = cells(p.line, upTo: p.col)
        guard wraps, columns > 0 else { return (p.line, c) }
        var sub = c / columns
        // At the very end of a full row, the caret stays at the end of that row.
        if sub > 0, c % columns == 0, c == cells(p.line, upTo: lines[p.line].count) { sub -= 1 }
        return (rowStarts[p.line] + sub, c - sub * columns)
    }

    private func revealCaret() {
        rebuildRows()
        let r = place(caret)
        if r.row < scrollRow { scrollRow = r.row }
        if r.row >= scrollRow + visibleRows { scrollRow = r.row - visibleRows + 1 }
        if !wraps {
            if r.cell < scrollColumn { scrollColumn = max(r.cell - 4, 0) }
            if r.cell >= scrollColumn + columns { scrollColumn = r.cell - columns + 8 }
        }
    }

    private var selection: (Pos, Pos)? {
        guard let anchor, anchor != caret else { return nil }
        return anchor < caret ? (anchor, caret) : (caret, anchor)
    }

    private func text(_ a: Pos, _ b: Pos) -> String {
        if a.line == b.line { return String(Array(lines[a.line])[a.col..<b.col]) }
        var out = String(Array(lines[a.line])[a.col...])
        for l in (a.line + 1)..<b.line { out += "\n" + lines[l] }
        return out + "\n" + String(Array(lines[b.line])[..<b.col])
    }

    var selectedText: String? { selection.map { text($0.0, $0.1) } }

    // MARK: Editing

    /// Runs a change to the lines as one step to undo; typing in a row is one step.
    private func edit(_ kind: EditKind, _ change: (inout [String]) -> Void) {
        guard !readOnly, case .text = content else { return }
        if kind == .other || lastEdit != .typing {
            undoStack.append((lines, caret))
            if undoStack.count > 500 { undoStack.removeFirst() }
        }
        redoStack = []
        lastEdit = kind
        change(&lines)
        if lines.isEmpty { lines = [""] }
        version += 1
        goalColumn = nil
    }

    /// Puts `text` where the caret (or the selection) is.
    private func insert(_ text: String, kind: EditKind = .typing) {
        let (a, b) = selection ?? (caret, caret)
        let pieces = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        edit(selection == nil ? kind : .other) { lines in
            let first = Array(lines[a.line]), last = Array(lines[b.line])
            let before = String(first[..<a.col]), after = String(last[b.col...])
            var new = pieces
            new[0] = before + new[0]
            new[new.count - 1] += after
            lines.replaceSubrange(a.line...b.line, with: new)
        }
        caret = Pos(line: a.line + pieces.count - 1, col: pieces.count == 1 ? a.col + pieces[0].count : pieces[pieces.count - 1].count)
        anchor = nil
        revealCaret()
        invalidate()
    }

    private func deleteSelection() {
        guard selection != nil else { return }
        insert("", kind: .other)
    }

    /// Backspace or Delete: the selection, or a character (a word, with Ctrl) either side.
    private func delete(forward: Bool, word: Bool) {
        if selection != nil { return deleteSelection() }
        let target = forward ? (word ? wordEnd(caret) : stepRight(caret)) : (word ? wordStart(caret) : stepLeft(caret))
        guard target != caret else { return }
        anchor = target
        insert("", kind: .other)
    }

    private func stepLeft(_ p: Pos) -> Pos { p.col > 0 ? Pos(line: p.line, col: p.col - 1) : p.line > 0 ? Pos(line: p.line - 1, col: lines[p.line - 1].count) : p }
    private func stepRight(_ p: Pos) -> Pos { p.col < lines[p.line].count ? Pos(line: p.line, col: p.col + 1) : p.line + 1 < lines.count ? Pos(line: p.line + 1, col: 0) : p }

    private func isWord(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }

    private func wordStart(_ p: Pos) -> Pos {
        if p.col == 0 { return stepLeft(p) }
        let chars = Array(lines[p.line])
        var i = p.col
        while i > 0, chars[i - 1].isWhitespace { i -= 1 }
        if i > 0, isWord(chars[i - 1]) { while i > 0, isWord(chars[i - 1]) { i -= 1 } } else if i > 0 { i -= 1 }
        return Pos(line: p.line, col: i)
    }

    private func wordEnd(_ p: Pos) -> Pos {
        let chars = Array(lines[p.line])
        if p.col >= chars.count { return stepRight(p) }
        var i = p.col
        while i < chars.count, chars[i].isWhitespace { i += 1 }
        if i < chars.count, isWord(chars[i]) { while i < chars.count, isWord(chars[i]) { i += 1 } } else if i < chars.count { i += 1 }
        return Pos(line: p.line, col: i)
    }

    private func move(to p: Pos, extend: Bool, keepGoal: Bool = false) {
        if extend { anchor = anchor ?? caret } else { anchor = nil }
        caret = clamp(p)
        if !keepGoal { goalColumn = nil }
        lastEdit = nil
        revealCaret()
        invalidate()
    }

    /// Up or down a row (a wrapped one, while wrapping), keeping to the column it started in.
    private func vertical(_ rows: Int, extend: Bool) {
        rebuildRows()
        let here = place(caret)
        let goal = goalColumn ?? here.cell
        let target = min(max(here.row + rows, 0), rowCount - 1)
        if target == here.row {
            move(to: rows < 0 ? Pos(line: 0, col: 0) : Pos(line: lines.count - 1, col: lines[lines.count - 1].count), extend: extend)
            return
        }
        let (l, sub) = line(ofRow: target)
        let cell = wraps ? sub * columns + goal : goal
        move(to: Pos(line: l, col: col(l, atCell: cell)), extend: extend, keepGoal: true)
        goalColumn = goal
    }

    private var indentUnit: String {
        if lines.prefix(400).contains(where: { $0.hasPrefix("\t") }) { return "\t" }
        return language == .json || language == .yaml || isMarkdown ? "  " : "    "
    }

    /// Tab and Shift+Tab over selected lines: each indented, or out.
    private func indent(_ out: Bool) {
        let (a, b) = selection ?? (caret, caret)
        let unit = indentUnit
        edit(.other) { lines in
            for l in a.line...b.line {
                if out {
                    let lead = lines[l].prefix { $0 == " " || $0 == "\t" }
                    let drop = lead.hasPrefix("\t") ? 1 : min(lead.count, unit == "\t" ? 4 : unit.count)
                    lines[l] = String(lines[l].dropFirst(drop))
                } else if !lines[l].isEmpty || a.line == b.line {
                    lines[l] = unit + lines[l]
                }
            }
        }
        anchor = Pos(line: a.line, col: 0)
        caret = clamp(Pos(line: b.line, col: lines[b.line].count))
        invalidate()
    }

    func undo() {
        guard let last = undoStack.popLast() else { return }
        redoStack.append((lines, caret))
        lines = last.lines
        caret = clamp(last.caret)
        anchor = nil
        lastEdit = nil
        version += 1
        revealCaret()
        invalidate()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append((lines, caret))
        lines = next.lines
        caret = clamp(next.caret)
        anchor = nil
        lastEdit = nil
        version += 1
        revealCaret()
        invalidate()
    }

    /// Scrolls to a line (counting from 1) and marks it: now, or once the file has been read.
    func reveal(line: Int) {
        pendingLine = line
        applyPendingLine()
        invalidate()
    }

    private func applyPendingLine() {
        guard let line = pendingLine, case .text = content else { return }
        pendingLine = nil
        markedLine = min(max(line, 1), lines.count)
        caret = Pos(line: markedLine! - 1, col: 0)
        anchor = nil
        rebuildRows()
        scrollRow = max(place(caret).row - visibleRows / 3, 0)
    }

    // MARK: Layout

    private func header(_ a: UIRect, _ s: Float) -> UIRect { UIRect(x: a.x, y: a.y, width: a.width, height: (36 * s).rounded()) }
    private func body(_ a: UIRect, _ s: Float) -> UIRect {
        let h = header(a, s)
        return UIRect(x: a.x, y: h.maxY, width: a.width, height: max(a.maxY - h.maxY, 0))
    }
    private func gutterWidth(_ s: Float) -> Float { Float(max(String(lines.count).count, 3)) * cellSize.width + 22 * s }
    private func textX(_ a: UIRect, _ s: Float) -> Float { body(a, s).x + gutterWidth(s) }
    private func textTop(_ a: UIRect, _ s: Float) -> Float { body(a, s).y + 6 * s }

    /// The header's buttons that show for this file, right to left from the close button.
    private var buttonsShown: [Button] {
        var out: [Button] = []
        if case .text = content {
            if isMarkdown { out.append(.preview) }
            out.append(.tail)
            out.append(.wrap)
            if language != nil { out.append(.beautify) }
            out.append(.save)
        }
        out.append(.close)
        return out
    }

    private func buttonRects(_ a: UIRect, _ s: Float) -> [(Button, UIRect)] {
        let side = (26 * s).rounded(), gap = (4 * s).rounded()
        var x = a.maxX - 10 * s - side
        var out: [(Button, UIRect)] = []
        for b in buttonsShown.reversed() {
            out.append((b, UIRect(x: x, y: (a.y + (header(a, s).height - side) / 2).rounded(), width: side, height: side)))
            x -= side + gap
        }
        return out
    }

    private func glyph(_ b: Button) -> UInt16 {
        switch b {
        case .preview: return 0xE8A1  // a page with a preview
        case .tail: return 0xE70D     // a chevron down, drawn twice (see drawHeader)
        case .wrap: return 0xE751     // a line that wraps round
        case .beautify: return 0xE8FD // indented lines
        case .save: return 0xE74E
        case .close: return 0xE8BB
        }
    }

    private func tip(_ b: Button) -> String {
        switch b {
        case .preview: return "Open Preview"
        case .tail: return tailing ? "Stop Tailing" : "Tail File (keep the end in view as it grows)"
        case .wrap: return wraps ? "Don't Wrap Lines   Alt+Z" : "Wrap Lines   Alt+Z"
        case .beautify: return "Beautify / Format Document   Shift+Alt+F"
        case .save: return "Save   Ctrl+S"
        case .close: return "Close   Ctrl+W"
        }
    }

    // MARK: Syntax colors

    /// The Mac's colors for each kind of token (SyntaxHighlighter there), from the theme.
    private static func color(_ t: SyntaxToken) -> UInt32 {
        let fg = TerminalPalette.foreground, bg = TerminalPalette.background, ansi = TerminalPalette.ansi
        switch t {
        case .comment: return TerminalPalette.mix(fg, bg, 0.42)
        case .key, .tag: return ansi[4]
        case .string: return ansi[2]
        case .number, .entity: return ansi[5]
        case .literal: return ansi[6]
        case .attribute: return ansi[3]
        case .punctuation: return TerminalPalette.mix(fg, bg, 0.5)
        }
    }

    private func buildColors() {
        guard colorsBuilt != version else { return }
        colorsBuilt = version
        lineColors = []
        guard let language, case .text = content else { return }
        let tokens = SyntaxScanner.tokens(in: lines.joined(separator: "\n"), as: language)
        guard !tokens.isEmpty else { return }
        // Where each line starts, counted in UTF-16 as the scanner's ranges are.
        var starts: [Int] = []
        starts.reserveCapacity(lines.count)
        var at = 0
        for l in lines { starts.append(at); at += l.utf16.count + 1 }
        let fg = TerminalPalette.foreground
        var perUnit: [[UInt32]] = lines.map { [UInt32](repeating: fg, count: $0.utf16.count) }
        for (range, token) in tokens {
            let c = Self.color(token)
            var lo = 0, hi = lines.count - 1
            while lo < hi { let mid = (lo + hi + 1) / 2; if starts[mid] <= range.location { lo = mid } else { hi = mid - 1 } }
            var line = lo, offset = range.location - starts[lo], left = range.length
            while left > 0, line < lines.count {
                let room = perUnit[line].count - offset
                for k in offset..<(offset + max(min(room, left), 0)) { perUnit[line][k] = c }
                left -= room + 1
                line += 1
                offset = 0
            }
        }
        // From UTF-16 units to cells as drawn: a character takes its first unit's color, a tab four cells.
        lineColors = lines.enumerated().map { i, text in
            var out: [UInt32] = [], unit = 0
            for ch in text {
                let c = perUnit[i][min(unit, max(perUnit[i].count - 1, 0))]
                if ch == "\t" { out += [c, c, c, c] } else { out.append(c) }
                unit += ch.utf16.count
            }
            return out
        }
    }

    // MARK: Drawing

    /// The canvas last drawn on, for measuring the conflict bar's buttons when a click comes.
    private weak var barCanvas: Canvas?

    func draw(on canvas: Canvas, in a: UIRect, scale s: Float) {
        lastArea = a
        lastScale = s
        barCanvas = canvas
        let p = PanelPaint(canvas: canvas, scale: s), fg = p.fg
        p.backdrop(a, TerminalPalette.background)
        sol_canvas_push_clip(canvas.raw, a.x, a.y, a.width, a.height)
        defer { sol_canvas_pop_clip(canvas.raw) }
        let b = body(a, s)
        switch content {
        case .loading: p.label("Loading…", UIRect(x: b.x + 16 * s, y: b.y + 12 * s, width: b.width - 32 * s, height: 22 * s), alpha: 0.55)
        case .failed(let why): p.label(why, UIRect(x: b.x + 16 * s, y: b.y + 12 * s, width: b.width - 32 * s, height: 22 * s), alpha: 0.55)
        case .binary(let size):
            p.label("A binary file (\(Self.size(size))): there's no text to show.", UIRect(x: b.x + 16 * s, y: b.y + 12 * s, width: b.width - 32 * s, height: 22 * s), alpha: 0.55)
        case .image(let data): drawImage(data, on: canvas, in: b, p, s)
        case .text:
            if let rows = compareRows { drawCompare(rows, on: canvas, in: a, p, s) } else { drawText(on: canvas, in: a, p, s) }
        }
        drawConflictBar(a, p, s)
        drawHeader(a, p, s, fg)
    }

    // MARK: The conflict bar and Compare

    /// The bar's place, its title's width, and its buttons (Compare, Overwrite, Revert, Cancel), at the page's bottom right
    /// as the Mac puts it.
    private func conflictBarLayout(_ a: UIRect, _ p: PanelPaint, _ s: Float) -> (box: UIRect, title: String, buttons: [(String, UIRect)])? {
        guard conflict != nil else { return nil }
        let title = "\u{201C}\(name)\u{201D} changed on disk"
        let titles = [compareRows == nil ? "Compare" : "Back to Editing"] + Self.barTitles.dropFirst()
        let widths = titles.map { p.width($0, pixels: 12.5, semibold: true) + 12 * s }
        let titleW = min(p.width(title, pixels: 12, semibold: true), 360 * s)
        let w = min(32 * s + titleW + 12 * s + widths.reduce(0, +) + 4 * s * Float(widths.count) + 8 * s, a.width - 16 * s), h = 32 * s
        let box = UIRect(x: max(a.x + 8 * s, a.maxX - w - 12 * s), y: a.maxY - h - 10 * s, width: w, height: h)
        var x = box.maxX - 8 * s
        var buttons: [(String, UIRect)] = []
        for (t, bw) in zip(titles, widths).reversed() {
            x -= bw
            buttons.insert((t, UIRect(x: x, y: box.y + 5 * s, width: bw, height: h - 10 * s)), at: 0)
            x -= 4 * s
        }
        return (box, title, buttons)
    }

    private func drawConflictBar(_ a: UIRect, _ p: PanelPaint, _ s: Float) {
        guard let l = conflictBarLayout(a, p, s) else { return }
        let b = l.box, fg = p.fg
        p.fill(UIRect(x: b.x, y: b.y + 2 * s, width: b.width, height: b.height), 0x000000, 0.25, radius: 8)
        p.fill(b, TerminalPalette.surface, 1, radius: 8)
        sol_canvas_stroke_rounded(p.canvas.raw, b.x + 0.5, b.y + 0.5, b.width - 1, b.height - 1, 8 * s, fg, TerminalPalette.isDark ? 0.10 : 0.14, 1)
        p.icon(0xE7BA, UIRect(x: b.x + 8 * s, y: b.y, width: 20 * s, height: b.height), pixels: 12, color: TerminalPalette.ansi[3], alpha: 1)
        let titleRight = (l.buttons.first?.1.x ?? b.maxX) - 8 * s
        p.label(l.title, UIRect(x: b.x + 32 * s, y: b.y, width: max(titleRight - b.x - 32 * s, 0), height: b.height), pixels: 12, semibold: true)
        for (i, (title, r)) in l.buttons.enumerated() {
            if hoveredBarButton == i { p.fill(r, fg, 0.08, radius: 5) }
            p.label(title, UIRect(x: r.x + 6 * s, y: r.y, width: r.width - 8 * s, height: r.height), pixels: 12.5, semibold: true, color: TerminalPalette.accent)
        }
    }

    /// What's on disk (left) beside the unsaved edits (right), line against line: removed lines in red, added in green.
    private func drawCompare(_ rows: [TextDiff.Row], on canvas: Canvas, in a: UIRect, _ p: PanelPaint, _ s: Float) {
        let b = body(a, s), lh = cellSize.height, half = (b.width / 2).rounded()
        let titleH = 24 * s
        visibleRows = max(Int((b.height - titleH - 6 * s) / lh), 1)
        compareScroll = min(compareScroll, max(rows.count - visibleRows, 0))
        let digits = max(String(rows.count).count, 3), gutter = Float(digits) * cellSize.width + 18 * s
        let red = TerminalPalette.ansi[1], green = TerminalPalette.ansi[2]
        for (side, x0) in [(0, b.x), (1, b.x + half)] {
            p.fill(UIRect(x: x0, y: b.y, width: half, height: titleH), TerminalPalette.chrome, 0.5)
            p.label(side == 0 ? "On Disk" : "Your Edits", UIRect(x: x0 + 12 * s, y: b.y, width: half - 24 * s, height: titleH), pixels: 11.5, semibold: true, alpha: 0.7)
        }
        p.fill(UIRect(x: b.x + half, y: b.y, width: 1, height: b.height), p.fg, 0.12)
        let top = b.y + titleH + 4 * s
        let cellsPerSide = max(Int((half - gutter - 12 * s) / max(cellSize.width, 1)), 4)
        sol_canvas_push_clip(canvas.raw, b.x, top, b.width, b.maxY - top)
        for k in 0..<min(visibleRows + 1, rows.count - compareScroll) {
            let row = rows[compareScroll + k], y = top + Float(k) * lh
            for (side, x0) in [(0, b.x), (1, b.x + half)] {
                let cell = side == 0 ? row.left : row.right
                let tint: UInt32? = row.kind == .same ? nil : (side == 0 ? (cell == nil ? nil : red) : (cell == nil ? nil : green))
                if let tint { p.fill(UIRect(x: x0, y: y, width: half, height: lh), tint, 0.16) }
                else if row.kind != .same { p.fill(UIRect(x: x0, y: y, width: half, height: lh), p.fg, 0.03) }
                guard let cell else { continue }
                let number = String(cell.number), w = Float(number.count) * cellSize.width
                p.mono(number, x: x0 + gutter - 10 * s - w, y: y, maxCells: number.count, color: TerminalPalette.mix(p.fg, TerminalPalette.background, 0.4))
                let text = cell.text.replacingOccurrences(of: "\t", with: "    ")
                p.mono(text, x: x0 + gutter, y: y, maxCells: cellsPerSide, color: p.fg)
            }
        }
        sol_canvas_pop_clip(canvas.raw)
    }

    private func drawHeader(_ a: UIRect, _ p: PanelPaint, _ s: Float, _ fg: UInt32) {
        let h = header(a, s), buttons = buttonRects(a, s)
        p.backdrop(h, TerminalPalette.chrome)
        p.fill(UIRect(x: a.x, y: h.maxY - 1, width: a.width, height: 1), fg, 0.10)
        p.icon(FileKind(name: name).glyph, UIRect(x: a.x + 10 * s, y: h.y, width: 18 * s, height: h.height), pixels: 12, alpha: 0.65)
        let right = (buttons.last?.1.x ?? a.maxX) - 10 * s
        let nameW = min(p.width(name, pixels: 13, semibold: true), max(right - a.x - 36 * s, 0))
        p.label(name, UIRect(x: a.x + 34 * s, y: h.y, width: nameW + 2, height: h.height), pixels: 13, semibold: true)
        var x = a.x + 34 * s + nameW + 8 * s
        // Unsaved: a dot after the name, as on the Mac.
        if hasUnsavedChanges {
            sol_canvas_fill_ellipse(p.canvas.raw, x + 3 * s, h.midY, 3.5 * s, 3.5 * s, fg, 0.75)
            x += 14 * s
        }
        let showingNote = note.map { Date().timeIntervalSince($0.at) < 2.5 } ?? false
        // Gone, changed under unsaved edits, or (over ssh) whether the host is answering: in its color, as on the Mac.
        if !showingNote {
            func tag(_ text: String, _ color: UInt32, dot: Bool) {
                let w = p.width(text, pixels: 11, semibold: true)
                guard right - x > w + (dot ? 44 : 30) * s else { return }
                var tx = x
                if dot {
                    sol_canvas_fill_ellipse(p.canvas.raw, x + 3 * s, h.midY, 3 * s, 3 * s, color, 1)
                    tx += 10 * s
                }
                p.label(text, UIRect(x: tx, y: h.y, width: w + 2, height: h.height), pixels: 11, semibold: true, color: color)
                x = tx + w + 8 * s
            }
            if deletedOnDisk { tag(readOnly ? "Deleted" : "Deleted \u{00B7} Ctrl+S saves it again", TerminalPalette.ansi[1], dot: false) }
            else if changedOnDisk { tag("Changed on Disk", TerminalPalette.ansi[3], dot: false) }
            else if let live = watchLive { tag(live ? "Live" : "Not Updating", live ? TerminalPalette.ansi[2] : TerminalPalette.ansi[3], dot: true) }
        }
        if let note, showingNote {
            p.label(note.text, UIRect(x: x, y: h.y, width: max(right - x, 0), height: h.height), pixels: 11.5, color: note.problem ? 0xE06B6B : TerminalPalette.accent)
        } else {
            var detail = folder
            if readOnly { detail = "read-only: only its first \(Self.textLimit / 1024 / 1024) MB  ·  " + folder }
            if right - x > 40 * s { p.label(detail, UIRect(x: x, y: h.y, width: right - x, height: h.height), pixels: 11.5, alpha: 0.45) }
        }
        for (button, r) in buttons {
            let on = (button == .tail && tailing) || (button == .wrap && wraps)
            let enabled = button != .save || ((hasUnsavedChanges || deletedOnDisk) && !readOnly)
            if hovered == button && enabled || on { p.fill(r, on ? TerminalPalette.accent : fg, on ? 0.22 : 0.10, radius: 5) }
            let color: UInt32? = on ? TerminalPalette.accent : nil, alpha: Float = enabled ? (hovered == button || on ? 0.95 : 0.7) : 0.25
            if button == .tail {
                // Two chevrons, one over the other, as the Mac's chevron.down.2.
                p.icon(glyph(button), UIRect(x: r.x, y: r.y - 3 * s, width: r.width, height: r.height), pixels: 10, color: color, alpha: alpha)
                p.icon(glyph(button), UIRect(x: r.x, y: r.y + 3 * s, width: r.width, height: r.height), pixels: 10, color: color, alpha: alpha)
            } else {
                p.icon(glyph(button), r, pixels: button == .close ? 10 : 12, color: color, alpha: alpha)
            }
        }
        // The hovered button's name below it, as the Mac's tooltips show.
        if let hovered, let r = buttons.first(where: { $0.0 == hovered })?.1 {
            let text = tip(hovered), w = p.width(text, pixels: 12) + 18 * s
            let box = UIRect(x: min(max(r.x + r.width / 2 - w / 2, a.x + 6 * s), a.maxX - w - 6 * s), y: r.maxY + 6 * s, width: w, height: 24 * s)
            p.fill(UIRect(x: box.x, y: box.y + 2 * s, width: box.width, height: box.height), 0x000000, 0.25, radius: 6)
            p.fill(box, TerminalPalette.mix(fg, TerminalPalette.chrome, 0.12), 1, radius: 6)
            sol_canvas_stroke_rounded(p.canvas.raw, box.x + 0.5, box.y + 0.5, box.width - 1, box.height - 1, 6 * s, fg, 0.18, 1)
            p.label(text, UIRect(x: box.x + 9 * s, y: box.y, width: box.width - 18 * s, height: box.height), pixels: 12)
        }
    }

    private func drawText(on canvas: Canvas, in a: UIRect, _ p: PanelPaint, _ s: Float) {
        let b = body(a, s), lh = cellSize.height, gutter = gutterWidth(s), top = textTop(a, s), tx = b.x + gutter
        visibleRows = max(Int((b.height - 6 * s) / lh), 1)
        columns = max(Int((b.width - gutter - 12 * s) / max(cellSize.width, 1)), 8)
        rebuildRows()
        buildColors()
        scrollRow = min(scrollRow, max(rowCount - 1, 0))
        p.fill(UIRect(x: b.x, y: b.y, width: gutter - 8 * s, height: b.height), TerminalPalette.chrome, 0.35)
        let numberColor = TerminalPalette.mix(p.fg, TerminalPalette.background, 0.4)
        let sel = selection, focusedCaret = TerminalPalette.accent
        var row = scrollRow
        while row < min(scrollRow + visibleRows + 1, rowCount) {
            let (l, sub) = line(ofRow: row), y = top + Float(row - scrollRow) * lh
            if markedLine == l + 1 { p.fill(UIRect(x: b.x, y: y, width: b.width, height: lh), TerminalPalette.accent, 0.14) }
            else if caret.line == l && sel == nil { p.fill(UIRect(x: tx - 4 * s, y: y, width: b.maxX - tx + 4 * s, height: lh), p.fg, 0.04) }
            if sub == 0 {
                let number = String(l + 1), w = Float(number.count) * cellSize.width
                p.mono(number, x: b.x + gutter - 16 * s - w, y: y, maxCells: number.count, color: caret.line == l ? p.fg : numberColor)
            }
            // The row's piece of the line.
            let text = Array(shown(l))
            let start = wraps ? sub * columns : scrollColumn, end = min(text.count, wraps ? start + columns : scrollColumn + columns)
            // What's selected on it.
            if let (s0, s1) = sel, s0.line <= l, l <= s1.line {
                let from = s0.line == l ? cells(l, upTo: s0.col) : 0
                let to = s1.line == l ? cells(l, upTo: s1.col) : text.count + 1
                let a0 = max(from, start), a1 = min(to, wraps ? start + columns : scrollColumn + columns + 1)
                if a1 > a0 { p.fill(UIRect(x: tx + Float(a0 - start) * cellSize.width, y: y, width: Float(a1 - a0) * cellSize.width, height: lh), TerminalPalette.accent, 0.30) }
            }
            if start < end {
                // In runs of one color each.
                let colors = l < lineColors.count && lineColors[l].count == text.count ? lineColors[l] : nil
                var k = start
                while k < end {
                    let c = colors?[k] ?? p.fg
                    var j = k + 1
                    while j < end, (colors?[j] ?? p.fg) == c { j += 1 }
                    p.mono(String(text[k..<j]), x: tx + Float(k - start) * cellSize.width, y: y, maxCells: j - k, color: c)
                    k = j
                }
            }
            row += 1
        }
        // The caret.
        let c = place(caret)
        if c.row >= scrollRow && c.row < scrollRow + visibleRows + 1 && !readOnly {
            let x = tx + Float(c.cell - (wraps ? 0 : scrollColumn)) * cellSize.width
            if x >= tx - 1 { p.fill(UIRect(x: x.rounded(), y: top + Float(c.row - scrollRow) * lh, width: max((1.5 * s).rounded(), 1), height: lh), focusedCaret, 1) }
        }
    }

    private func drawImage(_ data: Data, on canvas: Canvas, in b: UIRect, _ p: PanelPaint, _ s: Float) {
        var image = images[canvas.raw]
        if image == nil {
            let id = data.withUnsafeBytes { sol_canvas_load_image(canvas.raw, $0.bindMemory(to: UInt8.self).baseAddress, Int32($0.count)) }
            var w: Int32 = 0, h: Int32 = 0
            sol_canvas_image_size(canvas.raw, id, &w, &h)
            image = (id, w, h)
            images[canvas.raw] = image
        }
        guard let image, image.id >= 0, image.width > 0, image.height > 0 else {
            p.label("Windows can't read this image.", UIRect(x: b.x + 16 * s, y: b.y + 12 * s, width: b.width - 32 * s, height: 22 * s), alpha: 0.55)
            return
        }
        // Fitted to the page, never larger than it is (at this display's scale), with its size beneath.
        let room = UIRect(x: b.x + 16 * s, y: b.y + 16 * s, width: max(b.width - 32 * s, 1), height: max(b.height - 50 * s, 1))
        let natural = (w: Float(image.width) * s, h: Float(image.height) * s)
        let fit = min(1, room.width / natural.w, room.height / natural.h)
        let w = (natural.w * fit).rounded(), h = (natural.h * fit).rounded()
        let x = (room.x + (room.width - w) / 2).rounded(), y = (room.y + (room.height - h) / 2).rounded()
        // A checkerboard behind, so transparent parts show as such.
        let cell = (8 * s).rounded()
        sol_canvas_push_clip(canvas.raw, x, y, w, h)
        var row = 0, cy = y
        while cy < y + h {
            var cx = x + (row % 2 == 0 ? 0 : cell)
            while cx < x + w {
                p.fill(UIRect(x: cx, y: cy, width: cell, height: cell), p.fg, 0.06)
                cx += cell * 2
            }
            cy += cell
            row += 1
        }
        sol_canvas_pop_clip(canvas.raw)
        sol_canvas_draw_image(canvas.raw, image.id, x, y, w, h, 1)
        let caption = "\(image.width) × \(image.height)" + (fit < 1 ? "  ·  \(Int((fit * 100).rounded()))%" : "")
        let cw = p.width(caption, pixels: 11.5)
        p.label(caption, UIRect(x: b.x + (b.width - cw) / 2, y: b.maxY - 28 * s, width: cw + 2, height: 20 * s), pixels: 11.5, alpha: 0.5)
    }

    static func size(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) bytes" }
        if bytes < 1024 * 1024 { return String(format: "%.0f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / 1024 / 1024)
    }

    // MARK: Mouse

    /// The text position at a point of the page.
    private func position(atX x: Float, y: Float) -> Pos {
        let a = lastArea, s = lastScale
        rebuildRows()
        let row = min(max(scrollRow + Int(floor((y - textTop(a, s)) / cellSize.height)), 0), max(rowCount - 1, 0))
        let (l, sub) = line(ofRow: row)
        let cell = max(Int(((x - textX(a, s)) / cellSize.width).rounded()), 0) + (wraps ? sub * columns : scrollColumn)
        return Pos(line: l, col: col(l, atCell: cell))
    }

    func mouse(_ message: UINT, x: Float, y: Float, in a: UIRect, scale s: Float) -> Bool {
        if let canvas = barCanvas, let l = conflictBarLayout(a, PanelPaint(canvas: canvas, scale: s), s) {
            let i = l.buttons.firstIndex { $0.1.contains(x, y) }
            if i != hoveredBarButton { hoveredBarButton = i; invalidate() }
            if l.box.contains(x, y) {
                if message == Win.WM_LBUTTONUP, let i { pressBar(i) }
                return true
            }
            if compareRows != nil { return true }
        }
        let before = hovered
        let onButton = buttonRects(a, s).first { $0.1.contains(x, y) }?.0
        hovered = onButton
        let inText = body(a, s).contains(x, y)
        if case .text = content {
            switch message {
            case Win.WM_LBUTTONDOWN where onButton == nil && inText:
                let p = position(atX: x, y: y)
                move(to: p, extend: GetKeyState(Win.VK_SHIFT) < 0)
                selecting = true
            case Win.WM_LBUTTONDBLCLK where onButton == nil && inText:
                // The word under the pointer.
                let p = position(atX: x, y: y), chars = Array(lines[p.line])
                var a = min(p.col, chars.count), z = a
                if a < chars.count, !isWord(chars[a]), a > 0, isWord(chars[a - 1]) { a -= 1; z = a }
                while a > 0, isWord(chars[a - 1]) { a -= 1 }
                while z < chars.count, isWord(chars[z]) { z += 1 }
                if z == a, z < chars.count { z += 1 }
                anchor = Pos(line: p.line, col: a)
                caret = Pos(line: p.line, col: z)
                if anchor == caret { anchor = nil }
                selecting = false
                invalidate()
            case Win.WM_MOUSEMOVE where selecting:
                let p = position(atX: x, y: y)
                if anchor == nil { anchor = caret }
                caret = p
                revealCaret()
                invalidate()
            case Win.WM_LBUTTONUP:
                selecting = false
            default: break
            }
        }
        if message == Win.WM_LBUTTONUP, let onButton { press(onButton) }
        if before != hovered { invalidate() }
        return true
    }

    private func press(_ b: Button) {
        switch b {
        case .preview: openPreview()
        case .tail: toggleTail()
        case .wrap: toggleWrap()
        case .beautify: beautify()
        case .save: save()
        case .close: close()
        }
    }

    func mouseLeft() {
        guard hovered != nil else { return }
        hovered = nil
        invalidate()
    }

    func scroll(lines: Int, x: Float, y: Float, in a: UIRect, scale s: Float) {
        if compareRows != nil {
            compareScroll = max(compareScroll - lines, 0)
            return invalidate()
        }
        rebuildRows()
        // Shift turns the wheel sideways, as in most editors.
        if GetKeyState(Win.VK_SHIFT) < 0 && !wraps { scrollColumn = max(scrollColumn - lines * 2, 0) }
        else { scrollRow = min(max(scrollRow - lines, 0), max(rowCount - visibleRows, 0)) }
        invalidate()
    }

    // MARK: Keys

    func key(_ key: Int32, shift: Bool, ctrl: Bool) -> Bool {
        guard case .text = content else {
            if key == Win.VK_ESCAPE { close(); return true }
            return ctrl
        }
        switch key {
        case Win.VK_LEFT:
            if selection != nil && !shift { move(to: selection!.0, extend: false) }
            else { move(to: ctrl ? wordStart(caret) : stepLeft(caret), extend: shift) }
        case Win.VK_RIGHT:
            if selection != nil && !shift { move(to: selection!.1, extend: false) }
            else { move(to: ctrl ? wordEnd(caret) : stepRight(caret), extend: shift) }
        case Win.VK_UP: if ctrl { scrollRow = max(scrollRow - 1, 0); invalidate() } else { vertical(-1, extend: shift) }
        case Win.VK_DOWN: if ctrl { scrollRow += 1; invalidate() } else { vertical(1, extend: shift) }
        case Win.VK_PRIOR: vertical(-max(visibleRows - 1, 1), extend: shift)
        case Win.VK_NEXT: vertical(max(visibleRows - 1, 1), extend: shift)
        case Win.VK_HOME:
            if ctrl { move(to: Pos(line: 0, col: 0), extend: shift) } else {
                // To the text's start, then the line's, as editors do.
                let lead = lines[caret.line].prefix { $0 == " " || $0 == "\t" }.count
                move(to: Pos(line: caret.line, col: caret.col == lead ? 0 : lead), extend: shift)
            }
        case Win.VK_END: move(to: ctrl ? Pos(line: lines.count - 1, col: lines[lines.count - 1].count) : Pos(line: caret.line, col: lines[caret.line].count), extend: shift)
        case Win.VK_BACK: delete(forward: false, word: ctrl)
        case Win.VK_DELETE:
            if shift && !ctrl, let t = selectedText { copy(t); deleteSelection() } else { delete(forward: true, word: ctrl) }
        case Win.VK_RETURN:
            guard !ctrl else { return true }
            // A new line indented as this one.
            let lead = String(lines[caret.line].prefix { $0 == " " || $0 == "\t" })
            insert("\n" + lead, kind: .other)
        case Win.VK_TAB:
            if shift || (selection.map { $0.0.line != $0.1.line } ?? false) { indent(shift) } else { insert(indentUnit, kind: .other) }
        case Win.VK_ESCAPE:
            if compareRows != nil { compareRows = nil; invalidate() }
            else if anchor != nil || markedLine != nil { anchor = nil; markedLine = nil; invalidate() }
        case 0x41 where ctrl:
            anchor = Pos(line: 0, col: 0)
            caret = Pos(line: lines.count - 1, col: lines[lines.count - 1].count)
            invalidate()
        case 0x43 where ctrl: if let t = selectedText { copy(t) } else { copy(lines[caret.line] + lineEnding) }
        case 0x58 where ctrl:
            if let t = selectedText { copy(t); deleteSelection() }
            else if !readOnly {
                // The whole line, as editors cut with nothing selected.
                copy(lines[caret.line] + lineEnding)
                let l = caret.line
                edit(.other) { lines in lines.remove(at: l) }
                caret = clamp(Pos(line: l, col: 0))
                invalidate()
            }
        case 0x56 where ctrl: if let t = paste() { insert(t, kind: .other) }
        case 0x5A where ctrl: if shift { redo() } else { undo() }
        case 0x59 where ctrl: redo()
        case 0x53 where ctrl: save()
        case 0x74: reload()  // F5
        default: return ctrl
        }
        return true
    }

    func typed(_ text: String) {
        guard case .text = content, !readOnly else { return }
        insert(text)
    }

    // For tests
    var textLines: [String]? { if case .text = content { return lines }; return nil }
    /// The color drawn at a cell of a line, for tests.
    func colorAt(line: Int, cell: Int) -> UInt32? {
        buildColors()
        return line < lineColors.count && cell < lineColors[line].count ? lineColors[line][cell] : nil
    }
    var imageSize: (Int, Int)? { images.values.first.map { (Int($0.width), Int($0.height)) } }
    func press(button: Button) { press(button) }
    var hasConflict: Bool { conflict != nil }
    /// A look at the disk now, without waiting the second between looks.
    func syncNowForTesting() {
        lastSync = .distantPast
        syncTick(showing: true)
    }
    func pressConflict(_ title: String) { if let i = Self.barTitles.firstIndex(of: title) { pressBar(i) } }
    /// Types at the caret, as the keyboard would.
    func typeForTesting(_ text: String) { insert(text) }
}
