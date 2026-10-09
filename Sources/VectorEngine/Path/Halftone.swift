import Foundation

/// Vector halftone: a screen of dots (or line segments) sized by darkness, instead of traced shapes.
public struct Halftone: Sendable, Equatable {
    public enum Shape: String, Sendable, CaseIterable { case dot, line }

    /// Screen pitch (original px).
    public var cellSize: Double
    /// Screen angle in degrees (45 is classic).
    public var angle: Double
    public var shape: Shape
    public var ink: RGBA
    /// Fill behind the screen; nil = transparent.
    public var background: RGBA?

    public init(cellSize: Double = 8, angle: Double = 45, shape: Shape = .dot, ink: RGBA = RGBA(0, 0, 0), background: RGBA? = nil) {
        self.cellSize = cellSize; self.angle = angle; self.shape = shape; self.ink = ink; self.background = background
    }
}

enum HalftoneGenerator {
    /// Dots (area ∝ darkness) or line segments (thickness ∝ darkness) on a rotated grid with pitch
    /// `cell` (processing px), in processing coordinates. Darkness is 1 − brightness, composited
    /// over white, averaged over a 3×3 sampling of each cell.
    static func shapes(_ b: Bitmap, cell: Double, _ h: Halftone) -> [VectorShape] {
        let w = Double(b.width), hgt = Double(b.height)
        let a = h.angle * .pi / 180
        let u = Vec2(cos(a), sin(a)), v = Vec2(-sin(a), cos(a))
        let center = Vec2(w / 2, hgt / 2)
        let reach = Int((hypot(w, hgt) / 2 / cell).rounded(.up)) + 1
        func darkness(_ p: Vec2) -> Double {
            var sum = 0.0, n = 0
            for j in -1...1 {
                for i in -1...1 {
                    let q = p + u * (Double(i) * cell / 3) + v * (Double(j) * cell / 3)
                    let x = Int(q.x), y = Int(q.y)
                    guard x >= 0, y >= 0, x < b.width, y < b.height else { continue }
                    let px = b[x, y], al = Double(px.a) / 255
                    let l = (0.2126 * Double(px.r) + 0.7152 * Double(px.g) + 0.0722 * Double(px.b)) / 255
                    sum += 1 - (l * al + (1 - al))
                    n += 1
                }
            }
            return n == 0 ? 0 : sum / Double(n)
        }
        var subpaths: [Subpath] = []
        for j in -reach...reach {
            for i in -reach...reach {
                // Half-cell offset: cells tile the image instead of straddling its edges.
                let p = center + u * ((Double(i) + 0.5) * cell) + v * ((Double(j) + 0.5) * cell)
                guard p.x >= 0, p.y >= 0, p.x <= w, p.y <= hgt else { continue }
                let d = darkness(p)
                guard d > 0.02 else { continue }
                switch h.shape {
                case .dot:
                    // Area d·cell² → radius cell·√(d/π); a little overlap lets dark areas go solid.
                    subpaths.append(circle(p, radius: min(cell * 0.75, cell * (d / .pi).squareRoot())))
                case .line:
                    let half = u * (cell / 2), t = v * (cell * d / 2)
                    let c0 = p - half - t
                    subpaths.append(Subpath(start: c0, segments: [.line(to: p + half - t), .line(to: p + half + t), .line(to: p - half + t), .line(to: c0)]))
                }
            }
        }
        return subpaths.isEmpty ? [] : [VectorShape(color: h.ink, subpaths: subpaths)]
    }

    /// A circle as four cubic quarter-arcs.
    static func circle(_ c: Vec2, radius r: Double) -> Subpath {
        let k = 0.5523 * r
        let top = c + Vec2(0, -r), right = c + Vec2(r, 0), bottom = c + Vec2(0, r), left = c + Vec2(-r, 0)
        return Subpath(start: top, segments: [
            .cubic(c1: top + Vec2(k, 0), c2: right + Vec2(0, -k), to: right),
            .cubic(c1: right + Vec2(0, k), c2: bottom + Vec2(k, 0), to: bottom),
            .cubic(c1: bottom + Vec2(-k, 0), c2: left + Vec2(0, k), to: left),
            .cubic(c1: left + Vec2(0, -k), c2: top + Vec2(-k, 0), to: top),
        ])
    }
}
