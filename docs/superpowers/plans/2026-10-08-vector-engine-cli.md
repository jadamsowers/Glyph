# VectorEngine + CLI Implementation Plan (Plan 1 of 2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Swift package whose `VectorEngine` library turns a bitmap into a compact, gap-free SVG through eight inspectable stages, plus a `vectorize` CLI using it.

**Architecture:** A pipeline of pure stage functions (analyze → prefilter → quantize → segment → contours → polygon → curves → svg) over `Sendable` value types, held in a `PipelineState` so a later run can reuse unchanged stages. Region boundaries are extracted once as shared crack-edge chains between junctions; each chain is simplified and curve-fitted once and then assembled into region outlines (shared-edges mode) or outer-only outlines painted largest-first (stacked mode). The walking skeleton (Tasks 1–8) produces real SVGs from straight pixel-edge outlines; Tasks 9–10 swap in the polygon and Bézier stages; Task 11 adds stage pictures and streaming.

**Tech Stack:** Swift 6 (tools 6.0, Swift 6 language mode), CoreGraphics/ImageIO, swift-testing, swift-argument-parser (CLI only). macOS 14+.

**Spec:** `docs/superpowers/specs/2026-10-08-image-vectorizer-design.md`

## Global Constraints

- Package `swift-tools-version:6.0`, platform `.macOS(.v14)`, Swift 6 language mode (strict concurrency): every public stage type is `Sendable`.
- `VectorEngine` has **no** package dependencies. The CLI may depend only on `swift-argument-parser` (Apache-2.0). No GPL code; no potrace code.
- App-Store-safe: no `Process`, no external binaries, no network.
- Tests use `import Testing` (swift-testing). They need full Xcode selected (`xcode-select -p` → `/Applications/Xcode.app/...`); Command Line Tools alone cannot run them.
- Coordinates: y-down, (0,0) = top-left pixel corner. Pixel (x,y) covers [x,x+1]×[y,y+1].
- SVG: `viewBox="0 0 W H"` in **original** image pixels; `fill-rule="evenodd"`; relative commands; default precision 1 decimal.
- Defaults: max processing dimension 2000 px; logo → shared edges, no prefilter, speck 4, detail 0.6, smoothness 0.5; photo → stacked, bilateral prefilter, 16 colors, speck 24, detail 0.3, smoothness 0.6.
- Keep test images ≤ 64 px per side unless a test is specifically about size (debug builds are slow).

## Review Focus

1. **Transparent-background PNG logo** — the transparent area produces no path and stays transparent; the logo is still classified as a logo. (Task 2 `transparentPixelsAreExcluded`, Task 5 `transparentBackgroundEmitsNoBackgroundPath`, Task 6 `transparentLogoIsLogo`)
2. **JPEG-compressed logo** — compression noise and chroma fringes don't inflate the palette or flip it to "photo". (Task 2 `jpegLikeNoiseDoesNotAddColors`, `chromaFringesAreNotPaletteColors`, Task 6 `jpegNoisyLogoIsLogo`)
3. **Thin ring around a larger disk in stacked mode** — ordering by outer-boundary area (not pixel count) keeps the disk visible. (Task 10 `stackedModeKeepsRingAndDiskVisible`)
4. **Same-colored pixels touching only diagonally** — they are separate regions, every boundary loop closes, and nothing is left uncovered. (Task 3 `diagonalNeighborsAreNotConnected`, Task 4 `regionTouchingItselfDiagonally`)
5. **Very large image** — it is downscaled for processing, but the SVG is in original coordinates. (Task 1 `inputImageDownscalesLongSide`, Task 7 `downscaledInputIsWrittenAtOriginalSize`)

## File Map

```
Package.swift
.gitignore
scripts/make-samples.swift                      # sample PNG/JPEG generator for manual runs
Sources/VectorEngine/
  Core/Color.swift        RGBA, Lab
  Core/Geometry.swift     Vec2, LatticePoint
  Core/Random.swift       SplitMix64
  Core/Kinds.swift        ImageKind, TracingMode
  Core/Bitmap.swift       Bitmap (+ CG conversion, offscreen render)
  Core/InputImage.swift   InputImage, VectorEngineError
  Analyze/Analyzer.swift  Analysis, ClassifierParams, Analyzer
  Prefilter/Prefilter.swift  PrefilterParams, Prefilter (bilateral)
  Quantize/PaletteBuilder.swift  ColorCluster, PaletteBuilder
  Quantize/Quantizer.swift       QuantizeParams, QuantizedImage, Quantizer (logo + assign)
  Quantize/KMeans.swift          Quantizer.photo, Quantizer.quantize
  Segment/Segmenter.swift  Region, Segmentation, SegmentParams, Segmenter
  Trace/Topology.swift     Chain, ChainRef, RegionLoops, Topology (+ Dir, CrackGrid)
  Polygon/PolygonBuilder.swift  PolyChain, PolygonBuilder
  Curves/BezierFit.swift   BezierFit (Schneider)
  Curves/CurveFitter.swift CurveFitter
  Path/PathModel.swift     PathSegment, Curve, Subpath, VectorShape
  Path/ShapeAssembler.swift
  Path/ShapeRenderer.swift
  Path/SVGWriter.swift     VectorStats, VectorResult, SVGWriter
  Pipeline/Options.swift   Options, AdvancedOptions, ResolvedOptions, PolygonParams, CurveParams, OutputParams
  Pipeline/Pipeline.swift  Stage, PipelineState, StageEvent, Pipeline, Vectorizer
  Render/StageRenderer.swift
Sources/vectorize/VectorizeCommand.swift
Tests/VectorEngineTests/
  TestImages.swift CoreTests.swift QuantizeTests.swift SegmentTests.swift TopologyTests.swift
  AssemblyTests.swift AnalysisTests.swift PipelineTests.swift PolygonTests.swift CurveTests.swift RenderTests.swift
```

---

### Task 1: Package scaffold and core types

**Files:**
- Create: `Package.swift`, `.gitignore`, `Sources/VectorEngine/Core/{Color,Geometry,Random,Kinds,Bitmap,InputImage}.swift`
- Test: `Tests/VectorEngineTests/CoreTests.swift`

**Interfaces:**
- Produces: `RGBA(_ r:_ g:_ b:_ a: = 255)`, `.clear`, `.hex`, internal `.rgbKey: UInt32`; `Lab(_ c: RGBA)`, `Lab(l:a:b:)`, `distance(to:)`; `Vec2(_ x:_ y:)` with `+ - * prefix- dot length normalized distance(to:) distance(toSegment:_:) scaled(_:_:)`, `.zero`; `LatticePoint(_ x: Int, _ y: Int)`, `.vec`; internal `SplitMix64(seed:)`; `ImageKind {logo, photo}`; `TracingMode {sharedEdges, stacked}`; `Bitmap(width:height:pixels:)`, `Bitmap(width:height:generator:)`, `subscript(x:y:)`, `Bitmap(cgImage:width:height:)`, `makeCGImage()`, `static render(width:height:flipped: = true, _ draw: (CGContext) -> Void) -> Bitmap`; `InputImage(bitmap:originalWidth:originalHeight:)`, `InputImage(cgImage:maxDimension:)`, `InputImage.load(contentsOf:maxDimension:) throws`, `.id`, `.scaleX`, `.scaleY`; `VectorEngineError.unreadableImage(String)`.

- [ ] **Step 0: Confirm the toolchain**

Run: `xcode-select -p && xcodebuild -version`
Expected: a path inside `Xcode.app` and an Xcode version. If it prints `/Library/Developer/CommandLineTools`, stop and ask the user to run `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`.

- [ ] **Step 1: Create the package skeleton**

`Package.swift`:
```swift
// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "VectorEngine",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "VectorEngine", targets: ["VectorEngine"]),
    ],
    targets: [
        .target(name: "VectorEngine"),
        .testTarget(name: "VectorEngineTests", dependencies: ["VectorEngine"]),
    ]
)
```

`.gitignore`:
```
.build/
.swiftpm/
DerivedData/
xcuserdata/
samples/
out/
```

- [ ] **Step 2: Write the failing tests**

`Tests/VectorEngineTests/CoreTests.swift`:
```swift
import CoreGraphics
import Foundation
import Testing
@testable import VectorEngine

@Suite struct CoreTests {
    @Test func labOfWhiteAndBlack() {
        let w = Lab(RGBA(255, 255, 255))
        #expect(abs(w.l - 100) < 0.01)
        #expect(abs(w.a) < 0.05 && abs(w.b) < 0.05)
        #expect(abs(Lab(RGBA(0, 0, 0)).l) < 0.01)
    }

    @Test func labOfPureRed() {
        let r = Lab(RGBA(255, 0, 0))
        #expect(abs(r.l - 53.24) < 0.05)
        #expect(abs(r.a - 80.09) < 0.1)
        #expect(abs(r.b - 67.20) < 0.1)
    }

    @Test func hexString() {
        #expect(RGBA(255, 16, 0).hex == "#ff1000")
    }

    @Test func segmentDistance() {
        #expect(Vec2(5, 3).distance(toSegment: Vec2(0, 0), Vec2(10, 0)) == 3)
        #expect(Vec2(-4, 3).distance(toSegment: Vec2(0, 0), Vec2(10, 0)) == 5)
    }

    @Test func bitmapRoundTripsThroughCGImage() {
        let src = Bitmap(width: 3, height: 2) { x, y in
            x == 2 && y == 1 ? RGBA(200, 100, 50, 128) : RGBA(UInt8(x * 80), UInt8(y * 200), 7)
        }
        let back = Bitmap(cgImage: src.makeCGImage())
        #expect(back.width == 3 && back.height == 2)
        for y in 0..<2 { for x in 0..<3 where !(x == 2 && y == 1) { #expect(back[x, y] == src[x, y]) } }
        let semi = back[2, 1]
        #expect(semi.a == 128)
        #expect(abs(Int(semi.r) - 200) <= 2 && abs(Int(semi.g) - 100) <= 2 && abs(Int(semi.b) - 50) <= 2)
    }

    @Test func renderUsesTopDownRows() {
        let b = Bitmap.render(width: 4, height: 4) { ctx in
            ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 1))
        }
        #expect(b[0, 0] == RGBA(255, 0, 0))
        #expect(b[0, 3] == .clear)
    }

    // Review focus: very large image is downscaled but remembers its original size.
    @Test func inputImageDownscalesLongSide() {
        let big = Bitmap(width: 100, height: 50) { _, _ in RGBA(10, 20, 30) }
        let input = InputImage(cgImage: big.makeCGImage(), maxDimension: 40)
        #expect(input.bitmap.width == 40 && input.bitmap.height == 20)
        #expect(input.originalWidth == 100 && input.originalHeight == 50)
        #expect(input.scaleX == 2.5 && input.scaleY == 2.5)
    }

    @Test func inputImageNeverUpscales() {
        let small = Bitmap(width: 10, height: 10) { _, _ in RGBA(1, 2, 3) }
        let input = InputImage(cgImage: small.makeCGImage(), maxDimension: 2000)
        #expect(input.bitmap.width == 10 && input.scaleX == 1)
    }

    @Test func unreadableFileThrows() {
        #expect(throws: VectorEngineError.self) {
            try InputImage.load(contentsOf: URL(fileURLWithPath: "/nonexistent/x.png"), maxDimension: 100)
        }
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --filter CoreTests`
Expected: build failure, with errors such as "cannot find 'Lab' in scope".

- [ ] **Step 4: Implement the core types**

`Sources/VectorEngine/Core/Color.swift`:
```swift
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
```

`Sources/VectorEngine/Core/Geometry.swift`:
```swift
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
```

`Sources/VectorEngine/Core/Random.swift`:
```swift
/// Small deterministic PRNG so results are reproducible from run to run.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
```

`Sources/VectorEngine/Core/Kinds.swift`:
```swift
/// Which pipeline variant suits an image.
public enum ImageKind: String, Sendable, CaseIterable {
    case logo, photo
}

/// How region outlines are emitted.
public enum TracingMode: String, Sendable, CaseIterable {
    /// Adjacent regions share identical boundary curves; holes are cut out.
    case sharedEdges
    /// Regions are painted largest-first using only their outer boundary.
    case stacked
}
```

`Sources/VectorEngine/Core/Bitmap.swift`:
```swift
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
```

`Sources/VectorEngine/Core/InputImage.swift`:
```swift
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
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter CoreTests`
Expected: all 9 tests pass.

- [ ] **Step 6: Commit**

```bash
git add Package.swift .gitignore Sources Tests
git commit -m "feat: package scaffold and core color/geometry/bitmap types"
```

---

### Task 2: Logo quantization (palette discovery + nearest-color assignment)

**Files:**
- Create: `Sources/VectorEngine/Quantize/PaletteBuilder.swift`, `Sources/VectorEngine/Quantize/Quantizer.swift`
- Test: `Tests/VectorEngineTests/TestImages.swift`, `Tests/VectorEngineTests/QuantizeTests.swift`

**Interfaces:**
- Consumes: `RGBA`, `Lab`, `Bitmap`, `SplitMix64`, `ImageKind` (Task 1).
- Produces:
  - `struct ColorCluster { color: RGBA; lab: Lab; count: Int }`
  - `PaletteBuilder.clusters(of: Bitmap, alphaThreshold: UInt8, mergeDistance: Double, maxClusters: Int = 256) -> (clusters: [ColorCluster], opaqueCount: Int)`
  - `PaletteBuilder.palette(from:total:maxColors:minShare:blendSlack:blendKeepShare:) -> [ColorCluster]`
  - `public struct QuantizeParams` (`init(kind:colorCount:)`; vars `alphaThreshold=128, mergeDistance=10, minColorShare=0.001, blendSlack=0.15, blendKeepShare=0.03, kmeansIterations=12, kmeansSampleSize=20_000`)
  - `public struct QuantizedImage { width, height, palette: [RGBA], indices: [Int32] /* -1 transparent */ ; makeBitmap() }`
  - `Quantizer.logo(_:params:)`, `Quantizer.assign(_:palette:alphaThreshold:)`
  - Test helpers `TestImages.*` (used by every later test file).

- [ ] **Step 1: Write the shared test helpers**

`Tests/VectorEngineTests/TestImages.swift`:
```swift
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
```

- [ ] **Step 2: Write the failing tests**

`Tests/VectorEngineTests/QuantizeTests.swift`:
```swift
import Testing
@testable import VectorEngine

@Suite struct QuantizeTests {
    func logo(_ b: Bitmap, colors: Int = 8) -> QuantizedImage {
        Quantizer.logo(b, params: QuantizeParams(kind: .logo, colorCount: colors))
    }

    @Test func antialiasedTwoColorLogoGetsTwoColors() {
        let q = logo(TestImages.circle(antialias: true))
        #expect(q.palette.count == 2)
        let labs = q.palette.map { Lab($0) }
        #expect(labs.contains { $0.distance(to: Lab(TestImages.red)) < 3 })
        #expect(labs.contains { $0.distance(to: Lab(TestImages.white)) < 3 })
    }

    @Test func nearestColorIsChosenInLab() {
        let b = Bitmap(width: 2, height: 1) { x, _ in x == 0 ? RGBA(100, 100, 100) : RGBA(200, 200, 200) }
        let q = Quantizer.assign(b, palette: [TestImages.black, TestImages.white], alphaThreshold: 128)
        #expect(q.indices == [0, 1])
    }

    // Review focus: transparent-background logo.
    @Test func transparentPixelsAreExcluded() {
        let q = logo(TestImages.circle(bg: .clear, antialias: true))
        #expect(q.palette.count == 1)
        #expect(q.indices[0] == -1)
        #expect(q.indices[24 * 48 + 24] == 0)
    }

    // Review focus: JPEG-compressed logo.
    @Test func jpegLikeNoiseDoesNotAddColors() {
        let q = logo(TestImages.noisy(TestImages.circle(antialias: true), amplitude: 3))
        #expect(q.palette.count == 2)
    }

    // Review focus: JPEG chroma subsampling leaves fringe colors that sit off the straight blend line.
    @Test func chromaFringesAreNotPaletteColors() {
        let fringe = RGBA(254, 252, 216)   // measured on a real JPEG edge between white and orange
        let orange = RGBA(241, 166, 26)
        let b = Bitmap(width: 64, height: 64) { x, _ in x < 31 ? TestImages.white : (x == 31 ? fringe : orange) }
        #expect(logo(b).palette.count == 2)
    }

    @Test func colorCountCapsPaletteKeepingMostFrequent() {
        let b = TestImages.grid(["WWWWRRRB", "WWWWRRRG"], scale: 4)
        let q = logo(b, colors: 2)
        #expect(Set(q.palette) == [TestImages.white, TestImages.red])
    }

    @Test func largeMidtoneAreaIsKeptEvenOnABlendLine() {
        let gray = RGBA(128, 128, 128)
        let b = Bitmap(width: 64, height: 8) { x, _ in x < 24 ? TestImages.black : (x < 40 ? gray : TestImages.white) }
        #expect(logo(b).palette.count == 3)
    }

    @Test func fullyTransparentImageHasEmptyPalette() {
        let q = logo(Bitmap(width: 4, height: 4) { _, _ in .clear })
        #expect(q.palette.isEmpty && q.indices.allSatisfy { $0 == -1 })
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --filter QuantizeTests`
Expected: build failure, with errors such as "cannot find 'Quantizer' in scope".

- [ ] **Step 4: Implement palette discovery and assignment**

`Sources/VectorEngine/Quantize/PaletteBuilder.swift`:
```swift
/// A group of perceptually similar colors found in an image.
struct ColorCluster: Sendable, Equatable {
    var color: RGBA
    var lab: Lab
    var count: Int
}

enum PaletteBuilder {
    /// Buckets opaque pixels (5 bits per channel), then greedily merges buckets, most
    /// frequent first, into clusters whose seed is within `mergeDistance` (Lab).
    /// Cluster colors are count-weighted means. Sorted by count, descending.
    static func clusters(of bitmap: Bitmap, alphaThreshold: UInt8, mergeDistance: Double, maxClusters: Int = 256)
        -> (clusters: [ColorCluster], opaqueCount: Int)
    {
        var sums: [Int: (r: Int, g: Int, b: Int, n: Int)] = [:]
        var opaque = 0
        for p in bitmap.pixels where p.a >= alphaThreshold {
            opaque += 1
            let key = Int(p.r >> 3) << 10 | Int(p.g >> 3) << 5 | Int(p.b >> 3)
            var s = sums[key] ?? (0, 0, 0, 0)
            s.r += Int(p.r); s.g += Int(p.g); s.b += Int(p.b); s.n += 1
            sums[key] = s
        }
        let buckets = sums.values
            .map { s in (color: RGBA(UInt8(s.r / s.n), UInt8(s.g / s.n), UInt8(s.b / s.n)), n: s.n) }
            .sorted { $0.n != $1.n ? $0.n > $1.n : $0.color.rgbKey < $1.color.rgbKey }

        struct Acc { var seed: Lab; var r = 0, g = 0, b = 0, n = 0 }
        var accs: [Acc] = []
        for bucket in buckets {
            let lab = Lab(bucket.color)
            var target = -1, best = Double.infinity
            for (i, acc) in accs.enumerated() {
                let d = acc.seed.distance(to: lab)
                if d < best { best = d; target = i }
            }
            if target < 0 || best >= mergeDistance {
                guard accs.count < maxClusters else { continue }
                accs.append(Acc(seed: lab))
                target = accs.count - 1
            }
            accs[target].r += Int(bucket.color.r) * bucket.n
            accs[target].g += Int(bucket.color.g) * bucket.n
            accs[target].b += Int(bucket.color.b) * bucket.n
            accs[target].n += bucket.n
        }
        let clusters = accs.map { a in
            let c = RGBA(UInt8(a.r / a.n), UInt8(a.g / a.n), UInt8(a.b / a.n))
            return ColorCluster(color: c, lab: Lab(c), count: a.n)
        }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.color.rgbKey < $1.color.rgbKey }
        return (clusters, opaque)
    }

    /// Picks palette colors from clusters (most frequent first). Clusters under `minShare`
    /// are ignored; clusters under `blendKeepShare` that look like a mix of two already-chosen
    /// colors are treated as anti-aliasing or compression fringes and skipped.
    static func palette(from clusters: [ColorCluster], total: Int, maxColors: Int, minShare: Double,
                        blendSlack: Double, blendKeepShare: Double) -> [ColorCluster]
    {
        guard total > 0 else { return [] }
        var chosen: [ColorCluster] = []
        for c in clusters {
            if chosen.count >= maxColors { break }
            let share = Double(c.count) / Double(total)
            if share < minShare { break }
            if share < blendKeepShare && isBlend(c.color, of: chosen, slack: blendSlack) { continue }
            chosen.append(c)
        }
        if chosen.isEmpty, let first = clusters.first { chosen = [first] }
        return chosen
    }

    /// Whether `c` looks like a mix of two of `colors`: the RGB path a → c → b is at most
    /// (1 + slack) times the direct distance a → b. The slack scales with the colors' separation,
    /// so it also catches JPEG chroma fringes that sit off the straight blend line.
    static func isBlend(_ c: RGBA, of colors: [ColorCluster], slack: Double) -> Bool {
        func dist(_ x: RGBA, _ y: RGBA) -> Double {
            let dr = Double(x.r) - Double(y.r), dg = Double(x.g) - Double(y.g), db = Double(x.b) - Double(y.b)
            return (dr * dr + dg * dg + db * db).squareRoot()
        }
        for i in colors.indices {
            for j in colors.indices where j > i {
                let a = colors[i].color, b = colors[j].color
                let direct = dist(a, b)
                if direct > 0 && dist(a, c) + dist(c, b) <= direct * (1 + slack) { return true }
            }
        }
        return false
    }
}
```

