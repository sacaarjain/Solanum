import WinSDK

/// A finger dragged on a touch screen scrolls what's under it, as on a phone. Windows makes mouse messages from touches,
/// so a press from a finger is held back until the finger either moves (then it scrolls, and nothing is pressed) or
/// lifts (then it was a tap, and the press and release go through as a click where it went down).
struct TouchScroll {
    /// Whether the mouse message being handled came from a finger (not a pen, nor a mouse): Windows marks those.
    static var fromTouch: Bool {
        let extra = UInt(bitPattern: Int(GetMessageExtraInfo()))
        return extra & 0xFFFF_FF80 == 0xFF51_5780
    }

    /// Where the finger went down, for the click a tap makes.
    let start: LPARAM
    private let startY: Float
    private var lastY: Float
    /// Whether it's moved far enough to be a drag rather than a tap.
    private(set) var dragging = false
    /// The finger's travel per step, and what a step does: positive shows what's above, as a wheel turned away does.
    private let stepPixels: Float
    private let apply: (Int) -> Void
    private var remainder: Float = 0

    init(at lParam: LPARAM, stepPixels: Float, apply: @escaping (Int) -> Void) {
        start = lParam
        startY = Self.y(lParam)
        lastY = startY
        self.stepPixels = max(stepPixels, 1)
        self.apply = apply
    }

    /// The finger's moved. Less than `slop` pixels from where it went down, it's still a tap.
    mutating func moved(to lParam: LPARAM, slop: Float) {
        let y = Self.y(lParam)
        if !dragging {
            guard abs(y - startY) >= slop else { return }
            dragging = true
            lastY = y
        }
        // What's under the finger follows it: moving down shows what's above.
        remainder += (y - lastY) / stepPixels
        lastY = y
        let steps = Int(remainder)
        guard steps != 0 else { return }
        remainder -= Float(steps)
        apply(steps)
    }

    private static func y(_ lParam: LPARAM) -> Float { Float(Int16(truncatingIfNeeded: (lParam >> 16) & 0xFFFF)) }
}
