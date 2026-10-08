import Foundation

public struct Vec2: Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x; self.y = y
    }

    public static let zero = Vec2(0, 0)
    public static func + (l: Vec2, r: Vec2) -> Vec2 { Vec2(l.x + r.x, l.y + r.y) }
    public static func - (l: Vec2, r: Vec2) -> Vec2 { Vec2(l.x - r.x, l.y - r.y) }
    public static func * (l: Vec2, s: Double) -> Vec2 { Vec2(l.x * s, l.y * s) }
    public static prefix func - (v: Vec2) -> Vec2 { Vec2(-v.x, -v.y) }

    public func dot(_ o: Vec2) -> Double { x * o.x + y * o.y }
    public var length: Double { (x * x + y * y).squareRoot() }
    public var normalized: Vec2 {
        let l = length
        return l > 0 ? Vec2(x / l, y / l) : .zero
    }
    public func distance(to o: Vec2) -> Double { (self - o).length }
    public func scaled(_ sx: Double, _ sy: Double) -> Vec2 { Vec2(x * sx, y * sy) }

    /// Distance from this point to the segment a–b.
    public func distance(toSegment a: Vec2, _ b: Vec2) -> Double {
        let ab = b - a
        let len2 = ab.dot(ab)
        if len2 == 0 { return distance(to: a) }
        let t = max(0, min(1, (self - a).dot(ab) / len2))
        return distance(to: a + ab * t)
    }
}

/// A pixel-corner coordinate: (0,0) is the top-left corner of the image.
public struct LatticePoint: Hashable, Sendable {
    public var x: Int
    public var y: Int

    public init(_ x: Int, _ y: Int) {
        self.x = x; self.y = y
    }

    public var vec: Vec2 { Vec2(Double(x), Double(y)) }
}
