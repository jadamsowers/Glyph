import CoreGraphics
import Foundation

/// Row-major RGBA pixels with row 0 at the top.
public struct Bitmap: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public var pixels: [RGBA]

    public init(width: Int, height: Int, pixels: [RGBA]) {
        precondition(width > 0 && height > 0 && pixels.count == width * height)
        self.width = width; self.height = height; self.pixels = pixels
    }

    public init(width: Int, height: Int, generator: (Int, Int) -> RGBA) {
        var px: [RGBA] = []
        px.reserveCapacity(width * height)
        for y in 0..<height { for x in 0..<width { px.append(generator(x, y)) } }
        self.init(width: width, height: height, pixels: px)
    }

    public subscript(x: Int, y: Int) -> RGBA {
        get { pixels[y * width + x] }
        set { pixels[y * width + x] = newValue }
    }

    /// Draws `image` scaled to the given size (defaults to its own size).
    public init(cgImage image: CGImage, width: Int? = nil, height: Int? = nil) {
        let w = width ?? image.width, h = height ?? image.height
        self = Bitmap.render(width: w, height: h, flipped: false) { ctx in
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
    }

    public func makeCGImage() -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for (i, p) in pixels.enumerated() {
            let a = Int(p.a)
            bytes[i * 4] = UInt8((Int(p.r) * a + 127) / 255)
            bytes[i * 4 + 1] = UInt8((Int(p.g) * a + 127) / 255)
            bytes[i * 4 + 2] = UInt8((Int(p.b) * a + 127) / 255)
            bytes[i * 4 + 3] = p.a
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: Bitmap.colorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    /// Creates a bitmap by drawing into an offscreen CoreGraphics context.
    /// With `flipped` (the default) the context uses y-down coordinates matching pixel rows.
    public static func render(width: Int, height: Int, flipped: Bool = true, _ draw: (CGContext) -> Void) -> Bitmap {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buf in
            let ctx = CGContext(
                data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            if flipped {
                ctx.translateBy(x: 0, y: CGFloat(height))
                ctx.scaleBy(x: 1, y: -1)
            }
            draw(ctx)
        }
        var px = [RGBA](repeating: .clear, count: width * height)
        for i in 0..<px.count {
            let a = Int(bytes[i * 4 + 3])
            guard a > 0 else { continue }
            func un(_ v: UInt8) -> UInt8 { UInt8(min(255, (Int(v) * 255 + a / 2) / a)) }
            px[i] = RGBA(un(bytes[i * 4]), un(bytes[i * 4 + 1]), un(bytes[i * 4 + 2]), UInt8(a))
        }
        return Bitmap(width: width, height: height, pixels: px)
    }

    static var colorSpace: CGColorSpace { CGColorSpace(name: CGColorSpace.sRGB)! }
}
