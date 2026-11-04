import AppKit

extension Notification.Name {
    /// A log format was imported (or the formats folder changed): open logs choose their format again.
    static let solanumLogFormatsChanged = Notification.Name("SolanumLogFormatsChanged")
}

extension NSAttributedString.Key {
    /// A log line's tint (an error's red, a warning's yellow), drawn across the editor's whole width.
    static let solanumLogWash = NSAttributedString.Key("SolanumLogWash")
}

/// Imported log formats: JSON rules files in ~/.config/solanum/log-formats/ (see LogFormat.swift and the README).
enum LogFormatStore {
    static var folder: URL {
        if let dir = ProcessInfo.processInfo.environment["SOLANUM_LOG_FORMATS_DIR"], !dir.isEmpty { return URL(fileURLWithPath: dir) }
        return Config.shared.dir.appendingPathComponent("log-formats")
    }

    /// Colors for every log (chosen while the built-in coloring is on); imported formats start from them.
    static var allLogsFile: URL { folder.appendingPathComponent("_all-logs.json") }

    static var allLogs: LogFormat {
        guard let data = try? Data(contentsOf: allLogsFile), let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let f = try? LogFormat(json: j, file: allLogsFile, colorsOnly: true) else { return LogFormat(name: "All Logs") }
        return f
    }

    /// Read fresh each time (a log being opened): a handful of small files, and edits to them apply straight away.
    /// Each over the all-logs colors.
    static var formats: [LogFormat] {
        let base = allLogs
        return LogFormats.load(from: folder).formats.map { $0.merged(over: base) }
    }

    /// The built-in coloring, with the all-logs colors.
    static var builtIn: LogFormat {
        var f = LogFormat.builtIn.merged(over: allLogs)
        f.file = nil
        return f
    }

    /// Where colors chosen while `format` colors a log are kept: its own file, or (built-in) the all-logs one.
    static func colorsFile(for format: LogFormat) -> URL { format.file ?? allLogsFile }

    /// Changes a rules file's JSON (made if missing), then has open logs color again.
    static func edit(_ file: URL, _ change: (inout [String: Any]) -> Void) {
        var j = (try? Data(contentsOf: file)).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
        if j.isEmpty, file == allLogsFile { j["name"] = "All Logs" }
        change(&j)
        if var colors = j["colors"] as? [String: String] {
            colors = colors.filter { !$0.value.isEmpty }
            j["colors"] = colors.isEmpty ? nil : colors
        }
        if let rules = j["rules"] as? [[String: Any]], rules.isEmpty { j["rules"] = nil }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: j, options: [.prettyPrinted, .sortedKeys]).write(to: file)
        } catch {
            FileHandle.standardError.write("log colors: couldn't save \(file.path): \(error)\n".data(using: .utf8)!)
        }
        NotificationCenter.default.post(name: .solanumLogFormatsChanged, object: nil)
    }

    static func setStyle(_ key: LogStyleKey, _ style: LogStyle?, in file: URL) {
        edit(file) { j in
            var colors = j["colors"] as? [String: String] ?? [:]
            colors[key.rawValue] = style?.text
            j["colors"] = colors
        }
    }

    /// A marker's style; nil takes its rule out.
    static func setMarker(_ text: String, _ style: LogStyle?, in file: URL) {
        edit(file) { j in
            var rules = j["rules"] as? [[String: Any]] ?? []
            let i = rules.firstIndex { $0["text"] as? String == text }
            if let style, !style.isEmpty {
                let rule: [String: Any] = ["text": text, "style": style.text]
                if let i { rules[i] = rule } else { rules.append(rule) }
            } else if let i {
                rules.remove(at: i)
            }
            j["rules"] = rules
        }
    }

    /// Takes the chosen styles and markers out (regular-expression rules written by hand stay).
    static func resetColors(in file: URL) {
        edit(file) { j in
            j["colors"] = nil
            j["rules"] = (j["rules"] as? [[String: Any]] ?? []).filter { $0["text"] == nil }
        }
    }

    static func importFile(_ url: URL) throws -> LogFormat {
        let format = try LogFormats.importFile(url, into: folder)
        NotificationCenter.default.post(name: .solanumLogFormatsChanged, object: nil)
        return format
    }

    /// Asks for a logging config (logback.xml, log4j2.xml, log4j.properties, a Python logging ini) or a rules file
    /// and imports it; problems come up as an alert.
    static func runImportPanel(for window: NSWindow?, done: ((LogFormat) -> Void)? = nil) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        panel.message = "Choose a logging config (logback.xml, log4j2.xml, log4j.properties, a Python logging .ini) or a JSON rules file"
        let finish: (NSApplication.ModalResponse) -> Void = { resp in
            guard resp == .OK, let url = panel.url else { return }
            do {
                done?(try importFile(url))
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn't import “\(url.lastPathComponent)”"
                alert.informativeText = error.localizedDescription
                if let window { alert.beginSheetModal(for: window) } else if !Headless.active { alert.runModal() }
            }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: finish) } else { panel.begin(completionHandler: finish) }
    }
}

