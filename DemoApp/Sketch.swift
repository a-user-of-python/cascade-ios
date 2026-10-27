import Foundation

public enum PointKind: String, Codable {
    case start, end, center, whole
}

public enum SketchEntity: Codable, Equatable {
    case point(id: Int, at: Vec2, construction: Bool)
    case line(id: Int, a: Vec2, b: Vec2, construction: Bool)
    case circle(id: Int, center: Vec2, radius: Double, construction: Bool)
    case arc(id: Int, center: Vec2, radius: Double, startAngle: Double, endAngle: Double, construction: Bool)

    public var id: Int {
        switch self {
        case .point(let i, _, _), .line(let i, _, _, _),
             .circle(let i, _, _, _), .arc(let i, _, _, _, _, _): return i
        }
    }
    public var isConstruction: Bool {
        switch self {
        case .point(_, _, let c), .line(_, _, _, let c),
             .circle(_, _, _, let c), .arc(_, _, _, _, _, let c): return c
        }
    }
    /// Resolve an addressable point of this entity.
    public func resolve(_ kind: PointKind) -> Vec2? {
        switch self {
        case .point(_, let at, _):
            return at
        case .line(_, let a, let b, _):
            switch kind { case .start: return a; case .end: return b; default: return nil }
        case .circle(_, let c, _, _):
            return kind == .center ? c : nil
        case .arc(_, let c, let r, let a0, let a1, _):
            switch kind {
            case .center: return c
            case .start: return c + Vec2(cos(a0), sin(a0)) * r
            case .end: return c + Vec2(cos(a1), sin(a1)) * r
            default: return nil
            }
        }
    }
    /// Flatten to a polyline (for profiles and display). Circles/arcs are
    /// chord-approximated to `sagitta` tolerance.
    public func polyline(sagitta: Double = 0.01) -> [Vec2] {
        switch self {
        case .point(_, let at, _): return [at]
        case .line(_, let a, let b, _): return [a, b]
        case .circle(_, let c, let r, _):
            return arcPoints(center: c, radius: r, from: 0, to: 2 * Double.pi, sagitta: sagitta, closed: true)
        case .arc(_, let c, let r, let a0, let a1, _):
            return arcPoints(center: c, radius: r, from: a0, to: a1, sagitta: sagitta, closed: false)
        }
    }
}

public func arcPoints(center: Vec2, radius: Double, from a0: Double, to a1: Double,
                      sagitta: Double, closed: Bool) -> [Vec2] {
    var sweep = a1 - a0
    while sweep < 0 { sweep += 2 * Double.pi }
    if closed && abs(sweep) < 1e-12 { sweep = 2 * Double.pi }
    let r = max(radius, 1e-9)
    let maxStep = 2 * acos(max(-1, min(1, 1 - sagitta / r)))
    let steps = max(2, Int(ceil(sweep / max(maxStep, 0.05))))
    return (0...steps).map { i in
        let a = a0 + sweep * Double(i) / Double(steps)
        return center + Vec2(cos(a), sin(a)) * radius
    }
}

public enum SketchConstraint: Codable, Equatable {
    case coincident(entityA: Int, kindA: PointKind, entityB: Int, kindB: PointKind)
    case horizontal(entity: Int)
    case vertical(entity: Int)
    case distancePoints(entityA: Int, kindA: PointKind, entityB: Int, kindB: PointKind, value: Double)
    case radius(entity: Int, value: Double)
    case diameter(entity: Int, value: Double)
    case equalRadius(entityA: Int, entityB: Int)
    case equalLength(entityA: Int, entityB: Int)
    case parallel(entityA: Int, entityB: Int)
    case perpendicular(entityA: Int, entityB: Int)
    case pointOnLine(pointEntity: Int, pointKind: PointKind, lineEntity: Int)
    case pointOnCircle(pointEntity: Int, pointKind: PointKind, circleEntity: Int)
    case fixedPoint(entity: Int, kind: PointKind, at: Vec2)
    case angleBetween(entityA: Int, entityB: Int, degrees: Double)
    case tangentLineCircle(lineEntity: Int, circleEntity: Int)
    case symmetric(entityA: Int, kindA: PointKind, entityB: Int, kindB: PointKind, axisLine: Int)

