import Foundation
import WinSDK

/// A stand-in for Claude Code's input box, for the window test: `Solanum-test --fake-agent <text>`. It draws the same
/// box between two rules, word-wraps its text the same way, and takes a moment to answer keys, as a real program does
/// through ConPTY. Esc ends it, printing the text as "final=…".
enum FakeAgent {
    private static let width = 30
    private static let delay: TimeInterval = 0.2

    /// Rows as ranges of the text. A word-wrap swallows the space it breaks at.
    private static func layout(_ text: [Character]) -> [Range<Int>] {
        var rows: [Range<Int>] = []
        var start = 0
        while text.count - start > width {
            var end = start + width
            while end > start, text[end] != " " { end -= 1 }
            if end == start { end = start + width }
            rows.append(start..<end)
            start = text[end] == " " ? end + 1 : end
        }
        rows.append(start..<text.count)
        return rows
    }

    private static func rowOf(_ position: Int, _ rows: [Range<Int>]) -> Int {
        rows.lastIndex { $0.lowerBound <= position } ?? 0
    }

    static func run(text initial: String) {
        let input = GetStdHandle(DWORD(bitPattern: -10)), output = GetStdHandle(DWORD(bitPattern: -11))
        _ = SetConsoleMode(input, 0)
        _ = SetConsoleMode(output, 0x0005)  // processed output, virtual terminal sequences
        func write(_ s: String) {
            let units = Array(s.utf16)
            var written: DWORD = 0
            _ = WriteConsoleW(output, units, DWORD(units.count), &written, nil)
        }
        var text = Array(initial)
        var position = text.count
        let rule = String(repeating: "─", count: width + 2)

        func draw() {
            let rows = layout(text)
            var out = "\u{1b}[?25l\u{1b}[H" + rule + "\u{1b}[K\r\n"
            for (i, row) in rows.enumerated() {
                out += (i == 0 ? "❯ " : "  ") + String(text[row]) + "\u{1b}[K\r\n"
            }
            out += rule + "\u{1b}[K\u{1b}[J"
            let row = rowOf(position, rows)
            out += "\u{1b}[\(row + 2);\(position - rows[row].lowerBound + 3)H\u{1b}[?25h"
            write(out)
        }

        write("\u{1b}[2J")
        draw()
        var running = true
        while running {
            _ = WaitForSingleObject(input, INFINITE)
            Thread.sleep(forTimeInterval: delay)
            var pending: DWORD = 0
            _ = GetNumberOfConsoleInputEvents(input, &pending)
            for _ in 0..<pending {
                var record = INPUT_RECORD()
                var read: DWORD = 0
                guard ReadConsoleInputW(input, &record, 1, &read), read == 1, record.EventType == 1,
                      record.Event.KeyEvent.bKeyDown.boolValue else { continue }
                let rows = layout(text), row = rowOf(position, rows)
                let unit = record.Event.KeyEvent.uChar.UnicodeChar
                switch Int32(record.Event.KeyEvent.wVirtualKeyCode) {
                case 0x1B: running = false
                case 0x08:
                    if position > 0 {
                        position -= 1
                        text.remove(at: position)
                    }
                case 0x25: position = max(position - 1, 0)
                case 0x27: position = min(position + 1, text.count)
                case 0x26, 0x28:
                    let target = record.Event.KeyEvent.wVirtualKeyCode == 0x26 ? row - 1 : row + 1
                    if rows.indices.contains(target) {
                        position = min(rows[target].lowerBound + position - rows[row].lowerBound, rows[target].upperBound)
                    }
                default:
                    if unit >= 0x20, let scalar = Unicode.Scalar(unit) {
                        text.insert(Character(scalar), at: position)
                        position += 1
                    }
                }
            }
            if running { draw() }
        }
        write("\u{1b}[2J\u{1b}[H")
        write("final=" + String(text) + "\r\n")
    }
}
