import Foundation

/// Tessellation kernel (v1): turns profiles and parameters into meshes.
/// Exact booleans, fillets and shells arrive with the OCCT bridge and, until
/// then, return their designed error codes instead of failing silently.
public enum Tessellation {

    // MARK: Primitives (base on z=0, XY centered unless noted)

    public static func box(width: Double, depth: Double, height: Double) throws -> Mesh {
        guard width > 0, depth > 0, height > 0 else {
            throw CADError.primitiveParamInvalid("box dimensions must be > 0")
        }
        let x = width / 2, y = depth / 2
        var b = MeshBuilder()
        let v: [Vec3] = [
            Vec3(-x, -y, 0), Vec3(x, -y, 0), Vec3(x, y, 0), Vec3(-x, y, 0),
            Vec3(-x, -y, height), Vec3(x, -y, height), Vec3(x, y, height), Vec3(-x, y, height),
        ]
        let idx = v.map { b.vertex($0) }
        b.quad(idx[0], idx[3], idx[2], idx[1])  // bottom (down)
        b.quad(idx[4], idx[5], idx[6], idx[7])  // top
        b.quad(idx[0], idx[1], idx[5], idx[4])  // front
        b.quad(idx[1], idx[2], idx[6], idx[5])  // right
        b.quad(idx[2], idx[3], idx[7], idx[6])  // back
        b.quad(idx[3], idx[0], idx[4], idx[7])  // left
        return b.mesh
    }

    public static func cylinder(radius: Double, height: Double, baseZ: Double = 0,
                                segments: Int = 96, taperDegrees: Double = 0) throws -> Mesh {
        guard radius > 0, height > 0 else {
            throw CADError.primitiveParamInvalid("cylinder radius/height must be > 0")
        }
        let topR = radius - tan(taperDegrees * .pi / 180) * height
        guard topR > 0 else { throw CADError.primitiveParamInvalid("taper consumes the cylinder") }
        var b = MeshBuilder()
        let bottomC = b.vertex(Vec3(0, 0, baseZ))
        let topC = b.vertex(Vec3(0, 0, baseZ + height))
        var bot: [UInt32] = [], top: [UInt32] = []
        for i in 0..<segments {
            let a = 2 * Double.pi * Double(i) / Double(segments)
            bot.append(b.vertex(Vec3(cos(a) * radius, sin(a) * radius, baseZ)))
            top.append(b.vertex(Vec3(cos(a) * topR, sin(a) * topR, baseZ + height)))
        }
        for i in 0..<segments {
            let j = (i + 1) % segments
            b.quad(bot[i], bot[j], top[j], top[i])
            b.triangle(bottomC, bot[j], bot[i])
            b.triangle(topC, top[i], top[j])
        }
        return b.mesh
    }

    public static func sphere(radius: Double, segments: Int = 64, rings: Int = 40) throws -> Mesh {
        guard radius > 0 else { throw CADError.primitiveParamInvalid("sphere radius must be > 0") }
        var b = MeshBuilder()
        // Single pole vertices (a grid of coincident pole vertices would
        // weld into degenerate triangles with zero normals).
        let top = b.vertex(Vec3(0, 0, radius))
        let bottom = b.vertex(Vec3(0, 0, -radius))
        var grid: [[UInt32]] = []  // rings 1..<rings
        for r in 1..<rings {
            let phi = Double.pi * Double(r) / Double(rings)
            var row: [UInt32] = []
            for s in 0..<segments {
                let th = 2 * Double.pi * Double(s) / Double(segments)
                row.append(b.vertex(Vec3(radius * sin(phi) * cos(th), radius * sin(phi) * sin(th), radius * cos(phi))))
            }
            grid.append(row)
        }
        // Top cap fan.
        for s in 0..<segments {
            let s2 = (s + 1) % segments
            b.triangle(top, grid[0][s], grid[0][s2])
        }
        // Middle bands.
        for r in 0..<(grid.count - 1) {
            for s in 0..<segments {
                let s2 = (s + 1) % segments
                b.quad(grid[r + 1][s], grid[r + 1][s2], grid[r][s2], grid[r][s])
            }
        }
        // Bottom cap fan.
        let last = grid[grid.count - 1]
        for s in 0..<segments {
            let s2 = (s + 1) % segments
            b.triangle(bottom, last[s2], last[s])
        }
        return b.mesh
    }

