# CascadePort — the CascadeKit geometry library (Open CASCADE) on iPad, driven by Swift

This repo builds **CascadeKit**: a C++ geometry library built on
the real **Open CASCADE (OCCT) 8.0.1** libraries, plus an iPad app
that hosts it. The architecture, in one sentence:

**Swift drives; Cascade does the geometry.**

The library is C++. Every shape is built by OCCT's own libraries
(primitives, booleans, fillets, shell, tessellation, and STEP
import/export). The library's entire public interface is one
documented C header — `Facade/occt_facade.h` — which only passes
calls and data through to OCCT and catches its errors. No CAD
logic of ours exists in C++; if OCCT has an operation, the library
wraps it instead of approximating it. The app is Swift and calls
the library through a bridging header: it imports STEP files,
keeps a current body, and edits that body with sketches
(add / subtract), all as library calls.

## License

- The `OCCT/` directory is **Open CASCADE Technology 8.0.1**,
  © Open Cascade SAS, licensed under the **GNU LGPL 2.1 with the
  Open CASCADE exception**. The license texts ship in the tree at
  `OCCT/LICENSE_LGPL_21.txt` and `OCCT/OCCT_LGPL_EXCEPTION.txt` and
  must always ship with it.
- The project's own code — `Facade/`, `DemoApp/` and
  `gen_project.py` — is separate work that links the OCCT libraries
  through the façade.
- **No OCCT library sources have been modified.** The single
  generated header, `OCCT/generated/Standard_Version.hxx`, ships
  exactly as OCCT's own build generates it.

## What you get

- **CascadeKit** — a static library target: the OCCT subset sources
  (in `OCCT/`) plus the library façade, compiled as C++17. Its
  public API (see the API map at the top of
  `Facade/occt_facade.h`) covers primitives, profiles, sketches,
  booleans, finishing, queries, a selection census, tessellation,
  and STEP import/export — plus section 11, **FEM**: the library's
  own voxel mesher and linear-static solver (basic stress
  analysis), built on OCCT's geometry queries.
- **CascadeDemo** — a small iPad app that links CascadeKit and
  calls it from Swift through a bridging header. Normal-size
  buttons build shapes; each result is tessellated by OCCT and
  shown in SceneKit with its volume and triangle count. **Import
  STEP** loads a CAD file as the app's current body, and the
  **sketch editor** (MetalCAD's) can then add to or subtract from
  that body.

## Open it and run it on your iPad

1. **Get the repo on your Mac** — clone it, or download the ZIP from
   GitHub and unzip it.
2. **Open `CascadePort.xcodeproj`** in Xcode.
3. **Select the CascadeDemo target**, then **Signing &
   Capabilities**, and pick **your team** (your free Apple ID team
   is fine). The bundle ID is `com.user.cascadedemo`.
4. **Plug in your iPad** (or pick it from the device list at the top
   of the Xcode window).
5. **Press Run (▶)**. Xcode builds everything and installs
   **Cascade Demo** on the iPad. The first build takes a while —
   it compiles about two thousand C++ files.

No GitHub Actions, no extra tools: the Xcode project is complete
and self-contained. It is regenerated (byte-identical) by
`python3 gen_project.py` if ever needed.

## What each button proves

| Button | The trip it makes |
| --- | --- |
| **Box** | Swift → library → `BRepPrimAPI_MakeBox` in OCCT → tessellate → SceneKit. Volume reads **4 000 mm³**. |
| **Filleted box** | The box, then OCCT's own rolling-ball fillet (`BRepFilletAPI_MakeFillet`, radius 2 mm on every edge). Volume drops below 4 000 — a real blend, not a cutter approximation. |
| **Box + cylinder union** | Two OCCT primitives joined by OCCT's boolean engine (`BRepAlgoAPI_Fuse`). |
| **Hollow box (shell)** | OCCT's thick-solid offset (`BRepOffsetAPI_MakeThickSolid`) hollows the box with exact 1.5 mm walls. |
| **Sketch plate with hole** | Sketch entities → OCCT builds the face (`mc_face_from_sketch`) → prism. Volume reads **17 344.3 mm³** (verified on-device, matching the host proof exactly). |
| **Import STEP** | The file is copied into the app sandbox and read by OCCT's own STEP reader (`mc_import_step`) — geometry only, units converted to mm. The imported shape becomes the **current body** (a multi-solid file arrives as one compound; the status line reports its solid count). |
| **Sketch (MetalCAD editor)** | MetalCAD's real 2D sketch editor. **Finish & Extrude** extrudes the sketch through the library; when a current body exists it first asks: **Add to body** (`mc_unite`), **Subtract from body** (`mc_subtract`), or **New shape (standalone)**. The sketch sits on the ground (XZ) plane at the origin, extruded 10 mm — the booleans are world-space, so position your sketch against the body with that in mind. |
| **FEM** | Basic linear stress analysis of the current body (enabled once one exists): tap faces to fix (blue) or load (orange), pick a material (PLA / Aluminum / Steel) and a mesh size, then **Mesh** and **Solve**. The library voxel-meshes the body, assembles the hex8 stiffness matrix and solves it with PCG; the view re-colours by von Mises stress with the maximum stress and displacement in large type. Captioned honestly in the app: "Basic linear stress analysis — voxel mesh." |

Tap-drag in the 3D view to orbit the result.

## Layout

- `OCCT/` — the OCCT 8.0.1 subset (18 toolkits, see `MANIFEST.md`),
  with OCCT's licence files at `OCCT/LICENSE_LGPL_21.txt` and
  `OCCT/OCCT_LGPL_EXCEPTION.txt`.
- `Facade/` — the library's public C API (`occt_facade.h` /
  `occt_facade.cpp`): primitives, prism, revolve, loft, sweep,
  sketches, booleans, fillet, chamfer, shell, tessellation with
  per-face triangle ranges, volume / bounding box / contains
  queries, a selection census, STEP import/export, and the FEM
  section (voxel mesh + basic stress analysis — the project's own
  numerical code, not an OCCT wrap).
- `DemoApp/` — the SwiftUI host app (calls the library and
  displays; hosts MetalCAD's sketch editor).
- `MANIFEST.md` — exactly what was included, the build settings the
  project replicates, and the honest list of what can only be
  verified by the first real Xcode build.
