// occt_facade.cpp — implementation of the thin OCCT pass-through.
// Every function below is: translate inputs -> call the OCCT
// operation named in occt_facade.h -> translate the result -> return.
// No CAD logic lives here; see occt_facade.h for the principle.

#include "occt_facade.h"

#include <cmath>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <string>
#include <vector>

#include <BRepAlgoAPI_Common.hxx>
#include <BRepAlgoAPI_Cut.hxx>
#include <BRepAlgoAPI_Fuse.hxx>
#include <BRepBndLib.hxx>
#include <BRepBuilderAPI_MakeEdge.hxx>
#include <BRepBuilderAPI_MakeFace.hxx>
#include <BRepBuilderAPI_MakePolygon.hxx>
#include <BRepBuilderAPI_MakeWire.hxx>
#include <BRepCheck_Analyzer.hxx>
#include <BRepClass3d_SolidClassifier.hxx>
#include <BRepFilletAPI_MakeChamfer.hxx>
#include <BRepFilletAPI_MakeFillet.hxx>
#include <BRepGProp.hxx>
#include <BRepMesh_IncrementalMesh.hxx>
#include <BRepOffsetAPI_MakePipe.hxx>
#include <BRepOffsetAPI_MakeThickSolid.hxx>
#include <BRepOffsetAPI_ThruSections.hxx>
#include <BRepPrimAPI_MakeBox.hxx>
#include <BRepPrimAPI_MakeCone.hxx>
#include <BRepPrimAPI_MakeCylinder.hxx>
#include <BRepPrimAPI_MakePrism.hxx>
#include <BRepPrimAPI_MakeRevol.hxx>
#include <BRepPrimAPI_MakeSphere.hxx>
#include <BRep_Tool.hxx>
#include <Bnd_Box.hxx>
#include <GC_MakeArcOfCircle.hxx>
#include <GC_MakeSegment.hxx>
#include <GProp_GProps.hxx>
#include <GeomAbs_JoinType.hxx>
#include <Poly_Triangulation.hxx>
#include <Precision.hxx>
#include <Standard_Failure.hxx>
#include <Standard_Version.hxx>
#include <NCollection_IndexedMap.hxx>
#include <TopAbs.hxx>
#include <TopExp.hxx>
#include <TopLoc_Location.hxx>
#include <TopTools_ShapeMapHasher.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Shape.hxx>
#include <gp.hxx>
#include <gp_Ax1.hxx>
#include <gp_Ax2.hxx>
#include <gp_Ax3.hxx>
#include <gp_Circ.hxx>
#include <gp_Dir.hxx>
#include <gp_Pln.hxx>
#include <gp_Pnt.hxx>
#include <gp_Trsf.hxx>
#include <gp_Vec.hxx>

struct MCFacadeShape {
  TopoDS_Shape shape;
};

