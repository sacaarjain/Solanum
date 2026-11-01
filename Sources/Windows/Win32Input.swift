import Foundation

/// The console's own key format, which ConPTY asks for with `?9001h`. How characters outside ASCII survive depends on
/// the PSReadLine version: plain UTF-8 loses ✦ and emoji with 2.4.5 in Windows PowerShell, and virtual key VK_PACKET
/// loses all of them with 2.0.0, which Windows ships. Virtual key 0 with the character attached kept them all in both
/// (`Solanum-test --input-probe` shows this for a machine).
enum Win32Input {
    /// ASCII stays as it is, so control keys and escape sequences mean what they always do.
    static func encode(_ bytes: [UInt8]) -> [UInt8] {
        // A lone escape byte can't be told from the start of a sequence, and may wait for whatever's typed next.
        if bytes == [0x1B] { return Array("\u{1b}[27;1;27;1;0;1_\u{1b}[27;1;27;0;0;1_".utf8) }
        guard bytes.contains(where: { $0 >= 0x80 }) else { return bytes }
        var out: [UInt8] = []
        for scalar in String(decoding: bytes, as: UTF8.self).unicodeScalars {
            if scalar.isASCII {
                out.append(UInt8(scalar.value))
                continue
            }
            for unit in String(scalar).utf16 {
                out += Array("\u{1b}[0;0;\(unit);1;0;1_\u{1b}[0;0;\(unit);0;0;1_".utf8)
            }
        }
        return out
    }
}
