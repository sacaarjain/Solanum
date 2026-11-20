import Foundation

/// NumPy's own files, for the file editor: a .npy holds one array (a short header naming its type and shape, then its
/// values as they sit in memory) and a .npz a zip of them (np.savez stores each as it is, np.savez_compressed deflates
/// them). Shown as text: what each array is, then its values in a table (a 3-D one slice by slice), and, for a 2-D one,
/// as a picture: a heatmap of its values, or the image itself when it's height × width × RGB(A).
struct NumpyArray {
    enum Kind { case bool, int, uint, float, complex, unicode, bytes, datetime, timedelta }

    let name: String
    /// The type as NumPy writes it ("<f8", "|b1", "<U10", "<M8[ns]").
    let descr: String
    let kind: Kind
    let itemSize: Int
    let bigEndian: Bool
    /// A datetime's or timedelta's unit ("ns", "D").
    let unit: String
    let shape: [Int]
    let fortran: Bool
    /// The values, as stored; fewer than `count` when the file was cut short.
    let values: [UInt8]

    var count: Int { shape.reduce(1, *) }
    var available: Int { min(count, values.count / max(itemSize, 1)) }
    /// Plain numbers (not text, dates or complex): what can be plotted.
    var isNumeric: Bool { kind == .bool || kind == .int || kind == .uint || kind == .float }
    /// Height × width × 3 or 4, of bytes or of floats: a picture's own colors.
    var isImage: Bool { shape.count == 3 && (shape[2] == 3 || shape[2] == 4) && (kind == .uint && itemSize == 1 || kind == .float) }

    /// NumPy's name for the type: "float64", "<U10", "datetime64[ns]".
    var typeName: String {
        let bits = String(itemSize * 8)
        let name: String
        switch kind {
        case .bool: name = "bool"
        case .int: name = "int" + bits
        case .uint: name = "uint" + bits
        case .float: name = "float" + bits
        case .complex: name = "complex" + bits
        case .unicode: name = "<U\(itemSize / 4)"
        case .bytes: name = "|S\(itemSize)"
        case .datetime: name = "datetime64[\(unit)]"
        case .timedelta: name = "timedelta64[\(unit)]"
        }
        return name + (bigEndian && itemSize > 1 && kind != .bytes ? " (big-endian)" : "")
    }

    /// "(3, 4)", "(5,)", "()": as NumPy prints it.
    var shapeText: String {
        shape.count == 1 ? "(\(shape[0]),)" : "(" + shape.map(String.init).joined(separator: ", ") + ")"
    }

    // MARK: Reading

    enum Problem: Error, Equatable {
        case notNumpy
        /// Python objects, pickled: reading them would run code, so they're never read.
        case objects
        /// Named fields (a structured type), or a type with no fixed meaning here.
        case unsupported(String)
    }

