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