enum LogPainter {
    static func color(_ c: LogColor, _ th: Theme) -> NSColor {
        switch c {
        case .palette(let i): return th.paletteColor(i)
        case .rgb(let r, let g, let b): return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
        case .dim: return th.foreground.withAlphaComponent(0.5)
        case .faint: return th.foreground.withAlphaComponent(0.35)
        case .accent: return th.accent
        case .foreground: return th.foreground
        }
    }

    /// Colors the lines `range` touches, and after them the rest of an entry's stack trace (which takes its tint).
    /// Returns the lines it colored.
    @discardableResult
    static func paint(_ text: NSMutableAttributedString, in range: NSRange, format: LogFormat, theme th: Theme = Config.shared.theme) -> NSRange {
        let s = text.mutableString
        let n = s.length
        guard n > 0 else { return NSRange(location: 0, length: 0) }
        func content(_ r: NSRange) -> String {
            var end = NSMaxRange(r)
            while end > r.location, s.character(at: end - 1) == 0x0A || s.character(at: end - 1) == 0x0D { end -= 1 }
            return s.substring(with: NSRange(location: r.location, length: end - r.location))
        }
        let first = s.lineRange(for: NSRange(location: min(range.location, n - 1), length: 0)).location
        // The entry the first line may belong to: back over a stack trace to the line that starts it.
        var carried: LogLevel?
        var back = first, steps = 0
        while back > 0, steps < 400 {
            let prev = s.lineRange(for: NSRange(location: back - 1, length: 0))
            let p = format.paint(content(prev), carried: nil)
            if p.isHeader { carried = p.level; break }
            if !p.continues { break }
            back = prev.location
            steps += 1
        }
        let end = max(min(NSMaxRange(range), n), first + 1)
        let fonts = FontSet.current
        let regular = fonts.regular as NSFont, bold = fonts.bold as NSFont
        let washAlpha: CGFloat = th.isDark ? 0.13 : 0.10
        var at = first, extra = 0
        while at < n {
            let r = s.lineRange(for: NSRange(location: at, length: 0))
            let p = format.paint(content(r), carried: carried)
            if at >= end {
                guard p.continues, extra < 400 else { break }
                extra += 1
            }
            text.removeAttribute(.solanumLogWash, range: r)
            text.addAttributes([.foregroundColor: th.foreground, .font: regular], range: r)
            for paint in p.paints {
                let pr = NSRange(location: r.location + paint.range.location, length: paint.range.length)
                guard NSMaxRange(pr) <= NSMaxRange(r) else { continue }
                text.addAttribute(.foregroundColor, value: color(paint.color, th), range: pr)
                if paint.bold { text.addAttribute(.font, value: bold, range: pr) }
            }
            if let w = p.wash { text.addAttribute(.solanumLogWash, value: color(w, th).withAlphaComponent(washAlpha), range: r) }
            carried = p.isHeader ? p.level : p.continues ? carried : nil
            at = NSMaxRange(r)
        }
        return NSRange(location: first, length: at - first)
    }
}

