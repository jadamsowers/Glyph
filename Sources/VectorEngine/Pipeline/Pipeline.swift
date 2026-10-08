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
            resolved = Pipeline.resolve(options, p.analysis!, input)
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

    /// Runs the pipeline off the caller's task, yielding each stage as it completes.
    /// Cancelling the consuming task (or dropping the stream) cancels the run between stages.
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

    /// Raw value of the first stage that must be recomputed (`Stage.allCases.count` = none).
    static func firstStageToCompute(previous p: PipelineState, input: InputImage, options: Options) -> Int {
        guard p.input.id == input.id, let analysis = p.analysis, let oldResolved = p.resolved,
              ClassifierParams(p.options.advanced) == ClassifierParams(options.advanced)
        else { return 0 }
        let changed = resolve(options, analysis, input).firstChangedStage(comparedTo: oldResolved)?.rawValue ?? Stage.allCases.count
        let missing = Stage.allCases.first { !p.has($0) }?.rawValue ?? Stage.allCases.count
        return min(changed, missing)
    }

    /// Options resolved for this input: auto choices, then upscale and display-size adaptation.
    static func resolve(_ options: Options, _ analysis: Analysis, _ input: InputImage) -> ResolvedOptions {
        var r = options.resolved(with: analysis).adjusted(forUpscale: input.upscale)
            .adjusted(forDisplay: options.displaySize, longSide: max(input.originalWidth, input.originalHeight))
        r.prefilter.border = r.output.border * input.upscale
        let longOriginal = Double(max(input.originalWidth, input.originalHeight))
        let display = options.displaySize.map { min(Double($0), longOriginal) } ?? longOriginal
        r.curve.displayScale = display / Double(max(input.bitmap.width, input.bitmap.height))
        return r
    }

    /// Per-chain tolerance multipliers from the contrast across each chain (nil when disabled).
    static func multipliers(_ s: PipelineState, reference: Double?) -> [Double]? {
        guard let reference else { return nil }
        return Perceptual.chainColors(s.topology!, s.segmentation!.regions).map {
            Perceptual.toleranceMultiplier($0.0, $0.1, reference: reference)
        }
    }

    static func compute(_ stage: Stage, _ s: inout PipelineState) {
        switch stage {
        case .analyze:
            var a = Analyzer.analyze(s.input.bitmap, params: ClassifierParams(s.options.advanced))
            // Only the original pixels can show pixel art; an upscaled input was already judged not to be.
            if s.input.upscale > 1 { a.isPixelArt = false }
            s.analysis = a
            s.resolved = resolve(s.options, a, s.input)
        case .prefilter:
            s.prefiltered = Prefilter.apply(s.input.bitmap, params: s.resolved!.prefilter)
        case .quantize:
            s.quantized = Quantizer.quantize(s.prefiltered!, params: s.resolved!.quantize)
        case .segment:
            s.segmentation = Segmenter.segment(s.quantized!, params: s.resolved!.segment)
        case .contours:
            s.topology = Topology.build(s.segmentation!)
        case .polygon:
            let p = s.resolved!.polygon
            s.polygons = PolygonBuilder.build(s.topology!, params: p,
                                              multipliers: multipliers(s, reference: p.contrastReference))
        case .curves:
            let p = s.resolved!.curve
            let curves = CurveFitter.fit(s.polygons!, params: p, chains: s.topology!.chains,
                                         regionSizes: s.segmentation!.regions.map(\.pixelCount),
                                         multipliers: multipliers(s, reference: p.contrastReference))
            let colors = Perceptual.chainColors(s.topology!, s.segmentation!.regions)
            let visibility = colors.map { Perceptual.visibility($0.0, $0.1, reference: p.contrastReference ?? 30) }
            s.curves = Simplifier.reduce(curves, visibility: visibility, params: p,
                                         bounds: (s.input.bitmap.width, s.input.bitmap.height))
        case .svg:
            let r = s.resolved!, input = s.input
            var shapes = ShapeAssembler.shapes(topology: s.topology!, regions: s.segmentation!.regions, curves: s.curves!, tracing: r.output.tracing)
                .map { $0.scaled(input.scaleX, input.scaleY) }
            let outW = input.originalWidth + 2 * r.output.border, outH = input.originalHeight + 2 * r.output.border
            if let bg = r.output.background {
                let w = Double(outW), h = Double(outH)
                shapes.insert(VectorShape(color: bg, subpaths: [Subpath(start: .zero, segments: [
                    .line(to: Vec2(w, 0)), .line(to: Vec2(w, h)), .line(to: Vec2(0, h)), .line(to: .zero)])]), at: 0)
            }
            // Stacked output gets an underlay stroke to hide sibling seams: at least one processing
            // pixel, and at least one display pixel when shown smaller (output units throughout).
            let longSide = Double(max(input.originalWidth, input.originalHeight))
            let displayPixel = s.options.displaySize.map { longSide / Double(max(1, min(Int(longSide), $0))) } ?? 1
            let seam = r.output.tracing == .stacked ? max(input.scaleX, input.scaleY, displayPixel) : 0
            var result = VectorResult(shapes: shapes, width: outW, height: outH, precision: r.output.precision, seamStroke: seam)
            result.stats.visibleDifference = Perceptual.visibleDifference(
                shapes, outputWidth: outW, outputHeight: outH, reference: s.prefiltered!,
                compareSize: s.options.displaySize ?? 512)
            s.result = result
        }
    }
}

public enum Vectorizer {
    public static func vectorize(_ input: InputImage, options: Options = Options()) throws -> VectorResult {
        try Pipeline.run(input: input, options: options).result!
    }

    public static func vectorize(contentsOf url: URL, options: Options = Options()) throws -> VectorResult {
        try vectorize(InputImage.load(contentsOf: url, maxDimension: options.advanced.maxProcessingDimension,
                                      minDimension: options.advanced.minProcessingDimension), options: options)
    }
}
