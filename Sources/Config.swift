import AppKit

extension Notification.Name {
    static let solanumConfigChanged = Notification.Name("SolanumConfigChanged")
}

/// User preferences, persisted as `key = value` lines in ~/.config/solanum/config.
final class Config {
    static let shared = Config()

    var themeName = ThemeLibrary.defaultName
    var fontFamily = "System Mono"
    var fontSize: CGFloat = 13
    var lineHeight: CGFloat = 1.3
    var opacity: CGFloat = 0.95
    var blur = true
    var cursorStyle = "bar"
    var cursorBlink = true
    var ligatures = true
    var optionAsMeta = true
    var boldIsBright = false
    var scrollback = 10_000
    var shell = ""
    var shellIntegration = true
    var quickTerminalHotkey = "ctrl+`"
    var quickTerminalHeight: CGFloat = 0.45
    var quickTerminalAutoHide = true
    var notifyAfterSeconds: Double = 10
    var copyOnSelect = false
    var confirmQuit = true
    /// The theme's planet in the status bar, with the ship orbiting it.
    var planetCompanion = true
    var restoreSession = true
    var restoreScrollback = true
    /// Where files passing between two ssh hosts are staged on this Mac; empty for the default (see `transferStagingDir`).
    var transferFolder = ""
    var windowColumns = 110
    var windowRows = 32
    var padding: CGFloat = 16

    let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/solanum")
    var fileURL: URL { dir.appendingPathComponent("config") }
    var themesDir: URL { dir.appendingPathComponent("themes") }

    private var lastSave = Date.distantPast
    private var watcher: DispatchSourceFileSystemObject?

    var theme: Theme { ThemeLibrary.theme(named: themeName) }