    public static func cone(radius: Double, height: Double, segments: Int = 96) throws -> Mesh {
        guard radius > 0, height > 0 else {
            throw CADError.primitiveParamInvalid("cone radius/height must be > 0")
        }
        var b = MeshBuilder()
        let apex = b.vertex(Vec3(0, 0, height))
        let center = b.vertex(Vec3(0, 0, 0))
        var ring: [UInt32] = []
        for i in 0..<segments {
            let a = 2 * Double.pi * Double(i) / Double(segments)
            ring.append(b.vertex(Vec3(cos(a) * radius, sin(a) * radius, 0)))
        }
        for i in 0..<segments {
            let j = (i + 1) % segments
            b.triangle(ring[i], ring[j], apex)
            b.triangle(center, ring[j], ring[i])
        }
        return b.mesh
    }

    public static func torus(ringRadius: Double, tubeRadius: Double,
                             segments: Int = 96, sides: Int = 48) throws -> Mesh {
        guard ringRadius > 0, tubeRadius > 0 else {
            throw CADError.primitiveParamInvalid("torus radii must be > 0")
        }
        guard tubeRadius < ringRadius else {
            throw CADError.primitiveParamInvalid("torus tube radius must be < ring radius")
        }
        var b = MeshBuilder()
        var grid: [[UInt32]] = []
        for i in 0..<segments {
            let th = 2 * Double.pi * Double(i) / Double(segments)
            var row: [UInt32] = []
            for j in 0..<sides {
                let ph = 2 * Double.pi * Double(j) / Double(sides)
                let r = ringRadius + tubeRadius * cos(ph)
                row.append(b.vertex(Vec3(r * cos(th), r * sin(th), tubeRadius * sin(ph))))
            }
            grid.append(row)
        }
        for i in 0..<segments {
            let i2 = (i + 1) % segments
            for j in 0..<sides {
                let j2 = (j + 1) % sides
                b.quad(grid[i][j], grid[i2][j], grid[i2][j2], grid[i][j2])
            }
        }
        return b.mesh
    }

    // MARK: Polygon triangulation (ear clipping, holes bridged)

    /// Triangulate a simple polygon (CCW). Points in sketch space.
    public static func triangulate(_ polyIn: [Vec2]) throws -> [[Vec2]] {
        var poly = polyIn
        // Strip a duplicated closing point.
        if poly.count > 1 && poly.first!.distance(to: poly.last!) < 1e-12 { poly.removeLast() }
        guard poly.count >= 3 else { throw CADError.kernelTessellationFailed("polygon < 3 points") }
        if polygonArea(poly) < 0 { poly.reverse() }
        var tris: [[Vec2]] = []
        var idx = Array(poly.indices)
        func cross2(_ a: Vec2, _ b: Vec2, _ c: Vec2) -> Double { (b - a).cross(c - a) }
        var guardCount = 0
        while idx.count > 3 {
            guardCount += 1
            if guardCount > poly.count * poly.count + 16 {
                throw CADError.kernelTessellationFailed("ear clipping stalled")
            }
            var earFound = false
            for k in idx.indices {
                let prev = idx[(k - 1 + idx.count) % idx.count]
                let cur = idx[k]
                let next = idx[(k + 1) % idx.count]
                let a = poly[prev], b = poly[cur], c = poly[next]
                if cross2(a, b, c) <= 1e-12 { continue }  // reflex or collinear
                var contains = false
                for m in idx where m != prev && m != cur && m != next {
                    let p = poly[m]
                    // barycentric-ish point-in-triangle
                    let d1 = cross2(a, b, p), d2 = cross2(b, c, p), d3 = cross2(c, a, p)
                    if d1 > 1e-12 && d2 > 1e-12 && d3 > 1e-12 { contains = true; break }
                }
                if contains { continue }
                tris.append([a, b, c])
                idx.remove(at: k)
                earFound = true
                break
            }
            if !earFound { throw CADError.kernelTessellationFailed("no ear found (degenerate polygon)") }
        }
        let a = poly[idx[0]], b = poly[idx[1]], c = poly[idx[2]]
        if cross2(a, b, c) > 0 { tris.append([a, b, c]) }
        else if cross2(a, b, c) < 0 { tris.append([a, c, b]) }
        return tris
    }

