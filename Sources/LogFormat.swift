import Foundation

// Log files in the editor: colored the way Notepad++'s log highlighters do it (time, level, thread, logger, the
// message's numbers / strings / paths, exceptions and stack traces, error and warning lines washed red and yellow),
// with any ANSI color codes a logger wrote into the file (logback's %highlight, %cyan…) hidden and shown as the colors
// they ask for. A format imported from a logging config (logback / log4j / log4j2 / Python) or a JSON rules file
// colors that layout's fields exactly. Foundation only: no AppKit, no bridging casts.

/// A color a log painter asks for; the editor turns it into the theme's.
enum LogColor: Equatable {
    /// The xterm palette: the theme's 16 ANSI colors, then the 256-color cube.
    case palette(Int)
    case rgb(UInt8, UInt8, UInt8)
    case dim, faint, accent, foreground

    /// "red", "bright-blue", "dim", "accent", "#RRGGBB"… as a rules file names them.
    init?(name raw: String) {
        let name = raw.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "_", with: "-")
        let names = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white"]
        if let i = names.firstIndex(of: name) { self = .palette(i); return }
        for prefix in ["bright-", "bright"] where name.hasPrefix(prefix) {
            if let i = names.firstIndex(of: String(name.dropFirst(prefix.count))) { self = .palette(i + 8); return }
        }
        switch name {
        case "purple": self = .palette(5)
        case "gray", "grey", "dim": self = .dim
        case "faint": self = .faint
        case "accent": self = .accent
        case "default", "foreground", "text", "normal": self = .foreground
        default:
            var hex = Substring(name)
            if hex.hasPrefix("#") { hex = hex.dropFirst() }
            guard hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
            self = .rgb(UInt8(v >> 16), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF))
        }
    }

    /// As a rules file writes it (the inverse of `init(name:)`).
    var name: String {
        let names = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white"]
        switch self {
        case .palette(let i) where i < 8: return names[i]
        case .palette(let i) where i < 16: return "bright-" + names[i - 8]
        case .palette(let i): return "color-\(i)"
        case .rgb(let r, let g, let b): return String(format: "#%02X%02X%02X", r, g, b)
        case .dim: return "dim"
        case .faint: return "faint"
        case .accent: return "accent"
        case .foreground: return "default"
        }
    }
}

/// How something in a log is shown: a color, bold, and whether it tints or fades the whole line it's on.
/// Written as words, `"red bold tint"`, `"dim fade"`, `"#FFAA00"`.
struct LogStyle: Equatable {
    var color: LogColor?
    var bold = false
    /// Tints the whole line (and, for a level, its stack trace) in `color`.
    var tint = false
    /// Fades the whole line, for noise such as heartbeats.
    var fade = false

    init(color: LogColor? = nil, bold: Bool = false, tint: Bool = false, fade: Bool = false) {
        self.color = color
        self.bold = bold
        self.tint = tint
        self.fade = fade
    }

    init?(text: String) {
        for word in text.split(whereSeparator: { $0 == " " || $0 == "," }) {
            switch word.lowercased() {
            case "bold": bold = true
            case "tint", "line": tint = true
            case "fade", "hide": fade = true
            case "plain", "regular": break
            default:
                let w = String(word)
                if w.lowercased().hasPrefix("color-"), let i = Int(w.dropFirst(6)), (0...255).contains(i) { color = .palette(i); continue }
                guard let c = LogColor(name: w) else { return nil }
                color = c
            }
        }
    }

    var text: String {
        ([color?.name].compactMap { $0 } + (bold ? ["bold"] : []) + (tint ? ["tint"] : []) + (fade ? ["fade"] : [])).joined(separator: " ")
    }

    var isEmpty: Bool { color == nil && !bold && !tint && !fade }
}

/// What can be given a style of its own: a log's fields, its levels, and the parts of a message.
enum LogStyleKey: String, CaseIterable {
    case fatal, error, warn, notice, info, debug, trace
    case time, thread, logger, exception, stack, string, number, path, url, literal

    static let levels: [LogStyleKey] = [.fatal, .error, .warn, .notice, .info, .debug, .trace]
    static let fields: [LogStyleKey] = [.time, .thread, .logger, .exception, .stack, .string, .number, .path, .url, .literal]

    init(_ level: LogLevel) {
        switch level {
        case .fatal: self = .fatal
        case .error: self = .error
        case .warn: self = .warn
        case .notice: self = .notice
        case .info: self = .info
        case .debug: self = .debug
        case .trace: self = .trace
        }
    }

    var title: String {
        switch self {
        case .fatal: return "FATAL"
        case .error: return "ERROR"
        case .warn: return "WARN"
        case .notice: return "NOTICE"
        case .info: return "INFO"
        case .debug: return "DEBUG"
        case .trace: return "TRACE"
        case .time: return "Time"
        case .thread: return "Thread"
        case .logger: return "Logger"
        case .exception: return "Exceptions"
        case .stack: return "Stack Traces"
        case .string: return "Strings"
        case .number: return "Numbers and IDs"
        case .path: return "Paths"
        case .url: return "URLs"
        case .literal: return "true / false / null"
        }
    }

    var defaultStyle: LogStyle {
        switch self {
        case .fatal, .error: return LogStyle(color: .palette(1), bold: true, tint: true)
        case .warn: return LogStyle(color: .palette(3), bold: true, tint: true)
        case .notice: return LogStyle(color: .palette(6))
        case .info: return LogStyle(color: .palette(4))
        case .debug: return LogStyle(color: .dim)
        case .trace: return LogStyle(color: .faint)
        case .time, .thread, .stack: return LogStyle(color: .dim)
        case .logger, .literal: return LogStyle(color: .palette(6))
        case .exception: return LogStyle(color: .palette(1), bold: true)
        case .string: return LogStyle(color: .palette(2))
        case .number: return LogStyle(color: .palette(5))
        case .path, .url: return LogStyle(color: .palette(4))
        }
    }
}

/// A run of a line to color: `range` counts UTF-16 units from the line's start, in the text as it is in the file.
struct LogPaint: Equatable {
    var range: NSRange
    var color: LogColor
    var bold = false
}

enum LogLevel: Int, Comparable {
    case trace, debug, info, notice, warn, error, fatal

    static func < (a: LogLevel, b: LogLevel) -> Bool { a.rawValue < b.rawValue }

    /// ERROR, Warning, E, crit… (any case: a layout's level field, or a word a generic line's level was found by).
    init?(word raw: String) {
        switch raw.trimmingCharacters(in: .whitespaces).uppercased() {
        case "FATAL", "CRITICAL", "CRIT", "EMERG", "EMERGENCY", "ALERT", "SEVERE", "PANIC", "F", "C": self = .fatal
        case "ERROR", "ERR", "E", "FAIL", "FAILURE": self = .error
        case "WARN", "WARNING", "W": self = .warn
        case "NOTICE", "N": self = .notice
        case "INFO", "INFORMATION", "I": self = .info
        case "DEBUG", "DBG", "FINE", "CONFIG", "VERBOSE", "D", "V": self = .debug
        case "TRACE", "FINER", "FINEST", "T": self = .trace
        default: return nil
        }
    }

}

