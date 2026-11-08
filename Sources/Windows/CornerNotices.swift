import CCanvas
import Foundation
import WinSDK

/// A card in the top-right corner of a window, as on the Mac (CornerNoticeView there): a long command finishing in a
/// tab you're not watching, an agent stopping, an ssh connection dropping. Cards stack downward, newest on top, and
/// fade out after `lifetime`, or on ✕. Clicking one goes to the tab it's about. What a card says comes from
/// `NoticeRules` (Core), which the Mac shares.
final class CornerNotice {
    private(set) var title: String
    let mark: NoticeRules.Mark?
    let lines: [String]
    private(set) var button: (title: String, action: () -> Void)?
    /// The button doesn't close the card (it goes on to show what happens, as Reconnect does).
    let keepsOpen: Bool
    let lifetime: TimeInterval
    let created = Date()
    /// Clicking the card itself (not its button or ✕).
    var onClick: (() -> Void)?
    /// A password asked for in the card (see `askSecret`): what's typed, and what Return does with it.
    private(set) var secret: (placeholder: String, field: TextFieldState, submit: (String) -> Void)?
    /// The password field was just put in: the card's window gives it the keyboard.
    fileprivate var wantsFocus = false
    /// Fading out since.
    private(set) var fadingSince: Date?
    var isGone: Bool { fadingSince.map { Date().timeIntervalSince($0) >= CornerNoticeStack.fade } ?? false }

    init(_ card: NoticeRules.Card, button: (title: String, action: () -> Void)? = nil, keepsOpen: Bool = false, lifetime: TimeInterval = 30) {
        title = card.title
        mark = card.mark
        lines = card.lines
        self.button = button
        self.keepsOpen = keepsOpen
        self.lifetime = lifetime
    }

    /// The window shows changes at its next frame (see `CornerNoticeStack.changed`).
    func setTitle(_ text: String) { title = text; CornerNoticeStack.changed = true }

    /// Once it's done its part (Reconnect, pressed).
    func hideButton() { button = nil; CornerNoticeStack.changed = true }

    /// A password field in the card, for a question asked in a tab that isn't in front: Return hands what was typed to
    /// `submit`. Shown as dots, and kept nowhere but the field until it's sent.
    func askSecret(_ placeholder: String, submit: @escaping (String) -> Void) {
        secret = (placeholder, TextFieldState(""), submit)
        wantsFocus = true
        CornerNoticeStack.changed = true
    }

    /// The field goes (sent, or no longer wanted).
    func endSecret() {
        guard secret != nil else { return }
        secret = nil
        CornerNoticeStack.changed = true
    }

    var hasSecret: Bool { secret != nil }

    func dismiss() {
        guard fadingSince == nil else { return }
        fadingSince = Date()
        CornerNoticeStack.changed = true
    }

    fileprivate func editSecret(_ change: (inout TextFieldState) -> Void) {
        guard var s = secret else { return }
        change(&s.field)
        secret = s
    }
}

/// A window's corner cards: where each goes, drawing them, and their clicks and keys.
final class CornerNoticeStack {
    static let fade: TimeInterval = 0.25
    /// Something on a card changed outside the stack's own handling (a title, a button): the window draws again.
    static var changed = false

    private(set) var notices: [CornerNotice] = []
    private var hoverClose: ObjectIdentifier?
    private var hoverButton: ObjectIdentifier?
    /// The card whose password field has the keyboard.
    private(set) weak var focused: CornerNotice?

    func show(_ notice: CornerNotice) {
        notices.insert(notice, at: 0)
        // A card asking for a password takes the keyboard when it's the newest.
        if notice.hasSecret { focused = notice }
    }

    var isEmpty: Bool { notices.isEmpty }

    // MARK: Layout

    struct Placed {
        let notice: CornerNotice
        let card: UIRect, close: UIRect, button: UIRect?, secret: UIRect?
        let textX: Float, top: Float
    }

    private static let width: Float = 300, maxWidth: Float = 480, lineHeight: Float = 17

    private func measure(_ canvas: Canvas, _ text: String, _ px: Float, semibold: Bool) -> Float {
        let u = Array(text.utf16)
        return sol_canvas_measure_label(canvas.raw, u, Int32(u.count), px, semibold ? 1 : 0).rounded(.up)
    }

