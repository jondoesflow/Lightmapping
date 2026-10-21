import Foundation
import simd

/// Control-point grid that maps a surface's UV square onto the output canvas.
///
/// A 2x2 grid is a corner pin, rendered with a true perspective homography so straight
/// lines stay straight on flat walls. Denser grids (3x3, 4x4...) let edges bend around
/// curved forms; those are interpolated with a Catmull-Rom patch through the control points.
struct WarpMesh: Codable, Equatable {
    var columns: Int
    var rows: Int
    /// Row-major, row 0 is the top edge (v = 0). Coordinates are normalised output space, y down.
    var points: [SIMD2<Float>]

    init(columns: Int, rows: Int, points: [SIMD2<Float>]) {
        precondition(columns >= 2 && rows >= 2 && points.count == columns * rows)
        self.columns = columns
        self.rows = rows
        self.points = points
    }

    /// Axis-aligned rectangle corner pin.
    static func rect(center: SIMD2<Float>, size: SIMD2<Float>) -> WarpMesh {
        let h = size / 2
        return WarpMesh(columns: 2, rows: 2, points: [
            center + SIMD2(-h.x, -h.y), center + SIMD2(h.x, -h.y),
            center + SIMD2(-h.x, h.y), center + SIMD2(h.x, h.y),
        ])
    }

    static func quad(_ tl: SIMD2<Float>, _ tr: SIMD2<Float>, _ bl: SIMD2<Float>, _ br: SIMD2<Float>) -> WarpMesh {
        WarpMesh(columns: 2, rows: 2, points: [tl, tr, bl, br])
    }

    subscript(c: Int, r: Int) -> SIMD2<Float> {
        get { points[r * columns + c] }
        set { points[r * columns + c] = newValue }
    }

    var corners: (tl: SIMD2<Float>, tr: SIMD2<Float>, bl: SIMD2<Float>, br: SIMD2<Float>) {
        (self[0, 0], self[columns - 1, 0], self[0, rows - 1], self[columns - 1, rows - 1])
    }

    var bounds: (min: SIMD2<Float>, max: SIMD2<Float>) {
        points.reduce((SIMD2<Float>(repeating: .infinity), SIMD2<Float>(repeating: -.infinity))) {
            (simd_min($0.0, $1), simd_max($0.1, $1))
        }
    }

    var centroid: SIMD2<Float> { points.reduce(.zero, +) / Float(points.count) }

    mutating func translate(by d: SIMD2<Float>) {
        points = points.map { $0 + d }
    }

    mutating func scale(by s: Float, around c: SIMD2<Float>) {
        points = points.map { c + ($0 - c) * s }
    }

    mutating func rotate(by angle: Float, around c: SIMD2<Float>, aspect: Float) {
        // Rotate in aspect-corrected space so shapes don't skew on a wide canvas.
        let cs = cos(angle), sn = sin(angle)
        points = points.map { p in
            var d = p - c
            d.x *= aspect
            let r = SIMD2(d.x * cs - d.y * sn, d.x * sn + d.y * cs)
            return c + SIMD2(r.x / aspect, r.y)
        }
    }

    /// Re-sample the current warp into a grid with a different density, preserving its shape.
    func resampled(columns newC: Int, rows newR: Int) -> WarpMesh {
        var pts: [SIMD2<Float>] = []
        pts.reserveCapacity(newC * newR)
        for r in 0..<newR {
            for c in 0..<newC {
                pts.append(map(SIMD2(Float(c) / Float(newC - 1), Float(r) / Float(newR - 1))))
            }
        }
        return WarpMesh(columns: newC, rows: newR, points: pts)
    }

    // MARK: Mapping

    /// Map a surface UV coordinate to output space.
    func map(_ uv: SIMD2<Float>) -> SIMD2<Float> {
        if columns == 2 && rows == 2 {
            let c = corners
            return Homography.squareToQuad(c.tl, c.tr, c.br, c.bl).apply(uv)
        }
        return catmullRomPatch(uv)
    }

    private func catmullRomPatch(_ uv: SIMD2<Float>) -> SIMD2<Float> {
        let fx = uv.x * Float(columns - 1)
        let fy = uv.y * Float(rows - 1)
        let cx = min(max(Int(floor(fx)), 0), columns - 2)
        let cy = min(max(Int(floor(fy)), 0), rows - 2)
        let tx = fx - Float(cx)
        let ty = fy - Float(cy)

        func p(_ c: Int, _ r: Int) -> SIMD2<Float> {
            // Linear extrapolation past the border keeps edges straight-ish instead of clamping.
            let cc = min(max(c, 0), columns - 1), rr = min(max(r, 0), rows - 1)
            var v = self[cc, rr]
            if c < 0 { v = v * 2 - self[1, rr] }
            if c > columns - 1 { v = v * 2 - self[columns - 2, rr] }
            if r < 0 { v = v * 2 - self[cc, 1] }
            if r > rows - 1 { v = v * 2 - self[cc, rows - 2] }
            return v
        }

        var rowsInterp: [SIMD2<Float>] = []
        for j in -1...2 {
            rowsInterp.append(catmullRom(p(cx - 1, cy + j), p(cx, cy + j), p(cx + 1, cy + j), p(cx + 2, cy + j), tx))
        }
        return catmullRom(rowsInterp[0], rowsInterp[1], rowsInterp[2], rowsInterp[3], ty)
    }

