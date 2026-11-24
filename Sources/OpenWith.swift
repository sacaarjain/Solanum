import AppKit

/// "Open With ›" on a file's right-click menu (the sidebar's, an editor tab's, a Git Changes row's, a file link's in
/// the terminal), as Finder has it: the apps this Mac says can open the file, its default first, each with its icon,
/// then Other… to pick any app. Files on this Mac only (one over ssh isn't somewhere another app can open it).
enum OpenWith {
    /// The menu item with the submenu of apps for `paths` (the first one's apps; all of them open in the one chosen).
    /// Nil when there's nothing that could open them.
    static func item(for paths: [String]) -> NSMenuItem? {
        let urls = paths.map { URL(fileURLWithPath: $0) }
        guard let first = urls.first else { return nil }
        let apps = applications(for: first)
        let menu = NSMenu()
        let def = NSWorkspace.shared.urlForApplication(toOpen: first)
        if let d = def, let i = apps.firstIndex(of: d) {
            menu.addItem(appItem(apps[i], urls, title: name(apps[i]) + " (default)"))
            if apps.count > 1 { menu.addItem(.separator()) }
        }
        for a in apps where a != def { menu.addItem(appItem(a, urls, title: name(a))) }
        if !apps.isEmpty { menu.addItem(.separator()) }
        menu.addItem(ActionMenuItem("Other…") { chooseApp(urls) })
        let item = SubmenuMenuItem(title: "Open With", action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    /// The apps that can open `url`, a name once (several copies of one app: the one Launch Services prefers), by name,
    /// leaving Solanum out (it has Open).
    static func applications(for url: URL) -> [URL] {
        var seen = Set<String>()
        let me = Bundle.main.bundleIdentifier
        return NSWorkspace.shared.urlsForApplications(toOpen: url).filter { a in
            let id = Bundle(url: a)?.bundleIdentifier ?? a.path
            return id != me && seen.insert(id).inserted
        }.sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending }
    }

    static func name(_ app: URL) -> String { FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "") }

    private static func appItem(_ app: URL, _ urls: [URL], title: String) -> NSMenuItem {
        let item = ActionMenuItem(title) { open(urls, with: app) }
        let icon = NSWorkspace.shared.icon(forFile: app.path)
        icon.size = NSSize(width: 16, height: 16)
        item.image = icon
        return item
    }

    static func open(_ urls: [URL], with app: URL) {
        // A test run never reaches outside the app (see Headless).
        if Headless.active {
            for u in urls { FileHandle.standardError.write("headless: open \(u.absoluteString) with \(app.path)\n".data(using: .utf8)!) }
            return
        }
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            guard let error else { return }
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Couldn't open with \(name(app))"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    /// Other…: any app, picked from Applications.
    private static func chooseApp(_ urls: [URL]) {
        guard !Headless.active else { return FileHandle.standardError.write("headless: choose an app for \(urls.map(\.path))\n".data(using: .utf8)!) }
        let panel = NSOpenPanel()
        panel.title = "Open With"
        panel.prompt = "Open"
        panel.message = "Choose an app to open \(urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items") with"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK, let app = panel.url else { return }
        open(urls, with: app)
    }
}

/// A menu item whose submenu Solanum's dropdown always opens in place (a row with ›), however short, rather than laying
/// it out flat under a heading.
final class SubmenuMenuItem: NSMenuItem {}