    /// One array from a .npy file's bytes (perhaps only the start of them).
    static func parse(_ b: ArraySlice<UInt8>, name: String) -> Result<NumpyArray, Problem> {
        let s = b.startIndex
        guard b.count >= 10, Array(b[s..<(s + 6)]) == [0x93, 0x4E, 0x55, 0x4D, 0x50, 0x59] else { return .failure(.notNumpy) }
        let major = b[s + 6]
        let length: Int, start: Int
        if major == 1 {
            length = Int(b[s + 8]) | Int(b[s + 9]) << 8
            start = 10
        } else {
            guard b.count >= 12 else { return .failure(.notNumpy) }
            length = Int(b[s + 8]) | Int(b[s + 9]) << 8 | Int(b[s + 10]) << 16 | Int(b[s + 11]) << 24
            start = 12
        }
        guard start + length <= b.count else { return .failure(.notNumpy) }
        let header = String(decoding: b[(s + start)..<(s + start + length)], as: UTF8.self)
        guard let descr = Self.descr(in: header) else {
            return .failure(header.contains("'descr': [") || header.contains("\"descr\": [") ? .unsupported("named fields") : .notNumpy)
        }
        guard let shape = Self.shape(in: header) else { return .failure(.notNumpy) }
        let fortran = header.contains("'fortran_order': True")
        // "<f8": byte order, kind, size and (for dates) a unit.
        var chars = Substring(descr)
        var big = false
        if let first = chars.first, "<>|=".contains(first) {
            big = first == ">"
            chars = chars.dropFirst()
        }
        guard let k = chars.first else { return .failure(.notNumpy) }
        chars = chars.dropFirst()
        let digits = chars.prefix { $0.isNumber }
        let size = Int(digits) ?? 0
        var unit = ""
        if let open = chars.firstIndex(of: "["), let close = chars.firstIndex(of: "]"), open < close {
            unit = String(chars[chars.index(after: open)..<close])
        }
        let kind: Kind, itemSize: Int
        switch k {
        case "b", "?": kind = .bool; itemSize = 1
        case "i": kind = .int; itemSize = size
        case "u": kind = .uint; itemSize = size
        case "f": kind = .float; itemSize = size
        case "c": kind = .complex; itemSize = size
        case "U": kind = .unicode; itemSize = size * 4
        case "S", "a": kind = .bytes; itemSize = size
        case "M": kind = .datetime; itemSize = size
        case "m": kind = .timedelta; itemSize = size
        case "O": return .failure(.objects)
        default: return .failure(.unsupported(descr))
        }
        let sizes: [Kind: Set<Int>] = [.int: [1, 2, 4, 8], .uint: [1, 2, 4, 8], .float: [2, 4, 8], .complex: [8, 16],
                                       .datetime: [8], .timedelta: [8]]
        if let allowed = sizes[kind], !allowed.contains(itemSize) { return .failure(.unsupported(descr)) }
        guard itemSize > 0 || kind == .unicode || kind == .bytes else { return .failure(.unsupported(descr)) }
        return .success(NumpyArray(name: name, descr: descr, kind: kind, itemSize: itemSize, bigEndian: big, unit: unit,
                                   shape: shape, fortran: fortran, values: Array(b[(s + start + length)...])))
    }

    /// The header's 'descr': a quoted type. Nil for a list (named fields).
    private static func descr(in header: String) -> String? {
        guard let key = header.range(of: "'descr'") ?? header.range(of: "\"descr\"") else { return nil }
        var rest = header[key.upperBound...].drop { $0 == ":" || $0 == " " }
        guard let quote = rest.first, quote == "'" || quote == "\"" else { return nil }
        rest = rest.dropFirst()
        guard let end = rest.firstIndex(of: quote) else { return nil }
        return String(rest[..<end])
    }