    func load() {
        try? FileManager.default.createDirectory(at: themesDir, withIntermediateDirectories: true)
        ThemeLibrary.loadCustomThemes(from: themesDir)
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
            save()
            return
        }
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            apply(key: key, value: value)
        }
    }

    private func apply(key: String, value: String) {
        func bool() -> Bool { ["true", "yes", "on", "1"].contains(value.lowercased()) }
        func num() -> CGFloat? { Double(value).map { CGFloat($0) } }
        switch key {
        case "theme": themeName = ThemeLibrary.all.contains { $0.name.caseInsensitiveCompare(value) == .orderedSame } ? value : ThemeLibrary.defaultName
        case "font-family": fontFamily = value.isEmpty ? "System Mono" : value
        case "font-size": if let n = num() { fontSize = min(max(n, 8), 40) }
        case "line-height": if let n = num() { lineHeight = min(max(n, 0.9), 2.0) }
        case "background-opacity": if let n = num() { opacity = min(max(n, 0.3), 1) }
        case "background-blur": blur = bool()
        case "cursor-style": cursorStyle = value.lowercased()
        case "cursor-blink": cursorBlink = bool()
        case "font-ligatures": ligatures = bool()
        case "option-as-meta": optionAsMeta = bool()
        case "bold-is-bright": boldIsBright = bool()
        case "scrollback-lines": if let n = Int(value) { scrollback = min(max(n, 100), 200_000) }
        case "shell": shell = value
        case "shell-integration": shellIntegration = bool()
        case "quick-terminal-hotkey": quickTerminalHotkey = value
        case "quick-terminal-height": if let n = num() { quickTerminalHeight = min(max(n, 0.2), 0.95) }
        case "quick-terminal-autohide": quickTerminalAutoHide = bool()
        case "notify-after-seconds": if let n = Double(value) { notifyAfterSeconds = n }
        case "copy-on-select": copyOnSelect = bool()
        case "confirm-quit": confirmQuit = bool()
        case "planet-companion": planetCompanion = bool()
        case "restore-session": restoreSession = bool()
        case "restore-scrollback": restoreScrollback = bool()
        case "transfer-folder": transferFolder = value
        case "window-columns": if let n = Int(value) { windowColumns = min(max(n, 40), 400) }
        case "window-rows": if let n = Int(value) { windowRows = min(max(n, 10), 200) }
        case "padding": if let n = num() { padding = min(max(n, 0), 60) }
        default: break
        }
    }

    func save() {
        let text = """
        # Solanum configuration. Edit here or in Solanum › Settings (⌘,). Changes apply live.
        # Custom themes: drop JSON files into ~/.config/solanum/themes/ (see README).

        theme = \(themeName)
        font-family = \(fontFamily)
        font-size = \(fmt(fontSize))
        line-height = \(fmt(lineHeight))
        font-ligatures = \(ligatures)

        background-opacity = \(fmt(opacity))
        background-blur = \(blur)
        padding = \(fmt(padding))

        # Outer Wilds themes: the planet in the status bar, with your ship in orbit.
        planet-companion = \(planetCompanion)

        # bar | block | underline
        cursor-style = \(cursorStyle)
        cursor-blink = \(cursorBlink)

        option-as-meta = \(optionAsMeta)
        bold-is-bright = \(boldIsBright)
        copy-on-select = \(copyOnSelect)
        scrollback-lines = \(scrollback)

        # Leave empty to use your login shell.
        shell = \(shell)
        shell-integration = \(shellIntegration)

        # Modifiers: ctrl, alt/option, cmd, shift.  e.g. ctrl+`  or  alt+space
        quick-terminal-hotkey = \(quickTerminalHotkey)
        quick-terminal-height = \(fmt(quickTerminalHeight))
        quick-terminal-autohide = \(quickTerminalAutoHide)

        # Notify when a command running in the background takes at least this long (0 = off).
        notify-after-seconds = \(fmt(CGFloat(notifyAfterSeconds)))
        confirm-quit = \(confirmQuit)

        # Reopen windows, tabs, splits, tab names and groups on launch; optionally with recent output.
        restore-session = \(restoreSession)
        restore-scrollback = \(restoreScrollback)

        # Files copied between two ssh hosts land here on this Mac first and are deleted once delivered.
        # Leave empty for ~/Library/Caches/Solanum/Transfers.
        transfer-folder = \(transferFolder)

        window-columns = \(windowColumns)
        window-rows = \(windowRows)

        """
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        lastSave = Date()
        try? text.write(to: fileURL, atomically: true, encoding: .utf8)
        startWatching()
    }

    static let defaultTransferDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Solanum/Transfers")

    var transferStagingDir: URL {
        transferFolder.isEmpty ? Self.defaultTransferDir : URL(fileURLWithPath: (transferFolder as NSString).expandingTildeInPath)
    }

    private func fmt(_ v: CGFloat) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.2f", Double(v))
    }

    /// Saves and broadcasts a change.
    func commit() {
        save()
        FontSet.invalidate()
        NotificationCenter.default.post(name: .solanumConfigChanged, object: nil)
    }

    func startWatching() {
        watcher?.cancel()
        let fd = open(fileURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let renamed = !src.data.intersection([.rename, .delete]).isEmpty
            if Date().timeIntervalSince(self.lastSave) > 0.5 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.reloadFromDisk() }
            }
            if renamed {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.startWatching() }
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        watcher = src
    }

    func reloadFromDisk() {
        load()
        FontSet.invalidate()
        NotificationCenter.default.post(name: .solanumConfigChanged, object: nil)
    }
}

/// Fonts and cell metrics shared by all terminal views.
final class FontSet {
    let regular: CTFont
    let bold: CTFont
    let italic: CTFont
    let boldItalic: CTFont
    let size: CGFloat
    let cellW: CGFloat
    let cellH: CGFloat
    let ascent: CGFloat
    let descent: CGFloat
    let baseline: CGFloat
    let underlineOffset: CGFloat
    let lineWidth: CGFloat
    let ligatures: Bool
    private(set) var attrs: [[NSAttributedString.Key: Any]] = []
    private var glyphCache: [UInt32: Bool] = [:]

    private static var cached: FontSet?
    static var current: FontSet {
        if let c = cached { return c }
        let f = FontSet(config: Config.shared)
        cached = f
        return f
    }
    static func invalidate() { cached = nil }

