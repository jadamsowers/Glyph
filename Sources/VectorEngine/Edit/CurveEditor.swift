import CoreGraphics

extension PipelineState {
    /// Whether the output is built from `curves` (filled tracing), so hand edits to them show.
    /// Halftone and centerline output ignore the curves.
    public var isCurveEditable: Bool {
        guard let r = resolved, curves != nil, topology != nil, result != nil else { return false }
        return r.output.halftone == nil && !(r.output.centerline && r.quantize.monochrome != nil)
    }

    /// This state with hand-edited curves and no result: running the pipeline on it (same input
    /// and options) redoes only the SVG stage, and later option changes that only affect output
    /// keep the edits.
    public func replacingCurves(_ curves: [Curve]) -> PipelineState {
        var s = self
        s.curves = curves
        s.result = nil
        return s
    }

    /// Maps curve (processing pixel) coordinates to the output's: the SVG stage's scaling, then
    /// its flips and rotation.
    public var outputTransform: CGAffineTransform? {
        guard let r = resolved?.output else { return nil }
        let W = Double(input.originalWidth + 2 * r.border), H = Double(input.originalHeight + 2 * r.border)
        var t = CGAffineTransform(scaleX: input.scaleX, y: input.scaleY)
        if r.flipHorizontal { t = t.concatenating(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: W, ty: 0)) }
        if r.flipVertical { t = t.concatenating(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: H)) }
        switch r.rotation {
        case 90: t = t.concatenating(CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: H, ty: 0))     // (H − y, x)
        case 180: t = t.concatenating(CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: W, ty: H))   // (W − x, H − y)
        case 270: t = t.concatenating(CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: W))    // (y, W − x)
        default: break
        }
        return t
    }

    /// The output shapes `curves` would give, without the SVG stage's fidelity measurement or SVG
    /// text — cheap enough to redraw on every drag event. Nil unless `isCurveEditable`.
    public func previewShapes(_ curves: [Curve]) -> [VectorShape]? {
        guard isCurveEditable, let r = resolved else { return nil }
        let (shapes, w, h) = Pipeline.outputShapes(self, curves: curves)
        return Pipeline.orient(shapes, width: w, height: h, r.output).0
    }
}

extension Pipeline {
    /// The first stage a run with `options` would recompute after `previous` (nil = none).
    public static func stageToRecompute(after previous: PipelineState, input: InputImage, options: Options) -> Stage? {
        Stage(rawValue: firstStageToCompute(previous: previous, input: input, options: options))
    }
}

/// Hand editing of fitted curves: anchors and Bézier handles. Every chain is one boundary shared
/// by the regions on both sides, so an edit moves both colors' outlines together. Chain ends are
/// junctions shared with other chains; moving one moves every chain end there.
public struct CurveEditor: Sendable {
    public private(set) var curves: [Curve]

    public init(curves: [Curve]) { self.curves = curves }

    public enum Target: Hashable, Sendable {
        /// Anchor `index` of a chain: 0 is its start, k the end of segment k − 1.
        case anchor(chain: Int, index: Int)
        /// A cubic segment's first (`second == false`) or second control point.
        case handle(chain: Int, segment: Int, second: Bool)
    }

    /// What one drag moves, captured when it starts; `update` re-applies from these originals so
    /// repeated updates don't accumulate.
    public struct Drag: Sendable {
        let original: [Curve]
        let target: Target
        /// For an anchor: every anchor at that point (junction ends, both ends of a closed chain).
        let anchors: [Occurrence]
        /// For a handle: its anchor, and the handles on the far side of it that stay collinear.
        let pivot: Vec2
        let companions: [Target]
    }

    struct Occurrence: Hashable, Sendable { var chain: Int; var index: Int }

    // MARK: Reading

    /// The chain's anchors; a closed chain's closing point is its start and listed once.
    public func anchors(of chain: Int) -> [Vec2] {
        let c = curves[chain]
        let all = [c.start] + c.segments.map(\.end)
        return isClosed(chain) && all.count > 1 ? Array(all.dropLast()) : all
    }

    /// The chain's handles with the anchors they belong to.
    public func handles(of chain: Int) -> [(target: Target, anchor: Vec2, handle: Vec2)] {
        let c = curves[chain]
        var out: [(Target, Vec2, Vec2)] = []
        var from = c.start
        for (k, seg) in c.segments.enumerated() {
            if case .cubic(let c1, let c2, let to) = seg {
                out.append((.handle(chain: chain, segment: k, second: false), from, c1))
                out.append((.handle(chain: chain, segment: k, second: true), to, c2))
            }
            from = seg.end
        }
        return out
    }

    public func position(_ t: Target) -> Vec2 {
        switch t {
        case .anchor(let chain, let index): anchor(Occurrence(chain: chain, index: index))
        case .handle(let chain, let segment, let second):
            if case .cubic(let c1, let c2, _) = curves[chain].segments[segment] { second ? c2 : c1 } else { curves[chain].segments[segment].end }
        }
    }

    func isClosed(_ chain: Int) -> Bool { curves[chain].segments.count > 0 && curves[chain].start == curves[chain].end }

    func anchor(_ o: Occurrence) -> Vec2 { o.index == 0 ? curves[o.chain].start : curves[o.chain].segments[o.index - 1].end }

    // MARK: Hit testing (in view space: `transform` maps curve coordinates to it)

