import AppKit

// Extensions, VS Code style: a marketplace page (View › Extensions, ⇧⌘X) lists what can be added to Solanum, and
// installing one turns it on. An extension can bring its own page (a sub-tab above the terminal, like Git Graph)
// and its own MCP server, which installing registers with Claude Code (`claude mcp add --scope user`), so Claude in
// any tab gets its tools. The servers are built into Solanum itself: `Solanum --mcp <name>` (SleeperMCP.swift).
//
// Installed extensions are kept in ~/.config/solanum/extensions.json; an extension's own data under
// ~/.config/solanum/extensions/<id>/.

extension Notification.Name {
    static let solanumExtensionsChanged = Notification.Name("SolanumExtensionsChanged")
    static let solanumRemoteImageLoaded = Notification.Name("SolanumRemoteImageLoaded")
}

/// Something the marketplace offers.
struct SolanumExtension {
    let id: String
    let name: String
    /// What its page's sub-tab says.
    let pageTitle: String
    let publisher: String
    let version: String
    let summary: String
    let categories: [String]
    /// What it does, a line each.
    let features: [String]
    /// The MCP server it gives Claude Code (`Solanum --mcp <name>`), registered under this name.
    let mcpServer: String?
    /// Its tools, for the marketplace to list: (name, what it does).
    let tools: [(String, String)]
    /// Things worth knowing before installing.
    let notes: [String]
    /// Draws its icon in `rect`.
    let drawIcon: (NSRect) -> Void
    /// Its page.
    let makePage: () -> NSView & ExtensionPage
}

/// A page an extension (or the marketplace) shows above a tab's terminal.
protocol ExtensionPage: AnyObject {
    func applyTheme()
    /// What the editor header says under the sub-tab.
    var subtitle: String { get }
    /// Called when `subtitle` changes.
    var onSubtitleChanged: (() -> Void)? { get set }
    /// What takes the keyboard focus.
    var focusView: NSView { get }
}

enum Extensions {
    static let catalog: [SolanumExtension] = [SleeperExtension.info]

    static func find(_ id: String) -> SolanumExtension? { catalog.first { $0.id == id } }

    // MARK: Installed

    private static var file: URL { Config.shared.dir.appendingPathComponent("extensions.json") }
    private static var loaded = false
    private static var _installed: [String] = []

