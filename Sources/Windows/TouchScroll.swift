import WinSDK

/// A finger dragged on a touch screen scrolls what's under it, as on a phone: up and down, and across too where what's
/// under it scrolls that way (a file's long lines, the sidebar's long names). Windows makes mouse messages from touches,
/// so a press from a finger is held back until the finger either moves (then it scrolls, and nothing is pressed) or
/// lifts (then it was a tap, and the press and release go through as a click where it went down).
struct TouchScroll {
    /// Whether the mouse message being handled came from a finger (not a pen, nor a mouse): Windows marks those.
    static var fromTouch: Bool {
        let extra = UInt(bitPattern: Int(GetMessageExtraInfo()))
        return extra & 0xFFFF_FF80 == 0xFF51_5780
    }

    /// One way it scrolls: the finger's travel per step, and what a step does (positive shows what's above, or to the
    /// left, as the content follows the finger).
    struct Axis {
        let stepPixels: Float
        let apply: (Int) -> Void
        fileprivate var remainder: Float = 0

        init(stepPixels: Float, apply: @escaping (Int) -> Void) {
            self.stepPixels = max(stepPixels, 1)
            self.apply = apply
        }

        fileprivate mutating func move(by pixels: Float) {
            remainder += pixels / stepPixels
            let steps = Int(remainder)
            guard steps != 0 else { return }
            remainder -= Float(steps)
            apply(steps)
        }
    }

    /// Where the finger went down, for the click a tap makes.
    let start: LPARAM
    private let startX: Float, startY: Float
    private var lastX: Float, lastY: Float
    /// Whether it's moved far enough to be a drag rather than a tap.
    private(set) var dragging = false
    private var vertical: Axis
    private var sideways: Axis?

    init(at lParam: LPARAM, stepPixels: Float, apply: @escaping (Int) -> Void, sideways: Axis? = nil) {
        start = lParam
        startX = Self.x(lParam)
        startY = Self.y(lParam)
        lastX = startX
        lastY = startY
        vertical = Axis(stepPixels: stepPixels, apply: apply)
        self.sideways = sideways
    }

    /// The finger's moved. Less than `slop` pixels from where it went down, either way, it's still a tap.
    mutating func moved(to lParam: LPARAM, slop: Float) {
        let x = Self.x(lParam), y = Self.y(lParam)
        if !dragging {
            guard abs(y - startY) >= slop || (sideways != nil && abs(x - startX) >= slop) else { return }
            dragging = true
            lastX = x
            lastY = y
        }
        // What's under the finger follows it: moving down shows what's above, moving right what's to the left.
        vertical.move(by: y - lastY)
        sideways?.move(by: x - lastX)
        lastX = x
        lastY = y
    }

    private static func x(_ lParam: LPARAM) -> Float { Float(Int16(truncatingIfNeeded: lParam & 0xFFFF)) }
    private static func y(_ lParam: LPARAM) -> Float { Float(Int16(truncatingIfNeeded: (lParam >> 16) & 0xFFFF)) }
}
