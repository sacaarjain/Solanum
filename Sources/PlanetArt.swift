import AppKit
import simd

/// The Outer Wilds planets, rendered pixel by pixel: lit spheres textured with procedural noise (terrain, craters,
/// cloud bands, cracked crust, fog), atmospheres and glows, plus drawn vines, sand and comet tails. The theme's
/// planet sits in the status bar with the Hearthian ship orbiting it.
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

    /// Draws `planet` centered in `rect` (in a y-up context), rendered once per size and cached.
    static func draw(_ planet: Planet, in ctx: CGContext, rect: CGRect) {
        let t = ctx.userSpaceToDeviceSpaceTransform
        let scale = max(1, CGFloat(hypot(Double(t.a), Double(t.b))))
        let side = min(rect.width, rect.height)
        let px = Int((side * scale).rounded())
        // Small ones render larger and scale down, so fine detail blends instead of sparkling.
        let renderPx = min(1200, px < 160 ? px * 3 : px)
        guard renderPx >= 8, let img = image(planet, pixels: renderPx) else { return }
        ctx.saveGState()
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side))
        ctx.restoreGState()
    }

    private static var cache: [String: CGImage] = [:]

    private static func image(_ planet: Planet, pixels: Int) -> CGImage? {
        let key = "\(planet.rawValue)|\(pixels)"
        if let c = cache[key] { return c }
        let img = render(planet, pixels: pixels)
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
        for (i, (scale, weight)) in [(Float(2.6), Float(1)), (5.5, 0.7), (11, 0.45)].enumerated() {
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
                shade += 0.07 * weight * depth * (1 - (x - 1) / 0.35)
                tilt -= toward * (0.5 * weight * depth * (1 - (x - 1) / 0.35))
            }
        }
        let tangent = tilt - n * simd_dot(tilt, n)
        return (shade, simd_normalize(n + tangent * 0.8))
    }

    // MARK: Rendering

    private typealias Shader = (_ u: Float, _ v: Float, _ px: Float) -> C4

    /// The planet in a square of `S` pixels: drawn layers behind, the per-pixel scene, drawn layers in front.
    private static func render(_ planet: Planet, pixels S: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8, bytesPerRow: S * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let size = CGFloat(S)
        // Unit space (-1…1, y up) to pixels.
        ctx.translateBy(x: size / 2, y: size / 2)
        ctx.scaleBy(x: size / 2, y: size / 2)
        let scene = self.scene(planet)
        scene.behind?(ctx)
        if let img = shade(scene.pixel, S, space) {
            ctx.draw(img, in: CGRect(x: -1, y: -1, width: 2, height: 2))
        }
        scene.front?(ctx)
        return ctx.makeImage()
    }

    private static func shade(_ f: @escaping Shader, _ S: Int, _ space: CGColorSpace) -> CGImage? {
        var data = [UInt8](repeating: 0, count: S * S * 4)
        let px: Float = 2 / Float(S)
        data.withUnsafeMutableBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            DispatchQueue.concurrentPerform(iterations: S) { j in
                let v = 1 - (Float(j) + 0.5) * px
                for i in 0..<S {
                    let u = (Float(i) + 0.5) * px - 1
                    let c = simd_clamp(f(u, v, px), C4.zero, C4(repeating: 1))
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
        var behind: ((CGContext) -> Void)?
        var front: ((CGContext) -> Void)?
    }

    private static func scene(_ planet: Planet) -> Scene {
        switch planet {
        case .hourglass: return hourglass()
        case .timberHearth: return timberHearth()
        case .attlerock: return attlerock()
        case .brittleHollow: return brittleHollow()
        case .giantsDeep: return giantsDeep()
        case .darkBramble: return darkBramble()
        case .interloper: return interloper()
        case .quantumMoon: return quantumMoon()
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
    private static func timberHearth() -> Scene {
        let l = simd_normalize(V3(-0.62, 0.42, 0.66))
        let th = Ball(c: V2(-0.1, -0.08), r: 0.7, spin: rotation(0.5, 0.9, 0.15))
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
            if let h = hit(moon, u, v, px) {
                out = over(paint(moonRock(h, moon, l, 21), h.cover), out)
            }
            return out
        })
    }

    // Timber Hearth's moon: grey, deeply cratered.
    private static func attlerock() -> Scene {
        let l = simd_normalize(V3(-0.6, 0.5, 0.62))
        let moon = Ball(c: .zero, r: 0.86, spin: rotation(0.3, 1.2, 0))
        return Scene(pixel: { u, v, px in
            guard let h = hit(moon, u, v, px) else { return .zero }
            return paint(moonRock(h, moon, l, 31), h.cover)
        })
    }

    // Twin desert planets: Ash Twin's pale sand pours across onto Ember Twin's red rock.
    private static func hourglass() -> Scene {
        let l = simd_normalize(V3(-0.85, 0.15, 0.5))
        let ash = Ball(c: V2(-0.48, 0.44), r: 0.36, spin: rotation(0.2, 0.6, 0.3))
        let ember = Ball(c: V2(0.28, -0.26), r: 0.54, spin: rotation(0.9, 2.1, 0.1))
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
            let w = 0.075 * (1 - 0.4 * sin(.pi * bestT))
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

    // Dark, cracked crust over a black hole, falling apart in places; Hollow's Lantern glows beside it, lighting
    // that side orange.
    private static func brittleHollow() -> Scene {
        let sun = simd_normalize(V3(-0.55, 0.3, 0.78))
        let lantern = Ball(c: V2(0.66, 0.64), r: 0.17, spin: rotation(0.4, 0.2, 0))
        let bh = Ball(c: V2(-0.08, -0.1), r: 0.74, spin: rotation(0.2, 0.4, 0.1))
        let lanternDir = simd_normalize(V3(lantern.c.x - bh.c.x, lantern.c.y - bh.c.y, 0.25))
        let hole = simd_normalize(V3(0.18, 0.5, 0.85))
        return Scene(pixel: { u, v, px in
            var out = halo(bh, u, v, sun, rgb(0x8A8CC8), width: 0.08, strength: 0.3)
            out = over(halo(lantern, u, v, V3(0, 0, 1), rgb(0xFF8A30), width: 1.4, strength: 0.6), out)
            if let h = hit(bh, u, v, px) {
                let p = h.p
                let plates = worley(p * 3.2 + V3(fbm(p * 3, 3, 66), fbm(p * 3 + 4, 3, 67), 0) * 0.5, 61)
                let edge = plates.f2 - plates.f1
                var a = mix(rgb(0x22232E), rgb(0x4E5064), 0.5 + 0.5 * fbm(p * 4, 5, 62)) * (0.9 + 0.2 * plates.id)
                // Frost on the crust.
                a = mix(a, rgb(0x8E9BBE), smooth(0.25, 0.55, fbm(p * 2.4 + 7, 4, 63)) * 0.55)
                var c = a * (0.03 + diffuse(h.n, sun)) + rgb(0xFF7A2A) * (smooth(0.2, 1, simd_dot(h.n, lanternDir)) * 0.25) * a * 2
                // Fault lines between plates.
                c *= 0.35 + 0.65 * smooth(0.006, 0.03, edge + 0.02 * fbm(p * 20, 2, 68))
                // Where the crust has fallen in: the black hole, its edge lit violet.
                let rimAngle = 0.93 + 0.025 * fbm(p * 7, 3, 64)
                let into = simd_dot(h.n, hole)
                if into > rimAngle {
                    let t = (into - rimAngle) / (1 - rimAngle)
                    let glow = rgb(0x8A6CFF) * exp(-t * 7) * 1.2 + rgb(0xD8C8FF) * exp(-t * 30) * 0.6
                    c = mix(c, glow, smooth(0, 0.08, t))
                }
                c += rgb(0x8C96FF) * rim(h.n, sun) * 0.35
                out = over(paint(c, h.cover), out)
            }
            if let h = hit(lantern, u, v, px) {
                let w = worley(h.p * 4.5, 65)
                let lava = 1 - smooth(0.02, 0.16, w.f2 - w.f1)
                let crust = rgb(0x4A1A0A) * (0.4 + 0.8 * diffuse(h.n, sun)) + rgb(0xFF6A1A) * 0.35
                let hot = mix(rgb(0xFF7A1A), rgb(0xFFE6A0), lava)
                let c = mix(crust, hot, max(lava, 0.25 * (1 - h.n.z))) + rgb(0xFFB050) * pow(1 - h.n.z, 3) * 0.5
                out = over(paint(c, h.cover), out)
            }
            return out
        })
    }

    // A green ocean world under streaming cloud bands, spun into cyclones.
    private static func giantsDeep() -> Scene {
        let l = simd_normalize(V3(-0.58, 0.4, 0.7))
        let gd = Ball(c: .zero, r: 0.84, spin: rotation(0.25, 0.3, -0.15))
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

    // A pale, cracked shell of ice with enormous black thorned vines breaking out of it.
    private static func darkBramble() -> Scene {
        let l = simd_normalize(V3(-0.55, 0.5, 0.67))
        let shell = Ball(c: .zero, r: 0.56, spin: rotation(0.3, 0.7, 0))
        // Where vines come out: view-space directions, and how they bend.
        let vines: [(dir: V3, bend: Float, len: Float, width: Float)] = [
            (simd_normalize(V3(-0.6, 0.5, 0.62)), 0.7, 1.15, 0.13),
            (simd_normalize(V3(0.62, 0.5, 0.6)), -0.6, 1.0, 0.115),
            (simd_normalize(V3(0.2, -0.7, 0.68)), 0.55, 1.15, 0.14),
            (simd_normalize(V3(0.9, -0.25, 0.36)), 0.8, 0.85, 0.09),
            (simd_normalize(V3(0.05, 0.95, -0.3)), 0.6, 0.85, 0.1),
            (simd_normalize(V3(-0.9, -0.15, -0.4)), -0.5, 0.85, 0.1),
        ]
        func drawVines(_ ctx: CGContext, front: Bool) {
            for (k, vine) in vines.enumerated() where (vine.dir.z >= 0) == front {
                let base = CGPoint(x: CGFloat(shell.c.x + vine.dir.x * shell.r * (front ? 0.9 : 1)),
                                   y: CGFloat(shell.c.y + vine.dir.y * shell.r * (front ? 0.9 : 1)))
                let out2 = simd_normalize(V2(vine.dir.x, vine.dir.y))
                let side = V2(-out2.y, out2.x)
                // Out from the shell, curling to one side.
                var pts: [V2] = []
                let n = 24
                for i in 0...n {
                    let t = Float(i) / Float(n)
                    let reach = (front ? 0.04 : 0.05) + t * vine.len * (front ? 0.6 : 0.5)
                    let curl = vine.bend * t * t * 0.45
                    pts.append(V2(Float(base.x), Float(base.y)) + out2 * reach + side * curl + side * 0.02 * sin(t * 9 + Float(k)))
                }
                func width(_ t: Float) -> Float { vine.width * (1 - t * 0.8) * (0.5 + 0.5 * min(1, t * 6 + 0.4)) }
                var left: [CGPoint] = [], right: [CGPoint] = []
                for i in 0...n {
                    let t = Float(i) / Float(n)
                    let d = simd_normalize(pts[min(n, i + 1)] - pts[max(0, i - 1)])
                    let nn = V2(-d.y, d.x) * width(t)
                    left.append(CGPoint(x: CGFloat(pts[i].x + nn.x), y: CGFloat(pts[i].y + nn.y)))
                    right.append(CGPoint(x: CGFloat(pts[i].x - nn.x), y: CGFloat(pts[i].y - nn.y)))
                }
                let body = CGMutablePath()
                body.addLines(between: left + right.reversed())
                body.closeSubpath()
                // Thorns along both sides, pointing back toward the root.
                let thorns = CGMutablePath()
                for i in stride(from: 3, to: n - 2, by: 3) {
                    let t = Float(i) / Float(n)
                    let d = simd_normalize(pts[i + 1] - pts[i - 1])
                    let nrm = V2(-d.y, d.x)
                    for sgn: Float in [1, -1] where (i / 3 + (sgn > 0 ? 0 : 1)) % 2 == 0 {
                        let w = width(t)
                        let root = pts[i] + nrm * w * sgn * 0.8
                        let tip = pts[i] + nrm * (w + 0.06 * (1 - t * 0.6)) * sgn - d * 0.035
                        let back = pts[i] - d * 0.03 + nrm * w * sgn * 0.8
                        thorns.addLines(between: [CGPoint(x: CGFloat(root.x + d.x * 0.02), y: CGFloat(root.y + d.y * 0.02)),
                                                  CGPoint(x: CGFloat(tip.x), y: CGFloat(tip.y)), CGPoint(x: CGFloat(back.x), y: CGFloat(back.y))])
                        thorns.closeSubpath()
                    }
                }
                ctx.saveGState()
                let dark = front ? CGColor(srgbRed: 0.085, green: 0.08, blue: 0.075, alpha: 1) : CGColor(srgbRed: 0.06, green: 0.06, blue: 0.06, alpha: 1)
                ctx.setFillColor(dark)
                ctx.addPath(body)
                ctx.addPath(thorns)
                ctx.fillPath()
                // Bark lit on the side facing the light.
                ctx.addPath(body)
                ctx.clip()
                let lightSide = V2(l.x, l.y)
                let shift = simd_dot(side, lightSide) > 0 ? 1 : -1
                let hl = CGMutablePath()
                hl.addLines(between: pts.enumerated().map { i, p in
                    let q = p + side * Float(shift) * width(Float(i) / Float(n)) * 0.55
                    return CGPoint(x: CGFloat(q.x), y: CGFloat(q.y))
                })
                ctx.setStrokeColor(CGColor(srgbRed: 0.33, green: 0.31, blue: 0.29, alpha: front ? 0.4 : 0.2))
                ctx.setLineWidth(CGFloat(vine.width * 0.45))
                ctx.setLineCap(.round)
                ctx.addPath(hl)
                ctx.strokePath()
                ctx.restoreGState()
            }
        }
        return Scene(pixel: { u, v, px in
            var out = halo(shell, u, v, l, rgb(0xE6EEE8), width: 0.3, strength: 0.35)
            if let h = hit(shell, u, v, px) {
                let p = h.p
                let ice = mix(rgb(0xAEB8B4), rgb(0xF2F5F2), 0.5 + 0.5 * fbm(p * 4, 5, 81))
                let cracks = worley(p * 6, 82)
                var c = ice * (0.06 + diffuse(h.n, l))
                c *= 0.55 + 0.45 * smooth(0.005, 0.03, cracks.f2 - cracks.f1)
                // Dark holes where the vines break through, with a little seed light in the fog inside.
                for vine in vines where vine.dir.z > 0 {
                    let t = simd_dot(h.n, vine.dir)
                    let rr: Float = 0.985 - vine.width * 0.42
                    if t > rr {
                        let k = (t - rr) / (1 - rr)
                        c = mix(c, rgb(0x161A16) + rgb(0xE8E0B0) * exp(-pow((1 - k) * 3, 2)) * 0.22, smooth(0, 0.25, k))
                    }
                }
                c += rgb(0xE6F0EA) * rim(h.n, l) * 0.4
                out = over(paint(c, h.cover), out)
            }
            // Fog seeping out around it.
            let d = simd_length(V2(u, v) - shell.c) / shell.r
            if d > 0.95, d < 1.6 {
                let wisp = smooth(-0.05, 0.5, fbm(V3(u * 5, v * 5, 2), 4, 83)) * pow(1 - (d - 0.95) / 0.65, 2) * 0.25
                out = over(paint(rgb(0xDDE6E0), wisp), out)
            }
            return out
        }, behind: { ctx in drawVines(ctx, front: false) }, front: { ctx in drawVines(ctx, front: true) })
    }

    // The comet: a lumpy, icy nucleus with dark rock showing through, a glowing coma, and two tails streaming away
    // from the sun (a straight blue ion tail and a broader, curving white dust tail).
    private static func interloper() -> Scene {
        let l = simd_normalize(V3(-0.6, -0.5, 0.62))
        let c0 = V2(-0.36, -0.38)
        let tailDir = simd_normalize(V2(0.62, 0.78))
        let angle: Float = 0.55
        let rx: Float = 0.27, ry: Float = 0.19
        let spin = rotation(0.7, 0.4, 0.2)
        return Scene(pixel: { u, v, px in
            let rel = V2(u, v) - c0
            var out = C4.zero
            // Tails.
            let s = simd_dot(rel, tailDir)
            if s > -0.05 {
                let perp = rel.x * tailDir.y - rel.y * tailDir.x
                let sp = max(0, s)
                let ionW = 0.025 + 0.07 * sp
                let streak = 0.7 + 0.3 * fbm(V3(perp / ionW * 2.5, sp * 1.5, 0), 3, 91)
                let ion = exp(-pow(perp / ionW, 2)) * pow(max(0, 1 - sp / 1.75), 1.3) * streak * 0.75
                let curved = perp + 0.22 * sp * sp
                let dustW = 0.05 + 0.17 * sp
                let dust = exp(-pow(curved / dustW, 2)) * pow(max(0, 1 - sp / 1.5), 1.6) * 0.6 * (0.8 + 0.2 * fbm(V3(curved / dustW * 1.5, sp * 2, 3), 3, 92))
                let fadeIn = smooth(-0.05, 0.15, s)
                let a = clamp01((ion + dust) * fadeIn)
                if a > 0.001 {
                    let col = (rgb(0x86CCFF) * ion + rgb(0xF4F7FF) * dust) / max(0.0001, ion + dust)
                    out = over(paint(col, a), out)
                }
            }
            // Coma.
            let r = simd_length(rel)
            out = over(paint(rgb(0xD8F0FF), clamp01(exp(-r / 0.18) * 0.55)), out)
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
                var a = mix(rgb(0xE4F2FA), rgb(0x3E4A58), rock * 0.85)
                a = mix(a, rgb(0xB8DCF0), smooth(0.3, 0.6, fbm(p * 9, 3, 97)) * 0.3)
                var c = a * (0.05 + diffuse(nb, l))
                // Ghost matter glimmering in the dark side's cracks.
                c += rgb(0x4CF0C0) * smooth(0.35, 0.6, fbm(p * 8, 3, 98)) * (1 - smooth(-0.2, 0.3, simd_dot(nb, l))) * 0.18
                c += rgb(0xCDEBFF) * rim(n, l) * 0.5
                out = over(paint(c, cover), out)
            }
            return out
        })
    }

    // Grey rock wrapped in a shifting shroud of grey-white fog.
    private static func quantumMoon() -> Scene {
        let l = simd_normalize(V3(-0.55, 0.45, 0.7))
        let qm = Ball(c: .zero, r: 0.66, spin: rotation(0.6, 0.2, 0.3))
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

    // MARK: Status bar companion

    /// The little planet with the ship on an orbit around it. `phase` is the ship's angle; it passes behind the
    /// planet on the far half of the orbit.
    static func drawCompanion(_ planet: Planet, in ctx: CGContext, rect: CGRect, phase: CGFloat, ship: NSColor, trail: NSColor) {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let rx = rect.width / 2 - 1.5, ry = rect.height * 0.2
        let tilt: CGFloat = -0.22
        func orbit(_ a: CGFloat) -> CGPoint {
            let x = cos(a) * rx, y = sin(a) * ry
            return CGPoint(x: c.x + x * cos(tilt) - y * sin(tilt), y: c.y + x * sin(tilt) + y * cos(tilt))
        }
        let behind = sin(phase) > 0   // the upper half of the ellipse is the far side
        func drawShip() {
            for k in 1...5 {
                let p = orbit(phase - CGFloat(k) * 0.16)
                ctx.setFillColor(trail.withAlphaComponent(0.5 * (1 - CGFloat(k) / 6) * (behind ? 0.5 : 1)).cgColor)
                ctx.fillEllipse(in: CGRect(x: p.x - 0.8, y: p.y - 0.8, width: 1.6, height: 1.6))
            }
            let p = orbit(phase)
            ctx.setFillColor(ship.withAlphaComponent(behind ? 0.45 : 1).cgColor)
            ctx.fillEllipse(in: CGRect(x: p.x - 1.6, y: p.y - 1.6, width: 3.2, height: 3.2))
        }
        if behind { drawShip() }
        let size = min(rect.height, rect.width) * 0.86
        draw(planet, in: ctx, rect: CGRect(x: c.x - size / 2, y: c.y - size / 2, width: size, height: size))
        if !behind { drawShip() }
    }
}