/// The Colors part of a log's palette menu: a style for each level and field, and for the markers in the log.
enum LogColorMenu {
    /// `selection`: text selected in the log, offered as a marker.
    static func add(to menu: NSMenu, format: LogFormat, selection: String?, window: NSWindow?) {
        let th = Config.shared.theme
        let file = LogFormatStore.colorsFile(for: format)
        let scope = format.file == nil ? "all logs" : "“\(format.name)”"
        let header = NSMenuItem(title: "Colors (saved for \(scope))", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        func keyItem(_ key: LogStyleKey) -> NSMenuItem {
            let (style, chosen) = format.style(key)
            let item = NSMenuItem(title: key.title, action: nil, keyEquivalent: "")
            item.attributedTitle = sample(key.title, style, th)
            item.submenu = styleMenu(style, chosen: chosen, defaultStyle: key.defaultStyle, window: window) { LogFormatStore.setStyle(key, $0, in: file) }
            return item
        }
        let levels = NSMenuItem(title: "Levels", action: nil, keyEquivalent: "")
        levels.submenu = NSMenu()
        LogStyleKey.levels.forEach { levels.submenu!.addItem(keyItem($0)) }
        menu.addItem(levels)
        let fields = NSMenuItem(title: "Fields", action: nil, keyEquivalent: "")
        fields.submenu = NSMenu()
        LogStyleKey.fields.forEach { fields.submenu!.addItem(keyItem($0)) }
        menu.addItem(fields)

        // Markers: text you pick out, wherever it shows up in a line.
        let markers = format.rules.compactMap(\.text).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        menu.addItem(.separator())
        let title = NSMenuItem(title: "Markers", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        for text in markers {
            let style = format.markerStyle(text) ?? LogStyle()
            let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            item.attributedTitle = sample(text, style, th)
            item.submenu = styleMenu(style, chosen: true, defaultStyle: LogStyle(), marker: true, window: window) {
                LogFormatStore.setMarker(text, $0, in: file)
            }
            menu.addItem(item)
        }
        let added = LogStyle(color: .accent, bold: true)
        if let selection, !markers.contains(selection) {
            let shown = selection.count > 40 ? selection.prefix(39) + "…" : selection
            menu.addItem(ActionMenuItem("Add “\(shown)” as a Marker") { LogFormatStore.setMarker(selection, added, in: file) })
        }
        menu.addItem(ActionMenuItem("Add Marker…") { askForMarker(window: window) { LogFormatStore.setMarker($0, added, in: file) } })
        menu.addItem(ActionMenuItem("Reset Colors") { LogFormatStore.resetColors(in: file) })
    }

    /// `text` as it shows in the log, for a menu item's title.
    private static func sample(_ text: String, _ style: LogStyle, _ th: Theme) -> NSAttributedString {
        var attrs: [NSAttributedString.Key: Any] = [.font: style.bold ? NSFont.monospacedSystemFont(ofSize: 12.5, weight: .bold)
                                                                       : NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)]
        if let c = style.color { attrs[.foregroundColor] = LogPainter.color(c, th).withAlphaComponent(1) }
        if style.tint, let c = style.color { attrs[.backgroundColor] = LogPainter.color(c, th).withAlphaComponent(0.25) }
        if style.fade { attrs[.foregroundColor] = NSColor.tertiaryLabelColor }
        return NSAttributedString(string: text, attributes: attrs)
    }

    static let colors: [(String, LogColor)] = [
        ("Red", .palette(1)), ("Green", .palette(2)), ("Yellow", .palette(3)), ("Blue", .palette(4)), ("Magenta", .palette(5)),
        ("Cyan", .palette(6)), ("Bright Red", .palette(9)), ("Bright Green", .palette(10)), ("Bright Yellow", .palette(11)),
        ("Bright Blue", .palette(12)), ("Bright Magenta", .palette(13)), ("Bright Cyan", .palette(14)),
        ("Text", .foreground), ("Dim", .dim), ("Faint", .faint), ("Accent", .accent),
    ]

    private static func swatch(_ c: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { r in
            c.setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)).fill()
            NSColor.labelColor.withAlphaComponent(0.25).setStroke()
            NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)).stroke()
            return true
        }
    }

    /// Default, the theme's colors and a custom one, then bold, tint and fade. `set(nil)` goes back to the default
    /// (for a marker, takes it out).
    static func styleMenu(_ current: LogStyle, chosen: Bool, defaultStyle: LogStyle, marker: Bool = false, window: NSWindow?,
                          set: @escaping (LogStyle?) -> Void) -> NSMenu {
        let th = Config.shared.theme
        let menu = NSMenu()
        if !marker { menu.addItem(ActionMenuItem("Default", checked: !chosen) { set(nil) }) }
        menu.addItem(.separator())
        for (name, c) in colors {
            let item = ActionMenuItem(name, checked: current.color == c) {
                var s = current
                s.color = c
                set(s)
            }
            item.image = swatch(LogPainter.color(c, th))
            menu.addItem(item)
        }
        var custom: NSColor?
        if case .rgb(let r, let g, let b) = current.color {
            custom = NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
        }
        let customItem = ActionMenuItem("Custom Color…", checked: custom != nil) {
            ColorPick.show(custom ?? current.color.map { LogPainter.color($0, th) } ?? th.foreground) { picked in
                var s = current
                let c = picked.usingColorSpace(.sRGB) ?? picked
                s.color = .rgb(UInt8(clamping: Int((c.redComponent * 255).rounded())), UInt8(clamping: Int((c.greenComponent * 255).rounded())),
                               UInt8(clamping: Int((c.blueComponent * 255).rounded())))
                set(s)
            }
        }
        if let custom { customItem.image = swatch(custom) }
        menu.addItem(customItem)
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Bold", checked: current.bold) { var s = current; s.bold.toggle(); set(s) })
        menu.addItem(ActionMenuItem("Tint Whole Line", checked: current.tint) {
            var s = current
            s.tint.toggle()
            if s.color == nil { s.color = .accent }
            set(s)
        })
        menu.addItem(ActionMenuItem("Fade Whole Line", checked: current.fade) { var s = current; s.fade.toggle(); set(s) })
        if marker {
            menu.addItem(.separator())
            menu.addItem(ActionMenuItem("Remove Marker") { set(nil) })
        }
        return menu
    }

    /// Dev aid: what Add Marker… adds, without the alert.
    static var devMarkerText: String?

    private static func askForMarker(window: NSWindow?, _ done: @escaping (String) -> Void) {
        if let text = devMarkerText { return done(text) }
        let alert = NSAlert()
        alert.messageText = "Add a Marker"
        alert.informativeText = "Text to pick out wherever it appears in a line, such as [FAIL], timeout or a logger's name."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "[FAIL]"
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        let finish: (NSApplication.ModalResponse) -> Void = { resp in
            let text = field.stringValue.trimmingCharacters(in: .whitespaces)
            if resp == .alertFirstButtonReturn, !text.isEmpty { done(text) }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: finish) } else if !Headless.active { finish(alert.runModal()) }
    }
}

/// The system color panel, for a custom color: each change lands a moment after it stops moving.
final class ColorPick: NSObject {
    private static var current: ColorPick?
    private let done: (NSColor) -> Void
    private var pending: DispatchWorkItem?

    private init(_ done: @escaping (NSColor) -> Void) { self.done = done }

    static func show(_ color: NSColor, _ done: @escaping (NSColor) -> Void) {
        let pick = ColorPick(done)
        current = pick
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.color = color
        panel.setTarget(pick)
        panel.setAction(#selector(changed(_:)))
        panel.isContinuous = true
        panel.orderFront(nil)
    }

    @objc private func changed(_ panel: NSColorPanel) {
        let color = panel.color
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.done(color) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
}