`Sources/VectorEngine/Quantize/Quantizer.swift`:
```swift
public struct QuantizeParams: Sendable, Equatable {
    public var kind: ImageKind
    public var colorCount: Int
    public var alphaThreshold: UInt8 = 128
    public var mergeDistance: Double = 10
    public var minColorShare: Double = 0.001
    public var blendSlack: Double = 0.15
    public var blendKeepShare: Double = 0.03
    public var kmeansIterations: Int = 12
    public var kmeansSampleSize: Int = 20_000

    public init(kind: ImageKind, colorCount: Int) {
        self.kind = kind
        self.colorCount = colorCount
    }
}

/// Every pixel mapped to a palette entry; -1 marks transparent pixels.
public struct QuantizedImage: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let palette: [RGBA]
    public let indices: [Int32]

    public func makeBitmap() -> Bitmap {
        Bitmap(width: width, height: height, pixels: indices.map { $0 < 0 ? .clear : palette[Int($0)] })
    }
}

enum Quantizer {
    /// Logo palette: dominant flat colors, ignoring anti-aliasing blends.
    static func logo(_ bitmap: Bitmap, params p: QuantizeParams) -> QuantizedImage {
        let (clusters, total) = PaletteBuilder.clusters(of: bitmap, alphaThreshold: p.alphaThreshold, mergeDistance: p.mergeDistance)
        let chosen = PaletteBuilder.palette(
            from: clusters, total: total, maxColors: p.colorCount, minShare: p.minColorShare,
            blendSlack: p.blendSlack, blendKeepShare: p.blendKeepShare)
        return assign(bitmap, palette: chosen.map(\.color), alphaThreshold: p.alphaThreshold)
    }

    /// Maps each opaque pixel to the perceptually nearest palette color.
    static func assign(_ bitmap: Bitmap, palette: [RGBA], alphaThreshold: UInt8) -> QuantizedImage {
        let labs = palette.map { Lab($0) }
        var cache: [UInt32: Int32] = [:]
        var indices = [Int32](repeating: -1, count: bitmap.pixels.count)
        if !palette.isEmpty {
            for (i, p) in bitmap.pixels.enumerated() where p.a >= alphaThreshold {
                if let hit = cache[p.rgbKey] { indices[i] = hit; continue }
                let lab = Lab(p)
                var best = 0, bestD = Double.infinity
                for (j, q) in labs.enumerated() {
                    let d = q.distance(to: lab)
                    if d < bestD { bestD = d; best = j }
                }
                cache[p.rgbKey] = Int32(best)
                indices[i] = Int32(best)
            }
        }
        return QuantizedImage(width: bitmap.width, height: bitmap.height, palette: palette, indices: indices)
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter QuantizeTests`
Expected: all 8 tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/VectorEngine/Quantize Tests/VectorEngineTests
git commit -m "feat: logo palette discovery with anti-alias blend rejection"
```

---

### Task 3: Segmentation (connected regions + speck merging)

**Files:**
- Create: `Sources/VectorEngine/Segment/Segmenter.swift`
- Test: `Tests/VectorEngineTests/SegmentTests.swift`

**Interfaces:**
- Consumes: `QuantizedImage`, `Lab`, `RGBA` (Tasks 1–2); `TestImages.quantized` (Task 2).
- Produces:
  - `public struct Region { color: RGBA; pixelCount: Int }`
  - `public struct Segmentation { width, height, labels: [Int32] /* -1 = none */, regions: [Region]; func label(_ x: Int, _ y: Int) -> Int32 /* -1 outside */ }`
  - `public struct SegmentParams { var speckSize: Int; init(speckSize:) }`
  - `Segmenter.segment(_ q: QuantizedImage, params: SegmentParams) -> Segmentation`
  - Region labels are numbered in order of first appearance (row-major scan).

- [ ] **Step 1: Write the failing tests**

`Tests/VectorEngineTests/SegmentTests.swift`:
```swift
import Testing
@testable import VectorEngine

@Suite struct SegmentTests {
    func segment(_ rows: [String], speck: Int = 0) -> Segmentation {
        Segmenter.segment(TestImages.quantized(rows), params: SegmentParams(speckSize: speck))
    }

    @Test func sameColorPiecesThatDoNotTouchAreSeparate() {
        let s = segment(["RWR"])
        #expect(s.regions.count == 3)
        #expect(s.label(0, 0) != s.label(2, 0))
    }

    // Review focus: same-colored pixels touching only diagonally.
    @Test func diagonalNeighborsAreNotConnected() {
        let s = segment(["RW", "WR"])
        #expect(s.regions.count == 4)
    }

    @Test func specksMergeIntoTheirNeighbor() {
        let rows = (0..<20).map { y in
            String((0..<20).map { x -> Character in
                (x == 2 && y == 2) || ((10..<15).contains(x) && (10..<15).contains(y)) ? "K" : "W"
            })
        }
        let s = segment(rows, speck: 4)
        #expect(s.regions.count == 2)
        #expect(s.regions.map(\.pixelCount).sorted() == [25, 375])
        #expect(s.label(2, 2) == s.label(0, 0))
    }

    @Test func speckMergesIntoMostSimilarColor() {
        // A one-pixel blue speck between red and white joins whichever neighbor is closer in Lab.
        let s = segment(["RRRRBWWWW"], speck: 2)
        let dRed = Lab(TestImages.blue).distance(to: Lab(TestImages.red))
        let dWhite = Lab(TestImages.blue).distance(to: Lab(TestImages.white))
        let expected = dRed < dWhite ? s.label(0, 0) : s.label(8, 0)
        #expect(s.label(4, 0) == expected)
        #expect(s.regions.count == 2)
    }

    @Test func speckTouchingOnlyTransparencyIsKept() {
        let s = segment(["...", ".R.", "..."], speck: 4)
        #expect(s.regions.count == 1)
        #expect(s.label(1, 1) == 0 && s.label(0, 0) == -1)
    }

    @Test func outsideTheImageIsNone() {
        let s = segment(["R"])
        #expect(s.label(-1, 0) == -1 && s.label(0, 1) == -1 && s.label(0, 0) == 0)
    }