    private static func shape(in header: String) -> [Int]? {
        guard let key = header.range(of: "'shape'") ?? header.range(of: "\"shape\""),
              let open = header[key.upperBound...].firstIndex(of: "("),
              let close = header[open...].firstIndex(of: ")") else { return nil }
        var out: [Int] = []
        for part in header[header.index(after: open)..<close].split(separator: ",") {
            let t = part.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "L", with: "")
            if t.isEmpty { continue }
            guard let n = Int(t), n >= 0 else { return nil }
            out.append(n)
        }
        return out
    }

    // MARK: Values

    /// Where the value at a position (in C order, the last index fastest, as it's shown) is stored.
    func stored(_ c: Int) -> Int {
        guard fortran, shape.count > 1 else { return c }
        var rest = c, at = 0, step = 1
        var index = [Int](repeating: 0, count: shape.count)
        for d in (0..<shape.count).reversed() {
            index[d] = rest % shape[d]
            rest /= shape[d]
        }
        for d in 0..<shape.count {
            at += index[d] * step
            step *= shape[d]
        }
        return at
    }

    private func raw(_ offset: Int, _ size: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<size {
            let byte = UInt64(values[offset + (bigEndian ? i : size - 1 - i)])
            v = v << 8 | byte
        }
        return v
    }

    private func signed(_ offset: Int, _ size: Int) -> Int64 {
        let shift = UInt64(64 - size * 8)
        return Int64(bitPattern: raw(offset, size) << shift) >> Int64(shift)
    }

    private func real(_ offset: Int, _ size: Int) -> Double {
        let bits = raw(offset, size)
        switch size {
        case 2: return Self.half(UInt16(bits))
        case 4: return Double(Float(bitPattern: UInt32(bits)))
        default: return Double(bitPattern: bits)
        }
    }

    static func half(_ h: UInt16) -> Double {
        let sign: Double = h & 0x8000 != 0 ? -1 : 1
        let exp = Int(h >> 10 & 0x1F), frac = Double(h & 0x3FF)
        if exp == 0 { return sign * frac * pow(2, -24) }
        if exp == 31 { return frac == 0 ? sign * .infinity : .nan }
        return sign * (1 + frac / 1024) * pow(2, Double(exp - 15))
    }

    /// The value stored at `i`, as a number (for the picture). Nil for text, dates and complex numbers.
    func number(_ i: Int) -> Double? {
        let o = i * itemSize
        // The usual types, stored in this computer's own byte order: read straight off (a view reads millions).
        if !bigEndian {
            switch (kind, itemSize) {
            case (.float, 4): return Double(values.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: Float.self) })
            case (.float, 8): return values.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: Double.self) }
            case (.uint, 1): return Double(values[o])
            case (.int, 1): return Double(Int8(bitPattern: values[o]))
            case (.uint, 2): return Double(values.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt16.self) })
            case (.int, 2): return Double(values.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: Int16.self) })
            case (.uint, 4): return Double(values.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt32.self) })
            case (.int, 4): return Double(values.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: Int32.self) })
            case (.int, 8): return Double(values.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: Int64.self) })
            default: break
            }
        }
        switch kind {
        case .bool: return values[o] != 0 ? 1 : 0
        case .int: return Double(signed(o, itemSize))
        case .uint: return Double(raw(o, itemSize))
        case .float: return real(o, itemSize)
        default: return nil
        }
    }

    /// The value stored at `i`, as NumPy would print it.
    func text(_ i: Int) -> String {
        let o = i * itemSize
        switch kind {
        case .bool: return values[o] != 0 ? "True" : "False"
        case .int: return String(signed(o, itemSize))
        case .uint: return String(raw(o, itemSize))
        case .float:
            // A float32 to its own precision (0.1, not 0.10000000149011612).
            if itemSize == 4 { let v = Float(real(o, 4)); return v.isFinite ? "\(v)" : Self.format(Double(v), half: false) }
            return Self.format(real(o, itemSize), half: itemSize == 2)
        case .complex:
            let h = itemSize / 2, re = real(o, h), im = real(o + h, h)
            let imText = Self.format(abs(im), half: false)
            return Self.format(re, half: false) + (im.sign == .minus ? "-" : "+") + imText + "j"
        case .unicode:
            var scalars = String.UnicodeScalarView()
            for k in 0..<(itemSize / 4) {
                let v = UInt32(raw(o + k * 4, 4))
                if v == 0 { break }
                scalars.append(Unicode.Scalar(v) ?? "\u{FFFD}")
            }
            return "'" + String(scalars) + "'"
        case .bytes:
            var out = "b'"
            for k in 0..<itemSize {
                let c = values[o + k]
                if c == 0 { break }
                out += c >= 0x20 && c < 0x7F && c != 0x27 && c != 0x5C ? String(UnicodeScalar(c)) : String(format: "\\x%02x", c)
            }
            return out + "'"
        case .datetime: return Self.date(signed(o, 8), unit: unit)
        case .timedelta:
            let v = signed(o, 8)
            return v == Int64.min ? "NaT" : "\(v) \(unit)"
        }
    }

    static func format(_ d: Double, half: Bool) -> String {
        if d.isNaN { return "nan" }
        if d.isInfinite { return d < 0 ? "-inf" : "inf" }
        if half { return String(format: "%.4g", d) }
        return "\(d)"
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    /// A datetime64 value: whole days as a date, finer units with the time.
    static func date(_ v: Int64, unit: String) -> String {
        if v == Int64.min { return "NaT" }
        switch unit {
        case "Y": return String(1970 + v)
        case "M":
            let y = 1970 + Int(v >= 0 ? v / 12 : (v - 11) / 12), m = Int(((v % 12) + 12) % 12) + 1
            return String(format: "%d-%02d", y, m)
        default: break
        }
        let seconds: Double
        switch unit {
        case "W": seconds = Double(v) * 604_800
        case "D": seconds = Double(v) * 86_400
        case "h": seconds = Double(v) * 3_600
        case "m": seconds = Double(v) * 60
        case "s": seconds = Double(v)
        case "ms": seconds = Double(v) / 1e3
        case "us": seconds = Double(v) / 1e6
        case "ns": seconds = Double(v) / 1e9
        default: return "\(v) \(unit)"
        }
        let f = dateFormatter
        switch unit {
        case "W", "D": f.dateFormat = "yyyy-MM-dd"
        case "h", "m": f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        case "s": f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        case "ms": f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        default: f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
        }
        return f.string(from: Date(timeIntervalSince1970: seconds))
    }
}

