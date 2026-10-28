import Foundation
import SceneKit
import Combine // ObservableObject / @Published for CurrentBody

/// Thin Swift-side caller for the CascadeKit library (the OCCT
/// façade, Facade/occt_facade.h).
///
/// This file contains NO geometry logic: each function calls the
/// library (which calls Open CASCADE directly), then converts the
/// returned tessellation buffers into a SceneKit geometry for
/// display. Swift decides what to build; OCCT does the geometry.
enum CascadeEngine {

    struct Result {
        var node: SCNNode
        var volume: Double
        var triangles: Int
        var faces: Int
        /// Solid count, when the producing call knows it (STEP
        /// import); nil otherwise.
        var solids: Int? = nil
        /// STEP surface colours per census face, when the import
        /// carried any (faces without a colour hold the standard
        /// body gray, ready for display); nil when the file had
        /// no colours — the node then uses the plain material.
        var faceColors: [(r: Double, g: Double, b: Double)]? = nil
    }

    enum EngineError: Error {
        case occt(String)
    }

    /// How a finished sketch applies when the editor's
    /// "Finish & Extrude" runs.
    enum ExtrudeMode {
        /// The extruded solid stands alone (the original behaviour).
        case standalone
        /// Unite the extruded solid into the current body.
        case add
        /// Cut the extruded solid out of the current body.
        case subtract
    }

    private static func lastError() -> String {
        String(cString: mc_last_error())
    }

    /// Run a façade build closure that returns a shape handle, then
    /// tessellate + measure it (the handle is freed afterwards).
    /// The closure is responsible for freeing any intermediate
    /// handles it creates.
    private static func render(_ build: () throws -> UnsafeMutablePointer<MCFacadeShape>) throws -> Result {
        let shape = try build()
        defer { mc_free_shape(shape) }
        return try measure(shape)
    }

    /// The shape's STEP surface colours per census face, when the
    /// handle came from an import whose file carried colours
    /// (mc_shape_face_colors). Faces with no colour of their own
    /// hold the standard body gray so callers can use the array
    /// directly for display. Returns nil when NO face has a
    /// colour (or the query fails) — the no-colour path then
    /// behaves exactly as before.
    static func faceColors(of shape: UnsafeMutablePointer<MCFacadeShape>)
        -> [(r: Double, g: Double, b: Double)]? {
        var err: Int32 = 0
        var faces: Int32 = 0
        guard mc_shape_counts(shape, &faces, nil, nil, &err) == MC_OK.rawValue,
              faces > 0 else { return nil }
        var rgb = [Double](repeating: 0, count: Int(faces) * 3)
        var has = [Int32](repeating: 0, count: Int(faces))
        guard mc_shape_face_colors(shape, &rgb, &has, &err) == MC_OK.rawValue
        else { return nil }
        var any = false
        var out: [(r: Double, g: Double, b: Double)] = []
        out.reserveCapacity(Int(faces))
        for i in 0 ..< Int(faces) {
            if has[i] != 0 {
                any = true
                out.append((rgb[3 * i], rgb[3 * i + 1], rgb[3 * i + 2]))
            } else {
                out.append((0.85, 0.88, 0.92))
            }
        }
        return any ? out : nil
    }

    /// Tessellate + measure a shape handle WITHOUT freeing it —
    /// the caller keeps ownership (the current body stays alive
    /// across calls this way).
    private static func measure(_ shape: UnsafeMutablePointer<MCFacadeShape>,
                                faceColors: [(r: Double, g: Double, b: Double)]? = nil) throws -> Result {
        var err: Int32 = 0
        let volume = mc_volume(shape, &err)
        guard err == MC_OK.rawValue else { throw EngineError.occt(lastError()) }

        var mesh = MCFacadeMesh()
        let rc = mc_tessellate(shape, 0.1, &mesh, &err)
        guard rc == MC_OK.rawValue, err == MC_OK.rawValue else {
            throw EngineError.occt(lastError())
        }
        defer { mc_free_mesh(&mesh) }

        let node = makeNode(from: mesh, faceColors: faceColors)
        var result = Result(node: node,
                            volume: volume,
                            triangles: Int(mesh.triangleCount),
                            faces: Int(mesh.faceCount))
        result.faceColors = faceColors
        return result
    }

