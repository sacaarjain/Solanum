import AppKit
import simd

/// The Outer Wilds planets, rendered pixel by pixel: lit spheres textured with procedural noise (terrain, craters,
/// cloud bands, cracked crust, fog), atmospheres and glows, plus vines, shell slabs, sand and comet tails. The theme's
/// planet sits in the status bar beside its name, as a still icon.
enum PlanetArt {
    enum Planet: String, CaseIterable {
        case hourglass = "Hourglass", timberHearth = "Timber Hearth", attlerock = "Attlerock", brittleHollow = "Brittle Hollow"
        case giantsDeep = "Giant's Deep", darkBramble = "Dark Bramble", interloper = "Interloper", quantumMoon = "Quantum Moon"
    }

    /// The planet a theme is named after: a built-in planet theme, or a custom one whose name contains a planet's
    /// (e.g. "My Hourglass").
    static func planet(for theme: Theme) -> Planet? {
        if ThemeLibrary.isVSCode(theme) { return nil }
        return Planet.allCases.first { theme.name.localizedCaseInsensitiveContains($0.rawValue) }
    }

    // MARK: Drawing

    /// Draws `planet` centered in `rect` (in a y-up context), rendered once per size and cached. An `icon` is just
    /// the planet (both twins for Hourglass) filling the square, without moons or the Lantern.
    static func draw(_ planet: Planet, in ctx: CGContext, rect: CGRect, icon: Bool = false) {
        let t = ctx.userSpaceToDeviceSpaceTransform
        let scale = max(1, CGFloat(hypot(Double(t.a), Double(t.b))))
        let side = min(rect.width, rect.height)
        let px = Int((side * scale).rounded())
        guard px >= 8, px <= 1200, let img = image(planet, pixels: px, icon: icon) else { return }
        // Rendered at the exact device size, so it lands on whole pixels unscaled and stays sharp.
        var frame = ctx.convertToDeviceSpace(CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side))
        frame.origin = CGPoint(x: frame.minX.rounded(), y: frame.minY.rounded())
        frame.size = CGSize(width: px, height: px)
        ctx.saveGState()
        ctx.interpolationQuality = .high
        ctx.draw(img, in: ctx.convertToUserSpace(frame))
        ctx.restoreGState()
    }

    private static var cache: [String: CGImage] = [:]

    private static func image(_ planet: Planet, pixels: Int, icon: Bool) -> CGImage? {
        let key = "\(planet.rawValue)|\(pixels)|\(icon)"
        if let c = cache[key] { return c }
        let img = render(planet, pixels: pixels, icon: icon)
        if cache.count > 24 { cache.removeAll() }
        cache[key] = img
        return img
    }

    // MARK: Math

    typealias V2 = SIMD2<Float>
    typealias V3 = SIMD3<Float>
    /// Premultiplied RGBA.
    typealias C4 = SIMD4<Float>

    @inline(__always) private static func rgb(_ hex: UInt32) -> V3 {
        V3(Float((hex >> 16) & 0xFF), Float((hex >> 8) & 0xFF), Float(hex & 0xFF)) / 255
    }
    @inline(__always) private static func clamp01(_ x: Float) -> Float { min(1, max(0, x)) }
    @inline(__always) private static func smooth(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
        let t = clamp01((x - e0) / (e1 - e0))
        return t * t * (3 - 2 * t)
    }
    @inline(__always) private static func mix(_ a: V3, _ b: V3, _ t: Float) -> V3 { a + (b - a) * t }
    /// `top` over `bottom`.
    @inline(__always) private static func over(_ top: C4, _ bottom: C4) -> C4 { top + bottom * (1 - top.w) }
    @inline(__always) private static func paint(_ c: V3, _ a: Float) -> C4 { C4(c * a, a) }

    private static func rotation(_ x: Float, _ y: Float, _ z: Float) -> simd_float3x3 {
        let rx = simd_float3x3(rows: [V3(1, 0, 0), V3(0, cos(x), -sin(x)), V3(0, sin(x), cos(x))])
        let ry = simd_float3x3(rows: [V3(cos(y), 0, sin(y)), V3(0, 1, 0), V3(-sin(y), 0, cos(y))])
        let rz = simd_float3x3(rows: [V3(cos(z), -sin(z), 0), V3(sin(z), cos(z), 0), V3(0, 0, 1)])
        return rz * ry * rx
    }

    // MARK: Noise

    @inline(__always) private static func hash(_ x: Int32, _ y: Int32, _ z: Int32, _ s: Int32) -> Float {
        var h = UInt32(bitPattern: x &* 374_761_393) &+ UInt32(bitPattern: y &* 668_265_263)
        h = h &+ UInt32(bitPattern: z &* 1_440_662_683) &+ UInt32(bitPattern: s &* 1_274_126_177)
        h = (h ^ (h >> 13)) &* 1_274_126_177
        h ^= h >> 16
        return Float(h & 0xFFFFFF) / 16_777_215
    }

    /// Smooth value noise in -1…1.
    private static func noise(_ p: V3, _ s: Int32) -> Float {
        let f = floor(p)
        let t = p - f
        let w = t * t * (3 - 2 * t)
        let x = Int32(f.x), y = Int32(f.y), z = Int32(f.z)
        let a = hash(x, y, z, s), b = hash(x + 1, y, z, s), c = hash(x, y + 1, z, s), d = hash(x + 1, y + 1, z, s)
        let e = hash(x, y, z + 1, s), g = hash(x + 1, y, z + 1, s), h = hash(x, y + 1, z + 1, s), k = hash(x + 1, y + 1, z + 1, s)
        let ab = a + (b - a) * w.x, cd = c + (d - c) * w.x, eg = e + (g - e) * w.x, hk = h + (k - h) * w.x
        let l1 = ab + (cd - ab) * w.y, l2 = eg + (hk - eg) * w.y
        return (l1 + (l2 - l1) * w.z) * 2 - 1
    }

    /// Fractal noise, roughly -1…1.
    private static func fbm(_ p: V3, _ octaves: Int, _ s: Int32, gain: Float = 0.5) -> Float {
        var sum: Float = 0, amp: Float = 0.5, norm: Float = 0, q = p
        for i in 0..<octaves {
            sum += amp * noise(q, s &+ Int32(i) &* 31)
            norm += amp
            amp *= gain
            q = q * 2.03 + V3(1.7, 9.2, 3.1)
        }
        return sum / norm
    }

    /// Cellular noise: distance to the nearest and second-nearest feature point, the nearest one's id (0…1),
    /// and the offset from `p` to it.
    private static func worley(_ p: V3, _ s: Int32) -> (f1: Float, f2: Float, id: Float, to: V3) {
        let f = floor(p)
        var d1: Float = 9, d2: Float = 9, id: Float = 0, to = V3.zero
        let bx = Int32(f.x), by = Int32(f.y), bz = Int32(f.z)
        for dz in Int32(-1)...1 {
            for dy in Int32(-1)...1 {
                for dx in Int32(-1)...1 {
                    let cx = bx + dx, cy = by + dy, cz = bz + dz
                    let pt = V3(Float(cx) + hash(cx, cy, cz, s), Float(cy) + hash(cx, cy, cz, s &+ 1), Float(cz) + hash(cx, cy, cz, s &+ 2))
                    let v = pt - p
                    let d = simd_length(v)
                    if d < d1 {
                        d2 = d1; d1 = d; id = hash(cx, cy, cz, s &+ 3); to = v
                    } else if d < d2 {
                        d2 = d
                    }
                }
            }
        }
        return (d1, d2, id, to)
    }

    /// Rotates `p` around `axis` by an angle that fades with distance from it: a cyclone.
    private static func twist(_ p: V3, _ axis: V3, _ strength: Float, _ radius: Float) -> V3 {
        let d = 1 - simd_dot(p, axis)
        let a = strength * exp(-d / radius)
        let c = cos(a), s = sin(a)
        return p * c + simd_cross(axis, p) * s + axis * simd_dot(axis, p) * (1 - c)
    }

    // MARK: Spheres

    private struct Ball {
        let c: V2
        let r: Float
        /// Turns the view-space surface normal into texture space, so each planet shows a chosen face.
        let spin: simd_float3x3
    }

    private struct Hit {
        /// View-space normal (z toward the viewer) and the texture-space point.
        let n: V3
        let p: V3
        /// How much of the pixel the ball covers (antialiased edge).
        let cover: Float
    }

    @inline(__always) private static func hit(_ b: Ball, _ u: Float, _ v: Float, _ px: Float) -> Hit? {
        let dx = (u - b.c.x) / b.r, dy = (v - b.c.y) / b.r
        let d = (dx * dx + dy * dy).squareRoot()
        let cover = clamp01((1 - d) * b.r / px + 0.5)
        guard cover > 0 else { return nil }
        let n = simd_normalize(V3(dx, dy, max(0, 1 - min(1, d * d)).squareRoot() + 0.0001))
        return Hit(n: n, p: b.spin * n, cover: cover)
    }

    /// Soft-terminator diffuse light.
    @inline(__always) private static func diffuse(_ n: V3, _ l: V3) -> Float {
        let x = simd_dot(n, l)
        return smooth(-0.18, 1, x) * 1.08
    }

    /// Atmosphere scattering at the limb, strongest on the lit side.
    @inline(__always) private static func rim(_ n: V3, _ l: V3) -> Float {
        pow(1 - n.z, 2.6) * smooth(-0.35, 0.6, simd_dot(n, l))
    }

    /// Glow just outside a ball, brighter toward the light.
    private static func halo(_ b: Ball, _ u: Float, _ v: Float, _ l: V3, _ color: V3, width: Float, strength: Float) -> C4 {
        let dx = u - b.c.x, dy = v - b.c.y
        let d = (dx * dx + dy * dy).squareRoot() / b.r
        guard d > 0.9, d < 1 + width else { return .zero }
        let fade = pow(1 - clamp01((d - 1) / width), 2.2)
        let facing = 0.3 + 0.7 * smooth(-0.5, 0.8, (dx * l.x + dy * l.y) / max(0.0001, (dx * dx + dy * dy).squareRoot()) / max(0.0001, simd_length(V2(l.x, l.y))))
        return paint(color, clamp01(fade * facing * strength))
    }

    /// Craters at three sizes, as a brightness shift and a tilted normal (bowls lit on the side away from the light).
    private static func craters(_ p: V3, _ n: V3, _ spin: simd_float3x3, _ s: Int32, density: Float = 0.45, depth: Float = 1) -> (shade: Float, n: V3) {
        var shade: Float = 0
        var tilt = V3.zero
        let sizes: [(scale: Float, weight: Float)] = [(2.6, 1), (5.5, 0.7), (11, 0.45)]
        for (i, (scale, weight)) in sizes.enumerated() {
            let w = worley(p * scale, s &+ Int32(i) &* 7)
            guard w.id < density else { continue }
            let radius: Float = 0.22 + 0.22 * (w.id / density)
            let x = w.f1 / radius
            guard x < 1.35 else { continue }
            // Direction toward the crater's center, back in view space.
            let toward = spin.transpose * simd_normalize(w.to)
            if x < 1 {
                shade -= 0.08 * weight * depth * (1 - x * x)
                tilt += toward * (0.9 * weight * depth * smooth(0.35, 1, x))
            } else {
                let rim: Float = weight * depth * (1 - (x - 1) / 0.35)
                shade += 0.07 * rim
                tilt -= toward * (0.5 * rim)
            }
        }
        let tangent = tilt - n * simd_dot(tilt, n)
        return (shade, simd_normalize(n + tangent * 0.8))
    }

    // MARK: Rendering

    private typealias Shader = (_ u: Float, _ v: Float, _ px: Float) -> C4

    /// The planet in a square of `S` pixels.
    private static func render(_ planet: Planet, pixels S: Int, icon: Bool) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        // Small ones take several samples per pixel, so fine detail blends instead of sparkling.
        return shade(scene(planet, icon: icon).pixel, S, samples: S < 64 ? 5 : S < 200 ? 3 : 1, space)
    }

    /// Shades each pixel as the average of `samples`² points spread across it.
    private static func shade(_ f: @escaping Shader, _ S: Int, samples n: Int, _ space: CGColorSpace) -> CGImage? {
        var data = [UInt8](repeating: 0, count: S * S * 4)
        let px: Float = 2 / Float(S)
        let sub = px / Float(n)
        data.withUnsafeMutableBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            DispatchQueue.concurrentPerform(iterations: S) { j in
                for i in 0..<S {
                    var sum = C4.zero
                    for sj in 0..<n {
                        let v = 1 - (Float(j) * px + (Float(sj) + 0.5) * sub)
                        for si in 0..<n {
                            let u = Float(i) * px + (Float(si) + 0.5) * sub - 1
                            sum += simd_clamp(f(u, v, sub), C4.zero, C4(repeating: 1))
                        }
                    }
                    let c = sum / Float(n * n)
                    let o = (j * S + i) * 4
                    base[o] = UInt8(min(c.x, c.w) * 255 + 0.5)
                    base[o + 1] = UInt8(min(c.y, c.w) * 255 + 0.5)
                    base[o + 2] = UInt8(min(c.z, c.w) * 255 + 0.5)
                    base[o + 3] = UInt8(c.w * 255 + 0.5)
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(data) as CFData) else { return nil }
        return CGImage(width: S, height: S, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: S * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private struct Scene {
        let pixel: Shader
    }

    private static func scene(_ planet: Planet, icon: Bool) -> Scene {
        switch planet {
        case .hourglass: return hourglass(icon)
        case .timberHearth: return timberHearth(icon)
        case .attlerock: return attlerock(icon)
        case .brittleHollow: return brittleHollow(icon)
        case .giantsDeep: return giantsDeep(icon)
        case .darkBramble: return darkBramble(icon)
        case .interloper: return interloper(icon)
        case .quantumMoon: return quantumMoon(icon)
        }
    }

    // MARK: The planets

    /// A grey cratered moon's surface color at a hit.
    private static func moonRock(_ h: Hit, _ ball: Ball, _ l: V3, _ s: Int32, tint: V3 = V3(1, 0.985, 0.96)) -> V3 {
        let (cs, n) = craters(h.p, h.n, ball.spin, s)
        let tone = 0.56 + 0.1 * fbm(h.p * 3, 5, s &+ 50) + 0.05 * fbm(h.p * 14, 3, s &+ 60) + cs
        // Maria: broad darker plains.
        let maria = smooth(0.05, 0.35, fbm(h.p * 1.4, 4, s &+ 70)) * 0.13
        return V3(repeating: max(0.05, tone - maria)) * tint * (0.04 + diffuse(n, l))
    }

    // Home: pine forest and tan rock, red canyon walls, a few lakes, geyser steam and a thin blue sky. Attlerock in orbit.
    private static func timberHearth(_ icon: Bool) -> Scene {
        let l = simd_normalize(V3(-0.62, 0.42, 0.66))
        let th = Ball(c: icon ? .zero : V2(-0.1, -0.08), r: icon ? 0.92 : 0.7, spin: rotation(0.5, 0.9, 0.15))
        let moon = Ball(c: V2(0.64, 0.62), r: 0.15, spin: rotation(1.1, 0.3, 0.4))
        let sky = rgb(0x9CCBFF)
        return Scene(pixel: { u, v, px in
            var out = halo(th, u, v, l, sky, width: 0.1, strength: 0.6)
            if let h = hit(th, u, v, px) {
                let p = h.p
                let elev = fbm(p * 2.1, 6, 11)
                let detail = fbm(p * 10, 4, 12)
                let canyon = smooth(0.9, 0.97, 1 - abs(fbm(p * 1.7 + V3(5, 1, 2), 4, 13)))
                var a: V3
                var spec: Float = 0
                if elev < -0.42 {
                    a = mix(rgb(0x24496A), rgb(0x3A6E96), smooth(-0.7, -0.42, elev))
                    spec = 0.4
                } else {
                    let forest = mix(rgb(0x233F21), rgb(0x47703A), 0.5 + 0.5 * detail)
                    let rock = mix(rgb(0x7A6D5E), rgb(0xA89478), 0.5 + 0.5 * fbm(p * 6, 3, 16))
                    a = mix(forest, rock, smooth(0.08, 0.34, elev + detail * 0.2))
                    a = mix(a, rgb(0x8A4E33), canyon * 0.75)
                    a = mix(rgb(0x9C9070), a, smooth(-0.42, -0.36, elev))
                }
                let lit = a * (0.04 + diffuse(h.n, l))
                let r = simd_reflect(-l, h.n)
                let gloss = spec * pow(max(0, r.z), 28) * smooth(0, 0.3, simd_dot(h.n, l))
                let warp = V3(fbm(p * 2, 3, 17), fbm(p * 2 + 4, 3, 18), 0) * 0.5
                let cloud = smooth(0.28, 0.6, fbm(p * 2.6 + warp, 5, 14)) * 0.7
                var c = mix(lit + V3(repeating: gloss), V3(repeating: 1) * (0.06 + diffuse(h.n, l)), cloud)
                c += sky * rim(h.n, l) * 0.6
                out = over(paint(c, h.cover), out)
            }
            if !icon, let h = hit(moon, u, v, px) {
                out = over(paint(moonRock(h, moon, l, 21), h.cover), out)
            }
            return out
        })
    }

    // Timber Hearth's moon: grey, deeply cratered.
    private static func attlerock(_ icon: Bool) -> Scene {
        let l = simd_normalize(V3(-0.6, 0.5, 0.62))
        let moon = Ball(c: .zero, r: icon ? 0.96 : 0.86, spin: rotation(0.3, 1.2, 0))
        return Scene(pixel: { u, v, px in
            guard let h = hit(moon, u, v, px) else { return .zero }
            return paint(moonRock(h, moon, l, 31), h.cover)
        })
    }

    // Twin desert planets: Ash Twin's pale sand pours across onto Ember Twin's red rock.
    private static func hourglass(_ icon: Bool) -> Scene {
        let l = simd_normalize(V3(-0.85, 0.15, 0.5))
        let ash = Ball(c: icon ? V2(-0.55, 0.53) : V2(-0.48, 0.44), r: icon ? 0.42 : 0.36, spin: rotation(0.2, 0.6, 0.3))
        let ember = Ball(c: icon ? V2(0.32, -0.32) : V2(0.28, -0.26), r: icon ? 0.62 : 0.54, spin: rotation(0.9, 2.1, 0.1))
        // The sand column: from Ash Twin's near side to where it lands on Ember Twin.
        let a = ash.c + simd_normalize(ember.c - ash.c) * ash.r * 0.92
        let b = ember.c + simd_normalize(V2(-0.62, 0.78)) * ember.r * 0.94
        let ctrl = (a + b) / 2 + V2(0.06, 0.08)
        let samples = 40
        let curve: [V2] = (0...samples).map { i in
            let t = Float(i) / Float(samples)
            return a * (1 - t) * (1 - t) + ctrl * 2 * (1 - t) * t + b * t * t
        }
        let landing = simd_normalize(V3(-0.62, 0.78, 0.5))
        return Scene(pixel: { u, v, px in
            var out = halo(ember, u, v, l, rgb(0xFF9A5A), width: 0.08, strength: 0.4)
            out = over(halo(ash, u, v, l, rgb(0xFFD49A), width: 0.1, strength: 0.4), out)
            if let h = hit(ember, u, v, px) {
                let (cs, n) = craters(h.p, h.n, ember.spin, 41, density: 0.3, depth: 0.7)
                let rock = mix(rgb(0x8A3A20), rgb(0xC9673C), 0.5 + 0.5 * fbm(h.p * 3, 5, 42))
                let canyon = smooth(0.8, 0.94, 1 - abs(fbm(h.p * 2.2, 4, 43)))
                var c = mix(rock, rgb(0x4E1E10), canyon * 0.8) * (1 + cs * 2)
                // Sand drifts where the column lands, and cactus specks.
                let drift = smooth(0.55, 0.85, simd_dot(h.n, landing) + 0.15 * fbm(h.p * 6, 3, 44))
                c = mix(c, rgb(0xE2B57A), drift)
                let cact = worley(h.p * 30, 45)
                if cact.f1 < 0.12, cact.id > 0.7 { c = mix(c, rgb(0x6F8A3A), 0.8 * (1 - drift)) }
                c = c * (0.03 + diffuse(n, l)) + rgb(0xFFB070) * rim(h.n, l) * 0.35
                out = over(paint(c, h.cover), out)
            }
            // The column, shaded as a twisting rope of sand.
            var best: Float = 9, bestT: Float = 0, side: Float = 0
            for i in 0..<samples {
                let p0 = curve[i], p1 = curve[i + 1]
                let e = p1 - p0
                let t = clamp01(simd_dot(V2(u, v) - p0, e) / simd_dot(e, e))
                let q = p0 + e * t
                let d = simd_length(V2(u, v) - q)
                if d < best {
                    best = d
                    bestT = (Float(i) + t) / Float(samples)
                    let nrm = V2(-e.y, e.x) / simd_length(e)
                    side = simd_dot(V2(u, v) - q, nrm)
                }
            }
            let w = (icon ? 0.05 : 0.075) * (1 - 0.4 * sin(.pi * bestT))
            if best < w + px {
                let cover = clamp01((w - best) / px + 0.5) * (0.82 + 0.18 * smooth(-0.3, 0.3, fbm(V3(bestT * 18, side / w * 2, 0), 3, 46)))
                let s = max(-1, min(1, side / w))
                let n = simd_normalize(V3(s * 0.6, s * 0.8, (1 - s * s).squareRoot() + 0.1))
                let streak = 0.85 + 0.15 * fbm(V3(bestT * 30, s * 4, 1), 3, 47)
                let c = rgb(0xE9BE82) * streak * (0.1 + diffuse(n, l))
                out = over(paint(c, cover), out)
            }
            if let h = hit(ash, u, v, px) {
                let dunes = sin((h.p.x * 0.6 + h.p.z) * 38 + fbm(h.p * 4, 3, 48) * 6) * 0.05
                let sand = mix(rgb(0xD8A060), rgb(0xF0CE96), 0.5 + 0.5 * fbm(h.p * 3, 4, 49)) * (1 + dunes)
                let c = sand * (0.05 + diffuse(h.n, l)) + rgb(0xFFD8A0) * rim(h.n, l) * 0.35
                out = over(paint(c, h.cover), out)
            }
            return out
        })
    }

    // Slate crust broken into angular plates, a snowfield on the sunlit side, and a great hole fallen in at the
    // middle: blue rubble lit red, red rock walls, and at its heart the black hole with its glowing ring.
    private static func brittleHollow(_ icon: Bool) -> Scene {
        let l = simd_normalize(V3(0.45, 0.4, 0.8))
        let bh = Ball(c: .zero, r: icon ? 0.92 : 0.86, spin: rotation(0.2, 0.4, 0.1))
        let snowDir = simd_normalize(V3(0.66, 0.66, 0.36))
        // The hole: a jagged outline (radii at evenly spaced angles) around `hc`, in units of the ball's radius.
        let hc = V2(-0.02, -0.06), hr = V2(0.48, 0.6)
        let edges: [Float] = (0..<13).map { 0.8 + 0.28 * hash(Int32($0), 3, 7, 160) }
        func outline(_ angle: Float) -> Float {
            let x = (angle / (2 * .pi) + 1).truncatingRemainder(dividingBy: 1) * Float(edges.count)
            let i = Int(x) % edges.count, f = x - floor(x)
            return edges[i] + (edges[(i + 1) % edges.count] - edges[i]) * f
        }
        let core = V2(-0.1, 0.07)
        return Scene(pixel: { u, v, px in
            let out = halo(bh, u, v, V3(0, 0, 1), rgb(0x4A38C8), width: 0.08, strength: 0.75)
            guard let h = hit(bh, u, v, px) else { return out }
            let q = (V2(u, v) - bh.c) / bh.r
            let e = (q - hc) / hr
            let reach = outline(atan2(e.y, e.x))
            let depth = (reach - simd_length(e)) / reach   // > 0 inside the hole, 1 at its center
            // The crust: plates split along straight faults, with finer cracks inside them.
            let p = h.p
            let plates = worley(p * 3.6 + V3(fbm(p * 2, 2, 161), fbm(p * 2 + 3, 2, 162), 0) * 0.25, 163)
            func spinTo(_ t: V3) -> V3 { simd_normalize(bh.spin.transpose * t) }
            let chips = worley(p * 8.5, 164)
            var rock = mix(rgb(0x343A50), rgb(0x5E6884), 0.5 + 0.5 * fbm(p * 5, 4, 165)) * (0.72 + 0.5 * plates.id)
            // Each plate's broken edge catches a little light before the fault.
            let lip = smooth(0.1, 0.04, plates.f2 - plates.f1) * smooth(0.0, 0.5, simd_dot(spinTo(plates.to), V3(-l.x, -l.y, 0)))
            rock *= (1 + 0.35 * lip) * (0.25 + 0.75 * smooth(0.015, 0.05, plates.f2 - plates.f1))
            rock *= 0.6 + 0.4 * smooth(0.01, 0.035, chips.f2 - chips.f1)
            // Snow on the sunlit side, with dark blocks of rock poking through.
            let snowy = smooth(0.64, 0.7, simd_dot(h.n, snowDir) + 0.08 * fbm(p * 4, 3, 166))
            let blocks = worley(p * 9, 167)
            let bare = blocks.id < 0.3 && blocks.f1 < 0.3 ? smooth(0.3, 0.24, blocks.f1) : 0
            var snow = mix(rgb(0xBDBCD6), rgb(0xE2E0EE), 0.5 + 0.5 * fbm(p * 6, 3, 168))
            snow *= 0.75 + 0.25 * smooth(0.005, 0.03, plates.f2 - plates.f1)
            var c = mix(rock, mix(snow, rock * 0.8, bare), snowy) * (0.3 + 0.8 * diffuse(h.n, l))
            // The crust's broken edge throws a shadow just outside the hole.
            c *= 0.45 + 0.55 * smooth(-0.1, 0, depth)
            c += rgb(0x5A48E0) * rim(h.n, V3(0, 0, 1)) * 0.6
            if depth > -0.02 {
                let d = simd_length(q - core)
                // Rubble inside: blue-violet fragments, their edges lit red by the ring.
                let frag = worley(V3(q.x * 7, q.y * 7, 0.5), 169)
                var inside = mix(rgb(0x1A1850), rgb(0x4644B4), frag.id) * (0.7 + 0.4 * fbm(V3(q.x, q.y, 1) * 12, 2, 170))
                let seam = 1 - smooth(0.02, 0.09, frag.f2 - frag.f1)
                inside = mix(inside, rgb(0xE04A22), seam * exp(-max(0, d - 0.18) * 7))
                // Cliffs around the rim: red rock in strata on the lower right, in shadow on the upper left.
                let toward = simd_normalize(e)
                let warm = smooth(-0.4, 0.5, simd_dot(toward, simd_normalize(V2(0.7, -0.6))))
                let wall = 1 - smooth(0.1 + 0.12 * warm, 0.16 + 0.14 * warm, depth)
                let strata = 0.8 + 0.2 * sin(depth * 70 + fbm(V3(q.x, q.y, 2) * 6, 2, 171) * 3)
                inside = mix(inside, mix(rgb(0x1C1E2A), rgb(0x9A3E26) * strata, warm), wall)
                // The black hole and its ring.
                let ring = exp(-pow((d - 0.13) / 0.035, 2)) + 0.45 * exp(-pow((d - 0.18) / 0.05, 2))
                let swirl = 0.75 + 0.25 * fbm(V3(atan2(q.y - core.y, q.x - core.x) * 2, d * 25, 3), 3, 172)
                inside = mix(inside, mix(rgb(0xC0181C), rgb(0xFF7A5A), smooth(0.6, 1, ring)), clamp01(ring * swirl))
                inside *= smooth(0.095, 0.115, d)
                c = mix(c, inside, clamp01(depth * reach * min(hr.x, hr.y) * bh.r / px + 0.5))
            }
            return over(paint(c, h.cover), out)
        })
    }

    // A green ocean world under streaming cloud bands, spun into cyclones.
    private static func giantsDeep(_ icon: Bool) -> Scene {
        let l = simd_normalize(V3(-0.58, 0.4, 0.7))
        let gd = Ball(c: .zero, r: icon ? 0.92 : 0.84, spin: rotation(0.25, 0.3, -0.15))
        let eyes = [simd_normalize(V3(0.4, 0.35, 0.85)), simd_normalize(V3(-0.5, -0.4, 0.75)), simd_normalize(V3(0.1, -0.7, 0.7))]
        return Scene(pixel: { u, v, px in
            var out = halo(gd, u, v, l, rgb(0x7CF0C4), width: 0.1, strength: 0.5)
            if let h = hit(gd, u, v, px) {
                var q = h.p
                q = twist(q, eyes[0], 4.2, 0.03)
                q = twist(q, eyes[1], -3.6, 0.025)
                q = twist(q, eyes[2], 3, 0.02)
                let warp = V3(fbm(q * 2, 4, 71), fbm(q * 2 + 5, 4, 72), 0) * 0.35
                let band = sin((q.y + warp.x) * 9 + fbm(q * 3, 4, 73) * 2.2)
                let cloud = fbm(V3(q.x * 1.3, q.y * 5, q.z * 1.3) + warp, 5, 74)
                var a = mix(rgb(0x17614F), rgb(0x3E9E78), 0.5 + 0.3 * band)
                a = mix(a, rgb(0xCDEFD6), smooth(0.12, 0.55, cloud) * 0.75)
                a = mix(a, rgb(0x0B3A31), smooth(-0.1, -0.5, cloud) * 0.7)
                var c = a * (0.04 + diffuse(h.n, l))
                c += rgb(0x8FFFD6) * rim(h.n, l) * 0.55
                out = over(paint(c, h.cover), out)
            }
            return out
        })
    }

    // A dense tangle of twisted brown vines around a white light, held in a ring of broken slabs of its icy shell.
    private static func darkBramble(_ icon: Bool) -> Scene {
        let l = simd_normalize(V2(0.35, 0.94))
        // The shell's slabs: center angle, half-width (radians), and inner and outer radius.
        let slabs: [(a: Float, w: Float, r0: Float, r1: Float)] = [
            (1.6, 0.48, 0.58, 0.98), (2.62, 0.3, 0.6, 0.86), (3.42, 0.28, 0.56, 0.92), (4.2, 0.3, 0.62, 0.88),
            (4.95, 0.44, 0.57, 0.97), (5.85, 0.28, 0.62, 0.86), (0.42, 0.36, 0.58, 0.92),
        ]
        let strands: [V2] = [0.3, 1.35, 2.4].map { V2(cos($0), sin($0)) }
        return Scene(pixel: { u, v, px in
            let q = V2(u, v)
            let d = simd_length(q)
            let angle = atan2(v, u)
            // The light inside, haze around it.
            var out = paint(rgb(0xB4B4AC), clamp01(0.5 * exp(-d / 0.28)))
            // Vines: three layers of wavy strands, each shaded round and twisted.
            // A rough ball, with arms reaching out to hold each slab.
            let arm = slabs.map { s -> Float in
                var da = angle - s.a
                da -= 2 * .pi * (da / (2 * .pi)).rounded()
                return smooth(s.w * 1.1, s.w * 0.3, abs(da)) * (s.r0 + 0.14)
            }.max() ?? 0
            let edge = max(0.6, arm) + 0.05 * fbm(V3(cos(angle), sin(angle), 0) * 2.5, 3, 180)
            if d < edge + px {
                var vine: Float = 0, shade: Float = 0
                for (k, dir) in strands.enumerated() {
                    let warp = fbm(V3(q.x, q.y, Float(k)) * 3, 3, 181 &+ Int32(k)) * 1.6
                    let phase = simd_dot(q, dir) * 6.5 + warp
                    let ridge = 1 - abs((phase - floor(phase)) * 2 - 1)
                    let rope = smooth(0.45, 0.68, ridge)
                    if rope > vine {
                        let twist = 0.7 + 0.3 * sin(simd_dot(q, V2(-dir.y, dir.x)) * 70 + phase * 9)
                        vine = rope
                        shade = ridge.squareRoot() * twist
                    }
                }
                var c = mix(rgb(0x1E120A), rgb(0x6E4628), shade)
                // Darker against the light at the middle.
                c *= 0.55 + 0.45 * smooth(0.12, 0.45, d)
                let gaps = mix(rgb(0x0C0806), rgb(0x8A8A82) * exp(-d / 0.2), smooth(0.4, 0.1, d))
                let body = clamp01((edge - d) / px + 0.5) * smooth(0.07, 0.18, d)
                out = over(paint(mix(gaps, c, vine), body * (0.75 + 0.25 * vine)), out)
            }
            // The white core.
            out = over(paint(rgb(0xF6F6F0), clamp01((0.075 - d) / px + 0.5) + clamp01(exp(-d / 0.06) * 0.6)), out)
            // The slabs, each a broken piece of the shell: dark underneath, icy blue-grey on top, pale at the rim.
            for (i, s) in slabs.enumerated() {
                var da = angle - s.a
                da -= 2 * .pi * (da / (2 * .pi)).rounded()
                let jag = 0.05 * fbm(V3(angle * 5, Float(i), 0), 2, 183)
                let r0 = s.r0 + jag, r1 = s.r1 + jag * 0.6
                // Fanning out from the vines: narrow where they hold it, broad at the rim.
                let w = s.w * (0.4 + 0.6 * smooth(0, 0.7, (d - r0) / (r1 - r0))) + 0.04 * sin(d * 18 + Float(i))
                let cover = clamp01(min(d - r0, r1 - d, (w - abs(da)) * d) / px + 0.5)
                guard cover > 0 else { continue }
                let t = clamp01((d - r0) / (r1 - r0))
                let facing = 0.55 + 0.45 * smooth(-0.6, 0.9, simd_dot(q / max(d, 0.0001), l))
                let grain = 0.8 + 0.3 * fbm(V3(angle * 7, d * 12, Float(i)), 3, 184)
                var c = mix(rgb(0x121A1C), rgb(0x46646A) * grain, smooth(0, 0.45, t)) * facing
                c = mix(c, rgb(0xA6D2CC) * facing, smooth(0.8, 0.98, t) * 0.75)
                out = over(paint(c, cover), out)
            }
            return out
        })
    }

    // The comet: a lumpy, icy nucleus with dark rock showing through, a glowing coma, and two tails streaming away
    // from the sun (a straight blue ion tail and a broader, curving white dust tail).
    private static func interloper(_ icon: Bool) -> Scene {
        let l = simd_normalize(V3(-0.6, -0.5, 0.62))
        // The icon's nucleus sits near the middle, level with the label beside it, under a flatter tail.
        let c0 = icon ? V2(-0.26, -0.1) : V2(-0.36, -0.38)
        let tailDir = simd_normalize(icon ? V2(0.8, 0.6) : V2(0.62, 0.78))
        let angle: Float = 0.55
        let rx: Float = icon ? 0.4 : 0.27, ry: Float = icon ? 0.32 : 0.19
        // The icon is mostly tail: wider and brighter, from a cleaner, icier nucleus.
        let tailW: Float = icon ? 1.9 : 1, tailA: Float = icon ? 1.35 : 1, rockA: Float = icon ? 0.45 : 0.85
        let spin = rotation(0.7, 0.4, 0.2)
        return Scene(pixel: { u, v, px in
            let rel = V2(u, v) - c0
            var out = C4.zero
            // The icon's glow fades out before the frame's edge instead of being cut off.
            let edge = icon ? smooth(1, 0.75, max(abs(u), abs(v))) : 1
            // Tails.
            let s = simd_dot(rel, tailDir)
            if s > -0.05 {
                let perp = rel.x * tailDir.y - rel.y * tailDir.x
                let sp = max(0, s)
                let ionW = (0.025 + 0.07 * sp) * tailW
                let streak = 0.7 + 0.3 * fbm(V3(perp / ionW * 2.5, sp * 1.5, 0), 3, 91)
                let ion = exp(-pow(perp / ionW, 2)) * pow(max(0, 1 - sp / 1.75), 1.3) * streak * 0.75
                let curved = perp + 0.22 * sp * sp
                let dustW = (0.05 + 0.17 * sp) * (icon ? 1.3 : 1)
                let dust = exp(-pow(curved / dustW, 2)) * pow(max(0, 1 - sp / 1.5), 1.6) * 0.6 * (0.8 + 0.2 * fbm(V3(curved / dustW * 1.5, sp * 2, 3), 3, 92))
                let fadeIn = smooth(-0.05, 0.15, s)
                let a = clamp01((ion + dust) * fadeIn * tailA)
                if a > 0.001 {
                    let col = (rgb(icon ? 0x5AAEFF : 0x86CCFF) * ion + rgb(0xF4F7FF) * dust) / max(0.0001, ion + dust)
                    out = over(paint(col, a * edge), out)
                }
            }
            // Coma.
            let r = simd_length(rel)
            out = over(paint(rgb(0xD8F0FF), clamp01(exp(-r / (icon ? 0.2 : 0.18)) * 0.55 * edge)), out)
            // Nucleus: a rotated, lumpy ellipsoid.
            let x = rel.x * cos(angle) + rel.y * sin(angle), y = -rel.x * sin(angle) + rel.y * cos(angle)
            let theta = atan2(y / ry, x / rx)
            let lump = 1 + 0.13 * fbm(V3(cos(theta) * 1.6, sin(theta) * 1.6, 0.5), 4, 93)
            let d = (pow(x / rx, 2) + pow(y / ry, 2)).squareRoot() / lump
            let cover = clamp01((1 - d) * ry * lump / px + 0.5)
            if cover > 0 {
                let z = max(0, 1 - min(1, d * d)).squareRoot()
                var n = simd_normalize(V3(x / (rx * lump), y / (ry * lump) * 1.2, z + 0.0001))
                n = V3(n.x * cos(angle) - n.y * sin(angle), n.x * sin(angle) + n.y * cos(angle), n.z)
                let p = spin * n
                let bump = V3(fbm(p * 6, 3, 94), fbm(p * 6 + 3, 3, 95), 0) * 0.25
                let nb = simd_normalize(n + bump)
                let rock = smooth(0.1, 0.35, fbm(p * 3.5, 5, 96))
                var a = mix(rgb(0xE4F2FA), rgb(0x3E4A58), rock * rockA)
                a = mix(a, rgb(0xB8DCF0), smooth(0.3, 0.6, fbm(p * 9, 3, 97)) * 0.3)
                var c = a * (0.05 + diffuse(nb, l))
                // Ghost matter glimmering in the dark side's cracks.
                if !icon { c += rgb(0x4CF0C0) * smooth(0.35, 0.6, fbm(p * 8, 3, 98)) * (1 - smooth(-0.2, 0.3, simd_dot(nb, l))) * 0.18 }
                c += rgb(0xCDEBFF) * rim(n, l) * 0.5
                out = over(paint(c, cover), out)
            }
            return out
        })
    }

    // Grey rock wrapped in a shifting shroud of grey-white fog.
    private static func quantumMoon(_ icon: Bool) -> Scene {
        let l = simd_normalize(V3(-0.55, 0.45, 0.7))
        let qm = Ball(c: .zero, r: icon ? 0.8 : 0.66, spin: rotation(0.6, 0.2, 0.3))
        return Scene(pixel: { u, v, px in
            var out = halo(qm, u, v, l, rgb(0xD6D7DC), width: 0.22, strength: 0.4)
            // Fog trailing beyond the limb.
            let dd = simd_length(V2(u, v) - qm.c) / qm.r
            if dd > 0.97, dd < 1.35 {
                let wisp = smooth(-0.1, 0.45, fbm(V3(u * 4.5, v * 4.5, 7) + V3(fbm(V3(u, v, 0) * 3, 3, 101), 0, 0), 5, 102))
                out = over(paint(rgb(0xCBCCD2) * 0.9, wisp * pow(1 - (dd - 0.97) / 0.38, 1.6) * 0.55), out)
            }
            if let h = hit(qm, u, v, px) {
                let (cs, n) = craters(h.p, h.n, qm.spin, 103, density: 0.35, depth: 0.8)
                let rock = mix(rgb(0x3E3E44), rgb(0x8C8C92), 0.5 + 0.5 * fbm(h.p * 3, 5, 104)) * (1 + cs * 1.5)
                let lit = rock * (0.04 + diffuse(n, l))
                let warp = V3(fbm(h.p * 1.8, 4, 105), fbm(h.p * 1.8 + 6, 4, 106), fbm(h.p * 1.8 + 11, 4, 107)) * 0.8
                let fog = smooth(-0.15, 0.45, fbm(h.p * 2.2 + warp, 5, 108)) * 0.8
                let fogCol = rgb(0xE2E3E8) * (0.12 + 0.95 * diffuse(h.n, l))
                var c = mix(lit, fogCol, fog)
                c += rgb(0xE8E8EE) * rim(h.n, l) * 0.45
                out = over(paint(c, h.cover), out)
            }
            return out
        })
    }
}
