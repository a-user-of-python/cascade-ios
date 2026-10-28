// occt_facade.cpp — implementation of the CascadeKit geometry
// library's public C API (occt_facade.h). Every function below is:
// translate inputs -> call the OCCT operation named in the header ->
// translate the result -> return. No CAD logic lives here; see
// occt_facade.h for the principle and the API map.

#include "occt_facade.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <map>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include <BRepAdaptor_Curve.hxx>
#include <BRepAdaptor_Surface.hxx>
#include <BRepAlgoAPI_Common.hxx>
#include <BRepAlgoAPI_Cut.hxx>
#include <BRepAlgoAPI_Fuse.hxx>
#include <BRepBndLib.hxx>
#include <BRepBuilderAPI_MakeEdge.hxx>
#include <BRepBuilderAPI_MakeFace.hxx>
#include <BRepBuilderAPI_MakePolygon.hxx>
#include <BRepBuilderAPI_MakeVertex.hxx>
#include <BRepBuilderAPI_MakeWire.hxx>
#include <BRepExtrema_DistShapeShape.hxx>
#include <BRepCheck_Analyzer.hxx>
#include <BRepClass3d_SolidClassifier.hxx>
#include <BRepFilletAPI_MakeChamfer.hxx>
#include <BRepFilletAPI_MakeFillet.hxx>
#include <BRepGProp.hxx>
#include <BRepMesh_IncrementalMesh.hxx>
#include <BRepBuilderAPI_GTransform.hxx>
#include <BRepOffsetAPI_DraftAngle.hxx>
#include <BRepOffsetAPI_MakePipe.hxx>
#include <BRepOffsetAPI_MakeThickSolid.hxx>
#include <BRepOffsetAPI_ThruSections.hxx>
#include <BRepPrimAPI_MakeBox.hxx>
#include <BRepPrimAPI_MakeCone.hxx>
#include <BRepPrimAPI_MakeCylinder.hxx>
#include <BRepPrimAPI_MakePrism.hxx>
#include <BRepPrimAPI_MakeRevol.hxx>
#include <BRepPrimAPI_MakeSphere.hxx>
#include <BRepPrimAPI_MakeTorus.hxx>
#include <BRep_Tool.hxx>
#include <Bnd_Box.hxx>
#include <GC_MakeArcOfCircle.hxx>
#include <GC_MakeSegment.hxx>
#include <IFSelect_ReturnStatus.hxx>
#include <BRep_Builder.hxx>
#include <NCollection_IndexedDataMap.hxx>
#include <NCollection_List.hxx>
#include <Quantity_Color.hxx>
#include <STEPCAFControl_Reader.hxx>
#include <TDF_Label.hxx>
#include <TDocStd_Document.hxx>
#include <TopoDS_Compound.hxx>
#include <XCAFDoc_ColorTool.hxx>
#include <XCAFDoc_DocumentTool.hxx>
#include <XCAFDoc_ShapeTool.hxx>
#include <STEPControl_Reader.hxx>
#include <STEPControl_StepModelType.hxx>
#include <STEPControl_Writer.hxx>
#include <GProp_GProps.hxx>
#include <GeomAbs_CurveType.hxx>
#include <GeomAbs_JoinType.hxx>
#include <GeomAbs_SurfaceType.hxx>
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
#include <gp_GTrsf.hxx>
#include <gp_Pln.hxx>
#include <gp_Pnt.hxx>
#include <gp_Trsf.hxx>
#include <gp_Vec.hxx>

// MCFacadeShape itself is defined in occt_facade.h (a single opaque
// void* member, so Swift's ClangImporter can import the type). The
// pointer holds a heap ShapeImpl owned by the handle: the shape
// itself, plus — only for handles returned by mc_import_step — the
// STEP surface colours matched onto the shape's census faces
// (3 RGB doubles + a flag per face; empty when the file carried
// no colours). See loadStepColors() below.