    private static func makeNode(from mesh: MCFacadeMesh,
                                 faceColors: [(r: Double, g: Double, b: Double)]? = nil) -> SCNNode {
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

        let posSource = SCNGeometrySource(vertices: positions)
        let norSource = SCNGeometrySource(normals: normals)
        let geometry: SCNGeometry
        if let faceColors {
            // Per-face display: one element + material per census
            // face, coloured from the STEP file (gray fallback is
            // already baked into the array by faceColors(of:)).
            var elements: [SCNGeometryElement] = []
            var materials: [SCNMaterial] = []
            let fcount = Int(mesh.faceCount)
            for f in 0 ..< fcount {
                let start = Int(mesh.faceTriStart[f])
                let count = Int(mesh.faceTriCount[f])
                var idx: [Int32] = []
                idx.reserveCapacity(count * 3)
                for i in (3 * start) ..< (3 * (start + count)) {
                    idx.append(mesh.indices[i])
                }
                elements.append(SCNGeometryElement(indices: idx,
                                                   primitiveType: .triangles))
                let c = f < faceColors.count
                    ? faceColors[f] : (r: 0.85, g: 0.88, b: 0.92)
                let material = SCNMaterial()
                material.lightingModel = .physicallyBased
                material.diffuse.contents = UIColor(red: CGFloat(c.r),
                                                    green: CGFloat(c.g),
                                                    blue: CGFloat(c.b),
                                                    alpha: 1.0)
                material.metalness.contents = 0.1
                material.roughness.contents = 0.55
                material.isDoubleSided = true
                materials.append(material)
            }
            geometry = SCNGeometry(sources: [posSource, norSource],
                                   elements: elements)
            geometry.materials = materials
        } else {
            var indices: [Int32] = []
            indices.reserveCapacity(tcount * 3)
            for i in 0..<(tcount * 3) {
                indices.append(mesh.indices[i])
            }
            let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
            geometry = SCNGeometry(sources: [posSource, norSource], elements: [element])

            let material = SCNMaterial()
            material.lightingModel = .physicallyBased
            material.diffuse.contents = UIColor(red: 0.85, green: 0.88, blue: 0.92, alpha: 1.0)
            material.metalness.contents = 0.1
            material.roughness.contents = 0.55
            material.isDoubleSided = true
            geometry.materials = [material]
        }

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
        try render { try buildSketchPlateShape() }
    }