/// A .npy or .npz file, read for showing.
struct NumpyFile {
    /// Each array (by name in a .npz), or why it can't be shown.
    let arrays: [(name: String, array: Result<NumpyArray, NumpyArray.Problem>)]
    let isArchive: Bool
    /// Only the start of the file was read.
    let cut: Bool

    /// The most values written out in all; a bigger array shows its start.
    static let valueLimit = 200_000
    /// The most columns of a table.
    static let columnLimit = 500

    init(_ data: [UInt8], name: String, cut: Bool = false) {
        self.cut = cut
        isArchive = name.lowercased().hasSuffix(".npz") || (data.count >= 4 && data[0] == 0x50 && data[1] == 0x4B && data[2] == 3 && data[3] == 4)
        if isArchive {
            arrays = Zip.entries(data).map { e in
                let short = e.name.hasSuffix(".npy") ? String(e.name.dropLast(4)) : e.name
                guard let bytes = e.bytes else { return (short, .failure(.unsupported("compressed in a way that can't be read"))) }
                return (short, NumpyArray.parse(bytes[...], name: short))
            }
        } else {
            arrays = [(name, NumpyArray.parse(data[...], name: name))]
        }
    }

    // MARK: As text

    /// The lines shown: what each array is, then its values.
    var lines: [String] {
        var out: [String] = []
        var budget = Self.valueLimit
        func problemText(_ p: NumpyArray.Problem) -> String {
            switch p {
            case .notNumpy: return "Not a NumPy array (or it was cut short)."
            case .objects: return "Holds Python objects (pickled): not shown, since reading them would run code."
            case .unsupported(let what): return "Its type (\(what)) can't be shown here."
            }
        }
        if isArchive {
            out.append(arrays.count == 1 ? "1 array" : "\(arrays.count) arrays")
            if arrays.isEmpty { out.append("(This .npz holds no arrays, or it isn't a zip.)") }
            let width = arrays.map(\.name.count).max() ?? 0
            let typeWidth = arrays.compactMap { try? $0.array.get().typeName.count }.max() ?? 0
            for (name, a) in arrays {
                let pad = String(repeating: " ", count: width - name.count)
                switch a {
                case .success(let a):
                    out.append("  \(name)\(pad)   \(a.typeName)" + String(repeating: " ", count: typeWidth - a.typeName.count) + "   \(a.shapeText)")
                case .failure(let p): out.append("  \(name)\(pad)   \(problemText(p))")
                }
            }
        }
        for (name, a) in arrays {
            if isArchive { out += ["", ""] }
            switch a {
            case .failure(let p):
                if isArchive { out.append(name) }
                out.append(problemText(p))
            case .success(let a):
                var about = [a.typeName, "shape " + a.shapeText, Self.grouped(a.count) + (a.count == 1 ? " value" : " values")]
                if a.fortran && a.shape.count > 1 { about.append("Fortran order") }
                out.append((isArchive ? [name] + about : about).joined(separator: "  \u{00B7}  "))
                out.append("")
                out += table(a, budget: &budget)
            }
        }
        if cut { out += ["", "Only the start of this file was read: values past it aren't shown."] }
        return out
    }

    static func grouped(_ n: Int) -> String {
        let digits = Array(String(n))
        var out = ""
        for (i, d) in digits.enumerated() {
            if i > 0 && (digits.count - i) % 3 == 0 { out += "," }
            out.append(d)
        }
        return out
    }

