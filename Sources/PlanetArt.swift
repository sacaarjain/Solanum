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

    /// The point on a polyline nearest `q`: its distance, how far along the line it is (0…1), which side `q` is on
    /// (signed distance along `normal`, the left of the direction of travel), and that normal.
    private static func nearest(_ q: V2, on line: [V2]) -> (d: Float, t: Float, side: Float, normal: V2) {
        var best: Float = .greatestFiniteMagnitude, t: Float = 0, side: Float = 0, normal = V2(0, 1)
        for i in 0..<(line.count - 1) {
            let p0 = line[i], e = line[i + 1] - p0
            let f: Float = clamp01(simd_dot(q - p0, e) / simd_dot(e, e))
            let to: V2 = q - (p0 + e * f)
            let d2: Float = simd_dot(to, to)
            if d2 < best {
                best = d2
                t = (Float(i) + f) / Float(line.count - 1)
                normal = V2(-e.y, e.x) / simd_length(e)
                side = simd_dot(to, normal)
            }
        }
        return (best.squareRoot(), t, side, normal)
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
        data.withUnsafeMutableBufferPointer { (buf: inout UnsafeMutableBufferPointer<UInt8>) in
            guard let base = buf.baseAddress else { return }
            DispatchQueue.concurrentPerform(iterations: S) { (j: Int) in
                for i in 0..<S {
                    var sum = C4.zero
                    for sj in 0..<n {
                        let y: Float = Float(j) * px + (Float(sj) + 0.5) * sub
                        let v: Float = 1 - y
                        for si in 0..<n {
                            let x: Float = Float(i) * px + (Float(si) + 0.5) * sub
                            let u: Float = x - 1
                            sum += simd_clamp(f(u, v, sub), C4.zero, C4(repeating: 1))
                        }
                    }
                    let c: C4 = sum / Float(n * n)
                    let o: Int = (j * S + i) * 4
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
        return Scene(pixel: { (u: Float, v: Float, px: Float) -> C4 in
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
        return Scene(pixel: { (u: Float, v: Float, px: Float) -> C4 in
            guard let h = hit(moon, u, v, px) else { return .zero }
            return paint(moonRock(h, moon, l, 31), h.cover)
        })
    }

    // Twin desert planets: Ash Twin's pale sand pours across onto Ember Twin's red rock.
    private static func hourglass(_ icon: Bool) -> Scene {
        let l = simd_normalize(V3(-0.85, 0.15, 0.5))
        let ash = Ball(c: icon ? V2(-0.6, 0.58) : V2(-0.54, 0.5), r: icon ? 0.38 : 0.33, spin: rotation(0.2, 0.6, 0.3))
        let ember = Ball(c: icon ? V2(0.34, -0.34) : V2(0.3, -0.28), r: icon ? 0.6 : 0.53, spin: rotation(0.9, 2.1, 0.1))
        // The sand column: from just inside Ash Twin's near side to where it lands on Ember Twin.
        let a = ash.c + simd_normalize(ember.c - ash.c) * ash.r * 0.8
        let b = ember.c + simd_normalize(V2(-0.62, 0.78)) * ember.r * 0.9
        let ctrl = (a + b) / 2 + V2(0.05, 0.07)
        let samples = 40
        let curve: [V2] = (0...samples).map { (i: Int) -> V2 in
            let t: Float = Float(i) / Float(samples)
            let s: Float = 1 - t
            return a * (s * s) + ctrl * (2 * s * t) + b * (t * t)
        }
        let landing = simd_normalize(V3(-0.62, 0.78, 0.5))
        let column: Float = icon ? 0.075 : 0.085
        return Scene(pixel: { (u: Float, v: Float, px: Float) -> C4 in
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
                // A puff of sand thrown up where the column lands.
                let puff = exp(-simd_length_squared(V2(u, v) - b) / 0.01)
                c = mix(c, rgb(0xE6BC84) * (0.25 + 0.8 * diffuse(h.n, l)), puff * 0.7)
                out = over(paint(c, h.cover), out)
            }
            // The column: a funnel drawn off Ash Twin that narrows to a twisting stream and spreads a little where it
            // lands, wrapped in helical bands, its edges dusty and slowly rippling.
            let (best, t, side, normal) = nearest(V2(u, v), on: curve)
            let w: Float = column * (0.4 + 0.6 * pow(1 - t, 2.4) + 0.22 * smooth(0.7, 1, t))
            if best < w * 1.2 + px {
                let s: Float = max(-1, min(1, side / w))
                // The edges ripple slowly, like a dust devil's.
                let fray: Float = 0.9 + 0.12 * fbm(V3(t * 9, s > 0 ? 1 : -1, 0), 2, 46)
                // Round across the column: the normal turns with the curve, so the light falls on the right side.
                let n: V3 = simd_normalize(V3(normal.x * s, normal.y * s, (1 - s * s).squareRoot() + 0.05))
                // Bands spiral around it, wound tighter where it narrows.
                let swirl: Float = t * 24 + t * t * 12 - asin(s) * 2.4 + fbm(V3(t * 5, s, 1), 2, 47) * 1.6
                let band: Float = smooth(-0.3, 0.7, sin(swirl)) * (0.6 + 0.4 * fbm(V3(t * 12, s * 2, 3), 2, 52))
                let sand: V3 = mix(rgb(0xF0CB92), rgb(0xB07A44), band * 0.55) * (0.93 + 0.12 * fbm(V3(t * 70, s * 5, 2), 2, 51))
                // Dusty at the edges rather than hard.
                let body: Float = smooth(w * fray + px, w * fray * 0.8, best)
                // Melts into the drift on landing instead of ending in a cap.
                let fade: Float = smooth(1, 0.82, t)
                out = over(paint(sand * (0.12 + diffuse(n, l)), body * fade), out)
            }
            if let h = hit(ash, u, v, px) {
                let ripple: Float = (h.p.x * 0.6 + h.p.z) * 38 + fbm(h.p * 4, 3, 48) * 6
                let dunes: Float = sin(ripple) * 0.05
                let sand: V3 = mix(rgb(0xD8A060), rgb(0xF0CE96), 0.5 + 0.5 * fbm(h.p * 3, 4, 49)) * (1 + dunes)
                let c: V3 = sand * (0.05 + diffuse(h.n, l)) + rgb(0xFFD8A0) * rim(h.n, l) * 0.35
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
        return Scene(pixel: { (u: Float, v: Float, px: Float) -> C4 in
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
        return Scene(pixel: { (u: Float, v: Float, px: Float) -> C4 in
            var out = halo(gd, u, v, l, rgb(0x7CF0C4), width: 0.1, strength: 0.5)
            if let h = hit(gd, u, v, px) {
                var q = h.p
                q = twist(q, eyes[0], 4.2, 0.03)
                q = twist(q, eyes[1], -3.6, 0.025)
                q = twist(q, eyes[2], 3, 0.02)
                let warp: V3 = V3(fbm(q * 2, 4, 71), fbm(q * 2 + 5, 4, 72), 0) * 0.35
                let stripe: Float = (q.y + warp.x) * 9 + fbm(q * 3, 4, 73) * 2.2
                let band: Float = sin(stripe)
                let cloud: Float = fbm(V3(q.x * 1.3, q.y * 5, q.z * 1.3) + warp, 5, 74)
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

    // A knot of brown vines around a pale yellow light, curling out through a ring of broken slabs of its blue shell.
    // Drawn flat, like a sketch: each slab a dark inner face under a pale outer rim, brushed in strokes.
    private static func darkBramble(_ icon: Bool) -> Scene {
        // The slabs: center angle, half-width (radians), inner and outer radius, and where the pale rim begins (0…1).
        let slabs: [(a: Float, w: Float, r0: Float, r1: Float, rim: Float)] = [
            (1.75, 0.5, 0.6, 0.95, 0.62), (1.0, 0.16, 0.63, 0.85, 0.62), (0.22, 0.48, 0.57, 0.98, 0.42),
            (-0.8, 0.42, 0.6, 0.94, 0.55), (-2.25, 0.36, 0.62, 0.95, 0.58), (3.08, 0.12, 0.7, 0.9, 0.5),
        ]
        // The vines: each walks outward from the knot, its heading wavering and, on some, curling over at the tip.
        let count = 19
        let vines: [(line: [V2], w: Float, lo: V2, hi: V2)] = (0..<count).map { (k: Int) in
            let h = (0..<4).map { hash(Int32(k), Int32($0), 0, 185) }
            let start: Float = Float(k) / Float(count) * 2 * .pi + (h[0] - 0.5) * 0.3
            let length: Float = 0.4 + 0.45 * h[1]
            let curl: Float = (h[3] > 0.5 ? 1 : -1) * (h[2] > 0.55 ? 4.2 : 1)
            var p = V2(cos(start), sin(start)) * 0.08
            var line = [p]
            for i in 1...24 {
                let t = Float(i) / 24
                let heading = start + (0.4 + 0.5 * h[2]) * sin(t * (5 + 4 * h[3]) + h[0] * 6.3) * (0.3 + t) + curl * t * t * t
                p += V2(cos(heading), sin(heading)) * length / 24
                line.append(p)
            }
            let w: Float = 0.042 + 0.026 * h[1]
            return (line, w, line.reduce(V2(repeating: 9)) { simd_min($0, $1) } - w, line.reduce(V2(repeating: -9)) { simd_max($0, $1) } + w)
        }
        let light = simd_normalize(V3(-0.45, 0.6, 0.66))
        let ink: Float = icon ? 0.022 : 0.014
        return Scene(pixel: { (u: Float, v: Float, px: Float) -> C4 in
            let q = V2(u, v)
            let d = simd_length(q)
            let angle = atan2(v, u)
            var out = C4.zero
            // The slabs, behind the vines.
            for (i, s) in slabs.enumerated() {
                var da = angle - s.a
                da -= 2 * .pi * (da / (2 * .pi)).rounded()
                guard abs(da) < s.w + 0.15 else { continue }
                let f = Float(i)
                let jag = 0.03 * fbm(V3(angle * 7, f, 0), 2, 190)
                let r0 = s.r0 + jag, r1 = s.r1 + jag * 0.8
                let side = s.w + 0.04 * fbm(V3(d * 9, f, 1), 2, 191)
                let sd = min(d - r0, r1 - d, (side - abs(da)) * d)
                let cover = clamp01(sd / px + 0.5)
                guard cover > 0 else { continue }
                let t = (d - r0) / (r1 - r0)
                let rim = s.rim + 0.06 * fbm(V3(angle * 5, f, 2), 2, 192)
                // Dark inner face brushed in radial strokes; pale outer rim brushed along its curve.
                let radial = 0.5 + 0.5 * fbm(V3(da * d * 48, d * 3, f), 2, 193)
                let along = 0.5 + 0.5 * fbm(V3(da * 3, d * 55, f), 2, 194)
                var c = mix(rgb(0x223852), rgb(0x3A5B7C), radial * (0.4 + 0.6 * t))
                c = mix(c, mix(rgb(0x5A87AA), rgb(0x8DB6D2), along), smooth(rim, rim + 0.02, t))
                // Ink along the edges and the fold between face and rim.
                let fold = smooth(0.03, 0.0, abs(t - rim) * (r1 - r0))
                c = mix(c, rgb(0x182638), max(smooth(ink, ink * 0.4, sd), fold * 0.8))
                out = over(paint(c, cover), out)
            }
            // The vines.
            for (k, vine) in vines.enumerated() {
                guard u > vine.lo.x, v > vine.lo.y, u < vine.hi.x, v < vine.hi.y else { continue }
                let (dist, t, side, normal) = nearest(q, on: vine.line)
                let w = vine.w * (1 - 0.72 * t)
                guard dist < w + px else { continue }
                let s = max(-1, min(1, side / w))
                let n = V3(normal.x * s, normal.y * s, (1 - s * s).squareRoot())
                let lum = 0.3 + 0.7 * max(0, simd_dot(n, light))
                var c = mix(rgb(0x2A1D10), rgb(0x86704A), lum) * (0.88 + 0.16 * fbm(V3(t * 28, s * 2, Float(k)), 2, 195))
                // Lit from the knot near their roots.
                c = mix(c, rgb(0xD8CC8C), exp(-d / 0.09) * 0.5)
                c = mix(c, rgb(0x140D06), smooth(w - ink, w, dist))
                out = over(paint(c, clamp01((w - dist) / px + 0.5)), out)
            }
            // The knot: a lumpy brown mass of vines wound around it, glowing pale yellow at its heart.
            let edge: Float = 0.2 + 0.03 * fbm(V3(cos(angle), sin(angle), 0) * 3, 3, 186)
            if d < edge + px {
                let wound = angle + d * 9
                let coil = 0.5 + 0.5 * fbm(V3(cos(wound) * 2, sin(wound) * 2, d * 26), 3, 187)
                var c = mix(rgb(0x2A1D10), rgb(0x6A5432), smooth(0.3, 0.75, coil))
                c = mix(c, rgb(0x140D06), smooth(edge - ink, edge, d))
                out = over(paint(c, clamp01((edge - d) / px + 0.5)), out)
            }
            let streaks = 0.75 + 0.25 * fbm(V3(cos(angle) * 4, sin(angle) * 4, d * 8), 2, 189)
            out = over(paint(rgb(0xE9E0A0), clamp01(exp(-max(0, d - 0.06) / 0.05) * streaks)), out)
            out = over(paint(rgb(0xFBF7D6), clamp01((0.065 - d) / px + 0.5)), out)
            return out
        })
    }

    // The comet, drawn flat with ink outlines: a ball of cracked pale ice plates, trailing a jagged tail of icy spikes
    // in three blues.
    private static func interloper(_ icon: Bool) -> Scene {
        // Heading left, the tail streaming right. The icon is level and centered, so it lines up with the label beside
        // it; the full picture tilts a little, its tail dipping.
        let R: Float = icon ? 0.44 : 0.38
        let head = icon ? V2(-0.46, 0) : V2(-0.54, 0.08)
        let back = icon ? V2(1, 0) : simd_normalize(V2(1, -0.13))
        let up = V2(-back.y, back.x)
        let ink: Float = icon ? 0.03 : 0.018
        // Each layer of the tail is a fan of tapering spikes: offset across the tail and half-width at the root (in
        // head radii), and length (in head radii).
        func spikes(_ layer: Int32, _ n: Int, reach: Float, spread: Float, shift: Float) -> [(y: Float, w: Float, len: Float)] {
            (0..<n).map { (i: Int) in
                let f = (Float(i) + 0.5) / Float(n) * 2 - 1
                let h0 = hash(Int32(i), layer, 0, 200), h1 = hash(Int32(i), layer, 1, 200), h2 = hash(Int32(i), layer, 2, 200)
                return (f * spread + shift + (h0 - 0.5) * 0.12, 0.2 + 0.14 * h1, reach * (0.55 + 0.45 * h2) * (1 - 0.3 * f * f))
            }
        }
        let layers = [
            spikes(0, 7, reach: icon ? 3.2 : 3.7, spread: 0.9, shift: 0),
            spikes(1, 6, reach: 2.8, spread: 0.7, shift: -0.06),
            spikes(2, 4, reach: 2, spread: 0.48, shift: -0.14),
        ]
        // Signed distance (in frame units, > 0 inside) to a layer, its spikes fanning slightly as they go.
        func tail(_ layer: Int, _ x: Float, _ y: Float) -> Float {
            var sd: Float = -9
            for (i, s) in layers[layer].enumerated() {
                let jag = 0.06 * fbm(V3(x * 2, Float(i), Float(layer)), 2, 201)
                let half = (s.w + jag) * pow(max(0, 1 - x / s.len), 0.75) - (x > s.len ? x - s.len : 0)
                sd = max(sd, min(half - abs(y - s.y * (1 + 0.1 * x)), x + 0.2))
            }
            return sd * R
        }
        return Scene(pixel: { (u: Float, v: Float, px: Float) -> C4 in
            let rel = V2(u, v) - head
            // Tail coordinates in head radii: along the tail, and across it.
            let x = simd_dot(rel, back) / R, y = simd_dot(rel, up) / R
            let r = simd_length(rel)
            let edge = R * (1 + 0.04 * fbm(V3(rel.x, rel.y, 0) / R * 2, 2, 202))
            let ball = edge - r
            let outline = max(ball, tail(0, x, y))
            guard outline > -px else { return .zero }
            func fill(_ c: V3, _ sd: Float) -> C4 { paint(c, clamp01(sd / px + 0.5)) }
            var out = fill(rgb(0x0E1420), outline)
            out = over(fill(rgb(0x1E4C8F), tail(0, x, y) - ink * 0.7), out)
            // The lighter layers each have a darker stroke at their edge.
            for (layer, colors) in [(1, (0x183E78, 0x2F6FB8)), (2, (0x285E9E, 0x5E9EDB))] as [(Int, (UInt32, UInt32))] {
                let sd = tail(layer, x, y)
                guard sd > -px else { continue }
                out = over(fill(rgb(colors.0), sd), out)
                out = over(fill(rgb(colors.1), sd - ink * 0.6), out)
            }
            // The head: pale ice plates on a sphere, so they shrink toward its edge, separated by blue cracks.
            if ball > -px {
                let b = rel / edge
                let z = max(0, 1 - min(1, simd_length_squared(b))).squareRoot()
                let plate = worley(rotation(0.3, -0.5, 0.2) * V3(b.x, b.y, z) * 2.4, 203)
                let crack = smooth(0.1, 0.15, plate.f2 - plate.f1)
                // Plates fade into the tail's blue on the trailing side.
                let trailing = smooth(-0.15, 0.65, simd_dot(b, back))
                var ice = mix(rgb(0xB4DDF4), rgb(0xE4F5FC), plate.id)
                ice = mix(ice, rgb(0x7FBDE8), trailing * 0.8)
                let c = mix(rgb(0x4A93D6), ice, crack * (1 - trailing * 0.6))
                out = over(fill(c, ball - ink), out)
            }
            return out
        })
    }

    // Grey rock wrapped in a shifting shroud of grey-white fog.
    private static func quantumMoon(_ icon: Bool) -> Scene {
        let l = simd_normalize(V3(-0.55, 0.45, 0.7))
        let qm = Ball(c: .zero, r: icon ? 0.8 : 0.66, spin: rotation(0.6, 0.2, 0.3))
        return Scene(pixel: { (u: Float, v: Float, px: Float) -> C4 in
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
