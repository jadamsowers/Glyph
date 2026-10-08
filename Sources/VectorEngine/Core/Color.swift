import Foundation

/// An 8-bit sRGB color with straight (non-premultiplied) alpha.
public struct RGBA: Hashable, Sendable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8
    public var a: UInt8

    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8 = 255) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    public static let clear = RGBA(0, 0, 0, 0)

    /// The color channels packed into 24 bits (alpha ignored); used as a cache key.
    var rgbKey: UInt32 { UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b) }

    public var hex: String { String(format: "#%02x%02x%02x", r, g, b) }
}

/// CIELAB (D65) color, used for perceptual distances.
public struct Lab: Sendable, Equatable {
    public var l: Double
    public var a: Double
    public var b: Double

    public init(l: Double, a: Double, b: Double) {
        self.l = l; self.a = a; self.b = b
    }

    public init(_ c: RGBA) {
        let r = Lab.linear[Int(c.r)], g = Lab.linear[Int(c.g)], b = Lab.linear[Int(c.b)]
        let x = (0.4124564 * r + 0.3575761 * g + 0.1804375 * b) / 0.95047
        let y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b
        let z = (0.0193339 * r + 0.1191920 * g + 0.9503041 * b) / 1.08883
        let fx = Lab.f(x), fy = Lab.f(y), fz = Lab.f(z)
        self.init(l: 116 * fy - 16, a: 500 * (fx - fy), b: 200 * (fy - fz))
    }

    public func distance(to o: Lab) -> Double {
        let dl = l - o.l, da = a - o.a, db = b - o.b
        return (dl * dl + da * da + db * db).squareRoot()
    }

    private static func f(_ t: Double) -> Double {
        t > 216.0 / 24389.0 ? cbrt(t) : (24389.0 / 27.0 * t + 16) / 116
    }

    private static let linear: [Double] = (0..<256).map { i in
        let v = Double(i) / 255
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }
}
