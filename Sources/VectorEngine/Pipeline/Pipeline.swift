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
