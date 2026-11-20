import CCanvas
import Foundation
import WinSDK

/// A NumPy file in the file editor, as the data viewers show one (H5Web, napari, PyCharm's): a summary of each array (its
/// range, mean, spread, and a histogram whose handles set a heatmap's contrast), then a view by its shape: a line plot
/// for a list of numbers, a heatmap with a color bar for a grid (its own colors for height × width × RGB), and a slider
/// for each further axis, played like a movie, with each frame's mean along the first. Values shows the numbers in a
/// grid, each cell tinted by its value. Scrolling zooms a plot around the pointer, dragging moves it, and a double-click
/// shows all of it again.
final class NumpyViewer {
    enum Mode { case plot, values }

    private struct State {
        var mode: Mode
        /// The place along each axis before the last two (a slider each).
        var index: [Int]
        /// The heatmap's window on its grid, in rows and columns; nil for all of it.
        var view: (top: Double, left: Double, rows: Double, cols: Double)?
        /// The line plot's window, by index; nil for all of it.
        var span: (from: Double, to: Double)?
        var lo: Double
        var hi: Double
        var log = false
        var map = NumpyColormap.viridis
        var gridTop = 0
        var gridLeft = 0
    }

    private enum Hit: Equatable {
        case array(Int), mode(Mode), colormap, log, auto, reset, play(Int), slider(Int), frames, histogram, plot, grid

        var isSlider: Bool {
            switch self {
            case .slider, .frames: return true
            default: return false
            }
        }
    }

    let file: NumpyFile
    var invalidate: () -> Void = {}
    var cellSize: (width: Float, height: Float) = (8, 16)

    private(set) var selected = 0
    private var states: [Int: State] = [:]
    private var statsCache: [Int: NumpyStats?] = [:]
    private var hits: [(Hit, UIRect)] = []
    private var pointer: (x: Float, y: Float)?
    private var hovered: Hit?
    /// What a press is dragging: the plot (from where, and the window then), a slider, or a contrast handle.
    private var drag: (hit: Hit, x: Float, y: Float, view: (top: Double, left: Double, rows: Double, cols: Double)?, span: (from: Double, to: Double)?, handle: Int)?
    private(set) var playing: Int?
    /// The last slider moved: what ← and → step.
    private var activeAxis = 0
    /// Where this frame's plot and grid were drawn, for the mouse.
    private var plotRect = UIRect(x: 0, y: 0, width: 0, height: 0)
    private var histRect = UIRect(x: 0, y: 0, width: 0, height: 0)
    private var gridLayout: (rect: UIRect, header: Float, column: Float, row: Float, rows: Int, cols: Int)?
    /// The heatmap drawn, by canvas, and what it was drawn from.
    private var images: [OpaquePointer: (id: Int32, key: String)] = [:]
    /// The line plot's points for its window and width.
    private var series: (key: String, points: [Float], low: Double, high: Double)?
    private var lastScale: Float = 1

    init(_ file: NumpyFile, keeping old: NumpyViewer? = nil) {
        self.file = file
        if let old, old.file.arrays.map({ (try? $0.array.get())?.shape }) == file.arrays.map({ (try? $0.array.get())?.shape }) {
            selected = old.selected
            states = old.states
        }
        if selected >= file.arrays.count { selected = 0 }
    }

    deinit {
        for (raw, image) in images { sol_canvas_free_image(raw, image.id) }
    }

    // MARK: The array shown

    private var array: NumpyArray? { file.arrays.indices.contains(selected) ? try? file.arrays[selected].array.get() : nil }

    private func stats(_ i: Int) -> NumpyStats? {
        if let known = statsCache[i] { return known }
        let made = (try? file.arrays[i].array.get()).flatMap { NumpyStats($0) }
        statsCache[i] = made
        return made
    }

    private var state: State {
        get {
            if let s = states[selected] { return s }
            let a = array, range = stats(selected)?.autoRange ?? (lo: 0, hi: 1)
            let plottable = a.map { $0.isNumeric && $0.available > 0 } ?? false
            return State(mode: plottable ? .plot : .values, index: Array(repeating: 0, count: max((a?.shape.count ?? 0) - 2, 0)),
                         lo: range.lo, hi: range.hi)
        }
        set { states[selected] = newValue }
    }

    private enum Shape { case scalar, line, heatmap, image, none }

    private func plotShape(_ a: NumpyArray) -> Shape {
        guard a.isNumeric, a.available > 0 else { return .none }
        if a.shape.isEmpty { return .scalar }
        if a.shape.count == 1 { return a.shape[0] > 0 ? .line : .none }
        if a.isImage { return .image }
        return a.shape.suffix(2).allSatisfy { $0 > 0 } ? .heatmap : .none
    }

    /// The axes with a slider: all but the last two, except for an image's picture, which uses its third for color.
    private func sliderAxes(_ a: NumpyArray, _ st: State) -> [Int] {
        if st.mode == .plot && plotShape(a) == .image { return [] }
        return a.shape.count > 2 ? Array(0..<(a.shape.count - 2)) : []
    }

    /// The grid of the last two axes at the sliders' places: its size, and its values by row and column.
    private func slice(_ a: NumpyArray, _ st: State) -> (rows: Int, cols: Int, value: (Int, Int) -> Double?, index: (Int, Int) -> Int) {
        let n = a.shape.count
        if n == 0 { return (1, 1, { _, _ in a.number(0) }, { _, _ in 0 }) }
        if n == 1 { return (a.shape[0], 1, { r, _ in r < a.available ? a.number(r) : nil }, { r, _ in r }) }
        let rows = a.shape[n - 2], cols = a.shape[n - 1]
        var frame = 0
        for (d, i) in st.index.enumerated() where d < n - 2 { frame = frame * a.shape[d] + min(i, a.shape[d] - 1) }
        let base = frame * rows * cols
        let index: (Int, Int) -> Int = { r, c in a.stored(base + r * cols + c) }
        return (rows, cols, { r, c in
            let i = index(r, c)
            return i < a.available ? a.number(i) : nil
        }, index)
    }

    // MARK: Drawing

