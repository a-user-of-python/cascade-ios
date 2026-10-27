import SwiftUI

/// Demo host for MetalCAD's real sketch editor.
///
/// `SketchEditorView.swift` in this folder is MetalCAD v1.10's actual
/// 2D sketch editor, copied from the MetalCAD app with ONE change (a
/// taller canvas, marked in place). It edits a `Sketch` value through
/// an `EditorModel`, which in MetalCAD is the document session class.
/// This file provides the demo's stand-in `EditorModel` exposing
/// exactly the five members the editor touches, plus the two small
/// helpers the editor expects from the app side:
///
///   - `mcFmt` — copied verbatim from MetalCAD's EditorView.swift.
///   - `ProjectGeometry.edgeSegments` — extracted from MetalCADKit's
///     Features2.swift. TRIMMED: in the kit it projects a rebuilt
///     body's sharp edges onto the sketch plane. The demo host has no
///     document and no rebuilt body (`rebuild` is always nil), so the
///     editor's Project button takes its built-in "no body" path and
///     this function is never called; its body is a stub for that
///     reason, with the signature unchanged.
///
/// Everything else the editor needs (Sketch, SketchSolver, CADError,
/// MCLog, Mesh, Faces, Tessellation, the mcFont/MCAccent helpers) is
/// the kit/app source copied unchanged into this folder. The constraint solver
/// stays Swift — no kernel ships one; only the sketch's GEOMETRY
/// (profile -> face -> solid) goes through the Cascade façade, in
/// CascadeEngine.sketchExtrude(sketch:).

/// Whole-number-friendly formatting shared by the editor views.
/// (Verbatim from MetalCAD's EditorView.swift.)
func mcFmt(_ v: Double) -> String {
    if v == v.rounded() && abs(v) < 1e15 { return String(Int(v)) }
    return String(format: "%.2f", v)
}

/// Stand-in for MetalCAD's EditorModel: hosts ONE standalone sketch
/// on the XZ ground plane, the plane the demo's Cascade extrude uses
/// (origin 0, +U = +X, +V = +Z, normal -Y; the solid is prismed along
/// the plane normal, so the sketch stands upright in the 3D view).
final class EditorModel: ObservableObject {
    /// Fixed id of the hosted sketch, so the editor and the extrude
    /// hand-off always agree on which sketch they mean.
    static let hostedSketchID = "cascade-demo-sketch"

    /// Shape of `rebuild` in MetalCAD (a result carrying the body
    /// mesh). The demo never rebuilds a body, so this stays nil and
    /// the editor's body-dependent actions report "no body", exactly
    /// as MetalCAD does for an empty document.
    struct RebuildStub {
        var mesh: Mesh
    }

    private var sketches: [String: Sketch] = [:]

    /// Face outlines drawn as guides in the editor. The demo sketch
    /// is not drawn on a solid face, so this stays empty.
    @Published var faceOutlines: [String: [Vec2]] = [:]

    /// Set by the editor's "Finish & Extrude": ContentView watches
    /// for it when the editor dismisses and runs the Cascade extrude.
    @Published var pendingExtrudeSketchID: String?

    /// Always nil in the demo (see RebuildStub).
    var rebuild: RebuildStub? = nil

    init() {
        let sketch = Sketch(id: Self.hostedSketchID, name: "Sketch", plane: .xz)
        sketches[sketch.id] = sketch
    }

    func sketch(withID id: String) -> Sketch? {
        sketches[id]
    }

    func replaceSketch(_ sketch: Sketch) {
        sketches[sketch.id] = sketch
    }
}

/// Extracted from MetalCADKit's Features2.swift — only the one
/// function SketchEditorView calls. See the header note: the body is
/// trimmed because the demo host never supplies a body mesh.
public enum ProjectGeometry {
    public static func edgeSegments(body: Mesh, onto plane: Plane3) -> [(Vec2, Vec2)] {
        []
    }
}
