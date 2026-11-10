import Foundation

/// Hosts typed into the hosts dropdown ("user@host", "-p 2222 host"), most recent first, as the Mac keeps them: ten at
/// most, in ssh-recent.txt beside the other settings.
enum SSHRecent {
    private static var file: URL { LogFormatStore.configFolder.appendingPathComponent("ssh-recent.txt") }

    static var list: [String] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func remember(_ target: String) {
        let kept = Array(([target] + list.filter { $0 != target }).prefix(10))
        try? FileManager.default.createDirectory(at: LogFormatStore.configFolder, withIntermediateDirectories: true)
        try? (kept.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
    }
}
