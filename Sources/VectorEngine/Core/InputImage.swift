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

    public init(bitmap: Bitmap, originalWidth: Int? = nil, originalHeight: Int? = nil) {
        self.bitmap = bitmap
        self.originalWidth = originalWidth ?? bitmap.width
        self.originalHeight = originalHeight ?? bitmap.height
    }

    /// Scales the image down (never up) so its long side is at most `maxDimension`.
    public init(cgImage: CGImage, maxDimension: Int) {
        let w = cgImage.width, h = cgImage.height
        let s = min(1, Double(max(1, maxDimension)) / Double(max(w, h)))
        let pw = max(1, Int((Double(w) * s).rounded())), ph = max(1, Int((Double(h) * s).rounded()))
        self.init(bitmap: Bitmap(cgImage: cgImage, width: pw, height: ph), originalWidth: w, originalHeight: h)
    }

    public static func load(contentsOf url: URL, maxDimension: Int) throws -> InputImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw VectorEngineError.unreadableImage(url.path) }
        return InputImage(cgImage: image, maxDimension: maxDimension)
    }
}