    static var installed: [String] {
        if !loaded {
            loaded = true
            if let data = try? Data(contentsOf: file), let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                _installed = (j["installed"] as? [String] ?? []).filter { find($0) != nil }
            }
        }
        return _installed
    }

    static func isInstalled(_ id: String) -> Bool { installed.contains(id) }

    private static func save() {
        let j: [String: Any] = ["installed": _installed]
        if let data = try? JSONSerialization.data(withJSONObject: j, options: [.prettyPrinted, .sortedKeys]) {
            try? FileManager.default.createDirectory(at: Config.shared.dir, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
        NotificationCenter.default.post(name: .solanumExtensionsChanged, object: nil)
    }

    /// Turns it on and registers its MCP server with Claude Code; `done` gets the registration's outcome.
    static func install(_ id: String, done: ((ClaudeMCP.Outcome) -> Void)? = nil) {
        guard let ext = find(id) else { return }
        if !installed.contains(id) { _installed.append(id); save() }
        guard let server = ext.mcpServer else { done?(.ok); return }
        ClaudeMCP.register(server) { outcome in
            NotificationCenter.default.post(name: .solanumExtensionsChanged, object: nil)
            done?(outcome)
        }
    }

    /// Turns it off, closes its pages and takes its MCP server out of Claude Code.
    static func uninstall(_ id: String, done: ((ClaudeMCP.Outcome) -> Void)? = nil) {
        guard let ext = find(id) else { return }
        _ = installed
        _installed.removeAll { $0 == id }
        save()
        for wc in NSApp.windows.compactMap({ $0.windowController as? TerminalWindowController }) {
            for tab in wc.allTabs {
                for ed in tab.editors where ed.mode == .extensionPage(id) { tab.closeEditor(ed) }
            }
        }
        guard let server = ext.mcpServer else { done?(.ok); return }
        ClaudeMCP.unregister(server) { outcome in
            NotificationCenter.default.post(name: .solanumExtensionsChanged, object: nil)
            done?(outcome)
        }
    }

    // MARK: Opening pages

    /// The marketplace, above the focused tab's terminal.
    static func showMarketplace(in wc: TerminalWindowController?) {
        guard let tab = wc?.activeTab else { return NSSound.beep() }
        tab.openFile(LocalFileSystem.shared, NSHomeDirectory(), mode: .extensions)
    }

    /// An installed extension's page, above `tab`'s terminal (the focused tab's, without one).
    @discardableResult
    static func showPage(_ id: String, in tab: TabSession?, focus: Bool = true) -> FileEditorView? {
        guard isInstalled(id), let tab = tab ?? (NSApp.keyWindow?.windowController as? TerminalWindowController)?.activeTab
                ?? NSApp.windows.compactMap({ $0.windowController as? TerminalWindowController }).first?.activeTab else { return nil }
        tab.openFile(LocalFileSystem.shared, NSHomeDirectory(), mode: .extensionPage(id), focus: focus)
        return tab.editors.first { $0.mode == .extensionPage(id) }
    }

    /// Every open page of an extension, in every window.
    static func openPages(_ id: String) -> [(tab: TabSession, editor: FileEditorView)] {
        var out: [(TabSession, FileEditorView)] = []
        for wc in NSApp.windows.compactMap({ $0.windowController as? TerminalWindowController }) {
            for tab in wc.allTabs {
                for ed in tab.editors where ed.mode == .extensionPage(id) { out.append((tab, ed)) }
            }
        }
        return out
    }

    /// The tab whose terminal runs process `pid` (Claude Code, the parent of an MCP server), if any.
    static func tab(runningPID pid: pid_t) -> TabSession? {
        for wc in NSApp.windows.compactMap({ $0.windowController as? TerminalWindowController }) {
            for tab in wc.allTabs {
                for p in tab.panes {
                    guard let shell = p.pty?.pid else { continue }
                    if p.pty?.foregroundPID == pid || Self.isDescendant(pid, of: shell) { return tab }
                }
            }
        }
        return nil
    }

    /// Whether `pid` is `ancestor` or one of its descendants.
    static func isDescendant(_ pid: pid_t, of ancestor: pid_t) -> Bool {
        var p = pid
        for _ in 0..<12 {
            if p == ancestor { return true }
            if p <= 1 { return false }
            var info = proc_bsdinfo()
            guard proc_pidinfo(p, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { return false }
            p = pid_t(info.pbi_ppid)
        }
        return false
    }

    /// At launch: listen for the MCP servers (other processes) asking for a view or saying Claude left notes.
    static func start() {
        SleeperExtension.start()
    }
}

// MARK: Claude Code's MCP servers

enum ClaudeMCP {
    enum Outcome {
        case ok
        case failed(String)
        /// Headless runs don't touch Claude Code's settings.
        case skipped
    }

    enum Status: Equatable {
        case registered
        /// Under that name, but running something else (another Solanum, or an older build somewhere else).
        case other(String)
        case missing
        case unknown
    }

    /// What Claude Code runs for an extension's server.
    static var executable: String { Bundle.main.executablePath ?? "/Applications/Solanum.app/Contents/MacOS/Solanum" }

    static func command(for server: String) -> String {
        "claude mcp add --scope user \(server) -- \(shellQuote(executable)) --mcp \(server)"
    }

    /// Whether ~/.claude.json lists the server for every project (user scope).
    static func status(_ server: String, done: @escaping (Status) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
            var s = Status.unknown
            if let data = try? Data(contentsOf: url), let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let entry = (j["mcpServers"] as? [String: Any])?[server] as? [String: Any] {
                    let cmd = entry["command"] as? String ?? ""
                    s = cmd == executable ? .registered : .other(cmd)
                } else {
                    s = .missing
                }
            }
            DispatchQueue.main.async { done(s) }
        }
    }

    static func register(_ server: String, done: @escaping (Outcome) -> Void) {
        run("claude mcp remove --scope user \(server) >/dev/null 2>&1; " + command(for: server), done: done)
    }

    static func unregister(_ server: String, done: @escaping (Outcome) -> Void) {
        run("claude mcp remove --scope user \(server)", done: done)
    }

    /// In the login shell, as a Solanum tab would run it (so `claude` is found where you installed it).
    private static func run(_ script: String, done: @escaping (Outcome) -> Void) {
        if Headless.active {
            FileHandle.standardError.write("headless: \(script)\n".data(using: .utf8)!)
            return done(.skipped)
        }
        let shell = ShellIntegration.userShell()
        let flags = (shell as NSString).lastPathComponent == "zsh" ? "-lic" : "-lc"
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: shell)
            p.arguments = [flags, "command -v claude >/dev/null 2>&1 || { echo 'Claude Code (the claude command) isn’t installed.' >&2; exit 127; }; " + script]
            let err = Pipe()
            p.standardOutput = FileHandle.nullDevice
            p.standardError = err
            p.standardInput = FileHandle.nullDevice
            var outcome = Outcome.failed("Couldn't start \(shell).")
            if (try? p.run()) != nil {
                DispatchQueue.global().asyncAfter(deadline: .now() + 30) { if p.isRunning { p.terminate() } }
                let text = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                p.waitUntilExit()
                // Shell startup files can print anything: keep the last line, which is claude's.
                let last = text.split(separator: "\n").last.map(String.init) ?? "claude exited with \(p.terminationStatus)."
                outcome = p.terminationStatus == 0 ? .ok : .failed(last)
            }
            DispatchQueue.main.async { done(outcome) }
        }
    }
}

// MARK: Asking Claude from a page

