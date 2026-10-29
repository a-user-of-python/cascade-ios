// ============================================================================
// CascadeKit — geometry library for the Cascade apps
// Public C API  (this header is the library's entire public interface)
// ============================================================================
//
// CascadeKit is a C++ library built on the Open CASCADE Technology
// (OCCT) 8.0.1 libraries. It packages OCCT's modelling toolkits plus
// this façade into one static library (the `CascadeKit` target); the
// host app links the library and calls only the functions declared
// here. The header is plain C so any host language with a C FFI
// (the apps use Swift through a bridging header) can consume it.
//
// ARCHITECTURE PRINCIPLE (Sean's rule): the host app drives; Cascade
// does the geometry. The app decides WHAT to build; OCCT's own
// libraries do ALL the geometry. Sections 1–10 of this façade
// therefore contain no CAD feature logic and no geometry math of
// their own — each function only translates arguments and buffers
// across the C ABI, calls the corresponding OCCT operation,
// translates the result back, and catches every OCCT exception so
// none crosses the boundary (failures come back as error codes +
// mc_last_error()). Section 11 (FEM) is the documented exception:
// the project's own mesh + solver code, built on OCCT queries.
//
// If an operation exists in OCCT, it is wrapped here rather than
// approximated. Handles are opaque; no C++ type crosses the ABI.
//
// CONVENTIONS
// - Units are millimetres and radians everywhere (angles noted
//   per-function where they differ).
// - Every function that can fail takes a trailing `int* err`
//   out-parameter (which may be NULL) and stores an MCFacadeError
//   code there; handle-returning functions return NULL on failure,
//   value-returning functions return the code itself. After any
//   failure, mc_last_error() describes it in words.
// - Ownership: a returned MCFacadeShape* is owned by the caller and
//   released with mc_free_shape(); a returned MCFacadeMesh's buffers
//   are released with mc_free_mesh(). Input handles are never
//   consumed — boolean/finishing operations leave their inputs
//   unchanged and return new handles.
// - Index spaces: face / edge / vertex indices are shared by the
//   census, tessellation and finishing sections (see "Selection
//   census") for as long as the shape handle is unchanged.
//
// API MAP
//   1. Handles, errors, lifecycle .... MCFacadeShape, mc_free_shape
//   2. Primitives .................... mc_box, mc_cylinder, ...
//   3. Profiles ...................... mc_prism, mc_revolve, ...
//   4. Sketches ...................... mc_face_from_sketch, mc_prism_face
//   5. Booleans ...................... mc_unite, mc_subtract, mc_intersect
//   6. Finishing ..................... mc_fillet, mc_chamfer, mc_shell
//   7. Queries ....................... mc_volume, mc_bbox, mc_contains, ...
//   8. Selection census .............. mc_shape_counts, mc_face_info, ...
//   9. Tessellation .................. mc_tessellate, mc_free_mesh
//  10. Import / export (STEP) ........ mc_import_step, mc_export_step,
//                                      mc_export_step_bodies,
//                                      mc_export_step_xde
//  11. FEM (mesh + stress analysis) .. mc_fem_mesh, mc_fem_solve, ...
//  12. Threads ....................... mc_thread
//
// Sections 1–10 are the pass-through described above. Section 11
// (FEM) is the deliberate exception: it is the project's OWN
// numerical code — a voxel mesher and a linear-static solver —
// built on top of OCCT geometry queries (classification, distance,
// census). It is documented as such in its section.
//
// LICENCE: the library's OCCT part is Open CASCADE Technology
// 8.0.1, (c) Open Cascade SAS, GNU LGPL 2.1 with the Open CASCADE
// exception (texts at OCCT/LICENSE_LGPL_21.txt and
// OCCT/OCCT_LGPL_EXCEPTION.txt in this repo). This façade is the
// project's own code. No OCCT library source is modified.
#pragma once

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// ============================================================================
// 1. Handles, errors, lifecycle
// ============================================================================

/// Opaque shape handle (wraps a TopoDS_Shape). The struct is given a
/// complete definition — a single façade-private pointer — because
/// Swift's ClangImporter does not import incomplete C structs: with
/// only a forward declaration, Swift cannot name the type at all
/// ("cannot find type 'MCFacadeShape' in scope"). The pointer is an
/// implementation detail; callers must treat the handle as opaque.
typedef struct MCFacadeShape {
  void* _impl;  ///< façade-private (points to a TopoDS_Shape)
} MCFacadeShape;

typedef enum MCFacadeError {
  MC_OK = 0,
  MC_ERR_INVALID_ARG = 1,  ///< null handle / bad parameter
  MC_ERR_OCCT = 2,         ///< OCCT exception or failed operation
  MC_ERR_EMPTY_RESULT = 3, ///< operation produced a null shape
  MC_ERR_FEM_SINGULAR = 4, ///< FEM: stiffness is singular (the part
                           ///< is not fixed enough — rigid-body
                           ///< motion remains) or a solve breakdown
  MC_ERR_FEM_NO_CONVERGE = 5, ///< FEM: PCG hit the iteration cap
                              ///< without reaching the tolerance
} MCFacadeError;

