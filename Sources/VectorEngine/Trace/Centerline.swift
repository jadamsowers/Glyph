import Foundation

/// Centerline tracing for line art: single stroked paths down the middle of ink strokes, instead
/// of filled outlines with two edges each. The ink is thinned to a one-pixel skeleton
/// (Zhang–Suen), the skeleton is split into paths at junctions and ends, short spurs are pruned,
/// and each path is smoothed and fitted with Béziers. Stroke width comes from a distance
/// transform: twice the median distance from skeleton pixels to the nearest paper.
enum Centerline {
    struct Params {
        /// Curve fit tolerance (processing px).
        var tolerance: Double
    }

    static func trace(_ q: QuantizedImage, ink: RGBA, params p: Params) -> [VectorShape] {
        let w = q.width, h = q.height
        let mask = q.indices.map { $0 >= 0 }
        let dist = distanceToPaper(mask, w, h)
        var skeleton = removeCorners(thin(mask, w, h), w, h)
        var paths = split(&skeleton, w, h)
        paths = pruneSpurs(paths, dist: dist, w: w)
        // One stroked shape per width (rounded to half a pixel) keeps the SVG to a few <path>s.
        var byWidth: [Double: [Subpath]] = [:]
        for path in paths where path.points.count >= 2 {
            let ds = path.points.map { dist[$0.y * w + $0.x] }.sorted()
            // The skeleton sits up to half a pixel off-center on even widths: 2d + ½ splits the
            // difference between odd (2d) and even (2d + 1) stroke widths.
            let width = max(1, ((2 * ds[ds.count / 2] + 0.5) * 2).rounded() / 2)
            byWidth[width, default: []].append(fit(path, tolerance: p.tolerance))
        }
        return byWidth.keys.sorted().map { VectorShape(color: ink, subpaths: byWidth[$0]!, stroke: $0) }
    }

    // MARK: Distance transform

    /// Two-pass chamfer (3-4) distance from each ink pixel to the nearest paper pixel or the
    /// image edge, in pixels (≈ Euclidean). A stroke n px wide peaks near n/2 at its middle.
    static func distanceToPaper(_ mask: [Bool], _ w: Int, _ h: Int) -> [Double] {
        let big = Int.max / 4
        var d = mask.map { $0 ? big : 0 }
        func at(_ x: Int, _ y: Int) -> Int { x < 0 || y < 0 || x >= w || y >= h ? 0 : d[y * w + x] }
        for y in 0..<h {
            for x in 0..<w where mask[y * w + x] {
                d[y * w + x] = min(d[y * w + x], at(x - 1, y) + 3, at(x, y - 1) + 3, at(x - 1, y - 1) + 4, at(x + 1, y - 1) + 4)
            }
        }
        for y in stride(from: h - 1, through: 0, by: -1) {
            for x in stride(from: w - 1, through: 0, by: -1) where mask[y * w + x] {
                d[y * w + x] = min(d[y * w + x], at(x + 1, y) + 3, at(x, y + 1) + 3, at(x + 1, y + 1) + 4, at(x - 1, y + 1) + 4)
            }
        }
        // A pixel adjacent to paper has chamfer 3 = 1 px; distances are measured from pixel
        // centers to the paper boundary, so subtract half a pixel.
        return d.map { $0 == 0 ? 0 : Double($0) / 3 - 0.5 }
    }

    // MARK: Thinning

