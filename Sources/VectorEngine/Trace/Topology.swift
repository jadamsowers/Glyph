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