    func draw(on canvas: Canvas, in b: UIRect, _ p: PanelPaint, _ s: Float) {
        lastScale = s
        hits = []
        gridLayout = nil
        plotRect = UIRect(x: 0, y: 0, width: 0, height: 0)
        histRect = plotRect
        let pad = (16 * s).rounded()
        var y = b.y + 12 * s
        let inner = UIRect(x: b.x + pad, y: b.y, width: max(b.width - pad * 2, 1), height: b.height)
        // A .npz's arrays, to pick from.
        if file.arrays.count > 1 {
            var x = inner.x
            for (i, entry) in file.arrays.enumerated() {
                let shape = (try? entry.array.get())?.shapeText ?? "?"
                let w = p.width(entry.name, pixels: 12, semibold: true) + p.width(shape, pixels: 11) + 26 * s
                guard x + w <= inner.maxX else { break }
                let r = UIRect(x: x, y: y, width: w, height: 24 * s)
                let on = i == selected
                p.fill(r, on ? TerminalPalette.accent : p.fg, on ? 0.18 : (hovered == .array(i) ? 0.10 : 0.05), radius: 6)
                p.label(entry.name, UIRect(x: r.x + 10 * s, y: r.y, width: w, height: r.height), pixels: 12, semibold: true,
                        color: on ? TerminalPalette.accent : nil)
                p.label(shape, UIRect(x: r.x + 16 * s + p.width(entry.name, pixels: 12, semibold: true), y: r.y, width: w, height: r.height), pixels: 11, alpha: 0.5)
                hits.append((.array(i), r))
                x += w + 6 * s
            }
            y += 34 * s
        }
        guard let a = array else {
            let why: String
            if case .failure(let problem) = file.arrays.indices.contains(selected) ? file.arrays[selected].array : .failure(.notNumpy) {
                switch problem {
                case .notNumpy: why = "Not a NumPy array, or it was cut short."
                case .objects: why = "Holds Python objects (pickled): not shown, since reading them would run code. Show as Text has the rest."
                case .unsupported(let what): why = "Its type (\(what)) can't be shown here."
                }
            } else { why = "This .npz holds no arrays, or it isn't a zip." }
            p.label(why, UIRect(x: inner.x, y: y, width: inner.width, height: 22 * s), alpha: 0.6)
            return
        }
        var st = state
        let shape = plotShape(a)
        if shape == .none && st.mode == .plot { st.mode = .values; state = st }
        let stats = self.stats(selected)
        y = drawSummary(a, stats, st, shape, UIRect(x: inner.x, y: y, width: inner.width, height: 92 * s), p, s) + 10 * s
        y = drawToolbar(a, st, shape, UIRect(x: inner.x, y: y, width: inner.width, height: 28 * s), p, s) + 10 * s
        // From the bottom: the status line, then the sliders (the first with its frames' means above it).
        let statusH = 22 * s
        var bottom = b.maxY - statusH - 6 * s
        let axes = sliderAxes(a, st)
        var sliderRows: [(Int, UIRect)] = []
        for d in axes.reversed() {
            bottom -= 30 * s
            sliderRows.insert((d, UIRect(x: inner.x, y: bottom, width: inner.width, height: 28 * s)), at: 0)
        }
        var framesRect: UIRect?
        if let first = sliderRows.first, first.0 == 0, let means = stats?.frameMeans, means.count > 1 {
            bottom -= 34 * s
            framesRect = UIRect(x: first.1.x, y: bottom, width: first.1.width, height: 30 * s)
        }
        let main = UIRect(x: inner.x, y: y, width: inner.width, height: max(bottom - 8 * s - y, 40 * s))
        var readout: String?
        if st.mode == .values {
            readout = drawGrid(a, st, main, p, s)
        } else {
            switch shape {
            case .line: readout = drawLine(a, st, main, p, s)
            case .heatmap, .image: readout = drawHeatmap(a, st, shape == .image, main, p, s)
            case .scalar:
                let v = a.text(0)
                p.label(v, UIRect(x: main.x + (main.width - p.width(v, pixels: 28, semibold: true)) / 2, y: main.y, width: main.width, height: min(main.height, 80 * s)),
                        pixels: 28, semibold: true)
            case .none: break
            }
        }
        if let framesRect, let means = stats?.frameMeans { drawFrames(means, current: st.index.first ?? 0, framesRect, p, s) }
        for (d, r) in sliderRows { drawSlider(a, axis: d, st, r, p, s) }
        let hint: String
        switch (st.mode, shape) {
        case (.values, _): hint = "Scroll to move through the values  \u{00B7}  Shift+scroll goes sideways"
        case (_, .line), (_, .heatmap), (_, .image):
            hint = "Scroll to zoom  \u{00B7}  drag to move  \u{00B7}  double-click to see all" + (axes.isEmpty ? "" : "  \u{00B7}  \u{2190} \u{2192} step, Space plays")
        default: hint = ""
        }
        p.label(readout ?? hint, UIRect(x: inner.x, y: b.maxY - statusH - 4 * s, width: inner.width, height: statusH), pixels: 11.5,
                alpha: readout == nil ? 0.4 : 0.8)
    }

