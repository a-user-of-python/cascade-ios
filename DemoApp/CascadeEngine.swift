import Foundation
import SceneKit

/// Thin Swift-side caller for the Cascade façade.
///
/// This file contains NO geometry logic: each function calls the
/// façade (which calls Open CASCADE directly), then converts the
/// returned tessellation buffers into a SceneKit geometry for
/// display. Swift decides what to build; OCCT does the geometry.
enum CascadeEngine {

    struct Result {
        var node: SCNNode
        var volume: Double
        var triangles: Int
        var faces: Int
    }

    enum EngineError: Error {
        case occt(String)
    }

    private static func lastError() -> String {
        String(cString: mc_last_error())
    }

    /// Run a façade build closure that returns a shape handle, then
    /// tessellate + measure it. The closure is responsible for
    /// freeing any intermediate handles it creates.
    private static func render(_ build: () throws -> UnsafeMutablePointer<MCFacadeShape>) throws -> Result {
        let shape = try build()
        defer { mc_free_shape(shape) }

        var err: Int32 = 0
        let volume = mc_volume(shape, &err)
        guard err == MC_OK.rawValue else { throw EngineError.occt(lastError()) }

        var mesh = MCFacadeMesh()
        let rc = mc_tessellate(shape, 0.1, &mesh, &err)
        guard rc == MC_OK.rawValue, err == MC_OK.rawValue else {
            throw EngineError.occt(lastError())
        }
        defer { mc_free_mesh(&mesh) }

        let node = makeNode(from: mesh)
        return Result(node: node,
                      volume: volume,
                      triangles: Int(mesh.triangleCount),
                      faces: Int(mesh.faceCount))
    }

    private static func makeNode(from mesh: MCFacadeMesh) -> SCNNode {
        let vcount = Int(mesh.vertexCount)
        let tcount = Int(mesh.triangleCount)

        var positions: [SCNVector3] = []
        var normals: [SCNVector3] = []
        positions.reserveCapacity(vcount)
        normals.reserveCapacity(vcount)
        for i in 0..<vcount {
            positions.append(SCNVector3(mesh.positions[3 * i],
                                        mesh.positions[3 * i + 1],
                                        mesh.positions[3 * i + 2]))
            normals.append(SCNVector3(mesh.normals[3 * i],
                                      mesh.normals[3 * i + 1],
                                      mesh.normals[3 * i + 2]))
        }
        var indices: [Int32] = []
        indices.reserveCapacity(tcount * 3)
        for i in 0..<(tcount * 3) {
            indices.append(mesh.indices[i])
        }

        let posSource = SCNGeometrySource(vertices: positions)
        let norSource = SCNGeometrySource(normals: normals)
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        let geometry = SCNGeometry(sources: [posSource, norSource], elements: [element])

        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = UIColor(red: 0.85, green: 0.88, blue: 0.92, alpha: 1.0)
        material.metalness.contents = 0.1
        material.roughness.contents = 0.55
        material.isDoubleSided = true
        geometry.materials = [material]

        let node = SCNNode(geometry: geometry)
        // OCCT is Z-up; SceneKit is Y-up. Rotate for display only:
        // after this rotation a local point (x, y, z) lands at
        // world (x, z, -y). Centre the model on the world origin
        // (in plan view) using the geometry's own bounding box.
        node.rotation = SCNVector4(1, 0, 0, -Float.pi / 2)
        let (minB, maxB) = geometry.boundingBox
        node.position = SCNVector3(-(minB.x + maxB.x) / 2,
                                   0,
                                   (minB.y + maxB.y) / 2)
        return node
    }

    // MARK: - The five demo builds (pure façade calls)

    static func box() throws -> Result {
        try render {
            var err: Int32 = 0
            guard let s = mc_box(20, 20, 10, &err) else {
                throw EngineError.occt(lastError())
            }
            return s
        }
    }

    static func filletedBox() throws -> Result {
        try render {
            var err: Int32 = 0
            guard let b = mc_box(20, 20, 10, &err) else {
                throw EngineError.occt(lastError())
            }
            defer { mc_free_shape(b) }
            guard let f = mc_fillet(b, 2.0, nil, 0, &err) else {
                throw EngineError.occt(lastError())
            }
            return f
        }
    }

    static func boxUnionCylinder() throws -> Result {
        try render {
            var err: Int32 = 0
            guard let b = mc_box(20, 20, 10, &err) else {
                throw EngineError.occt(lastError())
            }
            defer { mc_free_shape(b) }
            guard let c = mc_cylinder(5, 30, &err) else {
                throw EngineError.occt(lastError())
            }
            defer { mc_free_shape(c) }
            guard let u = mc_unite(b, c, &err) else {
                throw EngineError.occt(lastError())
            }
            return u
        }
    }

    static func hollowBox() throws -> Result {
        try render {
            var err: Int32 = 0
            guard let b = mc_box(20, 20, 10, &err) else {
                throw EngineError.occt(lastError())
            }
            defer { mc_free_shape(b) }
            guard let s = mc_shell(b, 1.5, &err) else {
                throw EngineError.occt(lastError())
            }
            return s
        }
    }

    /// Sketch -> face -> prism, end to end: a 60x40 plate outline
    /// (4 lines + 4 corner arcs, radius 6) with a circular hole
    /// (radius 8) in the middle, extruded 8 mm. The sketch entities
    /// are described as data only — Open CASCADE builds the edges,
    /// the wire, the face and the solid.
    static func sketchPlate() throws -> Result {
        try render {
            var err: Int32 = 0
            // Sketch plane: XY at the origin, normal +Z, +U = +X.
            let origin: [Double] = [0, 0, 0]
            let normal: [Double] = [0, 0, 1]
            let xDir: [Double] = [1, 0, 0]
            // Entity kinds: 0 = line (x1,y1,x2,y2), 1 = circle
            // (cx,cy,r), 2 = arc (cx,cy,r,start,end radians CCW).
            // Six doubles per entity, unused slots are 0.
            let entityTypes: [Int32] = [0, 2, 0, 2, 0, 2, 0, 2, 1]
            let entityData: [Double] = [
                6, 0, 54, 0, 0, 0,                       // line
                54, 6, 6, -Double.pi / 2, 0, 0,          // corner arc
                60, 6, 60, 34, 0, 0,                     // line
                54, 34, 6, 0, Double.pi / 2, 0,          // corner arc
                54, 40, 6, 40, 0, 0,                     // line
                6, 34, 6, Double.pi / 2, Double.pi, 0,   // corner arc
                0, 34, 0, 6, 0, 0,                       // line
                6, 6, 6, Double.pi, 3 * Double.pi / 2, 0, // corner arc
                30, 20, 8, 0, 0, 0,                      // hole circle
            ]
            // Profile 0 = the outline (entities 0..<8),
            // profile 1 = the hole (entity 8..<9).
            let profileStarts: [Int32] = [0, 8, 9]
            guard let face = mc_face_from_sketch(origin, normal, xDir,
                                                 entityTypes, entityData,
                                                 Int32(entityTypes.count),
                                                 profileStarts, 2, &err) else {
                throw EngineError.occt(lastError())
            }
            defer { mc_free_shape(face) }
            let dir: [Double] = [0, 0, 1]
            guard let s = mc_prism_face(face, dir, 8, &err) else {
                throw EngineError.occt(lastError())
            }
            return s
        }
    }
}
