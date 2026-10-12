import CoreVideo
import Foundation
import Vision

/// Makes the background transparent before tracing, so only the foreground is vectorized.
public struct BackgroundRemoval: Sendable, Equatable {
    public enum Method: String, Sendable, CaseIterable {
        /// Solid colour for logos and graphics, subject detection for photos.
        case auto
        /// Flood-fill the colour that dominates the image border.
        case solid
        /// Apple Vision subject lifting (as in Photos and Preview).
        case subject

        /// The concrete method for an image of this kind.
        public func resolved(for kind: ImageKind) -> Method {
            self == .auto ? (kind == .photo ? .subject : .solid) : self
        }
    }

    public var method: Method
    /// How far (ΔE) a pixel may be from the background colour and still count as background.
    public var tolerance: Double
    /// Also clear same-coloured areas that don't touch the edge (e.g. the inside of an "O").
    public var removeEnclosed: Bool

    public init(method: Method = .auto, tolerance: Double = 8, removeEnclosed: Bool = true) {
        self.method = method; self.tolerance = tolerance; self.removeEnclosed = removeEnclosed
    }
}

/// What background removal actually did.
public enum BackgroundOutcome: Sendable, Equatable {
    /// This border colour was removed.
    case solid(RGBA)
    /// Vision's subject mask was applied.
    case subject
    /// Vision found no subject; this border colour was removed instead.
    case subjectFallback(RGBA)
    /// No colour dominates the border, so nothing was removed.
    case noDominantColor
    /// The border is already mostly transparent; nothing to do.
    case alreadyTransparent

    /// A one-line description for the UI and CLI.
    public var summary: String {
        switch self {
        case .solid(let c): "Removed \(c.hex) background"
        case .subject: "Removed background around the subject"
        case .subjectFallback(let c): "No subject found; removed \(c.hex) background"
        case .noDominantColor: "No single background colour found; nothing removed"
        case .alreadyTransparent: "Background is already transparent"
        }
    }
}

/// Resolved removal settings (processing px).
public struct BackgroundParams: Sendable, Equatable {
    /// `.solid` or `.subject` (never `.auto`).
    public var method: BackgroundRemoval.Method
    public var tolerance: Double
    public var removeEnclosed: Bool
    /// Enclosed background-coloured areas smaller than this stay (highlights, dots).
    public var minEnclosedArea: Int
    /// Anti-aliased fringes are judged against the shape colour found within this many px.
    public var fringeRadius = 2
}

enum BackgroundRemover {
    /// Share of the opaque border that must match one colour for it to count as the background.
    static let minBorderShare = 0.6

    static func remove(_ b: Bitmap, _ p: BackgroundParams, alphaThreshold: UInt8 = 128,
                       subjectMask: (Bitmap) -> [Float]? = VisionSubject.mask) -> (Bitmap, BackgroundOutcome)
    {
        if p.method == .subject {
            if let mask = subjectMask(b) { return (applyMask(b, mask: mask), .subject) }
            let (out, outcome) = removeSolid(b, p, alphaThreshold: alphaThreshold)
            if case .solid(let c) = outcome { return (out, .subjectFallback(c)) }
            return (out, outcome)
        }
        return removeSolid(b, p, alphaThreshold: alphaThreshold)
    }

    /// Multiplies alpha by a per-pixel mask in 0…1 (row-major, same size as the bitmap).
    static func applyMask(_ b: Bitmap, mask: [Float]) -> Bitmap {
        var out = b
        for i in out.pixels.indices {
            let m = Double(max(0, min(1, mask[i])))
            out.pixels[i].a = UInt8((Double(out.pixels[i].a) * m).rounded())
        }
        return out
    }

    // MARK: Solid colour

