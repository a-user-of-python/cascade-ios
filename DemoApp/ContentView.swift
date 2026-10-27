import SwiftUI
import SceneKit

/// Cascade Demo: buttons, each one a direct trip through the façade
/// into Open CASCADE, with the tessellated result shown in SceneKit
/// and its volume / triangle count in large type. No geometry logic
/// lives in the app — it calls and displays.
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
                        showSketchEditor = true
                    } label: {
                        Label("Sketch (MetalCAD editor)", systemImage: "pencil.and.ruler")
                    }
                    .buttonStyle(.borderedProminent)
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
    }

    /// The editor's "Finish & Extrude" sets pendingExtrudeSketchID and
    /// dismisses; run the Cascade extrude on the hosted sketch through
    /// the same result path as the demo buttons. A plain dismiss
    /// (Done) leaves the flag unset and changes nothing here.
    private func sketchEditorDismissed() {
        guard let id = sketchModel.pendingExtrudeSketchID else { return }
        sketchModel.pendingExtrudeSketchID = nil
        guard let sketch = sketchModel.sketch(withID: id) else { return }
        run { try CascadeEngine.sketchExtrude(sketch: sketch) }
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

    private func run(_ action: () throws -> CascadeEngine.Result) {
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
            statusText = "Built by OCCT: \(result.faces) faces, tessellated at 0.1 mm deflection."
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