    /// An array's values: one value as it is; a list as rows of index and value; more dimensions as a table of the last
    /// two, one for each place in the others ("[0, :, :]").
    private func table(_ a: NumpyArray, budget: inout Int) -> [String] {
        if a.count == 0 { return ["(empty)"] }
        if a.available == 0 { return ["(its values weren't read)"] }
        if a.shape.isEmpty { budget -= 1; return [a.text(0)] }
        let leftAligned = a.kind == .unicode || a.kind == .bytes
        var out: [String] = []
        let rows = a.shape.count == 1 ? a.shape[0] : a.shape[a.shape.count - 2]
        let cols = a.shape.count == 1 ? 1 : a.shape[a.shape.count - 1]
        let slices = a.shape.count <= 2 ? 1 : a.count / max(rows * cols, 1)
        let leading = Array(a.shape.dropLast(2))
        for slice in 0..<slices {
            guard budget > 0 else {
                out += ["", "… \(Self.grouped(slices - slice)) more of the \(Self.grouped(slices)) tables, not shown"]
                break
            }
            if a.shape.count > 2 {
                var index: [Int] = [], rest = slice
                for d in leading.reversed() { index.insert(rest % d, at: 0); rest /= d }
                if slice > 0 { out.append("") }
                out.append("[" + (index.map(String.init) + [":", ":"]).joined(separator: ", ") + "]")
            }
            let shownCols = min(cols, Self.columnLimit)
            let shownRows = min(rows, max(1, budget / shownCols))
            var cells: [[String]] = []
            var missing = false
            for r in 0..<shownRows {
                var row: [String] = []
                for c in 0..<shownCols {
                    let i = a.stored((slice * rows + r) * cols + c)
                    if i >= a.available { missing = true; break }
                    row.append(a.text(i))
                }
                if row.isEmpty { break }
                cells.append(row)
                if missing { break }
            }
            budget -= cells.count * shownCols
            let header = a.shape.count == 1 ? nil : (0..<shownCols).map(String.init)
            out += Self.layout(cells, rowLabels: (0..<cells.count).map(String.init), header: header, leftAligned: leftAligned)
            if shownCols < cols { out.append("… \(Self.grouped(cols - shownCols)) more columns, not shown") }
            if missing { out.append("… the rest wasn't read"); break }
            if cells.count < rows { out.append("… \(Self.grouped(rows - cells.count)) more rows, not shown") }
        }
        return out
    }

    /// Columns padded to line up: the row's index, then its values (numbers to the right, text to the left).
    static func layout(_ cells: [[String]], rowLabels: [String], header: [String]?, leftAligned: Bool) -> [String] {
        let columns = max(cells.map(\.count).max() ?? 0, header?.count ?? 0)
        var widths = [Int](repeating: 0, count: columns)
        for row in cells + (header.map { [$0] } ?? []) {
            for (c, t) in row.enumerated() { widths[c] = max(widths[c], t.count) }
        }
        let labelWidth = rowLabels.map(\.count).max() ?? 0
        func pad(_ t: String, _ w: Int, left: Bool) -> String {
            let fill = String(repeating: " ", count: max(w - t.count, 0))
            return left ? t + fill : fill + t
        }
        func line(_ label: String, _ row: [String], left: Bool) -> String {
            var s = pad(label, labelWidth, left: false)
            for (c, t) in row.enumerated() { s += "   " + pad(t, widths[c], left: left) }
            while s.last == " " { s.removeLast() }
            return s
        }
        var out: [String] = []
        if let header { out.append(line("", header, left: leftAligned)) }
        for (r, row) in cells.enumerated() { out.append(line(rowLabels[r], row, left: leftAligned)) }
        return out
    }

    // MARK: As a picture

    /// The first array that makes a picture: a 2-D one (or the first 2-D slice of more), as a heatmap from its lowest
    /// value (dark blue) to its highest (yellow), or height × width × 3 or 4 as the image it is. A Windows bitmap,
    /// each value at least a few pixels across, and what it shows.
    var picture: (bitmap: [UInt8], caption: String)? {
        for case (_, .success(let a)) in arrays {
            if let p = Self.picture(a) { return (p.bitmap, (isArchive ? a.name + "  \u{00B7}  " : "") + p.caption) }
        }
        return nil
    }