/// Human-readable message for the most recent failure (static
/// storage; overwritten by the next failing call).
const char* mc_last_error(void);

/// OCCT version string of the linked libraries, e.g. "8.0.1".
const char* mc_occt_version(void);

/// Release a shape handle obtained from any function in this header.
/// NULL is accepted and does nothing.
void mc_free_shape(MCFacadeShape* s);

// ============================================================================
// 2. Primitives
// ============================================================================
// Direct wraps of BRepPrimAPI_MakeBox / MakeCylinder / MakeSphere /
// MakeCone.

/// Box with a corner at the origin, extending +X/+Y/+Z.
MCFacadeShape* mc_box(double w, double d, double h, int* err);
/// Cylinder: circular base on the XY plane at z=0, axis +Z, height h.
MCFacadeShape* mc_cylinder(double r, double h, int* err);
/// Sphere centred on the origin.
MCFacadeShape* mc_sphere(double r, int* err);
/// Cone: base radius r1 at z=0, top radius r2 at z=h, axis +Z.
MCFacadeShape* mc_cone(double r1, double r2, double h, int* err);
/// Torus: ring of radius `ringRadius` in the XY plane around the
/// Z axis (centred on the origin), tube radius `tubeRadius`.
/// (BRepPrimAPI_MakeTorus — added for the MetalCAD full-OCCT
/// migration; the kit's torus primitive has the same convention.)
MCFacadeShape* mc_torus(double ringRadius, double tubeRadius, int* err);

// ============================================================================
// 3. Profiles
// ============================================================================
// A profile is a planar polygon: `xy` holds `n` 2D points (u,v
// pairs). The profile plane is given by `origin` and the `xAxis` /
// `yAxis` 3D directions (a profile point (u,v) maps to
// origin + u*xAxis + v*yAxis; axes are normalised internally, which
// is data translation, not geometry logic). The polygon is closed
// automatically.

/// BRepPrimAPI_MakePrism: extrude the profile along `dir` for
/// `dist` mm.
MCFacadeShape* mc_prism(const double* xy, int n,
                        const double origin[3], const double xAxis[3],
                        const double yAxis[3], const double dir[3],
                        double dist, int* err);

/// BRepPrimAPI_MakeRevol: revolve the profile around the axis
/// through `axisPoint` along `axisDir`, by `angleDeg` degrees
/// (360 = full revolve).
MCFacadeShape* mc_revolve(const double* xy, int n,
                          const double origin[3], const double xAxis[3],
                          const double yAxis[3], const double axisPoint[3],
                          const double axisDir[3], double angleDeg, int* err);

/// BRepOffsetAPI_ThruSections: loft a solid through `profileCount`
/// polygon profiles, each on its own plane (origins / xAxes / yAxes
/// hold 3 doubles per profile; profilesXY / profileCounts describe
/// each profile's points). `ruled` != 0 selects ruled (straight)
/// interpolation between sections instead of smooth.
MCFacadeShape* mc_loft(const double* const* profilesXY,
                       const int* profileCounts, int profileCount,
                       const double* origins, const double* xAxes,
                       const double* yAxes, int ruled, int* err);

/// BRepOffsetAPI_MakePipe: sweep the profile along a path made of
/// `pathCount` 3D points (3 doubles each) joined as a polyline
/// spine.
MCFacadeShape* mc_sweep(const double* xy, int n,
                        const double origin[3], const double xAxis[3],
                        const double yAxis[3], const double* pathPts,
                        int pathCount, int* err);

// ============================================================================
// 4. Sketches
// ============================================================================
// A sketch is a set of 2D entities on a plane: line segments,
// circles and circular arcs, grouped into closed profiles. The
// entities are built as real OCCT objects (gp_Circ / Geom curves,
// BRepBuilderAPI_MakeEdge / MakeWire / MakeFace on a gp_Pln) — the
// façade only sequences the calls and translates the arrays.

/// Sketch entity kinds (the `entityTypes` values below).
typedef enum MCSketchEntityType {
  MC_SKETCH_LINE = 0,   ///< data: x1, y1, x2, y2
  MC_SKETCH_CIRCLE = 1, ///< data: cx, cy, r — a complete closed profile
  MC_SKETCH_ARC = 2,    ///< data: cx, cy, r, startAngle, endAngle
                        ///< (radians, counter-clockwise)
} MCSketchEntityType;

/// Doubles per entity in the flat `entityData` array of
/// mc_face_from_sketch. Unused slots are ignored (pass 0).
#define MC_SKETCH_DATA_STRIDE 6