    /// Cards down the right side, under the tab bar, newest first.
    func layout(canvas: Canvas, windowWidth: Float, top: Float, scale s: Float) -> [Placed] {
        var y = top + 10 * s
        var out: [Placed] = []
        for n in notices {
            let x0: Float = (n.mark == nil ? 14 : 34) * s
            let buttonW = n.button.map { measure(canvas, $0.title, 12.5 * s, semibold: true) + 8 * s } ?? 0
            let titleW = x0 + measure(canvas, n.title, 12.5 * s, semibold: true) + 4 * s + buttonW + 34 * s
            let linesW = n.lines.map { x0 + measure(canvas, $0, 11.5 * s, semibold: false) + 14 * s }.max() ?? 0
            let w = min(max(Self.width * s, titleW, linesW), Self.maxWidth * s, windowWidth - 28 * s)
            var h = (n.lines.isEmpty ? 40 : 38 + Float(n.lines.count) * Self.lineHeight) * s
            if n.secret != nil { h += 34 * s }
            let card = UIRect(x: (windowWidth - w - 14 * s).rounded(), y: y.rounded(), width: w.rounded(), height: h.rounded())
            let titleTop = n.lines.isEmpty ? card.y + (card.height - 18 * s) / 2 : card.y + 11 * s
            let close = UIRect(x: card.maxX - 30 * s, y: titleTop - 1 * s, width: 20 * s, height: 20 * s)
            let button = n.button.map { b -> UIRect in
                let bw = measure(canvas, b.title, 12.5 * s, semibold: true)
                return UIRect(x: close.x - 8 * s - bw, y: close.y, width: bw + 4 * s, height: 20 * s)
            }
            var secret: UIRect?
            if n.secret != nil {
                let below = titleTop + (22 + Float(n.lines.count) * Self.lineHeight) * s + 4 * s
                secret = UIRect(x: card.x + x0, y: below, width: card.width - x0 - 14 * s, height: 24 * s)
            }
            out.append(Placed(notice: n, card: card, close: close, button: button, secret: secret, textX: card.x + x0, top: titleTop))
            y += h + 8 * s
        }
        return out
    }

    // MARK: Drawing

