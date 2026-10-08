import Foundation

public struct VectorStats: Sendable, Equatable {
    public var pathCount: Int
    public var segmentCount: Int
    public var byteCount: Int
}

public struct VectorResult: Sendable, Equatable {
    /// Output size in original image pixels.
    public var width: Int
    public var height: Int
    /// Shapes in output coordinates, in paint order.
    public var shapes: [VectorShape]
    public var svg: String
    public var stats: VectorStats
    /// Width of the same-color underlay stroke beneath all fills (0 = none); see `ShapeRenderer.fill`.
    public var seamStroke: Double

    public init(shapes: [VectorShape], width: Int, height: Int, precision: Int, seamStroke: Double = 0) {
        self.width = width
        self.height = height
        self.shapes = shapes
        self.seamStroke = seamStroke
        svg = SVGWriter.document(shapes, width: width, height: height, precision: precision, seamStroke: seamStroke)
        let segments = shapes.reduce(0) { $0 + $1.subpaths.reduce(0) { $0 + $1.segments.count } }
        stats = VectorStats(pathCount: shapes.count, segmentCount: segments, byteCount: svg.utf8.count)
    }
}

enum SVGWriter {
    static func document(_ shapes: [VectorShape], width: Int, height: Int, precision: Int, seamStroke: Double = 0) -> String {
        var out = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 \(width) \(height)\" width=\"\(width)\" height=\"\(height)\" fill-rule=\"evenodd\""
        guard seamStroke > 0, !shapes.isEmpty else {
            out += ">\n"
            for s in shapes {
                out += "<path fill=\"\(s.color.hex)\" d=\"\(pathData(s.subpaths, precision: precision))\"/>\n"
            }
            return out + "</svg>\n"
        }
        // Each outline is defined once, stroked beneath everything, then filled in paint order.
        out += " xmlns:xlink=\"http://www.w3.org/1999/xlink\">\n<defs>\n"
        for (i, s) in shapes.enumerated() {
            out += "<path id=\"p\(i)\" d=\"\(pathData(s.subpaths, precision: precision))\"/>\n"
        }
        let w = format(Int((seamStroke * 100).rounded()), precision: 2)
        out += "</defs>\n<g fill=\"none\" stroke-width=\"\(w)\" stroke-linejoin=\"round\">\n"
        for (i, s) in shapes.enumerated() { out += "<use xlink:href=\"#p\(i)\" stroke=\"\(s.color.hex)\"/>\n" }
        out += "</g>\n"
        for (i, s) in shapes.enumerated() { out += "<use xlink:href=\"#p\(i)\" fill=\"\(s.color.hex)\"/>\n" }
        return out + "</svg>\n"
    }

    /// Compact path data: absolute moveto, then relative l/c commands. Coordinates are rounded to
    /// integers in units of 10^-precision first and deltas are taken between rounded values,
    /// so relative steps never drift.
    static func pathData(_ subpaths: [Subpath], precision: Int) -> String {
        let f = pow(10, Double(precision))
        func q(_ v: Double) -> Int { Int((v * f).rounded()) }
        var d = ""
        var command: Character = " "
        func emit(_ c: Character) {
            if c != command || c == "M" || c == "z" { d.append(c); command = c }
        }
        func num(_ i: Int) {
            let s = format(i, precision: precision)
            if let last = d.last, !last.isLetter, !s.hasPrefix("-") { d.append(" ") }
            d += s
        }
        for sp in subpaths {
            var cx = q(sp.start.x), cy = q(sp.start.y)
            let sx = cx, sy = cy
            emit("M"); num(cx); num(cy)
            for (i, seg) in sp.segments.enumerated() {
                switch seg {
                case .line(let to):
                    let tx = q(to.x), ty = q(to.y)
                    if tx == cx && ty == cy { continue }
                    if i == sp.segments.count - 1 && tx == sx && ty == sy { continue }   // z closes it
                    emit("l"); num(tx - cx); num(ty - cy)
                    cx = tx; cy = ty
                case .cubic(let c1, let c2, let to):
                    let tx = q(to.x), ty = q(to.y)
                    emit("c")
                    num(q(c1.x) - cx); num(q(c1.y) - cy); num(q(c2.x) - cx); num(q(c2.y) - cy); num(tx - cx); num(ty - cy)
                    cx = tx; cy = ty
                }
            }
            emit("z")
        }
        return d
    }

    /// Formats an integer measured in units of 10^-precision: 5 → ".5", -1234 (p=2) → "-12.34".
    static func format(_ i: Int, precision p: Int) -> String {
        if p == 0 { return String(i) }
        let f = Int(pow(10, Double(p)))
        let a = abs(i), whole = a / f, frac = a % f
        var s = String(whole)
        if frac != 0 {
            var fs = String(frac)
            fs = String(repeating: "0", count: p - fs.count) + fs
            while fs.hasSuffix("0") { fs.removeLast() }
            s = (whole == 0 ? "" : s) + "." + fs
        }
        return i < 0 ? "-" + s : s
    }
}