/// Build a planar FACE from sketch entities (BRepBuilderAPI_MakeFace
/// on the sketch plane).
///
/// Plane: `origin` is a 3D point on the plane, `normal` its normal,
/// `xDir` the direction of the sketch's +U axis (the +V axis is
/// normal x xDir, so (u, v) maps to origin + u*xDir + v*YDir; axes
/// are normalised internally — data translation).
///
/// Entities: `entityTypes[i]` is the kind of entity i (see
/// MCSketchEntityType); its parameters are the MC_SKETCH_DATA_STRIDE
/// doubles at `entityData + MC_SKETCH_DATA_STRIDE * i`, in sketch
/// (u, v) coordinates / radians as listed above. An arc's sweep is
/// counter-clockwise from startAngle to endAngle (wrapping past
/// 2*pi if needed) and must be less than a full turn — pass a
/// MC_SKETCH_CIRCLE entity for a full circle. A circle entity must
/// be the ONLY entity of its profile.
///
/// Profiles: `profileStarts` holds `profileCount + 1` indices:
/// profile p spans entities [profileStarts[p], profileStarts[p+1]),
/// profileStarts[0] == 0 and profileStarts[profileCount] ==
/// entityCount. Profile 0 is the outer profile; any further
/// profiles are holes cut into it. Describe every profile in the
/// SAME orientation (counter-clockwise around the plane normal for
/// a normal-facing face): OCCT represents a hole by an
/// oppositely-oriented wire, and the façade reverses hole wires
/// internally — that is B-rep representation translation, done for
/// you. Entities within a profile may be
/// in ANY order — they are connected end to end (endpoint match
/// within 1e-6 mm) before the wire is built. Every profile must
/// form a single closed loop; an open or disconnected profile is an
/// error (MC_ERR_INVALID_ARG), never a bogus face.
MCFacadeShape* mc_face_from_sketch(const double origin[3],
                                   const double normal[3],
                                   const double xDir[3],
                                   const int* entityTypes,
                                   const double* entityData, int entityCount,
                                   const int* profileStarts, int profileCount,
                                   int* err);

/// BRepPrimAPI_MakePrism of a FACE handle (e.g. from
/// mc_face_from_sketch) along `dir` for `dist` mm — the sketch-based
/// counterpart of mc_prism, which only takes polygon profiles.
MCFacadeShape* mc_prism_face(MCFacadeShape* face, const double dir[3],
                             double dist, int* err);

// ============================================================================
// 5. Booleans
// ============================================================================
// Direct wraps of BRepAlgoAPI_Fuse / Cut / Common. Inputs are left
// unchanged; the result is a new handle the caller owns.

MCFacadeShape* mc_unite(MCFacadeShape* a, MCFacadeShape* b, int* err);
MCFacadeShape* mc_subtract(MCFacadeShape* a, MCFacadeShape* b, int* err);
MCFacadeShape* mc_intersect(MCFacadeShape* a, MCFacadeShape* b, int* err);

// ============================================================================
// 6. Finishing (edge operations + shell)
// ============================================================================

/// Edge indices are 0-based positions in the shape's edge
/// enumeration — the shared census index space defined in the
/// "selection census" section below (TopExp traversal order, the
/// order mc_shape_counts / mc_edge_info / mc_edge_count report).
/// Pass edgeIndices == NULL (or edgeCount <= 0) to apply to ALL
/// edges; a non-null list applies to ONLY the listed edges — the
/// list parameter IS the selective form (there are deliberately
/// no separate *_edges functions).

/// BRepFilletAPI_MakeFillet with a constant radius.
MCFacadeShape* mc_fillet(MCFacadeShape* s, double radius,
                         const int* edgeIndices, int edgeCount, int* err);
/// BRepFilletAPI_MakeChamfer, symmetric (equal distances).
MCFacadeShape* mc_chamfer(MCFacadeShape* s, double dist,
                          const int* edgeIndices, int edgeCount, int* err);

/// BRepFilletAPI_MakeChamfer, two-distance (asymmetric): `distA`
/// is measured along "face A" of each edge, `distB` along the
/// other face. Face A is DEFINED as the adjacent face with the
/// lower census index (the shared face enumeration of section 8)
/// — a stored document carries no other face reference for an
/// asymmetric chamfer, so the convention is fixed here and in the
/// kit. An edge without exactly two adjacent faces fails.
MCFacadeShape* mc_chamfer2(MCFacadeShape* s, double distA, double distB,
                           const int* edgeIndices, int edgeCount, int* err);

/// BRepOffsetAPI_MakeThickSolid: closed hollow solid — the shape
/// offset inward by `thickness` mm, no faces removed (no openings).
MCFacadeShape* mc_shell(MCFacadeShape* s, double thickness, int* err);