    /// Zhang–Suen thinning to an 8-connected, one-pixel-wide skeleton.
    static func thin(_ mask: [Bool], _ w: Int, _ h: Int) -> [Bool] {
        var m = mask
        func px(_ x: Int, _ y: Int) -> Int { x < 0 || y < 0 || x >= w || y >= h ? 0 : (m[y * w + x] ? 1 : 0) }
        var changed = true
        while changed {
            changed = false
            for pass in 0..<2 {
                var remove: [Int] = []
                for y in 0..<h {
                    for x in 0..<w where m[y * w + x] {
                        // Neighbours P2…P9 clockwise from north.
                        let n = [px(x, y - 1), px(x + 1, y - 1), px(x + 1, y), px(x + 1, y + 1),
                                 px(x, y + 1), px(x - 1, y + 1), px(x - 1, y), px(x - 1, y - 1)]
                        let b = n.reduce(0, +)
                        guard b >= 2 && b <= 6 else { continue }
                        var a = 0
                        for i in 0..<8 where n[i] == 0 && n[(i + 1) % 8] == 1 { a += 1 }
                        guard a == 1 else { continue }
                        let ok = pass == 0
                            ? n[0] * n[2] * n[4] == 0 && n[2] * n[4] * n[6] == 0
                            : n[0] * n[2] * n[6] == 0 && n[0] * n[4] * n[6] == 0
                        if ok { remove.append(y * w + x) }
                    }
                }
                for i in remove { m[i] = false }
                if !remove.isEmpty { changed = true }
            }
        }
        return m
    }

    /// Removes skeleton pixels whose neighbours stay 8-connected without them (staircase corners),
    /// so every interior skeleton pixel has exactly two neighbours and junctions are real.
    static func removeCorners(_ sk: [Bool], _ w: Int, _ h: Int) -> [Bool] {
        var m = sk
        func px(_ x: Int, _ y: Int) -> Bool { x >= 0 && y >= 0 && x < w && y < h && m[y * w + x] }
        var changed = true
        while changed {
            changed = false
            for y in 0..<h {
                for x in 0..<w where m[y * w + x] {
                    let set = offsets.filter { px(x + $0.0, y + $0.1) }
                    guard set.count >= 2 && set.count <= 3 else { continue }
                    // Redundant if the neighbours are one 8-connected group without this pixel
                    // (e.g. W and N touch diagonally): removing it can't break the skeleton.
                    var group = [set[0]], rest = Array(set.dropFirst())
                    var grew = true
                    while grew {
                        grew = false
                        for (k, r) in rest.enumerated().reversed() where group.contains(where: { abs($0.0 - r.0) <= 1 && abs($0.1 - r.1) <= 1 }) {
                            group.append(r); rest.remove(at: k); grew = true
                        }
                    }
                    if rest.isEmpty {
                        m[y * w + x] = false
                        changed = true
                    }
                }
            }
        }
        return m
    }

    // MARK: Skeleton graph

    struct Point: Hashable { var x: Int; var y: Int }
    struct Path {
        var points: [Point]
        var isClosed: Bool
        /// Ends at an endpoint (degree 1) at the start / end — candidates for spur pruning.
        var freeStart: Bool
        var freeEnd: Bool
        /// Where a path meets a junction, the junction cluster's center, so all arms meet there.
        var startAnchor: Vec2? = nil
        var endAnchor: Vec2? = nil
    }

    static let offsets = [(0, -1), (1, -1), (1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1)]

