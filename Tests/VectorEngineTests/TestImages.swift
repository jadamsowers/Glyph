import Foundation
@testable import VectorEngine

enum TestImages {
    static let white = RGBA(255, 255, 255)
    static let black = RGBA(0, 0, 0)
    static let red = RGBA(220, 30, 40)
    static let blue = RGBA(30, 60, 200)
    static let green = RGBA(40, 170, 70)
    static let magenta = RGBA(255, 0, 255)

    /// A disc on a background. With `antialias`, edge pixels blend by 4×4 supersampled coverage.
    static func circle(size: Int = 48, radius: Double = 16, fg: RGBA = red, bg: RGBA = white, antialias: Bool = false) -> Bitmap {
        let c = Double(size) / 2
        let samples = antialias ? 4 : 1
        return Bitmap(width: size, height: size) { x, y in
            var inside = 0
            for sy in 0..<samples {
                for sx in 0..<samples {
                    let px = Double(x) + (Double(sx) + 0.5) / Double(samples)
                    let py = Double(y) + (Double(sy) + 0.5) / Double(samples)
                    if (px - c) * (px - c) + (py - c) * (py - c) <= radius * radius { inside += 1 }
                }
            }
            return blend(fg, bg, Double(inside) / Double(samples * samples))
        }
    }

    /// `a` over `b` with weight `t`, mixing sRGB-encoded values like typical anti-aliasing.
    static func blend(_ a: RGBA, _ b: RGBA, _ t: Double) -> RGBA {
        if t >= 1 { return a }
        if t <= 0 { return b }
        if b.a == 0 { return RGBA(a.r, a.g, a.b, UInt8((t * Double(a.a)).rounded())) }
        func mix(_ u: UInt8, _ v: UInt8) -> UInt8 { UInt8((Double(u) * t + Double(v) * (1 - t)).rounded()) }
        return RGBA(mix(a.r, b.r), mix(a.g, b.g), mix(a.b, b.b), mix(a.a, b.a))
    }

    static func color(for c: Character) -> RGBA {
        switch c {
        case "W": white
        case "R": red
        case "B": blue
        case "G": green
        case "K": black
        case ".": .clear
        default: RGBA(UInt8(c.asciiValue! &* 37), 120, 160)
        }
    }

    /// ASCII-art bitmap: W R B G K are named colors, '.' is transparent. `scale` enlarges each cell.
    static func grid(_ rows: [String], scale: Int = 1) -> Bitmap {
        let cells = rows.map(Array.init)
        return Bitmap(width: cells[0].count * scale, height: cells.count * scale) { x, y in
            color(for: cells[y / scale][x / scale])
        }
    }

    /// ASCII art straight to a QuantizedImage (one palette entry per character, '.' = -1).
    static func quantized(_ rows: [String]) -> QuantizedImage {
        let cells = rows.map(Array.init)
        let chars = Array(Set(cells.joined()).subtracting(["."])).sorted()
        var indices: [Int32] = []
        for row in cells { for c in row { indices.append(c == "." ? -1 : Int32(chars.firstIndex(of: c)!)) } }
        return QuantizedImage(width: cells[0].count, height: cells.count, palette: chars.map(color(for:)), indices: indices)
    }

    /// Random 2×2 blocks of the given colors plus scattered single pixels.
    static func randomBlocks(width: Int = 24, height: Int = 24, colors: [RGBA] = [red, blue, white], seed: UInt64 = 7) -> Bitmap {
        var rng = SplitMix64(seed: seed)
        func pick() -> RGBA { colors[Int(rng.next() % UInt64(colors.count))] }
        var b = Bitmap(width: width, height: height) { _, _ in colors[0] }
        for by in stride(from: 0, to: height, by: 2) {
            for bx in stride(from: 0, to: width, by: 2) {
                let c = pick()
                for y in by..<min(by + 2, height) { for x in bx..<min(bx + 2, width) { b[x, y] = c } }
            }
        }
        for _ in 0..<(width * height / 10) {
            let x = Int(rng.next() % UInt64(width)), y = Int(rng.next() % UInt64(height))
            b[x, y] = pick()
        }
        return b
    }

    /// Adds deterministic per-channel noise in ±amplitude to non-transparent pixels.
    static func noisy(_ src: Bitmap, amplitude: Int, seed: UInt64 = 3) -> Bitmap {
        var rng = SplitMix64(seed: seed)
        func n(_ v: UInt8) -> UInt8 {
            UInt8(max(0, min(255, Int(v) + Int(rng.next() % UInt64(2 * amplitude + 1)) - amplitude)))
        }
        var b = src
        for i in b.pixels.indices where b.pixels[i].a > 0 {
            let p = b.pixels[i]
            b.pixels[i] = RGBA(n(p.r), n(p.g), n(p.b), p.a)
        }
        return b
    }

    /// Two-axis gradient with texture noise; should classify as a photo.
    static func photoLike(size: Int = 64) -> Bitmap {
        noisy(Bitmap(width: size, height: size) { x, y in
            RGBA(UInt8(x * 255 / size), UInt8(y * 255 / size), UInt8((x + y) * 127 / size))
        }, amplitude: 20)
    }

    /// A blue disk (r = 12) inside a red ring (to r = 15) on white. The ring has fewer pixels than
    /// the disk but a larger outer boundary.
    static func ringAroundDisk(size: Int = 40) -> Bitmap {
        let c = Double(size) / 2
        return Bitmap(width: size, height: size) { x, y in
            let dx = Double(x) + 0.5 - c, dy = Double(y) + 0.5 - c
            let d = (dx * dx + dy * dy).squareRoot()
            return d <= 12 ? blue : (d <= 15 ? red : white)
        }
    }

    /// Fraction of identical pixels (two fully transparent pixels count as identical).
    static func agreement(_ a: Bitmap, _ b: Bitmap) -> Double {
        precondition(a.width == b.width && a.height == b.height)
        var same = 0
        for i in a.pixels.indices {
            let p = a.pixels[i], q = b.pixels[i]
            if p == q || (p.a == 0 && q.a == 0) { same += 1 }
        }
        return Double(same) / Double(a.pixels.count)
    }
}
