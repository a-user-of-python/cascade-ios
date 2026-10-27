# CascadePort — Open CASCADE on iPad, driven by Swift

This repo puts the real **Open CASCADE (OCCT) 8.0.1** geometry
libraries inside an iPad app. The architecture, in one sentence:

**Swift drives; Cascade does the geometry.**

The app is Swift. Every shape is built by OCCT's own C++ libraries
(primitives, booleans, fillets, shell, tessellation). Between them
sits one thin layer — `Facade/occt_facade.h` — a C interface that
only passes calls and data through to OCCT and catches its errors.
No CAD logic of ours exists in C++; if OCCT has an operation, the
façade wraps it instead of approximating it.

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
  (in `OCCT/`) plus the façade, compiled as C++17.
- **CascadeDemo** — a small iPad app that links CascadeKit and calls
  the façade from Swift through a bridging header. Four big buttons
  build four shapes; each result is tessellated by OCCT and shown in
  SceneKit with its volume and triangle count.

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
| **Box** | Swift → façade → `BRepPrimAPI_MakeBox` in OCCT → tessellate → SceneKit. Volume reads **4 000 mm³**. |
| **Filleted box** | The box, then OCCT's own rolling-ball fillet (`BRepFilletAPI_MakeFillet`, radius 2 mm on every edge). Volume drops below 4 000 — a real blend, not a cutter approximation. |
| **Box + cylinder union** | Two OCCT primitives joined by OCCT's boolean engine (`BRepAlgoAPI_Fuse`). |
| **Hollow box (shell)** | OCCT's thick-solid offset (`BRepOffsetAPI_MakeThickSolid`) hollows the box with exact 1.5 mm walls. |

Tap-drag in the 3D view to orbit the result.

## Layout

- `OCCT/` — the OCCT 8.0.1 subset (15 toolkits, see `MANIFEST.md`),
  with OCCT's licence files at `OCCT/LICENSE_LGPL_21.txt` and
  `OCCT/OCCT_LGPL_EXCEPTION.txt`.
- `Facade/` — the thin C pass-through (`occt_facade.h` /
  `occt_facade.cpp`): primitives, prism, revolve, loft, sweep,
  booleans, fillet, chamfer, shell, tessellation with per-face
  triangle ranges, volume / bounding box / contains queries.
- `DemoApp/` — the SwiftUI demo (call-and-display only).
- `MANIFEST.md` — exactly what was included, the build settings the
  project replicates, and the honest list of what can only be
  verified by the first real Xcode build.