    /// Splits the skeleton into paths between nodes (pixels with ≠ 2 neighbours) plus closed loops.
    static func split(_ sk: inout [Bool], _ w: Int, _ h: Int) -> [Path] {
        func on(_ p: Point) -> Bool { p.x >= 0 && p.y >= 0 && p.x < w && p.y < h && sk[p.y * w + p.x] }
        func neighbours(_ p: Point) -> [Point] { offsets.map { Point(x: p.x + $0.0, y: p.y + $0.1) }.filter(on) }
        func degree(_ p: Point) -> Int { neighbours(p).count }
        var usedEdges = Set<[Int]>()
        func edgeKey(_ a: Point, _ b: Point) -> [Int] { let i = a.y * w + a.x, j = b.y * w + b.x; return [min(i, j), max(i, j)] }
        var paths: [Path] = []
        func walk(from start: Point, via first: Point) -> Path {
            var pts = [start, first]
            usedEdges.insert(edgeKey(start, first))
            var prev = start, cur = first
            while degree(cur) == 2 {
                guard let next = neighbours(cur).first(where: { $0 != prev && !usedEdges.contains(edgeKey(cur, $0)) }) else { break }
                usedEdges.insert(edgeKey(cur, next))
                pts.append(next)
                prev = cur; cur = next
                if cur == start { break }
            }
            let closed = pts.count > 3 && pts.first == pts.last
            return Path(points: pts, isClosed: closed, freeStart: degree(start) == 1, freeEnd: !closed && degree(cur) == 1)
        }
        var nodes: [Point] = []
        for y in 0..<h { for x in 0..<w where sk[y * w + x] { let p = Point(x: x, y: y); if degree(p) != 2 { nodes.append(p) } } }
        for node in nodes {
            for n in neighbours(node) where !usedEdges.contains(edgeKey(node, n)) { paths.append(walk(from: node, via: n)) }
            if degree(node) == 0 { paths.append(Path(points: [node], isClosed: false, freeStart: true, freeEnd: true)) }
        }
        // Loops with no node.
        for y in 0..<h {
            for x in 0..<w where sk[y * w + x] {
                let p = Point(x: x, y: y)
                for n in neighbours(p) where !usedEdges.contains(edgeKey(p, n)) { paths.append(walk(from: p, via: n)) }
            }
        }
        // Adjacent junction pixels form one junction: group them, drop the tiny paths inside a
        // group, and anchor the arms at the group's center.
        let junctions = Set(nodes.filter { degree($0) >= 3 })
        var cluster: [Point: Int] = [:], centers: [Vec2] = []
        for j in junctions where cluster[j] == nil {
            var stack = [j], members: [Point] = []
            cluster[j] = centers.count
            while let p = stack.popLast() {
                members.append(p)
                for n in neighbours(p) where junctions.contains(n) && cluster[n] == nil { cluster[n] = centers.count; stack.append(n) }
            }
            let sum = members.reduce(Vec2.zero) { $0 + Vec2(Double($1.x) + 0.5, Double($1.y) + 0.5) }
            centers.append(sum * (1 / Double(members.count)))
        }
        return paths.compactMap { path in
            var p = path
            let a = cluster[p.points.first!], b = cluster[p.points.last!]
            if let a, let b, a == b, p.points.count <= 4 { return nil }
            if let a { p.startAnchor = centers[a] }
            if let b, !p.isClosed { p.endAnchor = centers[b] }
            return p
        }
    }

    /// Drops dangling branches shorter than ~1.5× the local stroke width: thinning sprouts these
    /// at corners and stroke ends. Isolated paths (free at both ends) are kept.
    static func pruneSpurs(_ paths: [Path], dist: [Double], w: Int) -> [Path] {
        paths.filter { p in
            guard p.freeStart != p.freeEnd else { return true }
            let attached = p.freeStart ? p.points.last! : p.points.first!
            let localWidth = 2 * dist[attached.y * w + attached.x]
            return Double(p.points.count) > 1.5 * localWidth + 1
        }
    }

    // MARK: Fitting

    /// Smooths pixel-center points (3-point moving average, ends fixed) and fits cubics.
    static func fit(_ path: Path, tolerance: Double) -> Subpath {
        var pts = path.points.map { Vec2(Double($0.x) + 0.5, Double($0.y) + 0.5) }
        if path.isClosed { pts.removeLast() }
        if pts.count >= 3 {
            let n = pts.count
            pts = (0..<n).map { i in
                if !path.isClosed && (i == 0 || i == n - 1) { return pts[i] }
                return (pts[(i + n - 1) % n] + pts[i] + pts[(i + 1) % n]) * (1.0 / 3)
            }
        }
        if path.isClosed { pts.append(pts[0]) }
        if let a = path.startAnchor { pts[0] = a }
        if let b = path.endAnchor { pts[pts.count - 1] = b }
        guard pts.count >= 3 else {
            return Subpath(start: pts[0], segments: pts.dropFirst().map { .line(to: $0) }, isClosed: false)
        }
        let k = min(3, pts.count - 1)
        var t1 = (pts[k] - pts[0]).normalized, t2 = (pts[pts.count - 1 - k] - pts[pts.count - 1]).normalized
        if path.isClosed {
            // Continuous tangent through the closing point.
            let t = (pts[1] - pts[pts.count - 2]).normalized
            t1 = t; t2 = -t
        }
        let segs = BezierFit.fit(pts, leftTangent: t1, rightTangent: t2, tolerance: tolerance)
        return Subpath(start: pts[0], segments: segs, isClosed: path.isClosed)
    }
}