    static func picture(_ a: NumpyArray) -> (bitmap: [UInt8], caption: String)? {
        guard a.shape.count >= 2, [.bool, .int, .uint, .float].contains(a.kind), a.available > 0 else { return nil }
        let image = a.shape.count == 3 && (a.shape[2] == 3 || a.shape[2] == 4) && (a.kind == .uint && a.itemSize == 1 || a.kind == .float)
        let rows = image ? a.shape[0] : a.shape[a.shape.count - 2]
        let cols = image ? a.shape[1] : a.shape[a.shape.count - 1]
        let depth = image ? a.shape[2] : 1
        guard rows > 0, cols > 0 else { return nil }
        // At most 2048 values a side (a bigger one sampled), each drawn as a square of pixels up to 512 across in all.
        let step = max(1, (max(rows, cols) + 2047) / 2048)
        let outRows = (rows + step - 1) / step, outCols = (cols + step - 1) / step
        let k = max(1, min(32, 512 / max(outRows, outCols)))
        func value(_ r: Int, _ c: Int, _ ch: Int) -> Double? {
            let i = a.stored(((r * cols) + c) * depth + ch)
            guard i < a.available, let v = a.number(i), v.isFinite else { return nil }
            return v
        }
        var lo = Double.infinity, hi = -Double.infinity
        if !image || a.kind == .float {
            for r in stride(from: 0, to: rows, by: step) {
                for c in stride(from: 0, to: cols, by: step) {
                    for ch in 0..<min(depth, 3) { if let v = value(r, c, ch) { lo = min(lo, v); hi = max(hi, v) } }
                }
            }
        }
        // A float image: 0…1 as most are, else its own range.
        if image && a.kind == .float && lo >= 0 && hi <= 1 { lo = 0; hi = 1 }
        let width = outCols * k, height = outRows * k
        let rowBytes = (width * 3 + 3) & ~3
        var bmp = [UInt8](repeating: 0, count: 54 + rowBytes * height)
        func put(_ v: Int, at o: Int, _ n: Int) { for i in 0..<n { bmp[o + i] = UInt8(truncatingIfNeeded: v >> (8 * i)) } }
        bmp[0] = 0x42; bmp[1] = 0x4D
        put(bmp.count, at: 2, 4); put(54, at: 10, 4); put(40, at: 14, 4)
        put(width, at: 18, 4); put(height, at: 22, 4); put(1, at: 26, 2); put(24, at: 28, 2)
        put(rowBytes * height, at: 34, 4)
        for orow in 0..<outRows {
            for ocol in 0..<outCols {
                let r = orow * step, c = ocol * step
                var rgb: (UInt8, UInt8, UInt8)
                if image {
                    func channel(_ ch: Int) -> UInt8 {
                        guard let v = value(r, c, ch) else { return 128 }
                        let t = a.kind == .float ? (hi > lo ? (v - lo) / (hi - lo) : 0.5) : v / 255
                        return UInt8(max(0, min(255, (t * 255).rounded())))
                    }
                    rgb = (channel(0), channel(1), channel(2))
                } else if let v = value(r, c, 0) {
                    rgb = Self.viridis(hi > lo ? (v - lo) / (hi - lo) : 0.5)
                } else {
                    rgb = (128, 128, 128)
                }
                for y in (orow * k)..<((orow + 1) * k) {
                    let line = 54 + (height - 1 - y) * rowBytes
                    for x in (ocol * k)..<((ocol + 1) * k) {
                        bmp[line + x * 3] = rgb.2
                        bmp[line + x * 3 + 1] = rgb.1
                        bmp[line + x * 3 + 2] = rgb.0
                    }
                }
            }
        }
        var caption = "\(Self.grouped(rows)) × \(Self.grouped(cols))"
        if a.shape.count > 2 && !image { caption = "[" + (Array(repeating: "0", count: a.shape.count - 2) + [":", ":"]).joined(separator: ", ") + "]  \u{00B7}  " + caption }
        if image { caption += "  \u{00B7}  as an image" }
        else if lo <= hi {
            func short(_ v: Double) -> String { a.kind == .float ? String(format: "%.4g", v) : String(Int64(v)) }
            caption += "  \u{00B7}  " + short(lo) + " (dark) to " + short(hi) + " (light)"
        }
        if step > 1 { caption += "  \u{00B7}  every \(step)th value" }
        return (bmp, caption)
    }

