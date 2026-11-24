import Foundation

// What the NumPy viewer draws, worked out apart from how it's drawn (shared by the Mac and Windows): an array's summary
// (its range, mean, spread and a histogram of its values), the colors of a heatmap, and the ticks along a plot's axes.

/// An array's numbers at a glance: how many aren't numbers, the range, mean and spread, and a histogram. Huge arrays are
/// sampled evenly (`sampled`). For a 3-D or bigger array, each frame's mean along the first axis, as a movie's
/// brightness over time.
struct NumpyStats {
    let total: Int
    let finite: Int
    let nan: Int
    let infinite: Int
    let min: Double
    let max: Double
    let mean: Double
    let std: Double
    /// Counts of the finite values in `binCount` equal steps from `min` to `max`.
    let bins: [Int]
    let sampled: Bool
    /// The mean of each index along the first axis (3-D and up); empty otherwise.
    let frameMeans: [Double]

    static let binCount = 1024

    init?(_ a: NumpyArray, limit: Int = 4_000_000) {
        let n = a.available
        guard n > 0, a.isNumeric else { return nil }
        let step = Swift.max(1, n / limit)
        var lo = Double.infinity, hi = -Double.infinity
        var count = 0, nans = 0, infs = 0, mean = 0.0, m2 = 0.0
        var i = 0
        while i < n {
            if let v = a.number(i) {
                if v.isNaN { nans += 1 } else if v.isInfinite { infs += 1 } else {
                    count += 1
                    if v < lo { lo = v }
                    if v > hi { hi = v }
                    let d = v - mean
                    mean += d / Double(count)
                    m2 += d * (v - mean)
                }
            }
            i += step
        }
        var bins = [Int](repeating: 0, count: Self.binCount)
        if count > 0 {
            let width = hi > lo ? (hi - lo) / Double(Self.binCount) : 1
            i = 0
            while i < n {
                if let v = a.number(i), v.isFinite { bins[Swift.min(Self.binCount - 1, Swift.max(0, Int((v - lo) / width)))] += 1 }
                i += step
            }
        }
        // Each frame's mean, from as many of its values as the limit allows.
        var frames: [Double] = []
        if a.shape.count >= 3, let first = a.shape.first, first > 1 {
            let per = a.count / first
            let take = Swift.max(1, Swift.min(per, limit / first))
            let stride = Swift.max(1, per / take)
            for f in 0..<first {
                var sum = 0.0, k = 0, c = f * per
                let end = (f + 1) * per
                while c < end {
                    let at = a.stored(c)
                    if at < n, let v = a.number(at), v.isFinite { sum += v; k += 1 }
                    c += stride
                }
                frames.append(k > 0 ? sum / Double(k) : .nan)
            }
        }
        total = a.count
        finite = count
        nan = nans
        infinite = infs
        min = count > 0 ? lo : .nan
        max = count > 0 ? hi : .nan
        self.mean = count > 0 ? mean : .nan
        std = count > 0 ? (m2 / Double(count)).squareRoot() : .nan
        self.bins = bins
        sampled = step > 1
        frameMeans = frames
    }

    /// The value below which `p` (0…1) of the finite values fall, to the histogram's step.
    func percentile(_ p: Double) -> Double {
        guard finite > 0, max > min else { return min }
        let target = Double(bins.reduce(0, +)) * p
        var seen = 0.0
        for (b, c) in bins.enumerated() {
            seen += Double(c)
            if seen >= target { return min + (max - min) * Double(b + 1) / Double(bins.count) }
        }
        return max
    }

    /// The range a heatmap's colors span at first: all of it for a small array, else from the 0.5th to the 99.5th
    /// percentile, as Fiji's auto contrast does, so a few bright pixels don't wash out the rest.
    var autoRange: (lo: Double, hi: Double) {
        guard finite > 0 else { return (0, 1) }
        guard finite >= 1000 else { return (min, max) }
        let lo = percentile(0.005), hi = percentile(0.995)
        return hi > lo ? (lo, hi) : (min, max)
    }
}

/// The heatmap colors, as matplotlib's: viridis (its usual), gray (as microscopy images are), magma, and coolwarm (for
/// values either side of zero).
struct NumpyColormap: Equatable {
    let name: String
    let stops: [(Double, Double, Double)]

    static func == (a: NumpyColormap, b: NumpyColormap) -> Bool { a.name == b.name }

    static let viridis = NumpyColormap(name: "viridis", stops: [(68, 1, 84), (72, 40, 120), (62, 74, 137), (49, 104, 142), (38, 130, 142),
                                                                (31, 158, 137), (53, 183, 121), (109, 205, 89), (253, 231, 37)])
    static let gray = NumpyColormap(name: "gray", stops: [(0, 0, 0), (255, 255, 255)])
    static let magma = NumpyColormap(name: "magma", stops: [(0, 0, 4), (28, 16, 68), (79, 18, 123), (129, 37, 129), (181, 54, 122),
                                                            (229, 80, 100), (251, 135, 97), (254, 194, 135), (252, 253, 191)])
    static let coolwarm = NumpyColormap(name: "coolwarm", stops: [(59, 76, 192), (98, 130, 234), (141, 176, 254), (184, 208, 249), (221, 221, 221),
                                                                  (245, 196, 173), (244, 154, 123), (222, 96, 77), (180, 4, 38)])
    static let all = [viridis, gray, magma, coolwarm]

