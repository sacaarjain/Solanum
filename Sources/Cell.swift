import Foundation

/// Style flags for a single terminal cell.
struct CellFlags: OptionSet {
    let rawValue: UInt16
    static let bold            = CellFlags(rawValue: 1 << 0)
    static let dim             = CellFlags(rawValue: 1 << 1)
    static let italic          = CellFlags(rawValue: 1 << 2)
    static let underline       = CellFlags(rawValue: 1 << 3)
    static let blink           = CellFlags(rawValue: 1 << 4)
    static let inverse         = CellFlags(rawValue: 1 << 5)
    static let invisible       = CellFlags(rawValue: 1 << 6)
    static let strike          = CellFlags(rawValue: 1 << 7)
    static let doubleUnderline = CellFlags(rawValue: 1 << 8)
    static let curlyUnderline  = CellFlags(rawValue: 1 << 9)

    static let anyUnderline: CellFlags = [.underline, .doubleUnderline, .curlyUnderline]
}

/// Colors are packed into a UInt32: 0 = default, 0x01xxxxxx = palette index, 0x02RRGGBB = true color.
enum TermColor {
    static let `default`: UInt32 = 0
    @inline(__always) static func indexed(_ i: Int) -> UInt32 { 0x0100_0000 | UInt32(i & 0xFF) }
    @inline(__always) static func rgb(_ r: Int, _ g: Int, _ b: Int) -> UInt32 {
        0x0200_0000 | (UInt32(r & 0xFF) << 16) | (UInt32(g & 0xFF) << 8) | UInt32(b & 0xFF)
    }
}

struct Cell: Equatable {
    /// Unicode scalar value; 0 means empty.
    var ch: UInt32 = 0
    var fg: UInt32 = 0
    var bg: UInt32 = 0
    var flags: CellFlags = []
    /// 1 = normal, 2 = head of a wide char, 0 = tail of a wide char.
    var width: UInt8 = 1

    @inline(__always) var isBlank: Bool {
        (ch == 0 || ch == 32) && bg == 0 && !flags.contains(.inverse) && flags.intersection(CellFlags.anyUnderline).isEmpty
    }
}

final class Line {
    var cells: [Cell]
    var wrapped = false
    /// Combining characters attached to a base cell, keyed by column.
    var extras: [Int: String]?

    init(cols: Int, fill: Cell = Cell()) {
        cells = Array(repeating: fill, count: cols)
    }

    private init(cells: [Cell]) {
        self.cells = cells
    }

    /// A separate line with the same contents (the cells are shared until either is written).
    func copy() -> Line {
        let l = Line(cells: cells)
        l.wrapped = wrapped
        l.extras = extras
        return l
    }

    /// The cell at a column, blank past the end of a trimmed line (see `trimForScrollback`).
    @inline(__always) func cell(_ x: Int) -> Cell {
        x < cells.count ? cells[x] : Cell()
    }

    /// Drops the trailing blank cells of a line going into scrollback, where it's never written again: most lines
    /// are far shorter than the window, and a full row of cells for each adds up over thousands of lines. So a
    /// scrollback line can have fewer cells than there are columns; past its end it's blank (`cell(_:)`).
    /// Soft-wrapped lines keep every cell, since reflow joins them to the next line column for column.
    func trimForScrollback() {
        guard !wrapped else { return }
        var n = cells.count
        while n > 0 {
            let c = cells[n - 1]
            guard c.width != 0, c.ch == 0 || c.ch == 32, c.bg == 0,
                  c.flags.isDisjoint(with: [.inverse, .strike, .underline, .doubleUnderline, .curlyUnderline]) else { break }
            n -= 1
        }
        if let e = extras, let last = e.keys.max() { n = max(n, last + 1) }
        // A new array, not removeLast: that keeps the full capacity allocated.
        if n < cells.count { cells = n == 0 ? [] : Array(cells[..<n]) }
    }

    func clear(_ fill: Cell) {
        for i in cells.indices { cells[i] = fill }
        wrapped = false
        extras = nil
    }

    func resize(cols: Int) {
        if cells.count > cols {
            cells.removeLast(cells.count - cols)
            if let last = cells.last, last.width == 2 { cells[cols - 1] = Cell() }
            extras = extras?.filter { $0.key < cols }
        } else if cells.count < cols {
            cells.append(contentsOf: repeatElement(Cell(), count: cols - cells.count))
        }
    }

