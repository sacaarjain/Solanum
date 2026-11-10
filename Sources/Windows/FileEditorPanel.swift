import CCanvas
import Foundation
import WinSDK

/// A file open above the terminal, as on the Mac's editor (FileEditor.swift there): its text, to edit and save, with the
/// header's buttons from left to right: Open Preview (Markdown), Tail File (the double chevron: the end stays in view as
/// the file grows), wrap lines, Beautify (JSON, YAML, XML), Save (dimmed until there's something to save) and close.
/// Images show fitted to the page. Ctrl+S saves, Alt+Z wraps, Shift+Alt+F beautifies.
///
/// Ctrl+F finds in the file and Ctrl+H replaces, as the Mac's ⌘F and VS Code do (Core's EditorFind): "3 of 12", Alt+C, W and
/// R for case, whole words and regular expressions, Enter and F3 to step. Logs are colored as on the Mac (Core's
/// LogFormat): levels, fields, stack traces and markers, any color codes a logger wrote hidden and shown as colors, and
/// the header's palette button picks the format and the colors.
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

    enum Button: String, CaseIterable { case preview, logColors, tail, wrap, beautify, save, close }

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
    /// Colored as JSON, YAML, XML or a log; a file with color codes in it, or one a log format names, is a log.
    private(set) var language: SyntaxLanguage?
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

    // Logs.
    /// The text has ANSI color codes (a log written with colors): they take no room and aren't drawn, the log's
    /// coloring shows their colors, and copying leaves them out. The file keeps them.
    private(set) var hidesEscapes = false
    /// The format coloring this log, and the one picked from the header's menu (nil: chosen by itself).
    private(set) var logFormat: LogFormat?
    private var logFormatPick: String?
    private var logCache: LogPaintCache?
    private var logBuilt = -1
    /// Each line's look as drawn: a color for each cell, which cells are bold, and a tint across the line.
    private struct LogLook { var colors: [UInt32], bold: [Bool], wash: UInt32? }
    private var logLooks: [Int: LogLook] = [:]
    /// For lines with color codes: which characters are part of one, and hidden.
    private var escapeMasks: [Int: [Bool]] = [:]
    private var masksBuilt = -1
    private var formatsObserver: NSObjectProtocol?

    // Find.
    private struct Find {
        var field = TextFieldState("")
        var replace = TextFieldState("")
        /// A field's text all selected, as on opening: typing replaces it.
        var fieldSelected = false, replaceSelected = false
        var showsReplace = false
        /// The replace field has the keyboard, rather than the find field.
        var inReplace = false
        /// UTF-16 ranges in the text with its lines joined by "\n".
        var matches: [NSRange] = []
        var capped = false
        var index: Int?
        /// Where it started, so typing more refines it from there rather than wandering down the file.
        var anchor = 0
        var badRegex = false
        var searchedVersion = -1
        var generation = 0
    }
    enum FindPart: Equatable { case bar, chevron, field, replaceField, matchCase, wholeWord, regex, previous, next, close, replaceOne, replaceAll }
    private var find: Find?
    /// The find bar has the keyboard (else the text has).
    private(set) var findFocused = false
    /// Kept from one file to the next, as in VS Code.
    static var findOptions = EditorFindOptions()
    private var findText: (version: Int, buffer: FindBuffer, starts: [Int])?
    private var findParts: [(FindPart, UIRect)] = []
    private var findBox: UIRect?
    private var hoveredFind: FindPart?
    /// Below this a plain search runs as the key is typed; it takes less than a frame.
    private static let instantFindLength = 2_000_000
    private static let instantRegexLength = 200_000

    var invalidate: () -> Void = {}
    var close: () -> Void = {}
    var post: (@escaping () -> Void) -> Void = { $0() }
    var copy: (String) -> Void = { _ in }
    var paste: () -> String? = { nil }
    var openPreview: () -> Void = {}
    /// A menu under a rectangle of the window (the log palette's).
    var showMenu: (_ items: [MenuItem], _ under: UIRect) -> Void = { _, _ in }
    /// Asks for a line of text (Add Marker…): what it's for, and the row that takes what's typed.
    var askText: (_ placeholder: String, _ action: String, _ done: @escaping (String) -> Void) -> Void = { _, _, _ in }
    /// Windows' Open dialog, for a file to import; nil when none was picked.
    var pickFile: (_ title: String) -> String? = { _ in nil }
    /// Opens a folder in Explorer.
    var openFolder: (String) -> Void = { _ in }
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
        // A log format imported, or its colors changed: open logs color again.
        formatsObserver = NotificationCenter.default.addObserver(forName: .solanumLogFormatsChanged, object: nil, queue: nil) { [weak self] _ in
            self?.post { self?.formatsChanged() }
        }
    }

    deinit {
        for (raw, image) in images { sol_canvas_free_image(raw, image.id) }
        if let formatsObserver { NotificationCenter.default.removeObserver(formatsObserver) }
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
        // Color codes a logger wrote into the file (logback's %highlight…) are hidden and shown as colors; a file with
        // them, or one an imported log format names, is a log whatever it's called.
        hidesEscapes = encoding == .utf8 || encoding == .windowsCP1252 ? data.contains(0x1B) : text.utf16.contains(0x1B)
        let firstRead = content != .text
        if language == nil, hidesEscapes || LogFormatStore.formats.contains(where: { $0.matches(fileName: name) }) { language = .log }
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
        if language == .log && (firstRead || logFormat == nil) { chooseLogFormat() }
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
        guard let language, language.canFormat else { return say("Beautify works on JSON, YAML and XML", problem: true) }
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
        let hidden = escapeMask(line)
        var n = 0
        for (i, ch) in lines[line].enumerated() where i < col && !(hidden?[i] ?? false) { n += ch == "\t" ? 4 : 1 }
        return n
    }

    /// The character at a cell of a line, rounding to the nearer side.
    private func col(_ line: Int, atCell cell: Int) -> Int {
        let hidden = escapeMask(line)
        var n = 0
        for (i, ch) in lines[line].enumerated() where !(hidden?[i] ?? false) {
            let w = ch == "\t" ? 4 : 1
            if cell < n + (w + 1) / 2 { return i }
            n += w
        }
        return lines[line].count
    }

    private func shown(_ line: Int) -> String {
        guard let hidden = escapeMask(line) else { return lines[line].replacingOccurrences(of: "\t", with: "    ") }
        var out = ""
        for (i, ch) in lines[line].enumerated() where !hidden[i] { if ch == "\t" { out += "    " } else { out.append(ch) } }
        return out
    }

    /// Which characters of a line are color codes, hidden; nil for a line with none (or a file that doesn't hide them).
    private func escapeMask(_ line: Int) -> [Bool]? {
        guard hidesEscapes else { return nil }
        if masksBuilt != version { escapeMasks = [:]; masksBuilt = version }
        if let m = escapeMasks[line] { return m.isEmpty ? nil : m }
        let m = Self.escapeMask(lines[line])
        escapeMasks[line] = m ?? []
        return m
    }

    /// ESC [ parameters and a final byte, as ANSIText takes them out.
    static func escapeMask(_ text: String) -> [Bool]? {
        guard text.utf16.contains(0x1B) else { return nil }
        let chars = Array(text)
        func scalar(_ c: Character) -> UInt32 { c.unicodeScalars.count == 1 ? c.unicodeScalars.first!.value : 0 }
        var out = [Bool](repeating: false, count: chars.count)
        var i = 0
        while i < chars.count {
            guard scalar(chars[i]) == 0x1B, i + 1 < chars.count, chars[i + 1] == "[" else { i += 1; continue }
            var j = i + 2
            while j < chars.count, (0x20...0x3F).contains(scalar(chars[j])) { j += 1 }
            if j < chars.count, (0x40...0x7E).contains(scalar(chars[j])) { j += 1 }
            for k in i..<j { out[k] = true }
            i = j
        }
        return out
    }

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

    private func revealCaret() { reveal(caret) }

    private func reveal(_ p: Pos) {
        rebuildRows()
        let r = place(p)
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

    var selectedText: String? { selection.map { hidesEscapes ? ANSIText.removing(text($0.0, $0.1)) : text($0.0, $0.1) } }

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

    /// A character either way; color codes hidden in a log are stepped over as nothing.
    private func stepLeft(_ p: Pos) -> Pos {
        var c = p.col
        if let hidden = escapeMask(p.line) { while c > 0, hidden[c - 1] { c -= 1 } }
        if c > 0 { return Pos(line: p.line, col: c - 1) }
        return p.line > 0 ? Pos(line: p.line - 1, col: lines[p.line - 1].count) : p
    }

    private func stepRight(_ p: Pos) -> Pos {
        var c = p.col
        let n = lines[p.line].count
        if let hidden = escapeMask(p.line) { while c < n, hidden[c] { c += 1 } }
        if c < n { return Pos(line: p.line, col: c + 1) }
        return p.line + 1 < lines.count ? Pos(line: p.line + 1, col: 0) : p
    }

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

    /// Scrolls to a line (counting from 1) and marks it: now, or once the file has been read. With `text` (Search in
    /// Project Folder's query), that's selected on it, as on the Mac.
    func reveal(line: Int, text: String? = nil) {
        pendingLine = line
        pendingText = text
        applyPendingLine()
        invalidate()
    }
    private var pendingText: String?

    private func applyPendingLine() {
        guard let line = pendingLine, case .text = content else { return }
        pendingLine = nil
        markedLine = min(max(line, 1), lines.count)
        let l = markedLine! - 1
        caret = Pos(line: l, col: 0)
        anchor = nil
        if let text = pendingText, !text.isEmpty, let r = lines[l].range(of: text, options: .caseInsensitive) {
            anchor = Pos(line: l, col: lines[l].distance(from: lines[l].startIndex, to: r.lowerBound))
            caret = Pos(line: l, col: lines[l].distance(from: lines[l].startIndex, to: r.upperBound))
        }
        pendingText = nil
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
            if language == .log { out.append(.logColors) }
            out.append(.tail)
            out.append(.wrap)
            if language?.canFormat == true { out.append(.beautify) }
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
        case .logColors: return 0xE790 // a palette, as the Mac's paintpalette
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
        case .logColors: return "Log Coloring: \(logFormat?.name ?? LogFormat.builtIn.name)"
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
        guard let language, language != .log, case .text = content else { return }
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
        // The text changed under the find bar: its matches follow.
        if let f = find, f.searchedVersion != version, case .text = content { runFind(select: false) }
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
        drawFindBar(a, p, s)
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
        let side = (16 * s).rounded()
        if !FileIcons.draw(name: name, directory: false, x: a.x + 11 * s, y: (h.midY - side / 2).rounded(), size: side, on: p.canvas) {
            p.icon(FileKind(name: name).glyph, UIRect(x: a.x + 10 * s, y: h.y, width: 18 * s, height: h.height), pixels: 12, alpha: 0.65)
        }
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
            let look = logLook(l)
            // A log's error and warning tints, across the whole width, under the text and the selection.
            if let wash = look?.wash { p.fill(UIRect(x: b.x, y: y, width: b.width, height: lh), wash, TerminalPalette.isDark ? 0.13 : 0.10) }
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
            // Find's matches: each shaded, the current one in the solid accent with its text in black or white.
            let current = drawMatches(line: l, rowStart: start, rowEnd: wraps ? start + columns : scrollColumn + columns, textCells: text.count,
                                      x: tx, y: y, p)
            if start < end {
                // In runs of one color (and weight) each.
                let colors = look.map { $0.colors.count == text.count ? $0.colors : nil }
                    ?? (l < lineColors.count && lineColors[l].count == text.count ? lineColors[l] : nil)
                let bold = look.flatMap { $0.bold.count == text.count ? $0.bold : nil }
                func color(_ k: Int) -> UInt32 {
                    if let current, current.contains(k) { return Self.onAccent }
                    return colors?[k] ?? p.fg
                }
                var k = start
                while k < end {
                    let c = color(k), heavy = bold?[k] ?? false
                    var j = k + 1
                    while j < end, color(j) == c, (bold?[j] ?? false) == heavy { j += 1 }
                    p.mono(String(text[k..<j]), x: tx + Float(k - start) * cellSize.width, y: y, maxCells: j - k, color: c, bold: heavy)
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
        if findMouse(message, x: x, y: y) { return true }
        let before = hovered
        let onButton = buttonRects(a, s).first { $0.1.contains(x, y) }?.0
        hovered = onButton
        let inText = body(a, s).contains(x, y)
        if case .text = content {
            switch message {
            case Win.WM_LBUTTONDOWN where onButton == nil && inText:
                // The text takes the keyboard back from the find bar, which stays open.
                if findFocused { findFocused = false; invalidate() }
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
        case .logColors: showLogMenu()
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
        if find != nil && findFocused, let used = findKey(key, shift: shift, ctrl: ctrl) { return used }
        switch key {
        case 0x46 where ctrl && !shift: showFind(replace: false)
        case 0x48 where ctrl && !shift: showFind(replace: true)
        case 0x72: if find == nil { showFind(replace: false) } else { stepFind(shift ? -1 : 1) }
        case Win.VK_ESCAPE where find != nil: closeFind()
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
        guard case .text = content else { return }
        if find != nil && findFocused { return findTyped(text) }
        guard !readOnly else { return }
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
    /// The color and weight drawn at a cell of a log's line, and its line's tint, for tests.
    func logLookForTesting(line: Int, cell: Int) -> (color: UInt32, bold: Bool, wash: UInt32?)? {
        guard let look = logLook(line), cell < look.colors.count else { return nil }
        return (look.colors[cell], look.bold[cell], look.wash)
    }
    /// A line as it's drawn, for tests.
    func shownForTesting(_ line: Int) -> String { shown(line) }
    /// The log palette's menu, as it would open, for tests.
    func logMenuForTesting() -> [MenuItem] { logMenuItems() }
    /// "count of total current='text'", or nil with the bar closed, for tests.
    var findStateForTesting: String? {
        guard let f = find else { return nil }
        let current = f.index.flatMap { i -> String? in
            guard f.matches.indices.contains(i) else { return nil }
            let starts = findSource().starts
            return text(pos(at: f.matches[i].location, starts), pos(at: NSMaxRange(f.matches[i]), starts))
        } ?? ""
        return "\(f.index.map { "\($0 + 1)" } ?? "-") of \(f.matches.count) current='\(current)'" + (f.badRegex ? " bad" : "")
    }
    func setReplaceForTesting(_ text: String) {
        guard var f = find else { return }
        f.replace = TextFieldState(text)
        f.showsReplace = true
        find = f
    }
    func replaceForTesting(all: Bool) { if all { replaceAll() } else { replaceCurrent() } }
    func caretForTesting() -> Pos { caret }
}

// MARK: - Logs

extension FileEditorPanel {
    /// The format for this log: the one picked from the header's menu, else one that names the file or fits its first
    /// lines (see `LogFormats.choose`), else the built-in coloring, as on the Mac.
    private func chooseLogFormat() {
        let formats = LogFormatStore.formats
        if let pick = logFormatPick {
            logFormat = pick == LogFormat.builtIn.name ? LogFormatStore.builtIn : formats.first { $0.name == pick }
            if logFormat != nil { return colorAgain() }
            logFormatPick = nil
        }
        let chosen = LogFormats.choose(for: name, sample: Array(lines.prefix(40)), among: formats)
        logFormat = chosen.file == nil ? LogFormatStore.builtIn : chosen
        colorAgain()
    }

    private func colorAgain() {
        guard let format = logFormat else { return }
        if let logCache { logCache.reset(format: format) } else { logCache = LogPaintCache(format: format) }
        logLooks = [:]
        logBuilt = version
        invalidate()
    }

    /// The formats folder changed (an import, colors chosen): the format is chosen again, its colors read afresh.
    private func formatsChanged() {
        guard language == .log, case .text = content else { return }
        chooseLogFormat()
    }

    /// A LogColor in the theme's colors, as the Mac's LogPainter has them.
    static func color(_ c: LogColor) -> UInt32 {
        let fg = TerminalPalette.foreground, bg = TerminalPalette.background
        switch c {
        case .palette(let i): return TerminalPalette.indexed(i)
        case .rgb(let r, let g, let b): return UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b)
        case .dim: return TerminalPalette.mix(fg, bg, 0.5)
        case .faint: return TerminalPalette.mix(fg, bg, 0.35)
        case .accent: return TerminalPalette.accent
        case .foreground: return fg
        }
    }

    /// How a log's line is drawn: worked out as it comes into view (see LogPaintCache), cell by cell as shown.
    private func logLook(_ l: Int) -> LogLook? {
        guard language == .log, let cache = logCache, lines.indices.contains(l) else { return nil }
        if logBuilt != version {
            cache.reset()
            logLooks = [:]
            logBuilt = version
        }
        if let look = logLooks[l] { return look }
        let paint = cache.paint(l, in: lines)
        let units = lines[l].utf16.count, fg = TerminalPalette.foreground
        var colors = [UInt32](repeating: fg, count: units), bold = [Bool](repeating: false, count: units)
        for run in paint.paints where run.range.location >= 0 && run.range.location + run.range.length <= units {
            let c = Self.color(run.color)
            for k in run.range.location..<(run.range.location + run.range.length) {
                colors[k] = c
                if run.bold { bold[k] = true }
            }
        }
        // From UTF-16 units to cells as drawn: a character takes its first unit's look, a tab four cells, a color code none.
        let hidden = escapeMask(l)
        var look = LogLook(colors: [], bold: [], wash: paint.wash.map(Self.color))
        var unit = 0
        for (i, ch) in lines[l].enumerated() {
            defer { unit += ch.utf16.count }
            if hidden?[i] ?? false { continue }
            let k = min(unit, max(units - 1, 0)), c = units > 0 ? colors[k] : fg, b = units > 0 && bold[k]
            for _ in 0..<(ch == "\t" ? 4 : 1) {
                look.colors.append(c)
                look.bold.append(b)
            }
        }
        logLooks[l] = look
        return look
    }

    /// The header's palette: which format colors this log, its colors, markers, and importing another, as on the Mac.
    private func showLogMenu() {
        guard let r = buttonRects(lastArea, lastScale).first(where: { $0.0 == .logColors })?.1 else { return }
        showMenu(logMenuItems(), r)
    }

    private func logMenuItems() -> [MenuItem] {
        let auto = logFormatPick == nil
        var items = [MenuItem(title: "Log Coloring", isEnabled: false),
                     MenuItem(title: auto ? "Automatic (\(logFormat?.name ?? LogFormat.builtIn.name))" : "Automatic", isChecked: auto) { [weak self] in
                         self?.pickLogFormat(nil)
                     }, .separator]
        for format in [LogFormat.builtIn] + LogFormatStore.formats {
            items.append(MenuItem(title: format.name, isChecked: !auto && logFormat?.name == format.name) { [weak self] in self?.pickLogFormat(format.name) })
        }
        items.append(.separator)
        if let format = logFormat {
            let reopen: ([MenuItem]) -> Void = { [weak self] sub in
                guard let self, let r = self.buttonRects(self.lastArea, self.lastScale).first(where: { $0.0 == .logColors })?.1 else { return }
                self.showMenu(sub, r)
            }
            items += LogColorMenu.items(format: format, selection: logSelection(), open: reopen, ask: { [weak self] done in
                self?.askText("Text to pick out, such as [FAIL], timeout or a logger's name", "Add as a Marker", done)
            })
            items.append(.separator)
        }
        items.append(MenuItem(title: "Import Log Format\u{2026}") { [weak self] in self?.importLogFormat() })
        items.append(MenuItem(title: "Show Log Formats Folder") { [weak self] in
            try? FileManager.default.createDirectory(at: LogFormatStore.folder, withIntermediateDirectories: true)
            self?.openFolder(LogFormatStore.folder.path)
        })
        return items
    }

    private func pickLogFormat(_ name: String?) {
        logFormatPick = name
        chooseLogFormat()
    }

    /// A logging config (logback.xml, log4j2.xml, log4j.properties, a Python logging .ini) or a JSON rules file, from
    /// Windows' Open dialog: it colors this log, picked if it wouldn't be chosen anyway.
    private func importLogFormat() {
        guard let path = pickFile("Import a logging config or a rules file") else { return }
        importLogFormat(from: path)
    }

    func importLogFormat(from path: String) {
        do {
            let format = try LogFormatStore.importFile(URL(fileURLWithPath: path))
            if language == .log, logFormat?.name != format.name { pickLogFormat(format.name) }
            say("Coloring with \u{201C}\(format.name)\u{201D}", problem: false)
        } catch {
            say("Couldn't import \(AnyPath.name(path)): \(error.localizedDescription)", problem: true)
        }
    }

    /// The selected text, if it's short and on one line: offered as a marker.
    private func logSelection() -> String? {
        guard let t = selectedText?.trimmingCharacters(in: .whitespaces), !t.isEmpty, t.count <= 200, !t.contains("\n") else { return nil }
        return t
    }
}

// MARK: - Find

extension FileEditorPanel {
    /// Whichever of black and white reads on the solid accent.
    static var onAccent: UInt32 {
        let a = TerminalPalette.accent
        let lum = (0.299 * Float((a >> 16) & 0xFF) + 0.587 * Float((a >> 8) & 0xFF) + 0.114 * Float(a & 0xFF)) / 255
        return lum > 0.55 ? 0x000000 : 0xFFFFFF
    }

    /// The text as searched (its lines joined by "\n", as UTF-16), and where each line starts in it; made once a version.
    private func findSource() -> (buffer: FindBuffer, starts: [Int]) {
        if let t = findText, t.version == version { return (t.buffer, t.starts) }
        var units: [UInt16] = [], starts: [Int] = []
        starts.reserveCapacity(lines.count)
        for (i, l) in lines.enumerated() {
            starts.append(units.count)
            units.append(contentsOf: l.utf16)
            if i < lines.count - 1 { units.append(10) }
        }
        let buffer = FindBuffer(units: units)
        findText = (version, buffer, starts)
        return (buffer, starts)
    }

    private func offset(of p: Pos, _ starts: [Int]) -> Int { starts[p.line] + lines[p.line].prefix(p.col).utf16.count }

    private func pos(at offset: Int, _ starts: [Int]) -> Pos {
        var lo = 0, hi = starts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        var unit = starts[lo], col = 0
        for ch in lines[lo] {
            if unit >= offset { break }
            unit += ch.utf16.count
            col += 1
        }
        return Pos(line: lo, col: col)
    }

    /// Ctrl+F, or Ctrl+H with Replace: the bar, with what's selected to search for, as in VS Code. Again: back to its field.
    func showFind(replace: Bool) {
        guard case .text = content, compareRows == nil else { return }
        let starts = findSource().starts
        var f = find ?? Find()
        f.anchor = offset(of: selection?.0 ?? caret, starts)
        if let t = selectedText, !t.contains("\n"), t.count < 200 { f.field = TextFieldState(t) }
        f.fieldSelected = true
        f.inReplace = false
        if replace && !readOnly {
            // Opened for replacing with something to find already: straight to what to put instead.
            if f.showsReplace || !f.field.text.isEmpty { f.inReplace = find != nil || !f.field.text.isEmpty }
            f.showsReplace = true
            f.replaceSelected = true
        }
        find = f
        findFocused = true
        runFind(select: true)
        invalidate()
    }

    /// Closing selects the current match, as on the Mac.
    func closeFind() {
        // Edited since it last looked: look again first, so what's selected is a match.
        if let f = find, f.searchedVersion != version { runFind(select: false) }
        if let f = find, let i = f.index, f.matches.indices.contains(i), f.searchedVersion == version {
            let starts = findSource().starts
            anchor = pos(at: f.matches[i].location, starts)
            caret = pos(at: NSMaxRange(f.matches[i]), starts)
        }
        find = nil
        findFocused = false
        hoveredFind = nil
        invalidate()
    }

    /// A plain search on an ordinary file happens right here, so there's nothing to wait for. A big file or a regular
    /// expression (which can take any amount of time) goes off the window's thread, and only the latest search counts.
    /// `select`: typing, from where it started; else (an edit in the file) the match the caret's at.
    private func runFind(select: Bool) {
        guard var f = find else { return }
        f.generation += 1
        f.searchedVersion = version
        let generation = f.generation, query = f.field.text, options = Self.findOptions
        find = f
        let finish: ([NSRange], Bool, Bool) -> Void = { [weak self] ranges, capped, bad in
            guard let self, var f = self.find, f.generation == generation else { return }
            f.matches = ranges
            f.capped = capped
            f.badRegex = bad
            let from = select ? f.anchor : self.offset(of: self.caret, self.findSource().starts)
            f.index = EditorFind.index(of: ranges, from: from)
            self.find = f
            if select { self.showCurrentMatch() }
            self.invalidate()
        }
        guard !query.isEmpty else { return finish([], false, false) }
        let buffer = findSource().buffer
        let plain = FindBuffer.canSearch(query, options)
        if plain, buffer.chars.count < Self.instantFindLength {
            let (ranges, capped) = buffer.matches(of: query, options)
            return finish(ranges, capped, false)
        }
        let expression: NSRegularExpression?
        if plain {
            expression = nil
        } else {
            do { expression = try EditorFind.expression(query, options) } catch { return finish([], false, true) }
        }
        // A regular expression over an ordinary file is quick too: only a big one waits for it.
        if let expression, buffer.chars.count < Self.instantRegexLength {
            let (ranges, capped) = EditorFind.matches(of: expression, in: lines.joined(separator: "\n"))
            return finish(ranges, capped, false)
        }
        buffer.prepare(matchCase: options.matchCase)
        let text = expression == nil ? nil : lines.joined(separator: "\n")
        let post = self.post
        DispatchQueue.global(qos: .userInitiated).async {
            let (ranges, capped) = expression.flatMap { e in text.map { EditorFind.matches(of: e, in: $0) } } ?? buffer.matches(of: query, options)
            post { finish(ranges, capped, false) }
        }
    }

    /// "3 of 12"; nil for nothing searched yet.
    private var findCount: (text: String, problem: Bool)? {
        guard let f = find, !f.field.text.isEmpty else { return nil }
        if f.badRegex { return ("Invalid regex", true) }
        guard let i = f.index else { return ("No results", true) }
        return ("\(i + 1) of \(f.matches.count)\(f.capped ? "+" : "")", false)
    }

    func stepFind(_ d: Int) {
        guard var f = find, !f.matches.isEmpty else { return }
        let i = f.index ?? 0
        f.index = (i + d + f.matches.count) % f.matches.count
        f.anchor = f.matches[f.index ?? 0].location
        find = f
        showCurrentMatch()
        invalidate()
    }

    /// In view, and selected if the keyboard's in the text. From the bar its highlight shows it; closing the bar selects it.
    private func showCurrentMatch() {
        guard let f = find, let i = f.index, f.matches.indices.contains(i) else { return }
        let starts = findSource().starts
        let a = pos(at: f.matches[i].location, starts), b = pos(at: NSMaxRange(f.matches[i]), starts)
        if !findFocused {
            anchor = a
            caret = b
        }
        markedLine = nil
        reveal(b)
        reveal(a)
    }

    /// The matches on a row shaded; returns the cells of the current one there, to draw its text in black or white.
    private func drawMatches(line l: Int, rowStart: Int, rowEnd: Int, textCells: Int, x tx: Float, y: Float, _ p: PanelPaint) -> Range<Int>? {
        guard let f = find, !f.matches.isEmpty, f.searchedVersion == version else { return nil }
        let starts = findSource().starts
        let lineStart = starts[l], lineEnd = lineStart + lines[l].utf16.count
        guard var k = EditorFind.index(of: f.matches, from: lineStart), f.matches[k].location >= lineStart else { return nil }
        var current: Range<Int>?
        var drawn = 0
        while k < f.matches.count, f.matches[k].location < lineEnd || (f.matches[k].location == lineEnd && f.matches[k].length > 0 && lineEnd == lineStart), drawn < 500 {
            let r = f.matches[k]
            let a = pos(at: r.location, starts), b = pos(at: NSMaxRange(r), starts)
            let c0 = a.line == l ? cells(l, upTo: a.col) : 0
            let c1 = b.line == l ? cells(l, upTo: b.col) : textCells + 1
            let x0 = max(c0, rowStart), x1 = min(max(c1, c0 + 1), rowEnd)
            let isCurrent = k == f.index
            if x1 > x0 {
                p.fill(UIRect(x: tx + Float(x0 - rowStart) * cellSize.width, y: y, width: Float(x1 - x0) * cellSize.width, height: cellSize.height),
                       TerminalPalette.accent, isCurrent ? 1 : (TerminalPalette.isDark ? 0.28 : 0.24))
            }
            if isCurrent { current = c0..<c1 }
            k += 1
            drawn += 1
            if b.line > l { break }
        }
        return current
    }

    // MARK: Replacing

    private func replaceCurrent() {
        guard let f = find, !readOnly, let i = f.index, f.matches.indices.contains(i), f.searchedVersion == version,
              let e = try? EditorFind.expression(f.field.text, Self.findOptions) else { return }
        let range = f.matches[i], text = lines.joined(separator: "\n")
        guard let m = e.firstMatch(in: text, range: range), m.range == range else { return runFind(select: false) }
        let new = EditorFind.replacement(f.replace.text, for: m, in: text, e, regex: Self.findOptions.regex)
        let starts = findSource().starts
        anchor = pos(at: range.location, starts)
        caret = pos(at: NSMaxRange(range), starts)
        insert(new, kind: .other)
        // On to the next match, past what was just put in.
        find?.anchor = range.location + new.utf16.count
        runFind(select: true)
    }

    private func replaceAll() {
        guard let f = find, !readOnly, !f.matches.isEmpty, let e = try? EditorFind.expression(f.field.text, Self.findOptions) else { return }
        let text = lines.joined(separator: "\n"), all = NSRange(location: 0, length: text.utf16.count)
        let template = Self.findOptions.regex ? f.replace.text : NSRegularExpression.escapedTemplate(for: f.replace.text)
        let count = e.numberOfMatches(in: text, range: all)
        guard count > 0 else { return }
        let replaced = e.stringByReplacingMatches(in: text, range: all, withTemplate: template)
        // As one step that Ctrl+Z undoes.
        edit(.other) { $0 = replaced.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) }
        caret = clamp(caret)
        anchor = nil
        find?.anchor = offset(of: caret, findSource().starts)
        say("Replaced \(count)", problem: false)
        runFind(select: false)
        invalidate()
    }

    // MARK: The bar's keys

    /// Alt+C, Alt+W and Alt+R while the bar's open: case, whole words and regular expressions, as in VS Code.
    func findAltKey(_ key: Int32) -> Bool {
        guard find != nil else { return false }
        switch key {
        case 0x43: Self.findOptions.matchCase.toggle()
        case 0x57: Self.findOptions.wholeWord.toggle()
        case 0x52: Self.findOptions.regex.toggle()
        default: return false
        }
        runFind(select: true)
        return true
    }

    /// The field with the keyboard, changed.
    private func editField(_ change: (inout TextFieldState, inout Bool) -> Void) {
        guard var f = find else { return }
        if f.inReplace { change(&f.replace, &f.replaceSelected) } else { change(&f.field, &f.fieldSelected) }
        let searchChanged = !f.inReplace && f.field.text != find?.field.text
        find = f
        if searchChanged { runFind(select: true) }
        invalidate()
    }

    private func findTyped(_ text: String) {
        editField { field, selected in
            if selected { field = TextFieldState(""); selected = false }
            field.insert(text)
        }
    }

    /// Keys while the bar has the keyboard; nil for those the editor takes as usual (Ctrl+S, Ctrl+Z…).
    private func findKey(_ key: Int32, shift: Bool, ctrl: Bool) -> Bool? {
        guard let f = find else { return nil }
        switch key {
        case Win.VK_ESCAPE: closeFind()
        case Win.VK_RETURN:
            if f.inReplace { if ctrl { replaceAll() } else { replaceCurrent() } } else { stepFind(shift ? -1 : 1) }
        case 0x72: stepFind(shift ? -1 : 1)
        case Win.VK_TAB:
            guard f.showsReplace else { return true }
            find?.inReplace.toggle()
            if find?.inReplace == true { find?.replaceSelected = true } else { find?.fieldSelected = true }
            invalidate()
        case Win.VK_BACK:
            editField { field, selected in
                if selected { field = TextFieldState(""); selected = false } else { field.deleteBackward(word: ctrl) }
            }
        case Win.VK_DELETE:
            editField { field, selected in
                if selected { field = TextFieldState(""); selected = false } else { field.deleteForward() }
            }
        case Win.VK_LEFT, Win.VK_RIGHT, Win.VK_HOME, Win.VK_END:
            editField { field, selected in
                let all = selected
                selected = false
                switch key {
                case Win.VK_HOME: field.move(to: 0)
                case Win.VK_END: field.move(to: field.text.count)
                case Win.VK_LEFT: field.move(to: all ? 0 : field.caret - 1)
                default: field.move(to: all ? field.text.count : field.caret + 1)
                }
            }
        case Win.VK_UP, Win.VK_DOWN, Win.VK_PRIOR, Win.VK_NEXT: break
        case 0x41 where ctrl: editField { _, selected in selected = true }
        case 0x43 where ctrl: copy(f.inReplace ? f.replace.text : f.field.text)
        case 0x58 where ctrl:
            copy(f.inReplace ? f.replace.text : f.field.text)
            editField { field, selected in field = TextFieldState(""); selected = false }
        case 0x56 where ctrl:
            guard let pasted = paste()?.split(whereSeparator: \.isNewline).first.map(String.init) else { return true }
            findTyped(pasted)
        case 0x46 where ctrl && !shift: showFind(replace: false)
        case 0x48 where ctrl && !shift:
            guard !readOnly else { return true }
            find?.showsReplace.toggle()
            find?.inReplace = find?.showsReplace == true
            find?.replaceSelected = true
            invalidate()
        default:
            // The editor's own Ctrl keys (save, undo, wrap…) still work; nothing else reaches the text.
            return ctrl ? nil : true
        }
        return true
    }

    // MARK: The bar, drawn

    private static let findRowHeight: Float = 36

    /// Where the bar and its parts go, at the top right of the text as VS Code puts it; the count needs measuring.
    private func layoutFindBar(_ a: UIRect, _ p: PanelPaint, _ s: Float) {
        findParts = []
        findBox = nil
        guard let f = find, case .text = content, compareRows == nil else { return }
        let b = body(a, s), rowH = (Self.findRowHeight * s).rounded()
        let w = min((420 * s).rounded(), b.width - 24 * s)
        guard w > 160 * s else { return }
        let box = UIRect(x: (b.maxX - w - 12 * s).rounded(), y: (b.y + 6 * s).rounded(), width: w, height: f.showsReplace ? rowH * 2 + 1 : rowH)
        findBox = box
        let side = (22 * s).rounded()
        func centered(_ x: Float, _ width: Float, row: Int = 0) -> UIRect {
            UIRect(x: x, y: (box.y + Float(row) * (rowH + 1) + (rowH - side) / 2).rounded(), width: width, height: side)
        }
        var x = box.x + 6 * s
        if !readOnly {
            findParts.append((.chevron, centered(x, 20 * s)))
            x += 24 * s
        }
        // From the right: close, next, previous, the three toggles, then the count against them; the field has what's left.
        var right = box.maxX - 6 * s
        for part in [FindPart.close, .next, .previous] {
            right -= side
            findParts.append((part, centered(right, side)))
            right -= 2 * s
        }
        right -= 6 * s
        for part in [FindPart.regex, .wholeWord, .matchCase] {
            right -= 24 * s
            findParts.append((part, centered(right, 24 * s)))
            right -= 2 * s
        }
        if let count = findCount { right -= p.width(count.text, pixels: 11) + 10 * s }
        findParts.append((.field, UIRect(x: x, y: box.y + 8 * s, width: max(right - x - 2 * s, 40 * s), height: rowH - 16 * s)))
        if f.showsReplace {
            var r2 = box.maxX - 6 * s
            // Replace and Replace All, as the Mac's arrow.turn.down.left and text.badge.checkmark.
            for part in [FindPart.replaceAll, .replaceOne] {
                r2 -= 24 * s
                findParts.append((part, centered(r2, 24 * s, row: 1)))
                r2 -= 2 * s
            }
            findParts.append((.replaceField, UIRect(x: x, y: box.y + rowH + 1 + 8 * s, width: max(r2 - x - 4 * s, 40 * s), height: rowH - 16 * s)))
        }
    }

    private func findRect(_ part: FindPart) -> UIRect? { findParts.first { $0.0 == part }?.1 }

    private func drawFindBar(_ a: UIRect, _ p: PanelPaint, _ s: Float) {
        layoutFindBar(a, p, s)
        guard let f = find, let box = findBox else { return }
        let fg = p.fg, accent = TerminalPalette.accent
        // As the commit card's: the theme's surface, a shadow, and its accent at the edge.
        p.fill(UIRect(x: box.x, y: box.y + 3 * s, width: box.width, height: box.height), 0x000000, 0.28, radius: 10)
        p.fill(box, TerminalPalette.surface, 1, radius: 10)
        sol_canvas_stroke_rounded(p.canvas.raw, box.x + 0.5, box.y + 0.5, box.width - 1, box.height - 1, 10 * s, accent, TerminalPalette.isDark ? 0.3 : 0.35, 1)
        if f.showsReplace { p.fill(UIRect(x: box.x + 8 * s, y: box.y + (Self.findRowHeight * s).rounded(), width: box.width - 16 * s, height: 1), fg, TerminalPalette.isDark ? 0.16 : 0.2) }
        for (part, r) in findParts {
            let hovered = hoveredFind == part
            switch part {
            case .chevron:
                if hovered { p.fill(r, accent, 0.13, radius: 5) }
                p.icon(f.showsReplace ? 0xE70D : 0xE76C, r, pixels: 9, color: hovered ? accent : nil, alpha: hovered ? 1 : 0.6)
            case .field, .replaceField:
                let replacing = part == .replaceField
                let focused = findFocused && f.inReplace == replacing
                drawField(replacing ? f.replace : f.field, selected: replacing ? f.replaceSelected : f.fieldSelected,
                          placeholder: replacing ? "Replace" : "Find", focused: focused, r, p, s)
            case .matchCase, .wholeWord, .regex:
                let on = part == .matchCase ? Self.findOptions.matchCase : part == .wholeWord ? Self.findOptions.wholeWord : Self.findOptions.regex
                if on || hovered { p.fill(r, accent, on ? 0.24 : 0.13, radius: 5) }
                let title = part == .matchCase ? "Aa" : part == .wholeWord ? "ab" : ".*"
                let tw = p.width(title, pixels: 12, semibold: true)
                let lx = (r.x + (r.width - tw) / 2).rounded()
                p.label(title, UIRect(x: lx, y: r.y, width: tw + 2, height: r.height), pixels: 12, semibold: true,
                        color: on || hovered ? accent : nil, alpha: on || hovered ? 1 : 0.6)
                if part == .wholeWord { p.fill(UIRect(x: lx, y: (r.midY + 6 * s).rounded(), width: tw, height: max((1 * s).rounded(), 1)), on || hovered ? accent : fg, on || hovered ? 1 : 0.6) }
            case .previous, .next, .close:
                if hovered { p.fill(r, accent, 0.13, radius: 5) }
                let glyph: UInt16 = part == .previous ? 0xE70E : part == .next ? 0xE70D : 0xE8BB
                let enabled = part == .close || !f.matches.isEmpty
                p.icon(glyph, r, pixels: part == .close ? 9 : 11, color: hovered && enabled ? accent : nil, alpha: enabled ? (hovered ? 1 : 0.6) : 0.25)
            case .replaceOne, .replaceAll:
                let enabled = !f.matches.isEmpty
                if hovered && enabled { p.fill(r, accent, 0.13, radius: 5) }
                p.icon(part == .replaceOne ? 0xE751 : 0xE9D5, r, pixels: 12, color: hovered && enabled ? accent : nil, alpha: enabled ? (hovered ? 1 : 0.6) : 0.25)
            case .bar: break
            }
        }
        if let count = findCount, let field = findRect(.field) {
            let w = p.width(count.text, pixels: 11)
            p.label(count.text, UIRect(x: field.maxX + 6 * s, y: field.y, width: w + 2, height: field.height), pixels: 11,
                    color: count.problem ? TerminalPalette.ansi[1] : nil, alpha: count.problem ? 1 : 0.55)
        }
    }

    /// A field: its text (scrolled to keep the caret in view), the caret while it has the keyboard, or its placeholder.
    private func drawField(_ field: TextFieldState, selected: Bool, placeholder: String, focused: Bool, _ r: UIRect, _ p: PanelPaint, _ s: Float) {
        // Plain text on the bar, as the Mac's fields are: the caret shows which has the keyboard.
        let inner = UIRect(x: r.x + 2 * s, y: r.y, width: r.width - 4 * s, height: r.height)
        guard !field.text.isEmpty else {
            p.label(placeholder, inner, pixels: 12.5, alpha: 0.4)
            if focused { p.fill(UIRect(x: inner.x, y: r.y + 5 * s, width: max((1.5 * s).rounded(), 1), height: r.height - 10 * s), TerminalPalette.accent, 1) }
            return
        }
        let caretX = p.width(field.beforeCaret, pixels: 12.5), whole = p.width(field.text, pixels: 12.5)
        let shift = max(0, min(caretX - inner.width + 4 * s, whole - inner.width + 4 * s))
        sol_canvas_push_clip(p.canvas.raw, inner.x, inner.y, inner.width, inner.height)
        if selected && focused { p.fill(UIRect(x: inner.x - shift, y: r.y + 4 * s, width: min(whole, inner.width + shift), height: r.height - 8 * s), TerminalPalette.accent, 0.3) }
        p.label(field.text, UIRect(x: inner.x - shift, y: r.y, width: whole + 4, height: r.height), pixels: 12.5)
        if focused && !selected {
            p.fill(UIRect(x: (inner.x - shift + caretX).rounded(), y: r.y + 5 * s, width: max((1.5 * s).rounded(), 1), height: r.height - 10 * s), TerminalPalette.accent, 1)
        }
        sol_canvas_pop_clip(p.canvas.raw)
    }

    // MARK: The bar's mouse

    /// True when the pointer's on the bar (it takes the click).
    private func findMouse(_ message: UINT, x: Float, y: Float) -> Bool {
        guard find != nil, let box = findBox else { return false }
        let part = box.contains(x, y) ? (findParts.first { $0.1.contains(x, y) }?.0 ?? .bar) : nil
        if part != hoveredFind { hoveredFind = part; invalidate() }
        guard let part else { return false }
        if message == Win.WM_LBUTTONDOWN || message == Win.WM_LBUTTONDBLCLK {
            switch part {
            case .field, .replaceField:
                let replacing = part == .replaceField
                findFocused = true
                find?.inReplace = replacing
                if message == Win.WM_LBUTTONDBLCLK {
                    if replacing { find?.replaceSelected = true } else { find?.fieldSelected = true }
                } else if let r = findRect(part), let canvas = barCanvas {
                    // The caret at the character nearest the click.
                    let p = PanelPaint(canvas: canvas, scale: lastScale)
                    var field = replacing ? find!.replace : find!.field
                    let chars = Array(field.text), inner = r.x + 2 * lastScale
                    let whole = p.width(field.text, pixels: 12.5), caretX = p.width(field.beforeCaret, pixels: 12.5)
                    let shift = max(0, min(caretX - (r.width - 4 * lastScale) + 4 * lastScale, whole - (r.width - 4 * lastScale) + 4 * lastScale))
                    var best = chars.count
                    for i in 0...chars.count where p.width(String(chars[..<i]), pixels: 12.5) - shift + inner >= x - 3 * lastScale { best = i; break }
                    field.move(to: best)
                    if replacing { find?.replace = field; find?.replaceSelected = false } else { find?.field = field; find?.fieldSelected = false }
                }
                invalidate()
            default:
                findFocused = true
            }
        }
        if message == Win.WM_LBUTTONUP {
            switch part {
            case .chevron:
                find?.showsReplace.toggle()
                find?.inReplace = find?.showsReplace == true
                find?.replaceSelected = true
            case .matchCase: Self.findOptions.matchCase.toggle(); runFind(select: true)
            case .wholeWord: Self.findOptions.wholeWord.toggle(); runFind(select: true)
            case .regex: Self.findOptions.regex.toggle(); runFind(select: true)
            case .previous: stepFind(-1)
            case .next: stepFind(1)
            case .close: closeFind()
            case .replaceOne: replaceCurrent()
            case .replaceAll: replaceAll()
            default: break
            }
            invalidate()
        }
        return true
    }
}
