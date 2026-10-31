import Foundation

enum Charset { case ascii, decSpecial }

enum MouseMode: Int { case none = 0, x10 = 9, normal = 1000, button = 1002, any = 1003 }

struct SavedCursor {
    var x = 0, y = 0
    var attr = Cell()
    var pendingWrap = false
    var originMode = false
    var g0: Charset = .ascii, g1: Charset = .ascii, gl = 0
}

/// A command block: prompt + command + output, delimited by OSC 133 shell-integration marks.
final class Block {
    enum State { case prompt, running, finished }
    let id: Int
    var state: State = .prompt
    var promptLine: Int
    var commandLine: Int?
    var commandCol = 0
    var outputLine: Int?
    var endLine: Int?
    var command = ""
    var exitCode: Int?
    var startTime: Date?
    var endTime: Date?
    var collapsed = false

    init(id: Int, promptLine: Int) {
        self.id = id
        self.promptLine = promptLine
    }

    var failed: Bool { state == .finished && (exitCode ?? 0) != 0 }

    /// True when the command launched an AI agent session (Claude Code), whose run time isn't meaningful.
    var isAgentSession: Bool {
        command.split(separator: " ").contains { ($0 as NSString).lastPathComponent == "claude" }
    }

    var duration: TimeInterval? {
        guard let s = startTime else { return nil }
        return (endTime ?? Date()).timeIntervalSince(s)
    }

    var hasOutput: Bool {
        guard let o = outputLine, let e = endLine else { return false }
        return e >= o
    }

    func lastLine(cursorAbs: Int) -> Int {
        switch state {
        case .prompt: return max(promptLine, cursorAbs)
        case .running: return max(promptLine, cursorAbs, (outputLine ?? promptLine + 1) - 1)
        case .finished: return max(promptLine, endLine ?? promptLine, (outputLine ?? promptLine + 1) - 1)
        }
    }

    func remap(_ f: (Int) -> Int) {
        promptLine = f(promptLine)
        commandLine = commandLine.map(f)
        outputLine = outputLine.map(f)
        endLine = endLine.map(f)
    }
}

protocol TerminalDelegate: AnyObject {
    func terminalSend(_ bytes: [UInt8])
    func terminalTitleChanged(_ t: Terminal)
    func terminalCwdChanged(_ t: Terminal)
    func terminalBell(_ t: Terminal)
    func terminalBlockFinished(_ t: Terminal, block: Block)
    func terminalClipboardWrite(_ t: Terminal, text: String)
    func terminalScreenSwitched(_ t: Terminal)
    func terminalSyncEnded(_ t: Terminal)
    /// Returns RGB for 10 (fg), 11 (bg), 12 (cursor) or 256+i for palette index i.
    func terminalColor(_ t: Terminal, code: Int) -> (UInt8, UInt8, UInt8)
    func terminalPixelSize(_ t: Terminal) -> (width: Int, height: Int)
    /// The shell integration's `settings` command.
    func terminalOpenSettings(_ t: Terminal)
    /// The ssh session ended with `status` (announced by the ssh wrapper before it clears `sshControlPath`).
    func terminalSSHExited(_ t: Terminal, status: Int)
}

extension TerminalDelegate {
    func terminalOpenSettings(_ t: Terminal) {}
    func terminalSSHExited(_ t: Terminal, status: Int) {}
}

final class Terminal {
    private(set) var cols: Int
    private(set) var rows: Int
    var screen: [Line]
    private(set) var primaryScreen: [Line] = []
    private(set) var usingAlt = false
    private(set) var scrollback: Ring<Line>
    /// Number of lines ever evicted from scrollback; makes absolute line numbers stable.
    private(set) var dropped = 0
    /// Lines pushed into scrollback since the view last checked (for scroll anchoring).
    var scrollbackPushes = 0

    var cursorX = 0, cursorY = 0
    var pendingWrap = false
    var attr = Cell()
    private(set) var scrollTop = 0, scrollBottom: Int
    private var tabStops: [Bool]

    // Modes
    private(set) var appCursorKeys = false
    private(set) var appKeypad = false
    private var autowrap = true
    private var originMode = false
    private var insertMode = false
    private var newlineMode = false
    private(set) var reverseVideo = false
    private(set) var cursorVisible = true
    private(set) var bracketedPaste = false
    private(set) var focusEvents = false
    private(set) var mouseMode: MouseMode = .none
    private(set) var mouseSGR = false
    private(set) var altScroll = true
    private(set) var syncOutput = false
    /// DECSCUSR value (nil = use user preference).
    private(set) var cursorShape: Int?

    private var g0: Charset = .ascii, g1: Charset = .ascii, gl = 0
    private var savedCursors = [SavedCursor(), SavedCursor()]
    private var lastPrinted: UInt32 = 0
    /// The OSC 8 link being printed, if any: cells written now link to it.
    private var hyperlink: String?

    var title: String?
    var cwd: String?
    /// Control socket of an ssh session running in this terminal (announced by the shell integration's ssh wrapper).
    var sshControlPath: String?
    /// The arguments that ssh session was started with (shell-quoted), to open another like it.
    var sshArgs: String?
    /// Folder reported by the remote shell over OSC 7 while an ssh session is running.
    var remoteCwd: String?

    private(set) var blocks: [Block] = []
    private(set) var currentBlock: Block?
    private var nextBlockId = 1

    weak var delegate: TerminalDelegate?

    // Parser state
    private enum PState { case ground, escape, escInter, csiEntry, csiParam, csiInter, csiIgnore, osc, oscEsc, str, strEsc }
    private var pstate: PState = .ground
    private var params = [Int](repeating: 0, count: 32)
    private var paramSub = [Bool](repeating: false, count: 32)
    private var paramCount = 0
    private var curParam = 0
    private var curIsSub = false
    private var prefix: UInt8 = 0
    private var inter: UInt8 = 0
    private var oscBuf: [UInt8] = []
    private var utf8Need = 0
    private var utf8Acc: UInt32 = 0

    init(cols: Int, rows: Int, scrollbackLimit: Int) {
        self.cols = max(2, cols)
        self.rows = max(1, rows)
        scrollback = Ring(capacity: max(100, scrollbackLimit))
        let c = self.cols
        screen = (0..<self.rows).map { _ in Line(cols: c) }
        scrollBottom = self.rows - 1
        tabStops = Terminal.defaultTabs(self.cols)
    }