    var isBlank: Bool {
        if wrapped || extras != nil { return false }
        for c in cells where !c.isBlank { return false }
        return true
    }

    /// Number of cells up to and including the last non-blank cell.
    var trimmedLength: Int {
        var i = cells.count - 1
        while i >= 0 && cells[i].isBlank && cells[i].width != 0 { i -= 1 }
        return i + 1
    }

    func string(at col: Int) -> String {
        let c = cells[col]
        var s = c.ch == 0 ? " " : String(Character(Unicode.Scalar(c.ch) ?? " "))
        if let e = extras?[col] { s += e }
        return s
    }

    /// Text of the line between two columns (inclusive), optionally trimming trailing spaces.
    func text(from: Int = 0, to: Int? = nil, trim: Bool = true) -> String {
        let end = min(to ?? cells.count - 1, cells.count - 1)
        guard from <= end else { return "" }
        var scalars = String.UnicodeScalarView()
        for x in from...end {
            let c = cells[x]
            if c.width == 0 { continue }
            if c.ch == 0 { scalars.append(" ") }
            else if let s = Unicode.Scalar(c.ch) { scalars.append(s) }
            if let e = extras?[x] { scalars.append(contentsOf: e.unicodeScalars) }
        }
        var s = String(scalars)
        if trim {
            while s.last == " " { s.removeLast() }
        }
        return s
    }
}

/// Fixed-capacity ring buffer used for scrollback.
struct Ring<T> {
    private var buf: [T?]
    private var head = 0
    private(set) var count = 0
    private(set) var capacity: Int

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        buf = Array(repeating: nil, count: self.capacity)
    }

    /// Appends an element; returns true if the oldest element was evicted.
    @discardableResult
    mutating func append(_ x: T) -> Bool {
        if count < capacity {
            buf[(head + count) % capacity] = x
            count += 1
            return false
        }
        buf[head] = x
        head = (head + 1) % capacity
        return true
    }

    subscript(i: Int) -> T {
        buf[(head + i) % capacity]!
    }

    mutating func removeAll() {
        buf = Array(repeating: nil, count: capacity)
        head = 0
        count = 0
    }

    func toArray() -> [T] {
        (0..<count).map { self[$0] }
    }

    /// Replaces contents (keeping only the newest `capacity` items). Returns number of items discarded.
    @discardableResult
    mutating func reset(with items: [T], capacity newCap: Int? = nil) -> Int {
        if let c = newCap { capacity = max(1, c) }
        let excess = max(0, items.count - capacity)
        buf = Array(repeating: nil, count: capacity)
        head = 0
        count = 0
        for x in items[excess...] { append(x) }
        return excess
    }
}

/// Display width of a Unicode scalar in terminal cells (0, 1 or 2).
enum CharWidth {
    private static var cache: [UInt32: Int8] = [:]

    @inline(__always) static func of(_ v: UInt32) -> Int {
        if v < 0x7F { return 1 }
        if v < 0xA0 { return 0 }
        if v < 0x300 { return 1 }
        if let c = cache[v] { return Int(c) }
        let w = compute(v)
        cache[v] = Int8(w)
        return w
    }

    private static func compute(_ v: UInt32) -> Int {
        guard let s = Unicode.Scalar(v) else { return 1 }
        if v == 0x200D || (0xFE00...0xFE0F).contains(v) || (0x200B...0x200F).contains(v) || (0xE0100...0xE01EF).contains(v) {
            return 0
        }
        switch s.properties.generalCategory {
        case .nonspacingMark, .enclosingMark: return 0
        default: break
        }
        if s.properties.isEmojiPresentation { return 2 }
        for r in wideRanges where r.contains(v) { return 2 }
        return 1
    }

    private static let wideRanges: [ClosedRange<UInt32>] = [
        0x1100...0x115F, 0x231A...0x231B, 0x2329...0x232A, 0x2E80...0x303E, 0x3041...0x33FF,
        0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF, 0xA960...0xA97F, 0xAC00...0xD7A3,
        0xF900...0xFAFF, 0xFE10...0xFE19, 0xFE30...0xFE6F, 0xFF00...0xFF60, 0xFFE0...0xFFE6,
        0x1F300...0x1F64F, 0x1F900...0x1F9FF, 0x20000...0x2FFFD, 0x30000...0x3FFFD,
    ]
}