    /// What it is, its numbers, and a histogram of its values: drag its handles to set the heatmap's contrast.
    private func drawSummary(_ a: NumpyArray, _ stats: NumpyStats?, _ st: State, _ shape: Shape, _ r: UIRect, _ p: PanelPaint, _ s: Float) -> Float {
        p.fill(r, p.fg, 0.035, radius: 8)
        sol_canvas_stroke_rounded(p.canvas.raw, r.x + 0.5, r.y + 0.5, r.width - 1, r.height - 1, 8 * s, p.fg, 0.08, 1)
        let histW = shape == .none || stats == nil ? 0 : min(320 * s, r.width * 0.42)
        let textW = r.width - histW - 32 * s
        var about = [a.typeName, a.shapeText, NumpyFile.grouped(a.count) + (a.count == 1 ? " value" : " values")]
        if a.fortran && a.shape.count > 1 { about.append("Fortran order") }
        if a.available < a.count { about.append("only \(NumpyFile.grouped(a.available)) read") }
        p.label(about.joined(separator: "  \u{00B7}  "), UIRect(x: r.x + 14 * s, y: r.y + 10 * s, width: textW, height: 22 * s), pixels: 13.5, semibold: true)
        if let st = stats, st.finite > 0 {
            let f = NumpyRender.short
            let pairs = [("min", f(st.min)), ("max", f(st.max)), ("mean", f(st.mean)), ("std", f(st.std))]
            var x = r.x + 14 * s
            for (name, value) in pairs {
                p.label(name, UIRect(x: x, y: r.y + 38 * s, width: 60 * s, height: 20 * s), pixels: 11.5, alpha: 0.5)
                x += p.width(name, pixels: 11.5) + 6 * s
                p.label(value, UIRect(x: x, y: r.y + 38 * s, width: 140 * s, height: 20 * s), pixels: 12.5, semibold: true)
                x += p.width(value, pixels: 12.5, semibold: true) + 18 * s
            }
            var notes: [String] = []
            notes.append(st.nan == 0 ? "no NaN" : "\(NumpyFile.grouped(st.nan)) NaN")
            if st.infinite > 0 { notes.append("\(NumpyFile.grouped(st.infinite)) infinite") }
            if st.sampled { notes.append("from an even sample of \(NumpyFile.grouped(st.finite + st.nan + st.infinite))") }
            p.label(notes.joined(separator: "  \u{00B7}  "), UIRect(x: r.x + 14 * s, y: r.y + 62 * s, width: textW, height: 20 * s), pixels: 11.5,
                    color: st.nan > 0 || st.infinite > 0 ? TerminalPalette.ansi[3] : nil, alpha: st.nan > 0 || st.infinite > 0 ? 0.9 : 0.5)
        } else if !a.isNumeric {
            p.label("Values shows them all.", UIRect(x: r.x + 14 * s, y: r.y + 38 * s, width: textW, height: 20 * s), pixels: 12, alpha: 0.55)
        } else if stats != nil {
            p.label("No values are numbers (all NaN or infinite).", UIRect(x: r.x + 14 * s, y: r.y + 38 * s, width: textW, height: 20 * s), pixels: 12, alpha: 0.55)
        }
        guard histW > 0, let stats, stats.finite > 0 else { return r.maxY }
        let h = UIRect(x: (r.maxX - histW - 14 * s).rounded(), y: r.y + 12 * s, width: histW.rounded(), height: r.height - 34 * s)
        histRect = h
        let contrast = shape == .heatmap
        let bars = max(8, min(128, Int(h.width / (2.5 * s))))
        var counts = [Int](repeating: 0, count: bars)
        for (i, c) in stats.bins.enumerated() { counts[i * bars / stats.bins.count] += c }
        let most = Double(counts.max() ?? 1).squareRoot()
        let barW = h.width / Float(bars)
        for (i, c) in counts.enumerated() where c > 0 {
            let height = max(1, Float(Double(c).squareRoot() / max(most, 1)) * h.height)
            let mid = stats.min + (stats.max - stats.min) * (Double(i) + 0.5) / Double(bars)
            let bar = UIRect(x: h.x + Float(i) * barW, y: h.maxY - height, width: max(barW - 0.5 * s, 1), height: height)
            if contrast {
                let rgb = st.map.color(NumpyRender.position(mid, lo: st.lo, hi: st.hi, log: st.log))
                p.fill(bar, UInt32(rgb.0) << 16 | UInt32(rgb.1) << 8 | UInt32(rgb.2), mid < st.lo || mid > st.hi ? 0.35 : 0.95)
            } else {
                p.fill(bar, TerminalPalette.accent, 0.7)
            }
        }
        p.fill(UIRect(x: h.x, y: h.maxY, width: h.width, height: 1), p.fg, 0.25)
        let span = stats.max - stats.min
        func x(_ v: Double) -> Float { span > 0 ? h.x + Float((v - stats.min) / span) * h.width : (h.x + h.width / 2) }
        if contrast {
            for (i, v) in [st.lo, st.hi].enumerated() {
                let hx = max(h.x, min(h.maxX, x(v))).rounded()
                p.fill(UIRect(x: hx - 0.5 * s, y: h.y - 2 * s, width: max(1.5 * s, 1), height: h.height + 4 * s), p.fg, 0.85)
                let grip = UIRect(x: hx - 4 * s, y: h.maxY + 1 * s, width: 8 * s, height: 7 * s)
                p.fill(grip, p.fg, drag?.hit == .histogram && drag?.handle == i ? 1 : 0.8, radius: 2)
            }
            let range = NumpyRender.short(st.lo) + "  to  " + NumpyRender.short(st.hi) + (st.log ? "  (log)" : "")
            p.label(range, UIRect(x: h.x, y: h.maxY + 6 * s, width: h.width, height: 16 * s), pixels: 10.5, alpha: 0.55)
        } else {
            let ends = NumpyRender.short(stats.min) + "  \u{2026}  " + NumpyRender.short(stats.max)
            p.label(ends, UIRect(x: h.x, y: h.maxY + 6 * s, width: h.width, height: 16 * s), pixels: 10.5, alpha: 0.5)
        }
        if contrast { hits.append((.histogram, UIRect(x: h.x - 6 * s, y: h.y - 4 * s, width: h.width + 12 * s, height: h.height + 14 * s))) }
        return r.maxY
    }

    /// Plot or Values, and the heatmap's colors, scale and contrast.
    private func drawToolbar(_ a: NumpyArray, _ st: State, _ shape: Shape, _ r: UIRect, _ p: PanelPaint, _ s: Float) -> Float {
        // The two views, as one control.
        let titles: [(Mode, String)] = [(.plot, "Plot"), (.values, "Values")]
        let segW = titles.map { p.width($0.1, pixels: 12, semibold: true) + 28 * s }
        let whole = UIRect(x: r.x, y: r.y, width: segW.reduce(0, +) + 4 * s, height: r.height)
        p.fill(whole, p.fg, 0.06, radius: 7)
        var x = whole.x + 2 * s
        for ((mode, title), w) in zip(titles, segW) {
            let seg = UIRect(x: x, y: r.y + 2 * s, width: w, height: r.height - 4 * s)
            let enabled = mode == .values || shape != .none
            if st.mode == mode { p.fill(seg, TerminalPalette.surface, 1, radius: 5); p.fill(seg, p.fg, 0.06, radius: 5) }
            else if hovered == .mode(mode) && enabled { p.fill(seg, p.fg, 0.05, radius: 5) }
            p.label(title, UIRect(x: seg.x + 14 * s, y: seg.y, width: w, height: seg.height), pixels: 12, semibold: true,
                    alpha: enabled ? (st.mode == mode ? 1 : 0.65) : 0.25)
            if enabled { hits.append((.mode(mode), seg)) }
            x += w
        }
        // On the right: what changes the colors, and back to the whole of it.
        var right = r.maxX
        func button(_ hit: Hit, _ title: String, on: Bool = false) {
            let w = p.width(title, pixels: 12, semibold: true) + 20 * s
            right -= w
            let b = UIRect(x: right, y: r.y, width: w, height: r.height)
            p.fill(b, on ? TerminalPalette.accent : p.fg, on ? 0.18 : (hovered == hit ? 0.11 : 0.06), radius: 7)
            p.label(title, UIRect(x: b.x + 10 * s, y: b.y, width: w, height: b.height), pixels: 12, semibold: true,
                    color: on ? TerminalPalette.accent : nil, alpha: 0.85)
            hits.append((hit, b))
            right -= 6 * s
        }
        let usesColors = shape == .heatmap && (st.mode == .plot || a.isNumeric)
        if usesColors {
            button(.auto, "Auto Contrast")
            button(.log, "Log", on: st.log)
            button(.colormap, st.map.name + "  \u{25BE}")
        }
        if st.mode == .plot && (st.view != nil || st.span != nil) { button(.reset, "Show All") }
        return r.maxY
    }

    private func color(_ rgb: (UInt8, UInt8, UInt8)) -> UInt32 { UInt32(rgb.0) << 16 | UInt32(rgb.1) << 8 | UInt32(rgb.2) }