    private static func defaultTabs(_ n: Int) -> [Bool] { (0..<n).map { $0 % 8 == 0 && $0 != 0 } }

    // MARK: - Absolute line addressing

    var firstAbs: Int { usingAlt ? 0 : dropped }
    var screenTopAbs: Int { usingAlt ? 0 : dropped + scrollback.count }
    var lastAbs: Int { screenTopAbs + rows - 1 }
    var cursorAbs: Int { screenTopAbs + cursorY }

    func line(abs: Int) -> Line? {
        if usingAlt { return abs >= 0 && abs < rows ? screen[abs] : nil }
        let i = abs - dropped
        if i < 0 { return nil }
        if i < scrollback.count { return scrollback[i] }
        let r = i - scrollback.count
        return r < rows ? screen[r] : nil
    }

    func setScrollbackLimit(_ n: Int) {
        let n = max(100, n)
        guard n != scrollback.capacity else { return }
        dropped += scrollback.reset(with: scrollback.toArray(), capacity: n)
        pruneBlocks()
    }

    // MARK: - Feeding bytes

    func feed(_ buf: UnsafeBufferPointer<UInt8>) {
        var i = 0
        let n = buf.count
        while i < n {
            let b = buf[i]
            i += 1
            switch pstate {
            case .ground:
                if utf8Need > 0 {
                    if b & 0xC0 == 0x80 {
                        utf8Acc = (utf8Acc << 6) | UInt32(b & 0x3F)
                        utf8Need -= 1
                        if utf8Need == 0 { printScalar(utf8Acc) }
                        continue
                    }
                    utf8Need = 0
                    printScalar(0xFFFD)
                }
                if b >= 0x20 && b < 0x7F {
                    printScalar(UInt32(b))
                } else if b < 0x20 {
                    if b == 0x1B { pstate = .escape; inter = 0 } else { execute(b) }
                } else if b == 0x7F {
                    // DEL: ignored
                } else if b >= 0xC2 && b <= 0xDF {
                    utf8Need = 1; utf8Acc = UInt32(b & 0x1F)
                } else if b >= 0xE0 && b <= 0xEF {
                    utf8Need = 2; utf8Acc = UInt32(b & 0x0F)
                } else if b >= 0xF0 && b <= 0xF4 {
                    utf8Need = 3; utf8Acc = UInt32(b & 0x07)
                } else {
                    printScalar(0xFFFD)
                }

            case .escape:
                switch b {
                case 0x1B: inter = 0
                case 0x18, 0x1A: pstate = .ground
                case 0x00...0x1F: execute(b)
                case 0x20...0x2F: inter = b; pstate = .escInter
                case 0x5B: resetCSI(); pstate = .csiEntry
                case 0x5D: oscBuf.removeAll(keepingCapacity: true); pstate = .osc
                case 0x50, 0x58, 0x5E, 0x5F: pstate = .str
                case 0x30...0x7E: pstate = .ground; escDispatch(b)
                default: pstate = .ground
                }

            case .escInter:
                switch b {
                case 0x1B: pstate = .escape; inter = 0
                case 0x18, 0x1A: pstate = .ground
                case 0x00...0x1F: execute(b)
                case 0x20...0x2F: inter = b
                case 0x30...0x7E: pstate = .ground; escDispatch(b)
                default: pstate = .ground
                }

            case .csiEntry, .csiParam:
                switch b {
                case 0x30...0x39:
                    curParam = min(curParam * 10 + Int(b - 0x30), 99_999)
                    pstate = .csiParam
                case 0x3B:
                    pushParam(); curIsSub = false; pstate = .csiParam
                case 0x3A:
                    pushParam(); curIsSub = true; pstate = .csiParam
                case 0x3C...0x3F:
                    if pstate == .csiEntry { prefix = b; pstate = .csiParam } else { pstate = .csiIgnore }
                case 0x20...0x2F:
                    inter = b; pstate = .csiInter
                case 0x40...0x7E:
                    pushParam(); pstate = .ground; csiDispatch(b)
                case 0x1B: pstate = .escape; inter = 0
                case 0x18, 0x1A: pstate = .ground
                case 0x00...0x1F: execute(b)
                default: pstate = .csiIgnore
                }

            case .csiInter:
                switch b {
                case 0x20...0x2F: inter = b
                case 0x30...0x3F: pstate = .csiIgnore
                case 0x40...0x7E: pushParam(); pstate = .ground; csiDispatch(b)
                case 0x1B: pstate = .escape; inter = 0
                case 0x18, 0x1A: pstate = .ground
                case 0x00...0x1F: execute(b)
                default: pstate = .csiIgnore
                }

            case .csiIgnore:
                switch b {
                case 0x40...0x7E: pstate = .ground
                case 0x1B: pstate = .escape; inter = 0
                case 0x18, 0x1A: pstate = .ground
                case 0x00...0x1F: execute(b)
                default: break
                }

            case .osc:
                switch b {
                case 0x07: pstate = .ground; handleOSC()
                case 0x1B: pstate = .oscEsc
                case 0x18, 0x1A: pstate = .ground
                case 0x00...0x1F: break
                default: if oscBuf.count < 4_000_000 { oscBuf.append(b) }
                }

            case .oscEsc:
                handleOSC()
                if b == 0x5C { pstate = .ground } else { pstate = .escape; inter = 0; i -= 1 }

            case .str:
                switch b {
                case 0x1B: pstate = .strEsc
                case 0x18, 0x1A: pstate = .ground
                default: break
                }

            case .strEsc:
                if b == 0x5C { pstate = .ground } else { pstate = .escape; inter = 0; i -= 1 }
            }
        }
    }

    private func resetCSI() {
        paramCount = 0; curParam = 0; curIsSub = false; prefix = 0; inter = 0
    }

    private func pushParam() {
        if paramCount < params.count {
            params[paramCount] = curParam
            paramSub[paramCount] = curIsSub
            paramCount += 1
        }
        curParam = 0
    }

    @inline(__always) private func p(_ i: Int, _ d: Int) -> Int {
        i < paramCount && params[i] != 0 ? params[i] : d
    }

    @inline(__always) private var p0: Int { paramCount > 0 ? params[0] : 0 }

