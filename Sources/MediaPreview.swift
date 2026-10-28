import AppKit
import AVKit
import PDFKit

/// Files the editor shows as a preview rather than as text.
enum MediaKind {
    case image, pdf, video, audio

    /// By extension; an explicit list since UTType maps e.g. `.ts` (TypeScript) to MPEG transport streams.
    init?(path: String) {
        switch (path as NSString).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "heic", "heif", "tiff", "tif", "bmp", "webp", "svg", "ico", "icns": self = .image
        case "pdf": self = .pdf
        case "mp4", "m4v", "mov": self = .video
        case "mp3", "m4a", "aac", "wav", "aiff", "aif", "flac", "caf": self = .audio
        default: return nil
        }
    }
}

/// Remote media is copied over before it's shown; larger files open as "too large".
let maxPreviewFileSize = 200 * 1024 * 1024

/// Read-only view of an image, PDF, video or audio file at a local URL.
final class MediaPreviewView: NSView {
    let kind: MediaKind
    /// Dimensions or page count and file size, for the editor header; nil if the file couldn't be opened.
    private(set) var info: String?
    private var content: NSView!
    private var player: AVPlayer?

    init(kind: MediaKind, url: URL) {
        self.kind = kind
        super.init(frame: .zero)
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map {
            ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)
        }
        var details: String?
        switch kind {
        case .image:
            let iv = NSImageView()
            iv.imageScaling = .scaleProportionallyDown
            iv.imageAlignment = .alignCenter
            iv.animates = true
            if let img = NSImage(contentsOf: url) {
                iv.image = img
                // Pixel size, not points (a 2x screenshot reports half its size in points).
                let px = img.representations.map { NSSize(width: $0.pixelsWide, height: $0.pixelsHigh) }.first { $0.width > 0 } ?? img.size
                details = "\(Int(px.width)) × \(Int(px.height))"
            }
            content = iv
        case .pdf:
            let pv = PDFView()
            pv.autoScales = true
            pv.displaysPageBreaks = true
            if let doc = PDFDocument(url: url) {
                pv.document = doc
                details = doc.pageCount == 1 ? "1 page" : "\(doc.pageCount) pages"
            }
            content = pv
        case .video, .audio:
            let pv = AVPlayerView()
            pv.controlsStyle = .inline
            pv.showsFullScreenToggleButton = kind == .video
            let player = AVPlayer(url: url)
            pv.player = player
            self.player = player
            details = kind == .video ? "Video" : "Audio"
            content = pv
        }
        if details != nil { info = [details, bytes].compactMap { $0 }.joined(separator: " · ") }
        addSubview(content)
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Takes keyboard focus (Space plays and pauses the player; arrows page through a PDF).
    var focusView: NSView { content }

    override func layout() {
        super.layout()
        content.frame = kind == .image ? bounds.insetBy(dx: 16, dy: 16) : bounds
    }

    func applyTheme() {
        if let pv = content as? PDFView { pv.backgroundColor = Config.shared.theme.background }
    }

    /// Stop playback when the file's sub-tab is switched away from or closed.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { player?.pause() }
    }
}