    static func removeSolid(_ b: Bitmap, _ p: BackgroundParams, alphaThreshold: UInt8) -> (Bitmap, BackgroundOutcome) {
        let w = b.width, h = b.height
        var border: [Int] = []
        for x in 0..<w { border.append(x); if h > 1 { border.append((h - 1) * w + x) } }
        if h > 2 { for y in 1..<(h - 1) { border.append(y * w); if w > 1 { border.append(y * w + w - 1) } } }
        let opaqueBorder = border.filter { b.pixels[$0].a >= alphaThreshold }
        guard opaqueBorder.count * 2 > border.count else { return (b, .alreadyTransparent) }
        guard let bg = dominantColor(opaqueBorder.map { b.pixels[$0] }, tolerance: p.tolerance) else { return (b, .noDominantColor) }

        let bgLab = Lab(bg)
        let lab = b.pixels.map(Lab.init)
        let opaque = b.pixels.map { $0.a >= alphaThreshold }
        let near = (0..<lab.count).map { opaque[$0] && lab[$0].distance(to: bgLab) <= p.tolerance }
        var removed = [Bool](repeating: false, count: lab.count)

        // Background-coloured areas: those touching the edge, plus (optionally) large enclosed ones.
        var seen = [Bool](repeating: false, count: lab.count)
        for start in 0..<lab.count where near[start] && !seen[start] {
            var stack = [start], members: [Int] = [], touchesEdge = false
            seen[start] = true
            while let i = stack.popLast() {
                members.append(i)
                let x = i % w, y = i / w
                if x == 0 || y == 0 || x == w - 1 || y == h - 1 { touchesEdge = true }
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where nx >= 0 && ny >= 0 && nx < w && ny < h {
                    let j = ny * w + nx
                    if near[j] && !seen[j] { seen[j] = true; stack.append(j) }
                }
            }
            if touchesEdge || (p.removeEnclosed && members.count >= p.minEnclosedArea) {
                for i in members { removed[i] = true }
            }
        }

        // Anti-aliased fringe: a pixel next to removed background goes with whichever it is closer
        // to — the background, or the most distinct shape colour nearby — so shapes keep their size.
        let r = max(1, p.fringeRadius)
        for _ in 0...r {
            var grow: [Int] = []
            for i in 0..<lab.count where opaque[i] && !removed[i] {
                let x = i % w, y = i / w
                let touches = [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)].contains { nx, ny in
                    nx >= 0 && ny >= 0 && nx < w && ny < h && removed[ny * w + nx]
                }
                guard touches else { continue }
                var shape = lab[i], farthest = lab[i].distance(to: bgLab)
                for ny in max(0, y - r)...min(h - 1, y + r) {
                    for nx in max(0, x - r)...min(w - 1, x + r) {
                        let j = ny * w + nx
                        guard opaque[j] && !removed[j] else { continue }
                        let d = lab[j].distance(to: bgLab)
                        if d > farthest { farthest = d; shape = lab[j] }
                    }
                }
                if lab[i].distance(to: bgLab) < lab[i].distance(to: shape) { grow.append(i) }
            }
            if grow.isEmpty { break }
            for i in grow { removed[i] = true }
        }

        var out = b
        for i in out.pixels.indices where removed[i] { out.pixels[i] = .clear }
        return (out, .solid(bg))
    }

    /// The border's most common colour (by 5-bit-per-channel bucket, then averaged over the
    /// pixels within `tolerance` of it), if at least `minBorderShare` of the border matches it.
    static func dominantColor(_ pixels: [RGBA], tolerance: Double) -> RGBA? {
        var counts: [Int: Int] = [:]
        for p in pixels { counts[Int(p.r >> 3) << 10 | Int(p.g >> 3) << 5 | Int(p.b >> 3), default: 0] += 1 }
        guard let top = counts.max(by: { $0.value < $1.value })?.key else { return nil }
        let seed = Lab(RGBA(UInt8((top >> 10) << 3 | 4), UInt8(((top >> 5) & 31) << 3 | 4), UInt8((top & 31) << 3 | 4)))
        let matching = pixels.filter { Lab($0).distance(to: seed) <= tolerance + 4 }
        guard !matching.isEmpty else { return nil }
        func mean(_ k: KeyPath<RGBA, UInt8>) -> UInt8 {
            UInt8((Double(matching.reduce(0) { $0 + Int($1[keyPath: k]) }) / Double(matching.count)).rounded())
        }
        let color = RGBA(mean(\.r), mean(\.g), mean(\.b))
        let lab = Lab(color)
        let share = Double(pixels.filter { Lab($0).distance(to: lab) <= tolerance }.count) / Double(pixels.count)
        return share >= minBorderShare ? color : nil
    }
}

/// Apple Vision's foreground subject mask.
enum VisionSubject {
    /// Per-pixel foreground probability (row-major, bitmap size), or nil when no subject is found.
    static func mask(_ b: Bitmap) -> [Float]? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: b.makeCGImage())
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.first, !observation.allInstances.isEmpty,
              let buffer = try? observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler),
              CVPixelBufferGetWidth(buffer) == b.width, CVPixelBufferGetHeight(buffer) == b.height
        else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let format = CVPixelBufferGetPixelFormatType(buffer)
        var mask = [Float](repeating: 0, count: b.width * b.height)
        for y in 0..<b.height {
            let row = base.advanced(by: y * rowBytes)
            for x in 0..<b.width {
                mask[y * b.width + x] = switch format {
                case kCVPixelFormatType_OneComponent32Float: row.assumingMemoryBound(to: Float.self)[x]
                case kCVPixelFormatType_OneComponent8: Float(row.assumingMemoryBound(to: UInt8.self)[x]) / 255
                default: 1
                }
            }
        }
        return mask
    }
}
