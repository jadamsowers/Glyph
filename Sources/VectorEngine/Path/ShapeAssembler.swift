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
            // Stacked mode relies on later shapes covering holes — but nothing paints a transparent
            // hole, so holes that border transparency stay cut out.
            let chosen = tracing == .stacked
                ? loops.enumerated().filter { k, loop in
                    k == t.regions[r].outerIndex
                        || loop.contains { t.chains[$0.chain].left < 0 || t.chains[$0.chain].right < 0 }
                }.map(\.element)
                : loops
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