/// How one line is colored.
struct LogLinePaint: Equatable {
    /// In order: later ones win where they overlap.
    var paints: [LogPaint] = []
    /// The line's own level, or (for a stack trace's lines) the level of the line they follow.
    var level: LogLevel?
    /// Starts an entry: a time or a level was found, or a layout matched.
    var isHeader = false
    /// Goes with the entry above (indented, `at …`, `Caused by: …`, a Traceback): it takes that entry's level.
    var continues = false
    /// A tint across the whole line.
    var wash: LogColor?
}

// MARK: - ANSI escapes

enum ANSIText {
    private static let esc: UInt16 = 0x1B, bracket: UInt16 = 0x5B

    private static func isParam(_ c: UInt16) -> Bool { c >= 0x20 && c <= 0x3F }
    private static func isFinal(_ c: UInt16) -> Bool { c >= 0x40 && c <= 0x7E }

    /// Where the escape sequence (`ESC [ … final`) holding the character at `i` starts, if one does. Looks only
    /// nearby, so it can be asked of every character a text view lays out.
    static func escapeStart(_ s: NSString, _ i: Int) -> Int? {
        let n = s.length
        guard i >= 0, i < n else { return nil }
        let c = s.character(at: i)
        if c == esc { return i + 1 < n && s.character(at: i + 1) == bracket ? i : nil }
        if c == bracket, i > 0, s.character(at: i - 1) == esc { return i - 1 }
        guard isParam(c) || isFinal(c) else { return nil }
        var j = isFinal(c) ? i - 1 : i
        while j >= 1, i - j < 48, isParam(s.character(at: j)) { j -= 1 }
        return j >= 1 && s.character(at: j) == bracket && s.character(at: j - 1) == esc ? j - 1 : nil
    }

    /// The whole escape sequence around `i`, if `i` is in one.
    static func escapeRange(_ s: NSString, around i: Int) -> NSRange? {
        guard let start = escapeStart(s, i) else { return nil }
        var j = start + 2
        while j < s.length, isParam(s.character(at: j)) { j += 1 }
        let end = j < s.length && isFinal(s.character(at: j)) ? j + 1 : j
        return i < end ? NSRange(location: start, length: end - start) : nil
    }

    static func contains(_ s: String) -> Bool { s.utf16.contains(esc) }

    /// The text with its escape sequences taken out (copying from a colored log).
    static func removing(_ s: String) -> String {
        guard contains(s) else { return s }
        return strip(s).visible
    }

    struct Stripped {
        /// The line as it reads.
        var visible: String
        /// Its UTF-16 units.
        var units: [UInt16]
        /// For each UTF-16 unit of `visible` (and one past its end), where it is in the line as written; nil when the
        /// line had no escapes, so each is where it was.
        var toRaw: [Int]?
        /// What the line's own color codes ask for, on the line as written.
        var colors: [LogPaint]

        /// `r` (in `visible`) in the line as written.
        func raw(_ r: NSRange) -> NSRange {
            guard r.location != NSNotFound, r.length > 0, r.location + r.length <= units.count else { return NSRange(location: NSNotFound, length: 0) }
            guard let toRaw else { return r }
            let a = toRaw[r.location], b = toRaw[r.location + r.length - 1] + 1
            return NSRange(location: a, length: b - a)
        }
    }

    /// Takes a line's escape sequences out, keeping where each character came from and the colors SGR codes set.
    /// Colors start over on each line, as loggers end their colored runs on the line they start them.
    static func strip(_ line: String) -> Stripped {
        let u = Array(line.utf16)
        // Most lines have none: nothing to take out or map.
        guard u.contains(esc) else { return Stripped(visible: line, units: u, toRaw: nil, colors: []) }
        var out: [UInt16] = [], map: [Int] = [], colors: [LogPaint] = []
        out.reserveCapacity(u.count)
        map.reserveCapacity(u.count + 1)
        var fg: LogColor?, bold = false, runStart = 0
        func close(at end: Int) {
            if (fg != nil || bold), end > runStart {
                colors.append(LogPaint(range: NSRange(location: runStart, length: end - runStart), color: fg ?? .foreground, bold: bold))
            }
        }
        var i = 0
        while i < u.count {
            if u[i] == esc, i + 1 < u.count, u[i + 1] == bracket {
                var j = i + 2
                while j < u.count, isParam(u[j]) { j += 1 }
                if j < u.count, isFinal(u[j]) {
                    if u[j] == 0x6D {
                        close(at: i)
                        // 1;31 → [1, 31], read straight from the characters.
                        var params: [Int] = [], n = 0
                        for k in (i + 2)..<j {
                            let d = u[k]
                            if d >= 0x30 && d <= 0x39 { n = n * 10 + Int(d - 0x30) } else if d == 0x3B || d == 0x3A { params.append(n); n = 0 }
                        }
                        params.append(n)
                        apply(params, &fg, &bold)
                        runStart = j + 1
                    }
                    i = j + 1
                } else {
                    i = j
                }
                continue
            }
            map.append(i)
            out.append(u[i])
            i += 1
        }
        close(at: u.count)
        map.append(u.count)
        // Backed by an NSString on the Mac, so the regular expressions run on it without converting it each time.
        #if canImport(Darwin)
        let visible = NSString(characters: out, length: out.count) as String
        #else
        let visible = String(decoding: out, as: UTF16.self)
        #endif
        return Stripped(visible: visible, units: out, toRaw: map, colors: colors)
    }

    /// One SGR sequence's parameters, applied to the foreground and bold (backgrounds are left out: a log reads
    /// better without blocks of color).
    private static func apply(_ p: [Int], _ fg: inout LogColor?, _ bold: inout Bool) {
        var k = 0
        while k < p.count {
            let v = p[k]
            switch v {
            case 0: fg = nil; bold = false
            case 1: bold = true
            case 22: bold = false
            case 30...37: fg = .palette(v - 30)
            case 90...97: fg = .palette(v - 90 + 8)
            case 39: fg = nil
            case 38:
                if k + 2 < p.count, p[k + 1] == 5 { fg = .palette(max(0, min(255, p[k + 2]))); k += 2 }
                else if k + 4 < p.count, p[k + 1] == 2 {
                    fg = .rgb(UInt8(clamping: p[k + 2]), UInt8(clamping: p[k + 3]), UInt8(clamping: p[k + 4])); k += 4
                }
            case 48:
                if k + 1 < p.count { k += p[k + 1] == 5 ? 2 : p[k + 1] == 2 ? 4 : 0 }
            default: break
            }
            k += 1
        }
    }
}

// MARK: - Layouts

/// A logging library's layout (`%d{HH:mm:ss.SSS} [%thread] %-5level %logger{36} - %msg%n`, or Python's
/// `%(asctime)s %(levelname)s %(name)s: %(message)s`) as a regular expression whose named groups are its fields.
enum LogLayout {
    /// The fields, by the group names a layout or a rules file's `line` uses, and how each is colored.
    enum Field {
        case time, thread, level, logger, message, number, other

