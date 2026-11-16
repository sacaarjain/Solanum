import CCanvas
import Foundation
import WinSDK

/// The scrollbars over everything that scrolls (terminals, files, previews, the sidebar, git's pages, lists, Settings),
/// as the Mac's overlay ones: hidden until it scrolls or the pointer comes to its edge, a thumb that fades away a moment
/// after, grows a little under the pointer, and can be dragged; a press on the track pages toward it.
///
/// Each frame, what scrolls draws its bars through `draw`, which notes where they are; scrolling is noticed by the
/// offset changing from one frame to the next, so nothing has to say it scrolled. The window passes its mouse to
/// `mouse` first, and keeps drawing while `isAnimating`.
enum ScrollBars {
    enum Axis { case vertical, horizontal }

    private struct Bar {
        let id: String
        let axis: Axis
        let track: UIRect
        let thumb: UIRect
        let total: Double
        let visible: Double
        let offset: Double
        let scale: Float
        let setOffset: (Double) -> Void
    }

    private static var bars: [ObjectIdentifier: [Bar]] = [:]
    private static var lastOffset: [String: Double] = [:]
    private static var activity: [String: Date] = [:]
    private static var hovered: String?
    private static var dragging: (id: String, start: Float, startOffset: Double)?

    /// How long a bar stays after it scrolled, then how long it takes to fade.
    private static let stay = 0.9, fade = 0.35

    static func clear(_ canvas: Canvas) { bars[ObjectIdentifier(canvas)] = [] }

    /// The bar across `track` (the strip along the edge it runs on) for content `total` long, of which `visible` shows,
    /// scrolled `offset` from the start; all in the same units (rows, pixels). Nothing when it all fits. `setOffset`
    /// scrolls it, for dragging.
    static func draw(id: String, on canvas: Canvas, track: UIRect, axis: Axis, total: Double, visible: Double, offset: Double,
                     scale s: Float, setOffset: @escaping (Double) -> Void) {
        guard total > visible + 0.5, visible > 0, track.width > 0, track.height > 0 else { return }
        let now = Date()
        if let last = lastOffset[id], abs(last - offset) > 0.01 { activity[id] = now }
        lastOffset[id] = offset
        let vertical = axis == .vertical
        let length = vertical ? track.height : track.width
        let thumbLength = min(max(length * Float(visible / total), 28 * s), length)
        let fraction = Float(min(max(offset / (total - visible), 0), 1))
        let start = (vertical ? track.y : track.x) + (length - thumbLength) * fraction
        let wide = hovered == id || dragging?.id == id
        let thickness = ((wide ? 8 : 5) * s).rounded(), inset = (2 * s).rounded()
        let thumb = vertical
            ? UIRect(x: track.maxX - inset - thickness, y: start, width: thickness, height: thumbLength)
            : UIRect(x: start, y: track.maxY - inset - thickness, width: thumbLength, height: thickness)
        bars[ObjectIdentifier(canvas), default: []].append(Bar(id: id, axis: axis, track: track, thumb: thumb, total: total, visible: visible,
                                                               offset: offset, scale: s, setOffset: setOffset))
        let alpha = visibility(id, now: now)
        guard alpha > 0 else { return }
        let c = canvas.raw, fg = TerminalPalette.foreground
        // Under the pointer, the track shows faintly too, as the Mac's does.
        if wide {
            let lane = vertical ? UIRect(x: thumb.x - 1, y: track.y, width: thickness + 2, height: track.height)
                                : UIRect(x: track.x, y: thumb.y - 1, width: track.width, height: thickness + 2)
            sol_canvas_fill_rounded(c, lane.x, lane.y, lane.width, lane.height, (thickness + 2) / 2, fg, 0.06 * alpha)
        }
        sol_canvas_fill_rounded(c, thumb.x, thumb.y, thumb.width, thumb.height, thickness / 2, fg, (wide ? 0.55 : 0.38) * alpha)
    }

    /// 1 while it's scrolling, hovered or dragged; fading to 0 after.
    private static func visibility(_ id: String, now: Date) -> Float {
        if hovered == id || dragging?.id == id { return 1 }
        guard let at = activity[id] else { return 0 }
        let t = now.timeIntervalSince(at)
        if t < stay { return 1 }
        return Float(max(0, 1 - (t - stay) / fade))
    }

    /// Whether a bar is still showing or fading, so the window keeps drawing.
    static var isAnimating: Bool {
        let now = Date()
        return activity.values.contains { now.timeIntervalSince($0) < stay + fade + 0.05 }
    }

    /// Where the pointer shows a bar, along its edge: a little wider than the thumb at its widest.
    private static func zone(_ b: Bar) -> UIRect {
        let w = (12 * b.scale).rounded()
        return b.axis == .vertical ? UIRect(x: b.track.maxX - w, y: b.track.y, width: w, height: b.track.height)
                                   : UIRect(x: b.track.x, y: b.track.maxY - w, width: b.track.width, height: w)
    }

    /// The window's mouse, before anything else has it. True when a bar took it (a press or drag on one); `redraw` says
    /// whether what's shown changed (a bar came under or left the pointer).
    static func mouse(_ message: UINT, x: Float, y: Float, on canvas: Canvas, redraw: inout Bool) -> Bool {
        let list = bars[ObjectIdentifier(canvas)] ?? []
        if let d = dragging {
            guard let b = list.last(where: { $0.id == d.id }) else { dragging = nil; return false }
            switch message {
            case Win.WM_MOUSEMOVE:
                let vertical = b.axis == .vertical
                let length = vertical ? b.track.height : b.track.width, thumbLength = vertical ? b.thumb.height : b.thumb.width
                let room = max(length - thumbLength, 1), moved = (vertical ? y : x) - d.start
                b.setOffset(min(max(d.startOffset + Double(moved / room) * (b.total - b.visible), 0), b.total - b.visible))
                activity[b.id] = Date()
                redraw = true
            case Win.WM_LBUTTONUP:
                dragging = nil
                activity[b.id] = Date()
                redraw = true
            default: break
            }
            return true
        }
        let under = list.last { zone($0).contains(x, y) }
        if under?.id != hovered {
            // Leaving, it fades from here rather than vanishing.
            if let was = hovered { activity[was] = Date() }
            hovered = under?.id
            redraw = true
        }
        guard let b = under, message == Win.WM_LBUTTONDOWN || message == Win.WM_LBUTTONDBLCLK else { return false }
        let vertical = b.axis == .vertical, at = vertical ? y : x
        let thumbStart = vertical ? b.thumb.y : b.thumb.x, thumbEnd = vertical ? b.thumb.maxY : b.thumb.maxX
        if at < thumbStart || at > thumbEnd {
            // A page toward the press, as Windows' own bars do; holding on goes on dragging from there.
            let page = b.visible * 0.9 * (at < thumbStart ? -1 : 1)
            let next = min(max(b.offset + page, 0), b.total - b.visible)
            b.setOffset(next)
            dragging = (b.id, at, next)
        } else {
            dragging = (b.id, at, b.offset)
        }
        activity[b.id] = Date()
        redraw = true
        return true
    }

    /// Whether a point is on a bar's edge (where the pointer is the arrow, as over any control), or one is being dragged.
    static func isOver(x: Float, y: Float, on canvas: Canvas) -> Bool {
        dragging != nil || (bars[ObjectIdentifier(canvas)] ?? []).contains { zone($0).contains(x, y) }
    }

    /// The pointer left the window: no bar is under it.
    static func mouseLeft() {
        if let was = hovered { activity[was] = Date() }
        hovered = nil
    }

    static var isDragging: Bool { dragging != nil }
}