    /// Merge holes into the outer loop by bridging, returning one polygon.
    static func bridgedPolygon(outer: [Vec2], holes: [[Vec2]]) throws -> [Vec2] {
        var result = outer
        if polygonArea(result) < 0 { result.reverse() }
        for hole in holes {
            var h = hole
            if polygonArea(h) > 0 { h.reverse() }  // holes CW
            // Rightmost hole point.
            guard let hi = h.indices.max(by: { h[$0].x < h[$1].x }) else { continue }
            let hp = h[hi]
            // Nearest visible outer vertex: min distance whose segment stays inside.
            var bestIdx = -1; var bestDist = Double.infinity
            for (i, v) in result.enumerated() {
                let d = v.distance(to: hp)
                if d >= bestDist { continue }
                let mid = (v + hp) * 0.5
                if !pointInPolygon(mid, outer) { continue }
                var crosses = false
                for j in result.indices {
                    let e1 = result[j], e2 = result[(j + 1) % result.count]
                    if segmentsCross(hp, v, e1, e2) != nil { crosses = true; break }
                }
                if !crosses { bestIdx = i; bestDist = d }
            }
            guard bestIdx >= 0 else { throw CADError.kernelTessellationFailed("could not bridge a hole") }
            // Splice: outer[0...best] + hole ring starting/ending at hp + back to outer[best].
            var spliced: [Vec2] = []
            spliced += result[0...bestIdx]
            for k in 0...h.count {
                spliced.append(h[(hi + k) % h.count])
            }
            spliced.append(result[bestIdx])
            if bestIdx + 1 < result.count { spliced += result[(bestIdx + 1)...] }
            result = spliced
        }
        return result
    }

    // MARK: Extrude / revolve

    public static func extrude(profile: Profile, plane: Plane3, length: Double) throws -> Mesh {
        guard length > 0 else { throw CADError.padLengthInvalid(length) }
        let poly = try bridgedPolygon(outer: profile.outer, holes: profile.holes)
        let tris = try triangulate(poly)
        var b = MeshBuilder()
        func w(_ p: Vec2, _ z: Double) -> Vec3 { plane.toWorld(p) + plane.normal * z }
        // Bottom (z=0, facing down) and top.
        for t in tris {
            let i0 = b.vertex(w(t[0], 0)), i1 = b.vertex(w(t[1], 0)), i2 = b.vertex(w(t[2], 0))
            b.triangle(i0, i2, i1)
            let j0 = b.vertex(w(t[0], length)), j1 = b.vertex(w(t[1], length)), j2 = b.vertex(w(t[2], length))
            b.triangle(j0, j1, j2)
        }
        // Sides for every loop: outer as stored (CCW), holes reversed to CW
        // so their walls face into the void and subtract volume.
        var loops = [profile.outer]
        for h in profile.holes {
            loops.append(polygonArea(h) > 0 ? Array(h.reversed()) : h)
        }
        for loop in loops {
            let n = loop.count
            for i in 0..<n {
                let p = loop[i], q = loop[(i + 1) % n]
                if p.distance(to: q) < 1e-12 { continue }
                let a = b.vertex(w(p, 0)), bb = b.vertex(w(q, 0))
                let c = b.vertex(w(q, length)), d = b.vertex(w(p, length))
                b.quad(a, bb, c, d)
            }
        }
        return b.mesh
    }

