import Foundation
import SceneKit
import SwiftUI

/// FEM panel glue for the CascadeKit library's section 11 (voxel
/// mesh + basic stress analysis, Facade/occt_facade.h).
///
/// Like the rest of the app this file holds no analysis logic: it
/// calls the library to mesh the current body, maps the user's
/// tapped B-rep faces to mesh nodes through the library, solves
/// through the library, and displays what comes back (SceneKit
/// geometry + readouts). The FEM mathematics lives in CascadeKit.

// MARK: - Library data boxes (own the C handles)

/// A built voxel mesh plus its copied-out arrays.
final class FemMeshData {
    let handle: UnsafeMutablePointer<MCFacadeFemMesh>
    let nodeCount: Int
    let elementCount: Int
    let quadCount: Int
    let nodeCoords: [Double]  // 3 per node
    let elements: [Int32]     // 8 per element
    let quads: [Int32]        // 4 per boundary quad
    let quadFaces: [Int32]    // census face per quad, -1 = none
    let volume: Double        // realised mesh volume (mm^3)
    let voxelSize: Double

    init(body: UnsafeMutablePointer<MCFacadeShape>, voxelSize: Double) throws {
        var err: Int32 = 0
        guard let h = mc_fem_mesh(body, voxelSize, &err) else {
            throw CascadeEngine.EngineError.occt(String(cString: mc_last_error()))
        }
        handle = h
        var nn: Int32 = 0, ne: Int32 = 0, nq: Int32 = 0
        guard mc_fem_mesh_counts(h, &nn, &ne, &nq, &err) == MC_OK.rawValue else {
            throw CascadeEngine.EngineError.occt(String(cString: mc_last_error()))
        }
        nodeCount = Int(nn)
        elementCount = Int(ne)
        quadCount = Int(nq)
        var nodes = [Double](repeating: 0, count: 3 * nodeCount)
        guard mc_fem_mesh_nodes(h, &nodes, &err) == MC_OK.rawValue else {
            throw CascadeEngine.EngineError.occt(String(cString: mc_last_error()))
        }
        nodeCoords = nodes
        var els = [Int32](repeating: 0, count: 8 * elementCount)
        guard mc_fem_mesh_elements(h, &els, &err) == MC_OK.rawValue else {
            throw CascadeEngine.EngineError.occt(String(cString: mc_last_error()))
        }
        elements = els
        var qs = [Int32](repeating: 0, count: 4 * quadCount)
        var qf = [Int32](repeating: -1, count: quadCount)
        guard mc_fem_mesh_surface_data(h, &qs, &qf, &err) == MC_OK.rawValue else {
            throw CascadeEngine.EngineError.occt(String(cString: mc_last_error()))
        }
        quads = qs
        quadFaces = qf
        volume = mc_fem_mesh_volume(h, &err)
        self.voxelSize = mc_fem_mesh_voxel_size(h, &err)
    }

    /// Mesh surface nodes lying on census face `face` (library
    /// mapping, cached on the C side).
    func nodesOnFace(_ face: Int) throws -> [Int32] {
        var err: Int32 = 0
        var count: Int32 = 0
        guard mc_fem_nodes_on_face(handle, Int32(face), nil, 0, &count, &err) == MC_OK.rawValue else {
            throw CascadeEngine.EngineError.occt(String(cString: mc_last_error()))
        }
        if count == 0 { return [] }
        var out = [Int32](repeating: 0, count: Int(count))
        var got: Int32 = 0
        guard mc_fem_nodes_on_face(handle, Int32(face), &out, count, &got, &err) == MC_OK.rawValue else {
            throw CascadeEngine.EngineError.occt(String(cString: mc_last_error()))
        }
        return out
    }

    deinit { mc_free_fem_mesh(handle) }
}

/// A finished solve plus its copied-out result fields.
final class FemResultData {
    let handle: UnsafeMutablePointer<MCFacadeFemResult>
    let nodeVM: [Double]      // node-averaged von Mises, MPa
    let maxVonMises: Double
    let maxDisplacement: Double
    let iterations: Int
    let relResidual: Double