    public var displayName: String {
        switch self {
        case .coincident: return "Coincident"
        case .horizontal: return "Horizontal"
        case .vertical: return "Vertical"
        case .distancePoints: return "Distance"
        case .radius: return "Radius"
        case .diameter: return "Diameter"
        case .equalRadius: return "Equal radius"
        case .equalLength: return "Equal length"
        case .parallel: return "Parallel"
        case .perpendicular: return "Perpendicular"
        case .pointOnLine: return "Point on line"
        case .pointOnCircle: return "Point on circle"
        case .fixedPoint: return "Fixed"
        case .angleBetween: return "Angle"
        case .tangentLineCircle: return "Tangent"
        case .symmetric: return "Symmetric"
        }
    }
    /// Entity ids this constraint references (for dangling checks).
    public var referencedEntities: [Int] {
        switch self {
        case .coincident(let a, _, let b, _): return [a, b]
        case .horizontal(let e), .vertical(let e), .radius(let e, _), .diameter(let e, _): return [e]
        case .distancePoints(let a, _, let b, _, _): return [a, b]
        case .equalRadius(let a, let b), .equalLength(let a, let b),
             .parallel(let a, let b), .perpendicular(let a, let b),
             .angleBetween(let a, let b, _): return [a, b]
        case .pointOnLine(let p, _, let l): return [p, l]
        case .pointOnCircle(let p, _, let c): return [p, c]
        case .fixedPoint(let e, _, _): return [e]
        case .tangentLineCircle(let l, let c): return [l, c]
        case .symmetric(let a, _, let b, _, let axis): return [a, b, axis]
        }
    }
}

/// One closed profile loop: CCW outer, CW holes (both flattened polylines).
public struct Profile: Equatable {
    public var outer: [Vec2]
    public var holes: [[Vec2]]
    public var area: Double { polygonArea(outer) - holes.reduce(0) { $0 + abs(polygonArea($1)) } }
    public init(outer: [Vec2], holes: [[Vec2]]) { self.outer = outer; self.holes = holes }
}

public func polygonArea(_ pts: [Vec2]) -> Double {
    var a = 0.0
    for i in pts.indices {
        let p = pts[i], q = pts[(i + 1) % pts.count]
        a += p.x * q.y - q.x * p.y
    }
    return a / 2
}

public func pointInPolygon(_ p: Vec2, _ poly: [Vec2]) -> Bool {
    var inside = false
    for i in poly.indices {
        let a = poly[i], b = poly[(i + 1) % poly.count]
        if (a.y > p.y) != (b.y > p.y) {
            let xInt = a.x + (p.y - a.y) * (b.x - a.x) / (b.y - a.y)
            if p.x < xInt { inside.toggle() }
        }
    }
    return inside
}

