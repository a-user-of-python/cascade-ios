import Foundation

/// Constraint solver: Levenberg–Marquardt over entity parameters with a
/// numeric Jacobian. Parameter blocks per entity:
/// point [x,y] · line [ax,ay,bx,by] · circle [cx,cy,r] · arc [cx,cy,r,a0,a1].
public struct SolveResult {
    public var degreesOfFreedom: Int
    public var iterations: Int
    public var residual: Double
    public var warnings: [CADError]
}

public enum SketchSolver {

    static func paramCount(of e: SketchEntity) -> Int {
        switch e {
        case .point: return 2
        case .line: return 4
        case .circle: return 3
        case .arc: return 5
        }
    }

    static func params(of e: SketchEntity) -> [Double] {
        switch e {
        case .point(_, let p, _): return [p.x, p.y]
        case .line(_, let a, let b, _): return [a.x, a.y, b.x, b.y]
        case .circle(_, let c, let r, _): return [c.x, c.y, r]
        case .arc(_, let c, let r, let a0, let a1, _): return [c.x, c.y, r, a0, a1]
        }
    }

    static func entity(id: Int, like e: SketchEntity, params p: [Double]) -> SketchEntity {
        switch e {
        case .point(_, _, let cons): return .point(id: id, at: Vec2(p[0], p[1]), construction: cons)
        case .line(_, _, _, let cons): return .line(id: id, a: Vec2(p[0], p[1]), b: Vec2(p[2], p[3]), construction: cons)
        case .circle(_, _, _, let cons): return .circle(id: id, center: Vec2(p[0], p[1]), radius: p[2], construction: cons)
        case .arc(_, _, _, _, _, let cons): return .arc(id: id, center: Vec2(p[0], p[1]), radius: p[2], startAngle: p[3], endAngle: p[4], construction: cons)
        }
    }

    /// A view over the flat parameter vector for one sketch.
    struct Layout {
        var offsets: [Int: Int] = [:]  // entity id -> start index
        var total: Int = 0
        init(_ sketch: Sketch) {
            for e in sketch.entities {
                offsets[e.id] = total
                total += paramCount(of: e)
            }
        }
    }

    static func point(_ sketch: Sketch, _ x: [Double], _ layout: Layout,
                      entity id: Int, kind: PointKind) throws -> Vec2 {
        guard let e = sketch.entity(id), let off = layout.offsets[id] else {
            throw CADError.danglingConstraint("entity \(id)")
        }
        switch e {
        case .point: return Vec2(x[off], x[off + 1])
        case .line:
            switch kind {
            case .start: return Vec2(x[off], x[off + 1])
            case .end: return Vec2(x[off + 2], x[off + 3])
            default: throw CADError.danglingConstraint("line has no \(kind.rawValue)")
            }
        case .circle:
            if kind == .center { return Vec2(x[off], x[off + 1]) }
            throw CADError.danglingConstraint("circle has no \(kind.rawValue)")
        case .arc:
            switch kind {
            case .center: return Vec2(x[off], x[off + 1])
            case .start: return Vec2(x[off] + cos(x[off + 3]) * x[off + 2], x[off + 1] + sin(x[off + 3]) * x[off + 2])
            case .end: return Vec2(x[off] + cos(x[off + 4]) * x[off + 2], x[off + 1] + sin(x[off + 4]) * x[off + 2])
            default: throw CADError.danglingConstraint("arc has no \(kind.rawValue)")
            }
        }
    }