    public static func revolve(profile: Profile, plane: Plane3, axisPoint: Vec2,
                               axisDirection: Vec2, angleDegrees: Double) throws -> Mesh {
        guard angleDegrees > 0, angleDegrees <= 360 else {
            throw CADError.transformInvalid("revolve angle \(angleDegrees) outside 0–360")
        }
        let dir = axisDirection.normalized
        guard dir.length > 0.5 else { throw CADError.revolveAxisMissing }
        // Profile must stay on one side of the axis.
        func signedDist(_ p: Vec2) -> Double { (p - axisPoint).cross(dir) }
        var signs = Set<Int>()
        for p in profile.outer {
            let d = signedDist(p)
            if abs(d) > 1e-9 { signs.insert(d > 0 ? 1 : -1) }
        }
        if signs.count > 1 { throw CADError.revolveProfileCrossesAxis }
        let axisOrigin3 = plane.toWorld(axisPoint)
        let axisDir3 = (plane.xAxis * dir.x + plane.yAxis * dir.y).normalized
        func rot(_ p: Vec3, _ ang: Double) -> Vec3 {
            let rel = p - axisOrigin3
            let cosA = cos(ang), sinA = sin(ang)
            return axisOrigin3 + rel * cosA + axisDir3.cross(rel) * sinA + axisDir3 * (axisDir3.dot(rel) * (1 - cosA))
        }
        let steps = max(4, Int(ceil(angleDegrees / 2.5)))
        var b = MeshBuilder()
        let loops = [profile.outer] + profile.holes
        for loop in loops {
            var rings: [[UInt32]] = []
            for s in 0...steps {
                let ang = (angleDegrees * Double.pi / 180) * Double(s) / Double(steps)
                rings.append(loop.map { b.vertex(rot(plane.toWorld($0), ang)) })
            }
            for s in 0..<steps {
                for i in loop.indices {
                    let j = (i + 1) % loop.count
                    let a = rings[s][i], bb = rings[s][j], c = rings[s + 1][j], d = rings[s + 1][i]
                    if a == bb || c == d { continue }
                    b.quad(a, bb, c, d)
                }
            }
        }
        // End caps for partial revolves.
        if angleDegrees < 360 {
            let poly = try bridgedPolygon(outer: profile.outer, holes: profile.holes)
            let tris = try triangulate(poly)
            let total = angleDegrees * Double.pi / 180
            for t in tris {
                let i0 = b.vertex(plane.toWorld(t[0])), i1 = b.vertex(plane.toWorld(t[1])), i2 = b.vertex(plane.toWorld(t[2]))
                b.triangle(i0, i2, i1)
                let j0 = b.vertex(rot(plane.toWorld(t[0]), total))
                let j1 = b.vertex(rot(plane.toWorld(t[1]), total))
                let j2 = b.vertex(rot(plane.toWorld(t[2]), total))
                b.triangle(j0, j1, j2)
            }
        }
        return b.mesh
    }
}

extension Tessellation {
    /// Offset a simple polygon in its plane, keeping vertex count and
    /// correspondence (each output vertex = intersection of the two
    /// adjacent offset edge lines). Positive d expands a CCW polygon.
    public static func offsetPolygon(_ polyIn: [Vec2], by d: Double) -> [Vec2]? {
        let poly = dropCollinear(polyIn)
        let area = polygonArea(poly)
        guard area != 0, poly.count >= 3 else { return nil }
        let ccw = area > 0
        func line(_ a: Vec2, _ b: Vec2) -> (n: Vec2, c: Double) {
            let dir = (b - a).normalized
            var nrm = Vec2(dir.y, -dir.x)
            if !ccw { nrm = nrm * -1 }
            return (nrm, nrm.dot(a) + d)
        }
        var out: [Vec2] = []
        let n = poly.count
        for i in 0..<n {
            let l1 = line(poly[(i + n - 1) % n], poly[i])
            let l2 = line(poly[i], poly[(i + 1) % n])
            let det = l1.n.x * l2.n.y - l1.n.y * l2.n.x
            guard abs(det) > 1e-12 else { return nil }
            out.append(Vec2((l1.c * l2.n.y - l1.n.y * l2.c) / det,
                            (l1.n.x * l2.c - l1.c * l2.n.x) / det))
        }
        let newArea = polygonArea(out)
        guard (newArea > 0) == ccw, abs(newArea) > abs(area) * 0.01 else { return nil }
        // Half-plane containment: every output vertex must respect EVERY
        // original edge's offset half-plane (inward distance >= |d| for a
        // shrink). Adjacent-line intersections alone can "wrap" through
        // the centre on over-shrinks and produce a plausible-looking but
        // wrong polygon; the non-adjacent constraints expose it.
        func inwardDistance(_ p: Vec2, _ a: Vec2, _ b: Vec2) -> Double {
            let dir = (b - a).normalized
            let cross = dir.x * (p.y - a.y) - dir.y * (p.x - a.x)
            return ccw ? cross : -cross  // > 0 = inside
        }
        if d < 0 {
            for p in out {
                for i in 0..<n {
                    if inwardDistance(p, poly[i], poly[(i + 1) % n]) < -d - 1e-9 { return nil }
                }
            }
        } else if d > 0 {
            func inwardDistanceOut(_ p: Vec2, _ a: Vec2, _ b: Vec2) -> Double {
                let dir = (b - a).normalized
                let cross = dir.x * (p.y - a.y) - dir.y * (p.x - a.x)
                let outArea = polygonArea(out)
                return outArea > 0 ? cross : -cross
            }
            for p in poly {
                for i in 0..<out.count {
                    if inwardDistanceOut(p, out[i], out[(i + 1) % out.count]) < d - 1e-9 { return nil }
                }
            }
        }
        return out
    }