    private func send(_ s: String) { delegate?.terminalSend(Array(s.utf8)) }

    // MARK: - Printing

    private static let decSpecial: [UInt32] = [
        0x0020, 0x25C6, 0x2592, 0x2409, 0x240C, 0x240D, 0x240A, 0x00B0, 0x00B1, 0x2424, 0x240B, 0x2518,
        0x2510, 0x250C, 0x2514, 0x253C, 0x23BA, 0x23BB, 0x2500, 0x23BC, 0x23BD, 0x251C, 0x2524, 0x2534,
        0x252C, 0x2502, 0x2264, 0x2265, 0x03C0, 0x2260, 0x00A3, 0x00B7,
    ]

    private func printScalar(_ input: UInt32) {
        var v = input
        let cs = gl == 0 ? g0 : g1
        if cs == .decSpecial, v >= 0x5F, v <= 0x7E { v = Terminal.decSpecial[Int(v - 0x5F)] }
        let w = v < 0x7F ? 1 : CharWidth.of(v)
        if w == 0 { addCombining(v); return }

        if pendingWrap {
            if autowrap {
                screen[cursorY].wrapped = true
                cursorX = 0
                index()
            }
            pendingWrap = false
        }
        if w == 2 && cursorX >= cols - 1 {
            if autowrap {
                let l = screen[cursorY]
                l.cells[cols - 1] = blankCell()
                l.wrapped = true
                cursorX = 0
                index()
            } else {
                cursorX = cols - 2
            }
        }
        let line = screen[cursorY]
        if insertMode { insertBlanks(line, at: cursorX, count: w) }
        clearWide(line, cursorX, w)
        line.cells[cursorX] = Cell(ch: v, fg: attr.fg, bg: attr.bg, flags: attr.flags, width: UInt8(w))
        if line.extras != nil {
            line.extras![cursorX] = nil
            if line.extras!.isEmpty { line.extras = nil }
        }
        if w == 2 {
            line.cells[cursorX + 1] = Cell(ch: 0, fg: attr.fg, bg: attr.bg, flags: attr.flags, width: 0)
        }
        if let h = hyperlink {
            if line.links == nil { line.links = [:] }
            for x in cursorX..<(cursorX + w) { line.links![x] = h }
        } else if line.links != nil {
            for x in cursorX..<(cursorX + w) { line.links![x] = nil }
            if line.links!.isEmpty { line.links = nil }
        }
        lastPrinted = v
        if cursorX + w >= cols {
            cursorX = cols - 1
            pendingWrap = true
        } else {
            cursorX += w
        }
    }

    private func clearWide(_ line: Line, _ x: Int, _ w: Int) {
        if line.cells[x].width == 0 && x > 0 {
            line.cells[x - 1].ch = 0
            line.cells[x - 1].width = 1
        }
        let end = x + w - 1
        if end < cols - 1 && line.cells[end].width == 2 {
            line.cells[end + 1].ch = 0
            line.cells[end + 1].width = 1
        }
    }

    private func addCombining(_ v: UInt32) {
        var x = pendingWrap ? cursorX : cursorX - 1
        guard x >= 0, let s = Unicode.Scalar(v) else { return }
        let line = screen[cursorY]
        if line.cells[x].width == 0 && x > 0 { x -= 1 }
        guard line.cells[x].ch != 0 else { return }
        var e = line.extras ?? [:]
        e[x, default: ""].unicodeScalars.append(s)
        line.extras = e
    }

    @inline(__always) private func blankCell() -> Cell {
        var c = Cell()
        c.bg = attr.bg
        return c
    }

    // MARK: - Control characters

    private func execute(_ b: UInt8) {
        switch b {
        case 0x07: delegate?.terminalBell(self)
        case 0x08:
            pendingWrap = false
            if cursorX > 0 { cursorX -= 1 }
        case 0x09: tab(1)
        case 0x0A, 0x0B, 0x0C:
            index()
            if newlineMode { cursorX = 0 }
            pendingWrap = false
        case 0x0D:
            cursorX = 0
            pendingWrap = false
        case 0x0E: gl = 1
        case 0x0F: gl = 0
        default: break
        }
    }

    private func index() {
        if cursorY == scrollBottom {
            scrollUp(1)
        } else if cursorY < rows - 1 {
            cursorY += 1
        }
    }

    private func reverseIndex() {
        if cursorY == scrollTop {
            scrollDown(1)
        } else if cursorY > 0 {
            cursorY -= 1
        }
        pendingWrap = false
    }

    private func tab(_ n: Int) {
        for _ in 0..<max(1, n) {
            var x = cursorX + 1
            while x < cols - 1 && !tabStops[x] { x += 1 }
            cursorX = min(x, cols - 1)
        }
        pendingWrap = false
    }

    private func backTab(_ n: Int) {
        for _ in 0..<max(1, n) {
            var x = cursorX - 1
            while x > 0 && !tabStops[x] { x -= 1 }
            cursorX = max(x, 0)
        }
        pendingWrap = false
    }

    // MARK: - Scrolling & editing

    func scrollUp(_ n: Int) {
        let count = min(n, scrollBottom - scrollTop + 1)
        guard count > 0 else { return }
        for _ in 0..<count {
            let removed = screen.remove(at: scrollTop)
            if scrollTop == 0 && !usingAlt {
                removed.trimForScrollback()
                if scrollback.append(removed) { dropped += 1 }
                scrollbackPushes += 1
            }
            screen.insert(Line(cols: cols, fill: blankCell()), at: scrollBottom)
        }
    }

    private func scrollDown(_ n: Int) {
        let count = min(n, scrollBottom - scrollTop + 1)
        guard count > 0 else { return }
        for _ in 0..<count {
            screen.remove(at: scrollBottom)
            screen.insert(Line(cols: cols, fill: blankCell()), at: scrollTop)
        }
    }

    private func insertBlanks(_ line: Line, at x: Int, count: Int) {
        let n = min(max(count, 1), cols - x)
        guard n > 0 else { return }
        line.cells.insert(contentsOf: repeatElement(blankCell(), count: n), at: x)
        line.cells.removeLast(n)
        line.extras = nil
        line.links = nil
    }

