import Foundation

/// A big paste in pieces, for a terminal that drops or garbles input sent all at once: Windows 10's console host reads
/// what's written to a pseudoconsole a few kilobytes at a time, and a sequence (an escape sequence, a key in win32-input
/// mode, a character of more than one byte) cut across two of those reads comes out wrong. Pieces end only where nothing
/// is cut, and go a moment apart, so each is read whole.
enum PasteChunks {
    /// `bytes` in pieces of about `size`, each ending at a place where nothing is cut. Joined, they're `bytes`.
    static func split(_ bytes: [UInt8], size: Int = 512) -> [[UInt8]] {
        guard bytes.count > size else { return bytes.isEmpty ? [] : [bytes] }
        var out: [[UInt8]] = []
        var start = 0
        var i = 0
        // Inside an escape sequence: from ESC to its final byte.
        var escape = false, csi = false
        var lastSafe = 0
        while i < bytes.count {
            let b = bytes[i]
            // Before this byte is a place to cut, unless it's in a sequence or the rest of a character.
            let continuation = b & 0xC0 == 0x80
            if !escape && !continuation && i > start { lastSafe = i }
            if escape {
                if csi {
                    // Parameters and intermediates go on; a final byte (@ to ~) ends it.
                    if b >= 0x40 && b <= 0x7E { escape = false; csi = false }
                } else if b == 0x5B || b == 0x5D || b == 0x50 {
                    // CSI, OSC or DCS: a body follows.
                    csi = true
                } else {
                    escape = false
                }
            } else if b == 0x1B {
                escape = true
            }
            i += 1
            if i - start >= size && lastSafe > start {
                out.append(Array(bytes[start..<lastSafe]))
                start = lastSafe
            }
        }
        if start < bytes.count { out.append(Array(bytes[start...])) }
        return out
    }
}