    init(mesh: FemMeshData, e: Double, nu: Double,
         fixedNodes: [Int32],
         loads: [(face: Int32, force: Double, dir: [Double])]) throws {
        var err: Int32 = 0
        let loadFaces = loads.map { $0.face }
        let loadForces = loads.map { $0.force }
        let loadDirs = loads.flatMap { $0.dir }
        guard let h = mc_fem_solve(mesh.handle, e, nu,
                                   fixedNodes, Int32(fixedNodes.count),
                                   loadFaces, loadForces, loadDirs,
                                   Int32(loads.count), &err) else {
            throw CascadeEngine.EngineError.occt(String(cString: mc_last_error()))
        }
        handle = h
        var mxVM = 0.0, mxD = 0.0, rr = 0.0
        var iters: Int32 = 0
        guard mc_fem_result_stats(h, &mxVM, &mxD, &iters, &rr, &err) == MC_OK.rawValue else {
            throw CascadeEngine.EngineError.occt(String(cString: mc_last_error()))
        }
        maxVonMises = mxVM
        maxDisplacement = mxD
        iterations = Int(iters)
        relResidual = rr
        var vm = [Double](repeating: 0, count: mesh.nodeCount)
        guard mc_fem_result_node_values(h, nil, &vm, &err) == MC_OK.rawValue else {
            throw CascadeEngine.EngineError.occt(String(cString: mc_last_error()))
        }
        nodeVM = vm
    }

    deinit { mc_free_fem_result(handle) }
}

// MARK: - Body tessellation for face picking

/// The current body's tessellation, read once for the panel:
/// per-face triangle ranges are the picking map (triangle ordinal
/// -> census face), the same index space as the library census.
private struct BodyTess {
    var positions: [Float]
    var normals: [Float]
    var indices: [Int32]
    var faceTriStart: [Int32]
    var faceTriCount: [Int32]
    var faceCount: Int
    var bbox: [Double]  // xmin ymin zmin xmax ymax zmax

    init(shape: UnsafeMutablePointer<MCFacadeShape>) throws {
        var err: Int32 = 0
        var bb = [Double](repeating: 0, count: 6)
        guard mc_bbox(shape, &bb, &err) == MC_OK.rawValue else {
            throw CascadeEngine.EngineError.occt(String(cString: mc_last_error()))
        }
        bbox = bb
        let diag = Swift.max(bb[3] - bb[0], bb[4] - bb[1], bb[5] - bb[2])
        var mesh = MCFacadeMesh()
        let deflection = Swift.max(0.05, diag / 2000.0)
        let rc = mc_tessellate(shape, deflection, &mesh, &err)
        guard rc == MC_OK.rawValue, err == MC_OK.rawValue else {
            throw CascadeEngine.EngineError.occt(String(cString: mc_last_error()))
        }
        defer { mc_free_mesh(&mesh) }
        let vc = Int(mesh.vertexCount)
        let tc = Int(mesh.triangleCount)
        positions = (0 ..< 3 * vc).map { mesh.positions[$0] }
        normals = (0 ..< 3 * vc).map { mesh.normals[$0] }
        indices = (0 ..< 3 * tc).map { mesh.indices[$0] }
        faceCount = Int(mesh.faceCount)
        faceTriStart = (0 ..< faceCount).map { mesh.faceTriStart[$0] }
        faceTriCount = (0 ..< faceCount).map { mesh.faceTriCount[$0] }
    }

    /// Census face for a SceneKit hit-test triangle ordinal.
    func face(forTriangle ordinal: Int) -> Int? {
        for f in 0 ..< faceCount {
            let s = Int(faceTriStart[f])
            let c = Int(faceTriCount[f])
            if ordinal >= s && ordinal < s + c { return f }
        }
        return nil
    }
}

// MARK: - Pickable SceneKit view

/// SCNView with a tap recogniser; a tap reports the census face
/// under the finger (via the tessellation's triangle ranges).
private struct PickableView: UIViewRepresentable {
    var scene: SCNScene
    var tess: BodyTess?
    var onTapFace: (Int) -> Void