    private func deleteChars(_ count: Int) {
        let line = screen[cursorY]
        let n = min(max(count, 1), cols - cursorX)
        guard n > 0 else { return }
        line.cells.removeSubrange(cursorX..<(cursorX + n))
        line.cells.append(contentsOf: repeatElement(blankCell(), count: n))
        line.extras = nil
        line.links = nil
        pendingWrap = false
    }

    private func eraseChars(_ count: Int) {
        let line = screen[cursorY]
        let end = min(cursorX + max(count, 1), cols)
        let b = blankCell()
        for x in cursorX..<end {
            line.cells[x] = b
            line.extras?[x] = nil
            line.links?[x] = nil
        }
        pendingWrap = false
    }

    private func insertLines(_ n: Int) {
        guard cursorY >= scrollTop && cursorY <= scrollBottom else { return }
        let n = min(max(n, 1), scrollBottom - cursorY + 1)
        for _ in 0..<n {
            screen.remove(at: scrollBottom)
            screen.insert(Line(cols: cols, fill: blankCell()), at: cursorY)
        }
        cursorX = 0
        pendingWrap = false
    }

    private func deleteLines(_ n: Int) {
        guard cursorY >= scrollTop && cursorY <= scrollBottom else { return }
        let n = min(max(n, 1), scrollBottom - cursorY + 1)
        for _ in 0..<n {
            screen.remove(at: cursorY)
            screen.insert(Line(cols: cols, fill: blankCell()), at: scrollBottom)
        }
        cursorX = 0
        pendingWrap = false
    }

    private func eraseInLine(_ mode: Int) {
        let line = screen[cursorY]
        let b = blankCell()
        switch mode {
        case 0:
            if line.cells[cursorX].width == 0 && cursorX > 0 { line.cells[cursorX - 1] = b }
            for x in cursorX..<cols { line.cells[x] = b; line.extras?[x] = nil; line.links?[x] = nil }
            line.wrapped = false
        case 1:
            let end = min(cursorX, cols - 1)
            if end + 1 < cols && line.cells[end].width == 2 { line.cells[end + 1] = b }
            for x in 0...end { line.cells[x] = b; line.extras?[x] = nil; line.links?[x] = nil }
        case 2:
            line.clear(b)
        default: break
        }
        pendingWrap = false
    }

    private func eraseInDisplay(_ mode: Int) {
        let b = blankCell()
        switch mode {
        case 0:
            eraseInLine(0)
            if cursorY + 1 < rows { for y in (cursorY + 1)..<rows { screen[y].clear(b) } }
        case 1:
            for y in 0..<cursorY { screen[y].clear(b) }
            eraseInLine(1)
        case 2:
            for y in 0..<rows { screen[y].clear(b) }
            if !usingAlt { removeBlocks(onOrAfter: screenTopAbs) }
        case 3:
            if !usingAlt {
                dropped += scrollback.count
                scrollback.removeAll()
                pruneBlocks()
            }
        default: break
        }
    }

    // MARK: - Cursor

    private func setCursor(x: Int, y: Int) {
        var yy = y
        if originMode {
            yy = min(max(yy + scrollTop, scrollTop), scrollBottom)
        } else {
            yy = min(max(yy, 0), rows - 1)
        }
        cursorX = min(max(x, 0), cols - 1)
        cursorY = yy
        pendingWrap = false
    }

    private func cursorUp(_ n: Int) {
        let limit = cursorY >= scrollTop ? scrollTop : 0
        cursorY = max(cursorY - n, limit)
        pendingWrap = false
    }

    private func cursorDown(_ n: Int) {
        let limit = cursorY <= scrollBottom ? scrollBottom : rows - 1
        cursorY = min(cursorY + n, limit)
        pendingWrap = false
    }

    private func saveCursor() {
        savedCursors[usingAlt ? 1 : 0] = SavedCursor(x: cursorX, y: cursorY, attr: attr, pendingWrap: pendingWrap,
                                                      originMode: originMode, g0: g0, g1: g1, gl: gl)
    }

    private func restoreCursor() {
        let s = savedCursors[usingAlt ? 1 : 0]
        cursorX = min(s.x, cols - 1)
        cursorY = min(s.y, rows - 1)
        attr = s.attr
        pendingWrap = s.pendingWrap
        originMode = s.originMode
        g0 = s.g0; g1 = s.g1; gl = s.gl
    }

    // MARK: - Escape dispatch

    private func escDispatch(_ f: UInt8) {
        switch inter {
        case 0:
            switch f {
            case 0x37: saveCursor()                       // 7
            case 0x38: restoreCursor()                    // 8
            case 0x44: index(); pendingWrap = false       // D
            case 0x45: index(); cursorX = 0; pendingWrap = false // E
            case 0x48: if cursorX < cols { tabStops[cursorX] = true } // H
            case 0x4D: reverseIndex()                     // M
            case 0x63: fullReset()                        // c
            case 0x3D: appKeypad = true                   // =
            case 0x3E: appKeypad = false                  // >
            default: break
            }
        case 0x28: g0 = f == 0x30 ? .decSpecial : .ascii  // ( designate G0
        case 0x29: g1 = f == 0x30 ? .decSpecial : .ascii  // ) designate G1
        case 0x23:
            if f == 0x38 { // DECALN
                for l in screen { for x in 0..<cols { l.cells[x] = Cell(ch: 0x45) } }
            }
        default: break
        }
        inter = 0
    }