enum ExtensionChat {
    /// Sends `prompt` to Claude Code in the tab showing `view`: to the Claude already running there, else starting
    /// one in its terminal (or, when that's busy with something else, in a new tab). `submit` presses ↩ after it.
    static func ask(_ prompt: String, from view: NSView, submit: Bool = true) {
        var v: NSView? = view
        var tab: TabSession?
        while let cur = v {
            if let area = cur as? EditorAreaView { tab = area.tab; break }
            v = cur.superview
        }
        guard let tab else { return NSSound.beep() }
        if let pane = tab.panes.first(where: { $0.pty?.foregroundAgent == .claude }) {
            return send(prompt, to: pane, submit: submit)
        }
        tab.showTerminal()
        let pane = tab.focusedPane
        if pane.hasStarted, !pane.exited, !pane.terminal.usingAlt, pane.remote == nil, !pane.hasRunningJob {
            let alias = Config.shared.shellIntegration ? AliasStore.shared.alias(running: "claude") : nil
            pane.send("\u{15}" + (alias ?? "claude") + "\r")
            pane.window?.makeFirstResponder(pane)
            return whenReady(pane, prompt, submit: submit)
        }
        if !pane.hasStarted {
            pane.pendingCommand = "claude"
            tab.focus()
            return whenReady(pane, prompt, submit: submit)
        }
        AgentChats.startChat(.claude, text: prompt, from: pane)
    }

    private static func send(_ text: String, to pane: TerminalView, submit: Bool) {
        guard pane.terminal.bracketedPaste, pane.agent?.status != .waiting else { return pane.chatPasteFailed(text) }
        pane.sendPaste(text)
        pane.window?.makeFirstResponder(pane)
        if submit {
            // After the paste lands, as ↩ typed by hand.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { pane.send("\r") }
        }
    }

    /// Once Claude Code has started in `pane` and is ready for input.
    private static func whenReady(_ pane: TerminalView, _ text: String, submit: Bool) {
        let deadline = Date().addingTimeInterval(45)
        Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak pane] t in
            guard let pane else { return t.invalidate() }
            pane.updateAgent()
            let ready = pane.pty?.foregroundAgent == .claude && pane.pty?.hasForegroundJob == true && AgentChats.readyForPaste(
                bracketed: pane.terminal.bracketedPaste, status: pane.agent?.status, quietFor: Date().timeIntervalSince(pane.lastOutputAt))
            guard ready || pane.exited || Date() > deadline else { return }
            t.invalidate()
            if ready { send(text, to: pane, submit: submit) } else { pane.chatPasteFailed(text) }
        }
    }
}

// MARK: Pictures from the web

/// Player photos, team logos and avatars: fetched once, kept in memory and on disk (~/Library/Caches).
final class RemoteImages {
    static let shared = RemoteImages()
    private let cache = NSCache<NSURL, NSImage>()
    private var loading: Set<URL> = []
    private var failed: [URL: Date] = [:]
    private lazy var dir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let d = base.appendingPathComponent((Bundle.main.bundleIdentifier ?? "local.solanum.terminal") + "/images", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private func file(for url: URL) -> URL {
        let name = url.absoluteString.unicodeScalars.reduce(into: UInt64(1469598103934665603)) { h, c in h = (h ^ UInt64(c.value)) &* 1099511628211 }
        return dir.appendingPathComponent(String(name, radix: 16))
    }

    /// The picture if it's here; otherwise nil, and it's fetched (`.solanumRemoteImageLoaded` says when).
    func image(_ url: URL?) -> NSImage? {
        guard let url else { return nil }
        if let img = cache.object(forKey: url as NSURL) { return img }
        if loading.contains(url) { return nil }
        if let f = failed[url], Date().timeIntervalSince(f) < 600 { return nil }
        loading.insert(url)
        let path = file(for: url)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var data = try? Data(contentsOf: path)
            if data == nil, !Headless.active || ProcessInfo.processInfo.environment["SOLANUM_SNAPSHOT_NET"] != nil {
                data = try? Sleeper.fetch(url)
                if let d = data, NSImage(data: d) != nil { try? d.write(to: path, options: .atomic) }
            }
            let img = data.flatMap(NSImage.init(data:))
            DispatchQueue.main.async {
                guard let self else { return }
                self.loading.remove(url)
                if let img {
                    self.cache.setObject(img, forKey: url as NSURL)
                    NotificationCenter.default.post(name: .solanumRemoteImageLoaded, object: url)
                } else {
                    self.failed[url] = Date()
                }
            }
        }
        return nil
    }
}

// MARK: A page drawn by hand

/// A flipped view drawn in one pass that also lays it out: `render()` draws (or, while `measuring`, only works out
/// how tall it is), and registers clickable spots as it goes. Hover and clicks are handled here.
class PageCanvas: NSView {
    struct Hit {
        let rect: NSRect
        let id: String
        let action: () -> Void
    }

    private(set) var hits: [Hit] = []
    var hover: String? { didSet { if hover != oldValue { needsDisplay = true } } }
    private var pressed: String?
    /// True while only measuring: nothing is drawn.
    private(set) var measuring = false
    private var dirty: NSRect = .infinite
    private var imageObserver: NSObjectProtocol?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        imageObserver = NotificationCenter.default.addObserver(forName: .solanumRemoteImageLoaded, object: nil, queue: .main) { [weak self] _ in
            self?.needsDisplay = true
        }
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit { imageObserver.map(NotificationCenter.default.removeObserver) }

    /// Draws everything (or measures it), top to bottom; the height used.
    func render() -> CGFloat { 0 }