    func draw(on canvas: Canvas, windowWidth: Float, top: Float, scale s: Float) {
        let c = canvas.raw, fg = TerminalPalette.foreground
        for p in layout(canvas: canvas, windowWidth: windowWidth, top: top, scale: s) {
            let n = p.notice, r = p.card
            let a: Float = n.fadingSince.map { max(0, 1 - Float(Date().timeIntervalSince($0) / Self.fade)) } ?? 1
            guard a > 0 else { continue }
            // A soft shadow, then the card in the theme's raised surface with a hairline border.
            for (grow, alpha) in [(Float(8), Float(0.07)), (4, 0.1), (2, 0.12)] {
                let g = grow * s
                sol_canvas_fill_rounded(c, r.x - g, r.y - g + 3 * s, r.width + g * 2, r.height + g * 2, 9 * s + g, 0x000000, alpha * a)
            }
            sol_canvas_fill_rounded(c, r.x, r.y, r.width, r.height, 9 * s, TerminalPalette.surface, a)
            sol_canvas_stroke_rounded(c, r.x + 0.5, r.y + 0.5, r.width - 1, r.height - 1, 9 * s, fg, (TerminalPalette.isDark ? 0.10 : 0.14) * a, 1)
            // The mark: white on a disc of its color.
            if let mark = n.mark {
                let cx = r.x + 21 * s, cy = p.top + 8.5 * s, rad = 8 * s
                let color: UInt32
                switch mark {
                case .finished: color = TerminalPalette.ansi[2]
                case .failed, .lostConnection: color = TerminalPalette.ansi[1]
                case .needsInput: color = AgentStatus.waiting.rgb
                }
                sol_canvas_fill_ellipse(c, cx, cy, rad, rad, color, a)
                switch mark {
                case .finished: sol_canvas_draw_icon(c, cx - rad, cy - rad, rad * 2, rad * 2, 0xE73E, 9 * s, 0xFFFFFF, a)
                case .failed: sol_canvas_draw_icon(c, cx - rad, cy - rad, rad * 2, rad * 2, 0xE711, 8 * s, 0xFFFFFF, a)
                case .needsInput, .lostConnection:
                    let t = Array((mark == .needsInput ? "?" : "!").utf16), tw = sol_canvas_measure_label(c, t, Int32(t.count), 11 * s, 1)
                    sol_canvas_draw_label(c, cx - tw / 2, cy - rad, tw + 2, rad * 2, t, Int32(t.count), 11 * s, 1, 0xFFFFFF, a)
                }
            }
            let titleRight = (p.button?.x ?? p.close.x) - 4 * s
            label(canvas, n.title, UIRect(x: p.textX, y: p.top, width: titleRight - p.textX, height: 17 * s), 12.5 * s, semibold: true, color: fg, alpha: a)
            for (i, line) in n.lines.enumerated() {
                let lr = UIRect(x: p.textX, y: p.top + (22 + Float(i) * Self.lineHeight) * s, width: r.maxX - 14 * s - p.textX, height: 16 * s)
                label(canvas, middleTruncated(canvas, line, 11.5 * s, lr.width), lr, 11.5 * s, semibold: false, color: fg, alpha: (i == 0 ? 0.85 : 0.55) * a)
            }
            if let b = p.button, let title = n.button?.title {
                if hoverButton == ObjectIdentifier(n) { sol_canvas_fill_rounded(c, b.x - 3 * s, b.y, b.width + 2 * s, b.height, 5 * s, fg, 0.08 * a) }
                label(canvas, title, UIRect(x: b.x, y: b.y, width: b.width, height: b.height), 12.5 * s, semibold: true, color: TerminalPalette.accent, alpha: a)
            }
            if hoverClose == ObjectIdentifier(n) { sol_canvas_fill_rounded(c, p.close.x, p.close.y, p.close.width, p.close.height, 5 * s, fg, 0.14 * a) }
            sol_canvas_draw_icon(c, p.close.x, p.close.y, p.close.width, p.close.height, 0xE711, 8.5 * s, fg, (hoverClose == ObjectIdentifier(n) ? 1 : 0.55) * a)
            if let box = p.secret, let secret = n.secret {
                // The field's box, as the theme draws its inputs.
                sol_canvas_fill_rounded(c, box.x, box.y, box.width, box.height, 6 * s, TerminalPalette.background, 0.6 * a)
                sol_canvas_stroke_rounded(c, box.x + 0.5, box.y + 0.5, box.width - 1, box.height - 1, 6 * s, TerminalPalette.accent, (focused === n ? 0.9 : 0.6) * a, 1)
                let inner = UIRect(x: box.x + 8 * s, y: box.y, width: box.width - 16 * s, height: box.height)
                let dots = String(repeating: "\u{2022}", count: secret.field.text.count)
                if dots.isEmpty {
                    label(canvas, secret.placeholder, inner, 12 * s, semibold: false, color: fg, alpha: 0.55 * a)
                } else {
                    label(canvas, dots, inner, 12.5 * s, semibold: false, color: fg, alpha: a)
                }
                if focused === n {
                    let before = String(repeating: "\u{2022}", count: secret.field.caret)
                    let cx = inner.x + (before.isEmpty ? 0 : measure(canvas, before, 12.5 * s, semibold: false))
                    sol_canvas_fill_rect(c, cx.rounded(), box.y + 5 * s, max(s.rounded(), 1), box.height - 10 * s, TerminalPalette.accent, a)
                }
            }
        }
    }

    private func label(_ canvas: Canvas, _ text: String, _ r: UIRect, _ px: Float, semibold: Bool, color: UInt32, alpha: Float) {
        let u = Array(text.utf16)
        sol_canvas_draw_label(canvas.raw, r.x, r.y, r.width, r.height, u, Int32(u.count), px, semibold ? 1 : 0, color, alpha)
    }

    /// Too long for its line: the middle goes, as the Mac truncates paths and commands.
    private func middleTruncated(_ canvas: Canvas, _ text: String, _ px: Float, _ width: Float) -> String {
        guard measure(canvas, text, px, semibold: false) > width else { return text }
        let chars = Array(text)
        var keep = chars.count - 1
        while keep > 2 {
            let head = keep / 2 + keep % 2, tail = keep / 2
            let candidate = String(chars.prefix(head)) + "\u{2026}" + String(chars.suffix(tail))
            if measure(canvas, candidate, px, semibold: false) <= width { return candidate }
            keep -= max(1, keep / 12)
        }
        return "\u{2026}"
    }

    // MARK: Mouse and keys

    /// What's under the pointer: a card, and on it ✕ or the button or the password field.
    enum Spot { case card, close, button, secret }

