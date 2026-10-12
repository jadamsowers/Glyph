import Foundation

/// How a diagonal touch between two ink pixels (a 2×2 checkerboard) is resolved.
public enum TurnPolicy: String, Sendable, CaseIterable {
    /// Ink pixels touching at a corner are joined (thin dark strokes stay connected).
    case connectInk
    /// They stay separate (paper connects instead).
    case separateInk
    /// Whichever color is locally rarer (in the surrounding 4×4) is connected — potrace's default.
    case minority
}

/// Black-and-white tracing: one ink color on transparent (or a background fill).
public struct Monochrome: Sendable, Equatable {
    /// Brightness (0…1) below which a pixel is ink; nil = automatic (Otsu's method).
    public var threshold: Double?
    /// Trace light pixels as ink instead of dark ones.
    public var invert: Bool
    public var ink: RGBA
    /// Fill behind the ink; nil = transparent.
    public var background: RGBA?
    public var turnPolicy: TurnPolicy

    public init(threshold: Double? = nil, invert: Bool = false, ink: RGBA = RGBA(0, 0, 0), background: RGBA? = nil,
                turnPolicy: TurnPolicy = .minority) {
        self.threshold = threshold; self.invert = invert; self.ink = ink; self.background = background
        self.turnPolicy = turnPolicy
    }
}

extension Quantizer {
    /// Ink (palette index 0) where brightness — composited over white, so transparency is paper —
    /// is below the threshold (above it when inverted); paper is transparent (-1).
    static func monochrome(_ bitmap: Bitmap, _ m: Monochrome) -> QuantizedImage {
        let brightness = bitmap.pixels.map { p -> Double in
            let a = Double(p.a) / 255
            let l = (0.2126 * Double(p.r) + 0.7152 * Double(p.g) + 0.0722 * Double(p.b)) / 255
            return l * a + (1 - a)
        }
        let t = m.threshold ?? otsu(brightness)
        // Transparent pixels are paper either way — inverting must not ink a removed background.
        var ink = zip(brightness, bitmap.pixels).map { v, p in m.invert ? v > t && p.a >= 128 : v < t }
        resolveDiagonals(&ink, width: bitmap.width, height: bitmap.height, policy: m.turnPolicy)
        return QuantizedImage(width: bitmap.width, height: bitmap.height, palette: [m.ink], indices: ink.map { $0 ? 0 : -1 })
    }

    /// Otsu's threshold: the split of the brightness histogram that maximizes between-class variance.
    static func otsu(_ values: [Double]) -> Double {
        var hist = [Double](repeating: 0, count: 256)
        for v in values { hist[min(255, max(0, Int(v * 255)))] += 1 }
        let total = Double(values.count), sumAll = hist.enumerated().reduce(0) { $0 + Double($1.offset) * $1.element }
        var weightB = 0.0, sumB = 0.0, best = 0.0, threshold = 127.5
        for i in 0..<256 {
            weightB += hist[i]
            guard weightB > 0, weightB < total else { continue }
            sumB += Double(i) * hist[i]
            let mB = sumB / weightB, mF = (sumAll - sumB) / (total - weightB)
            let between = weightB * (total - weightB) * (mB - mF) * (mB - mF)
            if between > best { best = between; threshold = Double(i) + 0.5 }
        }
        return threshold / 255
    }

    /// Applies the turn policy to every 2×2 checkerboard of ink: joining ink fills one paper pixel.
    static func resolveDiagonals(_ ink: inout [Bool], width w: Int, height h: Int, policy: TurnPolicy) {
        guard policy != .separateInk, w > 1, h > 1 else { return }
        for y in 0..<(h - 1) {
            for x in 0..<(w - 1) {
                let a = ink[y * w + x], b = ink[y * w + x + 1], c = ink[(y + 1) * w + x], d = ink[(y + 1) * w + x + 1]
                guard a == d, b == c, a != b else { continue }
                var join = policy == .connectInk
                if policy == .minority {
                    var inkCount = 0, n = 0
                    for yy in max(0, y - 1)...min(h - 1, y + 2) {
                        for xx in max(0, x - 1)...min(w - 1, x + 2) { n += 1; if ink[yy * w + xx] { inkCount += 1 } }
                    }
                    join = inkCount * 2 < n
                }
                if join { if a { ink[y * w + x + 1] = true } else { ink[y * w + x] = true } }
            }
        }
    }
}

extension Bitmap {
    /// The bitmap with `n` transparent pixels added on every side.
    func padded(by n: Int) -> Bitmap {
        guard n > 0 else { return self }
        let w = width + 2 * n
        return Bitmap(width: w, height: height + 2 * n) { x, y in
            let sx = x - n, sy = y - n
            return sx >= 0 && sy >= 0 && sx < width && sy < height ? self[sx, sy] : .clear
        }
    }
}