    static func residuals(_ sketch: Sketch, _ x: [Double], _ layout: Layout) throws -> [Double] {
        var r: [Double] = []
        func pt(_ id: Int, _ k: PointKind) throws -> Vec2 { try point(sketch, x, layout, entity: id, kind: k) }
        func radiusOf(_ id: Int) throws -> Double {
            guard let e = sketch.entity(id), let off = layout.offsets[id] else {
                throw CADError.danglingConstraint("entity \(id)")
            }
            switch e { case .circle, .arc: return x[off + 2]; default: throw CADError.danglingConstraint("no radius") }
        }
        func lineEnds(_ id: Int) throws -> (Vec2, Vec2) {
            (try pt(id, .start), try pt(id, .end))
        }
        for c in sketch.constraints {
            switch c {
            case .coincident(let a, let ka, let b, let kb):
                let d = try pt(a, ka) - pt(b, kb); r += [d.x, d.y]
            case .horizontal(let e):
                let (a, b) = try lineEnds(e); r.append(a.y - b.y)
            case .vertical(let e):
                let (a, b) = try lineEnds(e); r.append(a.x - b.x)
            case .distancePoints(let a, let ka, let b, let kb, let v):
                r.append(try pt(a, ka).distance(to: pt(b, kb)) - v)
            case .radius(let e, let v):
                r.append(try radiusOf(e) - v)
            case .diameter(let e, let v):
                r.append(2 * (try radiusOf(e)) - v)
            case .equalRadius(let a, let b):
                r.append(try radiusOf(a) - radiusOf(b))
            case .equalLength(let a, let b):
                let (a1, a2) = try lineEnds(a); let (b1, b2) = try lineEnds(b)
                r.append(a1.distance(to: a2) - b1.distance(to: b2))
            case .parallel(let a, let b):
                let (a1, a2) = try lineEnds(a); let (b1, b2) = try lineEnds(b)
                let da = a2 - a1, db = b2 - b1
                r.append(da.cross(db) / max(da.length * db.length, 1e-12))
            case .perpendicular(let a, let b):
                let (a1, a2) = try lineEnds(a); let (b1, b2) = try lineEnds(b)
                let da = a2 - a1, db = b2 - b1
                r.append(da.dot(db) / max(da.length * db.length, 1e-12))
            case .pointOnLine(let p, let k, let l):
                let pp = try pt(p, k); let (a, b) = try lineEnds(l)
                let ab = b - a
                r.append(ab.cross(pp - a) / max(ab.length, 1e-12))
            case .pointOnCircle(let p, let k, let c):
                let pp = try pt(p, k); let cc = try pt(c, .center)
                r.append(pp.distance(to: cc) - (try radiusOf(c)))
            case .fixedPoint(let e, let k, let at):
                let d = try pt(e, k) - at; r += [d.x, d.y]
            case .angleBetween(let a, let b, let deg):
                let (a1, a2) = try lineEnds(a); let (b1, b2) = try lineEnds(b)
                let da = (a2 - a1).normalized, db = (b2 - b1).normalized
                r.append(da.dot(db) - cos(deg * Double.pi / 180))
            case .tangentLineCircle(let l, let c):
                let (a, b) = try lineEnds(l); let cc = try pt(c, .center)
                let ab = b - a
                r.append(abs(ab.cross(cc - a)) / max(ab.length, 1e-12) - (try radiusOf(c)))
            case .symmetric(let a, let ka, let b, let kb, let axis):
                let pa = try pt(a, ka); let pb = try pt(b, kb)
                let (l1, l2) = try lineEnds(axis)
                let axisDir = (l2 - l1).normalized
                let proj = l1 + axisDir * (pa - l1).dot(axisDir)
                let reflected = proj * 2 - pa
                let d = reflected - pb; r += [d.x, d.y]
            }
        }
        return r
    }

    static func jacobian(_ sketch: Sketch, _ x: [Double], _ layout: Layout,
                         base: [Double]) throws -> [[Double]] {
        let h = 1e-6
        var J = [[Double]](repeating: [Double](repeating: 0, count: x.count), count: base.count)
        for j in x.indices {
            var xp = x; xp[j] += h
            let rp = try residuals(sketch, xp, layout)
            for i in base.indices { J[i][j] = (rp[i] - base[i]) / h }
        }
        return J
    }

    static func rank(of J: [[Double]], tol: Double = 1e-7) -> Int {
        guard !J.isEmpty else { return 0 }
        var M = J
        let rows = M.count, cols = M[0].count
        var rank = 0
        var row = 0
        for col in 0..<cols where row < rows {
            var piv = -1; var best = tol
            for r in row..<rows where abs(M[r][col]) > best { best = abs(M[r][col]); piv = r }
            if piv < 0 { continue }
            M.swapAt(row, piv)
            let d = M[row][col]
            for r in 0..<rows where r != row {
                let f = M[r][col] / d
                if f != 0 { for c in col..<cols { M[r][c] -= f * M[row][c] } }
            }
            rank += 1; row += 1
        }
        return rank
    }