    /// Viridis, NumPy's (matplotlib's) usual colors for a heatmap: dark blue through green to yellow.
    static func viridis(_ t: Double) -> (UInt8, UInt8, UInt8) {
        let stops: [(Double, Double, Double)] = [(68, 1, 84), (72, 40, 120), (62, 74, 137), (49, 104, 142), (38, 130, 142),
                                                 (31, 158, 137), (53, 183, 121), (109, 205, 89), (253, 231, 37)]
        let x = max(0, min(1, t)) * Double(stops.count - 1)
        let i = min(Int(x), stops.count - 2), f = x - Double(i)
        let a = stops[i], b = stops[i + 1]
        func mix(_ p: Double, _ q: Double) -> UInt8 { UInt8((p + (q - p) * f).rounded()) }
        return (mix(a.0, b.0), mix(a.1, b.1), mix(a.2, b.2))
    }
}

/// The files in a zip, as np.savez writes it, read from the start (so a .npz read only in part still shows what's
/// there): each one's name and contents, unpacked when deflated (np.savez_compressed).
enum Zip {
    struct Entry {
        let name: String
        /// Nil when it's packed some other way than stored or deflated.
        let bytes: [UInt8]?
    }

    static func entries(_ d: [UInt8], limit: Int = 512 * 1024 * 1024) -> [Entry] {
        func u16(_ o: Int) -> Int { o + 2 <= d.count ? Int(d[o]) | Int(d[o + 1]) << 8 : 0 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        func u64(_ o: Int) -> Int { u32(o) | u32(o + 4) << 32 }
        var out: [Entry] = []
        var o = 0
        while o + 30 <= d.count, u32(o) == 0x04034B50 {
            let method = u16(o + 8), nameLength = u16(o + 26), extraLength = u16(o + 28)
            var packed = u32(o + 18), size = u32(o + 22)
            let nameStart = o + 30, extraStart = nameStart + nameLength, dataStart = extraStart + extraLength
            guard dataStart <= d.count else { break }
            let name = String(decoding: d[nameStart..<extraStart], as: UTF8.self)
            // Zip64 (np.savez always asks for it): the sizes are in an extra field.
            var e = extraStart
            while e + 4 <= dataStart {
                let id = u16(e), length = u16(e + 2)
                if id == 1 {
                    var f = e + 4
                    if size == 0xFFFF_FFFF, f + 8 <= e + 4 + length { size = u64(f); f += 8 }
                    if packed == 0xFFFF_FFFF, f + 8 <= e + 4 + length { packed = u64(f) }
                }
                e += 4 + length
            }
            let end = min(dataStart + packed, d.count)
            let body = d[dataStart..<end]
            switch method {
            case 0: out.append(Entry(name: name, bytes: Array(body)))
            case 8: out.append(Entry(name: name, bytes: Inflate.inflate(body, limit: min(size, limit))))
            default: out.append(Entry(name: name, bytes: nil))
            }
            guard dataStart + packed <= d.count, packed >= 0 else { break }
            o = dataStart + packed
            // A data descriptor after it (sizes written after the data): skipped by its signature, when there is one.
            if u32(o) == 0x08074B50 { o += 16 }
        }
        return out
    }
}

/// Deflate (RFC 1951), unpacked: what zip and gzip use. As much as there is, up to `limit` bytes, when the data stops
/// early or is damaged.
enum Inflate {
    private struct Huffman {
        var counts = [Int](repeating: 0, count: 16)
        var symbols: [Int]
        init(_ lengths: ArraySlice<Int>) {
            symbols = [Int](repeating: 0, count: lengths.count)
            for l in lengths { counts[l] += 1 }
            counts[0] = 0
            var offsets = [Int](repeating: 0, count: 16)
            for l in 1..<15 { offsets[l + 1] = offsets[l] + counts[l] }
            for (i, l) in lengths.enumerated() where l != 0 {
                symbols[offsets[l]] = i
                offsets[l] += 1
            }
        }
    }