/// Draft (taper) the shape's side faces for mold release:
/// BRepOffsetAPI_DraftAngle applied to every planar / cylindrical
/// / conical face that is not a cap perpendicular to the pull
/// direction (faces whose normal is parallel to `pullDir` are the
/// caps and are left alone; they move with their neighbours). The
/// neutral plane passes through `neutralPoint` perpendicular to
/// `pullDir`; faces rotate about their intersection with it.
/// A POSITIVE `angleDeg` narrows the solid on the +pullDir side of
/// the neutral plane (material removed there), a negative angle
/// widens it — the convention the kit's draft and tapered extrude
/// already use. Added for the MetalCAD full-OCCT migration.
MCFacadeShape* mc_draft(MCFacadeShape* s, const double pullDir[3],
                        double angleDeg, const double neutralPoint[3],
                        int* err);

// ============================================================================
// 6b. Transforms
// ============================================================================

/// Apply a general linear map + translation: p' = R * p + t, with
/// `m` holding 12 doubles in row-major order
/// [r00 r01 r02 tx, r10 r11 r12 ty, r20 r21 r22 tz]. Covers rigid
/// motion, uniform and non-uniform scale, and mirror (negative
/// determinant) in one wrapper (copy semantics: the input handle
/// is left unchanged and the result is a new handle). Two paths:
/// a similarity (rigid / mirror / uniform scale) goes through
/// gp_Trsf + BRepBuilderAPI_Transform, which preserves the
/// analytic surfaces and curves exactly; anything else
/// (non-uniform scale, shear) goes through gp_GTrsf +
/// BRepBuilderAPI_GTransform, which converts surfaces and curves
/// to BSplines — geometrically faithful (bounds exact) but its
/// curved-face volume integration drifts (~+0.9% on a cylinder)
/// and census curve types become "other". Added for the MetalCAD
/// full-OCCT migration (patterns, mirror, move/scale, primitive
/// placement); the similarity path arrived with Stage 5.
MCFacadeShape* mc_transform(MCFacadeShape* s, const double m[12],
                            int* err);

// ============================================================================
// 7. Queries
// ============================================================================

/// BRepGProp volume of the shape (mm^3).
double mc_volume(MCFacadeShape* s, int* err);
/// BRepGProp::SurfaceProperties area of the shape (mm^2) — for a
/// face handle this is the face's own area; for a shape with
/// several faces it is their total. Swift uses it to validate
/// sketch profiles before extruding them.
double mc_face_area(MCFacadeShape* s, int* err);
/// BRepBndLib bounding box: writes xmin, ymin, zmin, xmax, ymax,
/// zmax into out[6].
int mc_bbox(MCFacadeShape* s, double out[6], int* err);
/// Number of edges in the shape (the index space of fillet/chamfer).
int mc_edge_count(MCFacadeShape* s, int* err);
/// BRepClass3d_SolidClassifier: 1 when the point is strictly inside
/// a solid of the shape, 0 when outside or on the boundary, -1 on
/// error (*err set). Shapes without a solid report MC_ERR_OCCT.
int mc_contains(MCFacadeShape* s, double x, double y, double z, int* err);

// ============================================================================
// 8. Selection census
// ============================================================================
// Index spaces. Faces, edges and vertices are enumerated in
// TopExp traversal order over the shape: each distinct sub-shape
// is taken at its first occurrence (the enumeration
// TopExp::MapShapes records, built on TopExp_Explorer). ALL
// index-based functions in this façade share these spaces, so
// indices line up across calls for as long as the shape handle
// is unchanged: face i below is the face whose triangles form
// range i of mc_tessellate; edge i below is edge i of
// mc_fillet / mc_chamfer, and mc_edge_count counts the same
// space. Swift enumerates a shape once through these functions,
// then drives selection, picking and edge finishing by index.
//
// The three functions below return MC_OK on success and an
// MC_ERR_* code (also stored to *err) on failure — a bad index
// is MC_ERR_INVALID_ARG, never a crash. Any output pointer may
// be NULL to skip that output.

/// The census: number of faces / edges / vertices of the shape
/// (TopExp::MapShapes extents).
int mc_shape_counts(MCFacadeShape* s, int* faces, int* edges,
                    int* vertices, int* err);

/// Per-face info for face `faceIndex` (census order): `area`
/// (mm^2) and area centroid `center` via
/// BRepGProp::SurfaceProperties; `isPlanar` is 1 when the face's
/// surface is a plane (BRepAdaptor_Surface), and `normal` is
/// then the face's outward normal (the plane axis, flipped when
/// the face's stored orientation is reversed). For a non-planar
/// face `normal` is (0, 0, 0).
int mc_face_info(MCFacadeShape* s, int faceIndex, double* area,
                 double center[3], double normal[3], int* isPlanar,
                 int* err);

/// The sketch plane of a PLANAR census face: `origin` is the
/// underlying plane's location (a point ON the plane), `xDir` /
/// `yDir` are the plane surface's own axes (unit, orthonormal),
/// chosen so that xDir x yDir is the face's OUTWARD normal (the
/// same normal `mc_face_info` reports): for a face whose stored
/// orientation is reversed, `yDir` is negated relative to the
/// surface's own Y axis. A sketch built on (origin, xDir, yDir)
/// lies exactly on the face, and extruding it along the outward
/// normal grows material away from the body. A NON-planar face is
/// refused with MC_ERR_INVALID_ARG ("face is not planar") — this
/// function never substitutes a tangent plane. Any output pointer
/// may be NULL to skip that output.
int mc_face_plane(MCFacadeShape* s, int faceIndex, double origin[3],
                  double xDir[3], double yDir[3], int* err);

