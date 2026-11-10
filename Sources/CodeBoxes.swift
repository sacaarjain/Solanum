import AppKit

// The Mac's part of Claude's code boxes: putting one on the pasteboard, and reading transcripts off the main thread.
// Finding the boxes (CodeBox, ClaudeTranscript, LineSnapshot) is shared with Windows, in Core/CodeBoxFinder.swift.

extension CodeBox {
    /// Puts the box on a pasteboard. A table goes on as HTML and RTF too, so Word, Google Docs, Teams, Outlook
    /// and spreadsheets paste a real table; plain-text apps (terminals, editors, Slack) get the markdown.
    func copy(to pb: NSPasteboard = .general) {
        pb.clearContents()
        guard let html else {
            pb.setString(copyText, forType: .string)
            return
        }
        pb.declareTypes([.html, .rtf, .string], owner: nil)
        pb.setString(html, forType: .html)
        if let data = html.data(using: .utf8),
           let attr = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.html,
                                                                    .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil),
           let rtf = try? attr.data(from: NSRange(location: 0, length: attr.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
            pb.setData(rtf, forType: .rtf)
        }
        pb.setString(copyText, forType: .string)
    }
}

extension ClaudeTranscript {
    private static let queue = DispatchQueue(label: "solanum.transcripts", qos: .utility)

    /// As `codeBlocks(cwd:home:)`, read off the main thread; `done` runs on the main queue.
    static func codeBlocks(cwd: String, _ done: @escaping ([String], String) -> Void) {
        queue.async {
            let found = codeBlocks(cwd: cwd, home: NSHomeDirectory())
            DispatchQueue.main.async { done(found.blocks, found.signature) }
        }
    }
}
