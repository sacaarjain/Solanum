import AppKit

// Renders Solanum's flower and tab prompt from the Mac's own drawing (Sources/SolanumArt.swift) into
// Sources/Windows/ArtData.swift, so Windows shows exactly the same art until the drawing itself is shared.
//
//   swiftc -parse-as-library Tools/MakeWindowsArt.swift Sources/SolanumArt.swift -o build/makeart && build/makeart
//
// Run it again when the art changes. Colors are Solanum Default's.
@main
enum MakeWindowsArt {
    static func png(points: CGSize, scale: Int, _ draw: (CGContext, CGRect) -> Void) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(points.width) * scale, pixelsHigh: Int(points.height) * scale,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        draw(context.cgContext, CGRect(origin: .zero, size: points))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    static func main() {
        let foreground = NSColor(srgbRed: 0xD7 / 255.0, green: 0xD3 / 255.0, blue: 0xC7 / 255.0, alpha: 1)
        var out = "// Made by Tools/MakeWindowsArt.swift from Sources/SolanumArt.swift. Don't edit by hand.\n\nenum ArtData {\n"
        out += "    /// Base64 PNGs, by name and then display scale.\n    static let images: [String: String] = [\n"
        for scale in 1...4 {
            func add(_ name: String, _ data: Data) { out += "        \"\(name)@\(scale)\": \"\(data.base64EncodedString())\",\n" }
            add("flower", png(points: CGSize(width: 22, height: 22), scale: scale) { ctx, r in
                SolanumArt.drawFlower(in: ctx, rect: r)
            })
            add("flowerOutline", png(points: CGSize(width: 16, height: 16), scale: scale) { ctx, r in
                SolanumArt.drawOutline(in: ctx, rect: r, color: foreground.withAlphaComponent(0.75).cgColor, lineWidth: 1.1)
            })
            for (name, title, petals) in [("prompt", foreground, CGFloat(1)), ("promptDim", foreground.withAlphaComponent(0.55), 0.65)] {
                let image = SolanumArt.promptImage(style: .pale, underscore: title, petalAlpha: petals)
                add(name, png(points: SolanumArt.promptSize, scale: scale) { _, r in image.draw(in: r) })
            }
        }
        out += "    ]\n}\n"
        try! out.write(toFile: "Sources/Windows/ArtData.swift", atomically: true, encoding: .utf8)
    }
}