/// Per-edge info for edge `edgeIndex` (census order): `curveType`
/// is 0 = line, 1 = circle, 2 = other
/// (BRepAdaptor_Curve); `length` via BRepGProp::LinearProperties
/// (OCCT 8.0.1's name for the edge-properties entry point);
/// `start` / `end` are the points of the edge's first / last
/// vertex in traversal orientation. `center` / `radius` are the
/// circle's own, and are only meaningful when curveType == 1 —
/// for any other curve they are (0, 0, 0) and 0.
int mc_edge_info(MCFacadeShape* s, int edgeIndex, int* curveType,
                 double* length, double start[3], double end[3],
                 double center[3], double* radius, int* err);

/// Per-face surface colours, in the census face index space.
/// Only handles returned by mc_import_step can carry colours:
/// the import also reads the file through OCCT's XDE document
/// layer (STEPCAFControl_Reader, colours enabled) and matches
/// XCAFDoc_ColorTool surface colours onto this shape's census
/// faces — a face-level colour when the document assigns one to
/// that face, otherwise the colour of the solid that contains
/// the face. The two reads produce different shape instances, so
/// the match is geometric (face area + centroid, then solid
/// containment) — exact STEP colours land on the exact faces for
/// ordinary files, proven by the host test suite with a
/// two-solid coloured file.
///
/// `outRGB` receives 3 doubles per census face (red, green, blue
/// in 0..1); `outHasColor` receives 1 int per face: 1 when the
/// file gave this face a colour, 0 otherwise (outRGB then 0).
/// Both arrays are caller-allocated with room for the face count
/// from mc_shape_counts; either may be NULL to skip it. Shapes
/// that did not come from mc_import_step (and imports whose file
/// carried no colours) succeed with every hasColor = 0. Returns
/// MC_OK on success.
int mc_shape_face_colors(MCFacadeShape* s, double* outRGB,
                         int* outHasColor, int* err);

// ============================================================================
// 9. Tessellation
// ============================================================================

/// Caller-visible tessellation result (BRepMesh_IncrementalMesh +
/// Poly_Triangulation readback). positions/normals are 3 floats per
/// vertex; indices are 3 ints per triangle. Vertices are duplicated
/// per face so the per-face ranges are exact.
///
/// Per-face ranges: triangles are appended face by face, so
/// triangles [faceTriStart[f], faceTriStart[f]+faceTriCount[f])
/// belong to B-rep face f (faces in TopExp traversal order). This
/// is the mapping MetalCAD needs for face picking / sketch-on-face.
typedef struct MCFacadeMesh {
  float* positions;
  float* normals;
  int* indices;
  int vertexCount;
  int triangleCount;
  int* faceTriStart;
  int* faceTriCount;
  int faceCount;
} MCFacadeMesh;

/// Triangulate with a linear deflection of `deflectionMM`.
/// Returns MC_OK and fills `out` on success.
int mc_tessellate(MCFacadeShape* s, double deflectionMM, MCFacadeMesh* out,
                  int* err);
void mc_free_mesh(MCFacadeMesh* m);

// ============================================================================
// 10. Import / export — STEP
// ============================================================================
// Direct wraps of OCCT's STEP data-exchange reader/writer
// (STEPControl_Reader / STEPControl_Writer, the libraries' own
// ops). STEP is the first exchange format. The reader transfers
// geometry; in addition, mc_import_step runs a second read of the
// same file through OCCT's XDE document layer
// (STEPCAFControl_Reader + XCAFDoc_ColorTool) and remembers the
// file's surface colours per census face — query them with
// mc_shape_face_colors() in section 8. Product names and
// assembly-document structure are still NOT imported: an imported
// multi-part file arrives as one compound shape, not as a named
// assembly.

/// Read a STEP file (AP203 / AP214 / AP242) from the filesystem
/// path `path` (UTF-8) and return its shape. All of the file's
/// roots are transferred and combined the way OCCT's reader
/// combines them (OneShape): a file holding several solids yields
/// a compound handle. When `solidCount` is non-NULL it receives
/// the number of solids (TopAbs_SOLID sub-shapes) inside the
/// result, so the caller can tell a single solid from a
/// multi-solid compound. The reader converts the file's units to
/// millimetres (OCCT's own behaviour).
///
/// Errors: a missing/unreadable file or a file the reader rejects
/// is MC_ERR_OCCT; a file that reads but contains no shape is
/// MC_ERR_EMPTY_RESULT. Never returns a partial shape.
MCFacadeShape* mc_import_step(const char* path, int* solidCount, int* err);