namespace {

struct ShapeImpl {
  TopoDS_Shape shape;
  std::vector<std::array<double, 3>> faceRGB;
  std::vector<char> faceHas;
};

ShapeImpl& implOf(MCFacadeShape* h) {
  return *static_cast<ShapeImpl*>(h->_impl);
}
const ShapeImpl& implOf(const MCFacadeShape* h) {
  return *static_cast<const ShapeImpl*>(h->_impl);
}

// Accessor for the wrapped shape (the handle's _impl points to it).
TopoDS_Shape& shapeOf(MCFacadeShape* h) { return implOf(h).shape; }
const TopoDS_Shape& shapeOf(const MCFacadeShape* h) {
  return implOf(h).shape;
}

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
  auto* impl = new ShapeImpl();
  impl->shape = s;
  h->_impl = impl;
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
    Maker mk(shapeOf(a), shapeOf(b));
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
    TopExp::MapShapes(shapeOf(s), TopAbs_EDGE, edgeMap);
    std::vector<int> idx;
    if (edgeIndices && edgeCount > 0) {
      for (int i = 0; i < edgeCount; ++i) idx.push_back(edgeIndices[i]);
    } else {
      for (int i = 0; i < edgeMap.Extent(); ++i) idx.push_back(i);
    }
    TopoDS_Shape result;
    if (isFillet) {
      BRepFilletAPI_MakeFillet mk(shapeOf(s));
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
      BRepFilletAPI_MakeChamfer mk(shapeOf(s));
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

// ------------------------------------------------------------ FEM
// Section 11's implementation: the project's own numerical code
// (see the header for the method and its stated limits). OCCT is
// used for geometry queries only — BRepClass3d_SolidClassifier
// decides which voxel cells are inside, BRepExtrema_DistShapeShape
// maps B-rep faces to mesh nodes, the census supplies face
// indices. Everything numerical (element stiffness, assembly,
// PCG, stress recovery) is plain C++ below.

struct FemMeshImpl {
  TopoDS_Shape shape;  // kept alive: face indices refer to it
  double voxel = 0.0;
  double origin[3] = {0, 0, 0};  // grid origin (bbox min)
  int cells[3] = {0, 0, 0};      // grid cells per axis
  std::vector<double> nodePos;   // 3 per node
  std::vector<int> elems;        // 8 node indices per element
  std::vector<int> surfQuads;    // 4 node indices per boundary quad
  std::vector<int> surfQuadFace; // census face per quad, or -1
  std::vector<int> surfNodes;    // sorted unique boundary nodes
  std::vector<TopoDS_Face> faces;      // census order
  std::vector<Bnd_Box> faceBoxes;      // per-face optimal bboxes
  std::map<int, std::vector<int>> nodesOnFaceCache;
};

struct FemResultImpl {
  int nodeCount = 0;
  std::vector<double> disp;    // 3 per node
  std::vector<double> nodeVM;  // node-averaged von Mises
  std::vector<double> elemVM;  // per-element centroid von Mises
  double maxVM = 0.0;
  double maxDisp = 0.0;
  int iterations = 0;
  double relResidual = 0.0;
};

FemMeshImpl& femOf(MCFacadeFemMesh* h) {
  return *static_cast<FemMeshImpl*>(h->_impl);
}
const FemMeshImpl& femOf(const MCFacadeFemMesh* h) {
  return *static_cast<const FemMeshImpl*>(h->_impl);
}
FemResultImpl& femResOf(MCFacadeFemResult* h) {
  return *static_cast<FemResultImpl*>(h->_impl);
}

// Point (node) to B-rep face distance via OCCT's distance query.
// Returns +infinity when the query does not complete.
double femPointFaceDistance(const gp_Pnt& p, const TopoDS_Face& face) {
  BRepBuilderAPI_MakeVertex mk(p);
  BRepExtrema_DistShapeShape dss(mk.Vertex(), face);
  dss.Perform();
  if (!dss.IsDone()) return 1e300;
  return dss.Value();
}

bool femPointInBox(const gp_Pnt& p, const Bnd_Box& box, double inflate) {
  double x0, y0, z0, x1, y1, z1;
  box.Get(x0, y0, z0, x1, y1, z1);
  return p.X() >= x0 - inflate && p.X() <= x1 + inflate &&
         p.Y() >= y0 - inflate && p.Y() <= y1 + inflate &&
         p.Z() >= z0 - inflate && p.Z() <= z1 + inflate;
}

// The nodes-on-face computation behind mc_fem_nodes_on_face and
// the solver's load mapping (cached on the mesh).
const std::vector<int>& femNodesOnFace(FemMeshImpl& m, int faceIndex) {
  auto it = m.nodesOnFaceCache.find(faceIndex);
  if (it != m.nodesOnFaceCache.end()) return it->second;
  std::vector<int> out;
  const TopoDS_Face& face = m.faces[(size_t)faceIndex];
  const Bnd_Box& box = m.faceBoxes[(size_t)faceIndex];
  const double tol = 0.75 * m.voxel;
  for (int n : m.surfNodes) {
    const gp_Pnt p(m.nodePos[3 * (size_t)n], m.nodePos[3 * (size_t)n + 1],
                   m.nodePos[3 * (size_t)n + 2]);
    if (!femPointInBox(p, box, tol)) continue;
    if (femPointFaceDistance(p, face) < tol) out.push_back(n);
  }
  auto res = m.nodesOnFaceCache.emplace(faceIndex, std::move(out));
  return res.first->second;
}

// Isotropic elasticity matrix (Voigt, engineering shear strains).
void femDMatrix(double E, double nu, double D[6][6]) {
  for (int i = 0; i < 6; ++i)
    for (int j = 0; j < 6; ++j) D[i][j] = 0.0;
  const double c = E / ((1.0 + nu) * (1.0 - 2.0 * nu));
  D[0][0] = D[1][1] = D[2][2] = c * (1.0 - nu);
  D[0][1] = D[0][2] = D[1][0] = D[1][2] = D[2][0] = D[2][1] = c * nu;
  D[3][3] = D[4][4] = D[5][5] = c * (1.0 - 2.0 * nu) / 2.0;
}

// Strain-displacement matrix of the trilinear hex8 at parametric
// point (a, b, c) for a cube element of side h. Local node order
// matches the connectivity order documented in the header.
void femBMatrix(double h, double a, double b, double c, double B[6][24]) {
  static const double sgn[8][3] = {{-1, -1, -1}, {1, -1, -1}, {1, 1, -1},
                                   {-1, 1, -1}, {-1, -1, 1}, {1, -1, 1},
                                   {1, 1, 1},   {-1, 1, 1}};
  for (int i = 0; i < 6; ++i)
    for (int j = 0; j < 24; ++j) B[i][j] = 0.0;
  const double s = 2.0 / h;  // d(parametric)/d(cartesian)
  for (int i = 0; i < 8; ++i) {
    const double dNx = 0.125 * sgn[i][0] * (1.0 + b * sgn[i][1]) *
                       (1.0 + c * sgn[i][2]) * s;
    const double dNy = 0.125 * (1.0 + a * sgn[i][0]) * sgn[i][1] *
                       (1.0 + c * sgn[i][2]) * s;
    const double dNz = 0.125 * (1.0 + a * sgn[i][0]) *
                       (1.0 + b * sgn[i][1]) * sgn[i][2] * s;
    B[0][3 * i + 0] = dNx;
    B[1][3 * i + 1] = dNy;
    B[2][3 * i + 2] = dNz;
    B[3][3 * i + 0] = dNy;
    B[3][3 * i + 1] = dNx;
    B[4][3 * i + 1] = dNz;
    B[4][3 * i + 2] = dNy;
    B[5][3 * i + 0] = dNz;
    B[5][3 * i + 2] = dNx;
  }
}

// Element stiffness of the voxel cube: full 2x2x2 Gauss
// integration. Every element of a voxel mesh is the same cube, so
// one matrix serves the mesh (exact here, not an approximation).
void femStiffness(double h, double E, double nu, double Ke[24][24]) {
  double D[6][6];
  femDMatrix(E, nu, D);
  for (int i = 0; i < 24; ++i)
    for (int j = 0; j < 24; ++j) Ke[i][j] = 0.0;
  const double g = 0.57735026918962577651;  // 1/sqrt(3)
  const double detJ = (h / 2.0) * (h / 2.0) * (h / 2.0);
  const double pts[2] = {-g, g};
  for (int ia = 0; ia < 2; ++ia)
    for (int ib = 0; ib < 2; ++ib)
      for (int ic = 0; ic < 2; ++ic) {
        double B[6][24];
        femBMatrix(h, pts[ia], pts[ib], pts[ic], B);
        // Ke += B^T D B detJ (all Gauss weights are 1)
        double DB[6][24];
        for (int r = 0; r < 6; ++r)
          for (int j = 0; j < 24; ++j) {
            double ssum = 0.0;
            for (int k = 0; k < 6; ++k) ssum += D[r][k] * B[k][j];
            DB[r][j] = ssum;
          }
        for (int i = 0; i < 24; ++i)
          for (int j = 0; j < 24; ++j) {
            double ssum = 0.0;
            for (int r = 0; r < 6; ++r) ssum += B[r][i] * DB[r][j];
            Ke[i][j] += ssum * detJ;
          }
      }
}

double femVonMises(const double s[6]) {
  const double d1 = s[0] - s[1], d2 = s[1] - s[2], d3 = s[2] - s[0];
  return std::sqrt(0.5 * (d1 * d1 + d2 * d2 + d3 * d3) +
                   3.0 * (s[3] * s[3] + s[4] * s[4] + s[5] * s[5]));
}

// ------------------------------------------------------- STEP colours
// Best-effort surface-colour read for mc_import_step: reads the
// same file a second way, through OCCT's XDE document layer
// (STEPCAFControl_Reader into a TDocStd_Document created directly
// — no application object, no presentation drivers), and matches
// XCAFDoc_ColorTool surface colours onto the census faces of the
// shape the plain reader produced. The document's shapes are
// different instances from the imported shape's, so the match is
// geometric: a census face first looks for a document face with
// the same area and centroid that carries a face colour; failing
// that, it takes the colour of the document solid that contains
// its centroid. Any failure anywhere leaves the handle colourless
// — colours are decoration and never fail an import.
void loadStepColors(const char* path, ShapeImpl* impl) {
  try {
    STEPCAFControl_Reader reader;
    reader.SetColorMode(Standard_True);
    if (reader.ReadFile(path) != IFSelect_RetDone) return;
    Handle(TDocStd_Document) doc = new TDocStd_Document("MDTV-XCAF");
    if (!reader.Transfer(doc)) return;
    Handle(XCAFDoc_ShapeTool) shapeTool =
        XCAFDoc_DocumentTool::ShapeTool(doc->Main());
    Handle(XCAFDoc_ColorTool) colorTool =
        XCAFDoc_DocumentTool::ColorTool(doc->Main());
    if (shapeTool.IsNull() || colorTool.IsNull()) return;

    // The document's free shapes in one compound, for traversal.
    NCollection_Sequence<TDF_Label> freeLabels;
    shapeTool->GetFreeShapes(freeLabels);
    if (freeLabels.IsEmpty()) return;
    BRep_Builder bb;
    TopoDS_Compound compound;
    bb.MakeCompound(compound);
    for (int i = 1; i <= freeLabels.Length(); ++i) {
      TopoDS_Shape s;
      if (shapeTool->GetShape(freeLabels.Value(i), s) && !s.IsNull())
        bb.Add(compound, s);
    }

    // Document faces with their solid ancestors and their own
    // face colours (if any); document solids with their colours.
    struct DocFace {
      double area;
      gp_Pnt centre;
      bool hasColor;
      std::array<double, 3> rgb;
    };
    std::vector<DocFace> docFaces;
    NCollection_IndexedDataMap<TopoDS_Shape,
                               NCollection_List<TopoDS_Shape>,
                               TopTools_ShapeMapHasher>
        faceAncestors;
    TopExp::MapShapesAndAncestors(compound, TopAbs_FACE, TopAbs_SOLID,
                                  faceAncestors);
    for (int i = 1; i <= faceAncestors.Extent(); ++i) {
      const TopoDS_Shape& df = faceAncestors.FindKey(i);
      GProp_GProps props;
      BRepGProp::SurfaceProperties(df, props);
      DocFace rec;
      rec.area = props.Mass();
      rec.centre = props.CentreOfMass();
      Quantity_Color col;
      rec.hasColor = colorTool->GetColor(df, XCAFDoc_ColorSurf, col);
      rec.rgb = {col.Red(), col.Green(), col.Blue()};
      docFaces.push_back(rec);
    }
    struct DocSolid {
      TopoDS_Shape shape;
      bool hasColor;
      std::array<double, 3> rgb;
    };
    std::vector<DocSolid> docSolids;
    NCollection_IndexedMap<TopoDS_Shape, TopTools_ShapeMapHasher>
        solidMap;
    TopExp::MapShapes(compound, TopAbs_SOLID, solidMap);
    for (int i = 1; i <= solidMap.Extent(); ++i) {
      DocSolid rec;
      rec.shape = solidMap.FindKey(i);
      Quantity_Color col;
      rec.hasColor = colorTool->GetColor(rec.shape, XCAFDoc_ColorSurf, col);
      rec.rgb = {col.Red(), col.Green(), col.Blue()};
      docSolids.push_back(rec);
    }
    bool anyColor = false;
    for (const DocFace& d : docFaces) anyColor = anyColor || d.hasColor;
    for (const DocSolid& d : docSolids) anyColor = anyColor || d.hasColor;
    if (!anyColor) return;

    // Census faces of the imported shape (the shared index space).
    NCollection_IndexedMap<TopoDS_Shape, TopTools_ShapeMapHasher>
        faceMap;
    TopExp::MapShapes(impl->shape, TopAbs_FACE, faceMap);
    const int nFaces = faceMap.Extent();
    impl->faceRGB.assign(nFaces, {0.0, 0.0, 0.0});
    impl->faceHas.assign(nFaces, 0);
    for (int i = 1; i <= nFaces; ++i) {
      GProp_GProps props;
      BRepGProp::SurfaceProperties(faceMap.FindKey(i), props);
      const double area = props.Mass();
      const gp_Pnt centre = props.CentreOfMass();
      // 1) a document face with this face's own colour.
      bool matched = false;
      for (const DocFace& d : docFaces) {
        if (!d.hasColor) continue;
        if (std::fabs(d.area - area) > 1e-4 * std::max(1.0, area))
          continue;
        if (d.centre.Distance(centre) > 1e-3) continue;
        impl->faceRGB[i - 1] = d.rgb;
        impl->faceHas[i - 1] = 1;
        matched = true;
        break;
      }
      if (matched) continue;
      // 2) the colour of the document solid containing the face.
      for (const DocSolid& d : docSolids) {
        if (!d.hasColor) continue;
        BRepClass3d_SolidClassifier cls(d.shape, centre,
                                        Precision::Confusion());
        if (cls.State() == TopAbs_IN || cls.State() == TopAbs_ON) {
          impl->faceRGB[i - 1] = d.rgb;
          impl->faceHas[i - 1] = 1;
          break;
        }
      }
    }
  } catch (...) {
    impl->faceRGB.clear();
    impl->faceHas.clear();
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

MCFacadeShape* mc_torus(double ringRadius, double tubeRadius, int* err) {
  try {
    BRepPrimAPI_MakeTorus mk(ringRadius, tubeRadius);
    mk.Build();
    return wrap(mk.Shape(), err);
  } catch (const Standard_Failure& e) {
    setOcctError(err, "mc_torus", e);
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
  if (shapeOf(face).ShapeType() != TopAbs_FACE) {
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
    BRepPrimAPI_MakePrism mk(shapeOf(face), v.Multiplied(dist));
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

// ------------------------------------------------------------ transforms

MCFacadeShape* mc_transform(MCFacadeShape* s, const double m[12],
                            int* err) {
  if (!s || !m) {
    fail(err, MC_ERR_INVALID_ARG, "null argument");
    return nullptr;
  }
  try {
    gp_GTrsf g;
    // gp_GTrsf::SetValue takes 1-based (row, col); the linear part
    // occupies (1..3, 1..3) and the translation (1..3, 4).
    for (int r = 0; r < 3; ++r)
      for (int c = 0; c < 4; ++c) g.SetValue(r + 1, c + 1, m[r * 4 + c]);
    const double det = m[0] * (m[5] * m[10] - m[6] * m[9]) -
                       m[1] * (m[4] * m[10] - m[6] * m[8]) +
                       m[2] * (m[4] * m[9] - m[5] * m[8]);
    if (std::fabs(det) < 1e-12) {
      fail(err, MC_ERR_INVALID_ARG, "mc_transform: singular matrix");
      return nullptr;
    }
    BRepBuilderAPI_GTransform mk(shapeOf(s), g, true);
    mk.Build();
    if (!mk.IsDone() || mk.Shape().IsNull()) {
      fail(err, MC_ERR_OCCT, "mc_transform: builder not done");
      return nullptr;
    }
    return wrap(mk.Shape(), err);
  } catch (const Standard_Failure& e) {
    setOcctError(err, "mc_transform", e);
    return nullptr;
  }
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
    mk.MakeThickSolidByJoin(shapeOf(s), noOpenings, -thickness,
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
    args.Append(shapeOf(s));
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

MCFacadeShape* mc_draft(MCFacadeShape* s, const double pullDir[3],
                        double angleDeg, const double neutralPoint[3],
                        int* err) {
  if (!s || !pullDir || !neutralPoint) {
    fail(err, MC_ERR_INVALID_ARG, "null argument");
    return nullptr;
  }
  try {
    gp_Dir dir(pullDir[0], pullDir[1], pullDir[2]);
    gp_Pln neutral(gp_Pnt(neutralPoint[0], neutralPoint[1],
                          neutralPoint[2]),
                   dir);
    const double angle = angleDeg * M_PI / 180.0;
    NCollection_IndexedMap<TopoDS_Shape, TopTools_ShapeMapHasher> faceMap;
    TopExp::MapShapes(shapeOf(s), TopAbs_FACE, faceMap);
    BRepOffsetAPI_DraftAngle mk(shapeOf(s));
    int added = 0;
    for (int i = 1; i <= faceMap.Extent(); ++i) {
      TopoDS_Face face = TopoDS::Face(faceMap.FindKey(i));
      BRepAdaptor_Surface surf(face);
      const GeomAbs_SurfaceType type = surf.GetType();
      bool eligible = false;
      if (type == GeomAbs_Plane) {
        // A plane whose normal runs along the pull direction is a
        // cap: it translates with its neighbours, it is not rotated.
        gp_Dir n = surf.Plane().Axis().Direction();
        if (face.Orientation() == TopAbs_REVERSED) n.Reverse();
        eligible = std::fabs(n.Dot(dir)) < 0.999;
      } else if (type == GeomAbs_Cylinder) {
        gp_Dir ax = surf.Cylinder().Axis().Direction();
        eligible = std::fabs(ax.Dot(dir)) > 0.7;
      } else if (type == GeomAbs_Cone) {
        gp_Dir ax = surf.Cone().Axis().Direction();
        eligible = std::fabs(ax.Dot(dir)) > 0.7;
      }
      if (!eligible) continue;
      mk.Add(face, dir, angle, neutral);
      if (!mk.AddDone()) {
        fail(err, MC_ERR_OCCT,
             "mc_draft: a face refused the draft angle");
        return nullptr;
      }
      ++added;
    }
    if (added == 0) {
      fail(err, MC_ERR_OCCT,
           "mc_draft: no draftable side faces for that pull direction");
      return nullptr;
    }
    mk.Build();
    if (!mk.IsDone() || mk.Shape().IsNull()) {
      fail(err, MC_ERR_OCCT, "mc_draft: builder not done");
      return nullptr;
    }
    return wrap(mk.Shape(), err);
  } catch (const Standard_Failure& e) {
    setOcctError(err, "mc_draft", e);
    return nullptr;
  }
}

double mc_volume(MCFacadeShape* s, int* err) {
  if (!s) {
    fail(err, MC_ERR_INVALID_ARG, "null shape handle");
    return 0.0;
  }
  try {
    GProp_GProps props;
    BRepGProp::VolumeProperties(shapeOf(s), props);
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
    BRepGProp::SurfaceProperties(shapeOf(s), props);
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
    BRepBndLib::AddOptimal(shapeOf(s), box, Standard_False,
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
  TopExp::MapShapes(shapeOf(s), TopAbs_EDGE, edgeMap);
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
    cls.Load(shapeOf(s));
    cls.Perform(gp_Pnt(x, y, z), 1e-7);
    if (err) *err = MC_OK;
    return cls.State() == TopAbs_IN ? 1 : 0;
  } catch (const Standard_Failure& e) {
    setOcctError(err, "mc_contains", e);
    return -1;
  }
}

// ------------------------------------------------------- selection census
// The enumeration behind every function here is TopExp::MapShapes
// — the TopExp traversal that records each distinct sub-shape at
// its first occurrence. edgeOp (fillet/chamfer) and mc_edge_count
// already index edges from the same map, so census indices and
// finishing indices line up by construction.

int mc_shape_counts(MCFacadeShape* s, int* faces, int* edges,
                    int* vertices, int* err) {
  if (!s) {
    return fail(err, MC_ERR_INVALID_ARG, "null shape handle");
  }
  try {
    if (faces) {
      NCollection_IndexedMap<TopoDS_Shape, TopTools_ShapeMapHasher> m;
      TopExp::MapShapes(shapeOf(s), TopAbs_FACE, m);
      *faces = m.Extent();
    }
    if (edges) {
      NCollection_IndexedMap<TopoDS_Shape, TopTools_ShapeMapHasher> m;
      TopExp::MapShapes(shapeOf(s), TopAbs_EDGE, m);
      *edges = m.Extent();
    }
    if (vertices) {
      NCollection_IndexedMap<TopoDS_Shape, TopTools_ShapeMapHasher> m;
      TopExp::MapShapes(shapeOf(s), TopAbs_VERTEX, m);
      *vertices = m.Extent();
    }
    if (err) *err = MC_OK;
    return MC_OK;
  } catch (const Standard_Failure& e) {
    setOcctError(err, "mc_shape_counts", e);
    return MC_ERR_OCCT;
  }
}

int mc_face_info(MCFacadeShape* s, int faceIndex, double* area,
                 double center[3], double normal[3], int* isPlanar,
                 int* err) {
  if (!s) {
    return fail(err, MC_ERR_INVALID_ARG, "null shape handle");
  }
  try {
    NCollection_IndexedMap<TopoDS_Shape, TopTools_ShapeMapHasher> faceMap;
    TopExp::MapShapes(shapeOf(s), TopAbs_FACE, faceMap);
    if (faceIndex < 0 || faceIndex >= faceMap.Extent()) {
      return fail(err, MC_ERR_INVALID_ARG, "face index out of range");
    }
    const TopoDS_Face face = TopoDS::Face(faceMap.FindKey(faceIndex + 1));
    if (area || center) {
      GProp_GProps props;
      BRepGProp::SurfaceProperties(face, props);
      if (area) *area = props.Mass();
      if (center) {
        const gp_Pnt c = props.CentreOfMass();
        center[0] = c.X();
        center[1] = c.Y();
        center[2] = c.Z();
      }
    }
    BRepAdaptor_Surface adaptor(face);
    const bool planar = adaptor.GetType() == GeomAbs_Plane;
    if (isPlanar) *isPlanar = planar ? 1 : 0;
    if (normal) {
      if (planar) {
        gp_Dir d = adaptor.Plane().Axis().Direction();
        if (face.Orientation() == TopAbs_REVERSED) d.Reverse();
        normal[0] = d.X();
        normal[1] = d.Y();
        normal[2] = d.Z();
      } else {
        normal[0] = normal[1] = normal[2] = 0.0;
      }
    }
    if (err) *err = MC_OK;
    return MC_OK;
  } catch (const Standard_Failure& e) {
    setOcctError(err, "mc_face_info", e);
    return MC_ERR_OCCT;
  }
}

int mc_edge_info(MCFacadeShape* s, int edgeIndex, int* curveType,
                 double* length, double start[3], double end[3],
                 double center[3], double* radius, int* err) {
  if (!s) {
    return fail(err, MC_ERR_INVALID_ARG, "null shape handle");
  }
  try {
    NCollection_IndexedMap<TopoDS_Shape, TopTools_ShapeMapHasher> edgeMap;
    TopExp::MapShapes(shapeOf(s), TopAbs_EDGE, edgeMap);
    if (edgeIndex < 0 || edgeIndex >= edgeMap.Extent()) {
      return fail(err, MC_ERR_INVALID_ARG, "edge index out of range");
    }
    const TopoDS_Edge edge = TopoDS::Edge(edgeMap.FindKey(edgeIndex + 1));
    BRepAdaptor_Curve adaptor(edge);
    const GeomAbs_CurveType type = adaptor.GetType();
    if (curveType) {
      *curveType = type == GeomAbs_Line    ? 0
                   : type == GeomAbs_Circle ? 1
                                            : 2;
    }
    if (length) {
      // OCCT 8.0.1's entry point for curve properties is
      // LinearProperties (there is no BRepGProp::EdgeProperties);
      // its Mass() is the edge length.
      GProp_GProps props;
      BRepGProp::LinearProperties(edge, props);
      *length = props.Mass();
    }
    if (start) {
      const gp_Pnt p = BRep_Tool::Pnt(TopExp::FirstVertex(edge, Standard_True));
      start[0] = p.X();
      start[1] = p.Y();
      start[2] = p.Z();
    }
    if (end) {
      const gp_Pnt p = BRep_Tool::Pnt(TopExp::LastVertex(edge, Standard_True));
      end[0] = p.X();
      end[1] = p.Y();
      end[2] = p.Z();
    }
    if (center || radius) {
      if (type == GeomAbs_Circle) {
        const gp_Circ circ = adaptor.Circle();
        if (center) {
          const gp_Pnt c = circ.Location();
          center[0] = c.X();
          center[1] = c.Y();
          center[2] = c.Z();
        }
        if (radius) *radius = circ.Radius();
      } else {
        if (center) center[0] = center[1] = center[2] = 0.0;
        if (radius) *radius = 0.0;
      }
    }
    if (err) *err = MC_OK;
    return MC_OK;
  } catch (const Standard_Failure& e) {
    setOcctError(err, "mc_edge_info", e);
    return MC_ERR_OCCT;
  }
}

int mc_shape_face_colors(MCFacadeShape* s, double* outRGB,
                         int* outHasColor, int* err) {
  if (!s) {
    return fail(err, MC_ERR_INVALID_ARG,
                "mc_shape_face_colors: null shape");
  }
  try {
    const ShapeImpl& impl = implOf(s);
    NCollection_IndexedMap<TopoDS_Shape, TopTools_ShapeMapHasher>
        faceMap;
    TopExp::MapShapes(impl.shape, TopAbs_FACE, faceMap);
    const int n = faceMap.Extent();
    const bool have = (int)impl.faceHas.size() == n;
    for (int i = 0; i < n; ++i) {
      const bool has = have && impl.faceHas[i] != 0;
      if (outHasColor) outHasColor[i] = has ? 1 : 0;
      if (outRGB) {
        outRGB[3 * i + 0] = has ? impl.faceRGB[i][0] : 0.0;
        outRGB[3 * i + 1] = has ? impl.faceRGB[i][1] : 0.0;
        outRGB[3 * i + 2] = has ? impl.faceRGB[i][2] : 0.0;
      }
    }
    if (err) *err = MC_OK;
    return MC_OK;
  } catch (const Standard_Failure& e) {
    setOcctError(err, "mc_shape_face_colors", e);
    return MC_ERR_OCCT;
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
    BRepMesh_IncrementalMesh mesher(shapeOf(s), deflectionMM, Standard_False,
                                    0.5, Standard_True);
    mesher.Perform();

    NCollection_IndexedMap<TopoDS_Shape, TopTools_ShapeMapHasher> faceMap;
    TopExp::MapShapes(shapeOf(s), TopAbs_FACE, faceMap);
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

// ------------------------------------------------------------ import / export

MCFacadeShape* mc_import_step(const char* path, int* solidCount, int* err) {
  if (!path || !*path) {
    fail(err, MC_ERR_INVALID_ARG, "mc_import_step: empty path");
    return nullptr;
  }
  try {
    STEPControl_Reader reader;
    if (reader.ReadFile(path) != IFSelect_RetDone) {
      fail(err, MC_ERR_OCCT,
           "mc_import_step: STEP reader could not read the file");
      return nullptr;
    }
    reader.TransferRoots();
    const TopoDS_Shape shape = reader.OneShape();
    if (shape.IsNull()) {
      fail(err, MC_ERR_EMPTY_RESULT,
           "mc_import_step: file contains no shape");
      return nullptr;
    }
    if (solidCount) {
      int n = 0;
      for (TopExp_Explorer ex(shape, TopAbs_SOLID); ex.More(); ex.Next()) ++n;
      *solidCount = n;
    }
    MCFacadeShape* h = wrap(shape, err);
    if (h) loadStepColors(path, &implOf(h));  // best-effort; see above
    return h;
  } catch (const Standard_Failure& e) {
    setOcctError(err, "mc_import_step", e);
    return nullptr;
  }
}

int mc_export_step(MCFacadeShape* s, const char* path, int* err) {
  if (!s || !path || !*path) {
    return fail(err, MC_ERR_INVALID_ARG, "mc_export_step: bad argument");
  }
  try {
    STEPControl_Writer writer;
    if (writer.Transfer(shapeOf(s), STEPControl_AsIs) != IFSelect_RetDone) {
      return fail(err, MC_ERR_OCCT, "mc_export_step: transfer failed");
    }
    if (writer.Write(path) != IFSelect_RetDone) {
      return fail(err, MC_ERR_OCCT, "mc_export_step: write failed");
    }
    if (err) *err = MC_OK;
    return MC_OK;
  } catch (const Standard_Failure& e) {
    setOcctError(err, "mc_export_step", e);
    return MC_ERR_OCCT;
  }
}

// ------------------------------------------------------------ FEM
// Section 11: voxel mesher + linear-static solver (the project's
// own numerical code; see occt_facade.h for the method statement).

MCFacadeFemMesh* mc_fem_mesh(MCFacadeShape* shape, double voxelSizeMM,
                             int* err) {
  if (!shape) {
    fail(err, MC_ERR_INVALID_ARG, "mc_fem_mesh: null shape handle");
    return nullptr;
  }
  if (!(voxelSizeMM > 0.0)) {
    fail(err, MC_ERR_INVALID_ARG, "mc_fem_mesh: voxel size must be > 0");
    return nullptr;
  }
  try {
    const TopoDS_Shape& src = shapeOf(shape);
    // Solids to classify against (a compound contributes each of
    // its solids; a lone solid contributes itself).
    std::vector<TopoDS_Shape> solids;
    for (TopExp_Explorer ex(src, TopAbs_SOLID); ex.More(); ex.Next())
      solids.push_back(ex.Current());
    if (solids.empty()) {
      fail(err, MC_ERR_OCCT, "mc_fem_mesh: shape contains no solid");
      return nullptr;
    }
    Bnd_Box bb;
    BRepBndLib::AddOptimal(src, bb, Standard_False, Standard_False);
    if (bb.IsVoid()) {
      fail(err, MC_ERR_EMPTY_RESULT, "mc_fem_mesh: bounding box is void");
      return nullptr;
    }
    double mn[3], mx[3];
    bb.Get(mn[0], mn[1], mn[2], mx[0], mx[1], mx[2]);
    const double h = voxelSizeMM;
    int cells[3];
    for (int a = 0; a < 3; ++a) {
      cells[a] =
          std::max(1, (int)std::ceil((mx[a] - mn[a]) / h - 1e-9));
    }
    const long long scanned =
        (long long)cells[0] * cells[1] * cells[2];
    if (scanned > 8000000LL) {
      fail(err, MC_ERR_INVALID_ARG,
           "mc_fem_mesh: voxel size too small for this shape (grid "
           "scan cap exceeded) — use a larger voxel size");
      return nullptr;
    }

    std::vector<std::unique_ptr<BRepClass3d_SolidClassifier>> classifiers;
    for (const TopoDS_Shape& s : solids) {
      auto cls = std::make_unique<BRepClass3d_SolidClassifier>();
      cls->Load(s);
      classifiers.push_back(std::move(cls));
    }
    auto inside = [&](const gp_Pnt& p) {
      for (auto& cls : classifiers) {
        cls->Perform(p, 1e-7);
        if (cls->State() == TopAbs_IN) return true;
      }
      return false;
    };

    auto* impl = new FemMeshImpl();
    impl->shape = src;
    impl->voxel = h;
    for (int a = 0; a < 3; ++a) {
      impl->origin[a] = mn[a];
      impl->cells[a] = cells[a];
    }
    const int nx = cells[0], ny = cells[1], nz = cells[2];
    std::vector<int> gridId(
        (size_t)(nx + 1) * (ny + 1) * (nz + 1), -1);
    auto gridIndex = [&](int i, int j, int k) {
      return ((size_t)i * (ny + 1) + (size_t)j) * (nz + 1) + (size_t)k;
    };
    // Cell corner offsets in the documented hex8 order.
    static const int corner[8][3] = {{0, 0, 0}, {1, 0, 0}, {1, 1, 0},
                                     {0, 1, 0}, {0, 0, 1}, {1, 0, 1},
                                     {1, 1, 1}, {0, 1, 1}};
    bool capHit = false;
    for (int i = 0; i < nx && !capHit; ++i)
      for (int j = 0; j < ny && !capHit; ++j)
        for (int k = 0; k < nz; ++k) {
          const gp_Pnt centre(mn[0] + (i + 0.5) * h, mn[1] + (j + 0.5) * h,
                              mn[2] + (k + 0.5) * h);
          if (!inside(centre)) continue;
          if ((int)(impl->elems.size() / 8) >= MC_FEM_MAX_ELEMENTS) {
            capHit = true;
            break;
          }
          for (const auto& c : corner) {
            const int gi = i + c[0], gj = j + c[1], gk = k + c[2];
            const size_t idx = gridIndex(gi, gj, gk);
            int id = gridId[idx];
            if (id < 0) {
              id = (int)(impl->nodePos.size() / 3);
              gridId[idx] = id;
              impl->nodePos.push_back(mn[0] + gi * h);
              impl->nodePos.push_back(mn[1] + gj * h);
              impl->nodePos.push_back(mn[2] + gk * h);
            }
            impl->elems.push_back(id);
          }
        }
    if (capHit) {
      delete impl;
      fail(err, MC_ERR_INVALID_ARG,
           "mc_fem_mesh: mesh would exceed the element cap "
           "(250000) — use a larger voxel size");
      return nullptr;
    }
    if (impl->elems.empty()) {
      delete impl;
      fail(err, MC_ERR_EMPTY_RESULT,
           "mc_fem_mesh: no voxel centre fell inside the solid — use "
           "a smaller voxel size");
      return nullptr;
    }

    // Boundary surface: a quad (4 nodes) shared by exactly one
    // element. Local face node orders follow the outward-normal
    // right-hand rule (see header).
    static const int lface[6][4] = {{0, 3, 2, 1}, {4, 5, 6, 7},
                                    {0, 1, 5, 4}, {3, 7, 6, 2},
                                    {0, 4, 7, 3}, {1, 2, 6, 5}};
    struct QuadRef {
      int count = 0;
      int elem = -1;
      int face = -1;
    };
    std::map<std::array<int, 4>, QuadRef> quadMap;
    const int nElem = (int)(impl->elems.size() / 8);
    for (int e = 0; e < nElem; ++e) {
      for (int f = 0; f < 6; ++f) {
        std::array<int, 4> key = {impl->elems[8 * (size_t)e + lface[f][0]],
                                  impl->elems[8 * (size_t)e + lface[f][1]],
                                  impl->elems[8 * (size_t)e + lface[f][2]],
                                  impl->elems[8 * (size_t)e + lface[f][3]]};
        std::array<int, 4> sorted = key;
        std::sort(sorted.begin(), sorted.end());
        QuadRef& ref = quadMap[sorted];
        if (ref.count == 0) {
          ref.elem = e;
          ref.face = f;
        }
        ++ref.count;
      }
    }
    std::vector<std::array<int, 4>> boundary;  // outward node order
    for (const auto& kv : quadMap) {
      if (kv.second.count != 1) continue;
      const int e = kv.second.elem, f = kv.second.face;
      std::array<int, 4> q = {impl->elems[8 * (size_t)e + lface[f][0]],
                              impl->elems[8 * (size_t)e + lface[f][1]],
                              impl->elems[8 * (size_t)e + lface[f][2]],
                              impl->elems[8 * (size_t)e + lface[f][3]]};
      boundary.push_back(q);
      for (int n : q) impl->surfQuads.push_back(n);
    }
    // Surface nodes: the sorted unique set the boundary uses.
    {
      std::vector<int> sn = impl->surfQuads;
      std::sort(sn.begin(), sn.end());
      sn.erase(std::unique(sn.begin(), sn.end()), sn.end());
      impl->surfNodes = std::move(sn);
    }
    // Census faces + their boxes (the shared index space), then
    // the boundary-quad -> B-rep-face association: the face
    // nearest each quad's centre.
    {
      NCollection_IndexedMap<TopoDS_Shape, TopTools_ShapeMapHasher>
          faceMap;
      TopExp::MapShapes(src, TopAbs_FACE, faceMap);
      for (int fi = 1; fi <= faceMap.Extent(); ++fi) {
        const TopoDS_Face face = TopoDS::Face(faceMap.FindKey(fi));
        impl->faces.push_back(face);
        Bnd_Box fb;
        BRepBndLib::AddOptimal(face, fb, Standard_False, Standard_False);
        impl->faceBoxes.push_back(fb);
      }
      const double reach = 1.5 * h;
      impl->surfQuadFace.assign(boundary.size(), -1);
      for (size_t q = 0; q < boundary.size(); ++q) {
        double cx = 0, cy = 0, cz = 0;
        for (int n : boundary[q]) {
          cx += impl->nodePos[3 * (size_t)n];
          cy += impl->nodePos[3 * (size_t)n + 1];
          cz += impl->nodePos[3 * (size_t)n + 2];
        }
        const gp_Pnt centre(cx / 4, cy / 4, cz / 4);
        double best = 1e300;
        int bestFace = -1;
        for (size_t fi = 0; fi < impl->faces.size(); ++fi) {
          if (!femPointInBox(centre, impl->faceBoxes[fi], reach)) continue;
          const double d = femPointFaceDistance(centre, impl->faces[fi]);
          if (d < best) {
            best = d;
            bestFace = (int)fi;
          }
        }
        if (best <= reach) impl->surfQuadFace[q] = bestFace;
      }
    }

    if (err) *err = MC_OK;
    auto* handle = new MCFacadeFemMesh();
    handle->_impl = impl;
    return handle;
  } catch (const Standard_Failure& e) {
    setOcctError(err, "mc_fem_mesh", e);
    return nullptr;
  }
}

void mc_free_fem_mesh(MCFacadeFemMesh* m) {
  if (!m) return;
  delete static_cast<FemMeshImpl*>(m->_impl);
  delete m;
}

int mc_fem_mesh_counts(MCFacadeFemMesh* m, int* nodes, int* elements,
                       int* surfaceQuads, int* err) {
  if (!m) return fail(err, MC_ERR_INVALID_ARG, "mc_fem_mesh_counts: null mesh");
  const FemMeshImpl& im = femOf(m);
  if (nodes) *nodes = (int)(im.nodePos.size() / 3);
  if (elements) *elements = (int)(im.elems.size() / 8);
  if (surfaceQuads) *surfaceQuads = (int)(im.surfQuads.size() / 4);
  if (err) *err = MC_OK;
  return MC_OK;
}

double mc_fem_mesh_volume(MCFacadeFemMesh* m, int* err) {
  if (!m) {
    fail(err, MC_ERR_INVALID_ARG, "mc_fem_mesh_volume: null mesh");
    return 0.0;
  }
  const FemMeshImpl& im = femOf(m);
  if (err) *err = MC_OK;
  const double h = im.voxel;
  return (double)(im.elems.size() / 8) * h * h * h;
}

double mc_fem_mesh_voxel_size(MCFacadeFemMesh* m, int* err) {
  if (!m) {
    fail(err, MC_ERR_INVALID_ARG, "mc_fem_mesh_voxel_size: null mesh");
    return 0.0;
  }
  if (err) *err = MC_OK;
  return femOf(m).voxel;
}

int mc_fem_mesh_nodes(MCFacadeFemMesh* m, double* out, int* err) {
  if (!m || !out)
    return fail(err, MC_ERR_INVALID_ARG, "mc_fem_mesh_nodes: null argument");
  const FemMeshImpl& im = femOf(m);
  std::memcpy(out, im.nodePos.data(), sizeof(double) * im.nodePos.size());
  if (err) *err = MC_OK;
  return MC_OK;
}

int mc_fem_mesh_elements(MCFacadeFemMesh* m, int* out, int* err) {
  if (!m || !out)
    return fail(err, MC_ERR_INVALID_ARG, "mc_fem_mesh_elements: null argument");
  const FemMeshImpl& im = femOf(m);
  std::memcpy(out, im.elems.data(), sizeof(int) * im.elems.size());
  if (err) *err = MC_OK;
  return MC_OK;
}

int mc_fem_mesh_surface_data(MCFacadeFemMesh* m, int* quads, int* quadFaces,
                             int* err) {
  if (!m)
    return fail(err, MC_ERR_INVALID_ARG,
                "mc_fem_mesh_surface_data: null mesh");
  const FemMeshImpl& im = femOf(m);
  if (quads)
    std::memcpy(quads, im.surfQuads.data(),
                sizeof(int) * im.surfQuads.size());
  if (quadFaces)
    std::memcpy(quadFaces, im.surfQuadFace.data(),
                sizeof(int) * im.surfQuadFace.size());
  if (err) *err = MC_OK;
  return MC_OK;
}

int mc_fem_nodes_on_face(MCFacadeFemMesh* m, int faceIndex, int* outNodes,
                         int outCapacity, int* outCount, int* err) {
  if (!m || !outCount)
    return fail(err, MC_ERR_INVALID_ARG,
                "mc_fem_nodes_on_face: null argument");
  FemMeshImpl& im = femOf(m);
  if (faceIndex < 0 || faceIndex >= (int)im.faces.size())
    return fail(err, MC_ERR_INVALID_ARG,
                "mc_fem_nodes_on_face: face index out of range");
  try {
    const std::vector<int>& nodes = femNodesOnFace(im, faceIndex);
    *outCount = (int)nodes.size();
    if (outNodes && outCapacity > 0) {
      const int n = std::min(outCapacity, (int)nodes.size());
      std::memcpy(outNodes, nodes.data(), sizeof(int) * (size_t)n);
    }
    if (err) *err = MC_OK;
    return MC_OK;
  } catch (const Standard_Failure& e) {
    setOcctError(err, "mc_fem_nodes_on_face", e);
    return MC_ERR_OCCT;
  }
}

MCFacadeFemResult* mc_fem_solve(MCFacadeFemMesh* mesh, double E, double nu,
                                const int* fixedNodes, int fixedCount,
                                const int* loadFaces,
                                const double* loadForces,
                                const double* loadDirs, int loadCount,
                                int* err) {
  if (!mesh) {
    fail(err, MC_ERR_INVALID_ARG, "mc_fem_solve: null mesh");
    return nullptr;
  }
  if (!(E > 0.0) || !(nu > -1.0 && nu < 0.5)) {
    fail(err, MC_ERR_INVALID_ARG,
         "mc_fem_solve: need E > 0 and -1 < nu < 0.5");
    return nullptr;
  }
  if (loadCount < 0 || (loadCount > 0 && (!loadFaces || !loadForces ||
                                           !loadDirs))) {
    fail(err, MC_ERR_INVALID_ARG, "mc_fem_solve: null load arrays");
    return nullptr;
  }
  if (fixedCount < 0 || (fixedCount > 0 && !fixedNodes)) {
    fail(err, MC_ERR_INVALID_ARG, "mc_fem_solve: null fixed nodes");
    return nullptr;
  }
  FemMeshImpl& im = femOf(mesh);
  const int nNode = (int)(im.nodePos.size() / 3);
  const int nElem = (int)(im.elems.size() / 8);
  const double h = im.voxel;

  std::vector<char> isFixed((size_t)nNode, 0);
  for (int i = 0; i < fixedCount; ++i) {
    const int n = fixedNodes[i];
    if (n < 0 || n >= nNode) {
      fail(err, MC_ERR_INVALID_ARG, "mc_fem_solve: fixed node out of range");
      return nullptr;
    }
    isFixed[(size_t)n] = 1;
  }
  if (fixedCount == 0) {
    fail(err, MC_ERR_FEM_SINGULAR,
         "mc_fem_solve: nothing is fixed — the stiffness is singular "
         "(rigid-body motion)");
    return nullptr;
  }
  std::vector<int> freeIndex((size_t)nNode, -1);
  int nFree = 0;
  for (int n = 0; n < nNode; ++n)
    if (!isFixed[(size_t)n]) freeIndex[(size_t)n] = nFree++;
  if (nFree == 0) {
    fail(err, MC_ERR_FEM_SINGULAR,
         "mc_fem_solve: every node is fixed — nothing to solve");
    return nullptr;
  }
  const int ndof = 3 * nFree;

  // Load vector over free dofs: each face's total force spread
  // evenly over its mapped nodes.
  std::vector<double> b((size_t)ndof, 0.0);
  try {
    for (int li = 0; li < loadCount; ++li) {
      const int fi = loadFaces[li];
      if (fi < 0 || fi >= (int)im.faces.size()) {
        fail(err, MC_ERR_INVALID_ARG, "mc_fem_solve: load face out of range");
        return nullptr;
      }
      double dir[3] = {loadDirs[3 * (size_t)li], loadDirs[3 * (size_t)li + 1],
                       loadDirs[3 * (size_t)li + 2]};
      const double dn =
          std::sqrt(dir[0] * dir[0] + dir[1] * dir[1] + dir[2] * dir[2]);
      if (dn < 1e-12) {
        fail(err, MC_ERR_INVALID_ARG,
             "mc_fem_solve: load direction is degenerate");
        return nullptr;
      }
      const std::vector<int>& nodes = femNodesOnFace(im, fi);
      if (nodes.empty()) {
        fail(err, MC_ERR_INVALID_ARG,
             "mc_fem_solve: a load face maps to no mesh nodes — refine "
             "the mesh or pick another face");
        return nullptr;
      }
      const double per = loadForces[li] / (double)nodes.size();
      for (int n : nodes) {
        const int fn = freeIndex[(size_t)n];
        if (fn < 0) continue;  // fixed node: its share is a reaction
        b[3 * (size_t)fn + 0] += per * dir[0] / dn;
        b[3 * (size_t)fn + 1] += per * dir[1] / dn;
        b[3 * (size_t)fn + 2] += per * dir[2] / dn;
      }
    }
  } catch (const Standard_Failure& e) {
    setOcctError(err, "mc_fem_solve", e);
    return nullptr;
  }
  double bNorm = 0.0;
  for (double v : b) bNorm += v * v;
  bNorm = std::sqrt(bNorm);
  if (!(bNorm > 0.0)) {
    fail(err, MC_ERR_INVALID_ARG,
         "mc_fem_solve: loads produce no force on any free node");
    return nullptr;
  }

  // Element stiffness (one cube serves the whole mesh).
  double Ke[24][24];
  femStiffness(h, E, nu, Ke);

  // ---- Assembly: block CSR over free nodes (3x3 blocks) ----
  std::vector<unsigned long long> pairs;
  pairs.reserve((size_t)nElem * 64);
  for (int e = 0; e < nElem; ++e) {
    int fn[8];
    for (int a = 0; a < 8; ++a)
      fn[a] = freeIndex[(size_t)im.elems[8 * (size_t)e + a]];
    for (int a = 0; a < 8; ++a) {
      if (fn[a] < 0) continue;
      for (int c = 0; c < 8; ++c) {
        if (fn[c] < 0) continue;
        pairs.push_back(((unsigned long long)(unsigned)fn[a] << 32) |
                        (unsigned)fn[c]);
      }
    }
  }
  std::sort(pairs.begin(), pairs.end());
  pairs.erase(std::unique(pairs.begin(), pairs.end()), pairs.end());
  const size_t nBlocks = pairs.size();
  if (nBlocks > 9000000) {
    fail(err, MC_ERR_INVALID_ARG,
         "mc_fem_solve: mesh too large to assemble — use a coarser "
         "voxel size");
    return nullptr;
  }
  std::vector<int> rowPtr((size_t)nFree + 1, 0);
  for (unsigned long long key : pairs) ++rowPtr[(size_t)(key >> 32) + 1];
  for (int i = 0; i < nFree; ++i) rowPtr[(size_t)i + 1] += rowPtr[(size_t)i];
  std::vector<int> colNodes(nBlocks, 0);
  for (size_t p = 0; p < nBlocks; ++p)
    colNodes[p] = (int)(pairs[p] & 0xffffffffULL);
  pairs.clear();
  pairs.shrink_to_fit();
  std::vector<double> vals(nBlocks * 9, 0.0);
  for (int e = 0; e < nElem; ++e) {
    int fn[8], gn[8];
    for (int a = 0; a < 8; ++a) {
      gn[a] = im.elems[8 * (size_t)e + a];
      fn[a] = freeIndex[(size_t)gn[a]];
    }
    for (int a = 0; a < 8; ++a) {
      if (fn[a] < 0) continue;
      const int rs = rowPtr[(size_t)fn[a]], re = rowPtr[(size_t)fn[a] + 1];
      for (int c = 0; c < 8; ++c) {
        if (fn[c] < 0) continue;
        const int* hit = std::lower_bound(colNodes.data() + rs,
                                          colNodes.data() + re, fn[c]);
        if (hit == colNodes.data() + re || *hit != fn[c]) continue;
        double* blk = &vals[9 * (size_t)(hit - colNodes.data())];
        for (int r = 0; r < 3; ++r)
          for (int cc = 0; cc < 3; ++cc)
            blk[3 * r + cc] += Ke[3 * a + r][3 * c + cc];
      }
    }
  }
  // Jacobi preconditioner = the diagonal; a non-positive diagonal
  // entry means the reduced stiffness is not positive definite.
  std::vector<double> diag((size_t)ndof, 0.0);
  for (int rn = 0; rn < nFree; ++rn) {
    for (int blk = rowPtr[(size_t)rn]; blk < rowPtr[(size_t)rn + 1]; ++blk) {
      if (colNodes[(size_t)blk] != rn) continue;
      for (int c = 0; c < 3; ++c)
        diag[3 * (size_t)rn + c] = vals[9 * (size_t)blk + 3 * c + c];
    }
  }
  for (int i = 0; i < ndof; ++i) {
    if (!(diag[(size_t)i] > 0.0)) {
      fail(err, MC_ERR_FEM_SINGULAR,
           "mc_fem_solve: stiffness has a non-positive diagonal — the "
           "part is not fixed enough");
      return nullptr;
    }
  }

  auto matvec = [&](const std::vector<double>& x, std::vector<double>& y) {
    std::fill(y.begin(), y.end(), 0.0);
    for (int rn = 0; rn < nFree; ++rn) {
      double y0 = 0.0, y1 = 0.0, y2 = 0.0;
      for (int blk = rowPtr[(size_t)rn]; blk < rowPtr[(size_t)rn + 1];
           ++blk) {
        const int cn = colNodes[(size_t)blk];
        const double* K = &vals[9 * (size_t)blk];
        const double x0 = x[3 * (size_t)cn], x1 = x[3 * (size_t)cn + 1],
                     x2 = x[3 * (size_t)cn + 2];
        y0 += K[0] * x0 + K[1] * x1 + K[2] * x2;
        y1 += K[3] * x0 + K[4] * x1 + K[5] * x2;
        y2 += K[6] * x0 + K[7] * x1 + K[8] * x2;
      }
      y[3 * (size_t)rn] = y0;
      y[3 * (size_t)rn + 1] = y1;
      y[3 * (size_t)rn + 2] = y2;
    }
  };

  // ---- Preconditioned conjugate gradients (Jacobi) ----
  // Convergence is accepted ONLY on the recomputed (true)
  // residual r = b - A x: the recursive CG residual can drift
  // from it, and on a singular-but-almost-consistent system (say,
  // one clamped node leaving rigid-body modes the load barely
  // excites) the recursive value can fake convergence while the
  // true residual plateaus. Each time the recursive residual
  // drops well under the tolerance, the true residual is checked;
  // if it misses, CG restarts from the true residual. A plateaued
  // true residual gives up early instead of burning the cap.
  const int kMaxIter = 10000;
  const double kTol = 1e-8;
  std::vector<double> x((size_t)ndof, 0.0), r(b), z((size_t)ndof),
      p((size_t)ndof), Ap((size_t)ndof);
  auto dot = [](const std::vector<double>& a, const std::vector<double>& c) {
    double s = 0.0;
    for (size_t i = 0; i < a.size(); ++i) s += a[i] * c[i];
    return s;
  };
  int iterations = 0;
  double relRes = 1.0;  // true relative residual, set at each check
  double prevRelRes = 1e300;
  int stalls = 0;
  bool converged = false;
  bool breakdown = false;
  while (!converged && !breakdown && iterations < kMaxIter) {
    for (int i = 0; i < ndof; ++i)
      z[(size_t)i] = r[(size_t)i] / diag[(size_t)i];
    p = z;
    double rz = dot(r, z);
    while (iterations < kMaxIter) {
      matvec(p, Ap);
      const double pAp = dot(p, Ap);
      if (!(pAp > 0.0) || !std::isfinite(pAp)) {
        breakdown = true;
        break;
      }
      const double alpha = rz / pAp;
      for (int i = 0; i < ndof; ++i) {
        x[(size_t)i] += alpha * p[(size_t)i];
        r[(size_t)i] -= alpha * Ap[(size_t)i];
      }
      ++iterations;
      if (std::sqrt(dot(r, r)) / bNorm < 0.1 * kTol) break;
      for (int i = 0; i < ndof; ++i)
        z[(size_t)i] = r[(size_t)i] / diag[(size_t)i];
      const double rzNew = dot(r, z);
      const double beta = rzNew / rz;
      for (int i = 0; i < ndof; ++i)
        p[(size_t)i] = z[(size_t)i] + beta * p[(size_t)i];
      rz = rzNew;
    }
    if (breakdown) break;
    // True residual check: r := b - A x.
    matvec(x, Ap);
    double rr = 0.0;
    for (int i = 0; i < ndof; ++i) {
      r[(size_t)i] = b[(size_t)i] - Ap[(size_t)i];
      rr += r[(size_t)i] * r[(size_t)i];
    }
    relRes = std::sqrt(rr) / bNorm;
    if (relRes < kTol) {
      converged = true;
      break;
    }
    if (relRes > 0.9 * prevRelRes) {
      if (++stalls >= 3) break;  // plateaued: inconsistent system
    } else {
      stalls = 0;
    }
    prevRelRes = relRes;
  }
  if (breakdown) {
    fail(err, MC_ERR_FEM_SINGULAR,
         "mc_fem_solve: solver breakdown (p^T A p <= 0) — the "
         "stiffness is singular; fix more of the part");
    return nullptr;
  }
  if (!converged) {
    char msg[192];
    std::snprintf(msg, sizeof(msg),
                  "mc_fem_solve: PCG did not converge in %d iterations "
                  "(true relative residual %.3g, target 1e-8) — the "
                  "system may be under-fixed",
                  iterations, relRes);
    fail(err, MC_ERR_FEM_NO_CONVERGE, msg);
    return nullptr;
  }
  const double finalRelRes = relRes;

  // ---- Stress recovery ----
  auto* res = new FemResultImpl();
  res->nodeCount = nNode;
  res->disp.assign((size_t)3 * nNode, 0.0);
  for (int n = 0; n < nNode; ++n) {
    const int fn = freeIndex[(size_t)n];
    if (fn < 0) continue;
    res->disp[3 * (size_t)n] = x[3 * (size_t)fn];
    res->disp[3 * (size_t)n + 1] = x[3 * (size_t)fn + 1];
    res->disp[3 * (size_t)n + 2] = x[3 * (size_t)fn + 2];
  }
  res->maxDisp = 0.0;
  for (int n = 0; n < nNode; ++n) {
    const double dx = res->disp[3 * (size_t)n],
                 dy = res->disp[3 * (size_t)n + 1],
                 dz = res->disp[3 * (size_t)n + 2];
    res->maxDisp = std::max(res->maxDisp, std::sqrt(dx * dx + dy * dy + dz * dz));
  }
  double D[6][6];
  femDMatrix(E, nu, D);
  double Bc[6][24];
  femBMatrix(h, 0.0, 0.0, 0.0, Bc);  // centroid
  double DBc[6][24];
  for (int r2 = 0; r2 < 6; ++r2)
    for (int j = 0; j < 24; ++j) {
      double ssum = 0.0;
      for (int k = 0; k < 6; ++k) ssum += D[r2][k] * Bc[k][j];
      DBc[r2][j] = ssum;
    }
  res->elemVM.assign((size_t)nElem, 0.0);
  std::vector<double> nodeSum((size_t)nNode, 0.0);
  std::vector<int> nodeCnt((size_t)nNode, 0);
  res->maxVM = 0.0;
  for (int e = 0; e < nElem; ++e) {
    double ue[24];
    for (int a = 0; a < 8; ++a) {
      const int n = im.elems[8 * (size_t)e + a];
      ue[3 * a] = res->disp[3 * (size_t)n];
      ue[3 * a + 1] = res->disp[3 * (size_t)n + 1];
      ue[3 * a + 2] = res->disp[3 * (size_t)n + 2];
    }
    double sig[6] = {0, 0, 0, 0, 0, 0};
    for (int r2 = 0; r2 < 6; ++r2) {
      double ssum = 0.0;
      for (int j = 0; j < 24; ++j) ssum += DBc[r2][j] * ue[j];
      sig[r2] = ssum;
    }
    const double vm = femVonMises(sig);
    res->elemVM[(size_t)e] = vm;
    res->maxVM = std::max(res->maxVM, vm);
    for (int a = 0; a < 8; ++a) {
      const int n = im.elems[8 * (size_t)e + a];
      nodeSum[(size_t)n] += vm;
      nodeCnt[(size_t)n] += 1;
    }
  }
  res->nodeVM.assign((size_t)nNode, 0.0);
  for (int n = 0; n < nNode; ++n)
    if (nodeCnt[(size_t)n] > 0)
      res->nodeVM[(size_t)n] = nodeSum[(size_t)n] / nodeCnt[(size_t)n];
  res->iterations = iterations;
  res->relResidual = finalRelRes;

  if (err) *err = MC_OK;
  auto* handle = new MCFacadeFemResult();
  handle->_impl = res;
  return handle;
}

void mc_free_fem_result(MCFacadeFemResult* r) {
  if (!r) return;
  delete static_cast<FemResultImpl*>(r->_impl);
  delete r;
}

int mc_fem_result_stats(MCFacadeFemResult* r, double* maxVonMises,
                        double* maxDisplacement, int* iterations,
                        double* relResidual, int* err) {
  if (!r)
    return fail(err, MC_ERR_INVALID_ARG, "mc_fem_result_stats: null result");
  const FemResultImpl& im = femResOf(r);
  if (maxVonMises) *maxVonMises = im.maxVM;
  if (maxDisplacement) *maxDisplacement = im.maxDisp;
  if (iterations) *iterations = im.iterations;
  if (relResidual) *relResidual = im.relResidual;
  if (err) *err = MC_OK;
  return MC_OK;
}

int mc_fem_result_node_values(MCFacadeFemResult* r, double* dispOut,
                              double* vonMisesOut, int* err) {
  if (!r)
    return fail(err, MC_ERR_INVALID_ARG,
                "mc_fem_result_node_values: null result");
  const FemResultImpl& im = femResOf(r);
  if (dispOut)
    std::memcpy(dispOut, im.disp.data(), sizeof(double) * im.disp.size());
  if (vonMisesOut)
    std::memcpy(vonMisesOut, im.nodeVM.data(),
                sizeof(double) * im.nodeVM.size());
  if (err) *err = MC_OK;
  return MC_OK;
}

int mc_fem_result_element_von_mises(MCFacadeFemResult* r, double* out,
                                    int* err) {
  if (!r || !out)
    return fail(err, MC_ERR_INVALID_ARG,
                "mc_fem_result_element_von_mises: null argument");
  const FemResultImpl& im = femResOf(r);
  std::memcpy(out, im.elemVM.data(), sizeof(double) * im.elemVM.size());
  if (err) *err = MC_OK;
  return MC_OK;
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

void mc_free_shape(MCFacadeShape* s) {
  if (!s) return;
  delete static_cast<ShapeImpl*>(s->_impl);
  delete s;
}

}  // extern "C"