    /// A list of numbers, as a line: one point per index when zoomed in close, else each pixel's lowest and highest.
    private func drawLine(_ a: NumpyArray, _ st: State, _ area: UIRect, _ p: PanelPaint, _ s: Float) -> String? {
        let n = a.shape[0]
        let left = 56 * s, below = 22 * s
        let plot = UIRect(x: (area.x + left).rounded(), y: area.y + 4 * s, width: max(area.width - left - 8 * s, 10), height: max(area.height - below - 4 * s, 10))
        plotRect = plot
        hits.append((.plot, plot))
        let from = st.span?.from ?? 0, to = st.span?.to ?? Double(max(n - 1, 1))
        let w = Int(plot.width)
        let key = "\(selected)|\(from)|\(to)|\(w)"
        if series?.key != key {
            var points: [Float] = []
            var low = Double.infinity, high = -Double.infinity
            let spanD = to - from
            let first = max(0, Int(from.rounded(.down))), last = min(n - 1, Int(to.rounded(.up)))
            if spanD <= Double(w) * 1.5, first <= last {
                for i in first...last {
                    guard i < a.available, let v = a.number(i), v.isFinite else { continue }
                    points += [Float(i), Float(v)]
                    low = min(low, v); high = max(high, v)
                }
            } else if spanD > Double(w) * 1.5 {
                for px in 0..<w {
                    let i0 = max(0, Int(from + spanD * Double(px) / Double(w)))
                    let i1 = min(min(n, a.available), max(i0 + 1, Int(from + spanD * Double(px + 1) / Double(w))))
                    var lo = Double.infinity, hi = -Double.infinity
                    var i = i0
                    while i < i1 {
                        if let v = a.number(i), v.isFinite { lo = min(lo, v); hi = max(hi, v) }
                        i += 1
                    }
                    guard lo <= hi else { continue }
                    let at = Float(from + spanD * (Double(px) + 0.5) / Double(w))
                    points += [at, Float(lo), at, Float(hi)]
                    low = min(low, lo); high = max(high, hi)
                }
            }
            series = (key, points, low, high)
        }
        guard let series, series.low <= series.high else {
            p.label("No numbers to plot here.", UIRect(x: plot.x, y: plot.y, width: plot.width, height: 22 * s), alpha: 0.55)
            return nil
        }
        var ylo = series.low, yhi = series.high
        if yhi == ylo { ylo -= 1; yhi += 1 }
        let padY = (yhi - ylo) * 0.06
        ylo -= padY; yhi += padY
        func px(_ i: Double) -> Float { plot.x + Float((i - from) / max(to - from, 1e-9)) * plot.width }
        func py(_ v: Double) -> Float { plot.maxY - Float((v - ylo) / (yhi - ylo)) * plot.height }
        // The grid, and its numbers.
        for t in NumpyRender.ticks(ylo, yhi, count: max(2, Int(plot.height / (48 * s)))) {
            let yy = py(t).rounded()
            p.fill(UIRect(x: plot.x, y: yy, width: plot.width, height: 1), p.fg, t == 0 ? 0.18 : 0.06)
            let text = NumpyRender.short(t), tw = p.width(text, pixels: 10.5)
            p.label(text, UIRect(x: plot.x - tw - 8 * s, y: yy - 8 * s, width: tw + 2, height: 16 * s), pixels: 10.5, alpha: 0.5)
        }
        for t in NumpyRender.ticks(from, to, count: max(2, Int(plot.width / (90 * s))), whole: true) where t == t.rounded() {
            let xx = px(t).rounded()
            p.fill(UIRect(x: xx, y: plot.y, width: 1, height: plot.height), p.fg, 0.05)
            let text = NumpyRender.short(t), tw = p.width(text, pixels: 10.5)
            p.label(text, UIRect(x: xx - tw / 2, y: plot.maxY + 4 * s, width: tw + 2, height: 16 * s), pixels: 10.5, alpha: 0.5)
        }
        var xy: [Float] = []
        xy.reserveCapacity(series.points.count)
        var k = 0
        while k + 1 < series.points.count {
            xy.append(px(Double(series.points[k])))
            xy.append(py(Double(series.points[k + 1])))
            k += 2
        }
        sol_canvas_push_clip(p.canvas.raw, plot.x, plot.y - 2 * s, plot.width, plot.height + 4 * s)
        if xy.count >= 4 {
            sol_canvas_stroke_polyline(p.canvas.raw, xy, Int32(xy.count / 2), 0, TerminalPalette.accent, 0.95, 1.25 * s)
        } else if xy.count == 2 {
            sol_canvas_fill_ellipse(p.canvas.raw, xy[0], xy[1], 3 * s, 3 * s, TerminalPalette.accent, 1)
        }
        sol_canvas_pop_clip(p.canvas.raw)
        // Under the pointer: its index, and the value there.
        guard let ptr = pointer, plot.contains(ptr.x, ptr.y), drag == nil else { return nil }
        let i = Int((from + Double((ptr.x - plot.x) / plot.width) * (to - from)).rounded())
        guard i >= 0, i < n else { return nil }
        let xx = px(Double(i)).rounded()
        p.fill(UIRect(x: xx, y: plot.y, width: 1, height: plot.height), p.fg, 0.3)
        guard i < a.available, let v = a.number(i) else { return "[\(i)]" }
        if v.isFinite {
            let yy = py(v)
            sol_canvas_fill_ellipse(p.canvas.raw, xx, yy, 4 * s, 4 * s, TerminalPalette.background, 1)
            sol_canvas_fill_ellipse(p.canvas.raw, xx, yy, 3 * s, 3 * s, TerminalPalette.accent, 1)
        }
        return "[\(i)]  =  " + a.text(i)
    }