/// Write the shape to a STEP file at `path` (UTF-8), AP214 format
/// as OCCT's writer produces it (STEPControl_AsIs: solids stay
/// solids, compounds stay compounds), lengths in millimetres.
/// Returns MC_OK on success. The counterpart of mc_import_step —
/// a shape written and re-imported keeps its volume, bounding box
/// and solid count (proven by the library's host test suite).
int mc_export_step(MCFacadeShape* s, const char* path, int* err);

/// Write SEVERAL shapes to one STEP file at `path`: the shapes
/// are assembled into a single TopoDS_Compound (representation
/// only — no geometry is computed) and written with the same
/// STEPControl_Writer settings as mc_export_step. A multi-solid
/// file written this way re-imports through mc_import_step as one
/// compound handle whose solidCount is the total number of solids
/// across all inputs — the symmetric counterpart of the import.
/// `count` must be >= 1 and every entry non-NULL, otherwise
/// MC_ERR_INVALID_ARG. With count == 1 this is mc_export_step.
int mc_export_step_bodies(MCFacadeShape* const* shapes, int count,
                          const char* path, int* err);

/// Write shapes to a STEP file at `path` through OCCT's XDE
/// document layer (STEPCAFControl_Writer, colour mode on), so the
/// file carries a SURFACE COLOUR per solid — the one thing
/// STEPControl_Writer cannot emit — plus a product name.
///
/// Each input shape contributes its solids: every solid becomes
/// its own labelled free shape in the XDE document (a shape with
/// no solids is added as-is), labelled `name` (when non-NULL) and
/// coloured with `rgbPerShape` — 3 doubles (red, green, blue in
/// 0..1) per INPUT shape, applied to every solid that shape
/// contributes. `rgbPerShape` may be NULL to write no colours.
/// A file written this way re-imports through mc_import_step with
/// its per-face colours readable via mc_shape_face_colors (the
/// import's colour matching is geometric, so the colour of a
/// solid lands on that solid's census faces). Returns MC_OK on
/// success.
int mc_export_step_xde(MCFacadeShape* const* shapes, int count,
                       const double* rgbPerShape, const char* name,
                       const char* path, int* err);

// ============================================================================
// 11. FEM — voxel mesh + basic stress analysis
// ============================================================================
// This section is the project's OWN numerical code — the one place
// the library computes something itself instead of wrapping an
// OCCT operation. OCCT supplies the geometry queries it stands on
// (solid classification for meshing, point-to-face distance for
// face mapping, the census for face indices); the mesher, the
// element formulation and the solver are CascadeKit code.
//
// METHOD, stated plainly — this is a BASIC linear analysis:
// - Mesh: a uniform voxel grid over the shape's bounding box. A
//   cell is kept when its CENTRE classifies inside the solid
//   (BRepClass3d_SolidClassifier), so boundaries come out
//   stair-stepped and features thinner than the voxel size can
//   vanish entirely. Kept cells are 8-node trilinear hexahedra
//   (hex8) sharing grid nodes. Compare mc_fem_mesh_volume()
//   against mc_volume() of the solid: a large drift is the
//   visible symptom of lost thin features.
// - Element: hex8 trilinear, full 2x2x2 Gauss integration,
//   isotropic linear elasticity. Every element is the same cube,
//   so one stiffness matrix serves the whole mesh (exact for this
//   mesh, not an approximation).
// - Assembly + solve: the stiffness matrix is fully assembled
//   into compressed sparse row form (3x3 nodal blocks) and solved
//   with preconditioned conjugate gradients (Jacobi
//   preconditioner), relative residual tolerance 1e-8, iteration
//   cap 10000. Linear statics, small displacements — nothing
//   else. A system that is not fixed enough is singular and
//   fails with MC_ERR_FEM_SINGULAR, never a garbage result.
// - Loads / fixity are defined on B-rep faces (census indices,
//   the shared index space of section 8) and mapped to mesh
//   surface nodes by mc_fem_nodes_on_face. A face's total load
//   is spread evenly over its mapped nodes.
// Units: mm, N, MPa (Young's modulus in MPa = N/mm^2),
// displacements in mm, von Mises stress in MPa.

/// Opaque FEM mesh handle (same complete-struct pattern as
/// MCFacadeShape, for Swift's ClangImporter).
typedef struct MCFacadeFemMesh {
  void* _impl;  ///< façade-private
} MCFacadeFemMesh;

/// Opaque FEM result handle (owned by the caller, released with
/// mc_free_fem_result).
typedef struct MCFacadeFemResult {
  void* _impl;  ///< façade-private
} MCFacadeFemResult;

/// Element cap of mc_fem_mesh: a mesh that would keep more cells
/// than this fails with MC_ERR_INVALID_ARG instead of building.
/// (The grid scan itself is also capped, at 8,000,000 cells, so a
/// tiny voxel size on a large shape fails fast rather than
/// classifying forever.)
#define MC_FEM_MAX_ELEMENTS 250000

