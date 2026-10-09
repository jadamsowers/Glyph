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
/// An outline; closed subpaths' last segment ends at `start`.
public struct Subpath: Sendable, Equatable {
    public var start: Vec2
    public var segments: [PathSegment]
    /// Open subpaths (centerline strokes) are not closed back to `start`.
    public var isClosed: Bool = true

    public init(start: Vec2, segments: [PathSegment], isClosed: Bool = true) {
        self.start = start; self.segments = segments; self.isClosed = isClosed
    }
}

public struct VectorShape: Sendable, Equatable {
    public var color: RGBA
    public var subpaths: [Subpath]
    /// When set, the shape is stroked with this width (round caps and joins) instead of filled.
    public var stroke: Double? = nil

    public init(color: RGBA, subpaths: [Subpath], stroke: Double? = nil) {
        self.color = color; self.subpaths = subpaths; self.stroke = stroke
    }

    /// Applies `f` to every point (an affine map, so control points transform exactly).
    func mapped(_ f: (Vec2) -> Vec2) -> VectorShape {
        VectorShape(color: color, subpaths: subpaths.map { sp in
            Subpath(start: f(sp.start), segments: sp.segments.map { seg in
                switch seg {
                case .line(let p): .line(to: f(p))
                case .cubic(let c1, let c2, let p): .cubic(c1: f(c1), c2: f(c2), to: f(p))
                }
            }, isClosed: sp.isClosed)
        }, stroke: stroke)
    }

    func scaled(_ sx: Double, _ sy: Double) -> VectorShape {
        VectorShape(color: color, subpaths: subpaths.map {
            Subpath(start: $0.start.scaled(sx, sy), segments: $0.segments.map { $0.scaled(sx, sy) }, isClosed: $0.isClosed)
        }, stroke: stroke.map { $0 * (sx + sy) / 2 })
    }
}
