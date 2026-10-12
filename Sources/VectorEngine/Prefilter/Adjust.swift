import Foundation

/// Tone and color adjustments applied before tracing.
public struct Adjustments: Sendable, Equatable {
    /// −1…1, added to every channel.
    public var brightness: Double
    /// 0…3 around mid-gray (1 = unchanged).
    public var contrast: Double
    /// 0…3 (0 = grayscale, 1 = unchanged).
    public var saturation: Double
    /// 0.2…5 (> 1 brightens midtones).
    public var gamma: Double
    public var invert: Bool

    public init(brightness: Double = 0, contrast: Double = 1, saturation: Double = 1, gamma: Double = 1, invert: Bool = false) {
        self.brightness = brightness; self.contrast = contrast; self.saturation = saturation
        self.gamma = gamma; self.invert = invert
    }

    public var isIdentity: Bool { self == Adjustments() }
}

extension Prefilter {
    /// Saturation (around Rec. 709 luminance), contrast, brightness, gamma, then invert, per pixel;
    /// alpha is unchanged.
    static func adjust(_ b: Bitmap, _ a: Adjustments) -> Bitmap {
        guard !a.isIdentity else { return b }
        // Same input color → same output, so memoize.
        var cache: [UInt32: RGBA] = [:]
        var out = b
        for (i, p) in b.pixels.enumerated() {
            if let hit = cache[p.rgbKey] { out.pixels[i] = RGBA(hit.r, hit.g, hit.b, p.a); continue }
            var v = SIMD3(Double(p.r), Double(p.g), Double(p.b)) / 255
            let l = 0.2126 * v.x + 0.7152 * v.y + 0.0722 * v.z
            v = SIMD3(repeating: l) + (v - SIMD3(repeating: l)) * a.saturation
            v = (v - 0.5) * a.contrast + 0.5 + a.brightness
            v = v.clamped(lowerBound: SIMD3(repeating: 0), upperBound: SIMD3(repeating: 1))
            if a.gamma != 1 { v = SIMD3(pow(v.x, 1 / a.gamma), pow(v.y, 1 / a.gamma), pow(v.z, 1 / a.gamma)) }
            if a.invert { v = 1 - v }
            let c = RGBA(UInt8((v.x * 255).rounded()), UInt8((v.y * 255).rounded()), UInt8((v.z * 255).rounded()), p.a)
            cache[p.rgbKey] = c
            out.pixels[i] = c
        }
        return out
    }

    /// Per-channel median over a (2r+1)² window: removes isolated noise (JPEG, scans) while keeping
    /// edges. Transparent pixels are left alone and ignored as neighbors.
    static func median(_ src: Bitmap, radius: Int, alphaThreshold: UInt8 = 128) -> Bitmap {
        guard radius > 0 else { return src }
        let w = src.width, h = src.height
        var out = src
        var rs: [UInt8] = [], gs: [UInt8] = [], bs: [UInt8] = []
        for y in 0..<h {
            for x in 0..<w where src[x, y].a >= alphaThreshold {
                rs.removeAll(keepingCapacity: true); gs.removeAll(keepingCapacity: true); bs.removeAll(keepingCapacity: true)
                for yy in max(0, y - radius)...min(h - 1, y + radius) {
                    for xx in max(0, x - radius)...min(w - 1, x + radius) {
                        let n = src[xx, yy]
                        guard n.a >= alphaThreshold else { continue }
                        rs.append(n.r); gs.append(n.g); bs.append(n.b)
                    }
                }
                rs.sort(); gs.sort(); bs.sort()
                let m = rs.count / 2
                out[x, y] = RGBA(rs[m], gs[m], bs[m], src[x, y].a)
            }
        }
        return out
    }
}