    /// The height `render()` needs at the current width.
    func measure() -> CGFloat {
        measuring = true
        hits = []
        let h = render()
        measuring = false
        return h
    }

    override func draw(_ dirtyRect: NSRect) {
        hits = []
        dirty = dirtyRect
        _ = render()
        dirty = .infinite
    }

    /// Whether `r` needs drawing now (it's being drawn, not measured, and it's in the part being redrawn).
    func visible(_ r: NSRect) -> Bool { !measuring && r.intersects(dirty) }

    func hit(_ rect: NSRect, _ id: String, _ action: @escaping () -> Void) {
        guard !measuring else { return }
        hits.append(Hit(rect: rect, id: id, action: action))
    }

    private func hitAt(_ e: NSEvent) -> Hit? {
        let p = convert(e.locationInWindow, from: nil)
        return hits.last { $0.rect.contains(p) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === self }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with e: NSEvent) {
        let h = hitAt(e)
        hover = h?.id
        (h == nil ? NSCursor.arrow : NSCursor.pointingHand).set()
    }

    override func mouseExited(with e: NSEvent) {
        hover = nil
        NSCursor.arrow.set()
    }

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        pressed = hitAt(e)?.id
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        defer { pressed = nil; needsDisplay = true }
        guard let h = hitAt(e), h.id == pressed else { return }
        h.action()
    }

    func isPressed(_ id: String) -> Bool { pressed == id && hover == id }

    // MARK: Drawing helpers

    var th: Theme { Config.shared.theme }

    static func para(_ align: NSTextAlignment = .left, _ mode: NSLineBreakMode = .byTruncatingTail) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.alignment = align
        p.lineBreakMode = mode
        return p
    }

    /// One line, cut off with … to fit `width`; returns the width it took.
    @discardableResult
    func text(_ s: String, _ font: NSFont, _ color: NSColor, x: CGFloat, y: CGFloat, width: CGFloat, align: NSTextAlignment = .left) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: Self.para(align)]
        let w = min(width, ceil((s as NSString).size(withAttributes: [.font: font]).width))
        let h = ceil(font.ascender - font.descender + font.leading) + 1
        let r = NSRect(x: x, y: y, width: max(0, width), height: h)
        if visible(r) { (s as NSString).draw(with: r, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs) }
        return w
    }

    /// Wrapped to `width`; returns the height it took.
    @discardableResult
    func paragraph(_ s: String, _ font: NSFont, _ color: NSColor, x: CGFloat, y: CGFloat, width: CGFloat, maxLines: Int = 0) -> CGFloat {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byWordWrapping
        p.lineSpacing = 2
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: p]
        var bound = (s as NSString).boundingRect(with: NSSize(width: max(1, width), height: .greatestFiniteMagnitude),
                                                 options: [.usesLineFragmentOrigin], attributes: attrs)
        if maxLines > 0 { bound.size.height = min(bound.height, CGFloat(maxLines) * (font.ascender - font.descender + font.leading + 2)) }
        let r = NSRect(x: x, y: y, width: width, height: ceil(bound.height))
        if visible(r) { (s as NSString).draw(with: r, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs) }
        return ceil(bound.height)
    }

    static func textWidth(_ s: String, _ font: NSFont) -> CGFloat { ceil((s as NSString).size(withAttributes: [.font: font]).width) }

    func fill(_ r: NSRect, _ color: NSColor, radius: CGFloat = 0) {
        guard visible(r) else { return }
        color.setFill()
        (radius > 0 ? NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius) : NSBezierPath(rect: r)).fill()
    }

    func stroke(_ r: NSRect, _ color: NSColor, radius: CGFloat = 0, width: CGFloat = 1) {
        guard visible(r.insetBy(dx: -1, dy: -1)) else { return }
        color.setStroke()
        let path = NSBezierPath(roundedRect: r.insetBy(dx: width / 2, dy: width / 2), xRadius: radius, yRadius: radius)
        path.lineWidth = width
        path.stroke()
    }

    func line(_ y: CGFloat, from x0: CGFloat, to x1: CGFloat, _ color: NSColor? = nil) {
        fill(NSRect(x: x0, y: y, width: x1 - x0, height: 1), color ?? th.border)
    }

    /// A rounded label: returns its width.
    @discardableResult
    func pill(_ s: String, x: CGFloat, y: CGFloat, height: CGFloat = 18, color: NSColor, filled: Bool = false,
              font: NSFont = .systemFont(ofSize: 10, weight: .bold), minWidth: CGFloat = 0, rightAligned: Bool = false) -> CGFloat {
        let w = max(minWidth, Self.textWidth(s, font) + 12)
        let r = NSRect(x: rightAligned ? x - w : x, y: y, width: w, height: height)
        fill(r, filled ? color : color.withAlphaComponent(th.isDark ? 0.20 : 0.14), radius: height / 2)
        let tc: NSColor = filled ? (color.luminance > 0.6 ? .black : .white) : (th.isDark ? color : color.mix(.black, 0.3))
        text(s, font, tc, x: r.minX, y: r.minY + (height - (font.ascender - font.descender)) / 2 - 1, width: w, align: .center)
        return w
    }

    /// A picture clipped to a circle (or rounded square), over a disc in case it's missing or see-through; `initials`
    /// show while it loads.
    func avatar(_ url: URL?, _ r: NSRect, initials: String = "", square: Bool = false, fit: Bool = false, bg: NSColor? = nil) {
        guard visible(r) else { return }
        let path = square ? NSBezierPath(roundedRect: r, xRadius: r.width * 0.22, yRadius: r.width * 0.22) : NSBezierPath(ovalIn: r)
        (bg ?? th.foreground.withAlphaComponent(th.isDark ? 0.10 : 0.08)).setFill()
        path.fill()
        if let img = RemoteImages.shared.image(url) {
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            let s = img.size
            if fit {
                let inset = r.insetBy(dx: r.width * 0.1, dy: r.height * 0.1)
                img.draw(in: inset, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            } else if s.width > 0, s.height > 0 {
                // Fill the circle, keeping the top (faces are near the top of a headshot).
                let scale = max(r.width / s.width, r.height / s.height)
                let w = s.width * scale, h = s.height * scale
                img.draw(in: NSRect(x: r.midX - w / 2, y: r.minY, width: w, height: h), from: .zero, operation: .sourceOver,
                         fraction: 1, respectFlipped: true, hints: nil)
            }
            NSGraphicsContext.restoreGraphicsState()
        } else if !initials.isEmpty {
            let f = NSFont.systemFont(ofSize: max(9, r.height * 0.36), weight: .semibold)
            text(initials, f, th.dimText, x: r.minX, y: r.midY - (f.ascender - f.descender) / 2 - 1, width: r.width, align: .center)
        }
    }

    static func initials(_ name: String) -> String {
        let parts = name.split(separator: " ").prefix(2)
        return parts.compactMap { $0.first.map(String.init) }.joined().uppercased()
    }

    func symbol(_ name: String, _ r: NSRect, _ color: NSColor, size: CGFloat = 12, weight: NSFont.Weight = .medium) {
        guard visible(r) else { return }
        let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: weight).applying(.init(paletteColors: [color]))
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else { return }
        let s = img.size
        img.draw(in: NSRect(x: r.midX - s.width / 2, y: r.midY - s.height / 2, width: s.width, height: s.height), from: .zero,
                 operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    enum ButtonStyle { case primary, secondary, plain, danger }

    /// A button; returns its width. `x` is its right edge when `rightAligned`.
    @discardableResult
    func button(_ title: String, id: String, x: CGFloat, y: CGFloat, height: CGFloat = 28, symbol sym: String? = nil,
                style: ButtonStyle = .secondary, rightAligned: Bool = false, enabled: Bool = true, action: @escaping () -> Void) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let w = title.isEmpty ? height : Self.textWidth(title, font) + (sym == nil ? 24 : 40)
        let r = NSRect(x: rightAligned ? x - w : x, y: y, width: w, height: height)
        let hot = hover == id && enabled, down = isPressed(id)
        let fg: NSColor
        switch style {
        case .primary:
            fill(r, th.accent.withAlphaComponent(enabled ? (down ? 0.75 : hot ? 0.9 : 1) : 0.4), radius: 7)
            fg = th.accent.luminance > 0.55 ? NSColor.black.withAlphaComponent(0.85) : .white
        case .secondary:
            fill(r, th.foreground.withAlphaComponent(down ? 0.16 : hot ? 0.12 : 0.07), radius: 7)
            stroke(r, th.border, radius: 7)
            fg = enabled ? th.foreground : th.dimText
        case .plain:
            if hot { fill(r, th.foreground.withAlphaComponent(down ? 0.12 : 0.07), radius: 7) }
            fg = enabled ? th.accent : th.dimText
        case .danger:
            fill(r, th.red.withAlphaComponent(down ? 0.3 : hot ? 0.22 : 0.14), radius: 7)
            fg = th.isDark ? th.red : th.red.mix(.black, 0.25)
        }
        var tx = r.minX + 12
        if let sym {
            // Alone, it's centered.
            let sr = title.isEmpty ? NSRect(x: r.minX, y: r.minY, width: r.width, height: height) : NSRect(x: tx, y: r.minY, width: 14, height: height)
            symbol(sym, sr, fg, size: 11.5, weight: .semibold)
            tx += 18
        }
        if !title.isEmpty { text(title, font, fg, x: tx, y: r.minY + (height - 15) / 2, width: r.maxX - tx - 8) }
        if enabled { hit(r, id, action) }
        return w
    }

    /// "5m ago", "3h ago", "Tue".
    static func ago(_ d: Date) -> String {
        let s = -d.timeIntervalSinceNow
        if s < 60 { return "just now" }
        if s < 3600 { return "\(Int(s / 60))m ago" }
        if s < 86_400 { return "\(Int(s / 3600))h ago" }
        if s < 7 * 86_400 { return "\(Int(s / 86_400))d ago" }
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f.string(from: d)
    }
}

