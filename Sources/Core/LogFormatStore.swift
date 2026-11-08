import Foundation

// Where log formats are kept, and coloring a log line by line, without drawing: shared by the Mac (LogColors.swift
// paints its text view) and Windows (its file editor draws what this works out). See LogFormat.swift.

extension Notification.Name {
    /// A log format was imported (or the formats folder changed): open logs choose their format again.
    static let solanumLogFormatsChanged = Notification.Name("SolanumLogFormatsChanged")
}

/// Imported log formats: JSON rules files in log-formats in Solanum's settings folder (~/.config/solanum on the Mac,
/// %APPDATA%\Solanum on Windows) (see LogFormat.swift and the README).
enum LogFormatStore {
    static var folder: URL {
        if let dir = ProcessInfo.processInfo.environment["SOLANUM_LOG_FORMATS_DIR"], !dir.isEmpty { return URL(fileURLWithPath: dir) }
        return configFolder.appendingPathComponent("log-formats")
    }

    /// Solanum's settings folder: ~/.config/solanum on the Mac (or `SOLANUM_CONFIG_DIR`, as the Mac's Config has it),
    /// %APPDATA%\Solanum on Windows. Tests point it somewhere of their own.
    static var configFolder: URL = {
        let env = ProcessInfo.processInfo.environment
        if let dir = env["SOLANUM_CONFIG_DIR"], !dir.isEmpty { return URL(fileURLWithPath: dir) }
        #if os(Windows)
        if let appData = env["APPDATA"], !appData.isEmpty { return URL(fileURLWithPath: appData).appendingPathComponent("Solanum") }
        #endif
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/solanum")
    }()

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

}

/// A log's lines colored as they come into view, each knowing the level of the entry it may belong to (a stack
/// trace's lines take their exception's). Lines are painted from the first one asked for back to the entry it's part
/// of, and kept until the text or the format changes.
final class LogPaintCache {
    private var paints: [LogLinePaint?] = []
    /// For each line painted: the level carried into the line after it.
    private var carriedOut: [LogLevel?] = []
    private(set) var format: LogFormat
    /// How far back to look for the entry a line belongs to.
    static let lookBack = 400

    init(format: LogFormat) { self.format = format }

    /// Starts over: the text changed, or a new format colors it.
    func reset(format: LogFormat? = nil) {
        if let format { self.format = format }
        paints = []
        carriedOut = []
    }

    /// How line `i` of `lines` is colored, painting it (and what it needs above it) if it isn't yet.
    func paint(_ i: Int, in lines: [String]) -> LogLinePaint {
        if paints.count != lines.count {
            paints = Array(repeating: nil, count: lines.count)
            carriedOut = Array(repeating: nil, count: lines.count)
        }
        guard lines.indices.contains(i) else { return LogLinePaint() }
        if let p = paints[i] { return p }
        // Back to a line already painted, or to the start of the entry this one may be part of.
        var start = i
        var carried: LogLevel?
        while start > 0 {
            if paints[start - 1] != nil { carried = carriedOut[start - 1]; break }
            if i - start >= Self.lookBack { break }
            start -= 1
        }
        if start < i, paints[start] == nil, start > 0, paints[start - 1] == nil {
            // Looked back as far as it goes: find the entry from here, as the Mac does.
            var back = start, steps = 0
            while back > 0, steps < Self.lookBack {
                let p = format.paint(lines[back - 1], carried: nil)
                if p.isHeader { carried = p.level; break }
                if !p.continues { break }
                back -= 1
                steps += 1
            }
        }
        var out = LogLinePaint()
        for k in start...i {
            let p = format.paint(lines[k], carried: carried)
            paints[k] = p
            carried = p.isHeader ? p.level : p.continues ? carried : nil
            carriedOut[k] = carried
            out = p
        }
        return out
    }
}