    /// Extrude with a draft (taper) angle: the top profile is the base
    /// profile offset inward by tan(taper) x length.
    public static func extrudeTapered(profile: Profile, plane: Plane3, length: Double, taperDegrees: Double) throws -> Mesh {
        guard length > 0 else { throw CADError.padLengthInvalid(length) }
        if abs(taperDegrees) < 1e-9 { return try extrude(profile: profile, plane: plane, length: length) }
        let shrink = tan(taperDegrees * .pi / 180) * length
        guard let outerTop = offsetPolygon(profile.outer, by: -shrink) else {
            throw CADError.booleanFailed("taper \(taperDegrees) degrees is too steep for this profile")
        }
        var holesTop: [[Vec2]] = []
        for h in profile.holes {
            guard let ht = offsetPolygon(h, by: shrink) else {
                throw CADError.booleanFailed("taper \(taperDegrees) degrees collapses a hole in this profile")
            }
            holesTop.append(ht)
        }
        var b = MeshBuilder()
        func w(_ p: Vec2, _ z: Double) -> Vec3 { plane.toWorld(p) + plane.normal * z }
        let bottomTris = try triangulate(try bridgedPolygon(outer: profile.outer, holes: profile.holes))
        let topTris = try triangulate(try bridgedPolygon(outer: outerTop, holes: holesTop))
        for t in bottomTris {
            let i0 = b.vertex(w(t[0], 0)), i1 = b.vertex(w(t[1], 0)), i2 = b.vertex(w(t[2], 0))
            b.triangle(i0, i2, i1)
        }
        for t in topTris {
            let j0 = b.vertex(w(t[0], length)), j1 = b.vertex(w(t[1], length)), j2 = b.vertex(w(t[2], length))
            b.triangle(j0, j1, j2)
        }
        // Walls by vertex correspondence (offset keeps the count).
        func walls(_ lo: [Vec2], _ hi: [Vec2], hole: Bool) {
            let l0 = hole && polygonArea(lo) > 0 ? Array(lo.reversed()) : lo
            let l1 = hole && polygonArea(hi) > 0 ? Array(hi.reversed()) : hi
            // Reversal breaks index correspondence; for holes use the
            // non-reversed loops and flip each quad instead.
            let a = hole ? lo : l0
            let c = hole ? hi : l1
            for i in 0..<a.count {
                let j = (i + 1) % a.count
                let p0 = b.vertex(w(a[i], 0)), p1 = b.vertex(w(a[j], 0))
                let p2 = b.vertex(w(c[j], length)), p3 = b.vertex(w(c[i], length))
                if hole { b.quad(p0, p3, p2, p1) } else { b.quad(p0, p1, p2, p3) }
            }
        }
        walls(profile.outer, outerTop, hole: false)
        for (h0, h1) in zip(profile.holes, holesTop) { walls(h0, h1, hole: true) }
        return b.mesh
    }
}
