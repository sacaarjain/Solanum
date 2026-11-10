import AppKit

// Renders Solanum's flower, tab prompt and app icon from the Mac's own drawing (Sources/SolanumArt.swift) into
// Sources/Windows/ArtData.swift and Support/Windows/Solanum.ico, so Windows shows exactly the same art until the drawing
// itself is shared.
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

    /// The Mac's app icon as a Windows .ico. The Mac leaves a wide margin around its icons that Windows doesn't, where it
    /// would just look small, so the margin is trimmed to what the shadow needs.
    static func windowsIcon() -> Data {
        let sizes = [16, 20, 24, 32, 40, 48, 64, 128, 256]
        let margin: CGFloat = 56
        let images = sizes.map { size in
            png(points: CGSize(width: size, height: size), scale: 1) { ctx, _ in
                let scale = CGFloat(size) / (1024 - margin * 2)
                ctx.scaleBy(x: scale, y: scale)
                ctx.translateBy(x: -margin, y: -margin)
                SolanumArt.drawIcon(in: ctx)
            }
        }
        func little<T: FixedWidthInteger>(_ value: T) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        var file = little(UInt16(0)) + little(UInt16(1)) + little(UInt16(sizes.count))
        var offset = 6 + 16 * sizes.count
        for (size, image) in zip(sizes, images) {
            let side = UInt8(size >= 256 ? 0 : size)
            file += Data([side, side, 0, 0]) + little(UInt16(1)) + little(UInt16(32)) + little(UInt32(image.count)) + little(UInt32(offset))
            offset += image.count
        }
        return images.reduce(file, +)
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
            // The status bar's ssh symbols, as the Mac draws them.
            for (name, symbol, color) in [("serverRack", "server.rack", foreground.withAlphaComponent(0.75)),
                                          ("network", "network", NSColor(srgbRed: 0xA5 / 255.0, green: 0x84 / 255.0, blue: 0xE8 / 255.0, alpha: 1))] {
                let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium).applying(.init(paletteColors: [color]))
                if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                    add(name, png(points: CGSize(width: 16, height: 16), scale: scale) { _, r in
                        let s = image.size
                        image.draw(in: CGRect(x: (r.width - s.width) / 2, y: (r.height - s.height) / 2, width: s.width, height: s.height))
                    })
                }
            }
            for (name, title, petals) in [("prompt", foreground, CGFloat(1)), ("promptDim", foreground.withAlphaComponent(0.55), 0.65)] {
                let image = SolanumArt.promptImage(style: .pale, underscore: title, petalAlpha: petals)
                add(name, png(points: SolanumArt.promptSize, scale: scale) { _, r in image.draw(in: r) })
            }
        }
        out += "    ]\n}\n"
        try! out.write(toFile: "Sources/Windows/ArtData.swift", atomically: true, encoding: .utf8)
        try! windowsIcon().write(to: URL(fileURLWithPath: "Support/Windows/Solanum.ico"))
    }
}