    /// A grid of values as a heatmap (or an image's own colors), its color bar beside it, rows and columns numbered.
    private func drawHeatmap(_ a: NumpyArray, _ st: State, _ image: Bool, _ area: UIRect, _ p: PanelPaint, _ s: Float) -> String? {
        let rows = image ? a.shape[0] : a.shape[a.shape.count - 2], cols = image ? a.shape[1] : a.shape[a.shape.count - 1]
        let left = 44 * s, below = 22 * s, bar = image ? 0 : 76 * s
        let room = UIRect(x: area.x + left, y: area.y + 2 * s, width: max(area.width - left - bar - 8 * s, 10), height: max(area.height - below - 2 * s, 10))
        let v = st.view ?? (top: 0, left: 0, rows: Double(rows), cols: Double(cols))
        let cell = min(room.width / Float(v.cols), room.height / Float(v.rows))
        let w = max((cell * Float(v.cols)).rounded(), 1), h = max((cell * Float(v.rows)).rounded(), 1)
        let rect = UIRect(x: (room.x + (room.width - w) / 2).rounded(), y: (room.y + (room.height - h) / 2).rounded(), width: w, height: h)
        plotRect = rect
        hits.append((.plot, rect))
        // Drawn at the screen's own pixels (no blur when zoomed in), at most 2048 a side.
        let iw = min(Int(w), 2048), ih = min(Int(h), 2048)
        let key = "\(selected)|\(st.index)|\(v)|\(st.lo)|\(st.hi)|\(st.log)|\(st.map.name)|\(iw)x\(ih)|\(st.mode)"
        var known = images[p.canvas.raw]
        if known?.key != key {
            if let old = known { sol_canvas_free_image(p.canvas.raw, old.id) }
            let rgba: [UInt8]
            if image {
                let depth = a.shape[2]
                let stats = self.stats(selected)
                let scale: Double = a.kind == .float ? ((stats?.max ?? 1) <= 1 && (stats?.min ?? 0) >= 0 ? 1 : max(stats?.max ?? 1, 1e-12)) : 255
                rgba = NumpyRender.image(width: iw, height: ih, rows: rows, cols: cols, top: v.top, left: v.left, spanRows: v.rows, spanCols: v.cols) { r, c, k in
                    let i = a.stored((r * cols + c) * depth + k)
                    return i < a.available ? a.number(i).map { $0 / scale } : nil
                }
            } else {
                let sl = slice(a, st)
                rgba = NumpyRender.heatmap(width: iw, height: ih, rows: rows, cols: cols, top: v.top, left: v.left, spanRows: v.rows, spanCols: v.cols,
                                           lo: st.lo, hi: st.hi, log: st.log, map: st.map, value: sl.value)
            }
            let id = rgba.withUnsafeBufferPointer { sol_canvas_load_rgba(p.canvas.raw, $0.baseAddress, Int32(iw), Int32(ih), 0xFFFF_FFFF) }
            known = (id, key)
            images[p.canvas.raw] = known
        }
        if let known, known.id >= 0 { sol_canvas_draw_image(p.canvas.raw, known.id, rect.x, rect.y, rect.width, rect.height, 1) }
        sol_canvas_stroke_rounded(p.canvas.raw, rect.x - 0.5, rect.y - 0.5, rect.width + 1, rect.height + 1, 0, p.fg, 0.15, 1)
        // Row numbers down the left, column numbers along the bottom.
        for t in NumpyRender.ticks(v.top, v.top + v.rows, count: max(2, Int(h / (44 * s))), whole: true) where t == t.rounded() && t >= 0 && Int(t) < rows {
            let yy = rect.y + Float((t + 0.5 - v.top) / v.rows) * h
            guard yy >= rect.y, yy <= rect.maxY else { continue }
            let text = String(Int(t)), tw = p.width(text, pixels: 10.5)
            p.label(text, UIRect(x: rect.x - tw - 6 * s, y: yy - 8 * s, width: tw + 2, height: 16 * s), pixels: 10.5, alpha: 0.5)
        }
        for t in NumpyRender.ticks(v.left, v.left + v.cols, count: max(2, Int(w / (70 * s))), whole: true) where t == t.rounded() && t >= 0 && Int(t) < cols {
            let xx = rect.x + Float((t + 0.5 - v.left) / v.cols) * w
            guard xx >= rect.x, xx <= rect.maxX else { continue }
            let text = String(Int(t)), tw = p.width(text, pixels: 10.5)
            p.label(text, UIRect(x: xx - tw / 2, y: rect.maxY + 4 * s, width: tw + 2, height: 16 * s), pixels: 10.5, alpha: 0.5)
        }
        // The color bar: high at the top.
        if !image {
            let cb = UIRect(x: (rect.maxX + 14 * s).rounded(), y: rect.y, width: (12 * s).rounded(), height: rect.height)
            let steps = max(2, min(128, Int(cb.height / (2 * s))))
            for i in 0..<steps {
                let t = 1 - (Double(i) + 0.5) / Double(steps)
                let y0 = cb.y + Float(i) * cb.height / Float(steps)
                p.fill(UIRect(x: cb.x, y: y0.rounded(.down), width: cb.width, height: (cb.height / Float(steps)).rounded(.up) + 1), color(st.map.color(t)), 1)
            }
            sol_canvas_stroke_rounded(p.canvas.raw, cb.x - 0.5, cb.y - 0.5, cb.width + 1, cb.height + 1, 0, p.fg, 0.15, 1)
            var marks: [Double] = st.log ? [st.lo, st.hi] : NumpyRender.ticks(st.lo, st.hi, count: max(2, Int(cb.height / (40 * s))))
            if marks.isEmpty { marks = [st.lo] }
            for m in marks {
                let t = NumpyRender.position(m, lo: st.lo, hi: st.hi, log: st.log)
                let yy = (cb.maxY - Float(t) * cb.height).rounded()
                p.fill(UIRect(x: cb.maxX, y: yy, width: 4 * s, height: 1), p.fg, 0.5)
                p.label(NumpyRender.short(m), UIRect(x: cb.maxX + 7 * s, y: yy - 8 * s, width: 60 * s, height: 16 * s), pixels: 10.5, alpha: 0.6)
            }
        }
        // Under the pointer: where it is, and the value there.
        guard let ptr = pointer, rect.contains(ptr.x, ptr.y), drag == nil else { return nil }
        let r = Int(v.top + Double((ptr.y - rect.y) / h) * v.rows), c = Int(v.left + Double((ptr.x - rect.x) / w) * v.cols)
        guard r >= 0, r < rows, c >= 0, c < cols else { return nil }
        if cell >= 6 * s {
            let cx = rect.x + Float(Double(c) - v.left) * cell, cy = rect.y + Float(Double(r) - v.top) * cell
            sol_canvas_push_clip(p.canvas.raw, rect.x, rect.y, rect.width, rect.height)
            sol_canvas_stroke_rounded(p.canvas.raw, cx, cy, cell, cell, 0, TerminalPalette.background, 0.9, 2 * s)
            sol_canvas_stroke_rounded(p.canvas.raw, cx, cy, cell, cell, 0, TerminalPalette.foreground, 0.9, 1 * s)
            sol_canvas_pop_clip(p.canvas.raw)
        }
        let lead = st.index.map(String.init)
        if image {
            let parts = (0..<min(a.shape[2], 4)).map { k -> String in
                let i = a.stored((r * cols + c) * a.shape[2] + k)
                return i < a.available ? a.text(i) : "?"
            }
            return "[\(r), \(c)]  =  (" + parts.joined(separator: ", ") + ")"
        }
        let i = slice(a, st).index(r, c)
        return "[" + (lead + [String(r), String(c)]).joined(separator: ", ") + "]  =  " + (i < a.available ? a.text(i) : "?")
    }

    /// Each frame's mean along the first axis, the one showing marked: where a movie brightens.
    private func drawFrames(_ means: [Double], current: Int, _ r: UIRect, _ p: PanelPaint, _ s: Float) {
        let track = sliderTrack(r, s)
        let box = UIRect(x: track.x, y: r.y, width: track.width, height: r.height)
        hits.append((.frames, box))
        let finite = means.filter(\.isFinite)
        guard let lo = finite.min(), let hi = finite.max() else { return }
        p.fill(box, p.fg, 0.03, radius: 4)
        var xy: [Float] = []
        for (i, m) in means.enumerated() where m.isFinite {
            xy.append(box.x + Float(i) / Float(max(means.count - 1, 1)) * box.width)
            xy.append(box.maxY - 3 * s - Float(hi > lo ? (m - lo) / (hi - lo) : 0.5) * (box.height - 6 * s))
        }
        if xy.count >= 4 { sol_canvas_stroke_polyline(p.canvas.raw, xy, Int32(xy.count / 2), 0, p.fg, 0.55, 1 * s) }
        let x = (box.x + Float(current) / Float(max(means.count - 1, 1)) * box.width).rounded()
        p.fill(UIRect(x: x - 0.5 * s, y: box.y, width: max(1.5 * s, 1), height: box.height), TerminalPalette.accent, 1)
        p.label("mean", UIRect(x: r.x, y: box.y, width: 60 * s, height: box.height), pixels: 10.5, alpha: 0.45)
    }

    private func sliderTrack(_ r: UIRect, _ s: Float) -> UIRect {
        UIRect(x: r.x + 96 * s, y: r.y, width: max(r.width - 96 * s - 110 * s, 20), height: r.height)
    }

