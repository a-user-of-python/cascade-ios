import SwiftUI
import SceneKit
import UniformTypeIdentifiers

/// Cascade Demo: buttons, each one a direct trip through the
/// CascadeKit library into Open CASCADE, with the tessellated
/// result shown in SceneKit and its volume / triangle count in
/// large type. No geometry logic lives in the app — it calls and
/// displays. "Import STEP" loads a file as the current body, which
/// the sketch editor can then add to / subtract from.
///
/// Layout: the SceneKit view owns the screen (all remaining space,
/// layout priority 1); the buttons are NORMAL iOS size in one
/// compact horizontal row along the bottom — they take only the
/// height a standard button needs.
struct ContentView: View {
    @State private var scene = SCNScene()
    @State private var volumeText = "—"
    @State private var triangleText = "—"
    @State private var statusText = "Tap a button to build a shape with Open CASCADE."
    @State private var isError = false

    /// Hosts the MetalCAD sketch the editor edits (DemoSketchHost).
    @StateObject private var sketchModel = EditorModel()
    @State private var showSketchEditor = false

    /// The current body (set by STEP import; edited by sketches).
    @StateObject private var currentBody = CurrentBody()
    @State private var showImporter = false
    @State private var showFEM = false
    /// A finished sketch waiting for its apply-mode choice (only
    /// used when a current body exists).
    @State private var pendingSketch: Sketch?
    @State private var showExtrudeChoice = false