    /// Build the sketch-plate solid and return its handle (the
    /// caller owns it). Shared by the on-screen demo build and the
    /// first-launch STEP export that seeds the Documents folder.
    private static func buildSketchPlateShape() throws -> UnsafeMutablePointer<MCFacadeShape> {
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

    /// Write the sketch plate out as a STEP file through the
    /// library (mc_export_step). Used once per install to seed the
    /// Documents folder with a real, importable sample; silently
    /// returns false on any failure (the caller treats the sample
    /// as best-effort — the README seed is what guarantees the
    /// folder shows up in the Files app).
    @discardableResult
    static func exportSketchPlate(toPath path: String) -> Bool {
        guard let shape = try? buildSketchPlateShape() else { return false }
        defer { mc_free_shape(shape) }
        var err: Int32 = 0
        return mc_export_step(shape, path, &err) == MC_OK.rawValue
            && err == MC_OK.rawValue
    }

    // MARK: - MetalCAD sketch -> Cascade solid

    /// Extrude a sketch from MetalCAD's real sketch editor (the
    /// Sketch/SketchSolver slice copied into this app) through the
    /// façade, returning the solid as a raw handle (the caller
    /// owns it). The kit validates and structures the profiles —
    /// `extractProfiles()` is the same call the editor's Finish
    /// button makes, so the same coded CADError messages surface.
    /// The sketch's entities then map 1:1 onto the façade's sketch
    /// types (line / circle / arc — never flattened), OCCT builds
    /// the face, and the face is prismed 10 mm along the sketch
    /// plane's normal. With several disjoint profiles, each is
    /// prismed on its own and the solids are united.
    private static func buildSketchSolid(sketch: Sketch) throws -> UnsafeMutablePointer<MCFacadeShape> {
        let profiles: [Profile]
        do {
            profiles = try sketch.extractProfiles().profiles
        } catch let e as CADError {
            throw EngineError.occt("\(e.userMessage) (\(e.code))")
        }
        guard !profiles.isEmpty else {
            let e = CADError.padNoProfile
            throw EngineError.occt("\(e.userMessage) (\(e.code))")
        }

        // Group the non-construction entities into loops: a circle
        // is a loop by itself; lines and arcs group by shared
        // endpoints. Points and construction geometry never bound a
        // profile (extractProfiles ignores them too).
        var groups: [[SketchEntity]] = []
        var chained: [SketchEntity] = []
        for e in sketch.entities where !e.isConstruction {
            switch e {
            case .circle: groups.append([e])
            case .line, .arc: chained.append(e)
            case .point: break
            }
        }
        var rest = chained
        while !rest.isEmpty {
            var group = [rest.removeFirst()]
            var grew = true
            while grew {
                grew = false
                let ends = group.flatMap { endpoints(of: $0) }
                var i = 0
                while i < rest.count {
                    let other = endpoints(of: rest[i])
                    if ends.contains(where: { a in other.contains { $0.distance(to: a) <= 1e-6 } }) {
                        group.append(rest.remove(at: i))
                        grew = true
                    } else {
                        i += 1
                    }
                }
            }
            groups.append(group)
        }

        // Assign each group to a kit profile loop (outer or hole) by
        // matching a group vertex against the loop's points — the
        // kit loops are the same entities' flattened polylines, so
        // entity endpoints appear in them exactly.
        struct KitLoop { var profile: Int; var isHole: Bool; var points: [Vec2] }
        var kitLoops: [KitLoop] = []
        for (i, p) in profiles.enumerated() {
            kitLoops.append(KitLoop(profile: i, isHole: false, points: p.outer))
            for h in p.holes { kitLoops.append(KitLoop(profile: i, isHole: true, points: h)) }
        }
        var outers: [Int: [SketchEntity]] = [:]
        var holes: [Int: [[SketchEntity]]] = [:]
        for group in groups {
            let samples = samplePoints(of: group)
            guard let loop = kitLoops.first(where: { kl in
                kl.points.contains { p in samples.contains { $0.distance(to: p) <= 1e-4 } }
            }) else {
                throw EngineError.occt("One outline couldn't be matched to a closed profile. Check for gaps or duplicate lines.")
            }
            if loop.isHole {
                holes[loop.profile, default: []].append(group)
            } else {
                outers[loop.profile, default: []].append(contentsOf: group)
            }
        }

        let plane = sketch.plane
        // (This block was the body of the render closure before the
        // handle-returning refactor; its `return` below is the
        // function's own return of the owned solid handle.)
        do {
            var err: Int32 = 0
            let origin: [Double] = [plane.origin.x, plane.origin.y, plane.origin.z]
            let normal: [Double] = [plane.normal.x, plane.normal.y, plane.normal.z]
            let xDir: [Double] = [plane.xAxis.x, plane.xAxis.y, plane.xAxis.z]
            var result: UnsafeMutablePointer<MCFacadeShape>?
            for i in profiles.indices {
                guard let outer = outers[i], !outer.isEmpty else {
                    if let r = result { mc_free_shape(r) }
                    throw EngineError.occt("A closed profile had no matching sketch lines.")
                }
                var types: [Int32] = []
                var data: [Double] = []
                var starts: [Int32] = [0]
                for e in outer { appendEntity(e, types: &types, data: &data) }
                starts.append(Int32(types.count))
                for hole in holes[i] ?? [] {
                    for e in hole { appendEntity(e, types: &types, data: &data) }
                    starts.append(Int32(types.count))
                }
                guard let face = mc_face_from_sketch(origin, normal, xDir,
                                                     types, data, Int32(types.count),
                                                     starts, Int32(starts.count - 1), &err) else {
                    if let r = result { mc_free_shape(r) }
                    throw EngineError.occt(lastError())
                }
                let solid = mc_prism_face(face, normal, 10, &err)
                mc_free_shape(face)
                guard let solid else {
                    if let r = result { mc_free_shape(r) }
                    throw EngineError.occt(lastError())
                }
                if let r = result {
                    let united = mc_unite(r, solid, &err)
                    mc_free_shape(r)
                    mc_free_shape(solid)
                    guard let united else { throw EngineError.occt(lastError()) }
                    result = united
                } else {
                    result = solid
                }
            }
            guard let final = result else {
                throw EngineError.occt("Nothing to extrude.")
            }
            return final
        }
    }

    /// The editor's "Finish & Extrude", with the edit mode applied:
    /// standalone shows the extruded solid on its own; add/subtract
    /// boolean it against the CURRENT BODY (mc_unite / mc_subtract,
    /// both OCCT ops) and the result becomes the new current body.
    /// Without a current body, add/subtract are an error — the UI
    /// only offers them when a body exists.
    static func sketchExtrude(sketch: Sketch, mode: ExtrudeMode,
                              body: CurrentBody) throws -> Result {
        let solid = try buildSketchSolid(sketch: sketch)
        switch mode {
        case .standalone:
            defer { mc_free_shape(solid) }
            return try measure(solid)
        case .add, .subtract:
            guard let current = body.handle else {
                mc_free_shape(solid)
                throw EngineError.occt("There is no current body to edit. Import a STEP file first.")
            }
            var err: Int32 = 0
            let combined = mode == .add ? mc_unite(current, solid, &err)
                                        : mc_subtract(current, solid, &err)
            mc_free_shape(solid)
            guard let combined else { throw EngineError.occt(lastError()) }
            do {
                let result = try measure(combined)
                body.install(combined) // frees the previous body
                return result
            } catch {
                mc_free_shape(combined)
                throw error
            }
        }
    }

    /// Import a STEP file as the current body. The library reads
    /// the geometry (mc_import_step) and remembers the file's
    /// surface colours on the handle; the imported handle stays
    /// alive in `body` so later sketch edits can add to / subtract
    /// from it, and the tessellation is returned for display —
    /// coloured per face when the file carried colours.
    static func importSTEP(path: String, name: String,
                           body: CurrentBody) throws -> Result {
        var err: Int32 = 0
        var solids: Int32 = 0
        guard let handle = mc_import_step(path, &solids, &err) else {
            throw EngineError.occt(lastError())
        }
        do {
            let colors = faceColors(of: handle)
            var result = try measure(handle, faceColors: colors)
            result.solids = Int(solids)
            body.install(handle, label: name)
            return result
        } catch {
            mc_free_shape(handle)
            throw error
        }
    }

    private static func endpoints(of e: SketchEntity) -> [Vec2] {
        switch e {
        case .line(_, let a, let b, _): return [a, b]
        case .arc: return [e.resolve(.start), e.resolve(.end)].compactMap { $0 }
        default: return []
        }
    }

    private static func samplePoints(of group: [SketchEntity]) -> [Vec2] {
        var pts: [Vec2] = []
        for e in group {
            pts += endpoints(of: e)
            if case .circle(_, let c, let r, _) = e { pts.append(c + Vec2(r, 0)) }
        }
        return pts
    }

    /// One sketch entity -> one façade entity (6-double stride):
    /// line = type 0 (x1,y1,x2,y2), circle = type 1 (cx,cy,r),
    /// arc = type 2 (cx,cy,r,start,end radians CCW).
    private static func appendEntity(_ e: SketchEntity, types: inout [Int32], data: inout [Double]) {
        switch e {
        case .line(_, let a, let b, _):
            types.append(0); data += [a.x, a.y, b.x, b.y, 0, 0]
        case .circle(_, let c, let r, _):
            types.append(1); data += [c.x, c.y, r, 0, 0, 0]
        case .arc(_, let c, let r, let a0, let a1, _):
            types.append(2); data += [c.x, c.y, r, a0, a1, 0]
        case .point:
            break
        }
    }
}

/// Owns the app's CURRENT BODY: the one shape that stays alive
/// between calls so sketch edits can add to / subtract from it.
/// Set by STEP import; replaced by the result of every add /
/// subtract. The five canned demo builds are display-only and
/// never touch it.
final class CurrentBody: ObservableObject {
    /// The live façade handle (owned here; freed on replace/deinit).
    private(set) var handle: UnsafeMutablePointer<MCFacadeShape>?

    /// Short label for the UI (the imported file's name).
    @Published private(set) var label: String?

    var exists: Bool { handle != nil }

    /// Take ownership of `h` (the caller relinquishes it); any
    /// previous body is freed. `label` updates only when given.
    func install(_ h: UnsafeMutablePointer<MCFacadeShape>, label newLabel: String? = nil) {
        if let old = handle { mc_free_shape(old) }
        handle = h
        if let newLabel { label = newLabel }
    }

    deinit {
        if let h = handle { mc_free_shape(h) }
    }
}
