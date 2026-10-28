// Renders Solanum's app icon into an .iconset folder: `makeicon <out.iconset>`.
// Built together with Sources/SolanumArt.swift, which holds the drawing.
import AppKit

@main
enum MakeIcon {
    static func render(size: Int) -> Data? {
        let s = CGFloat(size)
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: s / 1024, y: s / 1024)
        SolanumArt.drawIcon(in: ctx)
        guard let img = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])
    }

    static func main() {
        let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        let specs: [(String, Int)] = [
            ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
            ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
            ("icon_512x512", 512), ("icon_512x512@2x", 1024),
        ]
        for (name, size) in specs {
            if let d = render(size: size) {
                try? d.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
            }
        }
    }
}