    /// One axis's place: its name, play, a track to drag along, and where it is of how many.
    private func drawSlider(_ a: NumpyArray, axis d: Int, _ st: State, _ r: UIRect, _ p: PanelPaint, _ s: Float) {
        let count = a.shape[d], at = d < st.index.count ? st.index[d] : 0
        p.label("axis \(d)", UIRect(x: r.x, y: r.y, width: 56 * s, height: r.height), pixels: 12, semibold: d == activeAxis, alpha: 0.7)
        let play = UIRect(x: r.x + 58 * s, y: r.y + 2 * s, width: 26 * s, height: r.height - 4 * s)
        if hovered == .play(d) { p.fill(play, p.fg, 0.08, radius: 5) }
        p.icon(playing == d ? 0xE769 : 0xE768, play, pixels: 11, alpha: 0.8)  // pause, play
        hits.append((.play(d), play))
        let track = sliderTrack(r, s)
        let line = UIRect(x: track.x, y: track.midY - 2 * s, width: track.width, height: 4 * s)
        p.fill(line, p.fg, 0.12, radius: 2)
        let x = track.x + Float(at) / Float(max(count - 1, 1)) * track.width
        p.fill(UIRect(x: line.x, y: line.y, width: max(x - line.x, 0), height: line.height), TerminalPalette.accent, 0.8, radius: 2)
        let knob: Float = (hovered == .slider(d) || drag?.hit == .slider(d) ? 8 : 7) * s
        sol_canvas_fill_ellipse(p.canvas.raw, x, track.midY, knob, knob, TerminalPalette.surface, 1)
        sol_canvas_fill_ellipse(p.canvas.raw, x, track.midY, knob - 1.5 * s, knob - 1.5 * s, TerminalPalette.accent, 1)
        hits.append((.slider(d), UIRect(x: track.x - 10 * s, y: r.y, width: track.width + 20 * s, height: r.height)))
        p.label("\(NumpyFile.grouped(at)) of \(NumpyFile.grouped(count))", UIRect(x: track.maxX + 18 * s, y: r.y, width: 100 * s, height: r.height), pixels: 12, alpha: 0.7)
    }

    /// The values, in a grid of the last two axes: rows and columns numbered (staying put as it scrolls), each cell
    /// tinted by its value in the heatmap's colors.
    private func drawGrid(_ a: NumpyArray, _ st: State, _ area: UIRect, _ p: PanelPaint, _ s: Float) -> String? {
        let sl = slice(a, st)
        let cw = cellSize.width, rowH = (cellSize.height + 6 * s).rounded()
        let chars = columnChars(a)
        let colW = (Float(chars) * cw + 18 * s).rounded()
        let header = (Float(max(String(max(sl.rows - 1, 0)).count, 3)) * cw + 20 * s).rounded()
        let grid = UIRect(x: area.x, y: area.y, width: area.width, height: area.height)
        let visRows = max(Int((grid.height - rowH) / rowH), 1), visCols = max(Int((grid.width - header) / colW), 1)
        var st = st
        st.gridTop = min(max(st.gridTop, 0), max(sl.rows - visRows, 0))
        st.gridLeft = min(max(st.gridLeft, 0), max(sl.cols - visCols, 0))
        state = st
        gridLayout = (grid, header, colW, rowH, visRows, visCols)
        hits.append((.grid, grid))
        p.fill(grid, p.fg, 0.02, radius: 6)
        sol_canvas_push_clip(p.canvas.raw, grid.x, grid.y, grid.width, grid.height)
        defer { sol_canvas_pop_clip(p.canvas.raw) }
        let tint = a.isNumeric
        let stats = self.stats(selected)
        let lo = st.lo, hi = st.hi
        let table = st.map.table
        var hoverCell: (Int, Int)?
        if let ptr = pointer, grid.contains(ptr.x, ptr.y), ptr.x >= grid.x + header, ptr.y >= grid.y + rowH {
            let r = st.gridTop + Int((ptr.y - grid.y - rowH) / rowH), c = st.gridLeft + Int((ptr.x - grid.x - header) / colW)
            if r < sl.rows && c < sl.cols { hoverCell = (r, c) }
        }
        for k in 0...visRows {
            let r = st.gridTop + k
            guard r < sl.rows else { break }
            let y = grid.y + rowH + Float(k) * rowH
            if k % 2 == 1 { p.fill(UIRect(x: grid.x, y: y, width: grid.width, height: rowH), p.fg, 0.015) }
            for j in 0...visCols {
                let c = st.gridLeft + j
                guard c < sl.cols else { break }
                let x = grid.x + header + Float(j) * colW
                let i = sl.index(r, c)
                guard i < a.available else { continue }
                if tint, let v = a.number(i), v.isFinite, stats != nil {
                    let rgb = table[Int((NumpyRender.position(v, lo: lo, hi: hi, log: st.log) * 255).rounded())]
                    p.fill(UIRect(x: x + 1, y: y + 1, width: colW - 2, height: rowH - 2), color(rgb), 0.32, radius: 3)
                }
                var shown = cellText(a, i)
                // Too long: a number to fewer figures (still the right size), text cut short.
                if shown.count > chars, a.kind == .float, let v = a.number(i) {
                    for digits in [4, 2, 1] where shown.count > chars { shown = String(format: "%.\(digits)g", v) }
                }
                if shown.count > chars { shown = String(shown.prefix(chars - 1)) + "\u{2026}" }
                let right = a.kind != .unicode && a.kind != .bytes
                let tx = right ? x + colW - 9 * s - Float(shown.count) * cw : x + 9 * s
                p.mono(shown, x: tx, y: y + 3 * s, maxCells: chars, color: p.fg)
            }
        }
        if let (r, c) = hoverCell {
            let x = grid.x + header + Float(c - st.gridLeft) * colW, y = grid.y + rowH + Float(r - st.gridTop) * rowH
            sol_canvas_stroke_rounded(p.canvas.raw, x + 0.5, y + 0.5, colW - 1, rowH - 1, 3 * s, TerminalPalette.accent, 1, 1.5 * s)
        }
        // The numbers along the top and down the side, over what's scrolled under them.
        p.fill(UIRect(x: grid.x, y: grid.y, width: grid.width, height: rowH), TerminalPalette.page, 1)
        p.fill(UIRect(x: grid.x, y: grid.y, width: grid.width, height: rowH), p.fg, 0.05)
        p.fill(UIRect(x: grid.x, y: grid.y + rowH, width: header, height: grid.height), TerminalPalette.page, 1)
        p.fill(UIRect(x: grid.x, y: grid.y + rowH, width: header, height: grid.height), p.fg, 0.035)
        let dim = TerminalPalette.mix(p.fg, TerminalPalette.background, 0.45)
        for j in 0...visCols {
            let c = st.gridLeft + j
            guard c < sl.cols else { break }
            let label = a.shape.count == 1 ? "value" : String(c)
            let x = grid.x + header + Float(j) * colW
            p.mono(label, x: x + colW - 9 * s - Float(label.count) * cw, y: grid.y + 3 * s, maxCells: chars, color: hoverCell?.1 == c ? TerminalPalette.accent : dim)
        }
        for k in 0...visRows {
            let r = st.gridTop + k
            guard r < sl.rows else { break }
            let label = String(r)
            p.mono(label, x: grid.x + header - 10 * s - Float(label.count) * cw, y: grid.y + rowH + Float(k) * rowH + 3 * s, maxCells: 12,
                   color: hoverCell?.0 == r ? TerminalPalette.accent : dim)
        }
        p.fill(UIRect(x: grid.x, y: grid.y + rowH - 1, width: grid.width, height: 1), p.fg, 0.12)
        p.fill(UIRect(x: grid.x + header - 1, y: grid.y, width: 1, height: grid.height), p.fg, 0.12)
        // Scrollbars, as everywhere else.
        let id = "numpy:\(ObjectIdentifier(self).hashValue)", room = (12 * s).rounded()
        ScrollBars.draw(id: id + ":v", on: p.canvas, track: UIRect(x: grid.x, y: grid.y + rowH, width: grid.width, height: grid.height - rowH - room),
                        axis: .vertical, total: Double(sl.rows), visible: Double(visRows), offset: Double(st.gridTop), scale: s) { [weak self] top in
            self?.scrollGrid(rows: Int(top.rounded()) - (self?.state.gridTop ?? 0), cols: 0)
        }
        ScrollBars.draw(id: id + ":h", on: p.canvas, track: UIRect(x: grid.x + header, y: grid.y, width: grid.width - header - room, height: grid.height),
                        axis: .horizontal, total: Double(sl.cols), visible: Double(visCols), offset: Double(st.gridLeft), scale: s) { [weak self] left in
            self?.scrollGrid(rows: 0, cols: Int(left.rounded()) - (self?.state.gridLeft ?? 0))
        }
        guard let (r, c) = hoverCell else { return nil }
        let i = sl.index(r, c)
        let place = st.index.map(String.init) + (a.shape.count >= 2 ? [String(r), String(c)] : a.shape.count == 1 ? [String(r)] : [])
        return "[" + place.joined(separator: ", ") + "]  =  " + (i < a.available ? a.text(i) : "?")
    }

