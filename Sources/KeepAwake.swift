import AppKit

/// Keep Awake (⇧⌘A, or the cup in the status bar): the Mac and its display don't sleep for as long as Settings says
/// (`keep-awake-seconds`, 8 hours to start with), as on Windows. `caffeinate` does it, in the background with no
/// terminal, tied to Solanum (`-w`), so it ends when Solanum does even if Solanum is killed. The cup's menu adds an hour,
/// takes one off, or ends it.
enum KeepAwake {
    /// When it ends; nil while off.
    private(set) static var until: Date?
    private static var process: Process?
    private static var timer: Timer?
    /// Posted when it starts, stops, or its time changes (and once a second while it's on, for the time left).
    static let changed = Notification.Name("solanumKeepAwakeChanged")

    static var isOn: Bool { until.map { Date() < $0 } ?? false }

    /// Seconds left, nil while off.
    static var secondsLeft: Int? {
        guard let until, isOn else { return nil }
        return max(Int(until.timeIntervalSinceNow.rounded(.up)), 0)
    }

    static func start(seconds: Int) {
        until = Date().addingTimeInterval(TimeInterval(max(seconds, 1)))
        run(max(seconds, 1))
        tickEverySecond()
        NotificationCenter.default.post(name: changed, object: nil)
    }

    static func stop() {
        guard until != nil else { return }
        until = nil
        process?.terminate()
        process = nil
        timer?.invalidate()
        timer = nil
        NotificationCenter.default.post(name: changed, object: nil)
    }

    /// More time (or less, for negative `seconds`), ending it if that leaves none.
    static func extend(by seconds: Int) {
        guard let current = until, isOn else { return }
        let next = current.addingTimeInterval(TimeInterval(seconds))
        guard next > Date() else { return stop() }
        until = next
        run(max(Int(next.timeIntervalSinceNow.rounded(.up)), 1))
        NotificationCenter.default.post(name: changed, object: nil)
    }

    static func toggle() {
        if isOn { stop() } else { start(seconds: Config.shared.keepAwakeSeconds) }
    }

    /// The menu item's title: what it would do now.
    static var menuTitle: String {
        secondsLeft.map { "Stop Keeping Awake (\(shortDuration($0)) left)" } ?? "Keep Awake (\(shortDuration(Config.shared.keepAwakeSeconds)))"
    }

    /// What the pointer over the cup shows.
    static var tip: String {
        secondsLeft.map { "Keeping this Mac awake · \(shortDuration($0)) left" }
            ?? "Caffeinate is off · click to start it for \(shortDuration(Config.shared.keepAwakeSeconds))"
    }

    /// "8h", "7h 59m", "45m", "30s": the time left as the status bar shows it, to the minute past one (as on Windows).
    static func shortDuration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        let minutes = (seconds + 59) / 60
        let h = minutes / 60, m = minutes % 60
        return h == 0 ? "\(m)m" : m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }

    /// `caffeinate` for `seconds`, in place of any already running. Not in a test (a snapshot or the self-test), which
    /// mustn't keep the Mac awake: there it's only the state.
    private static func run(_ seconds: Int) {
        process?.terminate()
        process = nil
        guard !Headless.active, !CommandLine.arguments.contains("--selftest") else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        // The display, idle sleep and (on power) system sleep, for as long as asked or Solanum's running.
        p.arguments = ["-d", "-i", "-s", "-t", String(seconds), "-w", String(getpid())]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        process = p
    }

    /// While on: ends it once its time's up, and tells the cup and menu each second (the time left).
    private static func tickEverySecond() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1, repeats: true) { _ in
            if let until, Date() >= until { return stop() }
            NotificationCenter.default.post(name: changed, object: nil)
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
}

/// Keep Awake's cup, as Windows draws it: a teacup on its saucer on a 24-unit square (17 points across), filled lightly
/// and outlined, with three S-shaped wisps of steam over it that wave as they rise while it's on.
enum CupArt {
    private static let body = path("M3.2 9.6H17.4L16.7 14.2C16.3 16.8 14.4 18.6 11.9 18.6H8.7C6.2 18.6 4.3 16.8 3.9 14.2Z")
    private static let handle = path("M17.2 10.9C19.4 10.3 21.1 11.3 21 13C20.9 14.7 19 15.8 16.7 15.2")
    private static let saucer = path("M1.6 19.9H19C18.6 21.1 17.4 21.8 15.9 21.8H4.7C3.2 21.8 2 21.1 1.6 19.9Z")

