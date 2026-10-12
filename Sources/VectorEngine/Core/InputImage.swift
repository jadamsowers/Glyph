import CoreGraphics
import Foundation
import ImageIO

public enum VectorEngineError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case unreadableImage(String)

    public var description: String {
        switch self {
        case .unreadableImage(let path): "Could not read an image from \(path)"
        }
    }
    public var errorDescription: String? { description }
}

/// The image being vectorized, at processing resolution, plus its original size.
public struct InputImage: Sendable {
    /// Identifies this input so a later pipeline run knows whether earlier results apply.
    public let id = UUID()
    public let bitmap: Bitmap
    public let originalWidth: Int
    public let originalHeight: Int

    /// Multiply processing coordinates by these to get output (original-pixel) coordinates.
    public var scaleX: Double { Double(originalWidth) / Double(bitmap.width) }
    public var scaleY: Double { Double(originalHeight) / Double(bitmap.height) }
    /// Integer factor the image was upscaled by for processing (1 = not upscaled).
    public var upscale: Int { max(1, Int((Double(bitmap.width) / Double(originalWidth)).rounded())) }

    public init(bitmap: Bitmap, originalWidth: Int? = nil, originalHeight: Int? = nil) {
        self.bitmap = bitmap
        self.originalWidth = originalWidth ?? bitmap.width
        self.originalHeight = originalHeight ?? bitmap.height
    }

    /// Scales the image down so its long side is at most `maxDimension`. Images whose long side
    /// is below `minDimension` are instead upscaled smoothly (bicubic) to at least twice that, by
    /// an integer factor between 4× and 8×: at icon sizes, anti-aliased edge shades then yield
    /// sub-pixel edge positions and the tracer's pixel-sized heuristics work at a sensible scale.
    /// (Smaller factors measured worse: too little sub-pixel gain for the extra detail.)
    ///
    /// `highDetail` upscales larger images too — up to 4×, keeping the processed long side within
    /// `highDetailMaxDimension` — so features only a pixel or two wide in the source (small stars,
    /// ® marks) are traced instead of melting into blobs. Slower, and it can leave thin outlines
    /// along anti-aliased edges whose blend shades match another palette color.
    public init(cgImage: CGImage, maxDimension: Int, minDimension: Int = 0, highDetail: Bool = false) {
        let w = cgImage.width, h = cgImage.height
        let longSide = max(w, h)
        let small = minDimension > 0 && longSide < minDimension
        if small || highDetail {
            let factor = small ? min(8, max(4, Int((2 * Double(minDimension) / Double(longSide)).rounded(.up))))
                               : min(4, InputImage.highDetailMaxDimension / longSide)
            let original = Bitmap(cgImage: cgImage)
            // Pixel art's steps are real detail; blurring them would destroy exactly that.
            if factor > 1 && !Analyzer.looksLikePixelArt(original) {
                self.init(bitmap: original.upscaled(by: factor), originalWidth: w, originalHeight: h)
                return
            }
        }
        let s = min(1, Double(max(1, maxDimension)) / Double(max(w, h)))
        let pw = max(1, Int((Double(w) * s).rounded())), ph = max(1, Int((Double(h) * s).rounded()))
        self.init(bitmap: Bitmap(cgImage: cgImage, width: pw, height: ph), originalWidth: w, originalHeight: h)
    }

    /// Processed long side that high-detail upscaling stays within.
    public static let highDetailMaxDimension = 6000

    public static func load(contentsOf url: URL, maxDimension: Int, minDimension: Int = 0, highDetail: Bool = false) throws -> InputImage {
        InputImage(cgImage: try orientedImage(contentsOf: url), maxDimension: maxDimension, minDimension: minDimension, highDetail: highDetail)
    }

    /// Decodes the first image in a file at full size, applying its EXIF orientation (portrait
    /// phone photos are often stored sideways with an orientation tag).
    public static func orientedImage(contentsOf url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int
        else { throw VectorEngineError.unreadableImage(url.path) }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(w, h),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { throw VectorEngineError.unreadableImage(url.path) }
        return image
    }
}