    private var charsCache: [Int: Int] = [:]

    /// A column's width in characters: enough for the longest of its first few hundred values, within reason.
    private func columnChars(_ a: NumpyArray) -> Int {
        if let known = charsCache[selected] { return known }
        var most = 5
        for i in stride(from: 0, to: a.available, by: max(1, a.available / 400)) { most = max(most, cellText(a, i).count) }
        let chars = min(most, a.kind == .unicode || a.kind == .bytes ? 40 : 14)
        charsCache[selected] = chars
        return chars
    }

    private func cellText(_ a: NumpyArray, _ i: Int) -> String {
        if a.kind == .float, let v = a.number(i) {
            if !v.isFinite { return NumpyArray.format(v, half: false) }
            return String(format: "%.6g", v)
        }
        return a.text(i)
    }

    // MARK: Mouse and keys

    private func hit(_ x: Float, _ y: Float) -> Hit? { hits.first { $0.1.contains(x, y) }?.0 }

    func mouse(_ message: UINT, x: Float, y: Float) {
        switch message {
        case Win.WM_MOUSEMOVE:
            pointer = (x, y)
            if let d = drag { dragged(d, x, y) }
            let now = hit(x, y)
            if now != hovered || now == .plot || now == .grid || drag != nil { hovered = now; invalidate() }
        case Win.WM_LBUTTONDOWN:
            guard let h = hit(x, y) else { return }
            switch h {
            case .plot:
                drag = (h, x, y, state.view, state.span, 0)
            case .slider(let d):
                activeAxis = d
                drag = (h, x, y, nil, nil, 0)
                dragged(drag!, x, y)
            case .frames:
                activeAxis = 0
                drag = (h, x, y, nil, nil, 0)
                dragged(drag!, x, y)
            case .histogram:
                guard let stats = stats(selected), stats.max > stats.min else { return }
                let v = stats.min + Double((x - histRect.x) / histRect.width) * (stats.max - stats.min)
                let handle = abs(v - state.lo) <= abs(v - state.hi) ? 0 : 1
                drag = (h, x, y, nil, nil, handle)
                dragged(drag!, x, y)
            default: break
            }
        case Win.WM_LBUTTONUP:
            let was = drag
            drag = nil
            if let was, was.hit == .plot || was.hit == .histogram || was.hit.isSlider { invalidate(); return }
            guard let h = hit(x, y) else { return }
            press(h)
        case Win.WM_LBUTTONDBLCLK:
            switch hit(x, y) {
            case .plot?: resetZoom()
            case .histogram?: autoContrast()
            default: break
            }
        default: break
        }
    }

    private func press(_ h: Hit) {
        var st = state
        switch h {
        case .array(let i): selected = i; playing = nil; activeAxis = 0; series = nil
        case .mode(let m): st.mode = m; state = st
        case .colormap:
            let all = NumpyColormap.all
            st.map = all[((all.firstIndex(of: st.map) ?? 0) + 1) % all.count]
            state = st
        case .log: st.log.toggle(); state = st
        case .auto: autoContrast()
        case .reset: resetZoom()
        case .play(let d): activeAxis = d; playing = playing == d ? nil : d
        default: break
        }
        invalidate()
    }

    private func dragged(_ d: (hit: Hit, x: Float, y: Float, view: (top: Double, left: Double, rows: Double, cols: Double)?, span: (from: Double, to: Double)?, handle: Int), _ x: Float, _ y: Float) {
        guard let a = array else { return }
        var st = state
        switch d.hit {
        case .plot:
            let r = plotRect
            guard r.width > 0, r.height > 0 else { return }
            if plotShape(a) == .line, let span = d.span {
                let shift = Double((d.x - x) / r.width) * (span.to - span.from)
                st.span = clampSpan(span.from + shift, span.to + shift, n: a.shape[0])
            } else if let v = d.view {
                let dr = Double((d.y - y) / r.height) * v.rows, dc = Double((d.x - x) / r.width) * v.cols
                st.view = clampView((v.top + dr, v.left + dc, v.rows, v.cols), a)
            }
        case .slider(let axis):
            guard let row = hits.first(where: { $0.0 == .slider(axis) })?.1 else { return }
            let track = UIRect(x: row.x + 10 * lastScale, y: row.y, width: row.width - 20 * lastScale, height: row.height)
            let count = a.shape[axis]
            let at = Int((Double((x - track.x) / max(track.width, 1)) * Double(count - 1)).rounded())
            setIndex(axis, at, &st)
        case .frames:
            guard let box = hits.first(where: { $0.0 == .frames })?.1, let count = a.shape.first else { return }
            setIndex(0, Int((Double((x - box.x) / max(box.width, 1)) * Double(count - 1)).rounded()), &st)
        case .histogram:
            guard let stats = stats(selected), stats.max > stats.min else { return }
            let v = max(stats.min, min(stats.max, stats.min + Double((x - histRect.x) / max(histRect.width, 1)) * (stats.max - stats.min)))
            let gap = (stats.max - stats.min) / 1000
            if d.handle == 0 { st.lo = min(v, st.hi - gap) } else { st.hi = max(v, st.lo + gap) }
        default: return
        }
        state = st
        invalidate()
    }

