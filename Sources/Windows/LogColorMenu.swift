import Foundation

/// The Colors part of a log's palette menu, as the Mac's (LogColors.swift there): a style for each level and field, and
/// for the markers in the log. Saved through Core's LogFormatStore, so the Mac and Windows read the same rules files.
/// Solanum's menus here have no submenus: an item ending in › opens the next menu in the same place.
enum LogColorMenu {
    /// `selection`: text selected in the log, offered as a marker. `open` shows a menu where this one was; `ask` asks for
    /// a marker's text.
    static func items(format: LogFormat, selection: String?, open: @escaping ([MenuItem]) -> Void,
                      ask: @escaping (@escaping (String) -> Void) -> Void) -> [MenuItem] {
        let file = LogFormatStore.colorsFile(for: format)
        let scope = format.file == nil ? "all logs" : "\u{201C}\(format.name)\u{201D}"
        var items = [MenuItem(title: "Colors (saved for \(scope))", isEnabled: false)]

        func keyItems(_ keys: [LogStyleKey]) -> [MenuItem] {
            keys.map { key in
                let (style, chosen) = format.style(key)
                var item = MenuItem(title: key.title + "  \u{203A}") {
                    open([MenuItem(title: key.title, isEnabled: false)]
                         + styleMenu(style, chosen: chosen) { LogFormatStore.setStyle(key, $0, in: file) })
                }
                item.swatch = style.color.map(FileEditorPanel.color)
                return item
            }
        }
        items.append(MenuItem(title: "Levels  \u{203A}") { open(keyItems(LogStyleKey.levels)) })
        items.append(MenuItem(title: "Fields  \u{203A}") { open(keyItems(LogStyleKey.fields)) })

        // Markers: text you pick out, wherever it shows up in a line.
        let markers = format.rules.compactMap(\.text).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        items.append(.separator)
        items.append(MenuItem(title: "Markers", isEnabled: false))
        for text in markers {
            let style = format.markerStyle(text) ?? LogStyle()
            var item = MenuItem(title: text + "  \u{203A}") {
                open([MenuItem(title: text, isEnabled: false)]
                     + styleMenu(style, chosen: true, marker: true) { LogFormatStore.setMarker(text, $0, in: file) })
            }
            item.swatch = style.color.map(FileEditorPanel.color)
            items.append(item)
        }
        let added = LogStyle(color: .accent, bold: true)
        if let selection, !markers.contains(selection) {
            let shown = selection.count > 40 ? selection.prefix(39) + "\u{2026}" : selection
            items.append(MenuItem(title: "Add \u{201C}\(shown)\u{201D} as a Marker") { LogFormatStore.setMarker(selection, added, in: file) })
        }
        items.append(MenuItem(title: "Add Marker\u{2026}") { ask { LogFormatStore.setMarker($0, added, in: file) } })
        items.append(MenuItem(title: "Reset Colors") { LogFormatStore.resetColors(in: file) })
        return items
    }

    static let colors: [(String, LogColor)] = [
        ("Red", .palette(1)), ("Green", .palette(2)), ("Yellow", .palette(3)), ("Blue", .palette(4)), ("Magenta", .palette(5)),
        ("Cyan", .palette(6)), ("Bright Red", .palette(9)), ("Bright Green", .palette(10)), ("Bright Yellow", .palette(11)),
        ("Bright Blue", .palette(12)), ("Bright Magenta", .palette(13)), ("Bright Cyan", .palette(14)),
        ("Text", .foreground), ("Dim", .dim), ("Faint", .faint), ("Accent", .accent),
    ]

    /// Default, the theme's colors, then bold, tint and fade, as the Mac's. `set(nil)` goes back to the default (for a
    /// marker, takes it out).
    static func styleMenu(_ current: LogStyle, chosen: Bool, marker: Bool = false, set: @escaping (LogStyle?) -> Void) -> [MenuItem] {
        var items: [MenuItem] = []
        if !marker { items.append(MenuItem(title: "Default", isChecked: !chosen) { set(nil) }) }
        items.append(.separator)
        for (name, c) in colors {
            var item = MenuItem(title: name, isChecked: current.color == c) {
                var s = current
                s.color = c
                set(s)
            }
            item.swatch = FileEditorPanel.color(c)
            items.append(item)
        }
        if case .rgb = current.color {
            var item = MenuItem(title: "Custom (\(current.color?.name ?? ""))", isChecked: true, isEnabled: false)
            item.swatch = current.color.map(FileEditorPanel.color)
            items.append(item)
        }
        items.append(.separator)
        items.append(MenuItem(title: "Bold", isChecked: current.bold) { var s = current; s.bold.toggle(); set(s) })
        items.append(MenuItem(title: "Tint Whole Line", isChecked: current.tint) {
            var s = current
            s.tint.toggle()
            if s.color == nil { s.color = .accent }
            set(s)
        })
        items.append(MenuItem(title: "Fade Whole Line", isChecked: current.fade) { var s = current; s.fade.toggle(); set(s) })
        if marker {
            items.append(.separator)
            items.append(MenuItem(title: "Remove Marker") { set(nil) })
        }
        return items
    }
}
