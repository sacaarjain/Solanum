import Foundation
import WinSDK

/// "Open With…" on a file's right-click menu, as the Mac's Open With › and Explorer's: the apps Windows recommends for the
/// file's type, its default first, then Choose Another App…, Windows' own dialog for any app. Files on this PC only (one
/// over ssh isn't somewhere another app can open it).
enum OpenWith {
    /// The apps for `path`'s type, by the name Windows shows, the default first (marked) and the rest by name.
    static func apps(for path: String) -> [(name: String, isDefault: Bool)] {
        let names = handlers(for: path) { _, _ in false }
        let def = defaultApp(for: path)
        var seen = Set<String>()
        let unique = names.filter { seen.insert($0).inserted }
        let first = unique.filter { $0 == def }
        let rest = unique.filter { $0 != def }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return first.map { ($0, true) } + rest.map { ($0, false) }
    }

    /// The menu of apps, each opening `path` in it, then Choose Another App….
    static func items(for path: String, hwnd: HWND?) -> [MenuItem] {
        let found = apps(for: path)
        var items = found.map { app in
            MenuItem(title: app.isDefault ? app.name + " (default)" : app.name) { open(path, with: app.name) }
        }
        if !items.isEmpty { items.append(.separator) }
        items.append(MenuItem(title: "Choose Another App…") { chooseApp(path, hwnd: hwnd) })
        return items
    }

    /// Where a pick goes: tests look without opening anything.
    static var onOpen: (String, String) -> Void = { path, app in _ = launch(path, with: app) }
    static var onChoose: (String, HWND?) -> Void = { path, hwnd in
        var info = OPENASINFO()
        let file = wide(path)
        file.withUnsafeBufferPointer { f in
            info.pcszFile = f.baseAddress
            info.oaifInFlags = Int32(OAIF_EXEC.rawValue | OAIF_ALLOW_REGISTRATION.rawValue)
            _ = SHOpenWithDialog(hwnd, &info)
        }
    }

    static func open(_ path: String, with app: String) { onOpen(path, app) }
    static func chooseApp(_ path: String, hwnd: HWND?) { onChoose(path, hwnd) }

    /// Windows' default app for the file's type, by name ("Notepad").
    static func defaultApp(for path: String) -> String? {
        let ext = extensionOf(path)
        guard !ext.isEmpty else { return nil }
        var buffer = [WCHAR](repeating: 0, count: 260)
        var count = DWORD(buffer.count)
        guard AssocQueryStringW(ASSOCF(0), ASSOCSTR_FRIENDLYAPPNAME, wide(ext), nil, &buffer, &count) == S_OK else { return nil }
        let name = String(decodingCString: buffer, as: UTF16.self)
        return name.isEmpty ? nil : name
    }

    /// Opens `path` in the recommended app named `app`. False if it isn't one any more.
    @discardableResult
    static func launch(_ path: String, with app: String) -> Bool {
        var launched = false
        _ = handlers(for: path) { name, handler in
            guard name == app, let data = dataObject(for: path) else { return false }
            launched = handler.pointee.lpVtbl.pointee.Invoke(handler, data) >= 0
            _ = data.pointee.lpVtbl.pointee.Release(data)
            return true
        }
        return launched
    }

    /// The recommended handlers' names, in Windows' order; `visit` may use each one while it's held, and stops the walk
    /// by returning true.
    private static func handlers(for path: String, visit: (String, UnsafeMutablePointer<IAssocHandler>) -> Bool) -> [String] {
        let ext = extensionOf(path)
        guard !ext.isEmpty else { return [] }
        _ = CoInitializeEx(nil, DWORD(COINIT_APARTMENTTHREADED.rawValue))
        var list: UnsafeMutablePointer<IEnumAssocHandlers>?
        guard SHAssocEnumHandlers(wide(ext), ASSOC_FILTER_RECOMMENDED, &list) == S_OK, let list else { return [] }
        defer { _ = list.pointee.lpVtbl.pointee.Release(list) }
        var names: [String] = []
        while true {
            var handler: UnsafeMutablePointer<IAssocHandler>?
            var got: ULONG = 0
            guard list.pointee.lpVtbl.pointee.Next(list, 1, &handler, &got) == S_OK, got == 1, let handler else { break }
            defer { _ = handler.pointee.lpVtbl.pointee.Release(handler) }
            var ui: LPWSTR?
            guard handler.pointee.lpVtbl.pointee.GetUIName(handler, &ui) == S_OK, let ui else { continue }
            let name = String(decodingCString: ui, as: UTF16.self)
            CoTaskMemFree(ui)
            // Solanum has Open already.
            if name == "Solanum" || name.isEmpty { continue }
            names.append(name)
            if visit(name, handler) { break }
        }
        return names
    }

    /// The file as Windows hands it to an app.
    private static func dataObject(for path: String) -> UnsafeMutablePointer<IDataObject>? {
        var raw: UnsafeMutableRawPointer?
        var itemID = IID_IShellItem
        guard SHCreateItemFromParsingName(wide(path), nil, &itemID, &raw) == S_OK, let raw else { return nil }
        let item = raw.assumingMemoryBound(to: IShellItem.self)
        defer { _ = item.pointee.lpVtbl.pointee.Release(item) }
        var handler = BHID_DataObject, dataID = IID_IDataObject
        var data: UnsafeMutableRawPointer?
        guard item.pointee.lpVtbl.pointee.BindToHandler(item, nil, &handler, &dataID, &data) == S_OK, let data else { return nil }
        return data.assumingMemoryBound(to: IDataObject.self)
    }

    /// ".txt", or "" for a file without one.
    private static func extensionOf(_ path: String) -> String {
        let name = path.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? path
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return String(name[dot...])
    }
}
