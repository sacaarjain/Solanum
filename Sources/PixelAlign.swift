import AppKit

// Crisp chrome. Borders, pills and cards placed from measured text or cell widths (rarely whole numbers) land between
// pixels, and a 1pt line there is smeared faintly across two or three. These put them on whole device pixels.

extension CGContext {
    /// `r` with its edges moved to the nearest device pixels (at any scale, through any translation in effect).
    func pixelAligned(_ r: CGRect) -> CGRect {
        let d = convertToDeviceSpace(r)
        let minX = d.minX.rounded(), minY = d.minY.rounded()
        return convertToUserSpace(CGRect(x: minX, y: minY, width: max(0, d.maxX.rounded() - minX), height: max(0, d.maxY.rounded() - minY)))
    }

    func pixelAligned(_ p: CGPoint) -> CGPoint {
        let d = convertToDeviceSpace(p)
        return convertToUserSpace(CGPoint(x: d.x.rounded(), y: d.y.rounded()))
    }

    /// A rounded border of `width` just inside `r`, which is first put on whole pixels: one crisp line.
    func strokeInside(_ r: CGRect, radius: CGFloat, width: CGFloat = 1) {
        let a = pixelAligned(r).insetBy(dx: width / 2, dy: width / 2)
        let rr = max(0, min(radius - width / 2, a.width / 2, a.height / 2))
        setLineWidth(width)
        addPath(CGPath(roundedRect: a, cornerWidth: rr, cornerHeight: rr, transform: nil))
        strokePath()
    }
}

/// For drawing in an NSView's draw(_:): `r` on whole device pixels of the current context.
func pixelAligned(_ r: NSRect) -> NSRect {
    NSGraphicsContext.current?.cgContext.pixelAligned(r) ?? r
}