    /// The cup centered in `r` (a flipped view: y down, as the paths are). `steam`, in seconds, moves the steam; nil
    /// draws it still.
    static func draw(in r: NSRect, color: NSColor, alpha: CGFloat, steam: Double?) {
        let unit: CGFloat = 17 / 24, side = 24 * unit
        let origin = NSPoint(x: (r.minX + (r.width - side) / 2).rounded(), y: (r.minY + (r.height - side) / 2).rounded())
        var place = AffineTransform(translationByX: origin.x, byY: origin.y)
        place.scale(unit)
        func placed(_ p: NSBezierPath) -> NSBezierPath {
            let c = p.copy() as! NSBezierPath
            c.transform(using: place)
            return c
        }
        color.withAlphaComponent(alpha * 0.3).setFill()
        placed(body).fill()
        placed(saucer).fill()
        // Outlines in one solid color, so where the handle and saucer meet the cup doesn't show darker.
        let ink = alpha < 1 ? (color.blended(withFraction: 1 - alpha, of: Config.shared.theme.tabBarTint.withAlphaComponent(1)) ?? color) : color
        ink.setStroke()
        for p in [body, handle, saucer] {
            let c = placed(p)
            c.lineWidth = 1.6 * unit
            c.lineJoinStyle = .round
            c.lineCapStyle = .round
            c.stroke()
        }
        // Three wisps side by side; moving, each wave travels up them.
        let phase = CGFloat((steam ?? 0).truncatingRemainder(dividingBy: 1000)) * 4
        color.withAlphaComponent(alpha * 0.7).setStroke()
        for base in [CGFloat(7.3), 10.3, 13.3] {
            let wisp = NSBezierPath()
            let bottom: CGFloat = 8, top: CGFloat = 1.6, steps = 14
            for i in 0...steps {
                let yy = bottom - (bottom - top) * CGFloat(i) / CGFloat(steps)
                let p = NSPoint(x: origin.x + (base + 0.75 * sin(yy + phase)) * unit, y: origin.y + yy * unit)
                if i == 0 { wisp.move(to: p) } else { wisp.line(to: p) }
            }
            wisp.lineWidth = 1.15 * unit
            wisp.lineCapStyle = .round
            wisp.lineJoinStyle = .round
            wisp.stroke()
        }
    }

    /// The SVG path commands these use (absolute M, L, H, V, C and Z), in the paths' own units.
    static func path(_ d: String) -> NSBezierPath {
        let p = NSBezierPath()
        var numbers: [CGFloat] = [], command: Character = "M", current = NSPoint.zero
        func flush() {
            switch command {
            case "M":
                var i = 0
                while i + 1 < numbers.count {
                    current = NSPoint(x: numbers[i], y: numbers[i + 1])
                    if i == 0 { p.move(to: current) } else { p.line(to: current) }
                    i += 2
                }
            case "L":
                var i = 0
                while i + 1 < numbers.count { current = NSPoint(x: numbers[i], y: numbers[i + 1]); p.line(to: current); i += 2 }
            case "H":
                for x in numbers { current = NSPoint(x: x, y: current.y); p.line(to: current) }
            case "V":
                for y in numbers { current = NSPoint(x: current.x, y: y); p.line(to: current) }
            case "C":
                var i = 0
                while i + 5 < numbers.count {
                    current = NSPoint(x: numbers[i + 4], y: numbers[i + 5])
                    p.curve(to: current, controlPoint1: NSPoint(x: numbers[i], y: numbers[i + 1]), controlPoint2: NSPoint(x: numbers[i + 2], y: numbers[i + 3]))
                    i += 6
                }
            case "Z":
                p.close()
            default:
                break
            }
            numbers = []
        }
        var token = ""
        func endNumber() {
            if let n = Double(token) { numbers.append(CGFloat(n)) }
            token = ""
        }
        for ch in d {
            if ch.isLetter {
                endNumber()
                flush()
                command = ch
                if ch == "Z" || ch == "z" { flush() }
            } else if ch == " " || ch == "," {
                endNumber()
            } else if ch == "-", !token.isEmpty {
                endNumber()
                token = "-"
            } else {
                token.append(ch)
            }
        }
        endNumber()
        flush()
        return p
    }
}