/// A canvas in a scroll view, sized to what it draws.
final class CanvasScroll: NSScrollView {
    let canvas: PageCanvas

    init(_ canvas: PageCanvas) {
        self.canvas = canvas
        super.init(frame: .zero)
        documentView = canvas
        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Re-measures the canvas (after its content or width changed).
    func refit() {
        let w = contentView.bounds.width
        guard w > 0 else { return }
        canvas.frame.size.width = w
        let h = max(canvas.measure(), contentView.bounds.height)
        canvas.frame = NSRect(x: 0, y: 0, width: w, height: h)
        canvas.needsDisplay = true
    }

    override func layout() {
        super.layout()
        if abs(canvas.frame.width - contentView.bounds.width) > 0.5 || canvas.frame.height < contentView.bounds.height { refit() }
    }

    func scrollToTop() { contentView.scroll(to: .zero); reflectScrolledClipView(contentView) }
}

// MARK: The marketplace

final class ExtensionsPageView: NSView, ExtensionPage {
    private let scroll: CanvasScroll
    private let canvas = MarketplaceCanvas()
    private var observer: NSObjectProtocol?

    var subtitle: String { "Solanum Extensions · add pages to Solanum and tools to Claude Code" }
    var onSubtitleChanged: (() -> Void)?

    override init(frame: NSRect) {
        scroll = CanvasScroll(canvas)
        super.init(frame: frame)
        addSubview(scroll)
        canvas.onChange = { [weak self] in self?.scroll.refit() }
        observer = NotificationCenter.default.addObserver(forName: .solanumExtensionsChanged, object: nil, queue: .main) { [weak self] _ in
            self?.canvas.refreshStatus()
        }
        canvas.refreshStatus()
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit { observer.map(NotificationCenter.default.removeObserver) }

    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        scroll.frame = bounds
        scroll.refit()
    }