public struct Sketch: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var plane: Plane3
    public var entities: [SketchEntity] = []
    public var constraints: [SketchConstraint] = []
    private var nextEntityID: Int = 1

    public init(id: String = UUID().uuidString, name: String, plane: Plane3 = .xy) {
        self.id = id; self.name = name; self.plane = plane
    }

    public mutating func allocateID() -> Int { defer { nextEntityID += 1 }; return nextEntityID }
    public func entity(_ id: Int) -> SketchEntity? { entities.first { $0.id == id } }
    public mutating func add(_ e: SketchEntity) { entities.append(e) }
    public mutating func removeEntity(_ id: Int) { entities.removeAll { $0.id == id } }

    // MARK: Convenience builders (also used by the one-tap shapes in the app)

    @discardableResult
    public mutating func addLine(_ a: Vec2, _ b: Vec2, construction: Bool = false) -> Int {
        let i = allocateID(); add(.line(id: i, a: a, b: b, construction: construction)); return i
    }
    @discardableResult
    public mutating func addCircle(_ c: Vec2, _ r: Double, construction: Bool = false) -> Int {
        let i = allocateID(); add(.circle(id: i, center: c, radius: r, construction: construction)); return i
    }
    @discardableResult
    public mutating func addPoint(_ p: Vec2, construction: Bool = false) -> Int {
        let i = allocateID(); add(.point(id: i, at: p, construction: construction)); return i
    }
    /// Rectangle from two corners, as 4 lines with coincident corners.
    @discardableResult
    public mutating func addRectangle(from c1: Vec2, to c2: Vec2) -> [Int] {
        let p = [c1, Vec2(c2.x, c1.y), c2, Vec2(c1.x, c2.y)]
        var ids: [Int] = []
        for i in 0..<4 { ids.append(addLine(p[i], p[(i + 1) % 4])) }
        return ids
    }

    /// Health warnings (degenerate / duplicate entities), as coded errors.
    public func validate() -> [CADError] {
        var out: [CADError] = []
        for e in entities {
            switch e {
            case .line(let i, let a, let b, _) where a.distance(to: b) < 1e-9:
                out.append(.degenerateEntity(i))
            case .circle(let i, _, let r, _) where r <= 1e-9:
                out.append(.degenerateEntity(i))
            case .arc(let i, _, let r, _, _, _) where r <= 1e-9:
                out.append(.degenerateEntity(i))
            default: break
            }
        }
        for i in entities.indices {
            for j in entities.indices where j > i {
                let a = entities[i], b = entities[j]
                if case .line(_, let a1, let a2, _) = a, case .line(_, let b1, let b2, _) = b,
                   ((a1.distance(to: b1) < 1e-9 && a2.distance(to: b2) < 1e-9) ||
                    (a1.distance(to: b2) < 1e-9 && a2.distance(to: b1) < 1e-9)) {
                    out.append(.duplicateEntity(b.id))
                }
                if case .circle(_, let ac, let ar, _) = a, case .circle(_, let bc, let br, _) = b,
                   ac.distance(to: bc) < 1e-9 && abs(ar - br) < 1e-9 {
                    out.append(.duplicateEntity(b.id))
                }
            }
        }
        return out
    }

    // MARK: Profile extraction

    /// Extract closed profiles from non-construction entities.
    /// Throws SK204 (open), SK205 (self-intersecting). Warnings (SK206)
    /// are returned alongside via `warnings`.
    public func extractProfiles() throws -> (profiles: [Profile], warnings: [CADError]) {
        let curves = entities.filter { !$0.isConstruction }
        guard !curves.isEmpty else { throw CADError.sketchEmpty }
        var loops: [[Vec2]] = []
        var segments: [(a: Vec2, b: Vec2, pts: [Vec2])] = []
        for e in curves {
            switch e {
            case .circle:
                loops.append(e.polyline())
            case .point:
                continue
            default:
                let pts = e.polyline()
                for i in 0..<(pts.count - 1) {
                    segments.append((pts[i], pts[i + 1], [pts[i], pts[i + 1]]))
                }
            }
        }
        // Chain segments into loops by endpoint matching.
        let tol = 1e-6
        var used = [Bool](repeating: false, count: segments.count)
        var unmatchedEndpoints: [Vec2] = []
        for s in segments.indices where !used[s] {
            var chain: [Vec2] = [segments[s].a, segments[s].b]
            used[s] = true
            var grew = true
            while grew {
                grew = false
                for t in segments.indices where !used[t] {
                    if segments[t].a.distance(to: chain.last!) < tol {
                        chain.append(segments[t].b); used[t] = true; grew = true
                    } else if segments[t].b.distance(to: chain.last!) < tol {
                        chain.append(segments[t].a); used[t] = true; grew = true
                    } else if segments[t].b.distance(to: chain.first!) < tol {
                        chain.insert(segments[t].a, at: 0); used[t] = true; grew = true
                    } else if segments[t].a.distance(to: chain.first!) < tol {
                        chain.insert(segments[t].b, at: 0); used[t] = true; grew = true
                    }
                }
            }
            if chain.count > 2 && chain.first!.distance(to: chain.last!) < tol {
                chain.removeLast()
                if chain.count >= 3 { loops.append(chain) }
            } else {
                unmatchedEndpoints.append(chain.first!)
                unmatchedEndpoints.append(chain.last!)
            }
        }
        if !unmatchedEndpoints.isEmpty {
            // Report the closest pair as the gap.
            var best = (unmatchedEndpoints[0], unmatchedEndpoints[min(1, unmatchedEndpoints.count - 1)], Double.infinity)
            for i in unmatchedEndpoints.indices {
                for j in unmatchedEndpoints.indices where j > i {
                    let d = unmatchedEndpoints[i].distance(to: unmatchedEndpoints[j])
                    if d < best.2 { best = (unmatchedEndpoints[i], unmatchedEndpoints[j], d) }
                }
            }
            throw CADError.profileOpen(gapA: best.0, gapB: best.1)
        }
        // Self-intersection check per loop.
        for loop in loops {
            for i in loop.indices {
                let a = loop[i], b = loop[(i + 1) % loop.count]
                for j in loop.indices where j > i + 1 && !(i == 0 && j == loop.count - 1) {
                    let c = loop[j], d = loop[(j + 1) % loop.count]
                    if let hit = segmentsCross(a, b, c, d) {
                        throw CADError.profileSelfIntersecting(at: hit)
                    }
                }
            }
        }
        // Normalize orientation (outer CCW) and assign holes by containment parity.
        var warnings: [CADError] = []
        var normalized = loops.map { lp -> [Vec2] in polygonArea(lp) < 0 ? Array(lp.reversed()) : lp }
        // depth = number of other loops containing this one
        func depth(of idx: Int) -> Int {
            var d = 0
            for j in normalized.indices where j != idx {
                if pointInPolygon(normalized[idx][0], normalized[j]) { d += 1 }
            }
            return d
        }
        var profiles: [Profile] = []
        var holeOf: [Int: [Int]] = [:]  // outer index -> hole indices
        for i in normalized.indices {
            let d = depth(of: i)
            if d > 8 { warnings.append(.profileNestedTooDeep(d)) }
            if d % 2 == 0 {
                profiles.append(Profile(outer: normalized[i], holes: []))
                holeOf[i] = []
            }
        }
        // Each odd-depth loop is a hole of its immediate (depth-1) container.
        for i in normalized.indices where depth(of: i) % 2 == 1 {
            var container: Int? = nil
            var containerDepth = -1
            for j in normalized.indices where j != i && depth(of: j) % 2 == 0 {
                if pointInPolygon(normalized[i][0], normalized[j]) && depth(of: j) > containerDepth {
                    container = j; containerDepth = depth(of: j)
                }
            }
            if let c = container, let pi = profiles.firstIndex(where: { $0.outer == normalized[c] }) {
                profiles[pi].holes.append(normalized[i])
            }
        }
        _ = holeOf
        normalized = []
        return (profiles, warnings)
    }
}
