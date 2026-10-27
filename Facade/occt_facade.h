// occt_facade.h — thin, COMPLETE pass-through from C (and Swift) to
// the Open CASCADE (OCCT) geometry libraries.
//
// ARCHITECTURE PRINCIPLE (Sean's rule for the port): everything above
// this layer is Swift. Swift decides WHAT to build; OCCT's own
// libraries do ALL the geometry. This façade therefore contains no
// CAD feature logic and no geometry math of its own — each function
// only translates arguments and buffers across the C ABI, calls the
// corresponding OCCT operation, translates the result back, and
// catches every OCCT exception so none crosses the boundary
// (failures come back as error codes + mc_last_error()).
//
// If an operation exists in OCCT, it is wrapped here rather than
// approximated. Handles are opaque; no C++ type crosses the ABI.
//
// Units are millimetres everywhere. All returned buffers are
// malloc-owned by the caller and released with the matching free
// function.
#pragma once

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

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
} MCFacadeError;

/// Human-readable message for the most recent failure (static
/// storage; overwritten by the next failing call).
const char* mc_last_error(void);

/// OCCT version string of the linked libraries, e.g. "8.0.1".
const char* mc_occt_version(void);

// ---------------------------------------------------------------- primitives
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

// ---------------------------------------------------------------- profiles
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

// ---------------------------------------------------------------- sketches
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

// ---------------------------------------------------------------- booleans
// Direct wraps of BRepAlgoAPI_Fuse / Cut / Common. Inputs are left
// unchanged; the result is a new handle the caller owns.

MCFacadeShape* mc_unite(MCFacadeShape* a, MCFacadeShape* b, int* err);
MCFacadeShape* mc_subtract(MCFacadeShape* a, MCFacadeShape* b, int* err);
MCFacadeShape* mc_intersect(MCFacadeShape* a, MCFacadeShape* b, int* err);

// ---------------------------------------------------------------- edge ops

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

/// BRepOffsetAPI_MakeThickSolid: closed hollow solid — the shape
/// offset inward by `thickness` mm, no faces removed (no openings).
MCFacadeShape* mc_shell(MCFacadeShape* s, double thickness, int* err);

// ---------------------------------------------------------------- queries

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

// ------------------------------------------------------- selection census
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

/// Per-edge info for edge `edgeIndex` (census order):
/// `curveType` is 0 = line, 1 = circle, 2 = other
/// (BRepAdaptor_Curve); `length` via BRepGProp::LinearProperties
/// (OCCT 8.0.1's name for the edge-properties entry point);
/// `start` / `end` are the points of the edge's first / last
/// vertex in traversal orientation. `center` / `radius` are the
/// circle's own, and are only meaningful when curveType == 1 —
/// for any other curve they are (0, 0, 0) and 0.
int mc_edge_info(MCFacadeShape* s, int edgeIndex, int* curveType,
                 double* length, double start[3], double end[3],
                 double center[3], double* radius, int* err);

// ---------------------------------------------------------------- tessellation

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
void mc_free_shape(MCFacadeShape* s);

#ifdef __cplusplus
}
#endif
