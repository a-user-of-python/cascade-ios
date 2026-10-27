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

    // MARK: - The four demo builds (pure façade calls)

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
}