        init(group raw: String) {
            switch raw.lowercased() {
            case "time", "date", "timestamp", "datetime", "ts": self = .time
            case "thread", "pid", "tid", "process", "host", "hostname", "context": self = .thread
            case "level", "severity", "lvl", "loglevel": self = .level
            case "logger", "class", "source", "module", "category", "component", "name", "method", "function", "file", "caller":
                self = .logger
            case "message", "msg", "text": self = .message
            case "line", "lineno", "number", "code", "status", "relative", "elapsed": self = .number
            default: self = .other
            }
        }
    }

    /// The named groups in a regular expression, in order.
    static func groupNames(_ pattern: String) -> [String] {
        let re = try! NSRegularExpression(pattern: #"(?<!\\)\(\?<([A-Za-z][A-Za-z0-9]*)>"#)
        let ns = NSString(string: pattern)
        return re.matches(in: pattern, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
    }

    /// A layout as a regular expression (anchored at the line's start), or nil when it has no fields to find.
    static func regex(fromPattern pattern: String) -> String? {
        var used = Set<String>()
        var fields = 0
        let body = pattern.contains("%(") ? python(pattern, &used, &fields) : java(Array(pattern), &used, &fields)
        guard fields > 0 else { return nil }
        return "^" + body
    }

    private static func literal(_ c: Character) -> String {
        if c == " " || c == "\t" { return #"\s+"# }
        return "\\.^$|?*+()[]{}".contains(c) ? "\\" + String(c) : String(c)
    }

    /// Appends a literal, folding a run of spaces into one `\s+`.
    private static func add(_ c: Character, to out: inout String) {
        let piece = literal(c)
        if piece == #"\s+"# {
            if out.hasSuffix(#"\s+"#) { return }
            // A padded field's trailing \s* before a space: at least the one space.
            if out.hasSuffix(#"\s*"#) { out.removeLast(); out += "+"; return }
        }
        out += piece
    }

    private static func group(_ name: String, _ body: String, _ used: inout Set<String>, padded: Bool) -> String {
        let named = used.insert(name).inserted ? "(?<\(name)>\(body))" : "(?:\(body))"
        return padded ? #"\s*"# + named + #"\s*"# : named
    }

    /// logback, log4j and log4j2 conversion patterns.
    private static func java(_ c: [Character], _ used: inout Set<String>, _ fields: inout Int) -> String {
        var out = "", i = 0
        while i < c.count {
            let ch = c[i]
            if ch == "\\", i + 1 < c.count {
                // \n \t written into the pattern; a backslash before anything else stands for it.
                let next = c[i + 1]
                if next == "n" || next == "r" { i += 2; continue }
                add(next == "t" ? "\t" : next, to: &out)
                i += 2
                continue
            }
            guard ch == "%" else { add(ch, to: &out); i += 1; continue }
            i += 1
            guard i < c.count else { break }
            if c[i] == "%" { out += "%"; i += 1; continue }
            // Format modifier: -5, .30, 20.-30, …
            var modifier = ""
            while i < c.count, "-.0123456789".contains(c[i]) { modifier.append(c[i]); i += 1 }
            var word = ""
            while i < c.count, c[i].isLetter { word.append(c[i]); i += 1 }
            // A composite keyword: %highlight(…), %cyan(…), %replace(…){…}.
            var inner: [Character]?
            if i < c.count, c[i] == "(" {
                var depth = 0, j = i
                repeat {
                    if c[j] == "\\" { j += 2; continue }
                    if c[j] == "(" { depth += 1 } else if c[j] == ")" { depth -= 1 }
                    j += 1
                } while j < c.count && depth > 0
                inner = Array(c[(i + 1)..<max(i + 1, j - 1)])
                i = j
            }
            var options: [String] = []
            while i < c.count, c[i] == "{" {
                var j = i + 1, opt = ""
                while j < c.count, c[j] != "}" { opt.append(c[j]); j += 1 }
                options.append(opt)
                i = min(j + 1, c.count)
            }
            if let inner {
                let w = word.lowercased()
                if w == "replace" || w == "maxlen" || w == "truncate" || w == "encode" || w == "notempty" || w == "equals" {
                    out += ".*?"
                } else {
                    // Colors and styles (highlight, cyan, boldRed, style, …) only wrap what's inside.
                    out += java(inner, &used, &fields)
                }
                continue
            }
            let padded = !modifier.isEmpty
            switch word {
            case "d", "date":
                fields += 1
                out += group("time", dateRegex(options.first ?? ""), &used, padded: padded)
            case "t", "thread", "tn", "threadName":
                fields += 1
                out += group("thread", ".*?", &used, padded: padded)
            case "p", "le", "level":
                fields += 1
                out += group("level", "[A-Za-z]+", &used, padded: padded)
            case "c", "lo", "logger":
                fields += 1
                out += group("logger", #"[^\s]+"#, &used, padded: padded)
            case "C", "class":
                fields += 1
                out += group("source", #"[^\s]+"#, &used, padded: padded)
            case "M", "method":
                out += group("method", #"[^\s]+"#, &used, padded: padded)
            case "F", "file":
                out += group("file", #"[^\s]+"#, &used, padded: padded)
            case "L", "line":
                out += group("line", #"\d+|\?"#, &used, padded: padded)
            case "r", "relative":
                out += group("relative", #"\d+"#, &used, padded: padded)
            case "pid", "processId", "tid", "T", "threadId":
                out += group("pid", #"\d+"#, &used, padded: padded)
            case "m", "msg", "message":
                fields += 1
                out += group("message", ".*", &used, padded: false)
            case "n":
                break
            case "ex", "exception", "throwable", "xEx", "xException", "xThrowable", "rEx", "rException", "rThrowable",
                 "wEx", "wex", "nopex", "nopexception":
                out += #"\s*"#
            default:
                out += padded ? #"\s*.*?\s*"# : ".*?"
            }
        }
        return out
    }

    /// Python's logging.Formatter `%(name)s` style.
    private static func python(_ pattern: String, _ used: inout Set<String>, _ fields: inout Int) -> String {
        let c = Array(pattern)
        var out = "", i = 0
        while i < c.count {
            guard c[i] == "%", i + 1 < c.count, c[i + 1] == "(" else {
                if c[i] == "%", i + 1 < c.count, c[i + 1] == "%" { out += "%"; i += 2; continue }
                add(c[i], to: &out); i += 1; continue
            }
            var j = i + 2, name = ""
            while j < c.count, c[j] != ")" { name.append(c[j]); j += 1 }
            j += 1
            var modifier = ""
            while j < c.count, "-.0123456789#+ ".contains(c[j]) { modifier.append(c[j]); j += 1 }
            if j < c.count { j += 1 }   // the conversion type: s, d, f
            i = j
            let padded = !modifier.isEmpty
            switch name {
            case "asctime":
                fields += 1
                out += group("time", dateRegex(""), &used, padded: padded)
            case "levelname":
                fields += 1
                out += group("level", "[A-Za-z]+", &used, padded: padded)
            case "levelno", "lineno", "process", "thread", "msecs", "relativeCreated", "created":
                out += group(name == "lineno" ? "line" : name == "process" || name == "thread" ? "pid" : "relative",
                             #"[\d.]+"#, &used, padded: padded)
            case "name", "module", "filename", "funcName", "pathname":
                fields += 1
                out += group(name == "name" ? "logger" : "source", #"[^\s]+"#, &used, padded: padded)
            case "threadName", "processName", "taskName":
                fields += 1
                out += group("thread", ".*?", &used, padded: padded)
            case "message":
                fields += 1
                out += group("message", ".*", &used, padded: false)
            default:
                out += ".*?"
            }
        }
        return out
    }

    /// A Java date pattern (SimpleDateFormat letters) as a regular expression; an empty or named one is ISO 8601 style.
    static func dateRegex(_ format: String) -> String {
        let f = format.split(separator: ",").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        switch f.uppercased() {
        case "", "ISO8601", "DEFAULT", "ISO8601_BASIC", "DEFAULT_NANOS", "ISO8601_OFFSET_DATE_TIME_HHMM", "ISO8601_OFFSET_DATE_TIME_HHCMM":
            return #"\d{4}-?\d{2}-?\d{2}[T ]\d{2}:?\d{2}:?\d{2}(?:[.,]\d+)?(?:Z|[+-]\d{2}:?\d{2})?"#
        case "ABSOLUTE": return #"\d{2}:\d{2}:\d{2}[.,]\d+"#
        case "DATE": return #"\d{2} [A-Za-z]{3} \d{4} \d{2}:\d{2}:\d{2}[.,]\d+"#
        case "COMPACT": return #"\d{17}"#
        case "UNIX", "UNIX_MILLIS": return #"\d+"#
        default: break
        }
        let c = Array(f)
        var out = "", i = 0
        while i < c.count {
            let ch = c[i]
            if ch == "'" {
                var j = i + 1
                while j < c.count, c[j] != "'" { out += literal(c[j]); j += 1 }
                if j == i + 1 { out += "'" }
                i = j + 1
                continue
            }
            var n = 1
            while i + n < c.count, c[i + n] == ch { n += 1 }
            i += n
            switch ch {
            case "y", "u", "Y": out += n == 2 ? #"\d{2}"# : #"\d{4}"#
            case "M", "L": out += n >= 4 ? "[A-Za-z]+" : n == 3 ? "[A-Za-z]{3}" : #"\d{1,2}"#
            case "d", "H", "h", "k", "K", "m", "s": out += n >= 2 ? #"\d{\#(n)}"# : #"\d{1,2}"#
            case "S", "n": out += #"\d{\#(n)}"#
            case "D": out += #"\d{1,3}"#
            case "E": out += "[A-Za-z]+"
            case "a": out += "[AaPp][Mm]"
            case "z", "Z", "X", "x", "O":
                out += #"(?:Z|[A-Z]{2,5}|[+-]\d{2}:?\d{2})"#
            default:
                for _ in 0..<n { out += literal(ch) }
            }
        }
        return out
    }
}

// MARK: - Formats

/// How to color one kind of log: its layouts (each line that starts an entry), file names it's for, and rules.
struct LogFormat {
    /// Something to find in a line and how to show it: a marker (`text`, found as written, a word on its own) or a
    /// regular expression (`match`, its first group if it has one).
    struct Rule {
        let regex: NSRegularExpression
        let style: LogStyle
        /// The marker's text, for a rule made from one.
        let text: String?
    }

    struct Layout {
        let regex: NSRegularExpression
        let fields: [(name: String, field: LogLayout.Field)]
    }

    var name: String
    /// File names (`*` and `?` wildcards) it's always used for.
    var files: [String] = []
    var layouts: [Layout] = []
    var rules: [Rule] = []
    /// Its own styles for fields and levels; the rest are the defaults (or, merged, the all-logs ones).
    var styles: [LogStyleKey: LogStyle] = [:]
    /// The JSON file it was read from; nil for the built-in one.
    var file: URL?

    static let builtIn = LogFormat(name: "Built-in")

    init(name: String) { self.name = name }

    struct Problem: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// From a rules file: `name`, `files`, `pattern(s)` (a logging layout), `line(s)` (regular expressions with named
    /// groups), `colors` (a style for each field and level), `rules` (`text` or `match`, and `style`, or `color`,
    /// `bold`, `line`, `fade`; `ignoreCase`). `colorsOnly`: just colors and rules, as the all-logs file has.
    init(json j: [String: Any], file: URL? = nil, colorsOnly: Bool = false) throws {
        name = (j["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? file?.deletingPathExtension().lastPathComponent ?? "Log"
        self.file = file
        func list(_ one: String, _ many: String) -> [String] {
            (j[many] as? [String] ?? []) + ((j[one] as? String).map { [$0] } ?? [])
        }
        files = list("file", "files")
        for p in list("pattern", "patterns") {
            guard let re = LogLayout.regex(fromPattern: p) else { throw Problem(message: "The pattern “\(p)” has no fields (%d, %level, %logger, %msg…).") }
            layouts.append(try Self.layout(re))
        }
        for l in list("line", "lines") {
            layouts.append(try Self.layout(l.hasPrefix("^") ? l : "^" + l))
        }
        for (key, value) in j["colors"] as? [String: String] ?? [:] {
            guard let k = LogStyleKey(rawValue: key.lowercased()) else {
                throw Problem(message: "“\(key)” in “colors” isn't one of " + LogStyleKey.allCases.map(\.rawValue).joined(separator: ", ") + ".")
            }
            guard let style = LogStyle(text: value) else { throw Problem(message: "“\(value)” (for \(key)) isn't a color name or #RRGGBB, with bold / tint / fade.") }
            styles[k] = style
        }
        for (k, r) in (j["rules"] as? [[String: Any]] ?? []).enumerated() {
            let options: NSRegularExpression.Options = (r["ignoreCase"] as? Bool ?? false) ? [.caseInsensitive] : []
            let text = r["text"] as? String
            guard let pattern = text.map(Self.markerPattern) ?? r["match"] as? String ?? r["regex"] as? String, !pattern.isEmpty else {
                throw Problem(message: "Rule \(k + 1) has no “text” or “match”.")
            }
            let re: NSRegularExpression
            do { re = try NSRegularExpression(pattern: pattern, options: options) } catch {
                throw Problem(message: "Rule \(k + 1)'s “match” isn't a valid regular expression: \(pattern)")
            }
            var style: LogStyle
            if let words = r["style"] as? String {
                guard let parsed = LogStyle(text: words) else { throw Problem(message: "Rule \(k + 1)'s style “\(words)” isn't a color name or #RRGGBB, with bold / tint / fade.") }
                style = parsed
            } else {
                let colorName = r["color"] as? String
                let color = colorName.flatMap(LogColor.init(name:))
                if let colorName, color == nil { throw Problem(message: "Rule \(k + 1)'s color “\(colorName)” isn't a color name or #RRGGBB.") }
                style = LogStyle(color: color, bold: r["bold"] as? Bool ?? false, tint: r["line"] as? Bool ?? r["tint"] as? Bool ?? false,
                                 fade: r["fade"] as? Bool ?? false)
            }
            rules.append(Rule(regex: re, style: style, text: text))
        }
        if !colorsOnly, layouts.isEmpty, rules.isEmpty, styles.isEmpty {
            throw Problem(message: "It has no “pattern”, “line”, “colors” or “rules” to color with.")
        }
    }

    /// A marker as a regular expression: its text as written, not inside a longer word.
    static func markerPattern(_ text: String) -> String {
        let word = { (c: Character?) in c.map { $0.isLetter || $0.isNumber || $0 == "_" } ?? false }
        return (word(text.first) ? #"(?<![\w])"# : "") + NSRegularExpression.escapedPattern(for: text) + (word(text.last) ? #"(?![\w])"# : "")
    }

    /// This format over `base` (the all-logs colors): its styles win, and its rules come after (so win) base's.
    func merged(over base: LogFormat) -> LogFormat {
        var out = self
        out.styles = base.styles.merging(styles) { _, mine in mine }
        out.rules = base.rules + rules
        return out
    }

    /// The style for a field or level, and whether it's one somebody chose (which then wins over the file's own colors).
    func style(_ key: LogStyleKey) -> (style: LogStyle, chosen: Bool) {
        if let s = styles[key] { return (s, true) }
        return (key.defaultStyle, false)
    }

    /// The style of the marker `text`, if there's a rule for it (the last, which wins).
    func markerStyle(_ text: String) -> LogStyle? {
        rules.last { $0.text == text }?.style
    }

    private static func layout(_ pattern: String) throws -> Layout {
        let re: NSRegularExpression
        do { re = try NSRegularExpression(pattern: pattern) } catch {
            throw Problem(message: "Not a valid regular expression: \(pattern)")
        }
        return Layout(regex: re, fields: LogLayout.groupNames(pattern).map { ($0, LogLayout.Field(group: $0)) })
    }

    /// Whether it names this file (by its name, not its folder).
    func matches(fileName: String) -> Bool {
        files.contains { LogFormats.glob($0, fileName) }
    }

    /// How many of these lines (as they read, without escapes) one of its layouts matches.
    func score(_ lines: [String]) -> Int {
        guard !layouts.isEmpty else { return 0 }
        return lines.filter { line in
            let r = NSRange(location: 0, length: NSString(string: line).length)
            return layouts.contains { $0.regex.firstMatch(in: line, options: [.anchored], range: r) != nil }
        }.count
    }

    // MARK: Painting

    private static let stackFrame = try! NSRegularExpression(pattern: #"^\s+at\s+\S"#)
    private static let frameSource = try! NSRegularExpression(pattern: #"\(([^()]*:\d+|Native Method|Unknown Source)\)\s*$"#)
    private static let causedBy = try! NSRegularExpression(pattern: #"^\s*(Caused by:|Suppressed:)"#)
    private static let moreFrames = try! NSRegularExpression(pattern: #"^\s*\.\.\. \d+ (?:more|common frames omitted)\s*$"#)
    private static let traceback = try! NSRegularExpression(pattern: #"^(Traceback \(most recent call last\):|During handling of the above exception.*|The above exception was the direct cause.*)$"#)
    private static let pythonFrame = try! NSRegularExpression(pattern: #"^\s+File "[^"]*", line \d+"#)
    private static let exceptionStart = try! NSRegularExpression(pattern: #"^(?:[a-zA-Z_$][\w$]*\.)*[A-Z][\w$]*(?:Exception|Error|Throwable|Failure)\b"#)

    /// A time at the start of a line, as most loggers write one (ISO 8601, syslog, Apache, nginx, Go, Android…).
    private static let genericTime = try! NSRegularExpression(pattern: [
        #"^\[?(?:\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:[.,]\d{1,9})?(?:Z|[+-]\d{2}:?\d{2}| ?[A-Z]{3,4}\b)?"#,
        #"\d{4}/\d{2}/\d{2}[ T]\d{2}:\d{2}:\d{2}(?:[.,]\d+)?"#,
        #"\d{2}/[A-Z][a-z]{2}/\d{4}:\d{2}:\d{2}:\d{2}(?: [+-]\d{4})?"#,
        #"[A-Z][a-z]{2} [ \d]\d \d{2}:\d{2}:\d{2}(?:\.\d+)?"#,
        #"(?:[A-Z][a-z]{2} ){1,2}\d{1,2},? \d{4},? \d{1,2}:\d{2}:\d{2}(?: [AP]M)?"#,
        #"\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}"#,
        #"\d{2}:\d{2}:\d{2}(?:[.,]\d+)?)\]?"#,
    ].joined(separator: "|"))
    private static let genericThread = try! NSRegularExpression(pattern: #"\s*(\[[^\]\n]{1,80}\]|<[^>\n]{1,80}>)"#)
    /// A level word: upper case on its own, any case in brackets or after level=.
    private static let genericLevel = try! NSRegularExpression(pattern: [
        #"(?<![\w-])(FATAL|CRITICAL|CRIT|EMERG|ALERT|SEVERE|PANIC|ERROR|ERR|WARNING|WARN|NOTICE|INFO|DEBUG|TRACE|VERBOSE|FINEST|FINER|FINE)(?![\w-])"#,
        #"\[(fatal|critical|crit|emerg|alert|error|err|warning|warn|notice|info|debug|trace|verbose)\]"#,
        #"\b(?:level|lvl|severity)=\"?(\w+)"#,
        #""(?:level|severity|lvl)"\s*:\s*"(\w+)""#,
    ].joined(separator: "|"))
    private static let genericLogger = try! NSRegularExpression(pattern: #"\s+([A-Za-z_][\w$.]*(?:\[[^\]]*\])?)(?=\s+-\s|:\s)"#)

    private static func found(_ r: NSRange) -> Bool { r.location != NSNotFound && r.length > 0 }

    /// How to color one line (without its line break). `carried` is the level of the entry it may belong to.
    func paint(_ line: String, carried: LogLevel?) -> LogLinePaint {
        var out = LogLinePaint()
        let stripped = ANSIText.strip(line)
        let text = stripped.visible
        let ns = NSString(string: text)
        let whole = NSRange(location: 0, length: ns.length)
        // Defaults go under the file's own colors; what somebody chose goes over them.
        var paints: [LogPaint] = [], chosen: [LogPaint] = []
        var tint: LogColor?, fade = false
        func apply(_ r: NSRange, _ style: LogStyle, chosenStyle: Bool) {
            guard Self.found(r) else { return }
            if style.color != nil || style.bold {
                let p = LogPaint(range: r, color: style.color ?? .foreground, bold: style.bold)
                if chosenStyle { chosen.append(p) } else { paints.append(p) }
            }
            if style.tint, let c = style.color { tint = c }
            if style.fade { fade = true }
        }
        func paint(_ r: NSRange, _ key: LogStyleKey) {
            let s = style(key)
            // A level's tint is the entry's, set below; a field's tints the line it's on.
            var line = s.style
            if LogStyleKey.levels.contains(key) { line.tint = false }
            apply(r, line, chosenStyle: s.chosen)
        }
        var messageRange = whole

        // An entry's first line: one of the format's layouts, else the time / level most loggers start with.
        var matchedLayout = false
        for layout in layouts {
            guard let m = layout.regex.firstMatch(in: text, options: [.anchored], range: whole) else { continue }
            matchedLayout = true
            out.isHeader = true
            var message: NSRange?
            for (name, field) in layout.fields {
                let r = m.range(withName: name)
                guard Self.found(r) else { continue }
                switch field {
                case .time: paint(r, .time)
                case .thread: paint(r, .thread)
                case .level:
                    let level = LogLevel(word: ns.substring(with: r))
                    out.level = level
                    if let level { paint(r, LogStyleKey(level)) }
                case .logger: paint(r, .logger)
                case .number, .other: paint(r, .number)
                case .message: message = r
                }
            }
            messageRange = message ?? NSRange(location: m.range.location + m.range.length, length: ns.length - (m.range.location + m.range.length))
            break
        }
        if !matchedLayout {
            var at = 0
            if let t = Self.genericTime.firstMatch(in: text, options: [.anchored], range: whole) {
                out.isHeader = true
                paint(t.range, .time)
                at = t.range.length
                if let th = Self.genericThread.firstMatch(in: text, options: [.anchored], range: NSRange(location: at, length: ns.length - at)),
                   LogLevel(word: ns.substring(with: th.range(at: 1)).trimmingCharacters(in: CharacterSet(charactersIn: "[]<>"))) == nil {
                    paint(th.range(at: 1), .thread)
                    at = th.range.location + th.range.length
                }
            }
            let window = NSRange(location: at, length: min(ns.length - at, 120))
            if let l = Self.genericLevel.firstMatch(in: text, range: window) {
                var r = NSRange(location: NSNotFound, length: 0)
                for g in 1...4 where Self.found(l.range(at: g)) { r = l.range(at: g); break }
                if let level = LogLevel(word: ns.substring(with: r)) {
                    out.isHeader = true
                    out.level = level
                    paint(r, LogStyleKey(level))
                    let after = l.range.location + l.range.length
                    if let g = Self.genericLogger.firstMatch(in: text, options: [.anchored], range: NSRange(location: after, length: ns.length - after)) {
                        paint(g.range(at: 1), .logger)
                        at = g.range.location + g.range.length
                    } else {
                        at = max(at, after)
                    }
                }
            }
            if out.isHeader { messageRange = NSRange(location: at, length: ns.length - at) }
        }

        // A stack trace and the like: it belongs to the entry above.
        if !out.isHeader {
            if Self.stackFrame.firstMatch(in: text, range: whole) != nil {
                out.continues = true
                paint(whole, .stack)
                if let s = Self.frameSource.firstMatch(in: text, range: whole) { paint(s.range(at: 1), .path) }
                messageRange = NSRange(location: NSNotFound, length: 0)
            } else if Self.moreFrames.firstMatch(in: text, range: whole) != nil {
                out.continues = true
                paint(whole, .stack)
                messageRange = NSRange(location: NSNotFound, length: 0)
            } else if let c = Self.causedBy.firstMatch(in: text, range: whole) {
                out.continues = true
                paint(c.range(at: 1), .exception)
            } else if let t = Self.traceback.firstMatch(in: text, range: whole) {
                out.continues = true
                paint(t.range(at: 1), .exception)
                messageRange = NSRange(location: NSNotFound, length: 0)
            } else if Self.pythonFrame.firstMatch(in: text, range: whole) != nil {
                out.continues = true
                paint(whole, .stack)
            } else if Self.exceptionStart.firstMatch(in: text, range: whole) != nil
                        || (ns.length > 0 && (ns.character(at: 0) == 0x20 || ns.character(at: 0) == 0x09)) {
                out.continues = true
            }
            if out.continues { out.level = carried }
        }

        if Self.found(messageRange) {
            LogMessageScanner.scan(stripped.units, in: messageRange) { r, key in paint(r, key) }
        }
        // The entry's level tints it, stack trace and all.
        if let level = out.level {
            let s = style(LogStyleKey(level)).style
            if s.tint, let c = s.color { out.wash = c }
            if s.fade { fade = true }
        }

        // Markers and the format's own rules come last, so they win.
        for rule in rules {
            rule.regex.enumerateMatches(in: text, range: whole) { m, _, _ in
                guard let m else { return }
                let r = m.numberOfRanges > 1 && Self.found(m.range(at: 1)) ? m.range(at: 1) : m.range
                // A regular expression that tints its line (`"line": true`) leaves the match's own colors; a marker
                // is colored and tints too.
                if rule.text == nil, rule.style.tint {
                    if let c = rule.style.color { tint = c }
                    if rule.style.fade { fade = true }
                } else {
                    apply(r, rule.style, chosenStyle: true)
                }
            }
        }
        if let tint { out.wash = tint }

        func raw(_ list: [LogPaint]) -> [LogPaint] {
            list.compactMap { p in
                let r = stripped.raw(p.range)
                return Self.found(r) ? LogPaint(range: r, color: p.color, bold: p.bold) : nil
            }
        }
        if fade {
            // Faded: the whole line dim, whatever else it had.
            let all = stripped.raw(whole)
            out.paints = Self.found(all) ? [LogPaint(range: all, color: .faint)] : []
            out.wash = nil
            return out
        }
        // What the file's own color codes ask for wins over the defaults: the logger chose it. What you chose wins over both.
        out.paints = raw(paints) + stripped.colors + raw(chosen)
        return out
    }
}

/// The parts of a message worth a color (URLs, paths, IDs, numbers, quoted strings, exception classes, true / false /
/// null), found in one pass over its characters: a regular expression with all of them took most of a line's time,
/// and far more on long ones. Past `limit` characters a line is left as it is.
enum LogMessageScanner {
    static let limit = 4000

    private static func isDigit(_ c: UInt16) -> Bool { c >= 0x30 && c <= 0x39 }
    private static func isLetter(_ c: UInt16) -> Bool { (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) }
    private static func isHex(_ c: UInt16) -> Bool { isDigit(c) || (c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66) }
    /// Letters, digits, _ and $, and anything past ASCII (accented letters).
    private static func isWord(_ c: UInt16) -> Bool { isLetter(c) || isDigit(c) || c == 0x5F || c == 0x24 || c > 0x7F }
    private static func isSpace(_ c: UInt16) -> Bool { c == 0x20 || c == 0x09 }
    private static func isPathChar(_ c: UInt16) -> Bool { isWord(c) || c == 0x2E || c == 0x2D || c == 0x40 || c == 0x2B || c == 0x2F }

    private static let pathStops = Set("\",;'<>|*?".utf16), urlStops = Set("\"'<>)]".utf16), urlTrail = Set(".,;:".utf16)
    private static let words: Set<[UInt16]> = Set(["true", "false", "null", "nil", "None", "True", "False", "NaN"].map { Array($0.utf16) })
    private static let exceptionEnds: [[UInt16]] = ["Exception", "Error", "Throwable"].map { Array($0.utf16) }
    private static let units: [[UInt16]] = ["ms", "us", "µs", "ns", "s", "m", "h", "d", "KB", "MB", "GB", "TB", "KiB", "MiB", "GiB", "TiB", "B", "%"]
        .map { Array($0.utf16) }

    /// IOException, java.lang.IllegalStateError: a capitalized class name ending in Exception, Error or Throwable.
    private static func isException(_ name: ArraySlice<UInt16>) -> Bool {
        guard let first = name.first, first >= 0x41, first <= 0x5A else { return false }
        return exceptionEnds.contains { e in name.count > e.count && name.suffix(e.count).elementsEqual(e) }
    }

    static func scan(_ u: [UInt16], in range: NSRange, _ emit: (NSRange, LogStyleKey) -> Void) {
        let start = max(0, range.location), end = min(u.count, range.location + range.length, start + limit)
        var i = start
        func prev(_ k: Int) -> UInt16 { k > 0 ? u[k - 1] : 0x20 }
        func at(_ k: Int) -> UInt16 { k < end ? u[k] : 0 }
        func hexRun(_ k: Int, _ n: Int) -> Bool { k + n <= end && (k..<(k + n)).allSatisfy { isHex(u[$0]) } }
        func put(_ a: Int, _ b: Int, _ key: LogStyleKey) { if b > a { emit(NSRange(location: a, length: b - a), key) } }
        while i < end {
            let c = u[i], p = prev(i)
            // A UUID: 8-4-4-4-12 hex digits.
            if isHex(c), !isWord(p), hexRun(i, 8), at(i + 8) == 0x2D, hexRun(i + 9, 4), at(i + 13) == 0x2D, hexRun(i + 14, 4),
               at(i + 18) == 0x2D, hexRun(i + 19, 4), at(i + 23) == 0x2D, hexRun(i + 24, 12), !isWord(at(i + 36)) {
                put(i, i + 36, .number); i += 36; continue
            }
            // A quoted string.
            if c == 0x22 {
                var j = i + 1
                while j < end, u[j] != 0x22 { j += u[j] == 0x5C ? 2 : 1 }
                if j < end { put(i, j + 1, .string); i = j + 1; continue }
                i += 1; continue
            }
            if c == 0x27, !isWord(p) {
                var j = i + 1
                while j < end, j - i <= 200, u[j] != 0x27 { j += 1 }
                if j < end, u[j] == 0x27, j > i + 1, !isWord(at(j + 1)) { put(i, j + 1, .string); i = j + 1; continue }
                i += 1; continue
            }
            // A Windows path (C:\…, C:/…) or a UNC one (\\server\…).
            if (isLetter(c) && at(i + 1) == 0x3A && (at(i + 2) == 0x5C || at(i + 2) == 0x2F) && !isWord(p) && p != 0x2E)
                || (c == 0x5C && at(i + 1) == 0x5C && !isWord(p)) {
                var j = i + 2
                while j < end, !isSpace(u[j]), !pathStops.contains(u[j]) { j += 1 }
                put(i, j, .path); i = j; continue
            }
            // A Unix path: /a/b, ~/a, ./a, ../a.
            if c == 0x2F || ((c == 0x7E || c == 0x2E) && (at(i + 1) == 0x2F || (c == 0x2E && at(i + 1) == 0x2E && at(i + 2) == 0x2F))),
               !isWord(p), p != 0x2E, p != 0x2F, p != 0x3A, p != 0x7E {
                var j = i
                while j < end, u[j] == 0x2E || u[j] == 0x7E { j += 1 }
                if j < end, u[j] == 0x2F, j + 1 < end, isPathChar(u[j + 1]), u[j + 1] != 0x2F {
                    while j < end, isPathChar(u[j]) { j += 1 }
                    // Not a sentence's last dot.
                    while j > i, u[j - 1] == 0x2E { j -= 1 }
                    put(i, j, .path); i = j; continue
                }
                i += 1; continue
            }
            // A number (with a unit), or an IP address with its port.
            if isDigit(c) || (c == 0x2D && isDigit(at(i + 1))), !isWord(p), p != 0x2E, !(c != 0x2D && p == 0x2D && isWord(prev(i - 1))) {
                var j = i + (c == 0x2D ? 1 : 0)
                while j < end, isDigit(u[j]) { j += 1 }
                var dots = 0
                while at(j) == 0x2E, isDigit(at(j + 1)) {
                    j += 1; dots += 1
                    while j < end, isDigit(u[j]) { j += 1 }
                }
                if dots == 3, at(j) == 0x3A, isDigit(at(j + 1)) { j += 1; while j < end, isDigit(u[j]) { j += 1 } }
                if dots == 1 || dots == 0 || dots == 3 {
                    if let unit = units.first(where: { un in j + un.count <= end && Array(u[j..<(j + un.count)]) == un && !isWord(at(j + un.count)) }) { j += unit.count }
                    if !isWord(at(j)), at(j) != 0x2E || !isDigit(at(j + 1)) { put(i, j, .number); i = j; continue }
                }
                // Part of a word or a version (1.2.3.4.5, 3rd): skip it whole.
                while j < end, isWord(u[j]) || u[j] == 0x2E { j += 1 }
                i = max(j, i + 1); continue
            }
            // A word: a URL's scheme, true / false / null, an exception's class, or nothing.
            if isWord(c) {
                var j = i
                while j < end, isWord(u[j]) || u[j] == 0x2D || u[j] == 0x2B || (u[j] == 0x2E && j + 1 < end && isWord(u[j + 1])) { j += 1 }
                if at(j) == 0x3A, at(j + 1) == 0x2F, at(j + 2) == 0x2F, j > i {
                    var k = j + 3
                    while k < end, !isSpace(u[k]), !urlStops.contains(u[k]) { k += 1 }
                    while k > j + 3, urlTrail.contains(u[k - 1]) { k -= 1 }
                    put(i, k, .url); i = k; continue
                }
                let word = Array(u[i..<j])
                if words.contains(word) {
                    put(i, j, .literal)
                } else if isException(word[((word.lastIndex(of: 0x2E) ?? -1) + 1)...]) {
                    put(i, j, .exception)
                }
                i = j; continue
            }
            i += 1
        }
    }
}

enum LogFormats {
    /// File extensions and names taken for logs.
    static func isLogFile(name: String) -> Bool {
        let lower = name.lowercased()
        if lower.hasSuffix(".log") || lower.hasSuffix(".logs") || lower.hasSuffix(".out") || lower.hasSuffix(".err") { return true }
        // Rotated: app.log.1, app.log.2026-07-21
        if lower.contains(".log.") { return true }
        return ["syslog", "messages", "dmesg", "kern", "auth", "daemon"].contains(lower)
    }

    /// `*` and `?` wildcards, without case.
    static func glob(_ pattern: String, _ name: String) -> Bool {
        let p = Array(pattern.lowercased()), s = Array(name.lowercased())
        var pi = 0, si = 0, star = -1, mark = 0
        while si < s.count {
            if pi < p.count, p[pi] == "?" || p[pi] == s[si] { pi += 1; si += 1 }
            else if pi < p.count, p[pi] == "*" { star = pi; mark = si; pi += 1 }
            else if star >= 0 { pi = star + 1; mark += 1; si = mark }
            else { return false }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }

    /// The formats in a folder (each a .json rules file), by name. Ones that don't read are left out, with why.
    static func load(from dir: URL) -> (formats: [LogFormat], problems: [String]) {
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "json" && !$0.lastPathComponent.hasPrefix("_") }
        var formats: [LogFormat] = [], problems: [String] = []
        for f in files {
            do {
                guard let data = try? Data(contentsOf: f), let j = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw LogFormat.Problem(message: "It isn't a JSON object.")
                }
                formats.append(try LogFormat(json: j, file: f))
            } catch {
                problems.append("\(f.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return (formats.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }, problems)
    }

    /// The format for a file: one that names it, else the one whose layout fits most of its first lines (at least
    /// half of them), else the built-in coloring.
    static func choose(for fileName: String, sample: [String], among formats: [LogFormat]) -> LogFormat {
        if let named = formats.first(where: { $0.matches(fileName: fileName) }) { return named }
        let lines = sample.map { ANSIText.removing($0) }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.prefix(40)
        guard !lines.isEmpty else { return .builtIn }
        let scored = formats.map { ($0, $0.score(Array(lines))) }.max { $0.1 < $1.1 }
        if let (best, score) = scored, score > 0, score * 2 >= lines.count { return best }
        return .builtIn
    }

    // MARK: Importing

    /// Turns a logging config (logback / log4j2 XML, log4j / log4j2 / Spring / Python properties or ini) or a rules
    /// file (JSON) into a rules file's contents. `name` is the file's; `folder` the name of the folder it's in.
    static func convert(_ text: String, name: String, folder: String) throws -> [String: Any] {
        let ext = NSString(string: name).pathExtension.lowercased()
        let base = NSString(string: name).deletingPathExtension
        let generic = ["logback", "logback-spring", "logback-test", "log4j", "log4j2", "log4j2-spring", "log4j2-test",
                       "logging", "application", "config", "settings", "log"]
        let title = generic.contains(base.lowercased()) && !folder.isEmpty ? folder : base

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if ext == "json" || trimmed.hasPrefix("{") {
            guard let data = trimmed.data(using: .utf8), var j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw LogFormat.Problem(message: "“\(name)” isn't valid JSON.")
            }
            if (j["name"] as? String ?? "").isEmpty { j["name"] = title }
            _ = try LogFormat(json: j)
            return j
        }

        var patterns: [String] = [], files: [String] = []
        if trimmed.hasPrefix("<") {
            let body = text.replacingOccurrences(of: #"<!--[\s\S]*?-->"#, with: "", options: .regularExpression)
            // logback <pattern>, log4j2 <Pattern>, <PatternLayout pattern="…">, log4j 1 <param name="ConversionPattern" value="…">
            patterns += captures(#"<(?:pattern|Pattern)>\s*(?:<!\[CDATA\[)?([\s\S]*?)(?:\]\]>)?\s*</(?:pattern|Pattern)>"#, body)
            patterns += captures(#"<PatternLayout\b[^>]*\bpattern\s*=\s*"([^"]*)""#, body)
            patterns += captures(#"<param\s+name\s*=\s*"ConversionPattern"\s+value\s*=\s*"([^"]*)""#, body)
            files += captures(#"<(?:file|fileNamePattern|File|FileNamePattern)>\s*([^<]*?)\s*</"#, body)
            files += captures(#"\b(?:fileName|filePattern)\s*=\s*"([^"]*)""#, body)
            files += captures(#"<param\s+name\s*=\s*"File"\s+value\s*=\s*"([^"]*)""#, body)
        } else {
            for raw in text.components(separatedBy: .newlines) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard !line.hasPrefix("#"), !line.hasPrefix(";"), let eq = line.firstIndex(where: { $0 == "=" || $0 == ":" }) else { continue }
                let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
                var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                if value.count >= 2, let q = value.first, q == "\"" || q == "'", value.last == q { value = String(value.dropFirst().dropLast()) }
                guard !value.isEmpty else { continue }
                if key.hasSuffix("filepattern") || key.hasSuffix("filenamepattern") || key.hasSuffix(".file") || key.hasSuffix(".filename")
                    || key == "logging.file.name" || key == "filename" {
                    files.append(value)
                } else if key.hasSuffix("pattern") || key.hasSuffix("conversionpattern") || key == "format" || key.hasSuffix(".format")
                            || key.hasPrefix("logging.pattern.") {
                    // configparser's escaped %% before a Python field.
                    patterns.append(value.replacingOccurrences(of: "%%(", with: "%("))
                }
            }
        }
        patterns = patterns.map(unescapeXML).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        // The same layout written twice (console and file appenders) is one.
        var seen = Set<String>(), layouts: [String] = []
        for p in patterns {
            guard let re = LogLayout.regex(fromPattern: p), seen.insert(re).inserted else { continue }
            layouts.append(p)
        }
        guard !layouts.isEmpty else {
            throw LogFormat.Problem(message: "No log layout was found in “\(name)”. It reads logback and log4j2 XML (<pattern>, <PatternLayout>), "
                + "log4j / Spring / Python properties (…pattern=, format=), or a JSON rules file.")
        }
        var names: [String] = []
        for f in files.map(unescapeXML) {
            let leaf = f.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? f
            let glob = leaf
                .replacingOccurrences(of: #"%d\{[^}]*\}|%[a-zA-Z]+(?:\{[^}]*\})?|\$\{[^}]*\}|\{[^}]*\}"#, with: "*", options: .regularExpression)
                .replacingOccurrences(of: #"\*+"#, with: "*", options: .regularExpression)
            if !glob.isEmpty, glob != "*", !names.contains(glob) { names.append(glob) }
        }
        var j: [String: Any] = ["name": title, "patterns": layouts]
        if !names.isEmpty { j["files"] = names }
        return j
    }

    /// Imports a logging config or rules file into `dir` as a rules file (named after the format, never over another).
    static func importFile(_ url: URL, into dir: URL) throws -> LogFormat {
        guard let data = try? Data(contentsOf: url) else { throw LogFormat.Problem(message: "Couldn't read “\(url.lastPathComponent)”.") }
        var j = try convert(String(decoding: data, as: UTF8.self), name: url.lastPathComponent, folder: url.deletingLastPathComponent().lastPathComponent)
        j["importedFrom"] = url.path
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = (j["name"] as? String) ?? "Log"
        let safe = String(name.map { "\\/:*?\"<>|".contains($0) ? "-" : $0 }).trimmingCharacters(in: .whitespaces)
        var target = dir.appendingPathComponent((safe.isEmpty ? "Log" : safe) + ".json")
        var n = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = dir.appendingPathComponent("\(safe) \(n).json")
            n += 1
        }
        if n > 2 { j["name"] = "\(name) \(n - 1)" }
        let out = try JSONSerialization.data(withJSONObject: j, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: target)
        return try LogFormat(json: j, file: target)
    }

    private static func captures(_ pattern: String, _ text: String) -> [String] {
        let re = try! NSRegularExpression(pattern: pattern)
        let ns = NSString(string: text)
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap {
            $0.range(at: 1).location == NSNotFound ? nil : ns.substring(with: $0.range(at: 1))
        }
    }

    private static func unescapeXML(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