    func applyTheme() { scroll.refit() }
    var focusView: NSView { canvas }
}

final class MarketplaceCanvas: PageCanvas {
    var onChange: (() -> Void)?
    private var selected = Extensions.catalog.first?.id ?? ""
    private var mcp: [String: ClaudeMCP.Status] = [:]
    private var busy: Set<String> = []
    private var messages: [String: (String, Bool)] = [:]

    func refreshStatus() {
        for ext in Extensions.catalog {
            guard let server = ext.mcpServer else { continue }
            ClaudeMCP.status(server) { [weak self] s in
                self?.mcp[ext.id] = s
                self?.onChange?()
            }
        }
        onChange?()
    }

    private func install(_ ext: SolanumExtension) {
        busy.insert(ext.id)
        messages[ext.id] = nil
        onChange?()
        Extensions.install(ext.id) { [weak self] outcome in
            guard let self else { return }
            self.busy.remove(ext.id)
            switch outcome {
            case .ok: self.messages[ext.id] = ("Installed. Claude Code has its tools in new Claude sessions (restart a running one, or run /mcp).", true)
            case .skipped: self.messages[ext.id] = ("Installed (headless: Claude Code left alone).", true)
            case .failed(let m): self.messages[ext.id] = ("Installed, but couldn't add its tools to Claude Code: \(m) Run the command below in a terminal.", false)
            }
            self.refreshStatus()
        }
    }

    private func uninstall(_ ext: SolanumExtension) {
        busy.insert(ext.id)
        messages[ext.id] = nil
        onChange?()
        Extensions.uninstall(ext.id) { [weak self] outcome in
            guard let self else { return }
            self.busy.remove(ext.id)
            if case .failed(let m) = outcome { self.messages[ext.id] = ("Uninstalled; Claude Code still lists its tools: \(m)", false) }
            self.refreshStatus()
        }
    }

    private func reRegister(_ ext: SolanumExtension) {
        guard let server = ext.mcpServer else { return }
        busy.insert(ext.id)
        onChange?()
        ClaudeMCP.register(server) { [weak self] outcome in
            self?.busy.remove(ext.id)
            if case .failed(let m) = outcome { self?.messages[ext.id] = ("Couldn't add its tools to Claude Code: \(m)", false) }
            else { self?.messages[ext.id] = ("Added to Claude Code. New Claude sessions have its tools.", true) }
            self?.refreshStatus()
        }
    }

    override func render() -> CGFloat {
        let pad: CGFloat = 24
        let w = bounds.width
        var y: CGFloat = 22
        // Title
        text("Extensions", .systemFont(ofSize: 22, weight: .bold), th.foreground, x: pad, y: y, width: w - pad * 2)
        y += 32
        y += paragraph("Add features to Solanum. An extension can bring its own page (beside your terminal, like Git Graph) and give Claude Code new tools through an MCP server that Solanum runs itself.",
                       .systemFont(ofSize: 12.5), th.dimText, x: pad, y: y, width: min(720, w - pad * 2))
        y += 22

        let wide = w >= 860
        let listW = wide ? 320 : w - pad * 2
        let installed = Extensions.catalog.filter { Extensions.isInstalled($0.id) }
        let available = Extensions.catalog.filter { !Extensions.isInstalled($0.id) }
        var ly = y
        func section(_ title: String, _ list: [SolanumExtension]) {
            text(title.uppercased(), .systemFont(ofSize: 10.5, weight: .bold), th.dimText, x: pad, y: ly, width: listW)
            text("\(list.count)", .monospacedDigitSystemFont(ofSize: 10.5, weight: .medium), th.dimText.withAlphaComponent(0.7),
                 x: pad, y: ly, width: listW, align: .right)
            ly += 20
            if list.isEmpty {
                text(title == "Installed" ? "Nothing installed yet." : "You have everything.", .systemFont(ofSize: 12), th.dimText, x: pad, y: ly, width: listW)
                ly += 28
            }
            for ext in list { ly = card(ext, x: pad, y: ly, width: listW) + 8 }
            ly += 10
        }
        section("Installed", installed)
        section("Marketplace", available)

        var dy = y
        if let ext = Extensions.find(selected) {
            if wide {
                dy = detail(ext, x: pad + listW + 24, y: y, width: w - (pad + listW + 24) - pad)
            } else {
                line(ly, from: pad, to: w - pad)
                dy = detail(ext, x: pad, y: ly + 18, width: w - pad * 2)
            }
        }
        return max(ly, dy) + 30
    }

