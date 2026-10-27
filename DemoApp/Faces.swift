import Foundation

/// A planar region of a solid — what you sketch on. Extracted by grouping
/// welded-mesh triangles that are coplanar and edge-adjacent.
public struct PlanarFace: Equatable {
    public var plane: Plane3          // sketch plane: origin + axes (normal = face normal)
    public var outline2D: [Vec2]       // outer boundary in plane coordinates (CCW vs normal)
    public var area: Double
    public var centroid: Vec3
    public var triangleCount: Int
}

/// Remove points that lie on the segment between their neighbours
/// (CSG stitching leaves these along split edges; they break downstream
/// line-intersection math with zero determinants).
public func dropCollinear(_ poly: [Vec2], tolerance: Double = 1e-9) -> [Vec2] {
    guard poly.count > 3 else { return poly }
    var out: [Vec2] = []
    for i in poly.indices {
        let prev = poly[(i + poly.count - 1) % poly.count]
        let cur = poly[i]
        let next = poly[(i + 1) % poly.count]
        let d1 = cur - prev, d2 = next - cur
        let cross = d1.x * d2.y - d1.y * d2.x
        let scale = max(d1.length * d2.length, 1e-12)
        if abs(cross) / scale > tolerance { out.append(cur) }
    }
    return out.count >= 3 ? out : poly
}

public enum FaceExtractor {
    /// Faces plus the welded-mesh triangle indices that form each face.
    public static func groupedFaces(of meshIn: Mesh, minArea: Double = 1e-6)
        -> (faces: [PlanarFace], triangles: [[Int]], mesh: Mesh) {
        let mesh = meshIn.welded()
        let normals = mesh.faceNormals()
        let n = mesh.triangleCount
        guard n > 0 else { return ([], [], mesh) }
        var parent = Array(0..<n)
        func find(_ x: Int) -> Int {
            var r = x
            while parent[r] != r { r = parent[r] }
            var c = x
            while parent[c] != r { let nxt = parent[c]; parent[c] = r; c = nxt }
            return r
        }
        func unite(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[rb] = ra }
        }
        var edgeTri: [UInt64: Int] = [:]
        func key(_ a: UInt32, _ b: UInt32) -> UInt64 {
            (UInt64(max(a, b)) << 32) | UInt64(min(a, b))
        }
        func planeOf(_ t: Int) -> (n: Vec3, w: Double) {
            let a = mesh.vertices[Int(mesh.indices[t * 3])]
            return (normals[t], normals[t].dot(a))
        }
        for t in 0..<n {
            for k in 0..<3 {
                let a = mesh.indices[t * 3 + k], b = mesh.indices[t * 3 + (k + 1) % 3]
                let kk = key(a, b)
                if let other = edgeTri[kk] {
                    let (n1, w1) = planeOf(t), (n2, w2) = planeOf(other)
                    if n1.dot(n2) > 0.99999 && abs(w1 - w2) < 1e-4 {
                        unite(t, other)
                    }
                } else {
                    edgeTri[kk] = t
                }
            }
        }
        var groups: [Int: [Int]] = [:]
        for t in 0..<n { groups[find(t), default: []].append(t) }
        var faces: [PlanarFace] = []
        var faceTris: [[Int]] = []
        for (_, tris) in groups {
            let normal = normals[tris[0]]
            guard normal.length > 0.5 else { continue }
            var area = 0.0
            var centroid = Vec3.zero
            var boundaryEdges: [(Vec3, Vec3)] = []
            for t in tris {
                let a = mesh.vertices[Int(mesh.indices[t * 3])]
                let b = mesh.vertices[Int(mesh.indices[t * 3 + 1])]
                let c = mesh.vertices[Int(mesh.indices[t * 3 + 2])]
                let triArea = (b - a).cross(c - a).length / 2
                area += triArea
                centroid = centroid + (a + b + c) * (triArea / 3)
            }
            guard area >= minArea else { continue }
            centroid = centroid * (1 / area)
            var faceEdgeUse: [UInt64: Int] = [:]
            for t in tris {
                for k in 0..<3 {
                    let i0 = mesh.indices[t * 3 + k], i1 = mesh.indices[t * 3 + (k + 1) % 3]
                    faceEdgeUse[key(i0, i1), default: 0] += 1
                }
            }
            for t in tris {
                for k in 0..<3 {
                    let i0 = mesh.indices[t * 3 + k], i1 = mesh.indices[t * 3 + (k + 1) % 3]
                    if faceEdgeUse[key(i0, i1)] == 1 {
                        boundaryEdges.append((mesh.vertices[Int(i0)], mesh.vertices[Int(i1)]))
                    }
                }
            }
            let helper = abs(normal.y) < 0.9 ? Vec3(0, 1, 0) : Vec3(1, 0, 0)
            let xAxis = helper.cross(normal).normalized
            let yAxis = normal.cross(xAxis).normalized
            let plane = Plane3(origin: centroid, xAxis: xAxis, yAxis: yAxis)
            func to2D(_ p: Vec3) -> Vec2 {
                let d = p - centroid
                return Vec2(d.dot(xAxis), d.dot(yAxis))
            }
            var loops: [[Vec2]] = []
            var remaining = boundaryEdges.map { (to2D($0.0), to2D($0.1)) }
            while !remaining.isEmpty {
                var chain: [Vec2] = [remaining[0].0, remaining[0].1]
                remaining.removeFirst()
                var grew = true
                while grew {
                    grew = false
                    for i in remaining.indices {
                        let e = remaining[i]
                        if e.0.distance(to: chain.last!) < 1e-6 {
                            chain.append(e.1); remaining.remove(at: i); grew = true; break
                        } else if e.1.distance(to: chain.last!) < 1e-6 {
                            chain.append(e.0); remaining.remove(at: i); grew = true; break
                        }
                    }
                }
                if chain.count >= 3 {
                    if chain.count > 1 && chain.first!.distance(to: chain.last!) < 1e-6 { chain.removeLast() }
                    loops.append(chain)
                }
            }
            let outline = loops.max(by: { abs(polygonArea($0)) < abs(polygonArea($1)) }) ?? []
            faces.append(PlanarFace(plane: plane, outline2D: dropCollinear(outline), area: area,
                                    centroid: centroid, triangleCount: tris.count))
            faceTris.append(tris)
        }
        // Deterministic order: area, then normal, then centroid — plain
        // area order is unstable across runs for equal-area faces (cubes),
        // and downstream CSG sequences inherit that nondeterminism.
        let order = faces.indices.sorted {
            if faces[$0].area != faces[$1].area { return faces[$0].area > faces[$1].area }
            let a = faces[$0], b = faces[$1]
            if a.plane.normal.x != b.plane.normal.x { return a.plane.normal.x < b.plane.normal.x }
            if a.plane.normal.y != b.plane.normal.y { return a.plane.normal.y < b.plane.normal.y }
            if a.plane.normal.z != b.plane.normal.z { return a.plane.normal.z < b.plane.normal.z }
            if a.centroid.x != b.centroid.x { return a.centroid.x < b.centroid.x }
            if a.centroid.y != b.centroid.y { return a.centroid.y < b.centroid.y }
            return a.centroid.z < b.centroid.z
        }
        return (order.map { faces[$0] }, order.map { faceTris[$0] }, mesh)
    }

    public static func planarFaces(of meshIn: Mesh, minArea: Double = 1e-6) -> [PlanarFace] {
        groupedFaces(of: meshIn, minArea: minArea).faces
    }
}

