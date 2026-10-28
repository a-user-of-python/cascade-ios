import SwiftUI
import SceneKit

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
        .sheet(isPresented: $showImporter) {
            StepImportListView { url in
                showImporter = false
                importFile(url)
            }
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

    /// Import STEP from a file that already lives inside the app
    /// sandbox (Documents or Documents/Inbox, picked from the
    /// in-app import list): the library reads a plain filesystem
    /// path, so the file's own path goes straight through and it
    /// becomes the current body. No document picker is involved —
    /// under some signing setups the system picker cannot run, so
    /// files arrive through the Files app into this app's folder
    /// instead (UIFileSharingEnabled in Info.plist).
    private func importFile(_ url: URL) {
        let name = url.lastPathComponent
        run(status: { r in
            let n = r.solids ?? 0
            let colourNote = r.faceColors != nil
                ? " Shown in the colours from the file."
                : ""
            return "Imported \(name) — \(n) solid\(n == 1 ? "" : "s").\(colourNote) It is now the current body: open the sketch editor, draw, and Finish & Extrude to add or subtract."
        }) {
            try CascadeEngine.importSTEP(path: url.path, name: name, body: currentBody)
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
            // Defensive: the default far plane is 100 — fine for the
            // small demo shapes, but a large imported body would be
            // clipped by it.
            cameraNode.camera?.zNear = 0.1
            cameraNode.camera?.zFar = 10000
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

/// In-app STEP import list: scans Documents/Cascade (seeded at
/// launch by CascadeFolders — the folder Sean copies files into),
/// the Documents root, and Documents/Inbox (where files shared
/// into the app land) for .step / .stp files, newest first. This
/// replaces the system document picker entirely — under some
/// signing setups the picker cannot select files from the Files
/// app, so files are copied into "On My iPad → Cascade Demo →
/// Cascade" in the Files app instead (the app's Documents are
/// shared because Info.plist sets UIFileSharingEnabled +
/// LSSupportsOpeningDocumentsInPlace) and picked here. Every
/// listed file already lives inside the app sandbox, so its path
/// goes straight to the library.
struct StepImportListView: View {
    var onPick: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var files: [StepFileEntry] = []

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 10) {
                Text("Import STEP")
                    .font(.system(size: 28, weight: .bold))
                Spacer()
                Button {
                    scan()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                Button("Done") { dismiss() }
                    .buttonStyle(.bordered)
            }

            if files.isEmpty {
                Spacer()
                Text("No STEP files yet. In the Files app, copy a .step file into On My iPad → Cascade Demo → Cascade, then come back and tap Refresh.")
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
                Spacer()
            } else {
                List(files) { entry in
                    Button {
                        onPick(entry.url)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.name)
                                .font(.headline)
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                            Text(entry.detail)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.plain)
            }
        }
        .padding(16)
        .onAppear(perform: scan)
    }

    private func scan() {
        files = StepFileEntry.scan()
    }
}

/// Folder manager, NOVA-style (the pattern NovaVM uses to get a
/// working folder in the Files app): at app launch, CREATE a named
/// folder tree inside Documents and seed it so nothing is empty —
/// Documents/Cascade/ holds a README and a ready-to-import sample
/// STEP (the sketch plate, exported by the library itself), and
/// Documents/Inbox/ exists for files shared into the app. iOS
/// surfaces the app under Files → On My iPad once the app has run
/// and its Documents actually contain this tree. Everything is
/// idempotent: existing files are never overwritten, so later
/// launches change nothing.
enum CascadeFolders {
    /// Documents/Cascade, the folder Sean copies STEP files into.
    static func cascadeFolder(_ fm: FileManager = .default) -> URL? {
        fm.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Cascade", isDirectory: true)
    }

    static func setup() {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first,
              let cascade = cascadeFolder(fm) else { return }

        try? fm.createDirectory(at: cascade, withIntermediateDirectories: true)
        try? fm.createDirectory(at: docs.appendingPathComponent("Inbox", isDirectory: true),
                                withIntermediateDirectories: true)

        let readme = cascade.appendingPathComponent("README.txt")
        if !fm.fileExists(atPath: readme.path) {
            let text = """
            Cascade — STEP import folder

            Put .step files in this folder — Files app → On My iPad →
            Cascade Demo → Cascade — then open the app and tap Import STEP.

            sample-plate.step is already here: import it in the app to try
            the sketch tools right away.
            """
            try? text.write(to: readme, atomically: true, encoding: .utf8)
        }

        let sample = cascade.appendingPathComponent("sample-plate.step")
        if !fm.fileExists(atPath: sample.path) {
            // Best effort: if the export fails, the README alone
            // still leaves the folder non-empty.
            CascadeEngine.exportSketchPlate(toPath: sample.path)
        }
    }
}

/// One importable STEP file found in the sandbox.
struct StepFileEntry: Identifiable {
    let url: URL
    let name: String
    let detail: String
    let modified: Date
    var id: URL { url }

    /// Documents/Cascade first (the folder CascadeFolders seeds at
    /// launch and Sean copies files into), then the Documents root
    /// and Documents/Inbox — no location a file can land in is a
    /// dead end. .step / .stp only (case-insensitive), newest
    /// modification first.
    static func scan() -> [StepFileEntry] {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return [] }
        var folders: [(url: URL, label: String)] = []
        if let cascade = CascadeFolders.cascadeFolder(fm) {
            folders.append((cascade, "Cascade folder"))
        }
        folders.append((docs, "Documents"))
        folders.append((docs.appendingPathComponent("Inbox", isDirectory: true), "Inbox"))
        let sizeFmt = ByteCountFormatter()
        sizeFmt.countStyle = .file
        let dateFmt = DateFormatter()
        dateFmt.dateStyle = .medium
        dateFmt.timeStyle = .short
        var entries: [StepFileEntry] = []
        for folder in folders {
            guard let items = try? fm.contentsOfDirectory(
                at: folder.url,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]) else { continue }
            for item in items {
                let ext = item.pathExtension.lowercased()
                guard ext == "step" || ext == "stp" else { continue }
                let values = try? item.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey])
                if values?.isRegularFile == false { continue }
                let modified = values?.contentModificationDate ?? .distantPast
                let size = Int64(values?.fileSize ?? 0)
                let detail = "\(sizeFmt.string(fromByteCount: size)) · \(dateFmt.string(from: modified)) · in \(folder.label)"
                entries.append(StepFileEntry(url: item, name: item.lastPathComponent,
                                             detail: detail, modified: modified))
            }
        }
        return entries.sorted { $0.modified > $1.modified }
    }
}