    private static let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    private static let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    private static let distanceBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073,
                                       4097, 6145, 8193, 12289, 16385, 24577]
    private static let distanceExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
    private static let order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
    private static let fixed: (Huffman, Huffman) = {
        var l = [Int](repeating: 8, count: 288)
        for i in 144..<256 { l[i] = 9 }
        for i in 256..<280 { l[i] = 7 }
        return (Huffman(l[...]), Huffman([Int](repeating: 5, count: 30)[...]))
    }()

    private struct Ran: Error {}

    static func inflate(_ input: ArraySlice<UInt8>, limit: Int = .max) -> [UInt8] {
        let src = Array(input)
        var out: [UInt8] = []
        out.reserveCapacity(min(limit, max(src.count * 4, 1024)))
        var pos = 0, bitBuffer = 0, bitCount = 0
        func bits(_ n: Int) throws -> Int {
            while bitCount < n {
                guard pos < src.count else { throw Ran() }
                bitBuffer |= Int(src[pos]) << bitCount
                pos += 1
                bitCount += 8
            }
            let v = bitBuffer & ((1 << n) - 1)
            bitBuffer >>= n
            bitCount -= n
            return v
        }
        func decode(_ h: Huffman) throws -> Int {
            var code = 0, first = 0, index = 0
            for l in 1...15 {
                code |= try bits(1)
                let count = h.counts[l]
                if code - count < first { return h.symbols[index + code - first] }
                index += count
                first = (first + count) << 1
                code <<= 1
            }
            throw Ran()
        }
        func codes(_ lit: Huffman, _ dist: Huffman) throws {
            while true {
                let sym = try decode(lit)
                if sym < 256 {
                    out.append(UInt8(sym))
                    if out.count >= limit { throw Ran() }
                } else if sym == 256 {
                    return
                } else {
                    let s = sym - 257
                    guard s < 29 else { throw Ran() }
                    let length = lengthBase[s] + (try bits(lengthExtra[s]))
                    let ds = try decode(dist)
                    guard ds < 30 else { throw Ran() }
                    let distance = distanceBase[ds] + (try bits(distanceExtra[ds]))
                    guard distance <= out.count else { throw Ran() }
                    let from = out.count - distance
                    for i in 0..<length {
                        out.append(out[from + i])
                        if out.count >= limit { throw Ran() }
                    }
                }
            }
        }
        do {
            var last = 0
            while last == 0 {
                last = try bits(1)
                switch try bits(2) {
                case 0:
                    bitBuffer = 0
                    bitCount = 0
                    guard pos + 4 <= src.count else { throw Ran() }
                    let length = Int(src[pos]) | Int(src[pos + 1]) << 8
                    pos += 4
                    let end = min(pos + length, src.count)
                    out += src[pos..<end]
                    pos = end
                    if out.count >= limit || end < pos + length { throw Ran() }
                case 1:
                    try codes(fixed.0, fixed.1)
                case 2:
                    let nlen = try bits(5) + 257, ndist = try bits(5) + 1, ncode = try bits(4) + 4
                    var lengths = [Int](repeating: 0, count: 320)
                    for i in 0..<ncode { lengths[order[i]] = try bits(3) }
                    let lencode = Huffman(lengths[0..<19])
                    var i = 0
                    while i < nlen + ndist {
                        let sym = try decode(lencode)
                        if sym < 16 {
                            lengths[i] = sym
                            i += 1
                        } else {
                            var len = 0, repeatCount: Int
                            if sym == 16 {
                                guard i > 0 else { throw Ran() }
                                len = lengths[i - 1]
                                repeatCount = 3 + (try bits(2))
                            } else if sym == 17 {
                                repeatCount = 3 + (try bits(3))
                            } else {
                                repeatCount = 11 + (try bits(7))
                            }
                            guard i + repeatCount <= nlen + ndist else { throw Ran() }
                            for _ in 0..<repeatCount { lengths[i] = len; i += 1 }
                        }
                    }
                    try codes(Huffman(lengths[0..<nlen]), Huffman(lengths[nlen..<(nlen + ndist)]))
                default:
                    throw Ran()
                }
            }
        } catch {}
        if out.count > limit { out.removeLast(out.count - limit) }
        return out
    }
}