/// Built-in material library: appearance + density (g/cm³) for mass.
public struct Material: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var red: Double, green: Double, blue: Double
    public var density: Double  // g/cm^3
    public var metalness: Double  // 0..1 display hint
    public var roughness: Double  // 0..1 display hint
    public init(id: String, name: String, r: Double, g: Double, b: Double,
                density: Double, metalness: Double, roughness: Double) {
        self.id = id; self.name = name; self.red = r; self.green = g; self.blue = b
        self.density = density; self.metalness = metalness; self.roughness = roughness
    }
}

public enum MaterialLibrary {
    public static let all: [Material] = [
        Material(id: "aluminum-6061", name: "Aluminum 6061", r: 0.78, g: 0.80, b: 0.83, density: 2.70, metalness: 0.9, roughness: 0.35),
        Material(id: "steel-mild", name: "Steel (mild)", r: 0.55, g: 0.57, b: 0.60, density: 7.85, metalness: 0.9, roughness: 0.45),
        Material(id: "stainless-304", name: "Stainless 304", r: 0.83, g: 0.85, b: 0.87, density: 7.90, metalness: 0.95, roughness: 0.25),
        Material(id: "brass", name: "Brass", r: 0.85, g: 0.68, b: 0.35, density: 8.50, metalness: 0.95, roughness: 0.3),
        Material(id: "copper", name: "Copper", r: 0.85, g: 0.50, b: 0.35, density: 8.96, metalness: 0.95, roughness: 0.3),
        Material(id: "titanium", name: "Titanium", r: 0.62, g: 0.63, b: 0.66, density: 4.43, metalness: 0.95, roughness: 0.4),
        Material(id: "abs", name: "ABS plastic", r: 0.92, g: 0.92, b: 0.92, density: 1.05, metalness: 0.0, roughness: 0.6),
        Material(id: "pla", name: "PLA plastic", r: 0.30, g: 0.55, b: 0.95, density: 1.24, metalness: 0.0, roughness: 0.55),
        Material(id: "petg", name: "PETG plastic", r: 0.95, g: 0.45, b: 0.20, density: 1.27, metalness: 0.0, roughness: 0.5),
        Material(id: "nylon", name: "Nylon", r: 0.88, g: 0.86, b: 0.78, density: 1.15, metalness: 0.0, roughness: 0.65),
        Material(id: "oak", name: "Oak wood", r: 0.72, g: 0.55, b: 0.35, density: 0.72, metalness: 0.0, roughness: 0.8),
        Material(id: "delrin", name: "Delrin (acetal)", r: 0.96, g: 0.96, b: 0.94, density: 1.41, metalness: 0.0, roughness: 0.45),
    ]
    public static func byID(_ id: String) -> Material? { all.first { $0.id == id } }
    public static let defaultMaterial = MaterialLibrary.all[0]
}
