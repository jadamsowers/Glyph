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
    public var logoMaxEdgeFraction = 0.35
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
        logoMaxEdgeFraction = a.logoMaxEdgeFraction
    }
}
