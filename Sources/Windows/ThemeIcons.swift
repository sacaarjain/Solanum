import CCanvas
import Foundation

/// What a theme shows beside its name in the status bar, on its card in Settings and in the card hovering the name: a
/// planet, the Solanum flower, or a picture of your own (an animated GIF plays). As the Mac's ThemeIcon.
enum ThemeIcon: Equatable {
    case planet(PlanetArt.Planet)
    case flower
    /// A picture's full path.
    case picture(String)

    /// A theme's icon, from its "icon" setting: "planet:<name>", "flower", "none", or a picture's file name in the
    /// themes folder (a full path works too). Without one: the planet it's named after, or the flower for Solanum
    /// Default. A picture that's gone shows nothing.
    static func of(_ spec: ThemeSpec) -> ThemeIcon? {
        let custom = AppSettings.shared.customThemeFiles[spec.name] != nil
        guard let v = spec.icon, !v.isEmpty else {
            if let p = PlanetArt.planet(themeName: spec.name, isVSCode: !custom && ThemeSpecs.vsCode.contains { $0.name == spec.name }) { return .planet(p) }
            return !custom && spec.name == ThemeSpecs.defaultName ? .flower : nil
        }
        if v == "none" { return nil }
        if v == "flower" { return .flower }
        if v.hasPrefix("planet:") { return PlanetArt.Planet(rawValue: String(v.dropFirst(7))).map { .planet($0) } }
        let full = v.contains(":") || v.hasPrefix("\\") || v.hasPrefix("/")
        guard let path = full ? v : ThemeFiles.folder?.appendingPathComponent(v).path, FileManager.default.fileExists(atPath: path) else { return nil }
        return .picture(path)
    }

    /// The choices Settings offers for a theme's icon, as (title, setting): from its name, each planet, the flower,
    /// none. A picture of your own is picked with "Picture…".
    static var choices: [(title: String, value: String?)] {
        [("From Its Name", nil)] + PlanetArt.Planet.allCases.map { ($0.rawValue, "planet:\($0.rawValue)") }
            + [("Solanum Flower", "flower"), ("None", "none")]
    }

    /// The setting's title in the choices, or the picture's file name.
    static func title(of value: String?) -> String {
        if let hit = choices.first(where: { $0.value == value }) { return hit.title }
        return value.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "From Its Name"
    }

    /// Whether it moves, so whatever shows it redraws as its frames come.
    var isAnimated: Bool {
        if case .picture(let path) = self { return path.lowercased().hasSuffix(".gif") }
        return false
    }
}

extension Canvas {
    /// Draws a theme's icon fitting the square `r`. A GIF shows the frame for `time` (seconds, any clock: it loops).
    /// `outline`: the flower as the status bar's outline rather than the full one.
    func drawThemeIcon(_ icon: ThemeIcon, _ r: UIRect, scale: Float, time: Double = 0, outline: Bool = false, alpha: Float = 1) {
        switch icon {
        case .planet(let p):
            drawPlanet(p, r, alpha: alpha)
        case .flower:
            drawArt(outline ? "flowerOutline" : "flower", r, scale: scale, alpha: alpha)
        case .picture(let path):
            guard let frames = pictureFrames(path), !frames.images.isEmpty else { return }
            var image = frames.images[0]
            let total = frames.delays.reduce(0, +)
            if frames.images.count > 1, total > 0 {
                var at = Int32((time * 1000).truncatingRemainder(dividingBy: Double(total)))
                for (k, d) in frames.delays.enumerated() {
                    if at < d { image = frames.images[k]; break }
                    at -= d
                }
            }
            var iw: Int32 = 0, ih: Int32 = 0
            sol_canvas_image_size(raw, image, &iw, &ih)
            guard iw > 0, ih > 0 else { return }
            let zoom = min(r.width / Float(iw), r.height / Float(ih))
            let w = Float(iw) * zoom, h = Float(ih) * zoom
            sol_canvas_draw_image(raw, image, (r.x + (r.width - w) / 2).rounded(), (r.y + (r.height - h) / 2).rounded(), w, h, alpha)
        }
    }

    /// A picture's frames, read once per version of its file.
    private func pictureFrames(_ path: String) -> (images: [Int32], delays: [Int32])? {
        let modified = ((try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(path)|\(modified)"
        if let hit = loadedFrames[key] { return hit }
        let capacity = 240
        var images = [Int32](repeating: -1, count: capacity), delays = [Int32](repeating: 0, count: capacity)
        let n = sol_canvas_load_image_frames(raw, Array(path.utf16) + [0], 192, &images, &delays, Int32(capacity))
        let frames = n > 0 ? (Array(images.prefix(Int(n))), Array(delays.prefix(Int(n)))) : ([], [])
        loadedFrames[key] = frames
        return frames
    }
}
