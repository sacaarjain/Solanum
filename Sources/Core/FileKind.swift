import Foundation

/// What kind of file a name is, for its icon in the sidebar, the editor's sub-tabs and Git pages: shared by the Mac (an SF
/// Symbol for each, FileSidebarView.symbol) and Windows (a Segoe Fluent icon). By extension; VSCodeLanguages knows the
/// language of many more.
enum FileKind: Equatable {
    case image, archive, pdf, video, audio, text, code, other

    init(name: String) {
        let ext = name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map { last -> String in
            guard let dot = last.lastIndex(of: "."), dot != last.startIndex else { return "" }
            return String(last[last.index(after: dot)...]).lowercased()
        } ?? ""
        switch ext {
        case "png", "jpg", "jpeg", "gif", "heic", "tiff", "bmp", "webp", "svg", "ico": self = .image
        case "zip", "gz", "tgz", "bz2", "xz", "tar", "7z", "rar": self = .archive
        case "pdf": self = .pdf
        case "mp4", "m4v", "mov", "avi", "mkv", "webm": self = .video
        case "mp3", "m4a", "aac", "wav", "aiff", "aif", "flac", "caf", "ogg": self = .audio
        case "md", "txt", "rst", "log", "csv", "tsv": self = .text
        case "swift", "py", "js", "ts", "tsx", "jsx", "c", "h", "cpp", "hpp", "m", "go", "rs", "java", "kt", "rb", "php",
             "sh", "bash", "zsh", "json", "yaml", "yml", "toml", "xml", "html", "css", "sql", "r", "pl", "lua",
             "ps1", "psm1", "bat", "cmd", "cs", "fs", "vb":
            self = .code
        default: self = .other
        }
    }
}