    private func csiDispatch(_ f: UInt8) {
        if prefix == 0 && inter == 0 {
            switch f {
            case 0x40: insertBlanks(screen[cursorY], at: cursorX, count: p(0, 1))           // @
            case 0x41: cursorUp(p(0, 1))                                                     // A
            case 0x42, 0x65: cursorDown(p(0, 1))                                             // B e
            case 0x43, 0x61: cursorX = min(cursorX + p(0, 1), cols - 1); pendingWrap = false // C a
            case 0x44: cursorX = max(cursorX - p(0, 1), 0); pendingWrap = false              // D
            case 0x45: cursorDown(p(0, 1)); cursorX = 0                                      // E
            case 0x46: cursorUp(p(0, 1)); cursorX = 0                                        // F
            case 0x47, 0x60: cursorX = min(p(0, 1) - 1, cols - 1); pendingWrap = false       // G `
            case 0x48, 0x66: setCursor(x: p(1, 1) - 1, y: p(0, 1) - 1)                       // H f
            case 0x49: tab(p(0, 1))                                                          // I
            case 0x4A: eraseInDisplay(p0)                                                    // J
            case 0x4B: eraseInLine(p0)                                                       // K
            case 0x4C: insertLines(p(0, 1))                                                  // L
            case 0x4D: deleteLines(p(0, 1))                                                  // M
            case 0x50: deleteChars(p(0, 1))                                                  // P
            case 0x53: scrollUp(p(0, 1))                                                     // S
            case 0x54: if paramCount <= 1 { scrollDown(p(0, 1)) }                            // T
            case 0x58: eraseChars(p(0, 1))                                                   // X
            case 0x5A: backTab(p(0, 1))                                                      // Z
            case 0x62: if lastPrinted != 0 { for _ in 0..<min(p(0, 1), 65535) { printScalar(lastPrinted) } } // b
            case 0x63: if p0 == 0 { send("\u{1b}[?62;22c") }                                 // c
            case 0x64: setCursor(x: cursorX, y: p(0, 1) - 1)                                 // d
            case 0x67:                                                                       // g
                if p0 == 0 { if cursorX < cols { tabStops[cursorX] = false } }
                else if p0 == 3 { tabStops = Array(repeating: false, count: cols) }
            case 0x68: for k in 0..<paramCount { setANSIMode(params[k], true) }              // h
            case 0x6C: for k in 0..<paramCount { setANSIMode(params[k], false) }             // l
            case 0x6D: sgr()                                                                 // m
            case 0x6E:                                                                       // n
                if p0 == 5 { send("\u{1b}[0n") }
                else if p0 == 6 {
                    let y = originMode ? cursorY - scrollTop : cursorY
                    send("\u{1b}[\(y + 1);\(cursorX + 1)R")
                }
            case 0x72:                                                                       // r
                let top = p(0, 1) - 1
                let bottom = min(p(1, rows), rows) - 1
                if top < bottom {
                    scrollTop = top
                    scrollBottom = bottom
                    setCursor(x: 0, y: 0)
                }
            case 0x73: saveCursor()                                                          // s
            case 0x74: windowOps()                                                           // t
            case 0x75: restoreCursor()                                                       // u
            default: break
            }
        } else if prefix == 0x3F && inter == 0 { // ?
            switch f {
            case 0x68: for k in 0..<paramCount { setPrivateMode(params[k], true) }
            case 0x6C: for k in 0..<paramCount { setPrivateMode(params[k], false) }
            case 0x4A: eraseInDisplay(p0)
            case 0x4B: eraseInLine(p0)
            case 0x6E:
                if p0 == 6 { send("\u{1b}[?\(cursorY + 1);\(cursorX + 1)R") }
            default: break
            }
        } else if prefix == 0x3E { // >
            if f == 0x63 { send("\u{1b}[>1;10;0c") }
            else if f == 0x71 { send("\u{1b}P>|Solanum 0.1\u{1b}\\") }
        } else if inter == 0x20 && f == 0x71 { // SP q  DECSCUSR
            cursorShape = p0 == 0 ? nil : p0
        } else if inter == 0x21 && f == 0x70 { // ! p  DECSTR
            softReset()
        } else if inter == 0x24 && f == 0x70 { // $ p  DECRQM
            let m = p0
            let state: Int
            if prefix == 0x3F {
                if let v = privateModeValue(m) { state = v ? 1 : 2 } else { state = 0 }
                send("\u{1b}[?\(m);\(state)$y")
            } else {
                switch m {
                case 4: state = insertMode ? 1 : 2
                case 20: state = newlineMode ? 1 : 2
                default: state = 0
                }
                send("\u{1b}[\(m);\(state)$y")
            }
        }
    }

    private func windowOps() {
        switch p0 {
        case 14:
            if let s = delegate?.terminalPixelSize(self) { send("\u{1b}[4;\(s.height);\(s.width)t") }
        case 16:
            if let s = delegate?.terminalPixelSize(self) {
                send("\u{1b}[6;\(s.height / max(rows, 1));\(s.width / max(cols, 1))t")
            }
        case 18: send("\u{1b}[8;\(rows);\(cols)t")
        default: break
        }
    }

    private func setANSIMode(_ m: Int, _ on: Bool) {
        switch m {
        case 4: insertMode = on
        case 20: newlineMode = on
        default: break
        }
    }

    private func privateModeValue(_ m: Int) -> Bool? {
        switch m {
        case 1: return appCursorKeys
        case 5: return reverseVideo
        case 6: return originMode
        case 7: return autowrap
        case 25: return cursorVisible
        case 47, 1047, 1049: return usingAlt
        case 1000: return mouseMode == .normal
        case 1002: return mouseMode == .button
        case 1003: return mouseMode == .any
        case 1004: return focusEvents
        case 1006: return mouseSGR
        case 1007: return altScroll
        case 2004: return bracketedPaste
        case 2026: return syncOutput
        default: return nil
        }
    }

    private func setPrivateMode(_ m: Int, _ on: Bool) {
        switch m {
        case 1: appCursorKeys = on
        case 5: reverseVideo = on
        case 6: originMode = on; setCursor(x: 0, y: 0)
        case 7: autowrap = on
        case 9: mouseMode = on ? .x10 : .none
        case 25: cursorVisible = on
        case 47, 1047:
            if on { enterAlt() } else { exitAlt() }
        case 1048:
            if on { saveCursor() } else { restoreCursor() }
        case 1049:
            if on { saveCursor(); enterAlt() } else { exitAlt(); restoreCursor() }
        case 1000: mouseMode = on ? .normal : .none
        case 1002: mouseMode = on ? .button : .none
        case 1003: mouseMode = on ? .any : .none
        case 1004: focusEvents = on
        case 1006: mouseSGR = on
        case 1007: altScroll = on
        case 2004: bracketedPaste = on
        case 2026:
            syncOutput = on
            if !on { delegate?.terminalSyncEnded(self) }
        default: break
        }
    }

    private func enterAlt() {
        guard !usingAlt else {
            for l in screen { l.clear(Cell()) }
            return
        }
        primaryScreen = screen
        let c = cols
        screen = (0..<rows).map { _ in Line(cols: c) }
        usingAlt = true
        delegate?.terminalScreenSwitched(self)
    }