    /// A row in the list: icon, name, publisher, summary and a button.
    private func card(_ ext: SolanumExtension, x: CGFloat, y: CGFloat, width: CGFloat) -> CGFloat {
        let h: CGFloat = 78
        let r = NSRect(x: x, y: y, width: width, height: h)
        let sel = ext.id == selected
        fill(r, sel ? th.accent.withAlphaComponent(0.12) : hover == "card." + ext.id ? th.foreground.withAlphaComponent(0.05) : th.surface.withAlphaComponent(0.5), radius: 10)
        if sel { stroke(r, th.accent.withAlphaComponent(0.5), radius: 10) }
        hit(r, "card." + ext.id) { [weak self] in self?.selected = ext.id; self?.onChange?() }
        let icon = NSRect(x: x + 12, y: y + 14, width: 46, height: 46)
        if visible(icon) { ext.drawIcon(icon) }
        let tx = icon.maxX + 12, tw = r.maxX - tx - 12
        text(ext.name, .systemFont(ofSize: 13, weight: .semibold), th.foreground, x: tx, y: y + 12, width: tw - 70)
        text("\(ext.publisher) · v\(ext.version)", .systemFont(ofSize: 11), th.dimText, x: tx, y: y + 30, width: tw)
        text(ext.summary, .systemFont(ofSize: 11.5), th.foreground.withAlphaComponent(0.8), x: tx, y: y + 48, width: tw)
        let installed = Extensions.isInstalled(ext.id)
        if busy.contains(ext.id) {
            text("Working…", .systemFont(ofSize: 11, weight: .medium), th.dimText, x: r.maxX - 90, y: y + 12, width: 78, align: .right)
        } else if !installed {
            button("Install", id: "install." + ext.id, x: r.maxX - 10, y: y + 9, height: 22, style: .primary, rightAligned: true) { [weak self] in self?.install(ext) }
        } else {
            pill("Installed", x: r.maxX - 10, y: y + 11, color: th.green, rightAligned: true)
        }
        return y + h
    }