namespace {

thread_local std::string g_lastError;

int fail(int* err, int code, const std::string& msg) {
  g_lastError = msg;
  if (err) *err = code;
  return code;
}

MCFacadeShape* wrap(const TopoDS_Shape& s, int* err) {
  if (s.IsNull()) {
    fail(err, MC_ERR_EMPTY_RESULT, "operation produced a null shape");
    return nullptr;
  }
  if (err) *err = MC_OK;
  auto* h = new MCFacadeShape();
  h->shape = s;
  return h;
}

void setOcctError(int* err, const char* what, const Standard_Failure& e) {
  std::string m = what;
  m += ": ";
  const char* em = e.GetMessageString();
  m += (em ? em : "OCCT failure");
  fail(err, MC_ERR_OCCT, m);
}

// Shared profile translation: 2D polygon + plane -> OCCT wire.
// Pure data translation (points onto the plane, polygon closed).
bool makeWire(const double* xy, int n, const double origin[3],
              const double xAxis[3], const double yAxis[3],
              TopoDS_Wire& outWire, std::string& why) {
  if (!xy || n < 3 || !origin || !xAxis || !yAxis) {
    why = "profile needs at least 3 points and a plane";
    return false;
  }
  gp_Vec x(xAxis[0], xAxis[1], xAxis[2]);
  gp_Vec y(yAxis[0], yAxis[1], yAxis[2]);
  if (x.Magnitude() < 1e-12 || y.Magnitude() < 1e-12) {
    why = "profile plane axis is degenerate";
    return false;
  }
  x.Normalize();
  y.Normalize();
  const gp_Pnt o(origin[0], origin[1], origin[2]);
  BRepBuilderAPI_MakePolygon poly;
  for (int i = 0; i < n; ++i) {
    gp_Pnt p = o.Translated(x.Multiplied(xy[2 * i]))
                   .Translated(y.Multiplied(xy[2 * i + 1]));
    poly.Add(p);
  }
  poly.Close();
  if (!poly.IsDone()) {
    why = "polygon construction failed";
    return false;
  }
  outWire = poly.Wire();
  return true;
}

bool makeFace(const double* xy, int n, const double origin[3],
              const double xAxis[3], const double yAxis[3],
              TopoDS_Face& outFace, std::string& why) {
  TopoDS_Wire wire;
  if (!makeWire(xy, n, origin, xAxis, yAxis, wire, why)) return false;
  gp_Vec x(xAxis[0], xAxis[1], xAxis[2]);
  gp_Vec y(yAxis[0], yAxis[1], yAxis[2]);
  x.Normalize();
  y.Normalize();
  gp_Vec nrm = x.Crossed(y);
  if (nrm.Magnitude() < 1e-12) {
    why = "profile plane axes are parallel";
    return false;
  }
  gp_Ax3 ax(gp_Pnt(origin[0], origin[1], origin[2]), gp_Dir(nrm), gp_Dir(x));
  BRepBuilderAPI_MakeFace mf(gp_Pln(ax), wire, Standard_True);
  if (!mf.IsDone()) {
    why = "face construction failed";
    return false;
  }
  outFace = mf.Face();
  return true;
}

// ------------------------------------------------------------ sketches
// Entity -> OCCT edge translation. Every curve is an OCCT object
// (GC_MakeSegment / GC_MakeArcOfCircle on a gp_Circ carried by the
// sketch plane's axes) and every edge is BRepBuilderAPI_MakeEdge's
// product; nothing here computes profile geometry.

struct SketchEdge {
  TopoDS_Edge edge;
  gp_Pnt first;
  gp_Pnt last;
  bool isCircle = false;
};

// Endpoint coincidence tolerance for ordering a profile's edges
// (documented in occt_facade.h).
constexpr double kSketchJoinTol = 1e-6;

bool sketchMakeEdge(int type, const double* d, const gp_Pnt& o,
                    const gp_Dir& xDir, const gp_Dir& yDir,
                    const gp_Dir& nDir, SketchEdge& out, std::string& why) {
  const gp_Vec xv(xDir), yv(yDir);
  auto pt = [&](double u, double v) {
    return o.Translated(xv.Multiplied(u)).Translated(yv.Multiplied(v));
  };
  out.isCircle = false;
  if (type == MC_SKETCH_LINE) {
    const gp_Pnt p1 = pt(d[0], d[1]);
    const gp_Pnt p2 = pt(d[2], d[3]);
    if (p1.Distance(p2) < Precision::Confusion()) {
      why = "line entity has zero length";
      return false;
    }
    GC_MakeSegment mk(p1, p2);
    if (!mk.IsDone()) {
      why = "line construction failed";
      return false;
    }
    BRepBuilderAPI_MakeEdge me(mk.Value());
    if (!me.IsDone()) {
      why = "line edge construction failed";
      return false;
    }
    out.edge = me.Edge();
  } else if (type == MC_SKETCH_CIRCLE || type == MC_SKETCH_ARC) {
    const double r = d[2];
    if (!(r > Precision::Confusion())) {
      why = "circle/arc entity has a non-positive radius";
      return false;
    }
    const gp_Ax2 ax(pt(d[0], d[1]), nDir, xDir);
    const gp_Circ circ(ax, r);
    if (type == MC_SKETCH_CIRCLE) {
      BRepBuilderAPI_MakeEdge me(circ);
      if (!me.IsDone()) {
        why = "circle edge construction failed";
        return false;
      }
      out.edge = me.Edge();
      out.isCircle = true;
    } else {
      // CCW sweep from startAngle to endAngle, wrapping once past
      // 2*pi when end < start; a zero or full-turn sweep is not an
      // arc (a full turn is a circle entity).
      constexpr double kTwoPi = 6.28318530717958647692;
      double sweep = std::fmod(d[4] - d[3], kTwoPi);
      if (sweep < 0) sweep += kTwoPi;
      if (sweep < Precision::Angular()) {
        why = "arc entity has a zero sweep (use a circle for a full turn)";
        return false;
      }
      GC_MakeArcOfCircle mk(circ, d[3], d[3] + sweep, Standard_True);
      if (!mk.IsDone()) {
        why = "arc construction failed";
        return false;
      }
      BRepBuilderAPI_MakeEdge me(mk.Value());
      if (!me.IsDone()) {
        why = "arc edge construction failed";
        return false;
      }
      out.edge = me.Edge();
    }
  } else {
    why = "unknown sketch entity type";
    return false;
  }
  out.first = BRep_Tool::Pnt(TopExp::FirstVertex(out.edge, Standard_True));
  out.last = BRep_Tool::Pnt(TopExp::LastVertex(out.edge, Standard_True));
  return true;
}

// Order one profile's edges end to end and build its wire with
// BRepBuilderAPI_MakeWire (which requires connected input). The
// ordering is pure sequencing of the caller's entities — the wire,
// its vertices and its geometry are all OCCT's.
bool sketchMakeWire(const std::vector<SketchEdge>& edges, TopoDS_Wire& out,
                    std::string& why) {
  if (edges.empty()) {
    why = "profile has no entities";
    return false;
  }
  if (edges.size() == 1) {
    if (!edges[0].isCircle) {
      why = "profile is not closed (a single line/arc cannot close)";
      return false;
    }
    BRepBuilderAPI_MakeWire mw(edges[0].edge);
    if (!mw.IsDone()) {
      why = "wire construction failed";
      return false;
    }
    out = mw.Wire();
    return true;
  }
  std::deque<const SketchEdge*> chain;
  std::vector<bool> used(edges.size(), false);
  chain.push_back(&edges[0]);
  used[0] = true;
  gp_Pnt head = edges[0].first;
  gp_Pnt tail = edges[0].last;
  size_t placed = 1;
  while (placed < edges.size()) {
    bool progressed = false;
    for (size_t i = 0; i < edges.size(); ++i) {
      if (used[i]) continue;
      const SketchEdge& e = edges[i];
      if (e.first.Distance(tail) <= kSketchJoinTol) {
        chain.push_back(&e);
        tail = e.last;
      } else if (e.last.Distance(tail) <= kSketchJoinTol) {
        chain.push_back(&e);
        tail = e.first;
      } else if (e.last.Distance(head) <= kSketchJoinTol) {
        chain.push_front(&e);
        head = e.first;
      } else if (e.first.Distance(head) <= kSketchJoinTol) {
        chain.push_front(&e);
        head = e.last;
      } else {
        continue;
      }
      used[i] = true;
      ++placed;
      progressed = true;
    }
    if (!progressed) {
      why = "profile entities do not connect end to end";
      return false;
    }
  }
  if (head.Distance(tail) > kSketchJoinTol) {
    why = "profile is not closed";
    return false;
  }
  BRepBuilderAPI_MakeWire mw;
  for (const SketchEdge* e : chain) mw.Add(e->edge);
  if (!mw.IsDone()) {
    why = "wire construction failed (edges not connected)";
    return false;
  }
  out = mw.Wire();
  return true;
}

template <typename Maker>
MCFacadeShape* booleanOp(MCFacadeShape* a, MCFacadeShape* b, int* err,
                         const char* what) {
  if (!a || !b) {
    fail(err, MC_ERR_INVALID_ARG, "null shape handle");
    return nullptr;
  }
  try {
    Maker mk(a->shape, b->shape);
    mk.Build();
    if (!mk.IsDone()) {
      fail(err, MC_ERR_OCCT, std::string(what) + ": builder not done");
      return nullptr;
    }
    return wrap(mk.Shape(), err);
  } catch (const Standard_Failure& e) {
    setOcctError(err, what, e);
    return nullptr;
  }
}

MCFacadeShape* edgeOp(MCFacadeShape* s, double value, bool isFillet,
                      const int* edgeIndices, int edgeCount, int* err,
                      const char* what) {
  if (!s) {
    fail(err, MC_ERR_INVALID_ARG, "null shape handle");
    return nullptr;
  }
  try {
    NCollection_IndexedMap<TopoDS_Shape, TopTools_ShapeMapHasher> edgeMap;
    TopExp::MapShapes(s->shape, TopAbs_EDGE, edgeMap);
    std::vector<int> idx;
    if (edgeIndices && edgeCount > 0) {
      for (int i = 0; i < edgeCount; ++i) idx.push_back(edgeIndices[i]);
    } else {
      for (int i = 0; i < edgeMap.Extent(); ++i) idx.push_back(i);
    }
    TopoDS_Shape result;
    if (isFillet) {
      BRepFilletAPI_MakeFillet mk(s->shape);
      for (int i : idx) {
        if (i < 0 || i >= edgeMap.Extent()) {
          fail(err, MC_ERR_INVALID_ARG, "edge index out of range");
          return nullptr;
        }
        mk.Add(value, TopoDS::Edge(edgeMap.FindKey(i + 1)));
      }
      mk.Build();
      if (!mk.IsDone()) {
        fail(err, MC_ERR_OCCT, std::string(what) + ": builder not done");
        return nullptr;
      }
      result = mk.Shape();
    } else {
      BRepFilletAPI_MakeChamfer mk(s->shape);
      for (int i : idx) {
        if (i < 0 || i >= edgeMap.Extent()) {
          fail(err, MC_ERR_INVALID_ARG, "edge index out of range");
          return nullptr;
        }
        mk.Add(value, TopoDS::Edge(edgeMap.FindKey(i + 1)));
      }
      mk.Build();
      if (!mk.IsDone()) {
        fail(err, MC_ERR_OCCT, std::string(what) + ": builder not done");
        return nullptr;
      }
      result = mk.Shape();
    }
    return wrap(result, err);
  } catch (const Standard_Failure& e) {
    setOcctError(err, what, e);
    return nullptr;
  }
}

}  // namespace