    private func exitAlt() {
        guard usingAlt else { return }
        screen = primaryScreen
        primaryScreen = []
        usingAlt = false
        delegate?.terminalScreenSwitched(self)
    }

    private func softReset() {
        cursorVisible = true
        originMode = false
        autowrap = true
        insertMode = false
        appCursorKeys = false
        appKeypad = false
        scrollTop = 0
        scrollBottom = rows - 1
        attr = Cell()
        g0 = .ascii; g1 = .ascii; gl = 0
        pendingWrap = false
        savedCursors = [SavedCursor(), SavedCursor()]
    }

    private func fullReset() {
        exitAlt()
        softReset()
        newlineMode = false
        reverseVideo = false
        bracketedPaste = false
        focusEvents = false
        mouseMode = .none
        mouseSGR = false
        syncOutput = false
        cursorShape = nil
        for l in screen { l.clear(Cell()) }
        cursorX = 0
        cursorY = 0
        tabStops = Terminal.defaultTabs(cols)
        title = nil
        hyperlink = nil
        delegate?.terminalTitleChanged(self)
    }

    // MARK: - SGR

    private func sgr() {
        var i = 0
        if paramCount == 0 { attr = Cell(); return }
        while i < paramCount {
            let v = params[i]
            switch v {
            case 0: attr.fg = 0; attr.bg = 0; attr.flags = []
            case 1: attr.flags.insert(.bold)
            case 2: attr.flags.insert(.dim)
            case 3: attr.flags.insert(.italic)
            case 4:
                attr.flags.subtract(CellFlags.anyUnderline)
                if i + 1 < paramCount && paramSub[i + 1] {
                    switch params[i + 1] {
                    case 0: break
                    case 2: attr.flags.insert(.doubleUnderline)
                    case 3: attr.flags.insert(.curlyUnderline)
                    default: attr.flags.insert(.underline)
                    }
                    i += 1
                } else {
                    attr.flags.insert(.underline)
                }
            case 5, 6: attr.flags.insert(.blink)
            case 7: attr.flags.insert(.inverse)
            case 8: attr.flags.insert(.invisible)
            case 9: attr.flags.insert(.strike)
            case 21: attr.flags.subtract(CellFlags.anyUnderline); attr.flags.insert(.doubleUnderline)
            case 22: attr.flags.subtract([.bold, .dim])
            case 23: attr.flags.remove(.italic)
            case 24: attr.flags.subtract(CellFlags.anyUnderline)
            case 25: attr.flags.remove(.blink)
            case 27: attr.flags.remove(.inverse)
            case 28: attr.flags.remove(.invisible)
            case 29: attr.flags.remove(.strike)
            case 30...37: attr.fg = TermColor.indexed(v - 30)
            case 38:
                let (c, used) = extendedColor(at: i)
                if let c { attr.fg = c }
                i += used
            case 39: attr.fg = 0
            case 40...47: attr.bg = TermColor.indexed(v - 40)
            case 48:
                let (c, used) = extendedColor(at: i)
                if let c { attr.bg = c }
                i += used
            case 49: attr.bg = 0
            case 58:
                let (_, used) = extendedColor(at: i)
                i += used
            case 90...97: attr.fg = TermColor.indexed(v - 90 + 8)
            case 100...107: attr.bg = TermColor.indexed(v - 100 + 8)
            default: break
            }
            // Skip any stray sub-parameters we did not consume.
            i += 1
            while i < paramCount && paramSub[i] { i += 1 }
        }
    }

    /// Parses 38/48/58 extended colors. Returns the color and the number of extra params consumed.
    private func extendedColor(at i: Int) -> (UInt32?, Int) {
        if i + 1 < paramCount && paramSub[i + 1] {
            var j = i + 1
            var subs: [Int] = []
            while j < paramCount && paramSub[j] { subs.append(params[j]); j += 1 }
            let used = j - i - 1
            if subs.first == 5, subs.count >= 2 { return (TermColor.indexed(subs[1]), used) }
            if subs.first == 2 {
                if subs.count >= 5 { return (TermColor.rgb(subs[subs.count - 3], subs[subs.count - 2], subs[subs.count - 1]), used) }
                if subs.count == 4 { return (TermColor.rgb(subs[1], subs[2], subs[3]), used) }
            }
            return (nil, used)
        }
        guard i + 1 < paramCount else { return (nil, 0) }
        if params[i + 1] == 5, i + 2 < paramCount { return (TermColor.indexed(params[i + 2]), 2) }
        if params[i + 1] == 2, i + 4 < paramCount { return (TermColor.rgb(params[i + 2], params[i + 3], params[i + 4]), 4) }
        return (nil, 1)
    }

    // MARK: - OSC

    private func handleOSC() {
        guard let s = String(bytes: oscBuf, encoding: .utf8) ?? String(bytes: oscBuf, encoding: .isoLatin1) else { return }
        let parts = s.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = parts.first, let code = Int(first) else { return }
        let rest = parts.count > 1 ? String(parts[1]) : ""
        switch code {
        case 0, 2:
            title = rest.isEmpty ? nil : rest
            delegate?.terminalTitleChanged(self)
        case 7:
            if let path = Terminal.pathFromFileURL(rest) {
                if sshControlPath != nil { remoteCwd = path } else { cwd = path }
                delegate?.terminalCwdChanged(self)
            }
        case 4:
            let items = rest.split(separator: ";").map(String.init)
            var k = 0
            while k + 1 < items.count {
                if items[k + 1] == "?", let idx = Int(items[k]), let c = delegate?.terminalColor(self, code: 256 + idx) {
                    send("\u{1b}]4;\(idx);\(Terminal.rgbSpec(c))\u{1b}\\")
                }
                k += 2
            }
        case 10, 11, 12:
            if rest == "?", let c = delegate?.terminalColor(self, code: code) {
                send("\u{1b}]\(code);\(Terminal.rgbSpec(c))\u{1b}\\")
            }
        case 8:
            // OSC 8 ; params ; URI starts a link (params, such as id=, aren't needed); an empty URI ends it.
            let sub = rest.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            let uri = sub.count == 2 ? String(sub[1]) : ""
            hyperlink = uri.isEmpty || uri.count > 2048 ? nil : uri
        case 52:
            let sub = rest.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            if sub.count == 2, sub[1] != "?", let data = Data(base64Encoded: String(sub[1])),
               let text = String(data: data, encoding: .utf8) {
                delegate?.terminalClipboardWrite(self, text: text)
            }
        case 133:
            handleSemanticPrompt(rest)
        case 1337:
            if rest.hasPrefix("CurrentDir=") {
                let path = String(rest.dropFirst("CurrentDir=".count))
                if sshControlPath != nil { remoteCwd = path } else { cwd = path }
                delegate?.terminalCwdChanged(self)
            } else if rest == "SolanumOpenSettings" {
                delegate?.terminalOpenSettings(self)
            } else if rest.hasPrefix("SolanumSSHArgs=") {
                let b64 = String(rest.dropFirst("SolanumSSHArgs=".count))
                sshArgs = Data(base64Encoded: b64).map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
            } else if rest.hasPrefix("SolanumSSHExit=") {
                if let status = Int(rest.dropFirst("SolanumSSHExit=".count)) { delegate?.terminalSSHExited(self, status: status) }
            } else if rest.hasPrefix("SolanumSSH=") {
                let path = String(rest.dropFirst("SolanumSSH=".count))
                sshControlPath = path.isEmpty ? nil : path
                remoteCwd = nil
                delegate?.terminalCwdChanged(self)
            }
        default:
            break
        }
    }

