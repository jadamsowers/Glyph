public struct PolygonParams: Sendable, Equatable {
    /// Maximum distance (px) the simplified polygon may stray from the boundary points.
    public var tolerance: Double
    /// Turns at least this sharp (degrees) can become corners.
    public var cornerAngle: Double
    /// Staircase runs at least this long on both sides of a turn keep the exact lattice corner.
    public var cornerRunLength: Int
    /// A polygon edge counts as straight if boundary points stay within this distance of it.
    public var straightTolerance: Double
    /// Processing pixels per nominal pixel for the builder's fixed lengths (> 1 when upscaled).
    public var unit: Double = 1
    /// Trace exactly along pixel edges (pixel art): no smoothing at all.
    public var exactPixels = false
    /// Bumps and notches on straight edges with at least this area (px) keep exact corners;
    /// smaller ones are smoothed like specks. 0 preserves all; nil disables detection.
    public var minFeatureArea: Int? = nil
    /// Per-chain tolerance grows as contrast falls below this ΔE (nil = uniform tolerance).
    public var contrastReference: Double? = nil
}

public struct CurveParams: Sendable, Equatable {
    /// Maximum distance (px) a fitted Bézier may stray from the boundary points.
    public var tolerance: Double
    public var straightTolerance: Double
    /// Processing pixels per nominal pixel for the fitter's fixed lengths (> 1 when upscaled).
    public var unit: Double = 1
    /// Emit the polygon as straight lines (pixel art).
    public var exactPixels = false
    /// Per-chain tolerance grows as contrast falls below this ΔE (nil = uniform tolerance).
    public var contrastReference: Double? = nil
    /// Perceptual reduction budget, 0…1 (0 = off). See `Simplifier`.
    public var simplify: Double = 0
    /// Display pixels per processing pixel, for simplification costs.
    public var displayScale: Double = 1
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
    /// Images smaller than this (long side) are upscaled for processing; 0 disables.
    public var minProcessingDimension = 256
    public var alphaThreshold: UInt8 = 128
    // Classification
    public var logoMaxColors = 32
    public var logoMaxGradientFraction = 0.35
    public var logoMaxEdgeFraction = 0.35
    public var logoMinCoverage = 0.88
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
    // Perceptual
    /// Loosen tolerances (and speck merging) on low-contrast boundaries.
    public var contrastWeighting = true
    /// ΔE at or above which a boundary counts as fully visible.
    public var contrastReference = 30.0

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
    /// Trace exactly along pixel edges; nil = automatic (on for detected pixel art).
    public var exactPixels: Bool?
    /// Perceptual reduction, 0…1: merge curve segments while the visible change stays small.
    public var simplify: Double?
    /// Long side (px) the result will be shown at; detail invisible at that size is dropped.
    /// nil = shown at original size.
    public var displaySize: Int?
    public var advanced: AdvancedOptions

    public init(kind: ImageKind? = nil, tracing: TracingMode? = nil, colorCount: Int? = nil, detail: Double? = nil,
                smoothness: Double? = nil, speckSize: Int? = nil, simplify: Double? = nil, displaySize: Int? = nil,
                advanced: AdvancedOptions = AdvancedOptions())
    {
        self.kind = kind; self.tracing = tracing; self.colorCount = colorCount; self.detail = detail
        self.smoothness = smoothness; self.speckSize = speckSize; self.simplify = simplify
        self.displaySize = displaySize; self.advanced = advanced
    }

    public func resolved(with analysis: Analysis) -> ResolvedOptions {
        let kind = self.kind ?? analysis.kind
        let isLogo = kind == .logo
        let a = advanced
        let detail = max(0, min(1, self.detail ?? (isLogo ? 0.6 : 0.3)))
        let smooth = max(0, min(1, smoothness ?? (isLogo ? 0.5 : 0.6)))
        let colors = max(2, min(256, colorCount ?? (isLogo ? max(2, min(32, analysis.significantColors)) : 16)))
        let exact = exactPixels ?? analysis.isPixelArt
        let speck = max(0, speckSize ?? (exact ? 0 : (isLogo ? 4 : 24)))

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

        let contrast = a.contrastWeighting ? a.contrastReference : nil
        var segment = SegmentParams(speckSize: speck)
        segment.contrastReference = exact ? nil : contrast
        return ResolvedOptions(
            kind: kind,
            prefilter: prefilter,
            quantize: quantize,
            segment: segment,
            polygon: PolygonParams(
                tolerance: a.polygonTolerance ?? (1.6 - 1.2 * detail),
                cornerAngle: a.cornerAngle ?? (30 + 60 * smooth),
                cornerRunLength: max(1, a.cornerRunLength),
                straightTolerance: a.straightTolerance,
                exactPixels: exact,
                minFeatureArea: speck,
                contrastReference: contrast),
            curve: CurveParams(tolerance: a.curveTolerance ?? (1.6 - 1.1 * detail), straightTolerance: a.straightTolerance,
                               exactPixels: exact, contrastReference: contrast, simplify: max(0, min(1, simplify ?? 0))),
            output: OutputParams(tracing: tracing ?? (isLogo || exact ? .sharedEdges : .stacked), precision: max(0, min(4, a.precision))))
    }
}

extension ResolvedOptions {
    /// Adapts pixel-sized parameters to an input upscaled by `factor`: distance tolerances and the
    /// builders' fixed lengths grow by factor / 2 (half an original pixel: finer than the source
    /// grid, which is what upscaling is for, without inflating the output), speck areas by factor².
    func adjusted(forUpscale factor: Int) -> ResolvedOptions {
        guard factor > 1 else { return self }
        var r = self
        let f = Double(factor) / 2
        r.polygon.tolerance *= f
        r.polygon.straightTolerance *= f
        r.curve.tolerance *= f
        r.curve.straightTolerance *= f
        r.polygon.unit = f
        r.curve.unit = f
        r.segment.speckSize *= factor * factor
        r.polygon.minFeatureArea = r.polygon.minFeatureArea.map { $0 * factor * factor }
        return r
    }
}

extension ResolvedOptions {
    /// Adapts to a result viewed with its long side at `displaySize` px (original long side
    /// `longSide`): at scale s < 1, detail below a display pixel is invisible, so distance
    /// tolerances and fixed lengths grow by 1/s, speck and feature areas by 1/s², and SVG
    /// coordinates lose their decimals once 1/s ≥ 10.
    func adjusted(forDisplay displaySize: Int?, longSide: Int) -> ResolvedOptions {
        guard let displaySize, displaySize > 0, displaySize < longSide else { return self }
        var r = self
        let k = Double(longSide) / Double(displaySize)
        r.polygon.tolerance *= k
        r.polygon.straightTolerance *= k
        r.polygon.unit *= k
        r.curve.tolerance *= k
        r.curve.straightTolerance *= k
        r.curve.unit *= k
        r.segment.speckSize = Int((Double(r.segment.speckSize) * k * k).rounded())
        r.polygon.minFeatureArea = r.polygon.minFeatureArea.map { Int((Double($0) * k * k).rounded()) }
        if k >= 10 { r.output.precision = 0 }
        return r
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
        logoMaxEdgeFraction = a.logoMaxEdgeFraction
        logoMinCoverage = a.logoMinCoverage
    }
}