    /// Solve the sketch in place. On hard failure the sketch is untouched and
    /// a coded CADError is thrown (SV301/302/305/306).
    @discardableResult
    public static func solve(_ sketch: inout Sketch, logger: MCLog = .shared) throws -> SolveResult {
        let start = Date()
        let layout = Layout(sketch)
        var x: [Double] = []
        for e in sketch.entities { x += params(of: e) }
        if x.isEmpty { return SolveResult(degreesOfFreedom: 0, iterations: 0, residual: 0, warnings: []) }

        var r = try residuals(sketch, x, layout)
        let J0 = try jacobian(sketch, x, layout, base: r)
        let initialRank = rank(of: J0)
        let dof = x.count - initialRank

        // Redundancy: more residual rows than rank, with everything already satisfied.
        var warnings: [CADError] = []
        let norm0 = r.reduce(0) { $0 + $1 * $1 }.squareRoot()
        if r.count > initialRank && norm0 < 1e-9 && !sketch.constraints.isEmpty {
            warnings.append(.redundantConstraint("one or more"))
        }

        var lambda = 1e-3
        var iterations = 0
        var converged = norm0 < 1e-9
        while !converged && iterations < 100 {
            iterations += 1
            let J = try jacobian(sketch, x, layout, base: r)
            // Normal equations (JᵀJ + λI) δ = -Jᵀr
            let n = x.count
            var A = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
            var g = [Double](repeating: 0, count: n)
            for i in r.indices {
                for j in 0..<n {
                    g[j] += J[i][j] * r[i]
                    for k in 0..<n { A[j][k] += J[i][j] * J[i][k] }
                }
            }
            for j in 0..<n { A[j][j] += lambda }
            guard let delta = solveLinear(A, g.map { -$0 }) else {
                throw CADError.solverSingular
            }
            let trial = zip(x, delta).map(+)
            let rt = try residuals(sketch, trial, layout)
            let normT = rt.reduce(0) { $0 + $1 * $1 }.squareRoot()
            let normC = r.reduce(0) { $0 + $1 * $1 }.squareRoot()
            if normT < normC {
                x = trial; r = rt; lambda = max(lambda * 0.3, 1e-12)
                if normT < 1e-9 { converged = true }
            } else {
                lambda *= 10
                if lambda > 1e9 { break }  // stalled at a least-squares minimum: non-convergence, not singularity
            }
        }
        let residual = r.reduce(0) { $0 + $1 * $1 }.squareRoot()
        logger.debug(.solver, "solve", context: [
            "entities": "\(sketch.entities.count)", "constraints": "\(sketch.constraints.count)",
            "dof": "\(dof)", "iterations": "\(iterations)",
            "residual": String(format: "%.3g", residual),
            "ms": String(format: "%.1f", Date().timeIntervalSince(start) * 1000),
        ])
        if !converged {
            if r.count > x.count {
                throw CADError.conflictingConstraints(sketch.constraints.map { $0.displayName })
            }
            throw CADError.solverDidNotConverge(residual: residual, iterations: iterations)
        }
        // Commit solved parameters.
        var out: [SketchEntity] = []
        for e in sketch.entities {
            let off = layout.offsets[e.id]!
            let count = paramCount(of: e)
            out.append(entity(id: e.id, like: e, params: Array(x[off..<(off + count)])))
        }
        sketch.entities = out
        return SolveResult(degreesOfFreedom: dof, iterations: iterations, residual: residual, warnings: warnings)
    }

    /// DOF without solving (for the live badge).
    public static func degreesOfFreedom(_ sketch: Sketch) -> Int {
        let layout = Layout(sketch)
        var x: [Double] = []
        for e in sketch.entities { x += params(of: e) }
        guard !x.isEmpty,
              let r = try? residuals(sketch, x, layout),
              let J = try? jacobian(sketch, x, layout, base: r) else { return x.count }
        return x.count - rank(of: J)
    }

    /// Gaussian elimination with partial pivoting. nil = singular.
    static func solveLinear(_ A0: [[Double]], _ b0: [Double]) -> [Double]? {
        var A = A0, b = b0
        let n = b.count
        for col in 0..<n {
            var piv = col; var best = abs(A[col][col])
            for r in (col + 1)..<n where abs(A[r][col]) > best { best = abs(A[r][col]); piv = r }
            if best < 1e-14 { return nil }
            if piv != col { A.swapAt(piv, col); b.swapAt(piv, col) }
            for r in (col + 1)..<n {
                let f = A[r][col] / A[col][col]
                if f == 0 { continue }
                for c in col..<n { A[r][c] -= f * A[col][c] }
                b[r] -= f * b[col]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for i in stride(from: n - 1, through: 0, by: -1) {
            var s = b[i]
            for c in (i + 1)..<n { s -= A[i][c] * x[c] }
            x[i] = s / A[i][i]
        }
        return x
    }
}