extern "C" {

const char* mc_last_error(void) { return g_lastError.c_str(); }

const char* mc_occt_version(void) { return OCC_VERSION_COMPLETE; }

// ------------------------------------------------------------ primitives

MCFacadeShape* mc_box(double w, double d, double h, int* err) {
  try {
    BRepPrimAPI_MakeBox mk(w, d, h);
    mk.Build();
    return wrap(mk.Shape(), err);
  } catch (const Standard_Failure& e) {
    setOcctError(err, "mc_box", e);
    return nullptr;
  }
}

MCFacadeShape* mc_cylinder(double r, double h, int* err) {
  try {
    BRepPrimAPI_MakeCylinder mk(r, h);
    mk.Build();
    return wrap(mk.Shape(), err);
  } catch (const Standard_Failure& e) {
    setOcctError(err, "mc_cylinder", e);
    return nullptr;
  }
}

MCFacadeShape* mc_sphere(double r, int* err) {
  try {
    BRepPrimAPI_MakeSphere mk(r);
    mk.Build();
    return wrap(mk.Shape(), err);
  } catch (const Standard_Failure& e) {
    setOcctError(err, "mc_sphere", e);
    return nullptr;
  }
}

MCFacadeShape* mc_cone(double r1, double r2, double h, int* err) {
  try {
    BRepPrimAPI_MakeCone mk(r1, r2, h);
    mk.Build();
    return wrap(mk.Shape(), err);
  } catch (const Standard_Failure& e) {
    setOcctError(err, "mc_cone", e);
    return nullptr;
  }
}

// ------------------------------------------------------------ profiles

MCFacadeShape* mc_prism(const double* xy, int n, const double origin[3],
                        const double xAxis[3], const double yAxis[3],
                        const double dir[3], double dist, int* err) {
  if (!dir) {
    fail(err, MC_ERR_INVALID_ARG, "null prism direction");
    return nullptr;
  }
  try {
    TopoDS_Face face;
    std::string why;
    if (!makeFace(xy, n, origin, xAxis, yAxis, face, why)) {
      fail(err, MC_ERR_INVALID_ARG, why);
      return nullptr;
    }
    gp_Vec v(dir[0], dir[1], dir[2]);
    if (v.Magnitude() < 1e-12) {
      fail(err, MC_ERR_INVALID_ARG, "prism direction is degenerate");
      return nullptr;
    }
    v.Normalize();
    BRepPrimAPI_MakePrism mk(face, v.Multiplied(dist));
    mk.Build();
    return wrap(mk.Shape(), err);
  } catch (const Standard_Failure& e) {
    setOcctError(err, "mc_prism", e);
    return nullptr;
  }
}

MCFacadeShape* mc_revolve(const double* xy, int n, const double origin[3],
                          const double xAxis[3], const double yAxis[3],
                          const double axisPoint[3], const double axisDir[3],
                          double angleDeg, int* err) {
  if (!axisPoint || !axisDir) {
    fail(err, MC_ERR_INVALID_ARG, "null revolve axis");
    return nullptr;
  }
  try {
    TopoDS_Face face;
    std::string why;
    if (!makeFace(xy, n, origin, xAxis, yAxis, face, why)) {
      fail(err, MC_ERR_INVALID_ARG, why);
      return nullptr;
    }
    gp_Vec ad(axisDir[0], axisDir[1], axisDir[2]);
    if (ad.Magnitude() < 1e-12) {
      fail(err, MC_ERR_INVALID_ARG, "revolve axis is degenerate");
      return nullptr;
    }
    gp_Ax1 ax(gp_Pnt(axisPoint[0], axisPoint[1], axisPoint[2]), gp_Dir(ad));
    BRepPrimAPI_MakeRevol mk(face, ax, angleDeg * M_PI / 180.0,
                             Standard_True);
    mk.Build();
    return wrap(mk.Shape(), err);
  } catch (const Standard_Failure& e) {
    setOcctError(err, "mc_revolve", e);
    return nullptr;
  }
}

MCFacadeShape* mc_loft(const double* const* profilesXY,
                       const int* profileCounts, int profileCount,
                       const double* origins, const double* xAxes,
                       const double* yAxes, int ruled, int* err) {
  if (!profilesXY || !profileCounts || profileCount < 2 || !origins ||
      !xAxes || !yAxes) {
    fail(err, MC_ERR_INVALID_ARG, "loft needs at least 2 profiles");
    return nullptr;
  }
  try {
    BRepOffsetAPI_ThruSections mk(Standard_True,
                                  ruled ? Standard_True : Standard_False,
                                  Precision::Confusion());
    for (int i = 0; i < profileCount; ++i) {
      TopoDS_Wire wire;
      std::string why;
      if (!makeWire(profilesXY[i], profileCounts[i], origins + 3 * i,
                    xAxes + 3 * i, yAxes + 3 * i, wire, why)) {
        fail(err, MC_ERR_INVALID_ARG, why);
        return nullptr;
      }
      mk.AddWire(wire);
    }
    mk.Build();
    if (!mk.IsDone()) {
      fail(err, MC_ERR_OCCT, "mc_loft: builder not done");
      return nullptr;
    }
    return wrap(mk.Shape(), err);
  } catch (const Standard_Failure& e) {
    setOcctError(err, "mc_loft", e);
    return nullptr;
  }
}

MCFacadeShape* mc_sweep(const double* xy, int n, const double origin[3],
                        const double xAxis[3], const double yAxis[3],
                        const double* pathPts, int pathCount, int* err) {
  if (!pathPts || pathCount < 2) {
    fail(err, MC_ERR_INVALID_ARG, "sweep path needs at least 2 points");
    return nullptr;
  }
  try {
    TopoDS_Face face;
    std::string why;
    if (!makeFace(xy, n, origin, xAxis, yAxis, face, why)) {
      fail(err, MC_ERR_INVALID_ARG, why);
      return nullptr;
    }
    BRepBuilderAPI_MakePolygon poly;
    for (int i = 0; i < pathCount; ++i) {
      poly.Add(gp_Pnt(pathPts[3 * i], pathPts[3 * i + 1], pathPts[3 * i + 2]));
    }
    if (!poly.IsDone()) {
      fail(err, MC_ERR_OCCT, "mc_sweep: path construction failed");
      return nullptr;
    }
    BRepOffsetAPI_MakePipe mk(poly.Wire(), face);
    mk.Build();
    if (!mk.IsDone()) {
      fail(err, MC_ERR_OCCT, "mc_sweep: builder not done");
      return nullptr;
    }
    return wrap(mk.Shape(), err);
  } catch (const Standard_Failure& e) {
    setOcctError(err, "mc_sweep", e);
    return nullptr;
  }
}

// ------------------------------------------------------------ sketches

MCFacadeShape* mc_face_from_sketch(const double origin[3],
                                   const double normal[3],
                                   const double xDir[3],
                                   const int* entityTypes,
                                   const double* entityData, int entityCount,
                                   const int* profileStarts,
                                   int profileCount, int* err) {
  if (!origin || !normal || !xDir || !entityTypes || !entityData ||
      !profileStarts || entityCount < 1 || profileCount < 1) {
    fail(err, MC_ERR_INVALID_ARG, "mc_face_from_sketch: null/bad arguments");
    return nullptr;
  }
  if (profileStarts[0] != 0 || profileStarts[profileCount] != entityCount) {
    fail(err, MC_ERR_INVALID_ARG,
         "mc_face_from_sketch: profileStarts must start at 0 and end at "
         "entityCount");
    return nullptr;
  }
  for (int p = 0; p < profileCount; ++p) {
    if (profileStarts[p + 1] <= profileStarts[p]) {
      fail(err, MC_ERR_INVALID_ARG,
           "mc_face_from_sketch: profile ranges must be non-empty and "
           "increasing");
      return nullptr;
    }
  }
  try {
    gp_Vec n(normal[0], normal[1], normal[2]);
    gp_Vec x(xDir[0], xDir[1], xDir[2]);
    if (n.Magnitude() < 1e-12 || x.Magnitude() < 1e-12) {
      fail(err, MC_ERR_INVALID_ARG,
           "mc_face_from_sketch: plane normal/xDir is degenerate");
      return nullptr;
    }
    n.Normalize();
    x.Normalize();
    if (std::fabs(n.Dot(x)) > 1.0 - 1e-9) {
      fail(err, MC_ERR_INVALID_ARG,
           "mc_face_from_sketch: plane normal and xDir are parallel");
      return nullptr;
    }
    const gp_Pnt o(origin[0], origin[1], origin[2]);
    const gp_Ax3 ax3(o, gp_Dir(n), gp_Dir(x));
    const gp_Pln plane(ax3);
    const gp_Dir xd = ax3.XDirection();
    const gp_Dir yd = ax3.YDirection();
    const gp_Dir nd = ax3.Direction();

    std::vector<TopoDS_Wire> wires;
    for (int p = 0; p < profileCount; ++p) {
      const int b = profileStarts[p], e = profileStarts[p + 1];
      std::vector<SketchEdge> edges;
      for (int i = b; i < e; ++i) {
        const int type = entityTypes[i];
        if (type == MC_SKETCH_CIRCLE && e - b > 1) {
          fail(err, MC_ERR_INVALID_ARG,
               "mc_face_from_sketch: a circle entity must be the only "
               "entity of its profile");
          return nullptr;
        }
        SketchEdge se;
        std::string why;
        if (!sketchMakeEdge(type, entityData + MC_SKETCH_DATA_STRIDE * i, o,
                            xd, yd, nd, se, why)) {
          fail(err, MC_ERR_INVALID_ARG,
               std::string("mc_face_from_sketch: ") + why);
          return nullptr;
        }
        edges.push_back(se);
      }
      TopoDS_Wire wire;
      std::string why;
      if (!sketchMakeWire(edges, wire, why)) {
        fail(err, MC_ERR_INVALID_ARG,
             std::string("mc_face_from_sketch: ") + why);
        return nullptr;
      }
      wires.push_back(wire);
    }

    BRepBuilderAPI_MakeFace mf(plane, wires[0], Standard_True);
    // OCCT represents a hole by a wire oriented OPPOSITE to the
    // outer wire, and MakeFace::Add does not reorient for us
    // (verified against 8.0.1: an unreversed hole is added as
    // material — area grows instead of shrinking — and the face
    // fails BRepCheck). Callers describe every profile in the same
    // orientation, so hole wires are reversed here: representation
    // translation, not geometry.
    for (size_t p = 1; p < wires.size(); ++p) {
      mf.Add(TopoDS::Wire(wires[p].Reversed()));
    }
    if (!mf.IsDone()) {
      fail(err, MC_ERR_OCCT, "mc_face_from_sketch: face construction failed");
      return nullptr;
    }
    const TopoDS_Face face = mf.Face();
    if (face.IsNull() || !BRepCheck_Analyzer(face).IsValid()) {
      fail(err, MC_ERR_OCCT,
           "mc_face_from_sketch: resulting face failed OCCT validity check");
      return nullptr;
    }
    return wrap(face, err);
  } catch (const Standard_Failure& ex) {
    setOcctError(err, "mc_face_from_sketch", ex);
    return nullptr;
  }
}

MCFacadeShape* mc_prism_face(MCFacadeShape* face, const double dir[3],
                             double dist, int* err) {
  if (!face || !dir) {
    fail(err, MC_ERR_INVALID_ARG, "mc_prism_face: null argument");
    return nullptr;
  }
  if (face->shape.ShapeType() != TopAbs_FACE) {
    fail(err, MC_ERR_INVALID_ARG, "mc_prism_face: handle is not a face");
    return nullptr;
  }
  try {
    gp_Vec v(dir[0], dir[1], dir[2]);
    if (v.Magnitude() < 1e-12) {
      fail(err, MC_ERR_INVALID_ARG, "mc_prism_face: direction is degenerate");
      return nullptr;
    }
    v.Normalize();
    BRepPrimAPI_MakePrism mk(face->shape, v.Multiplied(dist));
    mk.Build();
    return wrap(mk.Shape(), err);
  } catch (const Standard_Failure& e) {
    setOcctError(err, "mc_prism_face", e);
    return nullptr;
  }
}

// ------------------------------------------------------------ booleans

MCFacadeShape* mc_unite(MCFacadeShape* a, MCFacadeShape* b, int* err) {
  return booleanOp<BRepAlgoAPI_Fuse>(a, b, err, "mc_unite");
}

MCFacadeShape* mc_subtract(MCFacadeShape* a, MCFacadeShape* b, int* err) {
  return booleanOp<BRepAlgoAPI_Cut>(a, b, err, "mc_subtract");
}

MCFacadeShape* mc_intersect(MCFacadeShape* a, MCFacadeShape* b, int* err) {
  return booleanOp<BRepAlgoAPI_Common>(a, b, err, "mc_intersect");
}

// ------------------------------------------------------------ edge ops

MCFacadeShape* mc_fillet(MCFacadeShape* s, double radius,
                         const int* edgeIndices, int edgeCount, int* err) {
  return edgeOp(s, radius, true, edgeIndices, edgeCount, err, "mc_fillet");
}

MCFacadeShape* mc_chamfer(MCFacadeShape* s, double dist,
                          const int* edgeIndices, int edgeCount, int* err) {
  return edgeOp(s, dist, false, edgeIndices, edgeCount, err, "mc_chamfer");
}

MCFacadeShape* mc_shell(MCFacadeShape* s, double thickness, int* err) {
  if (!s) {
    fail(err, MC_ERR_INVALID_ARG, "null shape handle");
    return nullptr;
  }
  try {
    BRepOffsetAPI_MakeThickSolid mk;
    NCollection_List<TopoDS_Shape> noOpenings;
    // Negative offset: walls grow inward, outside dimensions kept.
    mk.MakeThickSolidByJoin(s->shape, noOpenings, -thickness,
                            Precision::Confusion());
    mk.Build();
    if (!mk.IsDone()) {
      fail(err, MC_ERR_OCCT, "mc_shell: builder not done");
      return nullptr;
    }
    // OCCT semantics (verified against the 8.0.1 sources,
    // BRepOffset_MakeOffset::MakeThickSolid): with an empty
    // removed-faces list, MakeThickSolid returns the bare
    // inward-offset solid, NOT the hollow part. The closed hollow
    // part is that offset solid cut from the original — composed
    // here from two OCCT operations (offset + BRepAlgoAPI_Cut);
    // the facade computes no geometry of its own.
    BRepAlgoAPI_Cut cut;
    NCollection_List<TopoDS_Shape> args, tools;
    args.Append(s->shape);
    tools.Append(mk.Shape());
    cut.SetArguments(args);
    cut.SetTools(tools);
    cut.SetRunParallel(false);
    cut.Build();
    if (!cut.IsDone() || cut.Shape().IsNull()) {
      fail(err, MC_ERR_OCCT, "mc_shell: cut of offset solid failed");
      return nullptr;
    }
    return wrap(cut.Shape(), err);
  } catch (const Standard_Failure& e) {
    setOcctError(err, "mc_shell", e);
    return nullptr;
  }
}

// ------------------------------------------------------------ queries

double mc_volume(MCFacadeShape* s, int* err) {
  if (!s) {
    fail(err, MC_ERR_INVALID_ARG, "null shape handle");
    return 0.0;
  }
  try {
    GProp_GProps props;
    BRepGProp::VolumeProperties(s->shape, props);
    if (err) *err = MC_OK;
    return props.Mass();
  } catch (const Standard_Failure& e) {
    setOcctError(err, "mc_volume", e);
    return 0.0;
  }
}

double mc_face_area(MCFacadeShape* s, int* err) {
  if (!s) {
    fail(err, MC_ERR_INVALID_ARG, "null shape handle");
    return 0.0;
  }
  try {
    GProp_GProps props;
    BRepGProp::SurfaceProperties(s->shape, props);
    if (err) *err = MC_OK;
    return props.Mass();
  } catch (const Standard_Failure& e) {
    setOcctError(err, "mc_face_area", e);
    return 0.0;
  }
}

int mc_bbox(MCFacadeShape* s, double out[6], int* err) {
  if (!s || !out) {
    return fail(err, MC_ERR_INVALID_ARG, "null argument");
  }
  try {
    Bnd_Box box;
    // AddOptimal: the exact, tight box from the geometry itself.
    // (BRepBndLib::Add inflates by triangulation gap + tolerance.)
    BRepBndLib::AddOptimal(s->shape, box, Standard_False,
                           Standard_False);
    if (box.IsVoid()) {
      return fail(err, MC_ERR_EMPTY_RESULT, "bounding box is void");
    }
    box.Get(out[0], out[1], out[2], out[3], out[4], out[5]);
    if (err) *err = MC_OK;
    return MC_OK;
  } catch (const Standard_Failure& e) {
    setOcctError(err, "mc_bbox", e);
    return MC_ERR_OCCT;
  }
}

int mc_edge_count(MCFacadeShape* s, int* err) {
  if (!s) {
    fail(err, MC_ERR_INVALID_ARG, "null shape handle");
    return -1;
  }
  NCollection_IndexedMap<TopoDS_Shape, TopTools_ShapeMapHasher> edgeMap;
  TopExp::MapShapes(s->shape, TopAbs_EDGE, edgeMap);
  if (err) *err = MC_OK;
  return edgeMap.Extent();
}

int mc_contains(MCFacadeShape* s, double x, double y, double z, int* err) {
  if (!s) {
    fail(err, MC_ERR_INVALID_ARG, "null shape handle");
    return -1;
  }
  try {
    BRepClass3d_SolidClassifier cls;
    cls.Load(s->shape);
    cls.Perform(gp_Pnt(x, y, z), 1e-7);
    if (err) *err = MC_OK;
    return cls.State() == TopAbs_IN ? 1 : 0;
  } catch (const Standard_Failure& e) {
    setOcctError(err, "mc_contains", e);
    return -1;
  }
}

// ------------------------------------------------------------ tessellation

int mc_tessellate(MCFacadeShape* s, double deflectionMM, MCFacadeMesh* out,
                  int* err) {
  if (!s || !out) {
    return fail(err, MC_ERR_INVALID_ARG, "null argument");
  }
  std::memset(out, 0, sizeof(*out));
  try {
    BRepMesh_IncrementalMesh mesher(s->shape, deflectionMM, Standard_False,
                                    0.5, Standard_True);
    mesher.Perform();

    NCollection_IndexedMap<TopoDS_Shape, TopTools_ShapeMapHasher> faceMap;
    TopExp::MapShapes(s->shape, TopAbs_FACE, faceMap);
    const int faceCount = faceMap.Extent();

    std::vector<float> positions;
    std::vector<float> normals;
    std::vector<int> indices;
    std::vector<int> faceStart(faceCount, 0);
    std::vector<int> faceCountArr(faceCount, 0);

    for (int fi = 1; fi <= faceCount; ++fi) {
      const TopoDS_Face face = TopoDS::Face(faceMap.FindKey(fi));
      TopLoc_Location loc;
      Handle(Poly_Triangulation) tri = BRep_Tool::Triangulation(face, loc);
      faceStart[fi - 1] = (int)indices.size() / 3;
      if (tri.IsNull()) {
        faceCountArr[fi - 1] = 0;
        continue;
      }
      if (!tri->HasNormals()) tri->ComputeNormals();
      const gp_Trsf& trsf = loc.Transformation();
      const bool reversed = (face.Orientation() == TopAbs_REVERSED);
      const int baseVertex = (int)positions.size() / 3;
      const int nbNodes = tri->NbNodes();
      for (int i = 1; i <= nbNodes; ++i) {
        gp_Pnt p = tri->Node(i).Transformed(trsf);
        positions.push_back((float)p.X());
        positions.push_back((float)p.Y());
        positions.push_back((float)p.Z());
        gp_Vec nrm = tri->Normal(i);
        gp_Dir nd(nrm);
        nd.Transform(trsf);
        float nx = (float)nd.X(), ny = (float)nd.Y(), nz = (float)nd.Z();
        if (reversed) { nx = -nx; ny = -ny; nz = -nz; }
        normals.push_back(nx);
        normals.push_back(ny);
        normals.push_back(nz);
      }
      const int nbTris = tri->NbTriangles();
      for (int i = 1; i <= nbTris; ++i) {
        Standard_Integer n1, n2, n3;
        tri->Triangle(i).Get(n1, n2, n3);
        if (reversed) std::swap(n2, n3);
        indices.push_back(baseVertex + n1 - 1);
        indices.push_back(baseVertex + n2 - 1);
        indices.push_back(baseVertex + n3 - 1);
      }
      faceCountArr[fi - 1] = nbTris;
    }

    const size_t nv = positions.size() / 3;
    const size_t nt = indices.size() / 3;
    out->positions = (float*)std::malloc(sizeof(float) * (nv * 3 ? nv * 3 : 1));
    out->normals = (float*)std::malloc(sizeof(float) * (nv * 3 ? nv * 3 : 1));
    out->indices = (int*)std::malloc(sizeof(int) * (nt * 3 ? nt * 3 : 1));
    out->faceTriStart = (int*)std::malloc(sizeof(int) * (faceCount ? faceCount : 1));
    out->faceTriCount = (int*)std::malloc(sizeof(int) * (faceCount ? faceCount : 1));
    if (!out->positions || !out->normals || !out->indices ||
        !out->faceTriStart || !out->faceTriCount) {
      mc_free_mesh(out);
      return fail(err, MC_ERR_OCCT, "out of memory");
    }
    if (nv) {
      std::memcpy(out->positions, positions.data(), sizeof(float) * nv * 3);
      std::memcpy(out->normals, normals.data(), sizeof(float) * nv * 3);
    }
    if (nt) std::memcpy(out->indices, indices.data(), sizeof(int) * nt * 3);
    if (faceCount) {
      std::memcpy(out->faceTriStart, faceStart.data(), sizeof(int) * faceCount);
      std::memcpy(out->faceTriCount, faceCountArr.data(), sizeof(int) * faceCount);
    }
    out->vertexCount = (int)nv;
    out->triangleCount = (int)nt;
    out->faceCount = faceCount;
    if (err) *err = MC_OK;
    return MC_OK;
  } catch (const Standard_Failure& e) {
    setOcctError(err, "mc_tessellate", e);
    return MC_ERR_OCCT;
  }
}

void mc_free_mesh(MCFacadeMesh* m) {
  if (!m) return;
  std::free(m->positions);
  std::free(m->normals);
  std::free(m->indices);
  std::free(m->faceTriStart);
  std::free(m->faceTriCount);
  std::memset(m, 0, sizeof(*m));
}

void mc_free_shape(MCFacadeShape* s) { delete s; }

}  // extern "C"