/// Build the voxel mesh of a shape at cubic voxel size
/// `voxelSizeMM`. The shape must contain at least one solid. The
/// mesh keeps its own reference to the shape, so the caller's
/// shape handle may be freed afterwards; face indices used with
/// this mesh are the census indices of THAT shape.
MCFacadeFemMesh* mc_fem_mesh(MCFacadeShape* shape, double voxelSizeMM,
                             int* err);
void mc_free_fem_mesh(MCFacadeFemMesh* m);

/// Mesh counts: nodes, kept elements (hex8 cells), and boundary
/// surface quads (see mc_fem_mesh_surface_data). Any output may
/// be NULL.
int mc_fem_mesh_counts(MCFacadeFemMesh* m, int* nodes, int* elements,
                       int* surfaceQuads, int* err);

/// The mesh's realised volume: element count x voxelSize^3. This
/// is the volume the ANALYSIS sees; drift against mc_volume() of
/// the solid is the thin-feature warning.
double mc_fem_mesh_volume(MCFacadeFemMesh* m, int* err);

/// The voxel size the mesh was built with.
double mc_fem_mesh_voxel_size(MCFacadeFemMesh* m, int* err);

/// Copy out node coordinates: 3 doubles per node (x, y, z) into
/// `out`, which must hold 3 * nodeCount doubles.
int mc_fem_mesh_nodes(MCFacadeFemMesh* m, double* out, int* err);

/// Copy out element connectivity: 8 node indices per element.
/// Node order within an element is the standard hex8 order —
/// bottom face (z = element min) counter-clockwise seen from
/// below [(0,0,0), (1,0,0), (1,1,0), (0,1,0)] in cell-corner
/// units, then the same four on the top face.
int mc_fem_mesh_elements(MCFacadeFemMesh* m, int* out, int* err);

/// Copy out the boundary surface: `quads` receives 4 node indices
/// per boundary quad, ordered so the quad's outward normal follows
/// from the right-hand rule; `quadFaces` receives, per quad, the
/// census index of the B-rep face the quad belongs to (the face
/// nearest the quad's centre), or -1 when no face is within
/// 1.5 voxel sizes. Either output may be NULL. Quad count comes
/// from mc_fem_mesh_counts.
int mc_fem_mesh_surface_data(MCFacadeFemMesh* m, int* quads,
                             int* quadFaces, int* err);

/// Map a B-rep face (census index, section 8) to the mesh surface
/// nodes lying on it: nodes whose point-to-face distance (OCCT
/// BRepExtrema) is below 0.75 x voxel size. These node sets are
/// how fixity and loads attach to the mesh.
///
/// `outNodes` may be NULL; `*outCount` always receives the total
/// number of matching nodes, and up to `outCapacity` of them are
/// written to `outNodes`. Results are cached per face. Calling
/// with the same mesh + face repeatedly is cheap.
int mc_fem_nodes_on_face(MCFacadeFemMesh* m, int faceIndex,
                         int* outNodes, int outCapacity, int* outCount,
                         int* err);

/// Solve the linear-static problem on a mesh.
///
/// - `E` / `nu`: Young's modulus (MPa) and Poisson's ratio
///   (must satisfy E > 0 and -1 < nu < 0.5).
/// - `fixedNodes` / `fixedCount`: mesh node indices clamped in
///   all three directions (build them with mc_fem_nodes_on_face
///   over the faces the user picked to fix). No fixed nodes —
///   or fixity that still leaves a rigid-body mode — fails with
///   MC_ERR_FEM_SINGULAR.
/// - Loads: `loadCount` entries; load i acts on B-rep face
///   `loadFaces[i]` with TOTAL force `loadForces[i]` newtons,
///   spread evenly over that face's mapped nodes, along the
///   direction `loadDirs[3*i .. 3*i+2]` (normalised internally).
///   A load face that maps to no mesh nodes is
///   MC_ERR_INVALID_ARG (refine the mesh or pick another face).
MCFacadeFemResult* mc_fem_solve(MCFacadeFemMesh* m, double E, double nu,
                                const int* fixedNodes, int fixedCount,
                                const int* loadFaces,
                                const double* loadForces,
                                const double* loadDirs, int loadCount,
                                int* err);
void mc_free_fem_result(MCFacadeFemResult* r);

/// Solve outcome: `maxVonMises` is the largest per-element
/// centroid von Mises stress (MPa); `maxDisplacement` the largest
/// nodal displacement magnitude (mm); `iterations` the PCG
/// iteration count; `relResidual` the final ||r|| / ||b||. Any
/// output may be NULL.
int mc_fem_result_stats(MCFacadeFemResult* r, double* maxVonMises,
                        double* maxDisplacement, int* iterations,
                        double* relResidual, int* err);