    /// The color at `t` (0…1), as red, green and blue.
    func color(_ t: Double) -> (UInt8, UInt8, UInt8) {
        let x = Swift.max(0, Swift.min(1, t.isNaN ? 0 : t)) * Double(stops.count - 1)
        let i = Swift.min(Int(x), stops.count - 2), f = x - Double(i)
        let a = stops[i], b = stops[i + 1]
        func mix(_ p: Double, _ q: Double) -> UInt8 { UInt8((p + (q - p) * f).rounded()) }
        return (mix(a.0, b.0), mix(a.1, b.1), mix(a.2, b.2))
    }

    /// 256 colors, low to high, for drawing quickly.
    var table: [(UInt8, UInt8, UInt8)] { (0..<256).map { color(Double($0) / 255) } }
}

enum NumpyRender {
    /// Where a value falls between the heatmap's ends, 0…1 (beyond them, clamped). On a log scale, a value at or below
    /// zero is the lowest color.
    static func position(_ v: Double, lo: Double, hi: Double, log: Bool) -> Double {
        if log {
            let floor = lo > 0 ? lo : Swift.max(hi * 1e-4, Double.leastNormalMagnitude)
            guard hi > floor else { return 0.5 }
            let t = (Foundation.log(Swift.max(v, floor)) - Foundation.log(floor)) / (Foundation.log(hi) - Foundation.log(floor))
            return Swift.max(0, Swift.min(1, t))
        }
        guard hi > lo else { return 0.5 }
        return Swift.max(0, Swift.min(1, (v - lo) / (hi - lo)))
    }

    /// RGBA pixels (`width` × `height`) of a `rows` × `cols` grid of values, seen through a window on it (`top`, `left`,
    /// and how many rows and columns it spans, fractions allowed): each pixel the color of the value under its middle.
    /// A value that isn't a number is gray; outside the grid is clear.
    static func heatmap(width: Int, height: Int, rows: Int, cols: Int, top: Double, left: Double, spanRows: Double, spanCols: Double,
                        lo: Double, hi: Double, log: Bool, map: NumpyColormap, value: (Int, Int) -> Double?) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: Swift.max(width * height * 4, 0))
        guard width > 0, height > 0, rows > 0, cols > 0 else { return out }
        let table = map.table
        let colOf = (0..<width).map { x in Int((left + (Double(x) + 0.5) / Double(width) * spanCols).rounded(.down)) }
        for y in 0..<height {
            let r = Int((top + (Double(y) + 0.5) / Double(height) * spanRows).rounded(.down))
            guard r >= 0, r < rows else { continue }
            var o = y * width * 4
            for x in 0..<width {
                defer { o += 4 }
                let c = colOf[x]
                guard c >= 0, c < cols else { continue }
                let rgb: (UInt8, UInt8, UInt8)
                if let v = value(r, c), v.isFinite {
                    rgb = table[Int((position(v, lo: lo, hi: hi, log: log) * 255).rounded())]
                } else {
                    rgb = (128, 128, 128)
                }
                out[o] = rgb.0; out[o + 1] = rgb.1; out[o + 2] = rgb.2; out[o + 3] = 255
            }
        }
        return out
    }

    /// The same for an image's own colors: `channel(r, c, k)` for red, green and blue, each 0…1.
    static func image(width: Int, height: Int, rows: Int, cols: Int, top: Double, left: Double, spanRows: Double, spanCols: Double,
                      channel: (Int, Int, Int) -> Double?) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: Swift.max(width * height * 4, 0))
        guard width > 0, height > 0, rows > 0, cols > 0 else { return out }
        let colOf = (0..<width).map { x in Int((left + (Double(x) + 0.5) / Double(width) * spanCols).rounded(.down)) }
        for y in 0..<height {
            let r = Int((top + (Double(y) + 0.5) / Double(height) * spanRows).rounded(.down))
            guard r >= 0, r < rows else { continue }
            var o = y * width * 4
            for x in 0..<width {
                defer { o += 4 }
                let c = colOf[x]
                guard c >= 0, c < cols else { continue }
                for k in 0..<3 {
                    let v = channel(r, c, k) ?? 0.5
                    out[o + k] = UInt8(Swift.max(0, Swift.min(255, (v * 255).rounded())))
                }
                out[o + 3] = 255
            }
        }
        return out
    }

    /// Round numbers along an axis from `lo` to `hi`, about `count` of them: steps of 1, 2 or 5 times a power of ten
    /// (whole numbers only, for an axis of indices).
    static func ticks(_ lo: Double, _ hi: Double, count: Int, whole: Bool = false) -> [Double] {
        guard lo.isFinite, hi.isFinite, hi > lo, count > 0 else { return lo.isFinite ? [lo] : [] }
        let raw = (hi - lo) / Double(count)
        let magnitude = pow(10, (Foundation.log10(raw) + 1e-9).rounded(.down))
        let n = raw / magnitude
        var step = (n < 1.5 ? 1 : n < 3 ? 2 : n < 7 ? 5 : 10) * magnitude
        if whole { step = max(step.rounded(), 1) }
        var out: [Double] = []
        // Each a whole number of steps, not added up (0.2 added ten times isn't quite 2).
        var k = (lo / step - 1e-9).rounded(.up)
        while out.count < 100 {
            let v = k * step
            guard v <= hi + step * 1e-9 else { break }
            // Rounded to twelve figures, so 3 × 0.1 shows as 0.3.
            out.append(abs(v) < step * 1e-9 ? 0 : Double(String(format: "%.12g", v)) ?? v)
            k += 1
        }
        return out
    }

    /// A value short enough for an axis or a readout: whole numbers as they are, others to four significant figures.
    static func short(_ v: Double) -> String {
        if v.isNaN { return "nan" }
        if v.isInfinite { return v < 0 ? "-inf" : "inf" }
        if v == v.rounded(), abs(v) < 1e7 { return String(Int64(v)) }
        return String(format: "%.4g", v)
    }
}