    /// Tessellate into a triangle list. Each vertex is (output position, uv).
    func tessellate(subdivisions n: Int = 32) -> [WarpVertex] {
        var grid: [WarpVertex] = []
        grid.reserveCapacity((n + 1) * (n + 1))
        for j in 0...n {
            for i in 0...n {
                let uv = SIMD2(Float(i) / Float(n), Float(j) / Float(n))
                grid.append(WarpVertex(position: map(uv), uv: uv))
            }
        }
        var tris: [WarpVertex] = []
        tris.reserveCapacity(n * n * 6)
        for j in 0..<n {
            for i in 0..<n {
                let a = grid[j * (n + 1) + i], b = grid[j * (n + 1) + i + 1]
                let c = grid[(j + 1) * (n + 1) + i], d = grid[(j + 1) * (n + 1) + i + 1]
                tris += [a, b, c, b, d, c]
            }
        }
        return tris
    }

    /// Outline of the warped UV square, for overlays and hit-testing.
    func outline(samplesPerEdge n: Int = 24) -> [SIMD2<Float>] {
        var out: [SIMD2<Float>] = []
        for i in 0..<n { out.append(map(SIMD2(Float(i) / Float(n), 0))) }
        for i in 0..<n { out.append(map(SIMD2(1, Float(i) / Float(n)))) }
        for i in 0..<n { out.append(map(SIMD2(1 - Float(i) / Float(n), 1))) }
        for i in 0..<n { out.append(map(SIMD2(0, 1 - Float(i) / Float(n)))) }
        return out
    }

    func contains(_ p: SIMD2<Float>) -> Bool { Polygon.contains(outline(), p) }
}

struct WarpVertex {
    var position: SIMD2<Float>
    var uv: SIMD2<Float>
}

@inline(__always)
func catmullRom(_ p0: SIMD2<Float>, _ p1: SIMD2<Float>, _ p2: SIMD2<Float>, _ p3: SIMD2<Float>, _ t: Float) -> SIMD2<Float> {
    let t2 = t * t, t3 = t2 * t
    let a = 2 * p1
    let b = (p2 - p0) * t
    let c = (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2
    let d = (-p0 + 3 * p1 - 3 * p2 + p3) * t3
    return 0.5 * (a + b + c + d)
}

/// 3x3 projective transform.
struct Homography: Equatable {
    var m: simd_float3x3

    func apply(_ p: SIMD2<Float>) -> SIMD2<Float> {
        let v = m * SIMD3(p.x, p.y, 1)
        return SIMD2(v.x / v.z, v.y / v.z)
    }

    var inverse: Homography { Homography(m: m.inverse) }

    /// Maps the unit square (0,0),(1,0),(1,1),(0,1) to the quad p0..p3 (same winding).
    /// Heckbert, "Fundamentals of Texture Mapping and Image Warping", 1989.
    static func squareToQuad(_ p0: SIMD2<Float>, _ p1: SIMD2<Float>, _ p2: SIMD2<Float>, _ p3: SIMD2<Float>) -> Homography {
        let s = p0 - p1 + p2 - p3
        let d1 = p1 - p2, d2 = p3 - p2
        var a, b, c, d, e, f, g, h: Float
        if abs(s.x) < 1e-7 && abs(s.y) < 1e-7 {
            // Affine case.
            a = p1.x - p0.x; b = p2.x - p1.x; c = p0.x
            d = p1.y - p0.y; e = p2.y - p1.y; f = p0.y
            g = 0; h = 0
        } else {
            let den = d1.x * d2.y - d2.x * d1.y
            g = (s.x * d2.y - d2.x * s.y) / den
            h = (d1.x * s.y - s.x * d1.y) / den
            a = p1.x - p0.x + g * p1.x
            b = p3.x - p0.x + h * p3.x
            c = p0.x
            d = p1.y - p0.y + g * p1.y
            e = p3.y - p0.y + h * p3.y
            f = p0.y
        }
        // Column-major: columns are (a,d,g), (b,e,h), (c,f,1).
        return Homography(m: simd_float3x3(SIMD3(a, d, g), SIMD3(b, e, h), SIMD3(c, f, 1)))
    }
}

enum Polygon {
    static func contains(_ poly: [SIMD2<Float>], _ p: SIMD2<Float>) -> Bool {
        guard poly.count >= 3 else { return false }
        var inside = false
        var j = poly.count - 1
        for i in 0..<poly.count {
            let a = poly[i], b = poly[j]
            if (a.y > p.y) != (b.y > p.y) && p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    /// Ramer-Douglas-Peucker simplification for hand-drawn outlines.
    static func simplify(_ pts: [SIMD2<Float>], tolerance: Float) -> [SIMD2<Float>] {
        guard pts.count > 2 else { return pts }
        var maxD: Float = 0, index = 0
        let a = pts.first!, b = pts.last!
        for i in 1..<(pts.count - 1) {
            let d = distanceToSegment(pts[i], a, b)
            if d > maxD { maxD = d; index = i }
        }
        if maxD > tolerance {
            let left = simplify(Array(pts[...index]), tolerance: tolerance)
            let right = simplify(Array(pts[index...]), tolerance: tolerance)
            return Array(left.dropLast()) + right
        }
        return [a, b]
    }

    static func distanceToSegment(_ p: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
        let ab = b - a
        let len2 = simd_length_squared(ab)
        if len2 == 0 { return simd_distance(p, a) }
        let t = max(0, min(1, simd_dot(p - a, ab) / len2))
        return simd_distance(p, a + ab * t)
    }

    static func bounds(_ pts: [SIMD2<Float>]) -> (min: SIMD2<Float>, max: SIMD2<Float>) {
        pts.reduce((SIMD2<Float>(repeating: .infinity), SIMD2<Float>(repeating: -.infinity))) {
            (simd_min($0.0, $1), simd_max($0.1, $1))
        }
    }
}