    private static func rgbSpec(_ c: (UInt8, UInt8, UInt8)) -> String {
        String(format: "rgb:%04x/%04x/%04x", Int(c.0) * 257, Int(c.1) * 257, Int(c.2) * 257)
    }

    static func pathFromFileURL(_ s: String) -> String? {
        guard s.hasPrefix("file://") else { return s.hasPrefix("/") ? s : nil }
        let afterScheme = s.dropFirst("file://".count)
        guard let slash = afterScheme.firstIndex(of: "/") else { return nil }
        let raw = String(afterScheme[slash...])
        return raw.removingPercentEncoding ?? raw
    }

    // MARK: - Command blocks (OSC 133)

    private func handleSemanticPrompt(_ s: String) {
        guard !usingAlt, let kind = s.first else { return }
        switch kind {
        case "A": promptStart()
        case "B": commandStart()
        case "C": outputStart()
        case "D":
            let parts = s.split(separator: ";")
            commandFinished(parts.count > 1 ? Int(parts[1]) : nil)
        default: break
        }
    }

    private func newBlock(at line: Int) -> Block {
        let b = Block(id: nextBlockId, promptLine: line)
        nextBlockId += 1
        blocks.append(b)
        currentBlock = b
        return b
    }

    private func promptStart() {
        pruneBlocks()
        if let b = currentBlock, b.state == .prompt {
            b.promptLine = cursorAbs
            b.commandLine = nil
            return
        }
        if currentBlock?.state == .running { commandFinished(nil) }
        _ = newBlock(at: cursorAbs)
    }

    private func commandStart() {
        let b: Block
        if let c = currentBlock, c.state == .prompt { b = c } else { b = newBlock(at: cursorAbs) }
        b.commandLine = cursorAbs
        b.commandCol = cursorX
    }

    private func outputStart() {
        let b: Block
        if let c = currentBlock, c.state == .prompt { b = c } else { b = newBlock(at: max(firstAbs, cursorAbs - 1)) }
        b.outputLine = cursorX == 0 ? cursorAbs : cursorAbs + 1
        b.command = extractCommand(b)
        b.state = .running
        b.startTime = Date()
        title = nil
        hyperlink = nil
    }