    final class Coordinator: NSObject {
        var tess: BodyTess?
        var onTapFace: (Int) -> Void = { _ in }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false
        view.backgroundColor = UIColor(white: 0.12, alpha: 1)
        view.scene = scene
        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(tap)
        context.coordinator.tess = tess
        context.coordinator.onTapFace = onTapFace
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        uiView.scene = scene
        context.coordinator.tess = tess
        context.coordinator.onTapFace = onTapFace
    }
}

extension PickableView.Coordinator {
    @objc func handleTap(_ gesture: UITapGestureRecognizer) {
        guard let view = gesture.view as? SCNView, let tess else { return }
        let point = gesture.location(in: view)
        let hits = view.hitTest(point, options: nil)
        guard let hit = hits.first,
              let face = tess.face(forTriangle: hit.faceIndex) else { return }
        onTapFace(face)
    }
}

// MARK: - The panel

struct FemPanelView: View {
    @ObservedObject var currentBody: CurrentBody
    @Environment(\.dismiss) private var dismiss

    private enum PickMode: String, CaseIterable {
        case fix = "Fix faces"
        case load = "Load faces"
    }
    private enum MaterialPreset: String, CaseIterable {
        case pla = "PLA"
        case aluminum = "Aluminum"
        case steel = "Steel"
        var e: Double {
            switch self {
            case .pla: return 3500
            case .aluminum: return 69000
            case .steel: return 200000
            }
        }
        var nu: Double {
            switch self {
            case .pla: return 0.36
            case .aluminum: return 0.33
            case .steel: return 0.30
            }
        }
        var label: String {
            switch self {
            case .pla: return "PLA (3500 MPa)"
            case .aluminum: return "Aluminum (69000 MPa)"
            case .steel: return "Steel (200000 MPa)"
            }
        }
    }
    private enum MeshSize: String, CaseIterable {
        case coarse = "Coarse"
        case medium = "Medium"
        case fine = "Fine"
        /// Voxel size = body bbox max dimension / divisor.
        var divisor: Double {
            switch self {
            case .coarse: return 16
            case .medium: return 32
            case .fine: return 64
            }
        }
    }