    init(config: Config) {
        let size = config.fontSize
        self.size = size
        let base: NSFont
        let isSystem = config.fontFamily == "System Mono" || config.fontFamily.isEmpty
        if isSystem {
            base = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        } else {
            base = NSFontManager.shared.font(withFamily: config.fontFamily, traits: [], weight: 5, size: size)
                ?? NSFont(name: config.fontFamily, size: size)
                ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
        let fm = NSFontManager.shared
        let boldFont: NSFont = isSystem ? NSFont.monospacedSystemFont(ofSize: size, weight: .bold) : fm.convert(base, toHaveTrait: .boldFontMask)
        func italicize(_ f: NSFont) -> NSFont {
            let it = fm.convert(f, toHaveTrait: .italicFontMask)
            if it.fontName != f.fontName { return it }
            var t = AffineTransform(scaleByX: size, byY: size)
            t.prepend(AffineTransform(m11: 1, m12: 0, m21: 0.2, m22: 1, tX: 0, tY: 0))
            return NSFont(descriptor: f.fontDescriptor, textTransform: t) ?? f
        }
        regular = base as CTFont
        bold = boldFont as CTFont
        italic = italicize(base) as CTFont
        boldItalic = italicize(boldFont) as CTFont

        var glyph = CGGlyph(0)
        var ch: UniChar = 0x4D // "M"
        CTFontGetGlyphsForCharacters(regular, &ch, &glyph, 1)
        var adv = CGSize.zero
        CTFontGetAdvancesForGlyphs(regular, .horizontal, &glyph, &adv, 1)
        cellW = adv.width > 0 ? adv.width : size * 0.6
        ascent = CTFontGetAscent(regular)
        descent = CTFontGetDescent(regular)
        let natural = ceil(ascent + descent + CTFontGetLeading(regular))
        cellH = max(natural, round(natural * config.lineHeight))
        baseline = round((cellH - (ascent + descent)) / 2 + ascent)
        underlineOffset = max(1.5, -CTFontGetUnderlinePosition(regular))
        lineWidth = max(1, round(size / 13))
        ligatures = config.ligatures

        let fromContext = NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String)
        let lig = NSAttributedString.Key(kCTLigatureAttributeName as String)
        for f in [regular, bold, italic, boldItalic] {
            attrs.append([.font: f, fromContext: true, lig: ligatures ? 1 : 0])
        }
    }

    @inline(__always) func styleIndex(_ flags: CellFlags) -> Int {
        (flags.contains(.bold) ? 1 : 0) + (flags.contains(.italic) ? 2 : 0)
    }

    /// Whether the primary font has its own glyph for a scalar (so it can be batched on the grid).
    func hasGlyph(_ v: UInt32) -> Bool {
        if v < 0x7F { return true }
        if let c = glyphCache[v] { return c }
        var result = false
        if v <= 0xFFFF {
            var u = UniChar(v)
            var g = CGGlyph(0)
            result = CTFontGetGlyphsForCharacters(regular, &u, &g, 1)
        }
        glyphCache[v] = result
        return result
    }
}

/// Saved command snippets, stored at ~/.config/solanum/snippets.json
struct Snippet: Codable {
    var name: String
    var command: String
}

final class SnippetStore {
    static let shared = SnippetStore()
    private(set) var snippets: [Snippet] = []
    var fileURL: URL { Config.shared.dir.appendingPathComponent("snippets.json") }

    func load() {
        if let data = try? Data(contentsOf: fileURL), let s = try? JSONDecoder().decode([Snippet].self, from: data) {
            snippets = s
        } else {
            snippets = [
                Snippet(name: "Git: pretty log graph", command: "git log --oneline --graph --decorate -20"),
                Snippet(name: "Git: branches by recent commit", command: "git branch --sort=-committerdate | head -15"),
                Snippet(name: "Disk usage of current folder", command: "du -sh * | sort -h"),
                Snippet(name: "Listening ports", command: "lsof -iTCP -sTCP:LISTEN -n -P"),
                Snippet(name: "Find large files (>100MB)", command: "find . -type f -size +100M 2>/dev/null"),
                Snippet(name: "Top processes by CPU", command: "ps -Ao pid,pcpu,pmem,comm -r | head -15"),
            ]
            save()
        }
    }

    func add(_ s: Snippet) {
        snippets.append(s)
        save()
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(snippets) {
            try? FileManager.default.createDirectory(at: Config.shared.dir, withIntermediateDirectories: true)
            try? data.write(to: fileURL)
        }
    }
}