/// Copy out per-node results: `dispOut` receives 3 doubles per
/// node (dx, dy, dz, mm), `vonMisesOut` one double per node (the
/// node-averaged von Mises stress, MPa — the average of the
/// centroid values of the elements sharing the node). Either
/// output may be NULL.
int mc_fem_result_node_values(MCFacadeFemResult* r, double* dispOut,
                              double* vonMisesOut, int* err);

/// Copy out per-element centroid von Mises stress (MPa), one
/// double per element.
int mc_fem_result_element_von_mises(MCFacadeFemResult* r, double* out,
                                    int* err);

// ============================================================================
// 12. Threads
// ============================================================================
//
// A REAL helical thread solid, in the canonical placement: axis
// +Z, base at the origin, segment spanning z in [0, length]. The
// parameters mirror MetalCAD's ThreadSpec one-to-one, so the kit
// passes its stored spec straight through:
//
//   majorDiameter   crest diameter of an external thread (mm)
//   pitch           axial distance between adjacent ridges (mm)
//   depth           radial thread depth (mm); root diameter is
//                   majorDiameter - 2*depth
//   profileAngleDeg the spec's nominal profile angle; validated
//                   (5..175) but see the profile note below
//   starts          1..4 thread starts (lead = starts * pitch)
//   isInternal      0 = external segment, != 0 = internal groove
//                   TOOL (see below)
//   isLeftHanded    0 = right-hand, != 0 = left-hand
//   taperDeg        cone taper of the thread axis cone (NPT:
//                   1.7899); radii shrink toward +Z
//   clearance       fit offset: an external ridge shrinks radially
//                   by this, an internal tool grows by it;
//                   |clearance| <= pitch/4
//   length          axial length of the segment (mm)
//
// Profile: the trapezoid MetalCAD's ThreadSpec defines — in the
// meridional (r, z) half-plane, root flat 3/4 pitch wide at the
// root radius, crest flat 1/8 pitch wide at the major radius.
// Those flats with `depth` compose the flank angle (about 54
// degrees at the standard depth); the profile is deliberately NOT
// rebuilt from profileAngleDeg, whose effect on the geometry
// flows through `depth` exactly as it does in the kit. That keeps
// engine threads measuring what the kit's own thread maths says.
//
// Construction (all OCCT, no façade geometry logic): the profile
// is swept with BRepOffsetAPI_MakePipeShell along an EXACT helix
// — a straight diagonal Geom2d_Line on the cylindrical (or
// conical, when tapered) surface, so the spine is the true helix,
// not a polyline — in auxiliary-spine mode with the thread axis
// as the auxiliary spine, which keeps every section in its
// meridional plane: the true lathe-generated thread form.
// (mc_sweep cannot do this: its spine is a polyline and its pipe
// has no auxiliary-spine mode. The MANIFEST's old remark that
// mc_sweep covers threads was wrong and is corrected there.)
//
// External: returns the COMPLETE threaded segment — the ridge(s)
// fused onto the root cylinder/cone — trimmed to exactly
// z in [0, length] with flat end faces. OCCT's boolean
// classifier is unreliable against these helicoid solids in a
// way that depends on the exact pitch/lead/span combination
// (host-harness measured: a fuse that is exact at one lead
// returns the ridge alone at another), so the segment is built
// by a verified fallback chain — ridge fused onto an
// exact-length core, ridge fused onto a full-span core, groove
// cut into a full-span blank, groove cut into an exact blank,
// and (even starts) a halves build: an even-ridge half fused
// with its one-step rotation across the coincident core —
// and every candidate is verified (volume inside the core/blank
// bounds, centre and ridge witness inside, groove witness
// outside) before it is accepted. If no construction verifies,
// the call fails with MC_ERR_OCCT and words, never a bogus
// solid.
//
// Internal: returns the GROOVE TOOL instead: the void solid a
// mating ridge sweeps out (axial widths complementary to the
// external profile: 7/8 pitch at the minor radius, 1/4 pitch at
// the major radius, flanks parallel to the external ridge's),
// spanning radially [minor/2 - 0.03 sink, major/2], trimmed to
// z in [0, length]. Multi-start tools are ONE sweep whose
// profile carries a groove trapezoid per start joined by a thin
// web inside the bore's void — no rotated copies, no fuses. The
// caller subtracts it from a blank bored at the minor diameter
// to leave a real internal thread; the blank should span past
// the tool in z (the same classifier quirk), which the kit's
// rebuild does.
//
// Impossible specifications fail with MC_ERR_INVALID_ARG and
// words, never a bogus solid: non-positive major/pitch/depth/
// length, pitch >= major, depth >= major/2, starts outside 1..4,
// angle outside 5..175, taper outside [0, 10) or a taper that
// closes the thread within `length`, |clearance| > pitch/4.
MCFacadeShape* mc_thread(double majorDiameter, double pitch,
                         double depth, double profileAngleDeg,
                         int starts, int isInternal,
                         int isLeftHanded, double taperDeg,
                         double clearance, double length, int* err);

#ifdef __cplusplus
}
#endif