    @State private var scene = SCNScene()
    @State private var tess: BodyTess?
    @State private var mode: PickMode = .fix
    @State private var fixedFaces: Set<Int> = []
    @State private var loadedFaces: Set<Int> = []
    @State private var forceN: Double = 1000
    @State private var pushIn = true
    @State private var material: MaterialPreset = .steel
    @State private var meshSize: MeshSize = .medium
    @State private var femMesh: FemMeshData?
    @State private var femResult: FemResultData?
    @State private var statusText = "Tap faces in the view to fix or load them."
    @State private var isError = false
    @State private var busy = false
    @State private var driftText: String?

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("FEM analysis")
                    .font(.system(size: 28, weight: .bold))
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.bordered)
            }
            Text("Basic linear stress analysis — voxel mesh.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            ZStack {
                PickableView(scene: scene, tess: tess) { face in
                    tapFace(face)
                }
                if busy {
                    ProgressView()
                        .controlSize(.large)
                        .padding(20)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)
            .background(Color(white: 0.12))
            .clipShape(RoundedRectangle(cornerRadius: 16))

            if femResult != nil {
                legend
            }

            Text(statusText)
                .font(.title3)
                .foregroundStyle(isError ? .red : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(3)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Tap mode", selection: $mode) {
                        ForEach(PickMode.allCases, id: \.self) { m in
                            Text(m.rawValue).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)

                    HStack {
                        Text("Fixed: \(faceList(fixedFaces))")
                        Spacer()
                        Text("Loaded: \(faceList(loadedFaces))")
                    }
                    .font(.headline)
                    if !fixedFaces.isEmpty || !loadedFaces.isEmpty {
                        Button("Clear faces") {
                            fixedFaces.removeAll()
                            loadedFaces.removeAll()
                            refreshScene()
                        }
                        .buttonStyle(.bordered)
                    }

                    HStack(spacing: 12) {
                        Text("Force per loaded face").font(.headline)
                        TextField("N", value: $forceN, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .keyboardType(.decimalPad)
                            .frame(width: 110)
                        Text("N").font(.headline)
                        Stepper("", value: $forceN, in: 1 ... 1_000_000, step: 100)
                            .labelsHidden()
                    }
                    Picker("Direction", selection: $pushIn) {
                        Text("Push in").tag(true)
                        Text("Pull out").tag(false)
                    }
                    .pickerStyle(.segmented)

                    Picker("Material", selection: $material) {
                        ForEach(MaterialPreset.allCases, id: \.self) { m in
                            Text(m.label).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)

                    Picker("Mesh size", selection: $meshSize) {
                        ForEach(MeshSize.allCases, id: \.self) { m in
                            Text(m.rawValue).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)

                    HStack(spacing: 10) {
                        Button {
                            buildMesh()
                        } label: {
                            Label("Mesh", systemImage: "grid")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(busy || tess == nil)
                        Button {
                            solve()
                        } label: {
                            Label("Solve", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(busy || femMesh == nil || fixedFaces.isEmpty || loadedFaces.isEmpty)
                        Button {
                            resetResults()
                        } label: {
                            Label("Reset view", systemImage: "arrow.counterclockwise")
                        }
                        .buttonStyle(.bordered)
                        .disabled(busy || femResult == nil)
                    }

                    if let mesh = femMesh {
                        Text("Mesh: \(mesh.nodeCount) nodes, \(mesh.elementCount) elements, voxel \(fmt(mesh.voxelSize)) mm. Mesh volume \(fmt(mesh.volume)) mm³.")
                            .font(.headline)
                    }
                    if let driftText {
                        Text(driftText)
                            .font(.headline)
                            .foregroundStyle(.orange)
                    }
                    if let r = femResult {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Max von Mises: \(fmt(r.maxVonMises)) MPa")
                                .font(.system(size: 26, weight: .bold, design: .rounded))
                            Text("Max displacement: \(fmtDisp(r.maxDisplacement)) mm")
                                .font(.system(size: 26, weight: .bold, design: .rounded))
                            Text("Solver: \(r.iterations) iterations, residual \(String(format: "%.2g", r.relResidual)).")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 330)
        }
        .padding(16)
        .onAppear { setUp() }
    }

    /// Blue -> red legend for the stress view.
    private var legend: some View {
        VStack(spacing: 2) {
            LinearGradient(
                colors: [Color(red: 0, green: 0, blue: 1),
                         Color(red: 0, green: 1, blue: 1),
                         Color(red: 0, green: 1, blue: 0),
                         Color(red: 1, green: 1, blue: 0),
                         Color(red: 1, green: 0, blue: 0)],
                startPoint: .leading, endPoint: .trailing)
                .frame(height: 14)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            HStack {
                Text("0 MPa")
                Spacer()
                Text("von Mises — max \(fmt(femResult?.maxVonMises ?? 0)) MPa")
            }
            .font(.subheadline)
        }
    }

    // MARK: actions

    private func setUp() {
        guard let handle = currentBody.handle else {
            statusText = "There is no current body. Import a STEP file first."
            isError = true
            return
        }
        do {
            let t = try BodyTess(shape: handle)
            tess = t
            refreshScene()
            statusText = "Tap faces in the view to fix or load them. \(t.faceCount) faces."
            isError = false
        } catch let CascadeEngine.EngineError.occt(message) {
            statusText = "OCCT error: \(message)"
            isError = true
        } catch {
            statusText = "Error: \(error.localizedDescription)"
            isError = true
        }
    }

    private func tapFace(_ face: Int) {
        switch mode {
        case .fix:
            if fixedFaces.contains(face) {
                fixedFaces.remove(face)
            } else {
                fixedFaces.insert(face)
                loadedFaces.remove(face)
            }
            statusText = "Face \(face) \(fixedFaces.contains(face) ? "fixed (blue)" : "unfixed")."
        case .load:
            if loadedFaces.contains(face) {
                loadedFaces.remove(face)
            } else {
                loadedFaces.insert(face)
                fixedFaces.remove(face)
            }
            statusText = "Face \(face) \(loadedFaces.contains(face) ? "loaded (orange)" : "unloaded")."
        }
        isError = false
        refreshScene()
    }

    private func buildMesh() {
        guard let handle = currentBody.handle, let t = tess else { return }
        let maxDim = Swift.max(t.bbox[3] - t.bbox[0],
                               t.bbox[4] - t.bbox[1],
                               t.bbox[5] - t.bbox[2])
        let voxel = Swift.max(0.1, maxDim / meshSize.divisor)
        busy = true
        statusText = "Meshing…"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let mesh = try FemMeshData(body: handle, voxelSize: voxel)
                var err: Int32 = 0
                let solidVol = mc_volume(handle, &err)
                let drift = solidVol > 0
                    ? abs(mesh.volume - solidVol) / solidVol : 0
                DispatchQueue.main.async {
                    femMesh = mesh
                    femResult = nil
                    busy = false
                    driftText = drift > 0.05
                        ? "Warning: mesh volume differs from the solid by \(Int((drift * 100).rounded()))% — thin features may be missing from the analysis. Try a finer mesh."
                        : nil
                    statusText = "Meshed: \(mesh.elementCount) elements. Pick fixed and loaded faces, then Solve."
                    isError = false
                    refreshScene()
                }
            } catch let CascadeEngine.EngineError.occt(message) {
                DispatchQueue.main.async {
                    busy = false
                    statusText = "Mesh failed: \(message)"
                    isError = true
                }
            } catch {
                DispatchQueue.main.async {
                    busy = false
                    statusText = "Mesh failed: \(error.localizedDescription)"
                    isError = true
                }
            }
        }
    }

    private func solve() {
        guard let mesh = femMesh, let handle = currentBody.handle else { return }
        busy = true
        statusText = "Solving…"
        let fixed = fixedFaces
        let loaded = loadedFaces
        let force = forceN
        let push = pushIn
        let mat = material
        let bbox = tess?.bbox ?? [0, 0, 0, 0, 0, 0]
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // Fixed nodes: the union of the fixed faces' mapped
                // node sets (library mapping).
                var fixedSet = Set<Int32>()
                for f in fixed {
                    for n in try mesh.nodesOnFace(f) { fixedSet.insert(n) }
                }
                // Loads: total force per face along the face normal
                // (push = -normal, into the part; pull = +normal).
                // Non-planar faces use centre-outward direction.
                var loads: [(face: Int32, force: Double, dir: [Double])] = []
                for f in loaded {
                    let dir = try loadDirection(shape: handle, face: f, push: push, bbox: bbox)
                    loads.append((face: Int32(f), force: force, dir: dir))
                }
                let result = try FemResultData(
                    mesh: mesh, e: mat.e, nu: mat.nu,
                    fixedNodes: fixedSet.sorted(),
                    loads: loads)
                DispatchQueue.main.async {
                    femResult = result
                    busy = false
                    statusText = "Solved. The view is coloured by von Mises stress."
                    isError = false
                    refreshScene()
                }
            } catch let CascadeEngine.EngineError.occt(message) {
                DispatchQueue.main.async {
                    busy = false
                    statusText = "Solve failed: \(message)"
                    isError = true
                }
            } catch {
                DispatchQueue.main.async {
                    busy = false
                    statusText = "Solve failed: \(error.localizedDescription)"
                    isError = true
                }
            }
        }
    }

    private func resetResults() {
        femResult = nil
        statusText = "Back to the plain body. Selections and mesh are kept."
        isError = false
        refreshScene()
    }

    /// Load direction for a face: its outward normal when planar
    /// (from the library census), else the direction from the
    /// body's bbox centre to the face centre. Push inverts it.
    private func loadDirection(shape: UnsafeMutablePointer<MCFacadeShape>,
                               face: Int, push: Bool,
                               bbox: [Double]) throws -> [Double] {
        var err: Int32 = 0
        var area = 0.0
        var center = [Double](repeating: 0, count: 3)
        var normal = [Double](repeating: 0, count: 3)
        var planar: Int32 = 0
        let rc = mc_face_info(shape, Int32(face), &area, &center, &normal,
                              &planar, &err)
        guard rc == MC_OK.rawValue else {
            throw CascadeEngine.EngineError.occt(String(cString: mc_last_error()))
        }
        var dir: [Double]
        if planar == 1 {
            dir = normal
        } else {
            let c = [(bbox[0] + bbox[3]) / 2,
                     (bbox[1] + bbox[4]) / 2,
                     (bbox[2] + bbox[5]) / 2]
            dir = [center[0] - c[0], center[1] - c[1], center[2] - c[2]]
        }
        let len = (dir[0] * dir[0] + dir[1] * dir[1] + dir[2] * dir[2]).squareRoot()
        guard len > 1e-12 else {
            throw CascadeEngine.EngineError.occt("That face has no usable load direction.")
        }
        let s = (push ? -1.0 : 1.0) / len
        return [dir[0] * s, dir[1] * s, dir[2] * s]
    }

    // MARK: scenes

    private func refreshScene() {
        if let mesh = femMesh, let result = femResult {
            scene = makeResultScene(mesh: mesh, result: result)
        } else if let t = tess {
            scene = makeSelectionScene(tess: t)
        }
    }

    /// Frame a geometry node the way the main view does (Z-up
    /// library space -> Y-up SceneKit, plan-centred), and add a
    /// camera fitted to the tessellation's bounding box.
    private func framedScene(geometry: SCNGeometry) -> SCNScene {
        let newScene = SCNScene()
        newScene.background.contents = UIColor(white: 0.12, alpha: 1)
        let node = SCNNode(geometry: geometry)
        node.rotation = SCNVector4(1, 0, 0, -Float.pi / 2)
        let (minB, maxB) = geometry.boundingBox
        node.position = SCNVector3(-(minB.x + maxB.x) / 2, 0,
                                   (minB.y + maxB.y) / 2)
        newScene.rootNode.addChildNode(node)

        let dx = Double(maxB.x - minB.x), dy = Double(maxB.y - minB.y),
            dz = Double(maxB.z - minB.z)
        let diag = Swift.max(1.0, (dx * dx + dy * dy + dz * dz).squareRoot())
        let cz = Double(minB.z + maxB.z) / 2  // local z -> world height
        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        // The default far plane is 100, but this camera sits ~1.35x
        // the body diagonal away — any body with diagonal over ~74
        // would lie beyond it and clip to nothing. Scale the clip
        // planes with the body.
        cameraNode.camera?.zNear = Swift.max(0.1, diag * 0.01)
        cameraNode.camera?.zFar = diag * 20
        cameraNode.position = SCNVector3(Float(diag * 0.75),
                                         Float(cz + diag * 0.6),
                                         Float(diag * 0.95))
        cameraNode.look(at: SCNVector3(0, Float(cz), 0))
        newScene.rootNode.addChildNode(cameraNode)

        let keyLight = SCNNode()
        keyLight.light = SCNLight()
        keyLight.light?.type = .omni
        keyLight.light?.intensity = 900
        keyLight.position = SCNVector3(30, 50, 30)
        newScene.rootNode.addChildNode(keyLight)
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 350
        newScene.rootNode.addChildNode(ambient)
        return newScene
    }

    /// The body with one geometry element per B-rep face, so faces
    /// colour by selection state (fixed = blue, loaded = orange).
    private func makeSelectionScene(tess t: BodyTess) -> SCNScene {
        var positions: [SCNVector3] = []
        positions.reserveCapacity(t.positions.count / 3)
        var normals: [SCNVector3] = []
        for i in 0 ..< t.positions.count / 3 {
            positions.append(SCNVector3(t.positions[3 * i],
                                        t.positions[3 * i + 1],
                                        t.positions[3 * i + 2]))
            normals.append(SCNVector3(t.normals[3 * i],
                                      t.normals[3 * i + 1],
                                      t.normals[3 * i + 2]))
        }
        let posSource = SCNGeometrySource(vertices: positions)
        let norSource = SCNGeometrySource(normals: normals)
        var elements: [SCNGeometryElement] = []
        var materials: [SCNMaterial] = []
        for f in 0 ..< t.faceCount {
            let start = Int(t.faceTriStart[f])
            let count = Int(t.faceTriCount[f])
            let idx = Array(t.indices[(3 * start) ..< (3 * (start + count))])
            elements.append(SCNGeometryElement(indices: idx,
                                               primitiveType: .triangles))
            let mat = SCNMaterial()
            mat.lightingModel = .physicallyBased
            if fixedFaces.contains(f) {
                mat.diffuse.contents = UIColor(red: 0.2, green: 0.45,
                                               blue: 1.0, alpha: 1.0)
            } else if loadedFaces.contains(f) {
                mat.diffuse.contents = UIColor(red: 1.0, green: 0.45,
                                               blue: 0.1, alpha: 1.0)
            } else {
                mat.diffuse.contents = UIColor(red: 0.85, green: 0.88,
                                               blue: 0.92, alpha: 1.0)
            }
            mat.metalness.contents = 0.1
            mat.roughness.contents = 0.55
            mat.isDoubleSided = true
            materials.append(mat)
        }
        let geometry = SCNGeometry(sources: [posSource, norSource],
                                   elements: elements)
        geometry.materials = materials
        return framedScene(geometry: geometry)
    }

    /// The voxel mesh's boundary surface, vertex-coloured by node
    /// von Mises (blue low -> red high).
    private func makeResultScene(mesh: FemMeshData,
                                 result: FemResultData) -> SCNScene {
        var positions: [SCNVector3] = []
        positions.reserveCapacity(mesh.nodeCount)
        for i in 0 ..< mesh.nodeCount {
            positions.append(SCNVector3(mesh.nodeCoords[3 * i],
                                        mesh.nodeCoords[3 * i + 1],
                                        mesh.nodeCoords[3 * i + 2]))
        }
        let maxVM = Swift.max(result.maxVonMises, 1e-12)
        var colors: [Float] = []
        colors.reserveCapacity(3 * mesh.nodeCount)
        for i in 0 ..< mesh.nodeCount {
            let c = stressColor(result.nodeVM[i] / maxVM)
            colors.append(Float(c.r))
            colors.append(Float(c.g))
            colors.append(Float(c.b))
        }
        var indices: [Int32] = []
        indices.reserveCapacity(6 * mesh.quadCount)
        for q in 0 ..< mesh.quadCount {
            let a = mesh.quads[4 * q], b = mesh.quads[4 * q + 1]
            let c = mesh.quads[4 * q + 2], d = mesh.quads[4 * q + 3]
            indices += [a, b, c, a, c, d]
        }
        let posSource = SCNGeometrySource(vertices: positions)
        var colorData = Data(count: colors.count * MemoryLayout<Float>.size)
        colorData.withUnsafeMutableBytes { raw in
            colors.withUnsafeBufferPointer { buf in
                raw.copyMemory(from: UnsafeRawBufferPointer(buf))
            }
        }
        let colorSource = SCNGeometrySource(
            data: colorData, semantic: .color, vectorCount: mesh.nodeCount,
            usesFloatComponents: true, componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0, dataStride: 3 * MemoryLayout<Float>.size)
        let element = SCNGeometryElement(indices: indices,
                                         primitiveType: .triangles)
        let geometry = SCNGeometry(sources: [posSource, colorSource],
                                   elements: [element])
        let mat = SCNMaterial()
        mat.lightingModel = .constant
        mat.diffuse.contents = UIColor.white
        mat.isDoubleSided = true
        geometry.materials = [mat]
        return framedScene(geometry: geometry)
    }

    /// Blue -> cyan -> green -> yellow -> red ramp, t in [0, 1].
    private func stressColor(_ t: Double) -> (r: Double, g: Double, b: Double) {
        let t = Swift.min(1.0, Swift.max(0.0, t))
        let stops: [(Double, Double, Double)] = [
            (0, 0, 1), (0, 1, 1), (0, 1, 0), (1, 1, 0), (1, 0, 0),
        ]
        let x = t * Double(stops.count - 1)
        let i = Swift.min(stops.count - 2, Int(x))
        let f = x - Double(i)
        let a = stops[i], b = stops[i + 1]
        return (a.0 + (b.0 - a.0) * f,
                a.1 + (b.1 - a.1) * f,
                a.2 + (b.2 - a.2) * f)
    }

    // MARK: formatting

    private func fmt(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 2
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }

    private func fmtDisp(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 4
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }

    private func faceList(_ faces: Set<Int>) -> String {
        if faces.isEmpty { return "none" }
        return faces.sorted().map(String.init).joined(separator: ", ")
    }
}