    private func setIndex(_ axis: Int, _ at: Int, _ st: inout State) {
        guard let a = array, axis < st.index.count else { return }
        st.index[axis] = max(0, min(a.shape[axis] - 1, at))
    }

    private func clampSpan(_ from: Double, _ to: Double, n: Int) -> (from: Double, to: Double)? {
        let last = Double(max(n - 1, 1)), width = to - from
        if width >= last { return nil }
        let start = max(0, min(last - width, from))
        return (start, start + width)
    }

    private func clampView(_ v: (top: Double, left: Double, rows: Double, cols: Double), _ a: NumpyArray) -> (top: Double, left: Double, rows: Double, cols: Double)? {
        let image = plotShape(a) == .image
        let rows = Double(image ? a.shape[0] : a.shape[a.shape.count - 2]), cols = Double(image ? a.shape[1] : a.shape[a.shape.count - 1])
        if v.rows >= rows && v.cols >= cols { return nil }
        let top = v.rows >= rows ? (rows - v.rows) / 2 : max(0, min(rows - v.rows, v.top))
        let left = v.cols >= cols ? (cols - v.cols) / 2 : max(0, min(cols - v.cols, v.left))
        return (top, left, v.rows, v.cols)
    }

    private func resetZoom() {
        var st = state
        st.view = nil
        st.span = nil
        state = st
        invalidate()
    }

    private func autoContrast() {
        guard let range = stats(selected)?.autoRange else { return }
        var st = state
        st.lo = range.lo
        st.hi = range.hi
        state = st
        invalidate()
    }

    /// The wheel: over a plot, zooms around the pointer; over the values, scrolls them; over a slider, steps it.
    func scroll(lines: Int, x: Float, y: Float) {
        guard let a = array else { return }
        var st = state
        switch hit(x, y) {
        case .plot?:
            let f = pow(0.8, Double(lines))
            let r = plotRect
            if plotShape(a) == .line {
                let n = a.shape[0]
                let from = st.span?.from ?? 0, to = st.span?.to ?? Double(max(n - 1, 1))
                let at = from + Double((x - r.x) / max(r.width, 1)) * (to - from)
                let width = max((to - from) * f, 4)
                st.span = clampSpan(at - (at - from) * width / (to - from), at - (at - from) * width / (to - from) + width, n: n)
            } else {
                let image = plotShape(a) == .image
                let rows = Double(image ? a.shape[0] : a.shape[a.shape.count - 2]), cols = Double(image ? a.shape[1] : a.shape[a.shape.count - 1])
                let v = st.view ?? (top: 0, left: 0, rows: rows, cols: cols)
                guard max(v.rows * f, v.cols * f) >= 2 || f > 1 else { return }
                let pr = v.top + Double((y - r.y) / max(r.height, 1)) * v.rows, pc = v.left + Double((x - r.x) / max(r.width, 1)) * v.cols
                st.view = clampView((pr - (pr - v.top) * f, pc - (pc - v.left) * f, v.rows * f, v.cols * f), a)
            }
        case .grid?:
            state = st
            if GetKeyState(Win.VK_SHIFT) < 0 { scrollGrid(rows: 0, cols: -lines) } else { scrollGrid(rows: -lines, cols: 0) }
            return
        case .slider(let d)?:
            activeAxis = d
            setIndex(d, (d < st.index.count ? st.index[d] : 0) - lines.signum(), &st)
        case .frames?:
            setIndex(0, (st.index.first ?? 0) - lines.signum(), &st)
        default: return
        }
        state = st
        invalidate()
    }

    private func scrollGrid(rows: Int, cols: Int) {
        var st = state
        st.gridTop = max(st.gridTop + rows, 0)
        st.gridLeft = max(st.gridLeft + cols, 0)
        state = st
        invalidate()
    }

    /// ← and → step the last slider moved (Shift: ten at a time), Space plays it; in Values, the arrows and Page keys
    /// move through the grid. True if it was used.
    func key(_ key: Int32, shift: Bool, ctrl: Bool) -> Bool {
        guard let a = array, !ctrl else { return false }
        var st = state
        let axes = sliderAxes(a, st)
        let page = max((gridLayout?.rows ?? 20) - 1, 1)
        switch key {
        case Win.VK_LEFT where !axes.isEmpty, Win.VK_RIGHT where !axes.isEmpty:
            let axis = axes.contains(activeAxis) ? activeAxis : axes[0]
            setIndex(axis, (axis < st.index.count ? st.index[axis] : 0) + (key == Win.VK_LEFT ? -1 : 1) * (shift ? 10 : 1), &st)
            state = st
        case 0x20 where !axes.isEmpty:  // Space
            let axis = axes.contains(activeAxis) ? activeAxis : axes[0]
            playing = playing == nil ? axis : nil
        case Win.VK_LEFT where st.mode == .values: scrollGrid(rows: 0, cols: -1); return true
        case Win.VK_RIGHT where st.mode == .values: scrollGrid(rows: 0, cols: 1); return true
        case Win.VK_UP where st.mode == .values: scrollGrid(rows: -1, cols: 0); return true
        case Win.VK_DOWN where st.mode == .values: scrollGrid(rows: 1, cols: 0); return true
        case Win.VK_PRIOR where st.mode == .values: scrollGrid(rows: -page, cols: 0); return true
        case Win.VK_NEXT where st.mode == .values: scrollGrid(rows: page, cols: 0); return true
        case Win.VK_HOME where st.mode == .values: st.gridTop = 0; st.gridLeft = 0; state = st
        case Win.VK_HOME: resetZoom(); return true
        default: return false
        }
        invalidate()
        return true
    }

    /// About ten times a second: a playing slider steps on, round from its end.
    func tick() {
        guard let axis = playing, let a = array, axis < a.shape.count else { return }
        var st = state
        guard axis < st.index.count else { playing = nil; return }
        st.index[axis] = (st.index[axis] + 1) % max(a.shape[axis], 1)
        state = st
        invalidate()
    }

    func mouseLeft() {
        guard pointer != nil || hovered != nil else { return }
        pointer = nil
        hovered = nil
        invalidate()
    }

    // MARK: For tests

    var modeForTesting: Mode { state.mode }
    var indexForTesting: [Int] { state.index }
    func pressForTesting(mode: Mode) { press(.mode(mode)) }
    var zoomedForTesting: Bool { state.view != nil || state.span != nil }
    /// The wheel turned up over the middle of the plot drawn last.
    func zoomForTesting() { scroll(lines: 3, x: plotRect.x + plotRect.width / 2, y: plotRect.y + plotRect.height / 2) }
    /// The pointer at the middle of the plot or grid drawn last.
    func pointForTesting() {
        let r = gridLayout?.rect ?? plotRect
        pointer = (r.x + r.width * 0.4, r.y + r.height * 0.4)
    }
}