    var body: some View {
        VStack(spacing: 12) {
            Text("Cascade Demo")
                .font(.system(size: 34, weight: .bold))
                .frame(maxWidth: .infinity, alignment: .leading)

            Text("OCCT \(String(cString: mc_occt_version())) — every shape below is built by the Open CASCADE libraries, called from Swift.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            ModelView(scene: scene)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
                .background(Color(white: 0.12))
                .clipShape(RoundedRectangle(cornerRadius: 16))

            HStack(spacing: 32) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Volume").font(.headline).foregroundStyle(.secondary)
                    Text(volumeText).font(.system(size: 30, weight: .bold, design: .rounded))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Triangles").font(.headline).foregroundStyle(.secondary)
                    Text(triangleText).font(.system(size: 30, weight: .bold, design: .rounded))
                }
                if let label = currentBody.label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Current body").font(.headline).foregroundStyle(.secondary)
                        Text(label).font(.system(size: 22, weight: .semibold, design: .rounded)).lineLimit(1)
                    }
                }
                Spacer()
            }

            Text(statusText)
                .font(.title3)
                .foregroundStyle(isError ? .red : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(3)

            // Normal-size buttons, one compact row (scrolls sideways
            // on a narrow screen instead of growing taller).
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    demoButton("Box", systemImage: "cube") { try CascadeEngine.box() }
                    demoButton("Filleted box", systemImage: "cube.fill") { try CascadeEngine.filletedBox() }
                    demoButton("Box + cylinder union", systemImage: "cylinder") { try CascadeEngine.boxUnionCylinder() }
                    demoButton("Hollow box (shell)", systemImage: "square.dashed") { try CascadeEngine.hollowBox() }
                    demoButton("Sketch plate with hole", systemImage: "square.and.pencil") { try CascadeEngine.sketchPlate() }
                    Button {
                        showImporter = true
                    } label: {
                        Label("Import STEP", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderedProminent)
                    Button {
                        showSketchEditor = true
                    } label: {
                        Label("Sketch (MetalCAD editor)", systemImage: "pencil.and.ruler")
                    }
                    .buttonStyle(.borderedProminent)
                    Button {
                        showFEM = true
                    } label: {
                        Label("FEM", systemImage: "function")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!currentBody.exists)
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            // License attribution — travels with the app.
            Text("Geometry: Open CASCADE Technology 8.0.1 — LGPL 2.1 with the Open CASCADE exception. © Open Cascade SAS.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(2)
        }
        .padding(16)
        .fullScreenCover(isPresented: $showSketchEditor, onDismiss: sketchEditorDismissed) {
            SketchEditorView(model: sketchModel, sketchID: EditorModel.hostedSketchID)
        }
        .fullScreenCover(isPresented: $showFEM) {
            FemPanelView(currentBody: currentBody)
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.data],
                      allowsMultipleSelection: false) { result in
            handleImport(result)
        }
        .confirmationDialog("Apply the sketch to the current body?",
                            isPresented: $showExtrudeChoice, titleVisibility: .visible) {
            Button("Add to body") { extrudePending(.add) }
            Button("Subtract from body") { extrudePending(.subtract) }
            Button("New shape (standalone)") { extrudePending(.standalone) }
            Button("Cancel", role: .cancel) { pendingSketch = nil }
        } message: {
            Text("Your sketch is extruded 10 mm, in place on the ground plane. Add it to \(currentBody.label ?? "the current body"), subtract it, or keep it as a new shape on its own.")
        }
    }

    /// The editor's "Finish & Extrude" sets pendingExtrudeSketchID and
    /// dismisses. With a current body, ask how the extrusion applies
    /// (add / subtract / standalone); without one, it simply extrudes
    /// standalone, as before. A plain dismiss (Done) leaves the flag
    /// unset and changes nothing here.
    private func sketchEditorDismissed() {
        guard let id = sketchModel.pendingExtrudeSketchID else { return }
        sketchModel.pendingExtrudeSketchID = nil
        guard let sketch = sketchModel.sketch(withID: id) else { return }
        if currentBody.exists {
            pendingSketch = sketch
            showExtrudeChoice = true
        } else {
            run { try CascadeEngine.sketchExtrude(sketch: sketch, mode: .standalone, body: currentBody) }
        }
    }

    private func extrudePending(_ mode: CascadeEngine.ExtrudeMode) {
        guard let sketch = pendingSketch else { return }
        pendingSketch = nil
        run(status: { _ in
            switch mode {
            case .add: return "Added the sketch extrusion to the current body."
            case .subtract: return "Subtracted the sketch extrusion from the current body."
            case .standalone: return "Built the sketch as a new shape. The current body is unchanged."
            }
        }) {
            try CascadeEngine.sketchExtrude(sketch: sketch, mode: mode, body: currentBody)
        }
    }

    /// Import STEP: copy the picked file into the app sandbox (the
    /// library reads a plain filesystem path), then import it as
    /// the current body through the library.
    private func handleImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else {
            if case .failure(let e) = result {
                statusText = "Import cancelled or failed: \(e.localizedDescription)"
                isError = true
            }
            return
        }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let dst = FileManager.default.temporaryDirectory
                .appendingPathComponent(url.lastPathComponent)
            if FileManager.default.fileExists(atPath: dst.path) {
                try FileManager.default.removeItem(at: dst)
            }
            try FileManager.default.copyItem(at: url, to: dst)
            let name = url.lastPathComponent
            run(status: { r in
                let n = r.solids ?? 0
                return "Imported \(name) — \(n) solid\(n == 1 ? "" : "s"). It is now the current body: open the sketch editor, draw, and Finish & Extrude to add or subtract."
            }) {
                try CascadeEngine.importSTEP(path: dst.path, name: name, body: currentBody)
            }
        } catch {
            statusText = "Couldn't read that file: \(error.localizedDescription)"
            isError = true
        }
    }

    private func demoButton(_ title: String, systemImage: String,
                            action: @escaping () throws -> CascadeEngine.Result) -> some View {
        Button {
            run(action)
        } label: {
            Label(title, systemImage: systemImage)
        }
        .buttonStyle(.borderedProminent)
    }

    private func run(status: ((CascadeEngine.Result) -> String)? = nil,
                     _ action: () throws -> CascadeEngine.Result) {
        do {
            let result = try action()
            let newScene = SCNScene()
            newScene.background.contents = UIColor(white: 0.12, alpha: 1)

            let cameraNode = SCNNode()
            cameraNode.camera = SCNCamera()
            cameraNode.position = SCNVector3(34, 30, 38)
            cameraNode.look(at: SCNVector3(0, 4, 0))
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

            newScene.rootNode.addChildNode(result.node)
            scene = newScene

            let fmt = NumberFormatter()
            fmt.numberStyle = .decimal
            fmt.maximumFractionDigits = 1
            volumeText = (fmt.string(from: NSNumber(value: result.volume)) ?? "\(result.volume)") + " mm³"
            triangleText = "\(result.triangles)"
            statusText = status?(result) ?? "Built by OCCT: \(result.faces) faces, tessellated at 0.1 mm deflection."
            isError = false
        } catch let CascadeEngine.EngineError.occt(message) {
            statusText = "OCCT error: \(message)"
            isError = true
        } catch {
            statusText = "Error: \(error.localizedDescription)"
            isError = true
        }
    }
}

struct ModelView: UIViewRepresentable {
    var scene: SCNScene

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false
        view.backgroundColor = UIColor(white: 0.12, alpha: 1)
        view.scene = scene
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        uiView.scene = scene
    }
}