    @Test func largeUniformImageDoesNotOverflowTheStack() {
        let q = QuantizedImage(width: 600, height: 600, palette: [TestImages.white], indices: [Int32](repeating: 0, count: 360_000))
        let s = Segmenter.segment(q, params: SegmentParams(speckSize: 4))
        #expect(s.regions == [Region(color: TestImages.white, pixelCount: 360_000)])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SegmentTests`
Expected: build failure, with errors such as "cannot find 'Segmenter' in scope".

- [ ] **Step 3: Implement the segmenter**

`Sources/VectorEngine/Segment/Segmenter.swift`:
```swift
public struct Region: Sendable, Equatable {
    public var color: RGBA
    public var pixelCount: Int
}

/// Connected regions (4-connectivity) of equal palette color.
public struct Segmentation: Sendable, Equatable {
    public let width: Int
    public let height: Int
    /// Region label per pixel; -1 = transparent.
    public let labels: [Int32]
    public let regions: [Region]

    /// The label at (x, y), or -1 outside the image.
    @inline(__always)
    public func label(_ x: Int, _ y: Int) -> Int32 {
        x < 0 || y < 0 || x >= width || y >= height ? -1 : labels[y * width + x]
    }
}

public struct SegmentParams: Sendable, Equatable {
    /// Regions with fewer pixels than this are merged into their most similar neighbor.
    public var speckSize: Int

    public init(speckSize: Int) { self.speckSize = speckSize }
}

enum Segmenter {
    static func segment(_ q: QuantizedImage, params: SegmentParams) -> Segmentation {
        let (labels, colorOf, counts) = labelComponents(q)
        return mergeSpecks(q, labels: labels, colorOf: colorOf, counts: counts, speckSize: params.speckSize)
    }

    /// Flood-fills runs of equal palette index with an explicit stack (no recursion).
    static func labelComponents(_ q: QuantizedImage) -> (labels: [Int32], colorOf: [Int32], counts: [Int]) {
        let w = q.width, h = q.height
        var labels = [Int32](repeating: -1, count: w * h)
        var colorOf: [Int32] = [], counts: [Int] = []
        var stack: [Int] = []
        for start in 0..<(w * h) where q.indices[start] >= 0 && labels[start] < 0 {
            let id = Int32(colorOf.count), color = q.indices[start]
            colorOf.append(color)
            var n = 0
            labels[start] = id
            stack.append(start)
            while let i = stack.popLast() {
                n += 1
                let x = i % w, y = i / w
                if x > 0, labels[i - 1] < 0, q.indices[i - 1] == color { labels[i - 1] = id; stack.append(i - 1) }
                if x < w - 1, labels[i + 1] < 0, q.indices[i + 1] == color { labels[i + 1] = id; stack.append(i + 1) }
                if y > 0, labels[i - w] < 0, q.indices[i - w] == color { labels[i - w] = id; stack.append(i - w) }
                if y < h - 1, labels[i + w] < 0, q.indices[i + w] == color { labels[i + w] = id; stack.append(i + w) }
            }
            counts.append(n)
        }
        return (labels, colorOf, counts)
    }

    /// Merges regions smaller than `speckSize` (smallest first) into the adjacent region with the
    /// closest Lab color (ties: longer shared border, then lower label), using a region adjacency
    /// graph and union-find. Regions touching only transparency are kept. Labels are then renumbered
    /// in order of first appearance.
    static func mergeSpecks(_ q: QuantizedImage, labels: [Int32], colorOf: [Int32], counts: [Int], speckSize: Int) -> Segmentation {
        let w = q.width, h = q.height, n = counts.count
        var parent = Array(0..<n)
        var size = counts
        if speckSize > 1 && n > 1 {
            var adj = [[Int: Int]](repeating: [:], count: n)
            for y in 0..<h {
                for x in 0..<w {
                    let a = Int(labels[y * w + x])
                    guard a >= 0 else { continue }
                    if x + 1 < w {
                        let b = Int(labels[y * w + x + 1])
                        if b >= 0 && b != a { adj[a][b, default: 0] += 1; adj[b][a, default: 0] += 1 }
                    }
                    if y + 1 < h {
                        let b = Int(labels[(y + 1) * w + x])
                        if b >= 0 && b != a { adj[a][b, default: 0] += 1; adj[b][a, default: 0] += 1 }
                    }
                }
            }
            let labs = q.palette.map { Lab($0) }
            let order = (0..<n).filter { counts[$0] < speckSize }.sorted { (counts[$0], $0) < (counts[$1], $1) }
            for r in order {
                // Adjacency keys are always current roots, so `r` is still a root unless merged away.
                guard parent[r] == r, size[r] < speckSize, !adj[r].isEmpty else { continue }
                let mine = labs[Int(colorOf[r])]
                let target = adj[r].min { l, m in
                    let dl = labs[Int(colorOf[l.key])].distance(to: mine), dm = labs[Int(colorOf[m.key])].distance(to: mine)
                    if dl != dm { return dl < dm }
                    if l.value != m.value { return l.value > m.value }
                    return l.key < m.key
                }!.key
                parent[r] = target
                size[target] += size[r]
                for (nb, len) in adj[r] where nb != target {
                    adj[nb][r] = nil
                    adj[nb][target, default: 0] += len
                    adj[target][nb, default: 0] += len
                }
                adj[target][r] = nil
                adj[r] = [:]
            }
        }
        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }
            return x
        }
        var newId = [Int32](repeating: -1, count: n)
        var regions: [Region] = []
        var out = [Int32](repeating: -1, count: w * h)
        for i in 0..<(w * h) {
            let l = Int(labels[i])
            guard l >= 0 else { continue }
            let root = find(l)
            if newId[root] < 0 {
                newId[root] = Int32(regions.count)
                regions.append(Region(color: q.palette[Int(colorOf[root])], pixelCount: size[root]))
            }
            out[i] = newId[root]
        }
        return Segmentation(width: w, height: h, labels: out, regions: regions)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SegmentTests`
Expected: all 7 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/VectorEngine/Segment Tests/VectorEngineTests/SegmentTests.swift
git commit -m "feat: 4-connected region labeling with speck merging"
```

---

### Task 4: Topology (shared boundary chains and region loops)

**Files:**
- Create: `Sources/VectorEngine/Trace/Topology.swift`
- Test: `Tests/VectorEngineTests/TopologyTests.swift`

**Background for the implementer:** Boundaries live on the (W+1)×(H+1) lattice of pixel corners. A *crack edge* is a unit lattice edge whose two adjacent pixels have different labels; outside the image counts as label -1, the same as transparent. A lattice vertex where 3 or 4 crack edges meet is a *junction*. That includes the 2×2 diagonal "checkerboard" case, which is how 4-connectivity stays unambiguous. A *chain* is a maximal path of crack edges through degree-2 vertices. It runs from junction to junction, or it is a closed loop with no junction. Because both labels along a chain stay constant, each chain is simplified and fitted **once** and then shared by the regions on its two sides. When a region's loops are assembled at a junction, the walk prefers a screen-left turn: it hugs the region's own pixel on its left, which matches 4-connected foreground and 8-connected background.

**Interfaces:**
- Consumes: `Segmentation`, `LatticePoint` (Tasks 1, 3).
- Produces:
  - `public struct Chain { points: [LatticePoint] /* closed: last == first */; left: Int32; right: Int32; isClosed: Bool }`. `left` is the label on the screen-left side when walking forward in y-down coordinates.
  - `public struct ChainRef: Hashable { chain: Int; reversed: Bool }`
  - `public struct RegionLoops { loops: [[ChainRef]]; areas: [Double] /* signed; outer negative, holes positive */; outerIndex: Int; var outerArea: Double }`
  - `public struct Topology { width, height, chains: [Chain], regions: [RegionLoops] /* indexed by label */; static func build(_: Segmentation) -> Topology; func points(_: ChainRef) -> [LatticePoint] }`
  - Invariant: for each region, `-areas.sum() == pixelCount`.

- [ ] **Step 1: Write the failing tests**

`Tests/VectorEngineTests/TopologyTests.swift`:
```swift
import Testing
@testable import VectorEngine

@Suite struct TopologyTests {
    func topo(_ rows: [String]) -> (Segmentation, Topology) {
        let seg = Segmenter.segment(TestImages.quantized(rows), params: SegmentParams(speckSize: 0))
        return (seg, Topology.build(seg))
    }

    /// Loops must chain end-to-start and their signed areas must add up to the region's pixel count.
    func checkInvariants(_ seg: Segmentation, _ t: Topology, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(t.regions.count == seg.regions.count, sourceLocation: sourceLocation)
        for (r, region) in t.regions.enumerated() {
            #expect(-region.areas.reduce(0, +) == Double(seg.regions[r].pixelCount), "region \(r)", sourceLocation: sourceLocation)
            for loop in region.loops {
                let pieces = loop.map { t.points($0) }
                for (i, p) in pieces.enumerated() {
                    #expect(p.last == pieces[(i + 1) % pieces.count].first, sourceLocation: sourceLocation)
                }
            }
        }
    }

    /// Crack edges counted directly from the labels.
    func crackEdgeCount(_ s: Segmentation) -> Int {
        var n = 0
        for y in 0...s.height { for x in 0..<s.width where s.label(x, y - 1) != s.label(x, y) { n += 1 } }
        for y in 0..<s.height { for x in 0...s.width where s.label(x - 1, y) != s.label(x, y) { n += 1 } }
        return n
    }

    @Test func singlePixelIsOneClosedLoop() {
        let (seg, t) = topo(["R"])
        #expect(t.chains.count == 1)
        #expect(t.chains[0].isClosed && t.chains[0].points.count == 5)
        #expect(t.regions[0].loops.count == 1 && t.regions[0].outerArea == 1)
        checkInvariants(seg, t)
    }

    @Test func randomBlocksSatisfyInvariantsAndUseEveryEdgeOnce() {
        for seed: UInt64 in [1, 2, 3] {
            let b = TestImages.randomBlocks(seed: seed)
            let q = Quantizer.assign(b, palette: [TestImages.red, TestImages.blue, TestImages.white], alphaThreshold: 128)
            let seg = Segmenter.segment(q, params: SegmentParams(speckSize: 0))
            let t = Topology.build(seg)
            checkInvariants(seg, t)
            #expect(t.chains.reduce(0) { $0 + $1.points.count - 1 } == crackEdgeCount(seg))
        }
    }

    @Test func checkerboardCenterIsAJunction() {
        let (seg, t) = topo(["RW", "WR"])
        #expect(t.chains.allSatisfy { !$0.isClosed })
        #expect(t.regions.allSatisfy { $0.loops.count == 1 })
        checkInvariants(seg, t)
    }

    // Review focus: a region whose holes touch diagonally at one lattice vertex.
    @Test func regionTouchingItselfDiagonally() {
        let (seg, t) = topo(["WWWW", "WWRW", "WBWW", "WWWW"])
        let white = Int(seg.label(0, 0))
        #expect(t.regions[white].loops.count == 2)   // outer + one hole around the diagonal R/B pair
        #expect(t.regions[white].outerArea == 16)
        checkInvariants(seg, t)
    }

    @Test func ringHasOuterLoopAndHole() {
        let (seg, t) = topo(["WWWWW", "WRRRW", "WRBRW", "WRRRW", "WWWWW"])
        let ring = Int(seg.label(1, 1))
        #expect(t.regions[ring].loops.count == 2)
        #expect(t.regions[ring].outerArea == 9)
        checkInvariants(seg, t)
    }

    @Test func transparencyGetsNoRegion() {
        let (seg, t) = topo(["..", ".R"])
        #expect(t.regions.count == 1)
        #expect(t.chains.count == 1 && t.chains[0].isClosed)
        checkInvariants(seg, t)
    }

    @Test func stripesProduceOpenChainsBetweenBorderJunctions() {
        let (seg, t) = topo(["RWB", "RWB"])
        let rw = t.chains.filter { Set([$0.left, $0.right]) == Set([seg.label(0, 0), seg.label(1, 0)]) }
        #expect(rw.count == 1 && !rw[0].isClosed)
        #expect(Set([rw[0].points.first!, rw[0].points.last!]) == [LatticePoint(1, 0), LatticePoint(1, 2)])
        checkInvariants(seg, t)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter TopologyTests`
Expected: build failure, with errors such as "cannot find 'Topology' in scope".

- [ ] **Step 3: Implement the topology builder**

`Sources/VectorEngine/Trace/Topology.swift`:
```swift
/// A maximal run of crack edges separating the same two labels. Open chains start and end at
/// junctions (3+ edges meet); closed chains loop through degree-2 vertices only.
public struct Chain: Sendable, Equatable {
    /// Lattice vertices along the chain; closed chains repeat the first point at the end.
    public var points: [LatticePoint]
    /// Label on the screen-left side when walking forward (y-down); -1 = none.
    public var left: Int32
    public var right: Int32
    public var isClosed: Bool
}

public struct ChainRef: Sendable, Hashable {
    public var chain: Int
    public var reversed: Bool
}

/// The closed boundary loops of one region, each walked with the region on its left.
public struct RegionLoops: Sendable, Equatable {
    public var loops: [[ChainRef]]
    /// Signed lattice area per loop: outer boundaries are negative, holes positive.
    public var areas: [Double]
    /// The loop with the largest absolute area: the region's outer boundary.
    public var outerIndex: Int
    public var outerArea: Double { abs(areas[outerIndex]) }
}

public struct Topology: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public var chains: [Chain]
    /// Indexed by region label.
    public var regions: [RegionLoops]

    public func points(_ ref: ChainRef) -> [LatticePoint] {
        ref.reversed ? chains[ref.chain].points.reversed() : chains[ref.chain].points
    }
}

enum Dir: CaseIterable {
    case east, south, west, north

    var dx: Int {
        switch self {
        case .east: 1
        case .west: -1
        default: 0
        }
    }
    var dy: Int {
        switch self {
        case .south: 1
        case .north: -1
        default: 0
        }
    }
    var opposite: Dir {
        switch self {
        case .east: .west
        case .west: .east
        case .south: .north
        case .north: .south
        }
    }
    /// The screen-left turn in y-down coordinates (facing east, left is north).
    var left: Dir {
        switch self {
        case .east: .north
        case .north: .west
        case .west: .south
        case .south: .east
        }
    }
    var right: Dir { left.opposite }

    init(from a: LatticePoint, to b: LatticePoint) {
        switch (b.x - a.x, b.y - a.y) {
        case (1, 0): self = .east
        case (-1, 0): self = .west
        case (0, 1): self = .south
        default: self = .north
        }
    }
}

/// Crack-edge lookups over a segmentation. Horizontal edge (x, y) lies between pixels (x, y-1)
/// and (x, y); vertical edge (x, y) lies between pixels (x-1, y) and (x, y).
struct CrackGrid {
    let seg: Segmentation
    var w: Int { seg.width }
    var h: Int { seg.height }
    var hCount: Int { w * (h + 1) }
    var edgeCount: Int { hCount + (w + 1) * h }

    /// The id of the edge leaving lattice vertex (x, y) in direction d, if a boundary lies there.
    func edge(_ x: Int, _ y: Int, _ d: Dir) -> Int? {
        switch d {
        case .east: x < w && seg.label(x, y - 1) != seg.label(x, y) ? y * w + x : nil
        case .west: x > 0 && seg.label(x - 1, y - 1) != seg.label(x - 1, y) ? y * w + x - 1 : nil
        case .south: y < h && seg.label(x - 1, y) != seg.label(x, y) ? hCount + y * (w + 1) + x : nil
        case .north: y > 0 && seg.label(x - 1, y - 1) != seg.label(x, y - 1) ? hCount + (y - 1) * (w + 1) + x : nil
        }
    }

    func degree(_ x: Int, _ y: Int) -> Int {
        Dir.allCases.reduce(0) { $0 + (edge(x, y, $1) == nil ? 0 : 1) }
    }

    /// (left, right) labels when traveling from (x, y) in direction d.
    func sides(_ x: Int, _ y: Int, _ d: Dir) -> (Int32, Int32) {
        switch d {
        case .east: (seg.label(x, y - 1), seg.label(x, y))
        case .west: (seg.label(x - 1, y), seg.label(x - 1, y - 1))
        case .south: (seg.label(x, y), seg.label(x - 1, y))
        case .north: (seg.label(x - 1, y - 1), seg.label(x, y - 1))
        }
    }
}

extension Topology {
    public static func build(_ seg: Segmentation) -> Topology {
        let grid = CrackGrid(seg: seg)
        var visited = [Bool](repeating: false, count: grid.edgeCount)
        var chains: [Chain] = []

        func walk(_ sx: Int, _ sy: Int, _ startDir: Dir) -> Chain {
            let (left, right) = grid.sides(sx, sy, startDir)
            var points = [LatticePoint(sx, sy)]
            var x = sx, y = sy, d = startDir
            while true {
                visited[grid.edge(x, y, d)!] = true
                x += d.dx
                y += d.dy
                points.append(LatticePoint(x, y))
                if grid.degree(x, y) != 2 { return Chain(points: points, left: left, right: right, isClosed: false) }
                if x == sx && y == sy { return Chain(points: points, left: left, right: right, isClosed: true) }
                let back = d.opposite
                d = Dir.allCases.first { $0 != back && grid.edge(x, y, $0) != nil }!
            }
        }

        // Open chains: walk out of every junction along each unvisited edge.
        for y in 0...seg.height {
            for x in 0...seg.width where grid.degree(x, y) >= 3 {
                for d in Dir.allCases {
                    if let e = grid.edge(x, y, d), !visited[e] { chains.append(walk(x, y, d)) }
                }
            }
        }
        // Whatever is left forms closed loops through degree-2 vertices.
        for y in 0...seg.height {
            for x in 0..<seg.width {
                if let e = grid.edge(x, y, .east), !visited[e] { chains.append(walk(x, y, .east)) }
            }
        }
        for y in 0..<seg.height {
            for x in 0...seg.width {
                if let e = grid.edge(x, y, .south), !visited[e] { chains.append(walk(x, y, .south)) }
            }
        }

        var byRegion = [[Int]](repeating: [], count: seg.regions.count)
        for (i, c) in chains.enumerated() {
            if c.left >= 0 { byRegion[Int(c.left)].append(i) }
            if c.right >= 0 { byRegion[Int(c.right)].append(i) }
        }
        let regions = byRegion.enumerated().map {
            linkLoops(region: Int32($0.offset), chainIndices: $0.element, chains: chains)
        }
        return Topology(width: seg.width, height: seg.height, chains: chains, regions: regions)
    }

    /// Joins a region's chains (oriented so the region is on the left) into closed loops.
    static func linkLoops(region r: Int32, chainIndices: [Int], chains: [Chain]) -> RegionLoops {
        struct End {
            var ref: ChainRef
            var start: LatticePoint
            var end: LatticePoint
            var firstDir: Dir
            var lastDir: Dir
        }
        var loops: [[ChainRef]] = []
        var open: [End] = []
        for i in chainIndices {
            let c = chains[i]
            let ref = ChainRef(chain: i, reversed: c.right == r)
            if c.isClosed { loops.append([ref]); continue }
            let p = ref.reversed ? Array(c.points.reversed()) : c.points
            open.append(End(ref: ref, start: p[0], end: p[p.count - 1],
                            firstDir: Dir(from: p[0], to: p[1]), lastDir: Dir(from: p[p.count - 2], to: p[p.count - 1])))
        }
        var byStart: [LatticePoint: [Int]] = [:]
        for (i, e) in open.enumerated() { byStart[e.start, default: []].append(i) }
        var used = [Bool](repeating: false, count: open.count)
        for s in open.indices where !used[s] {
            used[s] = true
            var loop = [open[s].ref], cur = s
            while true {
                let din = open[cur].lastDir
                let candidates = byStart[open[cur].end] ?? []
                var next: Int?
                for want in [din.left, din, din.right, din.opposite] {
                    if let c = candidates.first(where: { open[$0].firstDir == want && (!used[$0] || $0 == s) }) {
                        next = c
                        break
                    }
                }
                assert(next != nil, "boundary loop failed to close")
                guard let n = next, n != s else { break }
                used[n] = true
                loop.append(open[n].ref)
                cur = n
            }
            loops.append(loop)
        }
        let areas = loops.map { loop -> Double in
            var pts: [LatticePoint] = []
            for ref in loop {
                let p = ref.reversed ? Array(chains[ref.chain].points.reversed()) : chains[ref.chain].points
                pts.append(contentsOf: p.dropLast())
            }
            var sum = 0
            for i in pts.indices {
                let a = pts[i], b = pts[(i + 1) % pts.count]
                sum += a.x * b.y - b.x * a.y
            }
            return Double(sum) / 2
        }
        let outer = areas.indices.max { abs(areas[$0]) < abs(areas[$1]) } ?? 0
        return RegionLoops(loops: loops, areas: areas, outerIndex: outer)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter TopologyTests`
Expected: all 7 tests pass. If `checkInvariants` fails on area, print the loop's points for the failing region. Area mismatches almost always come from a wrong row in `CrackGrid.sides`, so check those against the doc comment above.

- [ ] **Step 5: Commit**

```bash
git add Sources/VectorEngine/Trace Tests/VectorEngineTests/TopologyTests.swift
git commit -m "feat: shared boundary chains and per-region loops"
```

---

### Task 5: Path model, shape assembly, SVG writer, rasterizer

**Files:**
- Create: `Sources/VectorEngine/Path/{PathModel,ShapeAssembler,ShapeRenderer,SVGWriter}.swift`
- Test: `Tests/VectorEngineTests/AssemblyTests.swift`

**Interfaces:**
- Consumes: `Topology`, `ChainRef`, `Region`, `Vec2`, `RGBA`, `TracingMode`, `Bitmap.render` (Tasks 1–4).
- Produces:
  - `public enum PathSegment { case line(to: Vec2); case cubic(c1: Vec2, c2: Vec2, to: Vec2); var end: Vec2; func scaled(_:_:) }`
  - `public struct Curve { start: Vec2; segments: [PathSegment]; var end; static func polyline([Vec2]) -> Curve; func reversed() -> Curve }`. There is one curve per chain; a closed chain's curve ends at its start.
  - `public struct Subpath { start: Vec2; segments: [PathSegment] }`, implicitly closed.
  - `public struct VectorShape { color: RGBA; subpaths: [Subpath]; func scaled(_:_:) }`
  - `ShapeAssembler.shapes(topology:regions:curves:tracing:) -> [VectorShape]`. Shapes are ordered by outer area, descending. Shared mode merges same-colored regions into one shape; stacked mode emits outer loops only.
  - `ShapeRenderer.path(for:) -> CGPath`, `ShapeRenderer.fill(_:in:)` (expects a y-down context), `ShapeRenderer.rasterize(_:width:height:antialias: = true, background: = .clear) -> Bitmap`, internal `ShapeRenderer.cgColor(_:)`.
  - `public struct VectorStats { pathCount, segmentCount, byteCount }`, `public struct VectorResult { width, height, shapes, svg, stats; init(shapes:width:height:precision:) }`
  - `SVGWriter.document(_:width:height:precision:)`, `SVGWriter.pathData(_:precision:)`, `SVGWriter.format(_ scaledInt: Int, precision:)`

- [ ] **Step 1: Write the failing tests**

`Tests/VectorEngineTests/AssemblyTests.swift`:
```swift
import Foundation
import Testing
@testable import VectorEngine

@Suite struct AssemblyTests {
    /// Exact palette → regions → chains, outlined with straight pixel-edge polylines.
    func polylineResult(_ b: Bitmap, palette: [RGBA], tracing: TracingMode) -> (QuantizedImage, VectorResult) {
        let q = Quantizer.assign(b, palette: palette, alphaThreshold: 128)
        let seg = Segmenter.segment(q, params: SegmentParams(speckSize: 0))
        let t = Topology.build(seg)
        let curves = t.chains.map { Curve.polyline($0.points.map(\.vec)) }
        let shapes = ShapeAssembler.shapes(topology: t, regions: seg.regions, curves: curves, tracing: tracing)
        return (q, VectorResult(shapes: shapes, width: b.width, height: b.height, precision: 1))
    }

    @Test(arguments: TracingMode.allCases)
    func polylinesReproduceThePixelsExactly(tracing: TracingMode) {
        let b = TestImages.randomBlocks()
        let (q, r) = polylineResult(b, palette: [TestImages.red, TestImages.blue, TestImages.white], tracing: tracing)
        let raster = ShapeRenderer.rasterize(r.shapes, width: b.width, height: b.height, antialias: false)
        #expect(TestImages.agreement(raster, q.makeBitmap()) == 1)
    }

    // Review focus: transparent-background logo.
    @Test func transparentBackgroundEmitsNoBackgroundPath() {
        let (_, r) = polylineResult(TestImages.circle(bg: .clear), palette: [TestImages.red], tracing: .sharedEdges)
        #expect(r.shapes.count == 1)
        let raster = ShapeRenderer.rasterize(r.shapes, width: 48, height: 48, antialias: false)
        #expect(raster[0, 0].a == 0 && raster[24, 24] == TestImages.red)
    }

    @Test func sharedModeMergesSameColoredRegionsStackedDoesNot() {
        let b = TestImages.grid(["RWR"])
        #expect(polylineResult(b, palette: [TestImages.red, TestImages.white], tracing: .sharedEdges).1.shapes.count == 2)
        #expect(polylineResult(b, palette: [TestImages.red, TestImages.white], tracing: .stacked).1.shapes.count == 3)
    }

    @Test func svgIsWellFormed() {
        let (_, r) = polylineResult(TestImages.randomBlocks(), palette: [TestImages.red, TestImages.blue, TestImages.white], tracing: .sharedEdges)
        #expect(XMLParser(data: Data(r.svg.utf8)).parse())
        #expect(r.svg.contains("viewBox=\"0 0 24 24\""))
        #expect(r.svg.components(separatedBy: "<path ").count - 1 == r.shapes.count)
        #expect(r.stats.byteCount == r.svg.utf8.count && r.stats.pathCount == r.shapes.count)
    }

    @Test func numberFormatting() {
        #expect(SVGWriter.format(5, precision: 1) == ".5")
        #expect(SVGWriter.format(-5, precision: 1) == "-.5")
        #expect(SVGWriter.format(120, precision: 1) == "12")
        #expect(SVGWriter.format(-1234, precision: 2) == "-12.34")
        #expect(SVGWriter.format(0, precision: 1) == "0")
        #expect(SVGWriter.format(7, precision: 0) == "7")
    }

    @Test func pathDataIsRelativeAndCompact() {
        let square = Subpath(start: Vec2(0, 0), segments: [
            .line(to: Vec2(10, 0)), .line(to: Vec2(10, 10)), .line(to: Vec2(0, 10)), .line(to: Vec2(0, 0)),
        ])
        #expect(SVGWriter.pathData([square], precision: 1) == "M0 0l10 0 0 10-10 0z")
        let curve = Subpath(start: Vec2(1, 1), segments: [
            .cubic(c1: Vec2(2, 1), c2: Vec2(3, 2), to: Vec2(3, 3)), .line(to: Vec2(1, 1)),
        ])
        #expect(SVGWriter.pathData([curve], precision: 1) == "M1 1c1 0 2 1 2 2z")
    }

    @Test func reversedCurveRoundTrips() {
        let c = Curve(start: Vec2(0, 0), segments: [.line(to: Vec2(1, 0)), .cubic(c1: Vec2(2, 0), c2: Vec2(3, 1), to: Vec2(3, 2))])
        let r = c.reversed()
        #expect(r.start == Vec2(3, 2) && r.end == Vec2(0, 0))
        #expect(r.segments.first == .cubic(c1: Vec2(3, 1), c2: Vec2(2, 0), to: Vec2(1, 0)))
        #expect(r.reversed() == c)
    }

    @Test func degenerateImages() {
        let (_, empty) = polylineResult(Bitmap(width: 4, height: 4) { _, _ in .clear }, palette: [], tracing: .sharedEdges)
        #expect(empty.shapes.isEmpty)
        #expect(XMLParser(data: Data(empty.svg.utf8)).parse())
        let (_, dot) = polylineResult(Bitmap(width: 1, height: 1) { _, _ in TestImages.red }, palette: [TestImages.red], tracing: .stacked)
        #expect(dot.shapes.count == 1)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AssemblyTests`
Expected: build failure, with errors such as "cannot find 'Curve' in scope".

- [ ] **Step 3: Implement the path model**

`Sources/VectorEngine/Path/PathModel.swift`:
```swift
public enum PathSegment: Sendable, Equatable {
    case line(to: Vec2)
    case cubic(c1: Vec2, c2: Vec2, to: Vec2)

    public var end: Vec2 {
        switch self {
        case .line(let p): p
        case .cubic(_, _, let p): p
        }
    }

    func scaled(_ sx: Double, _ sy: Double) -> PathSegment {
        switch self {
        case .line(let p): .line(to: p.scaled(sx, sy))
        case .cubic(let c1, let c2, let p): .cubic(c1: c1.scaled(sx, sy), c2: c2.scaled(sx, sy), to: p.scaled(sx, sy))
        }
    }
}

/// The outline piece for one chain. A closed chain's curve ends where it starts.
public struct Curve: Sendable, Equatable {
    public var start: Vec2
    public var segments: [PathSegment]

    public init(start: Vec2, segments: [PathSegment]) {
        self.start = start
        self.segments = segments
    }

    public var end: Vec2 { segments.last?.end ?? start }

    public static func polyline(_ points: [Vec2]) -> Curve {
        Curve(start: points[0], segments: points.dropFirst().map { .line(to: $0) })
    }

    /// The same geometry traversed backwards.
    public func reversed() -> Curve {
        let ends = [start] + segments.map(\.end)
        var out: [PathSegment] = []
        for i in stride(from: segments.count - 1, through: 0, by: -1) {
            let to = ends[i]
            switch segments[i] {
            case .line: out.append(.line(to: to))
            case .cubic(let c1, let c2, _): out.append(.cubic(c1: c2, c2: c1, to: to))
            }
        }
        return Curve(start: ends[ends.count - 1], segments: out)
    }
}

/// A closed outline; its last segment ends at `start`.
public struct Subpath: Sendable, Equatable {
    public var start: Vec2
    public var segments: [PathSegment]
}

public struct VectorShape: Sendable, Equatable {
    public var color: RGBA
    public var subpaths: [Subpath]

    func scaled(_ sx: Double, _ sy: Double) -> VectorShape {
        VectorShape(color: color, subpaths: subpaths.map {
            Subpath(start: $0.start.scaled(sx, sy), segments: $0.segments.map { $0.scaled(sx, sy) })
        })
    }
}
```

- [ ] **Step 4: Implement the assembler and rasterizer**

`Sources/VectorEngine/Path/ShapeAssembler.swift`:
```swift
enum ShapeAssembler {
    /// Turns per-chain curves into filled shapes, largest outer boundary first.
    /// Shared-edges mode cuts holes (even-odd) and merges same-colored regions into one shape;
    /// stacked mode uses each region's outer boundary only, relying on paint order.
    static func shapes(topology t: Topology, regions: [Region], curves: [Curve], tracing: TracingMode) -> [VectorShape] {
        let order = t.regions.indices.sorted { a, b in
            let aa = t.regions[a].outerArea, ab = t.regions[b].outerArea
            return aa != ab ? aa > ab : a < b
        }
        var shapes: [VectorShape] = []
        var shapeForColor: [RGBA: Int] = [:]
        for r in order {
            let loops = t.regions[r].loops
            let chosen = tracing == .stacked ? [loops[t.regions[r].outerIndex]] : loops
            let subpaths = chosen.map { subpath($0, curves) }
            let color = regions[r].color
            if tracing == .sharedEdges, let i = shapeForColor[color] {
                shapes[i].subpaths += subpaths
            } else {
                shapeForColor[color] = shapes.count
                shapes.append(VectorShape(color: color, subpaths: subpaths))
            }
        }
        return shapes
    }

    static func subpath(_ loop: [ChainRef], _ curves: [Curve]) -> Subpath {
        var segments: [PathSegment] = []
        var start: Vec2?
        for ref in loop {
            let c = ref.reversed ? curves[ref.chain].reversed() : curves[ref.chain]
            if start == nil { start = c.start }
            segments += c.segments
        }
        return Subpath(start: start!, segments: segments)
    }
}
```

`Sources/VectorEngine/Path/ShapeRenderer.swift`:
```swift
import CoreGraphics

public enum ShapeRenderer {
    public static func path(for shape: VectorShape) -> CGPath {
        let p = CGMutablePath()
        for sp in shape.subpaths {
            p.move(to: cg(sp.start))
            for seg in sp.segments {
                switch seg {
                case .line(let to): p.addLine(to: cg(to))
                case .cubic(let c1, let c2, let to): p.addCurve(to: cg(to), control1: cg(c1), control2: cg(c2))
                }
            }
            p.closeSubpath()
        }
        return p
    }

    /// Fills shapes in order with the even-odd rule. `ctx` must use y-down coordinates.
    public static func fill(_ shapes: [VectorShape], in ctx: CGContext) {
        for s in shapes {
            ctx.addPath(path(for: s))
            ctx.setFillColor(cgColor(s.color))
            ctx.fillPath(using: .evenOdd)
        }
    }

    public static func rasterize(_ shapes: [VectorShape], width: Int, height: Int, antialias: Bool = true, background: RGBA = .clear) -> Bitmap {
        Bitmap.render(width: width, height: height) { ctx in
            if background.a > 0 {
                ctx.setFillColor(cgColor(background))
                ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            }
            ctx.setShouldAntialias(antialias)
            fill(shapes, in: ctx)
        }
    }

    static func cgColor(_ c: RGBA) -> CGColor {
        CGColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: CGFloat(c.a) / 255)
    }

    static func cg(_ v: Vec2) -> CGPoint { CGPoint(x: v.x, y: v.y) }
}
```

- [ ] **Step 5: Implement the SVG writer**

`Sources/VectorEngine/Path/SVGWriter.swift`:
```swift
import Foundation

public struct VectorStats: Sendable, Equatable {
    public var pathCount: Int
    public var segmentCount: Int
    public var byteCount: Int
}

public struct VectorResult: Sendable, Equatable {
    /// Output size in original image pixels.
    public var width: Int
    public var height: Int
    /// Shapes in output coordinates, in paint order.
    public var shapes: [VectorShape]
    public var svg: String
    public var stats: VectorStats

    public init(shapes: [VectorShape], width: Int, height: Int, precision: Int) {
        self.width = width
        self.height = height
        self.shapes = shapes
        svg = SVGWriter.document(shapes, width: width, height: height, precision: precision)
        let segments = shapes.reduce(0) { $0 + $1.subpaths.reduce(0) { $0 + $1.segments.count } }
        stats = VectorStats(pathCount: shapes.count, segmentCount: segments, byteCount: svg.utf8.count)
    }
}

enum SVGWriter {
    static func document(_ shapes: [VectorShape], width: Int, height: Int, precision: Int) -> String {
        var out = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 \(width) \(height)\" width=\"\(width)\" height=\"\(height)\" fill-rule=\"evenodd\">\n"
        for s in shapes {
            out += "<path fill=\"\(s.color.hex)\" d=\"\(pathData(s.subpaths, precision: precision))\"/>\n"
        }
        out += "</svg>\n"
        return out
    }

    /// Compact path data: absolute moveto, then relative l/c commands. Coordinates are rounded to
    /// integers in units of 10^-precision first and deltas are taken between rounded values,
    /// so relative steps never drift.
    static func pathData(_ subpaths: [Subpath], precision: Int) -> String {
        let f = pow(10, Double(precision))
        func q(_ v: Double) -> Int { Int((v * f).rounded()) }
        var d = ""
        var command: Character = " "
        func emit(_ c: Character) {
            if c != command || c == "M" || c == "z" { d.append(c); command = c }
        }
        func num(_ i: Int) {
            let s = format(i, precision: precision)
            if let last = d.last, !last.isLetter, !s.hasPrefix("-") { d.append(" ") }
            d += s
        }
        for sp in subpaths {
            var cx = q(sp.start.x), cy = q(sp.start.y)
            let sx = cx, sy = cy
            emit("M"); num(cx); num(cy)
            for (i, seg) in sp.segments.enumerated() {
                switch seg {
                case .line(let to):
                    let tx = q(to.x), ty = q(to.y)
                    if tx == cx && ty == cy { continue }
                    if i == sp.segments.count - 1 && tx == sx && ty == sy { continue }   // z closes it
                    emit("l"); num(tx - cx); num(ty - cy)
                    cx = tx; cy = ty
                case .cubic(let c1, let c2, let to):
                    let tx = q(to.x), ty = q(to.y)
                    emit("c")
                    num(q(c1.x) - cx); num(q(c1.y) - cy); num(q(c2.x) - cx); num(q(c2.y) - cy); num(tx - cx); num(ty - cy)
                    cx = tx; cy = ty
                }
            }
            emit("z")
        }
        return d
    }

    /// Formats an integer measured in units of 10^-precision: 5 → ".5", -1234 (p=2) → "-12.34".
    static func format(_ i: Int, precision p: Int) -> String {
        if p == 0 { return String(i) }
        let f = Int(pow(10, Double(p)))
        let a = abs(i), whole = a / f, frac = a % f
        var s = String(whole)
        if frac != 0 {
            var fs = String(frac)
            fs = String(repeating: "0", count: p - fs.count) + fs
            while fs.hasSuffix("0") { fs.removeLast() }
            s = (whole == 0 ? "" : s) + "." + fs
        }
        return i < 0 ? "-" + s : s
    }
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --filter AssemblyTests`
Expected: all 10 test cases pass (the parameterized test runs twice).

- [ ] **Step 7: Commit**

```bash
git add Sources/VectorEngine/Path Tests/VectorEngineTests/AssemblyTests.swift
git commit -m "feat: shape assembly, compact SVG writer and rasterizer"
```

---

### Task 6: Analysis, photo quantizer, prefilter, and options

**Files:**
- Create: `Sources/VectorEngine/Analyze/Analyzer.swift`, `Sources/VectorEngine/Quantize/KMeans.swift`, `Sources/VectorEngine/Prefilter/Prefilter.swift`, `Sources/VectorEngine/Pipeline/Options.swift`
- Test: `Tests/VectorEngineTests/AnalysisTests.swift`

**Interfaces:**
- Consumes: `PaletteBuilder`, `Quantizer.assign`, `QuantizeParams`, `SegmentParams`, `SplitMix64`, `ImageKind`, `TracingMode` (Tasks 1–3).
- Produces:
  - `public struct Analysis { kind: ImageKind; significantColors: Int; gradientFraction: Double; palette: [RGBA]; shares: [Double] }`
  - `public struct ClassifierParams` (defaults listed in the code; `init()`, plus internal `init(_ a: AdvancedOptions)`)
  - `Analyzer.analyze(_ bitmap: Bitmap, params: ClassifierParams) -> Analysis`
  - `Quantizer.photo(_:params:)`, `Quantizer.quantize(_:params:)`, which dispatches on `params.kind`
  - `public struct PrefilterParams { enabled; radius = 2; sigmaColor = 24; alphaThreshold = 128; init(enabled:) }`, `Prefilter.apply(_:params:)`, `Prefilter.bilateral(_:radius:sigmaColor:alphaThreshold:)`
  - `public struct PolygonParams { tolerance; cornerAngle; cornerRunLength; straightTolerance }`, `public struct CurveParams { tolerance; straightTolerance }`, `public struct OutputParams { tracing; precision }`
  - `public struct ResolvedOptions { kind, prefilter, quantize, segment, polygon, curve, output }`
  - `public struct Options { kind?, tracing?, colorCount?, detail?, smoothness?, speckSize?, advanced; init(...); func resolved(with: Analysis) -> ResolvedOptions }`, `public struct AdvancedOptions`

- [ ] **Step 1: Write the failing tests**

`Tests/VectorEngineTests/AnalysisTests.swift`:
```swift
import Testing
@testable import VectorEngine

@Suite struct AnalysisTests {
    func analyze(_ b: Bitmap) -> Analysis { Analyzer.analyze(b, params: ClassifierParams()) }

    @Test func flatLogoIsLogo() {
        let a = analyze(TestImages.circle(size: 96, radius: 32, antialias: true))
        #expect(a.kind == .logo)
        #expect(a.significantColors == 2)
    }

    // Review focus: JPEG-compressed logo.
    @Test func jpegNoisyLogoIsLogo() {
        let a = analyze(TestImages.noisy(TestImages.circle(size: 96, radius: 32, antialias: true), amplitude: 3))
        #expect(a.kind == .logo)
        #expect(a.significantColors == 2)
    }

    // Review focus: transparent-background logo.
    @Test func transparentLogoIsLogo() {
        let a = analyze(TestImages.circle(size: 96, radius: 32, bg: .clear, antialias: true))
        #expect(a.kind == .logo && a.significantColors == 1)
    }

    @Test func texturedGradientIsPhoto() {
        #expect(analyze(TestImages.photoLike()).kind == .photo)
    }

    @Test func smoothGradientIsPhoto() {
        let b = Bitmap(width: 64, height: 64) { x, _ in RGBA(UInt8(x * 4), 80, UInt8(255 - x * 4)) }
        #expect(analyze(b).kind == .photo)
    }

    @Test func kmeansFindsTheUnderlyingColors() {
        let base = TestImages.grid(["RRBB", "RRBB", "GGGG"], scale: 12)
        var p = QuantizeParams(kind: .photo, colorCount: 3)
        p.kmeansIterations = 12
        let q = Quantizer.photo(TestImages.noisy(base, amplitude: 10), params: p)
        #expect(q.palette.count == 3)
        for c in [TestImages.red, TestImages.blue, TestImages.green] {
            #expect(q.palette.contains { Lab($0).distance(to: Lab(c)) < 6 })
        }
    }

    @Test func kmeansIsDeterministic() {
        let b = TestImages.photoLike()
        let p = QuantizeParams(kind: .photo, colorCount: 8)
        #expect(Quantizer.photo(b, params: p) == Quantizer.photo(b, params: p))
    }

    @Test func bilateralSmoothsNoiseButKeepsEdges() {
        let step = Bitmap(width: 32, height: 16) { x, _ in x < 16 ? RGBA(40, 40, 40) : RGBA(220, 220, 220) }
        let noisy = TestImages.noisy(step, amplitude: 12)
        let out = Prefilter.bilateral(noisy, radius: 2, sigmaColor: 24, alphaThreshold: 128)
        func meanDeviation(_ b: Bitmap) -> Double {
            var s = 0
            for y in 0..<16 { for x in 0..<12 { s += abs(Int(b[x, y].r) - 40) } }
            return Double(s) / Double(16 * 12)
        }
        #expect(meanDeviation(out) < meanDeviation(noisy) * 0.6)
        for y in 0..<16 {
            #expect(abs(Int(out[14, y].r) - 40) < 20)
            #expect(abs(Int(out[17, y].r) - 220) < 20)
        }
    }

    let logo = Analysis(kind: .logo, significantColors: 5, gradientFraction: 0.02, palette: [], shares: [])
    let photo = Analysis(kind: .photo, significantColors: 33, gradientFraction: 0.6, palette: [], shares: [])

    @Test func logoDefaults() {
        let r = Options().resolved(with: logo)
        #expect(r.kind == .logo && r.output.tracing == .sharedEdges && !r.prefilter.enabled)
        #expect(r.quantize.colorCount == 5 && r.segment.speckSize == 4)
    }

    @Test func photoDefaults() {
        let r = Options().resolved(with: photo)
        #expect(r.kind == .photo && r.output.tracing == .stacked && r.prefilter.enabled)
        #expect(r.quantize.colorCount == 16 && r.segment.speckSize == 24)
    }

    @Test func explicitChoicesWin() {
        let o = Options(kind: .photo, tracing: .sharedEdges, colorCount: 7, speckSize: 0)
        let r = o.resolved(with: logo)
        #expect(r.kind == .photo && r.output.tracing == .sharedEdges && r.prefilter.enabled)
        #expect(r.quantize.colorCount == 7 && r.segment.speckSize == 0)
    }

    @Test func detailAndSmoothnessMapToTolerances() {
        var o = Options(detail: 1, smoothness: 0)
        let r = o.resolved(with: logo)
        #expect(abs(r.polygon.tolerance - 0.4) < 1e-9 && abs(r.curve.tolerance - 0.5) < 1e-9)
        #expect(r.polygon.cornerAngle == 30)
        o.advanced.polygonTolerance = 3
        #expect(o.resolved(with: logo).polygon.tolerance == 3)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AnalysisTests`
Expected: build failure, with errors such as "cannot find 'Analyzer' in scope".

- [ ] **Step 3: Implement the analyzer**

`Sources/VectorEngine/Analyze/Analyzer.swift`:
```swift
public struct Analysis: Sendable, Equatable {
    public var kind: ImageKind
    /// Distinct colors after merging near-duplicates and ignoring anti-aliasing blends.
    public var significantColors: Int
    /// Share of pixels showing soft, gradual change (shading, texture).
    public var gradientFraction: Double
    /// The significant colors, most common first, and their share of opaque pixels.
    public var palette: [RGBA]
    public var shares: [Double]
}

public struct ClassifierParams: Sendable, Equatable {
    public var alphaThreshold: UInt8 = 128
    public var mergeDistance: Double = 10
    public var minColorShare: Double = 0.001
    public var blendSlack: Double = 0.15
    public var blendKeepShare: Double = 0.03
    public var logoMaxColors = 32
    public var logoMaxGradientFraction = 0.25
    public var sampleDimension = 256

    public init() {}
}

enum Analyzer {
    static func analyze(_ bitmap: Bitmap, params p: ClassifierParams) -> Analysis {
        let sample = downsample(bitmap, to: p.sampleDimension)
        let (clusters, total) = PaletteBuilder.clusters(of: sample, alphaThreshold: p.alphaThreshold, mergeDistance: p.mergeDistance)
        let palette = PaletteBuilder.palette(
            from: clusters, total: total, maxColors: p.logoMaxColors + 1, minShare: p.minColorShare,
            blendSlack: p.blendSlack, blendKeepShare: p.blendKeepShare)
        let gradient = gradientFraction(sample, alphaThreshold: p.alphaThreshold)
        let isLogo = palette.count <= p.logoMaxColors && gradient < p.logoMaxGradientFraction
        return Analysis(
            kind: isLogo ? .logo : .photo, significantColors: palette.count, gradientFraction: gradient,
            palette: palette.map(\.color), shares: palette.map { total > 0 ? Double($0.count) / Double(total) : 0 })
    }

    /// Nearest-neighbor downsample so the long side is at most `maxSide`.
    static func downsample(_ b: Bitmap, to maxSide: Int) -> Bitmap {
        let longSide = max(b.width, b.height)
        guard longSide > maxSide else { return b }
        let w = max(1, b.width * maxSide / longSide), h = max(1, b.height * maxSide / longSide)
        return Bitmap(width: w, height: h) { x, y in b[x * b.width / w, y * b.height / h] }
    }

    /// Share of opaque pixels whose 3×3 box-averaged color differs from the box 3 px to the
    /// right or below by 2.5…40 (largest channel). Averaging hides compression noise; the upper
    /// bound excludes hard edges. Flat logos score low; gradients and textures score high.
    static func gradientFraction(_ b: Bitmap, alphaThreshold: UInt8) -> Double {
        let w = b.width, h = b.height, d = 3
        guard w > 2 + d, h > 2 + d else { return 0 }
        var avg = [SIMD3<Int32>](repeating: .zero, count: w * h)
        var solid = [Bool](repeating: false, count: w * h)
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                var s = SIMD3<Int32>.zero, ok = true
                for dy in -1...1 {
                    for dx in -1...1 {
                        let p = b[x + dx, y + dy]
                        if p.a < alphaThreshold { ok = false }
                        s &+= SIMD3(Int32(p.r), Int32(p.g), Int32(p.b))
                    }
                }
                avg[y * w + x] = s
                solid[y * w + x] = ok
            }
        }
        var soft = 0, counted = 0
        for y in 1..<(h - 1 - d) {
            for x in 1..<(w - 1 - d) {
                let i = y * w + x
                guard solid[i], solid[i + d], solid[i + d * w] else { continue }
                counted += 1
                func diff(_ j: Int) -> Double {
                    let v = avg[i] &- avg[j]
                    return Double(max(abs(v.x), abs(v.y), abs(v.z))) / 9
                }
                let m = max(diff(i + d), diff(i + d * w))
                if m >= 2.5 && m <= 40 { soft += 1 }
            }
        }
        return counted == 0 ? 0 : Double(soft) / Double(counted)
    }
}
```

- [ ] **Step 4: Implement the photo quantizer**

`Sources/VectorEngine/Quantize/KMeans.swift`:
```swift
extension Quantizer {
    static func quantize(_ bitmap: Bitmap, params: QuantizeParams) -> QuantizedImage {
        switch params.kind {
        case .logo: logo(bitmap, params: params)
        case .photo: photo(bitmap, params: params)
        }
    }

    /// Deterministic k-means++ in Lab on an evenly strided pixel sample. Palette colors are the
    /// mean sRGB color of each cluster; duplicates are dropped so equal colors never split regions.
    static func photo(_ bitmap: Bitmap, params p: QuantizeParams) -> QuantizedImage {
        let opaque = bitmap.pixels.filter { $0.a >= p.alphaThreshold }
        guard !opaque.isEmpty else { return assign(bitmap, palette: [], alphaThreshold: p.alphaThreshold) }
        let step = max(1, opaque.count / max(1, p.kmeansSampleSize))
        let sample = stride(from: 0, to: opaque.count, by: step).map { opaque[$0] }
        let labs = sample.map { Lab($0) }
        let k = max(1, min(p.colorCount, Set(sample.map(\.rgbKey)).count))
        var rng = SplitMix64(seed: 0x5EED)

        var centers = [labs[Int(rng.next() % UInt64(labs.count))]]
        var nearest = labs.map { $0.distance(to: centers[0]) }
        while centers.count < k {
            let weights = nearest.map { $0 * $0 }
            let total = weights.reduce(0, +)
            guard total > 0 else { break }
            var target = Double(rng.next() % 1_000_000) / 1_000_000 * total
            var chosen = labs.count - 1
            for (i, w) in weights.enumerated() {
                target -= w
                if target <= 0 { chosen = i; break }
            }
            centers.append(labs[chosen])
            for i in labs.indices { nearest[i] = min(nearest[i], labs[i].distance(to: labs[chosen])) }
        }

        var colors = [RGBA](repeating: .clear, count: centers.count)
        for _ in 0..<max(1, p.kmeansIterations) {
            var sl = [Double](repeating: 0, count: centers.count), sa = sl, sb = sl
            var sr = [Int](repeating: 0, count: centers.count), sg = sr, sbl = sr, n = sr
            for (i, lab) in labs.enumerated() {
                var best = 0, bestD = Double.infinity
                for (j, c) in centers.enumerated() {
                    let d = c.distance(to: lab)
                    if d < bestD { bestD = d; best = j }
                }
                sl[best] += lab.l; sa[best] += lab.a; sb[best] += lab.b
                sr[best] += Int(sample[i].r); sg[best] += Int(sample[i].g); sbl[best] += Int(sample[i].b)
                n[best] += 1
            }
            for j in centers.indices where n[j] > 0 {
                let c = Double(n[j])
                centers[j] = Lab(l: sl[j] / c, a: sa[j] / c, b: sb[j] / c)
                colors[j] = RGBA(UInt8(sr[j] / n[j]), UInt8(sg[j] / n[j]), UInt8(sbl[j] / n[j]))
            }
        }
        var palette: [RGBA] = []
        for c in colors where c.a > 0 && !palette.contains(c) { palette.append(c) }
        return assign(bitmap, palette: palette, alphaThreshold: p.alphaThreshold)
    }
}
```

- [ ] **Step 5: Implement the prefilter**

`Sources/VectorEngine/Prefilter/Prefilter.swift`:
```swift
import Foundation

public struct PrefilterParams: Sendable, Equatable {
    public var enabled: Bool
    public var radius: Int = 2
    public var sigmaColor: Double = 24
    public var alphaThreshold: UInt8 = 128

    public init(enabled: Bool) { self.enabled = enabled }
}

enum Prefilter {
    static func apply(_ b: Bitmap, params p: PrefilterParams) -> Bitmap {
        p.enabled && p.radius > 0 ? bilateral(b, radius: p.radius, sigmaColor: p.sigmaColor, alphaThreshold: p.alphaThreshold) : b
    }

    /// Edge-preserving blur: each neighbor is weighted by spatial distance and color similarity.
    static func bilateral(_ src: Bitmap, radius: Int, sigmaColor: Double, alphaThreshold: UInt8) -> Bitmap {
        let sigmaSpace = Double(radius) / 2 + 0.5
        var spatial: [Double] = []
        for dy in -radius...radius {
            for dx in -radius...radius { spatial.append(exp(-Double(dx * dx + dy * dy) / (2 * sigmaSpace * sigmaSpace))) }
        }
        // Color weight table indexed by squared RGB distance / 16.
        let denominator = 2 * sigmaColor * sigmaColor
        let colorWeight = (0...(3 * 255 * 255 / 16 + 1)).map { (key: Int) -> Double in exp(-Double(key * 16) / denominator) }
        let w = src.width, h = src.height
        var out = src
        for y in 0..<h {
            for x in 0..<w {
                let c = src[x, y]
                guard c.a >= alphaThreshold else { continue }
                var sr = 0.0, sg = 0.0, sb = 0.0, sw = 0.0, k = 0
                for dy in -radius...radius {
                    for dx in -radius...radius {
                        defer { k += 1 }
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, ny >= 0, nx < w, ny < h else { continue }
                        let n = src[nx, ny]
                        guard n.a >= alphaThreshold else { continue }
                        let dr = Int(n.r) - Int(c.r), dg = Int(n.g) - Int(c.g), db = Int(n.b) - Int(c.b)
                        let wgt = spatial[k] * colorWeight[(dr * dr + dg * dg + db * db) / 16]
                        sr += wgt * Double(n.r); sg += wgt * Double(n.g); sb += wgt * Double(n.b); sw += wgt
                    }
                }
                out[x, y] = RGBA(UInt8((sr / sw).rounded()), UInt8((sg / sw).rounded()), UInt8((sb / sw).rounded()), c.a)
            }
        }
        return out
    }
}
```

- [ ] **Step 6: Implement options and their resolution**

`Sources/VectorEngine/Pipeline/Options.swift`:
```swift
public struct PolygonParams: Sendable, Equatable {
    /// Maximum distance (px) the simplified polygon may stray from the boundary points.
    public var tolerance: Double
    /// Turns at least this sharp (degrees) can become corners.
    public var cornerAngle: Double
    /// Staircase runs at least this long on both sides of a turn keep the exact lattice corner.
    public var cornerRunLength: Int
    /// A polygon edge counts as straight if boundary points stay within this distance of it.
    public var straightTolerance: Double
}

public struct CurveParams: Sendable, Equatable {
    /// Maximum distance (px) a fitted Bézier may stray from the boundary points.
    public var tolerance: Double
    public var straightTolerance: Double
}

public struct OutputParams: Sendable, Equatable {
    public var tracing: TracingMode
    /// Decimal places in SVG coordinates.
    public var precision: Int
}

/// Concrete values for every stage, after auto choices are filled in from the analysis.
public struct ResolvedOptions: Sendable, Equatable {
    public var kind: ImageKind
    public var prefilter: PrefilterParams
    public var quantize: QuantizeParams
    public var segment: SegmentParams
    public var polygon: PolygonParams
    public var curve: CurveParams
    public var output: OutputParams
}

/// Every knob. `nil` means "choose automatically from the analysis".
public struct AdvancedOptions: Sendable, Equatable {
    public var maxProcessingDimension = 2000
    public var alphaThreshold: UInt8 = 128
    // Classification
    public var logoMaxColors = 32
    public var logoMaxGradientFraction = 0.25
    // Palette discovery (logo)
    public var colorMergeDistance = 10.0
    public var minColorShare = 0.001
    public var blendSlack = 0.15
    public var blendKeepShare = 0.03
    // Photo
    public var prefilter: Bool? = nil
    public var prefilterRadius = 2
    public var prefilterSigmaColor = 24.0
    public var kmeansIterations = 12
    public var kmeansSampleSize = 20_000
    // Geometry
    public var polygonTolerance: Double? = nil
    public var cornerAngle: Double? = nil
    public var cornerRunLength = 2
    public var straightTolerance = 0.6
    public var curveTolerance: Double? = nil
    // Output
    public var precision = 1

    public init() {}
}

public struct Options: Sendable, Equatable {
    public var kind: ImageKind?
    public var tracing: TracingMode?
    public var colorCount: Int?
    /// 0…1; higher keeps more detail (tighter tolerances).
    public var detail: Double?
    /// 0…1; higher rounds more corners.
    public var smoothness: Double?
    public var speckSize: Int?
    public var advanced: AdvancedOptions

    public init(kind: ImageKind? = nil, tracing: TracingMode? = nil, colorCount: Int? = nil, detail: Double? = nil,
                smoothness: Double? = nil, speckSize: Int? = nil, advanced: AdvancedOptions = AdvancedOptions())
    {
        self.kind = kind; self.tracing = tracing; self.colorCount = colorCount; self.detail = detail
        self.smoothness = smoothness; self.speckSize = speckSize; self.advanced = advanced
    }

    public func resolved(with analysis: Analysis) -> ResolvedOptions {
        let kind = self.kind ?? analysis.kind
        let isLogo = kind == .logo
        let a = advanced
        let detail = max(0, min(1, self.detail ?? (isLogo ? 0.6 : 0.3)))
        let smooth = max(0, min(1, smoothness ?? (isLogo ? 0.5 : 0.6)))
        let colors = max(2, min(256, colorCount ?? (isLogo ? max(2, min(32, analysis.significantColors)) : 16)))

        var prefilter = PrefilterParams(enabled: a.prefilter ?? !isLogo)
        prefilter.radius = a.prefilterRadius
        prefilter.sigmaColor = a.prefilterSigmaColor
        prefilter.alphaThreshold = a.alphaThreshold

        var quantize = QuantizeParams(kind: kind, colorCount: colors)
        quantize.alphaThreshold = a.alphaThreshold
        quantize.mergeDistance = a.colorMergeDistance
        quantize.minColorShare = a.minColorShare
        quantize.blendSlack = a.blendSlack
        quantize.blendKeepShare = a.blendKeepShare
        quantize.kmeansIterations = a.kmeansIterations
        quantize.kmeansSampleSize = a.kmeansSampleSize

        return ResolvedOptions(
            kind: kind,
            prefilter: prefilter,
            quantize: quantize,
            segment: SegmentParams(speckSize: max(0, speckSize ?? (isLogo ? 4 : 24))),
            polygon: PolygonParams(
                tolerance: a.polygonTolerance ?? (1.6 - 1.2 * detail),
                cornerAngle: a.cornerAngle ?? (30 + 60 * smooth),
                cornerRunLength: max(1, a.cornerRunLength),
                straightTolerance: a.straightTolerance),
            curve: CurveParams(tolerance: a.curveTolerance ?? (1.6 - 1.1 * detail), straightTolerance: a.straightTolerance),
            output: OutputParams(tracing: tracing ?? (isLogo ? .sharedEdges : .stacked), precision: max(0, min(4, a.precision))))
    }
}

extension ClassifierParams {
    init(_ a: AdvancedOptions) {
        self.init()
        alphaThreshold = a.alphaThreshold
        mergeDistance = a.colorMergeDistance
        minColorShare = a.minColorShare
        blendSlack = a.blendSlack
        blendKeepShare = a.blendKeepShare
        logoMaxColors = a.logoMaxColors
        logoMaxGradientFraction = a.logoMaxGradientFraction
    }
}
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `swift test --filter AnalysisTests`
Expected: all 12 tests pass. If `flatLogoIsLogo` or `jpegNoisyLogoIsLogo` fails on `kind`, print `a.gradientFraction`. The logo must stay below 0.25. Don't loosen the thresholds silently: report the measured value, because the classifier thresholds belong to the spec.

- [ ] **Step 8: Commit**

```bash
git add Sources/VectorEngine/Analyze Sources/VectorEngine/Quantize/KMeans.swift Sources/VectorEngine/Prefilter Sources/VectorEngine/Pipeline/Options.swift Tests/VectorEngineTests/AnalysisTests.swift
git commit -m "feat: logo/photo classification, k-means, bilateral prefilter, options"
```

---

### Task 7: Pipeline with stage reuse (walking skeleton)

**Files:**
- Create: `Sources/VectorEngine/Polygon/PolygonBuilder.swift` (skeleton version; Task 9 replaces it), `Sources/VectorEngine/Curves/CurveFitter.swift` (skeleton version; Task 10 replaces it), `Sources/VectorEngine/Pipeline/Pipeline.swift`
- Test: `Tests/VectorEngineTests/PipelineTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 1–6.
- Produces:
  - `public struct PolyChain { dense: [Vec2]; vertices: [Int]; corners: [Bool]; isClosed: Bool; var polygon: [Vec2] }`
  - `PolygonBuilder.build(_ t: Topology, params: PolygonParams) -> [PolyChain]`
  - `CurveFitter.fit(_ polys: [PolyChain], params: CurveParams) -> [Curve]`
  - `public enum Stage: Int, CaseIterable, Comparable { analyze, prefilter, quantize, segment, contours, polygon, curves, svg; title; slug }`
  - `public struct PipelineState { input, options, resolved?, analysis?, prefiltered?, quantized?, segmentation?, topology?, polygons?, curves?, result?; public init(input:options:) }`
  - `public struct StageEvent { stage; duration: Duration; reused: Bool; state: PipelineState }`
  - `Pipeline.run(input:options:reusing:onStage:) throws -> PipelineState`
  - `ResolvedOptions.firstChangedStage(comparedTo:) -> Stage?`
  - `Vectorizer.vectorize(_ input: InputImage, options:)`, `Vectorizer.vectorize(contentsOf:options:)`

- [ ] **Step 1: Write the failing tests**

`Tests/VectorEngineTests/PipelineTests.swift`:
```swift
import Foundation
import Testing
@testable import VectorEngine

@Suite struct PipelineTests {
    func reusedStages(first: Options, then second: Options) throws -> [Stage] {
        let input = InputImage(bitmap: TestImages.circle())
        let previous = try Pipeline.run(input: input, options: first)
        var reused: [Stage] = []
        _ = try Pipeline.run(input: input, options: second, reusing: previous) { if $0.reused { reused.append($0.stage) } }
        return reused
    }

    @Test func logoEndToEnd() throws {
        let state = try Pipeline.run(input: InputImage(bitmap: TestImages.circle(antialias: true)), options: Options())
        let result = try #require(state.result)
        #expect(state.analysis?.kind == .logo)
        #expect(XMLParser(data: Data(result.svg.utf8)).parse())
        let raster = ShapeRenderer.rasterize(result.shapes, width: 48, height: 48, antialias: false, background: TestImages.magenta)
        #expect(!raster.pixels.contains(TestImages.magenta))
        #expect(TestImages.agreement(raster, try #require(state.quantized).makeBitmap()) > 0.95)
    }

    @Test func emitsEveryStageInOrder() throws {
        var seen: [Stage] = []
        _ = try Pipeline.run(input: InputImage(bitmap: TestImages.circle()), options: Options()) { seen.append($0.stage) }
        #expect(seen == Stage.allCases)
    }

    @Test func changingDetailReusesEverythingBeforePolygon() throws {
        #expect(try reusedStages(first: Options(), then: Options(detail: 0.9)) == [.analyze, .prefilter, .quantize, .segment, .contours])
    }

    @Test func changingTracingOnlyRedoesSVG() throws {
        #expect(try reusedStages(first: Options(), then: Options(tracing: .stacked)) == Array(Stage.allCases.dropLast()))
    }

    @Test func identicalOptionsReuseEverything() throws {
        #expect(try reusedStages(first: Options(), then: Options()) == Stage.allCases)
    }

    @Test func changingColorsRedoesFromQuantize() throws {
        #expect(try reusedStages(first: Options(), then: Options(colorCount: 5)) == [.analyze, .prefilter])
    }

    @Test func aDifferentInputIsNeverReused() throws {
        let previous = try Pipeline.run(input: InputImage(bitmap: TestImages.circle()), options: Options())
        var reused = 0
        _ = try Pipeline.run(input: InputImage(bitmap: TestImages.circle()), options: Options(), reusing: previous) { if $0.reused { reused += 1 } }
        #expect(reused == 0)
    }

    // Review focus: very large image.
    @Test func downscaledInputIsWrittenAtOriginalSize() throws {
        let big = Bitmap(width: 64, height: 48) { x, y in
            let dx = Double(x) - 32, dy = Double(y) - 24
            return dx * dx + dy * dy < 256 ? TestImages.red : TestImages.white
        }
        let input = InputImage(cgImage: big.makeCGImage(), maxDimension: 32)
        #expect(input.bitmap.width == 32 && input.bitmap.height == 24)
        let r = try Vectorizer.vectorize(input)
        #expect(r.width == 64 && r.height == 48)
        #expect(r.svg.contains("viewBox=\"0 0 64 48\""))
        let ends = r.shapes.flatMap { $0.subpaths.flatMap { [$0.start] + $0.segments.map(\.end) } }
        #expect(ends.allSatisfy { $0.x >= 0 && $0.x <= 64 && $0.y >= 0 && $0.y <= 48 })
        #expect(ends.contains { $0.x > 40 })
    }

    @Test func throwingFromOnStageStopsTheRun() {
        #expect(throws: CancellationError.self) {
            try Pipeline.run(input: InputImage(bitmap: TestImages.circle()), options: Options()) { _ in throw CancellationError() }
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter PipelineTests`
Expected: build failure, with errors such as "cannot find 'Pipeline' in scope".

- [ ] **Step 3: Add skeleton polygon and curve stages**

`Sources/VectorEngine/Polygon/PolygonBuilder.swift`:
```swift
/// One chain's boundary as dense points plus the simplified polygon chosen from them.
public struct PolyChain: Sendable, Equatable {
    /// Boundary sample points. Open chains include both endpoints; closed chains don't repeat the first point.
    public var dense: [Vec2]
    /// Indices into `dense` of the polygon's vertices, ascending.
    public var vertices: [Int]
    /// Whether each polygon vertex is a sharp corner (open-chain endpoints always are).
    public var corners: [Bool]
    public var isClosed: Bool

    public var polygon: [Vec2] { vertices.map { dense[$0] } }
}

enum PolygonBuilder {
    // Walking-skeleton version: every lattice point is a corner vertex. Task 9 replaces this file.
    static func build(_ t: Topology, params: PolygonParams) -> [PolyChain] {
        t.chains.map { c in
            let pts = (c.isClosed ? c.points.dropLast() : c.points[...]).map(\.vec)
            return PolyChain(dense: pts, vertices: Array(pts.indices), corners: pts.map { _ in true }, isClosed: c.isClosed)
        }
    }
}
```

`Sources/VectorEngine/Curves/CurveFitter.swift`:
```swift
enum CurveFitter {
    // Walking-skeleton version: straight lines through the polygon. Task 10 replaces this file.
    static func fit(_ polys: [PolyChain], params: CurveParams) -> [Curve] {
        polys.map { p in
            var pts = p.polygon
            if p.isClosed { pts.append(pts[0]) }
            return Curve.polyline(pts)
        }
    }
}
```

- [ ] **Step 4: Implement the pipeline**

`Sources/VectorEngine/Pipeline/Pipeline.swift`:
```swift
import Foundation

public enum Stage: Int, CaseIterable, Sendable, Comparable {
    case analyze, prefilter, quantize, segment, contours, polygon, curves, svg

    public static func < (a: Stage, b: Stage) -> Bool { a.rawValue < b.rawValue }

    public var title: String {
        switch self {
        case .analyze: "Analyze"
        case .prefilter: "Pre-filter"
        case .quantize: "Quantize"
        case .segment: "Segment"
        case .contours: "Contours"
        case .polygon: "Polygon"
        case .curves: "Curves"
        case .svg: "SVG"
        }
    }

    /// File-name friendly: "analyze", "prefilter", …
    public var slug: String { title.lowercased().replacingOccurrences(of: "-", with: "") }
}

/// Everything computed so far for one input image.
public struct PipelineState: Sendable {
    public let input: InputImage
    public internal(set) var options: Options
    public internal(set) var resolved: ResolvedOptions?
    public internal(set) var analysis: Analysis?
    public internal(set) var prefiltered: Bitmap?
    public internal(set) var quantized: QuantizedImage?
    public internal(set) var segmentation: Segmentation?
    public internal(set) var topology: Topology?
    public internal(set) var polygons: [PolyChain]?
    public internal(set) var curves: [Curve]?
    public internal(set) var result: VectorResult?

    public init(input: InputImage, options: Options) {
        self.input = input
        self.options = options
    }

    func has(_ stage: Stage) -> Bool {
        switch stage {
        case .analyze: analysis != nil
        case .prefilter: prefiltered != nil
        case .quantize: quantized != nil
        case .segment: segmentation != nil
        case .contours: topology != nil
        case .polygon: polygons != nil
        case .curves: curves != nil
        case .svg: result != nil
        }
    }

    mutating func copy(_ stage: Stage, from p: PipelineState) {
        switch stage {
        case .analyze:
            analysis = p.analysis
            resolved = options.resolved(with: p.analysis!)
        case .prefilter: prefiltered = p.prefiltered
        case .quantize: quantized = p.quantized
        case .segment: segmentation = p.segmentation
        case .contours: topology = p.topology
        case .polygon: polygons = p.polygons
        case .curves: curves = p.curves
        case .svg: result = p.result
        }
    }
}

public struct StageEvent: Sendable {
    public let stage: Stage
    public let duration: Duration
    /// True when the output was carried over from the previous run instead of recomputed.
    public let reused: Bool
    public let state: PipelineState
}

extension ResolvedOptions {
    /// The earliest stage whose parameters differ (analysis and contours have none here).
    public func firstChangedStage(comparedTo o: ResolvedOptions) -> Stage? {
        if prefilter != o.prefilter { return .prefilter }
        if quantize != o.quantize { return .quantize }
        if segment != o.segment { return .segment }
        if polygon != o.polygon { return .polygon }
        if curve != o.curve { return .curves }
        if output != o.output { return .svg }
        return nil
    }
}

public enum Pipeline {
    /// Runs every stage in order, reusing outputs from `previous` where the input and the relevant
    /// options are unchanged. `onStage` is called after each stage; throwing from it stops the run.
    public static func run(input: InputImage, options: Options, reusing previous: PipelineState? = nil,
                           onStage: (StageEvent) throws -> Void = { _ in }) throws -> PipelineState
    {
        var state = PipelineState(input: input, options: options)
        let start = previous.map { firstStageToCompute(previous: $0, input: input, options: options) } ?? 0
        for stage in Stage.allCases {
            if stage.rawValue < start, let prev = previous {
                state.copy(stage, from: prev)
                try onStage(StageEvent(stage: stage, duration: .zero, reused: true, state: state))
            } else {
                try Task.checkCancellation()
                let t0 = ContinuousClock.now
                compute(stage, &state)
                try onStage(StageEvent(stage: stage, duration: ContinuousClock.now - t0, reused: false, state: state))
            }
        }
        return state
    }

    /// Raw value of the first stage that must be recomputed (`Stage.allCases.count` = none).
    static func firstStageToCompute(previous p: PipelineState, input: InputImage, options: Options) -> Int {
        guard p.input.id == input.id, let analysis = p.analysis, let oldResolved = p.resolved,
              ClassifierParams(p.options.advanced) == ClassifierParams(options.advanced)
        else { return 0 }
        let changed = options.resolved(with: analysis).firstChangedStage(comparedTo: oldResolved)?.rawValue ?? Stage.allCases.count
        let missing = Stage.allCases.first { !p.has($0) }?.rawValue ?? Stage.allCases.count
        return min(changed, missing)
    }

    static func compute(_ stage: Stage, _ s: inout PipelineState) {
        switch stage {
        case .analyze:
            let a = Analyzer.analyze(s.input.bitmap, params: ClassifierParams(s.options.advanced))
            s.analysis = a
            s.resolved = s.options.resolved(with: a)
        case .prefilter:
            s.prefiltered = Prefilter.apply(s.input.bitmap, params: s.resolved!.prefilter)
        case .quantize:
            s.quantized = Quantizer.quantize(s.prefiltered!, params: s.resolved!.quantize)
        case .segment:
            s.segmentation = Segmenter.segment(s.quantized!, params: s.resolved!.segment)
        case .contours:
            s.topology = Topology.build(s.segmentation!)
        case .polygon:
            s.polygons = PolygonBuilder.build(s.topology!, params: s.resolved!.polygon)
        case .curves:
            s.curves = CurveFitter.fit(s.polygons!, params: s.resolved!.curve)
        case .svg:
            let r = s.resolved!, input = s.input
            let shapes = ShapeAssembler.shapes(topology: s.topology!, regions: s.segmentation!.regions, curves: s.curves!, tracing: r.output.tracing)
                .map { $0.scaled(input.scaleX, input.scaleY) }
            s.result = VectorResult(shapes: shapes, width: input.originalWidth, height: input.originalHeight, precision: r.output.precision)
        }
    }
}

public enum Vectorizer {
    public static func vectorize(_ input: InputImage, options: Options = Options()) throws -> VectorResult {
        try Pipeline.run(input: input, options: options).result!
    }

    public static func vectorize(contentsOf url: URL, options: Options = Options()) throws -> VectorResult {
        try vectorize(InputImage.load(contentsOf: url, maxDimension: options.advanced.maxProcessingDimension), options: options)
    }
}
```

- [ ] **Step 5: Run the whole suite**

Run: `swift test`
Expected: all tests pass, including the 9 new PipelineTests.

- [ ] **Step 6: Commit**

```bash
git add Sources/VectorEngine/Polygon Sources/VectorEngine/Curves Sources/VectorEngine/Pipeline/Pipeline.swift Tests/VectorEngineTests/PipelineTests.swift
git commit -m "feat: staged pipeline with reuse of unchanged stages"
```

---

### Task 8: `vectorize` CLI and sample images

**Files:**
- Modify: `Package.swift` (replace whole file)
- Create: `Sources/vectorize/VectorizeCommand.swift`, `scripts/make-samples.swift`

**Interfaces:**
- Consumes: `Options`, `InputImage.load`, `Pipeline.run`, `ImageKind`, `TracingMode` (Tasks 1–7).
- Produces: the executable `vectorize <input> [-o out.svg] [--mode auto|logo|photo] [--trace auto|shared|stacked] [--colors N] [--detail D] [--smoothness S] [--speck N] [--max-size N] [-v]`. Task 11 adds `--stages <dir>`.

- [ ] **Step 1: Add the executable target**

`Package.swift`:
```swift
// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "VectorEngine",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "VectorEngine", targets: ["VectorEngine"]),
        .executable(name: "vectorize", targets: ["vectorize"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(name: "VectorEngine"),
        .executableTarget(
            name: "vectorize",
            dependencies: ["VectorEngine", .product(name: "ArgumentParser", package: "swift-argument-parser")]),
        .testTarget(name: "VectorEngineTests", dependencies: ["VectorEngine"]),
    ]
)
```

- [ ] **Step 2: Write the command**

`Sources/vectorize/VectorizeCommand.swift`:
```swift
import ArgumentParser
import Foundation
import VectorEngine

@main
struct VectorizeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "vectorize", abstract: "Convert a bitmap image into an SVG.")

    enum ModeChoice: String, ExpressibleByArgument, CaseIterable { case auto, logo, photo }
    enum TraceChoice: String, ExpressibleByArgument, CaseIterable { case auto, shared, stacked }

    @Argument(help: "Input image (PNG, JPEG, HEIC, TIFF, …).") var input: String
    @Option(name: .shortAndLong, help: "Output SVG path (default: the input name with .svg).") var output: String?
    @Option(help: "Pipeline: auto, logo or photo.") var mode: ModeChoice = .auto
    @Option(help: "Tracing: auto, shared or stacked.") var trace: TraceChoice = .auto
    @Option(help: "Number of colors.") var colors: Int?
    @Option(help: "Detail 0–1 (higher keeps more nodes).") var detail: Double?
    @Option(help: "Smoothness 0–1 (higher rounds more corners).") var smoothness: Double?
    @Option(help: "Merge regions smaller than this many pixels.") var speck: Int?
    @Option(help: "Longest side used for processing, in pixels.") var maxSize: Int = 2000
    @Flag(name: .shortAndLong, help: "Print stage timings, analysis and stats.") var verbose = false

    func run() throws {
        let inURL = URL(fileURLWithPath: input)
        let outURL = output.map { URL(fileURLWithPath: $0) } ?? inURL.deletingPathExtension().appendingPathExtension("svg")

        var options = Options(kind: ImageKind(rawValue: mode.rawValue), colorCount: colors, detail: detail,
                              smoothness: smoothness, speckSize: speck)
        options.tracing = switch trace {
        case .auto: nil
        case .shared: .sharedEdges
        case .stacked: .stacked
        }
        options.advanced.maxProcessingDimension = maxSize

        let image = try InputImage.load(contentsOf: inURL, maxDimension: maxSize)
        let state = try Pipeline.run(input: image, options: options) { event in
            guard verbose else { return }
            let c = event.duration.components
            let ms = Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
            let line = event.stage.title.padding(toLength: 10, withPad: " ", startingAt: 0) + String(format: "%8.1f ms\n", ms)
            FileHandle.standardError.write(Data(line.utf8))
        }
        guard let result = state.result else { throw ExitCode.failure }
        try result.svg.write(to: outURL, atomically: true, encoding: .utf8)

        if verbose, let a = state.analysis, let r = state.resolved {
            print("kind: \(r.kind.rawValue) (detected \(a.kind.rawValue): \(a.significantColors) colors, gradient \(String(format: "%.2f", a.gradientFraction)))")
            print("tracing: \(r.output.tracing.rawValue), palette: \(state.quantized?.palette.count ?? 0) colors, processed at \(image.bitmap.width)×\(image.bitmap.height)")
            print("paths: \(result.stats.pathCount), segments: \(result.stats.segmentCount), bytes: \(result.stats.byteCount)")
        }
        print(outURL.path)
    }
}
```

- [ ] **Step 3: Write the sample generator**

`scripts/make-samples.swift`:
```swift
// Generates sample images for manual runs: swift scripts/make-samples.swift samples
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let dir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "samples")
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }

func save(_ name: String, width: Int, height: Int, _ draw: (CGContext) -> Void) {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    draw(ctx)
    let url = dir.appendingPathComponent(name)
    let type = name.hasSuffix(".jpg") ? UTType.jpeg : UTType.png
    let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
    CGImageDestinationFinalize(dest)
    print(url.path)
}

func drawLogo(_ ctx: CGContext) {
    ctx.setFillColor(color(0.10, 0.20, 0.55)); ctx.fillEllipse(in: CGRect(x: 20, y: 20, width: 360, height: 360))
    ctx.setFillColor(color(1, 1, 1)); ctx.fillEllipse(in: CGRect(x: 60, y: 60, width: 280, height: 280))
    ctx.setFillColor(color(0.95, 0.65, 0.10))
    ctx.move(to: CGPoint(x: 200, y: 300)); ctx.addLine(to: CGPoint(x: 290, y: 140)); ctx.addLine(to: CGPoint(x: 110, y: 140))
    ctx.closePath(); ctx.fillPath()
    ctx.setFillColor(color(0.85, 0.15, 0.20)); ctx.fill(CGRect(x: 120, y: 100, width: 160, height: 24))
}

// Flat logo on a transparent background.
save("logo.png", width: 400, height: 400, drawLogo)
// Same logo as a JPEG on white: compression noise, no transparency.
save("logo.jpg", width: 400, height: 400) { ctx in
    ctx.setFillColor(color(1, 1, 1)); ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 400))
    drawLogo(ctx)
}
// Photo-like: radial gradient with translucent blobs.
save("photo.png", width: 400, height: 300) { ctx in
    let g = CGGradient(colorsSpace: srgb, colors: [color(0.95, 0.80, 0.40), color(0.20, 0.35, 0.70), color(0.05, 0.05, 0.15)] as CFArray,
                       locations: [0, 0.5, 1])!
    ctx.drawRadialGradient(g, startCenter: CGPoint(x: 280, y: 200), startRadius: 0, endCenter: CGPoint(x: 200, y: 150),
                           endRadius: 260, options: [.drawsAfterEndLocation])
    for i in 0..<12 {
        ctx.setFillColor(color(CGFloat(i % 3) * 0.4, 0.6, CGFloat(i % 4) * 0.25, 0.35))
        ctx.fillEllipse(in: CGRect(x: 20 + i * 30, y: 30 + (i * 53) % 200, width: 60, height: 60))
    }
}
```

- [ ] **Step 4: Build and try it**

Run:
```bash
swift scripts/make-samples.swift samples
swift build -c release
mkdir -p out
.build/release/vectorize samples/logo.png -o out/logo.svg --verbose
.build/release/vectorize samples/logo.jpg -o out/logo-jpg.svg --verbose
.build/release/vectorize samples/photo.png -o out/photo.svg --verbose
```
Expected:
- The first two commands print `kind: logo` and `tracing: sharedEdges`, with a palette of 4 colors (navy, white, orange, red; logo.png's surround is transparent).
- The photo command prints `kind: photo` and `tracing: stacked`.
- Each command ends by printing the output path.
- The SVGs are still faceted: they use straight pixel edges until Tasks 9–10.

If the classifier misjudges a sample, record the printed `gradient`/`colors` values in the task report rather than retuning thresholds here.

- [ ] **Step 5: Check error handling**

Run: `.build/release/vectorize /nonexistent.png; echo "exit=$?"`
Expected: `Error: Could not read an image from /nonexistent.png` and `exit=1`.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Package.resolved Sources/vectorize scripts
git commit -m "feat: vectorize CLI and sample image generator"
```

---

### Task 9: Polygon stage (staircase removal, simplification, corner detection)

**Files:**
- Modify: `Sources/VectorEngine/Polygon/PolygonBuilder.swift` (replace the whole file)
- Test: `Tests/VectorEngineTests/PolygonTests.swift`

**Background for the implementer:**
- *Dense points.* A pixel boundary is a staircase. The midpoint of every straight run lies on the ideal edge: for a slope-1/3 edge, the midpoints of runs 3,1,3,1… are exactly collinear. A turn between two runs that are both at least `cornerRunLength` long is a real corner, such as a rectangle's, so that lattice vertex is kept too.
- *Simplification.* Douglas–Peucker on the dense points. Open chains pin both endpoints, which are the junctions, so neighboring regions stay welded. Closed loops split at point 0 and the point farthest from it. Afterwards, a cleanup pass drops vertices the split forced in that turn out to be redundant. Then *sharpening* rebuilds corners that anti-aliasing shaved into a short bevel: two vertices under 8 px apart, between edges at least 2.5× longer, are replaced by the intersection of those edges.
- *Corners.* A polygon vertex is a corner if its turn is ≥ 150°, or if its turn is ≥ `cornerAngle` and at least one adjacent edge is straight (its dense points bulge less than `straightTolerance` or 5% of the edge length). That distinguishes a square or triangle, whose edges are straight apart from anti-aliasing wobble, from the polygon of a small circle, whose edges bulge.

**Interfaces:**
- Consumes: `Chain`, `Topology`, `PolygonParams`, `Vec2` (Tasks 1, 4, 6). Keeps `PolyChain` exactly as defined in Task 7.
- Produces: `PolygonBuilder.build(_ t: Topology, params:) -> [PolyChain]` (same signature) plus `PolygonBuilder.build(_ chain: Chain, params:) -> PolyChain`.

- [ ] **Step 1: Write the failing tests**

`Tests/VectorEngineTests/PolygonTests.swift`:
```swift
import Testing
@testable import VectorEngine

@Suite struct PolygonTests {
    let params = PolygonParams(tolerance: 1.0, cornerAngle: 60, cornerRunLength: 2, straightTolerance: 0.6)

    func trace(_ b: Bitmap, palette: [RGBA]) -> (Segmentation, Topology) {
        let seg = Segmenter.segment(Quantizer.assign(b, palette: palette, alphaThreshold: 128), params: SegmentParams(speckSize: 0))
        return (seg, Topology.build(seg))
    }

    /// The polygon of the (single, closed) chain around the region containing pixel (x, y).
    func polygon(around x: Int, _ y: Int, in b: Bitmap, palette: [RGBA]) -> PolyChain {
        let (seg, t) = trace(b, palette: palette)
        let r = seg.label(x, y)
        let chain = t.chains.first { $0.left == r || $0.right == r }!
        return PolygonBuilder.build(chain, params: params)
    }

    @Test func axisAlignedSquareBecomesFourCorners() {
        let b = Bitmap(width: 20, height: 20) { x, y in
            (5..<15).contains(x) && (5..<15).contains(y) ? TestImages.red : TestImages.white
        }
        let poly = polygon(around: 10, 10, in: b, palette: [TestImages.red, TestImages.white])
        #expect(Set(poly.polygon) == [Vec2(5, 5), Vec2(15, 5), Vec2(15, 15), Vec2(5, 15)])
        #expect(poly.corners == [true, true, true, true])
    }

    @Test func diamondKeepsFourCorners() {
        let b = Bitmap(width: 25, height: 25) { x, y in abs(x - 12) + abs(y - 12) <= 9 ? TestImages.red : TestImages.white }
        let poly = polygon(around: 12, 12, in: b, palette: [TestImages.red, TestImages.white])
        #expect(poly.corners.filter { $0 }.count == 4)
        #expect(poly.vertices.count <= 8)
    }

    @Test func antialiasedTriangleKeepsThreeSharpCorners() {
        let corners = [Vec2(32, 6), Vec2(58, 56), Vec2(6, 56)]
        func inside(_ p: Vec2) -> Bool {
            (0..<3).allSatisfy { i in
                let a = corners[i], b = corners[(i + 1) % 3]
                return (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x) >= 0
            }
        }
        let b = Bitmap(width: 64, height: 64) { x, y in
            var n = 0
            for sy in 0..<4 { for sx in 0..<4 where inside(Vec2(Double(x) + (Double(sx) + 0.5) / 4, Double(y) + (Double(sy) + 0.5) / 4)) { n += 1 } }
            return TestImages.blend(TestImages.red, TestImages.white, Double(n) / 16)
        }
        let q = Quantizer.logo(b, params: QuantizeParams(kind: .logo, colorCount: 8))
        let seg = Segmenter.segment(q, params: SegmentParams(speckSize: 4))
        let r = seg.label(32, 40)
        let chain = Topology.build(seg).chains.first { $0.left == r || $0.right == r }!
        let poly = PolygonBuilder.build(chain, params: params)
        #expect(poly.vertices.count == 3)
        #expect(poly.corners == [true, true, true])
        for v in poly.polygon { #expect(corners.map { $0.distance(to: v) }.min()! < 1.5) }
    }

    @Test func circleHasNoCorners() {
        let poly = polygon(around: 20, 20, in: TestImages.circle(size: 40, radius: 12), palette: [TestImages.red, TestImages.white])
        #expect(poly.corners.allSatisfy { !$0 })
        #expect(poly.vertices.count <= 20)
    }

    @Test func singlePixelKeepsAShape() {
        let b = TestImages.grid(["WWW", "WRW", "WWW"])
        let poly = polygon(around: 1, 1, in: b, palette: [TestImages.red, TestImages.white])
        #expect(poly.vertices.count >= 3)
    }

    @Test func shallowStaircaseIsOneStraightEdge() {
        let b = Bitmap(width: 30, height: 12) { x, y in y * 3 >= x ? TestImages.red : TestImages.white }
        let (seg, t) = trace(b, palette: [TestImages.red, TestImages.white])
        let pair = Set([seg.label(0, 11), seg.label(29, 0)])
        let chain = t.chains.first { Set([$0.left, $0.right]) == pair }!
        #expect(PolygonBuilder.build(chain, params: params).vertices.count == 2)
    }

    @Test func openChainsKeepTheirJunctionEndpoints() {
        let b = Bitmap(width: 30, height: 10) { x, _ in x < 10 ? TestImages.red : (x < 20 ? TestImages.white : TestImages.blue) }
        let (_, t) = trace(b, palette: [TestImages.red, TestImages.white, TestImages.blue])
        let open = t.chains.filter { !$0.isClosed }
        #expect(!open.isEmpty)
        for chain in open {
            let poly = PolygonBuilder.build(chain, params: params)
            #expect(poly.dense.first == chain.points.first!.vec && poly.dense.last == chain.points.last!.vec)
            #expect(poly.vertices.first == 0 && poly.vertices.last == poly.dense.count - 1)
            #expect(poly.corners.first == true && poly.corners.last == true)
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter PolygonTests`
Expected: FAIL. The skeleton keeps every lattice point, so the square has 40 vertices and the circle is all corners.

- [ ] **Step 3: Replace the polygon builder**

`Sources/VectorEngine/Polygon/PolygonBuilder.swift`:
```swift
import Foundation

/// One chain's boundary as dense points plus the simplified polygon chosen from them.
public struct PolyChain: Sendable, Equatable {
    /// Boundary sample points. Open chains include both endpoints; closed chains don't repeat the first point.
    public var dense: [Vec2]
    /// Indices into `dense` of the polygon's vertices, ascending.
    public var vertices: [Int]
    /// Whether each polygon vertex is a sharp corner (open-chain endpoints always are).
    public var corners: [Bool]
    public var isClosed: Bool

    public var polygon: [Vec2] { vertices.map { dense[$0] } }
}

enum PolygonBuilder {
    static func build(_ t: Topology, params: PolygonParams) -> [PolyChain] {
        t.chains.map { build($0, params: params) }
    }

    static func build(_ chain: Chain, params p: PolygonParams) -> PolyChain {
        var dense = densePoints(chain, cornerRunLength: p.cornerRunLength)
        var vertices: [Int]
        if chain.isClosed {
            vertices = removeRedundant(simplifyClosed(dense, tolerance: p.tolerance), dense, tolerance: p.tolerance)
            if vertices.count < 3 { vertices = Array(dense.indices) }
        } else {
            vertices = simplify(Array(dense.indices), dense, tolerance: p.tolerance)
        }
        (dense, vertices) = sharpenCorners(dense, vertices, isClosed: chain.isClosed, cornerAngle: p.cornerAngle)
        let corners = classifyCorners(dense, vertices, isClosed: chain.isClosed, params: p)
        return PolyChain(dense: dense, vertices: vertices, corners: corners, isClosed: chain.isClosed)
    }

    struct Run {
        var start: Int
        var length: Int
        var dx: Int
        var dy: Int
    }

    /// Groups consecutive unit steps of a lattice path (≥ 2 points) into straight runs.
    static func runs(_ pts: [LatticePoint]) -> [Run] {
        var out: [Run] = []
        for i in 0..<(pts.count - 1) {
            let dx = pts[i + 1].x - pts[i].x, dy = pts[i + 1].y - pts[i].y
            if let last = out.last, last.dx == dx, last.dy == dy {
                out[out.count - 1].length += 1
            } else {
                out.append(Run(start: i, length: 1, dx: dx, dy: dy))
            }
        }
        return out
    }

    /// Run midpoints, plus turn vertices between two long runs. Open chains keep exact endpoints.
    static func densePoints(_ chain: Chain, cornerRunLength: Int) -> [Vec2] {
        var pts = chain.points
        if chain.isClosed {
            pts.removeLast()
            let m = pts.count
            func step(_ i: Int) -> (Int, Int) {
                let a = pts[i % m], b = pts[(i + 1) % m]
                return (b.x - a.x, b.y - a.y)
            }
            // Start at a turn so no run wraps around the end of the list.
            if let t = (0..<m).first(where: { step($0 + m - 1) != step($0) }) {
                pts = Array(pts[t...] + pts[..<t])
            }
            pts.append(pts[0])
        }
        let rs = runs(pts)
        var out: [Vec2] = chain.isClosed ? [] : [pts[0].vec]
        for (k, r) in rs.enumerated() {
            out.append(pts[r.start].vec + Vec2(Double(r.dx), Double(r.dy)) * (Double(r.length) / 2))
            if k == rs.count - 1 && !chain.isClosed { break }
            let next = rs[(k + 1) % rs.count]
            if r.length >= cornerRunLength && next.length >= cornerRunLength {
                out.append(pts[r.start + r.length].vec)
            }
        }
        if !chain.isClosed { out.append(pts[pts.count - 1].vec) }
        return out
    }

    /// Douglas–Peucker over `idx` (indices into `pts`); always keeps the first and last index.
    static func simplify(_ idx: [Int], _ pts: [Vec2], tolerance: Double) -> [Int] {
        guard idx.count > 2 else { return idx }
        var keep = [Bool](repeating: false, count: idx.count)
        keep[0] = true
        keep[idx.count - 1] = true
        var stack = [(0, idx.count - 1)]
        while let (a, b) = stack.popLast() {
            guard b > a + 1 else { continue }
            var worst = -1.0, at = a
            for i in (a + 1)..<b {
                let d = pts[idx[i]].distance(toSegment: pts[idx[a]], pts[idx[b]])
                if d > worst { worst = d; at = i }
            }
            if worst > tolerance {
                keep[at] = true
                stack.append((a, at))
                stack.append((at, b))
            }
        }
        return idx.indices.filter { keep[$0] }.map { idx[$0] }
    }

    /// Douglas–Peucker on a ring: split at point 0 and the point farthest from it.
    static func simplifyClosed(_ pts: [Vec2], tolerance: Double) -> [Int] {
        let n = pts.count
        guard n > 3 else { return Array(0..<n) }
        let far = (1..<n).max { pts[$0].distance(to: pts[0]) < pts[$1].distance(to: pts[0]) }!
        let first = simplify(Array(0...far), pts, tolerance: tolerance)
        let second = simplify(Array(far..<n) + [0], pts, tolerance: tolerance)
        return first + second.dropFirst().dropLast()
    }

    /// Drops ring vertices whose removal keeps every dense point within tolerance.
    static func removeRedundant(_ v: [Int], _ dense: [Vec2], tolerance: Double) -> [Int] {
        var v = v
        var j = 0
        while j < v.count && v.count > 3 {
            let prev = v[(j + v.count - 1) % v.count], next = v[(j + 1) % v.count]
            if maxDeviation(dense, from: prev, to: next) <= tolerance { v.remove(at: j) } else { j += 1 }
        }
        return v
    }

    /// Bevels shorter than this (px) are candidates for sharpening.
    static let cornerReach = 8.0

    /// Anti-aliasing and quantization shave sharp corners into a short bevel: two vertices a few
    /// pixels apart between two much longer edges. Replace such a pair with the intersection of
    /// those edges when it is close by and forms a real corner. Open-chain endpoints never move.
    static func sharpenCorners(_ dense: [Vec2], _ v: [Int], isClosed: Bool, cornerAngle: Double) -> ([Vec2], [Int]) {
        var dense = dense, v = v
        var j = isClosed ? 0 : 1
        while true {
            let m = v.count
            guard m >= (isClosed ? 5 : 4) else { break }
            // Edge (j, j+1). Closed rings skip the wrap-around edge; open chains keep both ends fixed.
            if isClosed ? j >= m - 1 : j + 2 >= m { break }
            let a = dense[v[isClosed ? (j + m - 1) % m : j - 1]], b = dense[v[j]]
            let c = dense[v[j + 1]], d = dense[v[(j + 2) % m]]
            let bevel = b.distance(to: c)
            if bevel < cornerReach, a.distance(to: b) >= 2.5 * bevel, c.distance(to: d) >= 2.5 * bevel,
               let x = intersection(a, b, d, c),
               x.distance(to: b) < cornerReach, x.distance(to: c) < cornerReach,
               turnDegrees(a, x, d) >= cornerAngle
            {
                let lo = v[j], hi = v[j + 1]
                dense.replaceSubrange(lo...hi, with: [x])
                v.remove(at: j + 1)
                for k in (j + 1)..<v.count { v[k] -= hi - lo }
            } else {
                j += 1
            }
        }
        return (dense, v)
    }

    /// Where the line through a→b meets the line through d→c, unless they're parallel.
    static func intersection(_ a: Vec2, _ b: Vec2, _ d: Vec2, _ c: Vec2) -> Vec2? {
        let r = b - a, s = c - d
        let denom = r.x * s.y - r.y * s.x
        guard abs(denom) > 1e-9 else { return nil }
        let t = ((d.x - a.x) * s.y - (d.y - a.y) * s.x) / denom
        return a + r * t
    }

    /// How far the path a → c → b turns at c, in degrees (0 = straight on).
    static func turnDegrees(_ a: Vec2, _ c: Vec2, _ b: Vec2) -> Double {
        acos(max(-1, min(1, (c - a).normalized.dot((b - c).normalized)))) * 180 / .pi
    }

    static func classifyCorners(_ dense: [Vec2], _ v: [Int], isClosed: Bool, params p: PolygonParams) -> [Bool] {
        let m = v.count
        return (0..<m).map { j in
            if !isClosed && (j == 0 || j == m - 1) { return true }
            let prev = (j + m - 1) % m, next = (j + 1) % m
            let turn = turnDegrees(dense[v[prev]], dense[v[j]], dense[v[next]])
            if turn >= 150 { return true }
            guard turn >= p.cornerAngle else { return false }
            return isStraight(dense, v[prev], v[j], p) || isStraight(dense, v[j], v[next], p)
        }
    }

    /// An edge is straight if its points bulge less than `straightTolerance` or 5% of its length.
    /// (An arc turning by `cornerAngle` or more bulges by at least ~12% of its chord, so arcs fail.)
    static func isStraight(_ dense: [Vec2], _ i: Int, _ j: Int, _ p: PolygonParams) -> Bool {
        maxDeviation(dense, from: i, to: j) <= max(p.straightTolerance, 0.05 * dense[i].distance(to: dense[j]))
    }

    /// Largest distance from the dense points strictly between i and j (walking forward, wrapping)
    /// to the chord i–j.
    static func maxDeviation(_ dense: [Vec2], from i: Int, to j: Int) -> Double {
        let n = dense.count
        var worst = 0.0, k = (i + 1) % n
        while k != j {
            worst = max(worst, dense[k].distance(toSegment: dense[i], dense[j]))
            k = (k + 1) % n
        }
        return worst
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter PolygonTests`
Expected: all 7 tests pass.

- [ ] **Step 5: Run the whole suite**

Run: `swift test`
Expected: everything passes. `PipelineTests.logoEndToEnd` still needs agreement > 0.95 and no uncovered pixels; shared chains keep that true.

- [ ] **Step 6: Commit**

```bash
git add Sources/VectorEngine/Polygon Tests/VectorEngineTests/PolygonTests.swift
git commit -m "feat: staircase-free polygon simplification with corner detection"
```

---

### Task 10: Bézier curve fitting

**Files:**
- Create: `Sources/VectorEngine/Curves/BezierFit.swift`
- Modify: `Sources/VectorEngine/Curves/CurveFitter.swift` (replace the whole file)
- Test: `Tests/VectorEngineTests/CurveTests.swift`

**Background for the implementer:** `BezierFit` is Philip Schneider's least-squares cubic fitting from *Graphics Gems* (1990). Starting from chord-length parameters, it solves for the two control-point distances along fixed end tangents, refines the parameters with Newton–Raphson, and splits at the worst point when the error is still too large. `CurveFitter` breaks each chain at its corners and fits each span between them. A span that is a single polygon edge, or whose points stay within `straightTolerance` of its chord, becomes a single line. A closed loop with fewer than two corners gets *smooth joins* added, so that no span starts and ends at the same point; at a smooth join both sides share one central tangent, which keeps the outline smooth.

**Interfaces:**
- Consumes: `PolyChain`, `CurveParams`, `Curve`, `PathSegment`, `Vec2` (Tasks 5–7, 9).
- Produces:
  - `BezierFit.fit(_ pts: [Vec2], leftTangent: Vec2, rightTangent: Vec2, tolerance: Double) -> [PathSegment]`. `leftTangent` points from `pts[0]` into the curve; `rightTangent` points from the last point back into it.
  - `BezierFit.point(_ bez: [Vec2], _ t: Double) -> Vec2`
  - `CurveFitter.fit(_ polys:params:)` (same signature as Task 7) and `CurveFitter.fit(_ poly: PolyChain, params:) -> Curve`. An open chain's curve runs from `dense.first` to `dense.last`; a closed chain's curve starts and ends at the same point.

- [ ] **Step 1: Write the failing tests**

`Tests/VectorEngineTests/CurveTests.swift`:
```swift
import Testing
@testable import VectorEngine

@Suite struct CurveTests {
    /// Points along a curve, densely sampled, for distance checks.
    func samples(_ start: Vec2, _ segments: [PathSegment]) -> [Vec2] {
        var out = [start], cur = start
        for seg in segments {
            switch seg {
            case .line(let to):
                for i in 1...20 { out.append(cur + (to - cur) * (Double(i) / 20)) }
            case .cubic(let c1, let c2, let to):
                for i in 1...50 { out.append(BezierFit.point([cur, c1, c2, to], Double(i) / 50)) }
            }
            cur = seg.end
        }
        return out
    }

    func shared(_ b: Bitmap, _ options: Options = Options()) throws -> PipelineState {
        try Pipeline.run(input: InputImage(bitmap: b), options: options)
    }

    @Test func quarterCircleFitsWithinTolerance() {
        let pts = (0...30).map { i -> Vec2 in
            let a = Double(i) / 30 * .pi / 2
            return Vec2(20 * cos(a), 20 * sin(a))
        }
        let segs = BezierFit.fit(pts, leftTangent: Vec2(0, 1), rightTangent: Vec2(1, 0), tolerance: 0.25)
        #expect(segs.count <= 2)
        let curve = samples(pts[0], segs)
        for p in pts { #expect(curve.map { $0.distance(to: p) }.min()! < 0.3) }
        #expect(segs.last?.end == pts.last)
    }

    @Test func squareBecomesFourLines() {
        let b = Bitmap(width: 20, height: 20) { x, y in
            (5..<15).contains(x) && (5..<15).contains(y) ? TestImages.red : TestImages.white
        }
        let seg = Segmenter.segment(Quantizer.assign(b, palette: [TestImages.red, TestImages.white], alphaThreshold: 128), params: SegmentParams(speckSize: 0))
        let t = Topology.build(seg)
        let r = seg.label(10, 10)
        let chain = t.chains.first { $0.left == r || $0.right == r }!
        let poly = PolygonBuilder.build(chain, params: PolygonParams(tolerance: 1, cornerAngle: 60, cornerRunLength: 2, straightTolerance: 0.6))
        let curve = CurveFitter.fit(poly, params: CurveParams(tolerance: 1, straightTolerance: 0.6))
        #expect(curve.segments.count == 4)
        #expect(curve.segments.allSatisfy { if case .line = $0 { true } else { false } })
        #expect(curve.end == curve.start)
    }

    @Test func circleBecomesAFewCubicsAndStaysFaithful() throws {
        let s = try shared(TestImages.circle(size: 48, radius: 16, antialias: true))
        let result = try #require(s.result)
        #expect(result.shapes.count == 2)
        let disc = try #require(result.shapes.first { Lab($0.color).distance(to: Lab(TestImages.red)) < 5 })
        #expect(disc.subpaths.count == 1 && disc.subpaths[0].segments.count <= 8)
        let raster = ShapeRenderer.rasterize(result.shapes, width: 48, height: 48, antialias: false, background: TestImages.magenta)
        #expect(!raster.pixels.contains(TestImages.magenta))
        #expect(TestImages.agreement(raster, try #require(s.quantized).makeBitmap()) > 0.97)
    }

    // Review focus: thin ring around a larger disk, stacked mode.
    @Test func stackedModeKeepsRingAndDiskVisible() throws {
        let b = TestImages.ringAroundDisk()
        let r = try #require(try shared(b, Options(tracing: .stacked)).result)
        let raster = ShapeRenderer.rasterize(r.shapes, width: 40, height: 40, antialias: false)
        #expect(raster[20, 20] == TestImages.blue)
        #expect(raster[20, 6] == TestImages.red)
        #expect(TestImages.agreement(raster, b) > 0.95)
    }

    @Test(arguments: TracingMode.allCases)
    func busyImageStaysCoveredAndFaithful(tracing: TracingMode) throws {
        let b = TestImages.randomBlocks(width: 32, height: 32)
        let s = try shared(b, Options(tracing: tracing, speckSize: 0))
        let raster = ShapeRenderer.rasterize(try #require(s.result).shapes, width: 32, height: 32, antialias: false, background: TestImages.magenta)
        #expect(raster.pixels.filter { $0 == TestImages.magenta }.isEmpty)
        #expect(TestImages.agreement(raster, try #require(s.quantized).makeBitmap()) > 0.85)
    }

    @Test func curvesShrinkTheSVG() throws {
        // Same image traced with tight vs loose detail: loose must not be larger.
        let b = TestImages.circle(size: 64, radius: 24, antialias: true)
        let tight = try #require(try shared(b, Options(detail: 1)).result)
        let loose = try #require(try shared(b, Options(detail: 0)).result)
        #expect(loose.stats.byteCount <= tight.stats.byteCount)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter CurveTests`
Expected: build failure, with errors such as "cannot find 'BezierFit' in scope".

- [ ] **Step 3: Implement Schneider fitting**

`Sources/VectorEngine/Curves/BezierFit.swift`:
```swift
/// Least-squares cubic Bézier fitting (Schneider, "An Algorithm for Automatically Fitting
/// Digitized Curves", Graphics Gems, 1990).
enum BezierFit {
    /// Fits cubics through `pts` (≥ 2 points), starting at pts[0]. `leftTangent` points from the
    /// start into the curve; `rightTangent` points from the end back into the curve (unit vectors).
    static func fit(_ pts: [Vec2], leftTangent: Vec2, rightTangent: Vec2, tolerance: Double) -> [PathSegment] {
        var out: [PathSegment] = []
        fitCubic(pts, 0, pts.count - 1, leftTangent, rightTangent, tolerance * tolerance, &out)
        return out
    }

    /// `error` is a squared distance.
    private static func fitCubic(_ d: [Vec2], _ first: Int, _ last: Int, _ t1: Vec2, _ t2: Vec2, _ error: Double, _ out: inout [PathSegment]) {
        if last - first == 1 {
            let dist = d[first].distance(to: d[last]) / 3
            out.append(.cubic(c1: d[first] + t1 * dist, c2: d[last] + t2 * dist, to: d[last]))
            return
        }
        var u = chordLengthParameterize(d, first, last)
        var bez = generateBezier(d, first, last, u, t1, t2)
        var (maxError, split) = computeMaxError(d, first, last, bez, u)
        if maxError < error { out.append(.cubic(c1: bez[1], c2: bez[2], to: bez[3])); return }
        if maxError < error * 4 {
            for _ in 0..<4 {
                u = reparameterize(d, first, u, bez)
                bez = generateBezier(d, first, last, u, t1, t2)
                (maxError, split) = computeMaxError(d, first, last, bez, u)
                if maxError < error { out.append(.cubic(c1: bez[1], c2: bez[2], to: bez[3])); return }
            }
        }
        var center = (d[split - 1] - d[split + 1]).normalized
        if center == .zero { center = (d[split - 1] - d[split]).normalized }
        fitCubic(d, first, split, t1, center, error, &out)
        fitCubic(d, split, last, -center, t2, error, &out)
    }

    private static func chordLengthParameterize(_ d: [Vec2], _ first: Int, _ last: Int) -> [Double] {
        var u = [0.0]
        for i in (first + 1)...last { u.append(u[u.count - 1] + d[i].distance(to: d[i - 1])) }
        let total = u[u.count - 1]
        return total > 0 ? u.map { $0 / total } : u.indices.map { Double($0) / Double(u.count - 1) }
    }

    private static func generateBezier(_ d: [Vec2], _ first: Int, _ last: Int, _ u: [Double], _ t1: Vec2, _ t2: Vec2) -> [Vec2] {
        let p0 = d[first], p3 = d[last]
        var c00 = 0.0, c01 = 0.0, c11 = 0.0, x0 = 0.0, x1 = 0.0
        for (i, t) in u.enumerated() {
            let a0 = t1 * b1(t), a1 = t2 * b2(t)
            c00 += a0.dot(a0)
            c01 += a0.dot(a1)
            c11 += a1.dot(a1)
            let tmp = d[first + i] - (p0 * (b0(t) + b1(t)) + p3 * (b2(t) + b3(t)))
            x0 += a0.dot(tmp)
            x1 += a1.dot(tmp)
        }
        let det = c00 * c11 - c01 * c01
        var alphaL = det == 0 ? 0 : (x0 * c11 - x1 * c01) / det
        var alphaR = det == 0 ? 0 : (c00 * x1 - c01 * x0) / det
        let segLength = p0.distance(to: p3)
        let epsilon = 1e-6 * segLength
        if alphaL < epsilon || alphaR < epsilon {
            alphaL = segLength / 3
            alphaR = segLength / 3
        }
        return [p0, p0 + t1 * alphaL, p3 + t2 * alphaR, p3]
    }

    /// Largest squared distance between a point and its parameter's position on the curve.
    private static func computeMaxError(_ d: [Vec2], _ first: Int, _ last: Int, _ bez: [Vec2], _ u: [Double]) -> (Double, Int) {
        var maxDist = 0.0, split = (last - first + 1) / 2 + first
        for i in (first + 1)..<last {
            let v = point(bez, u[i - first]) - d[i]
            let dist = v.dot(v)
            if dist >= maxDist { maxDist = dist; split = i }
        }
        return (maxDist, split)
    }

    private static func reparameterize(_ d: [Vec2], _ first: Int, _ u: [Double], _ bez: [Vec2]) -> [Double] {
        u.enumerated().map { newtonRaphson(bez, d[first + $0.offset], $0.element) }
    }

    private static func newtonRaphson(_ q: [Vec2], _ p: Vec2, _ u: Double) -> Double {
        let q1 = [(q[1] - q[0]) * 3, (q[2] - q[1]) * 3, (q[3] - q[2]) * 3]
        let q2 = [(q1[1] - q1[0]) * 2, (q1[2] - q1[1]) * 2]
        let qu = point(q, u)
        let q1u = q1[0] * ((1 - u) * (1 - u)) + q1[1] * (2 * u * (1 - u)) + q1[2] * (u * u)
        let q2u = q2[0] * (1 - u) + q2[1] * u
        let num = (qu - p).dot(q1u)
        let den = q1u.dot(q1u) + (qu - p).dot(q2u)
        guard den != 0 else { return u }
        return max(0, min(1, u - num / den))
    }

    static func point(_ b: [Vec2], _ t: Double) -> Vec2 {
        b[0] * b0(t) + b[1] * b1(t) + b[2] * b2(t) + b[3] * b3(t)
    }

    private static func b0(_ t: Double) -> Double { let m = 1 - t; return m * m * m }
    private static func b1(_ t: Double) -> Double { let m = 1 - t; return 3 * t * m * m }
    private static func b2(_ t: Double) -> Double { 3 * t * t * (1 - t) }
    private static func b3(_ t: Double) -> Double { t * t * t }
}
```

- [ ] **Step 4: Replace the curve fitter**

`Sources/VectorEngine/Curves/CurveFitter.swift`:
```swift
enum CurveFitter {
    static func fit(_ polys: [PolyChain], params: CurveParams) -> [Curve] {
        polys.map { fit($0, params: params) }
    }

    /// Breaks the chain at corners (and open ends) and fits each span: spans that are a single
    /// polygon edge, or whose points stay within `straightTolerance` of the chord, become one line;
    /// the rest become Bézier cubics. Closed loops with < 2 corners get smooth joins added so no
    /// span starts and ends at the same point.
    static func fit(_ poly: PolyChain, params p: CurveParams) -> Curve {
        let dense = poly.dense, n = dense.count, v = poly.vertices
        var breaks = zip(v, poly.corners).filter(\.1).map(\.0)
        var smooth = Set<Int>()
        if poly.isClosed && breaks.count < 2 {
            let anchor = breaks.first.flatMap { b in v.firstIndex(of: b) } ?? 0
            let joins = breaks.isEmpty ? [v[0], v[v.count / 2]] : [v[(anchor + v.count / 2) % v.count]]
            smooth = Set(joins)
            breaks = (breaks + joins).sorted()
        }

        func central(_ i: Int) -> Vec2 { (dense[(i + 2) % n] - dense[(i - 2 + n) % n]).normalized }

        var spans: [(Int, Int)] = []
        for i in 0..<(breaks.count - 1) { spans.append((breaks[i], breaks[i + 1])) }
        if poly.isClosed { spans.append((breaks[breaks.count - 1], breaks[0])) }

        let vertexSet = Set(v)
        var segments: [PathSegment] = []
        for (a, b) in spans {
            var pts: [Vec2] = []
            var interiorVertex = false
            var k = a
            while true {
                pts.append(dense[k])
                if k == b && pts.count > 1 { break }
                if pts.count > 1 && vertexSet.contains(k) { interiorVertex = true }
                k = (k + 1) % n
            }
            // A span that is a single polygon edge was already judged straight by the polygon stage.
            if !interiorVertex { segments.append(.line(to: dense[b])); continue }
            let start = smooth.contains(a) ? central(a) : forward(pts)
            let end = smooth.contains(b) ? -central(b) : backward(pts)
            segments += fitSpan(pts, startTangent: start, endTangent: end, params: p)
        }
        return Curve(start: dense[breaks[0]], segments: segments)
    }

    static func fitSpan(_ pts: [Vec2], startTangent: Vec2, endTangent: Vec2, params p: CurveParams) -> [PathSegment] {
        let a = pts[0], b = pts[pts.count - 1]
        if pts.count == 2 || pts.dropFirst().dropLast().allSatisfy({ $0.distance(toSegment: a, b) <= p.straightTolerance }) {
            return [.line(to: b)]
        }
        return BezierFit.fit(pts, leftTangent: startTangent, rightTangent: endTangent, tolerance: p.tolerance)
    }

    /// Direction leaving the first point, estimated a few points ahead.
    static func forward(_ pts: [Vec2]) -> Vec2 {
        let k = min(3, pts.count - 1)
        let t = (pts[k] - pts[0]).normalized
        return t == .zero ? (pts[pts.count - 1] - pts[0]).normalized : t
    }

    /// Direction from the last point back into the curve.
    static func backward(_ pts: [Vec2]) -> Vec2 {
        let k = min(3, pts.count - 1)
        let t = (pts[pts.count - 1 - k] - pts[pts.count - 1]).normalized
        return t == .zero ? (pts[0] - pts[pts.count - 1]).normalized : t
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter CurveTests`
Expected: all 7 test cases pass.

- [ ] **Step 6: Run the whole suite and look at the output**

Run:
```bash
swift test
swift build -c release && .build/release/vectorize samples/logo.png -o out/logo.svg --verbose && open -a Safari out/logo.svg
```
Expected: all tests pass. The logo should render with smooth circles and sharp triangle and bar corners. Its segment count should be far below the Task 8 run (record both numbers in the report).

- [ ] **Step 7: Commit**

```bash
git add Sources/VectorEngine/Curves Tests/VectorEngineTests/CurveTests.swift
git commit -m "feat: Schneider Bézier fitting between corners"
```

---

### Task 11: Stage pictures, streaming, and `vectorize --stages`

**Files:**
- Create: `Sources/VectorEngine/Render/StageRenderer.swift`
- Modify: `Sources/VectorEngine/Pipeline/Pipeline.swift` (add `Pipeline.stream` inside `enum Pipeline`)
- Modify: `Sources/vectorize/VectorizeCommand.swift` (add the `--stages` option and PNG writing)
- Test: `Tests/VectorEngineTests/RenderTests.swift`

**Interfaces:**
- Consumes: `PipelineState`, `Stage`, `ShapeRenderer`, all stage outputs (Tasks 1–10).
- Produces:
  - `StageRenderer.image(for stage: Stage, in state: PipelineState, scale: Double = 1) -> CGImage?`. The image is processing size × scale, and the result is nil if that stage hasn't run.
  - `StageRenderer.falseColor(_ seg: Segmentation) -> Bitmap`
  - `Pipeline.stream(input:options:reusing:) -> AsyncThrowingStream<StageEvent, Error>`. Canceling the consuming task cancels the work. Plan 2's app uses this API.

- [ ] **Step 1: Write the failing tests**

`Tests/VectorEngineTests/RenderTests.swift`:
```swift
import Testing
@testable import VectorEngine

@Suite struct RenderTests {
    @Test func everyStageRendersAtTheRequestedScale() throws {
        let s = try Pipeline.run(input: InputImage(bitmap: TestImages.circle(size: 32, radius: 10)), options: Options())
        for stage in Stage.allCases {
            let img = try #require(StageRenderer.image(for: stage, in: s, scale: 2), "\(stage)")
            #expect(img.width == 64 && img.height == 64, "\(stage)")
        }
    }

    @Test func stagesThatHaveNotRunRenderNil() {
        let s = PipelineState(input: InputImage(bitmap: TestImages.circle()), options: Options())
        #expect(StageRenderer.image(for: .curves, in: s) == nil)
    }

    @Test func falseColorsDifferBetweenNeighbors() {
        let seg = Segmenter.segment(TestImages.quantized(["RWB"]), params: SegmentParams(speckSize: 0))
        let b = StageRenderer.falseColor(seg)
        #expect(b[0, 0] != b[1, 0] && b[1, 0] != b[2, 0])
    }

    @Test func svgStageLooksLikeTheResult() throws {
        let s = try Pipeline.run(input: InputImage(bitmap: TestImages.circle()), options: Options())
        let img = try #require(StageRenderer.image(for: .svg, in: s))
        #expect(Bitmap(cgImage: img)[24, 24] == TestImages.red)
    }

    @Test func streamYieldsAllStagesThenFinishes() async throws {
        var stages: [Stage] = []
        var last: StageEvent?
        for try await e in Pipeline.stream(input: InputImage(bitmap: TestImages.circle()), options: Options()) {
            stages.append(e.stage)
            last = e
        }
        #expect(stages == Stage.allCases)
        #expect(last?.state.result != nil)
    }

    @Test func abandoningTheStreamEarlyIsSafe() async throws {
        for try await e in Pipeline.stream(input: InputImage(bitmap: TestImages.photoLike()), options: Options()) {
            #expect(e.stage == .analyze)
            break
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter RenderTests`
Expected: build failure, with errors such as "cannot find 'StageRenderer' in scope".

- [ ] **Step 3: Implement the stage renderer**

`Sources/VectorEngine/Render/StageRenderer.swift`:
```swift
import CoreGraphics
import Foundation

/// Draws a picture of each pipeline stage, for the app's stage timeline and `vectorize --stages`.
public enum StageRenderer {
    static let ink = CGColor(srgbRed: 0.08, green: 0.08, blue: 0.12, alpha: 1)
    static let cornerColor = CGColor(srgbRed: 0.93, green: 0.30, blue: 0.15, alpha: 1)
    static let smoothColor = CGColor(srgbRed: 0.15, green: 0.45, blue: 0.95, alpha: 1)
    static let handleColor = CGColor(srgbRed: 0.45, green: 0.45, blue: 0.50, alpha: 0.8)

    /// A picture of `stage` at processing resolution × `scale`, or nil if the stage hasn't run.
    public static func image(for stage: Stage, in s: PipelineState, scale: Double = 1) -> CGImage? {
        let w = max(1, Int((Double(s.input.bitmap.width) * scale).rounded()))
        let h = max(1, Int((Double(s.input.bitmap.height) * scale).rounded()))
        switch stage {
        case .analyze:
            guard let a = s.analysis else { return nil }
            return draw(w, h) { ctx in
                drawUpright(s.input.bitmap.makeCGImage(), in: ctx, width: w, height: h)
                // Palette strip along the bottom; each swatch is as wide as its share.
                let stripH = max(4, Double(h) * 0.12)
                let total = max(a.shares.reduce(0, +), 1e-9)
                var x = 0.0
                for (c, share) in zip(a.palette, a.shares) {
                    let sw = Double(w) * share / total
                    ctx.setFillColor(ShapeRenderer.cgColor(c))
                    ctx.fill(CGRect(x: x, y: Double(h) - stripH, width: sw, height: stripH))
                    x += sw
                }
            }
        case .prefilter:
            return s.prefiltered.map { pixels($0, w, h) }
        case .quantize:
            return s.quantized.map { pixels($0.makeBitmap(), w, h) }
        case .segment:
            return s.segmentation.map { pixels(falseColor($0), w, h) }
        case .contours:
            guard let q = s.quantized, let t = s.topology else { return nil }
            return overlay(q, w, h, scale) { ctx, px in
                ctx.setStrokeColor(ink)
                ctx.setLineWidth(px)
                for c in t.chains { addPolyline(ctx, c.points.map(\.vec)) }
                ctx.strokePath()
            }
        case .polygon:
            guard let q = s.quantized, let polys = s.polygons else { return nil }
            return overlay(q, w, h, scale) { ctx, px in
                ctx.setStrokeColor(ink)
                ctx.setLineWidth(px)
                for p in polys { addPolyline(ctx, p.isClosed ? p.polygon + [p.polygon[0]] : p.polygon) }
                ctx.strokePath()
                for p in polys {
                    for (v, corner) in zip(p.polygon, p.corners) { dot(ctx, v, radius: 1.6 * px, color: corner ? cornerColor : smoothColor) }
                }
            }
        case .curves:
            guard let q = s.quantized, let curves = s.curves else { return nil }
            return overlay(q, w, h, scale) { ctx, px in
                ctx.setStrokeColor(handleColor)
                ctx.setLineWidth(px * 0.6)
                for c in curves {
                    var cur = c.start
                    for seg in c.segments {
                        if case .cubic(let c1, let c2, let to) = seg {
                            ctx.move(to: cg(cur)); ctx.addLine(to: cg(c1))
                            ctx.move(to: cg(to)); ctx.addLine(to: cg(c2))
                        }
                        cur = seg.end
                    }
                }
                ctx.strokePath()
                ctx.setStrokeColor(ink)
                ctx.setLineWidth(px)
                for c in curves { ctx.addPath(path(c)) }
                ctx.strokePath()
                for c in curves { for seg in c.segments { dot(ctx, seg.end, radius: 1.3 * px, color: ink) } }
            }
        case .svg:
            guard let r = s.result else { return nil }
            return draw(w, h) { ctx in
                ctx.scaleBy(x: Double(w) / Double(r.width), y: Double(h) / Double(r.height))
                ShapeRenderer.fill(r.shapes, in: ctx)
            }
        }
    }

    /// Each region in a distinct hue (golden-ratio steps), transparency kept.
    static func falseColor(_ seg: Segmentation) -> Bitmap {
        let palette = (0..<seg.regions.count).map { i -> RGBA in
            let hue = (Double(i) * 0.618_033_988_75).truncatingRemainder(dividingBy: 1)
            return hsv(hue, 0.55, 0.95)
        }
        return Bitmap(width: seg.width, height: seg.height, pixels: seg.labels.map { $0 < 0 ? .clear : palette[Int($0)] })
    }

    static func hsv(_ h: Double, _ s: Double, _ v: Double) -> RGBA {
        let i = Int(h * 6) % 6, f = h * 6 - Double(Int(h * 6))
        let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        let (r, g, b): (Double, Double, Double) = switch i {
        case 0: (v, t, p)
        case 1: (q, v, p)
        case 2: (p, v, t)
        case 3: (p, q, v)
        case 4: (t, p, v)
        default: (v, p, q)
        }
        return RGBA(UInt8(r * 255), UInt8(g * 255), UInt8(b * 255))
    }

    // MARK: Drawing helpers (all contexts are y-down)

    static func draw(_ w: Int, _ h: Int, _ body: (CGContext) -> Void) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: Bitmap.colorSpace,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        body(ctx)
        return ctx.makeImage()!
    }

    /// Draws an image the right way up inside a y-down context.
    static func drawUpright(_ image: CGImage, in ctx: CGContext, width: Int, height: Int) {
        ctx.saveGState()
        ctx.interpolationQuality = .none
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        ctx.restoreGState()
    }

    static func pixels(_ b: Bitmap, _ w: Int, _ h: Int) -> CGImage {
        draw(w, h) { drawUpright(b.makeCGImage(), in: $0, width: w, height: h) }
    }

    /// The quantized image, faded, with `body` drawn on top in lattice coordinates.
    /// `body` receives the size of one output pixel in lattice units.
    static func overlay(_ q: QuantizedImage, _ w: Int, _ h: Int, _ scale: Double, _ body: (CGContext, Double) -> Void) -> CGImage {
        draw(w, h) { ctx in
            drawUpright(q.makeBitmap().makeCGImage(), in: ctx, width: w, height: h)
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.6))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.scaleBy(x: Double(w) / Double(q.width), y: Double(h) / Double(q.height))
            ctx.setLineJoin(.round)
            body(ctx, Double(q.width) / Double(w))
        }
    }

    static func addPolyline(_ ctx: CGContext, _ pts: [Vec2]) {
        guard let first = pts.first else { return }
        ctx.move(to: cg(first))
        for p in pts.dropFirst() { ctx.addLine(to: cg(p)) }
    }

    static func path(_ c: Curve) -> CGPath {
        let p = CGMutablePath()
        p.move(to: cg(c.start))
        for seg in c.segments {
            switch seg {
            case .line(let to): p.addLine(to: cg(to))
            case .cubic(let c1, let c2, let to): p.addCurve(to: cg(to), control1: cg(c1), control2: cg(c2))
            }
        }
        return p
    }

    static func dot(_ ctx: CGContext, _ v: Vec2, radius: Double, color: CGColor) {
        ctx.setFillColor(color)
        ctx.fillEllipse(in: CGRect(x: v.x - radius, y: v.y - radius, width: radius * 2, height: radius * 2))
    }

    static func cg(_ v: Vec2) -> CGPoint { CGPoint(x: v.x, y: v.y) }
}
```

- [ ] **Step 4: Add streaming to the pipeline**

In `Sources/VectorEngine/Pipeline/Pipeline.swift`, add this method inside `public enum Pipeline`, directly after `run(...)`:
```swift
    /// Runs the pipeline off the caller's task, yielding each stage as it completes.
    /// Canceling the consuming task (or dropping the stream) cancels the run between stages.
    public static func stream(input: InputImage, options: Options, reusing previous: PipelineState? = nil)
        -> AsyncThrowingStream<StageEvent, Error>
    {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    _ = try run(input: input, options: options, reusing: previous) { event in
                        try Task.checkCancellation()
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter RenderTests`
Expected: all 6 tests pass.

- [ ] **Step 6: Add `--stages` to the CLI**

In `Sources/vectorize/VectorizeCommand.swift`:

1. Add `import ImageIO` and `import UniformTypeIdentifiers` after `import Foundation`.
2. Add this option after the `maxSize` option:
```swift
    @Option(help: "Write a PNG picture of every pipeline stage into this directory.") var stages: String?
```
3. Insert this block in `run()`, directly before the `if verbose, let a = state.analysis` line:
```swift
        if let stages {
            let dir = URL(fileURLWithPath: stages)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let longSide = Double(max(image.bitmap.width, image.bitmap.height))
            let scale = max(1, min(8, (1024 / longSide).rounded(.down)))
            for stage in Stage.allCases {
                guard let picture = StageRenderer.image(for: stage, in: state, scale: scale) else { continue }
                let name = String(format: "%02d", stage.rawValue) + "-" + stage.slug + ".png"
                try writePNG(picture, to: dir.appendingPathComponent(name))
            }
        }
```
4. Add this method to the struct, below `run()`:
```swift
    func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
    }
```

- [ ] **Step 7: Verify the CLI end to end**

Run:
```bash
swift build -c release
.build/release/vectorize samples/logo.png -o out/logo.svg --stages out/logo-stages
ls out/logo-stages
open out/logo-stages
```
Expected: `ls` lists `00-analyze.png 01-prefilter.png 02-quantize.png 03-segment.png 04-contours.png 05-polygon.png 06-curves.png 07-svg.png`. Opening them shows: the original with a palette strip, then posterized colors, false-color regions, staircase outlines, polygons with red corner and blue smooth dots, curves with gray handles, and the final render.

- [ ] **Step 8: Run the whole suite and commit**

Run: `swift test`
Expected: every suite passes.

```bash
git add Sources Tests
git commit -m "feat: stage pictures, streaming pipeline, vectorize --stages"
```

---

## Done criteria for Plan 1

- `swift test` is green. `vectorize` handles `samples/logo.png`, `samples/logo.jpg` and `samples/photo.png`, and `--stages` writes eight PNGs.
- Plan 2 (the SwiftUI app: canvas, compare slider, stage timeline with replay, inspector and Advanced disclosure, export, XcodeGen project) is written next, against `Pipeline.stream`, `StageRenderer`, `Options` and `VectorResult` exactly as built here.
