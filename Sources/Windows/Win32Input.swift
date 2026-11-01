import Foundation

/// The console's own key format, which ConPTY asks for with `?9001h`. Plain UTF-8 input gets converted back into key
/// presses on the way in, and Windows PowerShell loses characters outside the system's old code page there. A key sent
/// as VK_PACKET, the code for "just this character", arrives whole.
enum Win32Input {
    private static let packetKey = 0xE7

    /// ASCII stays as it is, so control keys and escape sequences mean what they always do.
    static func encode(_ bytes: [UInt8]) -> [UInt8] {
        guard bytes.contains(where: { $0 >= 0x80 }) else { return bytes }
        var out: [UInt8] = []
        for scalar in String(decoding: bytes, as: UTF8.self).unicodeScalars {
            if scalar.isASCII {
                out.append(UInt8(scalar.value))
                continue
            }
            for unit in String(scalar).utf16 {
                out += Array("\u{1b}[\(packetKey);0;\(unit);1;0;1_\u{1b}[\(packetKey);0;\(unit);0;0;1_".utf8)
            }
        }
        return out
    }
}