    private func extractCommand(_ b: Block) -> String {
        let startLine = b.commandLine ?? b.promptLine
        let startCol = b.commandLine != nil ? b.commandCol : 0
        let endLine = min(max(startLine, (b.outputLine ?? cursorAbs) - 1), startLine + 50)
        var out = ""
        for a in startLine...endLine {
            guard let l = line(abs: a) else { continue }
            out += l.text(from: a == startLine ? startCol : 0, trim: !l.wrapped)
            if !l.wrapped && a != endLine { out += "\n" }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commandFinished(_ code: Int?) {
        guard let b = currentBlock, b.state == .running else { return }
        b.exitCode = code
        b.endTime = Date()
        let end = cursorX == 0 ? cursorAbs - 1 : cursorAbs
        b.endLine = max(end, (b.outputLine ?? b.promptLine + 1) - 1, b.promptLine)
        b.state = .finished
        title = nil
        hyperlink = nil  // a program that quit mid-link doesn't link the shell's output
        delegate?.terminalBlockFinished(self, block: b)
    }

    private func removeBlocks(onOrAfter abs: Int) {
        // A command that clears the screen while running (e.g. a TUI repainting) keeps its block;
        // its output now starts at the top of the cleared screen.
        if let c = currentBlock, c.state == .running, c.promptLine >= abs {
            c.remap { _ in abs }
        }
        blocks.removeAll { $0.promptLine >= abs && $0 !== currentBlock }
        if let c = currentBlock, c.promptLine >= abs, c.state != .running { currentBlock = nil }
    }

    private func pruneBlocks() {
        let cutoff = dropped
        let cursor = cursorAbs
        blocks.removeAll { $0.lastLine(cursorAbs: cursor) < cutoff }
        if let c = currentBlock, !blocks.contains(where: { $0 === c }) { currentBlock = nil }
    }

    // MARK: - Clear buffer (⌘K)

    /// Clears scrollback and screen, keeping the current prompt (if idle) at the top.
    func clearBuffer() {
        guard !usingAlt else { return }
        var keepFrom = cursorY
        if let b = currentBlock, b.state == .prompt, b.promptLine >= screenTopAbs, b.promptLine <= cursorAbs {
            keepFrom = b.promptLine - screenTopAbs
        }
        let kept = Array(screen[keepFrom...cursorY])
        dropped += scrollback.count
        scrollback.removeAll()
        var newScreen = kept
        while newScreen.count < rows { newScreen.append(Line(cols: cols)) }
        screen = newScreen
        cursorY -= keepFrom
        let shift = keepFrom
        if let b = currentBlock, b.state == .prompt {
            b.remap { $0 - shift }
            blocks = [b]
        } else {
            blocks = []
            currentBlock = nil
        }
    }

    // MARK: - Resize with reflow

    func resize(cols newColsIn: Int, rows newRowsIn: Int) {
        let newCols = max(2, newColsIn), newRows = max(1, newRowsIn)
        guard newCols != cols || newRows != rows else { return }
        if usingAlt {
            let sc = savedCursors[0]
            let r = reflowPrimary(screenLines: primaryScreen, cursorY: sc.y, cursorX: sc.x, newCols: newCols, newRows: newRows)
            primaryScreen = r.screen
            savedCursors[0].y = r.cursorY
            savedCursors[0].x = r.cursorX
            resizeAlt(newCols, newRows)
        } else {
            let r = reflowPrimary(screenLines: screen, cursorY: cursorY, cursorX: cursorX, newCols: newCols, newRows: newRows)
            screen = r.screen
            cursorY = r.cursorY
            cursorX = r.cursorX
        }
        cols = newCols
        rows = newRows
        scrollTop = 0
        scrollBottom = rows - 1
        tabStops = Terminal.defaultTabs(cols)
        pendingWrap = false
        cursorX = min(cursorX, cols - 1)
        cursorY = min(cursorY, rows - 1)
        for i in 0..<2 {
            savedCursors[i].x = min(savedCursors[i].x, cols - 1)
            savedCursors[i].y = min(savedCursors[i].y, rows - 1)
        }
    }

    private func resizeAlt(_ newCols: Int, _ newRows: Int) {
        for l in screen { l.resize(cols: newCols) }
        if newRows < rows {
            var remove = rows - newRows
            let below = rows - 1 - cursorY
            let fromBottom = min(remove, below)
            screen.removeLast(fromBottom)
            remove -= fromBottom
            if remove > 0 {
                screen.removeFirst(remove)
                cursorY -= remove
            }
        } else if newRows > rows {
            for _ in 0..<(newRows - rows) { screen.append(Line(cols: newCols)) }
        }
    }

    private func reflowPrimary(screenLines: [Line], cursorY cy: Int, cursorX cx: Int, newCols: Int, newRows: Int)
        -> (screen: [Line], cursorY: Int, cursorX: Int) {
        var all: [Line] = scrollback.toArray() + screenLines
        let originalCount = all.count
        let cursorIdx = scrollback.count + min(cy, max(screenLines.count - 1, 0))
        while all.count - 1 > cursorIdx, let last = all.last, last.isBlank { all.removeLast() }

        var newLines: [Line] = []
        newLines.reserveCapacity(all.count)
        var oldToNew = [Int](repeating: 0, count: originalCount)
        var newCursorIdx = 0, newCursorX = 0

        var i = 0
        while i < all.count {
            var j = i
            while j < all.count - 1 && all[j].wrapped { j += 1 }

            var cells: [Cell] = []
            var extras: [Int: String] = [:]
            var links: [Int: String] = [:]
            var starts: [Int] = []
            var cursorOff: Int?
            for k in i...j {
                let l = all[k]
                starts.append(cells.count)
                var take = k == j ? l.trimmedLength : l.cells.count
                if k == cursorIdx { take = max(take, min(cx, l.cells.count)); cursorOff = cells.count + cx }
                take = min(take, l.cells.count)
                if let e = l.extras { for (col, s) in e where col < take { extras[cells.count + col] = s } }
                if let k = l.links { for (col, s) in k where col < take { links[cells.count + col] = s } }
                cells.append(contentsOf: l.cells[0..<take])
            }

            var offLine = [Int](repeating: 0, count: cells.count + 1)
            var offCol = [Int](repeating: 0, count: cells.count + 1)
            var cur = Line(cols: newCols)
            var x = 0
            var p = 0
            while p < cells.count {
                let c = cells[p]
                let w = c.width == 2 ? 2 : 1
                if x + w > newCols {
                    cur.wrapped = true
                    newLines.append(cur)
                    cur = Line(cols: newCols)
                    x = 0
                }
                offLine[p] = newLines.count
                offCol[p] = x
                if let e = extras[p] {
                    if cur.extras == nil { cur.extras = [:] }
                    cur.extras![x] = e
                }
                if let u = links[p] {
                    if cur.links == nil { cur.links = [:] }
                    cur.links![x] = u
                    if c.width == 2 { cur.links![x + 1] = u }
                }
                if c.width == 2 {
                    cur.cells[x] = c
                    var tail = c
                    tail.ch = 0
                    tail.width = 0
                    cur.cells[x + 1] = tail
                    if p + 1 < cells.count && cells[p + 1].width == 0 {
                        offLine[p + 1] = newLines.count
                        offCol[p + 1] = x + 1
                        p += 2
                    } else {
                        p += 1
                    }
                    x += 2
                } else {
                    var cc = c
                    if cc.width == 0 { cc.width = 1; cc.ch = 0 }
                    cur.cells[x] = cc
                    x += 1
                    p += 1
                }
            }
            offLine[cells.count] = newLines.count
            offCol[cells.count] = x
            newLines.append(cur)

            for k in i...j { oldToNew[k] = offLine[min(starts[k - i], cells.count)] }
            if let off = cursorOff {
                let o = min(off, cells.count)
                newCursorIdx = offLine[o]
                newCursorX = min(offCol[o], newCols - 1)
                if off > cells.count { newCursorX = min(newCursorX + (off - cells.count), newCols - 1) }
            }
            i = j + 1
        }
        if all.count < originalCount {
            for k in all.count..<originalCount { oldToNew[k] = newCursorIdx }
        }

        let total = newLines.count
        var screenStart = max(0, total - newRows)
        if newCursorIdx < screenStart { screenStart = newCursorIdx }
        var scr = Array(newLines[screenStart..<min(total, screenStart + newRows)])
        while scr.count < newRows { scr.append(Line(cols: newCols)) }
        for l in newLines[0..<screenStart] { l.trimForScrollback() }
        let excess = scrollback.reset(with: Array(newLines[0..<screenStart]))

        let base = dropped
        for b in blocks {
            b.remap { abs in
                let oi = abs - base
                if oi < 0 { return abs }
                if oi >= oldToNew.count { return base + newCursorIdx }
                return base + oldToNew[oi]
            }
        }
        dropped += excess
        pruneBlocks()
        return (scr, newCursorIdx - screenStart, newCursorX)
    }
}