    func spot(atX x: Float, y: Float, canvas: Canvas, windowWidth: Float, top: Float, scale: Float) -> (Placed, Spot)? {
        for p in layout(canvas: canvas, windowWidth: windowWidth, top: top, scale: scale) where p.notice.fadingSince == nil && p.card.contains(x, y) {
            if p.close.contains(x, y) { return (p, .close) }
            if let b = p.button, UIRect(x: b.x - 3 * scale, y: b.y, width: b.width + 6 * scale, height: b.height).contains(x, y) { return (p, .button) }
            if let f = p.secret, f.contains(x, y) { return (p, .secret) }
            return (p, .card)
        }
        return nil
    }

    /// A mouse message over the window. True if a card took it (the terminal underneath doesn't get it).
    func mouse(_ message: UINT, x: Float, y: Float, canvas: Canvas, windowWidth: Float, top: Float, scale: Float) -> Bool {
        let hit = spot(atX: x, y: y, canvas: canvas, windowWidth: windowWidth, top: top, scale: scale)
        let close = hit.flatMap { $0.1 == .close ? ObjectIdentifier($0.0.notice) : nil }
        let button = hit.flatMap { $0.1 == .button ? ObjectIdentifier($0.0.notice) : nil }
        if close != hoverClose || button != hoverButton {
            hoverClose = close
            hoverButton = button
            Self.changed = true
        }
        guard let (p, spot) = hit else {
            // A click elsewhere puts the password field down.
            if message == Win.WM_LBUTTONDOWN, focused != nil { focused = nil; Self.changed = true }
            return false
        }
        guard message == Win.WM_LBUTTONDOWN else { return message != Win.WM_MOUSEMOVE }
        let n = p.notice
        switch spot {
        case .close: n.dismiss()
        case .button:
            n.button?.action()
            if !n.keepsOpen { n.dismiss() }
        case .secret: focused = n
        case .card:
            guard let go = n.onClick else { break }
            go()
            n.dismiss()
        }
        Self.changed = true
        return true
    }

    /// Whether the pointer over a card should be a hand: on a button or ✕, or anywhere on one that goes to its tab.
    func wantsHand(atX x: Float, y: Float, canvas: Canvas, windowWidth: Float, top: Float, scale: Float) -> Bool? {
        guard let (p, spot) = spot(atX: x, y: y, canvas: canvas, windowWidth: windowWidth, top: top, scale: scale) else { return nil }
        switch spot {
        case .close, .button: return true
        case .secret: return false
        case .card: return p.notice.onClick != nil
        }
    }

    /// A key for the focused password field. True if it was used.
    func key(_ key: Int32, ctrl: Bool) -> Bool {
        guard let n = focused, n.hasSecret, !n.isGone else { focused = nil; return false }
        switch key {
        case Win.VK_RETURN:
            guard let s = n.secret, !s.field.text.isEmpty else { return true }
            let text = s.field.text
            n.editSecret { $0 = TextFieldState("") }
            s.submit(text)
        case Win.VK_ESCAPE: focused = nil
        case Win.VK_BACK: n.editSecret { $0.deleteBackward() }
        case Win.VK_DELETE: n.editSecret { $0.deleteForward() }
        case Win.VK_LEFT: n.editSecret { $0.move(by: -1) }
        case Win.VK_RIGHT: n.editSecret { $0.move(by: 1) }
        default:
            // Characters come as WM_CHAR; with Ctrl they're nothing for a password.
            return ctrl || key >= 0x30
        }
        Self.changed = true
        return true
    }

    /// A character for the focused password field.
    func typed(_ unit: UInt16) -> Bool {
        guard let n = focused, n.hasSecret, unit >= 0x20, unit != 0x7F, let scalar = Unicode.Scalar(unit) else { return false }
        n.editSecret { $0.insert(String(Character(scalar))) }
        Self.changed = true
        return true
    }

    var hasFocusedField: Bool { focused?.hasSecret == true && focused?.isGone == false }

    /// From the window's timer: cards past their time fade, and faded ones go. True when anything shows differently.
    func tick() -> Bool {
        var redraw = Self.changed
        Self.changed = false
        if let n = notices.first(where: { $0.wantsFocus }) {
            n.wantsFocus = false
            focused = n
        }
        let now = Date()
        for n in notices where n.fadingSince == nil && now.timeIntervalSince(n.created) >= n.lifetime { n.dismiss(); redraw = true }
        if notices.contains(where: { $0.fadingSince != nil }) { redraw = true }
        let before = notices.count
        notices.removeAll { $0.isGone }
        if focused?.isGone == true || (focused != nil && !notices.contains { $0 === focused }) { focused = nil }
        return redraw || notices.count != before
    }
}