    private func detail(_ ext: SolanumExtension, x: CGFloat, y y0: CGFloat, width: CGFloat) -> CGFloat {
        var y = y0
        let r = NSRect(x: x, y: y, width: width, height: 0)
        let icon = NSRect(x: x, y: y, width: 84, height: 84)
        if visible(icon) { ext.drawIcon(icon) }
        let tx = icon.maxX + 18, tw = r.maxX - tx
        text(ext.name, .systemFont(ofSize: 20, weight: .bold), th.foreground, x: tx, y: y + 2, width: tw)
        var px = tx
        px += pill(ext.publisher, x: px, y: y + 32, color: th.accent) + 6
        px += pill("v" + ext.version, x: px, y: y + 32, color: th.foreground) + 6
        for c in ext.categories { px += pill(c, x: px, y: y + 32, color: th.ansi[4]) + 6 }
        let installed = Extensions.isInstalled(ext.id)
        var bx = tx
        let by = y + 58
        if busy.contains(ext.id) {
            text("Working…", .systemFont(ofSize: 12, weight: .medium), th.dimText, x: bx, y: by + 6, width: 200)
        } else if installed {
            bx += button("Open \(ext.pageTitle)", id: "open." + ext.id, x: bx, y: by, symbol: "rectangle.portrait.and.arrow.right", style: .primary) { [weak self] in
                guard let self else { return }
                var v: NSView? = self
                while let cur = v, !(cur is EditorAreaView) { v = cur.superview }
                Extensions.showPage(ext.id, in: (v as? EditorAreaView)?.tab)
            } + 8
            bx += button("Uninstall", id: "uninstall." + ext.id, x: bx, y: by, style: .danger) { [weak self] in self?.uninstall(ext) } + 8
        } else {
            bx += button("Install", id: "install2." + ext.id, x: bx, y: by, symbol: "arrow.down.circle", style: .primary) { [weak self] in self?.install(ext) } + 8
        }
        y += 100

        if let (msg, good) = messages[ext.id] {
            let mh = paragraphHeight(msg, width: width - 44)
            let box = NSRect(x: x, y: y, width: width, height: mh + 20)
            fill(box, (good ? th.green : th.red).withAlphaComponent(0.12), radius: 8)
            symbol(good ? "checkmark.circle.fill" : "exclamationmark.triangle.fill", NSRect(x: x + 8, y: y + 10, width: 16, height: 16), good ? th.green : th.red)
            paragraph(msg, .systemFont(ofSize: 12), th.foreground, x: x + 30, y: y + 10, width: width - 44)
            y += mh + 32
        }

        y += paragraph(ext.summary, .systemFont(ofSize: 13), th.foreground, x: x, y: y, width: width) + 18

        // Claude Code
        if let server = ext.mcpServer {
            text("CLAUDE CODE", .systemFont(ofSize: 10.5, weight: .bold), th.dimText, x: x, y: y, width: width)
            y += 20
            let box = NSRect(x: x, y: y, width: width, height: 0)
            var by = y + 12
            let status = mcp[ext.id] ?? .unknown
            let (sym, color, line): (String, NSColor, String) = {
                switch status {
                case .registered: return ("checkmark.seal.fill", th.green, "Its MCP server “\(server)” is registered with Claude Code (user scope): every Claude session can use its tools.")
                case .other(let c): return ("exclamationmark.triangle.fill", th.yellow, "Claude Code has a server named “\(server)” that runs something else (\(c)).")
                case .missing: return installed ? ("exclamationmark.triangle.fill", th.yellow, "Not registered with Claude Code yet, so Claude can't use its tools.")
                                                : ("circle.dashed", th.dimText, "Installing registers its MCP server “\(server)” with Claude Code.")
                case .unknown: return ("questionmark.circle", th.dimText, "Couldn't read Claude Code's settings (~/.claude.json). Installing registers it with the claude command.")
                }
            }()
            let lh = paragraphHeight(line, width: width - 60)
            let boxH = 12 + max(18, lh) + 12 + 22 + 12 + (installed && status != .registered ? 34 : 0)
            fill(NSRect(x: box.minX, y: y, width: width, height: boxH), th.surface.withAlphaComponent(0.6), radius: 10)
            symbol(sym, NSRect(x: x + 12, y: by, width: 18, height: 18), color, size: 14)
            paragraph(line, .systemFont(ofSize: 12), th.foreground, x: x + 40, y: by, width: width - 60)
            by += max(18, lh) + 12
            let cmd = ClaudeMCP.command(for: server)
            let cr = NSRect(x: x + 12, y: by, width: width - 24, height: 22)
            fill(cr, th.background.withAlphaComponent(0.7), radius: 5)
            text(cmd, .monospacedSystemFont(ofSize: 10.5, weight: .regular), th.dimText, x: cr.minX + 8, y: cr.minY + 4, width: cr.width - 60)
            button("", id: "copy." + ext.id, x: cr.maxX - 2, y: cr.minY, height: 22, symbol: "doc.on.doc", style: .plain, rightAligned: true) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(cmd, forType: .string)
            }
            by += 34
            if installed && status != .registered && !busy.contains(ext.id) {
                button("Add to Claude Code", id: "register." + ext.id, x: x + 12, y: by - 2, height: 26, symbol: "plus.circle", style: .secondary) { [weak self] in self?.reRegister(ext) }
            }
            y += boxH + 18
        }

        text("FEATURES", .systemFont(ofSize: 10.5, weight: .bold), th.dimText, x: x, y: y, width: width)
        y += 22
        for f in ext.features {
            symbol("checkmark", NSRect(x: x, y: y, width: 14, height: 16), th.accent, size: 10, weight: .bold)
            y += paragraph(f, .systemFont(ofSize: 12.5), th.foreground, x: x + 22, y: y, width: width - 22) + 8
        }

        if !ext.tools.isEmpty {
            y += 12
            text("TOOLS FOR CLAUDE", .systemFont(ofSize: 10.5, weight: .bold), th.dimText, x: x, y: y, width: width)
            y += 22
            for (name, what) in ext.tools {
                text(name, .monospacedSystemFont(ofSize: 11.5, weight: .semibold), th.accent, x: x, y: y, width: 190)
                y += max(18, paragraph(what, .systemFont(ofSize: 12), th.dimText, x: x + 200, y: y, width: width - 200)) + 8
            }
        }
        if !ext.notes.isEmpty {
            y += 12
            text("GOOD TO KNOW", .systemFont(ofSize: 10.5, weight: .bold), th.dimText, x: x, y: y, width: width)
            y += 22
            for n in ext.notes {
                symbol("info.circle", NSRect(x: x, y: y, width: 14, height: 16), th.dimText, size: 11)
                y += paragraph(n, .systemFont(ofSize: 12), th.foreground.withAlphaComponent(0.85), x: x + 22, y: y, width: width - 22) + 8
            }
        }
        return y
    }

    private func paragraphHeight(_ s: String, width: CGFloat) -> CGFloat {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byWordWrapping
        p.lineSpacing = 2
        return ceil((s as NSString).boundingRect(with: NSSize(width: max(1, width), height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin],
                                                 attributes: [.font: NSFont.systemFont(ofSize: 12), .paragraphStyle: p]).height)
    }
}