    /// The chain passing nearest `p`, if within `tolerance`.
    public func chain(near p: CGPoint, tolerance: Double, transform: CGAffineTransform) -> Int? {
        var best: (Int, Double)?
        let q = Vec2(p.x, p.y)
        for (i, c) in curves.enumerated() {
            var prev = view(c.start, transform)
            var from = c.start
            for seg in c.segments {
                for s in Self.samples(from, seg) {
                    let v = view(s, transform)
                    let d = q.distance(toSegment: prev, v)
                    if d <= tolerance, best == nil || d < best!.1 { best = (i, d) }
                    prev = v
                }
                from = seg.end
            }
        }
        return best?.0
    }

    /// The anchor or handle of `chain` nearest `p`, if within `tolerance`; handles win ties, since
    /// a handle resting on its anchor could not be grabbed otherwise.
    public func target(near p: CGPoint, in chain: Int, tolerance: Double, transform: CGAffineTransform) -> Target? {
        let q = Vec2(p.x, p.y)
        var best: (Target, Double)?
        func consider(_ t: Target, _ at: Vec2, bias: Double) {
            let d = q.distance(to: view(at, transform)) - bias
            if d <= tolerance, best == nil || d < best!.1 { best = (t, d) }
        }
        for h in handles(of: chain) { consider(h.target, h.handle, bias: 0.01) }
        for (i, a) in anchors(of: chain).enumerated() { consider(.anchor(chain: chain, index: i), a, bias: 0) }
        return best?.0
    }

    private func view(_ v: Vec2, _ t: CGAffineTransform) -> Vec2 {
        let p = CGPoint(x: v.x, y: v.y).applying(t)
        return Vec2(p.x, p.y)
    }

    static func samples(_ from: Vec2, _ seg: PathSegment) -> [Vec2] {
        switch seg {
        case .line(let p): return [p]
        case .cubic(let c1, let c2, let p): return (1...12).map { BezierFit.point([from, c1, c2, p], Double($0) / 12) }
        }
    }

    // MARK: Editing

    /// Starts dragging `target`. A handle on a smooth anchor (the handles on either side within
    /// ~10° of opposite) keeps the far handle collinear unless `breakSmooth` (⌥).
    public func beginDrag(_ target: Target, breakSmooth: Bool = false) -> Drag {
        switch target {
        case .anchor(let chain, let index):
            return Drag(original: curves, target: target, anchors: occurrences(of: Occurrence(chain: chain, index: index)),
                        pivot: .zero, companions: [])
        case .handle(let chain, let segment, let second):
            let own = Occurrence(chain: chain, index: second ? segment + 1 : segment)
            let pivot = anchor(own)
            let direction = (position(target) - pivot).normalized
            var companions: [Target] = []
            if !breakSmooth && direction != .zero {
                for o in occurrences(of: own) {
                    for h in handles(at: o) where h != target {
                        let d = (position(h) - pivot).normalized
                        if d != .zero && d.dot(direction) <= -cos(10 * Double.pi / 180) { companions.append(h) }
                    }
                }
            }
            return Drag(original: curves, target: target, anchors: [], pivot: pivot, companions: companions)
        }
    }

    /// Moves the drag's target to its starting position plus `delta` (curve coordinates).
    public mutating func update(_ drag: Drag, by delta: Vec2) {
        curves = drag.original
        switch drag.target {
        case .anchor:
            for o in drag.anchors { moveAnchor(o, by: delta) }
        case .handle:
            let moved = position(drag.target) + delta
            setHandle(drag.target, moved)
            let direction = (moved - drag.pivot).normalized
            guard direction != .zero else { return }
            for h in drag.companions {
                let length = position(h).distance(to: drag.pivot)
                setHandle(h, drag.pivot - direction * length)
            }
        }
    }

    /// Every anchor at the same point as `o`: for a chain end, the ends of all chains meeting
    /// there (including the other end of a closed chain); otherwise just `o`.
    func occurrences(of o: Occurrence) -> [Occurrence] {
        let n = curves[o.chain].segments.count
        guard o.index == 0 || o.index == n else { return [o] }
        let p = anchor(o)
        var out: [Occurrence] = []
        for (i, c) in curves.enumerated() where !c.segments.isEmpty {
            if c.start == p { out.append(Occurrence(chain: i, index: 0)) }
            if c.end == p { out.append(Occurrence(chain: i, index: c.segments.count)) }
        }
        return out
    }

    /// The handles attached to an anchor: the incoming segment's second and the outgoing one's first.
    func handles(at o: Occurrence) -> [Target] {
        let segs = curves[o.chain].segments
        var out: [Target] = []
        if o.index > 0, case .cubic = segs[o.index - 1] { out.append(.handle(chain: o.chain, segment: o.index - 1, second: true)) }
        if o.index < segs.count, case .cubic = segs[o.index] { out.append(.handle(chain: o.chain, segment: o.index, second: false)) }
        return out
    }

    mutating func moveAnchor(_ o: Occurrence, by d: Vec2) {
        for h in handles(at: o) { setHandle(h, position(h) + d) }
        if o.index == 0 {
            curves[o.chain].start = curves[o.chain].start + d
        } else {
            let k = o.index - 1
            switch curves[o.chain].segments[k] {
            case .line(let p): curves[o.chain].segments[k] = .line(to: p + d)
            case .cubic(let c1, let c2, let p): curves[o.chain].segments[k] = .cubic(c1: c1, c2: c2, to: p + d)
            }
        }
    }

    mutating func setHandle(_ t: Target, _ v: Vec2) {
        guard case .handle(let chain, let segment, let second) = t,
              case .cubic(let c1, let c2, let p) = curves[chain].segments[segment] else { return }
        curves[chain].segments[segment] = second ? .cubic(c1: c1, c2: v, to: p) : .cubic(c1: v, c2: c2, to: p)
    }
}
