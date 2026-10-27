import SwiftUI
import CoreText

// MARK: - Snap engine

enum SnapKind {
    case endpoint, center, midpoint, grid
    var label: String {
        switch self {
        case .endpoint: return "END"
        case .center: return "CEN"
        case .midpoint: return "MID"
        case .grid: return "GRID"
        }
    }
    /// Lower wins when several candidates are in range.
    var priority: Int {
        switch self {
        case .endpoint: return 0
        case .center: return 1
        case .midpoint: return 2
        case .grid: return 3
        }
    }
}

struct SnapResult {
    var point: Vec2
    var kind: SnapKind?
}

/// What part of an entity a drag is moving.
enum DragRole {
    case point, lineA, lineB, center
}

struct DragTarget {
    var entityID: Int
    var role: DragRole
    var original: Vec2
}

/// An addressable point of a sketch entity (a line end, a center, a
/// standalone point) — the currency of the Measure tool and of driving
/// dimensions.
struct SketchPointRef: Equatable {
    var entityID: Int
    var kind: PointKind

    func resolve(in sketch: Sketch) -> Vec2? {
        sketch.entity(entityID)?.resolve(kind)
    }

    var shortLabel: String {
        switch kind {
        case .start: return "#\(entityID) start"
        case .end: return "#\(entityID) end"
        case .center: return "#\(entityID) center"
        case .whole: return "point #\(entityID)"
        }
    }
}

/// 2D sketch editor v3: everything from v2 (real snapping, drag-to-move,
/// numeric inspector, face-outline guide) plus Fusion-style parametrics:
///  - a Measure tool: tap two points, read the distance, TYPE a new one
///    and Apply — an existing Distance dimension is updated, otherwise
///    the second point moves and the sketch re-solves;
///  - driving dimensions: the line Length and circle Radius fields
///    update-or-create a solver constraint, so 14.3 really becomes 14
///    everywhere the sketch is used;
///  - a constraints list whose values are editable in place;
///  - "Finish & Extrude": a closed profile goes straight to the
///    Extrude panel, like Fusion's finish-sketch flow.
struct SketchEditorView: View {
    @ObservedObject var model: EditorModel
    @AppStorage(MCAccent.key) private var accentHex: String = MCAccent.defaultHex
    private var accent: Color { MCAccent.color(hex: accentHex) }
    let sketchID: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    enum Tool: String, CaseIterable {
        case select = "Select"
        case line = "Line"
        case rectangle = "Rectangle"
        case circle = "Circle"
        case point = "Point"
        case spline = "Spline"
        case ellipse = "Ellipse"
        case polygon = "Polygon"
        case slot = "Slot"
        case text = "Text"
        case trim = "Trim"
        case measure = "Measure"
    }

    @State private var working: Sketch
    @State private var tool: Tool = .select
    @State private var snapEnabled = true
    @State private var selectedID: Int?
    @State private var pending: Vec2?
    @State private var liveSnap: SnapResult?
    @State private var dragging: DragTarget?
    @State private var dragChecked = false
    @State private var frozenTransform: ViewTransform?
    @State private var dof = 0
    @State private var solveNote: String?
    @State private var solveError: CADError?
    @State private var health: [CADError] = []

    // Numeric inspector fields (loaded when the selection changes).
    // (One variable per @State — SwiftUI wrappers reject multi-declarations.)
    @State private var fAX = ""
    @State private var fAY = ""
    @State private var fBX = ""
    @State private var fBY = ""
    @State private var fLength = ""
    @State private var fCX = ""
    @State private var fCY = ""
    @State private var fRadius = ""

    // Measure tool state.
    @State private var measureA: SketchPointRef?
    @State private var measureB: SketchPointRef?
    @State private var measureText = ""
    /// Circle-diameter measurement (tap a circle with the Measure
    /// tool): center + radius snapshots, cleared with the rest of
    /// the measurement. Separate from the A/B point pair — a tap on
    /// a circle REPLACES the current measurement, and vice versa.
    @State private var measureDiaCenter: Vec2?
    @State private var measureDiaRadius: Double?

    // v4 draw-tool state (one variable per @State — see the note above).
    @State private var splinePoints: [Vec2] = []
    @State private var slotTaps: [Vec2] = []
    @State private var polygonSides = 6
    // Text tool fields.
    @State private var textString = "TEXT"
    @State private var textSize = "20"
    @State private var textX = "0"
    @State private var textY = "0"
    @State private var textFont = "Helvetica-Bold"
    // Selection-edit fields (move / rotate / scale / mirror / pattern).
    @State private var opScope = "selected"
    @State private var moveDX = "10"
    @State private var moveDY = "0"
    @State private var rotateDeg = "90"
    @State private var rotateCX = ""
    @State private var rotateCY = ""
    @State private var scaleFactor = "2"
    @State private var scaleCX = ""
    @State private var scaleCY = ""
    @State private var patternMode = "rect"
    @State private var patRows = "2"
    @State private var patCols = "3"
    @State private var patSX = "20"
    @State private var patSY = "20"
    @State private var patCount = "6"
    @State private var patTotal = "360"
    @State private var patCX = ""
    @State private var patCY = ""
    @State private var offsetDist = "5"

    private static let textFonts = ["Helvetica-Bold", "Helvetica", "Courier-Bold",
                                    "TimesNewRomanPS-Bold", "Menlo-Bold"]

    init(model: EditorModel, sketchID: String) {
        _model = ObservedObject(wrappedValue: model)
        self.sketchID = sketchID
        _working = State(initialValue: model.sketch(withID: sketchID) ?? Sketch(name: "Sketch"))
    }

    private var guideOutline: [Vec2] { model.faceOutlines[sketchID] ?? [] }

    /// Text and projected geometry can push a sketch past a few
    /// hundred entities; past 250 the solver is skipped so editing
    /// stays responsive (dimensions then apply as direct edits).
    private var isHeavy: Bool { working.entities.count > 250 }

    // MARK: Coordinate transform (sketch mm <-> view points)

    struct ViewTransform {
        var scale: Double
        var cx: Double
        var cy: Double
        func toView(_ p: Vec2, in size: CGSize) -> CGPoint {
            CGPoint(x: (p.x - cx) * scale + Double(size.width) / 2,
                    y: Double(size.height) / 2 - (p.y - cy) * scale)
        }
        func toSketch(_ pt: CGPoint, in size: CGSize) -> Vec2 {
            Vec2((Double(pt.x) - Double(size.width) / 2) / scale + cx,
                 cy - (Double(pt.y) - Double(size.height) / 2) / scale)
        }
    }

    private func transform(for size: CGSize) -> ViewTransform {
        if let frozen = frozenTransform { return frozen }
        var pts: [Vec2] = guideOutline
        for e in working.entities { pts += e.polyline() }
        if let p = pending { pts.append(p) }
        pts += splinePoints
        pts += slotTaps
        guard let first = pts.first else {
            return ViewTransform(scale: 6, cx: 0, cy: 0)
        }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in pts {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        let pad = 10.0
        minX -= pad; maxX += pad; minY -= pad; maxY += pad
        let w = max(maxX - minX, 24), h = max(maxY - minY, 24)
        let s = min(Double(size.width) / w, Double(size.height) / h)
        return ViewTransform(scale: s, cx: (minX + maxX) / 2, cy: (minY + maxY) / 2)
    }

    // MARK: Snapping

    private func snap(_ raw: Vec2, scale: Double,
                      drag: DragTarget? = nil) -> SnapResult {
        guard snapEnabled else { return SnapResult(point: raw, kind: nil) }
        let threshold = 14 / max(scale, 0.001)
        var candidates: [(point: Vec2, kind: SnapKind)] = []
        for e in working.entities {
            switch e {
            case .point(_, let at, _):
                candidates.append((at, .endpoint))
            case .line(_, let a, let b, _):
                candidates.append((a, .endpoint))
                candidates.append((b, .endpoint))
                candidates.append(((a + b) * 0.5, .midpoint))
            case .circle(_, let c, _, _):
                candidates.append((c, .center))
            case .arc(let id, let c, _, _, _, _):
                candidates.append((c, .center))
                if let ent = working.entity(id) {
                    if let s = ent.resolve(.start) { candidates.append((s, .endpoint)) }
                    if let en = ent.resolve(.end) { candidates.append((en, .endpoint)) }
                }
            }
        }
        // Never snap a dragged point onto its own start position.
        if let drag {
            candidates.removeAll {
                $0.point.distance(to: drag.original) < 1e-9
            }
        }
        candidates.append((Vec2(raw.x.rounded(), raw.y.rounded()), .grid))
        var best: (point: Vec2, kind: SnapKind, dist: Double)?
        for c in candidates {
            let d = c.point.distance(to: raw)
            guard d <= threshold else { continue }
            if let b = best {
                if c.kind.priority < b.kind.priority ||
                    (c.kind.priority == b.kind.priority && d < b.dist) {
                    best = (c.point, c.kind, d)
                }
            } else {
                best = (c.point, c.kind, d)
            }
        }
        if let b = best { return SnapResult(point: b.point, kind: b.kind) }
        return SnapResult(point: raw, kind: nil)
    }

    private func draggablePoints() -> [(id: Int, role: DragRole, point: Vec2)] {
        var out: [(Int, DragRole, Vec2)] = []
        for e in working.entities {
            switch e {
            case .point(let id, let at, _):
                out.append((id, .point, at))
            case .line(let id, let a, let b, _):
                out.append((id, .lineA, a))
                out.append((id, .lineB, b))
            case .circle(let id, let c, _, _):
                out.append((id, .center, c))
            case .arc(let id, let c, _, _, _, _):
                out.append((id, .center, c))
            }
        }
        return out
    }

    private func moveDraggedPoint(_ target: DragTarget, to newPos: Vec2) {
        guard let idx = working.entities.firstIndex(where: { $0.id == target.entityID }) else { return }
        let e = working.entities[idx]
        switch (e, target.role) {
        case (.point(let id, _, let cons), .point):
            working.entities[idx] = .point(id: id, at: newPos, construction: cons)
        case (.line(let id, let a, let b, let cons), .lineA):
            working.entities[idx] = .line(id: id, a: newPos, b: b, construction: cons)
        case (.line(let id, let a, let b, let cons), .lineB):
            working.entities[idx] = .line(id: id, a: a, b: newPos, construction: cons)
        case (.line(let id, let a, let b, let cons), .point):
            // Whole-line drag fallback (unused roles map to nearest end).
            let da = a.distance(to: target.original), db = b.distance(to: target.original)
            if da <= db {
                working.entities[idx] = .line(id: id, a: newPos, b: b, construction: cons)
            } else {
                working.entities[idx] = .line(id: id, a: a, b: newPos, construction: cons)
            }
        case (.circle(let id, _, let r, let cons), .center):
            working.entities[idx] = .circle(id: id, center: newPos, radius: r, construction: cons)
        case (.arc(let id, _, let r, let a0, let a1, let cons), .center):
            working.entities[idx] = .arc(id: id, center: newPos, radius: r,
                                         startAngle: a0, endAngle: a1, construction: cons)
        default:
            break
        }
    }

    // MARK: Addressable points & direct point moves (Measure / dimensions)

    private func addressablePoints() -> [(ref: SketchPointRef, point: Vec2)] {
        var out: [(SketchPointRef, Vec2)] = []
        for e in working.entities {
            switch e {
            case .point(let id, let at, _):
                out.append((SketchPointRef(entityID: id, kind: .whole), at))
            case .line(let id, let a, let b, _):
                out.append((SketchPointRef(entityID: id, kind: .start), a))
                out.append((SketchPointRef(entityID: id, kind: .end), b))
            case .circle(let id, let c, _, _):
                out.append((SketchPointRef(entityID: id, kind: .center), c))
            case .arc(let id, _, _, _, _, _):
                if let s = e.resolve(.start) { out.append((SketchPointRef(entityID: id, kind: .start), s)) }
                if let en = e.resolve(.end) { out.append((SketchPointRef(entityID: id, kind: .end), en)) }
                if let c = e.resolve(.center) { out.append((SketchPointRef(entityID: id, kind: .center), c)) }
            }
        }
        return out
    }

    /// Move one addressable point directly. Arc endpoints are defined by
    /// angle, so they cannot be dragged this way (returns false).
    @discardableResult
    private func movePoint(_ ref: SketchPointRef, to newPos: Vec2) -> Bool {
        guard let idx = working.entities.firstIndex(where: { $0.id == ref.entityID }) else { return false }
        let e = working.entities[idx]
        switch (e, ref.kind) {
        case (.point(let id, _, let cons), .whole):
            working.entities[idx] = .point(id: id, at: newPos, construction: cons)
        case (.line(let id, _, let b, let cons), .start):
            working.entities[idx] = .line(id: id, a: newPos, b: b, construction: cons)
        case (.line(let id, let a, _, let cons), .end):
            working.entities[idx] = .line(id: id, a: a, b: newPos, construction: cons)
        case (.circle(let id, _, let r, let cons), .center):
            working.entities[idx] = .circle(id: id, center: newPos, radius: r, construction: cons)
        case (.arc(let id, _, let r, let a0, let a1, let cons), .center):
            working.entities[idx] = .arc(id: id, center: newPos, radius: r,
                                          startAngle: a0, endAngle: a1, construction: cons)
        default:
            return false
        }
        return true
    }

    // MARK: Body

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                headerRow
                finishRow
                canvas
                if let e = solveError {
                    messageRow(text: e.userMessage, code: e.code, color: .red)
                }
                if let n = solveNote {
                    Text(n)
                        .mcFont(18)
                        .foregroundStyle(.green)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let h = health.first {
                    messageRow(text: h.userMessage, code: h.code, color: .orange)
                }
                toolBar
                toolOptionsRow
                if isHeavy {
                    Text("Heavy sketch — \(working.entities.count) items. Solver passes are skipped so editing stays responsive; dimensions still apply directly.")
                        .mcFont(17, weight: .semibold)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if tool == .measure {
                    measureCard
                }
                if tool != .measure && hasMeasurement {
                    measureReadoutRow
                }
                if tool == .text {
                    textCard
                }
                if let id = selectedID, working.entity(id) != nil {
                    inspector(for: id)
                }
                selectionOpsCard
                if !working.constraints.isEmpty {
                    constraintsSection
                }
                entityList
            }
            .padding(10)
        }
        .navigationTitle(working.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { refresh() }
        .onChange(of: selectedID) { _, _ in loadInspector() }
    }

    private var headerRow: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(working.name)
                    .mcFont(24, weight: .bold)
                Text("\(working.entities.count) items · \(working.constraints.count) constraints")
                    .mcFont(17)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            dofBadge
        }
    }

    /// Fusion's finish-sketch flow: a closed profile can go straight
    /// into an Extrude panel; anything else stays here with the coded
    /// reason (MCAD-SK204 for an open profile, and so on).
    private var finishRow: some View {
        HStack(spacing: 12) {
            Button {
                finishAndExtrude()
            } label: {
                Label("Finish & Extrude", systemImage: "rectangle.expand.vertical")
                    .mcFont(20, weight: .bold)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(accent))
            }
            Button("Done") { dismiss() }
                .mcFont(20, weight: .semibold)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Capsule().fill(Color.white.opacity(0.12)))
            Spacer()
            Text("Finish & Extrude needs a closed profile.")
                .mcFont(16)
                .foregroundStyle(.secondary)
        }
    }

    private func finishAndExtrude() {
        do {
            let (profiles, _) = try working.extractProfiles()
            guard !profiles.isEmpty else { throw CADError.padNoProfile }
            model.pendingExtrudeSketchID = sketchID
            dismiss()
        } catch let e as CADError {
            solveError = e
            solveNote = nil
            MCLog.shared.log(error: e, category: .sketch)
        } catch {
            solveError = .unknown("\(error)")
            solveNote = nil
        }
    }

    @ViewBuilder
    private var dofBadge: some View {
        if working.entities.isEmpty {
            badge("Empty sketch", .gray)
        } else if dof == 0 {
            badge("Fully constrained", .green)
        } else {
            badge("\(dof) free", .orange)
        }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .mcFont(19, weight: .bold)
            .foregroundStyle(.black)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Capsule().fill(color))
    }

    private func messageRow(text: String, code: String, color: Color) -> some View {
        HStack(spacing: 10) {
            Text(text)
                .mcFont(18, weight: .semibold)
                .foregroundStyle(color)
            Text(code)
                .mcFont(14, design: .monospaced)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: Canvas

    private var canvas: some View {
        GeometryReader { geo in
            let t = transform(for: geo.size)
            ZStack(alignment: .topLeading) {
                Color(white: 0.05)
                Canvas { ctx, size in
                    draw(ctx, size: size, t: t)
                }
                if let live = liveSnap {
                    HStack(spacing: 8) {
                        if let kind = live.kind {
                            Text(kind.label)
                                .mcFont(16, weight: .bold)
                                .foregroundStyle(.black)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Capsule().fill(Color.yellow))
                        }
                        Text("X \(mcFmt(live.point.x)) · Y \(mcFmt(live.point.y)) mm")
                            .mcFont(17, weight: .semibold)
                            .foregroundStyle(.yellow)
                    }
                    .padding(8)
                }
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            gestureChanged(value, t: t, size: geo.size)
                        }
                        .onEnded { value in
                            gestureEnded(value, t: t, size: geo.size)
                        })
            }
        }
        // CascadeDemo adaptation: taller canvas (430 in MetalCAD) so the
        // sketch working area dominates the editor screen; controls keep
        // their normal size. The canvas lives in a ScrollView page, so a
        // fixed height is required (an infinite height collapses there).
        .frame(height: 600)
        .border(Color.white.opacity(0.25), width: 1)
    }

    private func gestureChanged(_ value: DragGesture.Value, t: ViewTransform, size: CGSize) {
        if frozenTransform == nil { frozenTransform = t }
        let ft = frozenTransform ?? t
        if !dragChecked {
            dragChecked = true
            // Drag-to-move wins over placement when a point is grabbed,
            // in Select mode or while no placement is pending. Measure
            // mode taps pick points instead of dragging them, and the
            // v4 tap-tools (spline / slot / trim / text) place points —
            // they never start a drag.
            let dragOK: Bool = {
                switch tool {
                case .select, .line, .rectangle, .circle, .point: return true
                default: return false
                }
            }()
            if pending == nil && splinePoints.isEmpty && slotTaps.isEmpty && dragOK {
                let startRaw = ft.toSketch(value.startLocation, in: size)
                let threshold = 16 / max(ft.scale, 0.001)
                var bestTarget: DragTarget?
                var bestDist = Double.greatestFiniteMagnitude
                for cand in draggablePoints() {
                    let d = cand.point.distance(to: startRaw)
                    if d < bestDist { bestDist = d; bestTarget = DragTarget(entityID: cand.id, role: cand.role, original: cand.point) }
                }
                if let target = bestTarget, bestDist <= threshold {
                    dragging = target
                    selectedID = target.entityID
                }
            }
        }
        let raw = ft.toSketch(value.location, in: size)
        let snapped = snap(raw, scale: ft.scale, drag: dragging)
        liveSnap = snapped
        if let target = dragging {
            moveDraggedPoint(target, to: snapped.point)
        }
    }

    private func gestureEnded(_ value: DragGesture.Value, t: ViewTransform, size: CGSize) {
        let ft = frozenTransform ?? t
        let raw = ft.toSketch(value.location, in: size)
        let snapped = snap(raw, scale: ft.scale, drag: dragging)
        defer {
            dragging = nil
            dragChecked = false
            frozenTransform = nil
            liveSnap = nil
        }
        if dragging != nil {
            changed()
            return
        }
        let p = snapped.point
        switch tool {
        case .select:
            selectNearest(to: raw, scale: ft.scale)
        case .measure:
            pickMeasurePoint(at: p, scale: ft.scale)
        case .line:
            if let start = pending {
                if start.distance(to: p) > 1e-9 {
                    working.addLine(start, p)
                    changed()
                }
                pending = nil
            } else {
                pending = p
            }
        case .rectangle:
            if let corner = pending {
                if abs(corner.x - p.x) > 1e-9 && abs(corner.y - p.y) > 1e-9 {
                    working.addRectangle(from: corner, to: p)
                    changed()
                }
                pending = nil
            } else {
                pending = p
            }
        case .circle:
            if let center = pending {
                let r = center.distance(to: p)
                if r > 0.1 {
                    working.addCircle(center, r)
                    changed()
                }
                pending = nil
            } else {
                pending = p
            }
        case .point:
            working.addPoint(p)
            changed()
        case .spline:
            splinePoints.append(p)
        case .ellipse:
            if let center = pending {
                let rx = abs(p.x - center.x), ry = abs(p.y - center.y)
                if rx > 0.5 && ry > 0.5 {
                    addEllipseLoop(center: center, rx: rx, ry: ry)
                    changed()
                }
                pending = nil
            } else {
                pending = p
            }
        case .polygon:
            if let center = pending {
                if center.distance(to: p) > 0.5 {
                    addPolygonLoop(center: center, vertex: p, sides: polygonSides)
                    changed()
                }
                pending = nil
            } else {
                pending = p
            }
        case .slot:
            slotTaps.append(p)
            if slotTaps.count == 3 {
                let r = slotTaps[2].distance(to: slotTaps[1])
                if r > 0.1 && slotTaps[0].distance(to: slotTaps[1]) > 0.5 {
                    addSlotEntities(a: slotTaps[0], b: slotTaps[1], r: r)
                    changed()
                }
                slotTaps = []
            }
        case .text:
            pending = p
            textX = mcFmt(p.x)
            textY = mcFmt(p.y)
        case .trim:
            trimTappedLine(at: raw, scale: ft.scale)
        }
    }

    private func draw(_ ctx: GraphicsContext, size: CGSize, t: ViewTransform) {
        let tl = t.toSketch(CGPoint(x: 0, y: 0), in: size)
        let br = t.toSketch(CGPoint(x: size.width, y: size.height), in: size)

        // 1 mm minor grid + 10 mm major grid (snapping is to 1 mm).
        var minor = Path()
        var gx = tl.x.rounded(.down)
        while gx <= br.x {
            minor.move(to: t.toView(Vec2(gx, tl.y), in: size))
            minor.addLine(to: t.toView(Vec2(gx, br.y), in: size))
            gx += 1
        }
        var gy = br.y.rounded(.down)
        while gy <= tl.y {
            minor.move(to: t.toView(Vec2(tl.x, gy), in: size))
            minor.addLine(to: t.toView(Vec2(br.x, gy), in: size))
            gy += 1
        }
        ctx.stroke(minor, with: .color(.white.opacity(0.03)), lineWidth: 1)
        var major = Path()
        gx = (tl.x / 10).rounded(.down) * 10
        while gx <= br.x {
            major.move(to: t.toView(Vec2(gx, tl.y), in: size))
            major.addLine(to: t.toView(Vec2(gx, br.y), in: size))
            gx += 10
        }
        gy = (br.y / 10).rounded(.down) * 10
        while gy <= tl.y {
            major.move(to: t.toView(Vec2(tl.x, gy), in: size))
            major.addLine(to: t.toView(Vec2(br.x, gy), in: size))
            gy += 10
        }
        ctx.stroke(major, with: .color(.white.opacity(0.09)), lineWidth: 1)

        // Face outline guide (the face this sketch lives on).
        if guideOutline.count > 1 {
            var guide = Path()
            guide.move(to: t.toView(guideOutline[0], in: size))
            for p in guideOutline.dropFirst() { guide.addLine(to: t.toView(p, in: size)) }
            guide.closeSubpath()
            ctx.fill(guide, with: .color(.white.opacity(0.05)))
            ctx.stroke(guide, with: .color(.white.opacity(0.4)),
                       style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
        }

        // Axes.
        var axes = Path()
        axes.move(to: t.toView(Vec2(tl.x, 0), in: size))
        axes.addLine(to: t.toView(Vec2(br.x, 0), in: size))
        axes.move(to: t.toView(Vec2(0, br.y), in: size))
        axes.addLine(to: t.toView(Vec2(0, tl.y), in: size))
        ctx.stroke(axes, with: .color(.white.opacity(0.3)), lineWidth: 1)

        // Entities.
        for e in working.entities {
            let selected = e.id == selectedID
            let color: Color = selected ? accent : (e.isConstruction ? .gray : .cyan)
            if case .point(_, let at, _) = e {
                let c = t.toView(at, in: size)
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)),
                         with: .color(color))
                continue
            }
            let pts = e.polyline()
            guard pts.count > 1 else { continue }
            var path = Path()
            path.move(to: t.toView(pts[0], in: size))
            for p in pts.dropFirst() { path.addLine(to: t.toView(p, in: size)) }
            if case .circle = e { path.closeSubpath() }
            ctx.stroke(path, with: .color(color),
                       style: StrokeStyle(lineWidth: selected ? 4 : 2.5,
                                          dash: e.isConstruction ? [6, 4] : []))
        }

        // Draggable point handles.
        for cand in draggablePoints() {
            let c = t.toView(cand.point, in: size)
            let isDragged = dragging?.entityID == cand.id && dragging?.role == cand.role
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)),
                     with: .color(isDragged ? .yellow : .white))
        }

        // Placement preview from the pending point to the live pointer.
        if let start = pending, let live = liveSnap {
            var preview = Path()
            switch tool {
            case .line:
                preview.move(to: t.toView(start, in: size))
                preview.addLine(to: t.toView(live.point, in: size))
            case .rectangle:
                let rect = CGRect(
                    x: min(t.toView(start, in: size).x, t.toView(live.point, in: size).x),
                    y: min(t.toView(start, in: size).y, t.toView(live.point, in: size).y),
                    width: abs(t.toView(live.point, in: size).x - t.toView(start, in: size).x),
                    height: abs(t.toView(live.point, in: size).y - t.toView(start, in: size).y))
                preview.addRect(rect)
            case .circle:
                let c = t.toView(start, in: size)
                let r = start.distance(to: live.point) * t.scale
                preview.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            case .ellipse:
                let c = t.toView(start, in: size)
                let rx = abs(live.point.x - start.x) * t.scale
                let ry = abs(live.point.y - start.y) * t.scale
                preview.addEllipse(in: CGRect(x: c.x - rx, y: c.y - ry, width: rx * 2, height: ry * 2))
            case .polygon:
                let verts = polygonVertices(center: start, vertex: live.point, sides: polygonSides)
                if verts.count > 1 {
                    preview.move(to: t.toView(verts[0], in: size))
                    for v in verts.dropFirst() { preview.addLine(to: t.toView(v, in: size)) }
                    preview.closeSubpath()
                }
            default:
                break
            }
            ctx.stroke(preview, with: .color(.yellow.opacity(0.8)),
                       style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            let c = t.toView(start, in: size)
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 6, y: c.y - 6, width: 12, height: 12)),
                     with: .color(.yellow))
        } else if let p = pending {
            let c = t.toView(p, in: size)
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 6, y: c.y - 6, width: 12, height: 12)),
                     with: .color(.yellow))
        }

        // Snap indicator: distinct shape per kind + label.
        if let live = liveSnap, let kind = live.kind {
            let c = t.toView(live.point, in: size)
            drawSnapIndicator(ctx, center: c, kind: kind)
            let label = Text(kind.label)
                .font(Font.system(size: MCTypeScale.scaled(14, for: dynamicTypeSize), weight: .bold))
                .foregroundColor(.yellow)
            ctx.draw(label, at: CGPoint(x: c.x + 16, y: c.y - 16))
        }

        // Measure picks: A (white) and B (accent), joined by a dashed
        // line so the measured span is visible.
        let pointA = measureA?.resolve(in: working)
        let pointB = measureB?.resolve(in: working)
        if let a = pointA, let b = pointB {
            var span = Path()
            span.move(to: t.toView(a, in: size))
            span.addLine(to: t.toView(b, in: size))
            ctx.stroke(span, with: .color(accent),
                       style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
        }
        if let a = pointA {
            drawMeasureMarker(ctx, at: t.toView(a, in: size), letter: "A", color: .white)
        }
        if let b = pointB {
            drawMeasureMarker(ctx, at: t.toView(b, in: size), letter: "B", color: accent)
        }
        // The measured distance, labelled on the span itself — the
        // readout that stays on the canvas whatever tool is active.
        if let a = pointA, let b = pointB {
            let mid = t.toView((a + b) * 0.5, in: size)
            let label = Text("\(mcFmt(a.distance(to: b))) mm")
                .font(Font.system(size: MCTypeScale.scaled(15, for: dynamicTypeSize), weight: .bold))
                .foregroundColor(accent)
            ctx.draw(label, at: CGPoint(x: mid.x, y: mid.y - 18))
        }

        // Circle diameter measurement: a dashed line straight
        // across the circle through its center, labelled "Ø …".
        if let c = measureDiaCenter, let r = measureDiaRadius {
            var dia = Path()
            dia.move(to: t.toView(c + Vec2(-r, 0), in: size))
            dia.addLine(to: t.toView(c + Vec2(r, 0), in: size))
            ctx.stroke(dia, with: .color(accent),
                       style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            let cv = t.toView(c, in: size)
            let label = Text("Ø \(mcFmt(r * 2)) mm")
                .font(Font.system(size: MCTypeScale.scaled(15, for: dynamicTypeSize), weight: .bold))
                .foregroundColor(accent)
            ctx.draw(label, at: CGPoint(x: cv.x, y: cv.y - r * t.scale - 16))
        }

        // Spline in progress: the sampled curve through the tapped
        // points (plus the live pointer as a tentative last point).
        if !splinePoints.isEmpty {
            var previewPts = splinePoints
            if let live = liveSnap { previewPts.append(live.point) }
            let samples = catmullRomSamples(previewPts)
            if samples.count > 1 {
                var path = Path()
                path.move(to: t.toView(samples[0], in: size))
                for p in samples.dropFirst() { path.addLine(to: t.toView(p, in: size)) }
                ctx.stroke(path, with: .color(.yellow.opacity(0.8)),
                           style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            }
            for p in splinePoints {
                let c = t.toView(p, in: size)
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)),
                         with: .color(.yellow))
            }
        }

        // Slot in progress: centers, then the full outline once the
        // second center is down (radius follows the pointer).
        if !slotTaps.isEmpty {
            for p in slotTaps {
                let c = t.toView(p, in: size)
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)),
                         with: .color(.yellow))
            }
            if slotTaps.count == 2, let live = liveSnap {
                let r = live.point.distance(to: slotTaps[1])
                if r > 0.05 {
                    let outline = slotOutlinePoints(a: slotTaps[0], b: slotTaps[1], r: r)
                    if outline.count > 1 {
                        var path = Path()
                        path.move(to: t.toView(outline[0], in: size))
                        for p in outline.dropFirst() { path.addLine(to: t.toView(p, in: size)) }
                        path.closeSubpath()
                        ctx.stroke(path, with: .color(.yellow.opacity(0.8)),
                                   style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    }
                }
            }
        }
    }

    private func drawMeasureMarker(_ ctx: GraphicsContext, at c: CGPoint,
                                   letter: String, color: Color) {
        ctx.stroke(Path(ellipseIn: CGRect(x: c.x - 11, y: c.y - 11, width: 22, height: 22)),
                   with: .color(color), lineWidth: 3)
        let label = Text(letter)
            .font(Font.system(size: MCTypeScale.scaled(15, for: dynamicTypeSize), weight: .bold))
            .foregroundColor(color)
        ctx.draw(label, at: CGPoint(x: c.x, y: c.y - 24))
    }

    private func drawSnapIndicator(_ ctx: GraphicsContext, center c: CGPoint, kind: SnapKind) {
        let s = 9.0
        switch kind {
        case .endpoint: // square
            ctx.stroke(Path(CGRect(x: c.x - s, y: c.y - s, width: s * 2, height: s * 2)),
                       with: .color(.yellow), lineWidth: 2.5)
        case .center: // X
            var p = Path()
            p.move(to: CGPoint(x: c.x - s, y: c.y - s)); p.addLine(to: CGPoint(x: c.x + s, y: c.y + s))
            p.move(to: CGPoint(x: c.x + s, y: c.y - s)); p.addLine(to: CGPoint(x: c.x - s, y: c.y + s))
            ctx.stroke(p, with: .color(.yellow), lineWidth: 2.5)
        case .midpoint: // triangle
            var p = Path()
            p.move(to: CGPoint(x: c.x, y: c.y - s))
            p.addLine(to: CGPoint(x: c.x + s, y: c.y + s))
            p.addLine(to: CGPoint(x: c.x - s, y: c.y + s))
            p.closeSubpath()
            ctx.stroke(p, with: .color(.yellow), lineWidth: 2.5)
        case .grid: // crosshair
            var p = Path()
            p.move(to: CGPoint(x: c.x - s - 3, y: c.y)); p.addLine(to: CGPoint(x: c.x + s + 3, y: c.y))
            p.move(to: CGPoint(x: c.x, y: c.y - s - 3)); p.addLine(to: CGPoint(x: c.x, y: c.y + s + 3))
            ctx.stroke(p, with: .color(.yellow), lineWidth: 2)
        }
    }

    private func selectNearest(to p: Vec2, scale: Double) {
        var bestID: Int? = nil
        var bestDist = Double.greatestFiniteMagnitude
        for e in working.entities {
            for pt in e.polyline() {
                let d = pt.distance(to: p)
                if d < bestDist { bestDist = d; bestID = e.id }
            }
        }
        let threshold = 14 / max(scale, 0.001)
        selectedID = (bestID != nil && bestDist <= threshold) ? bestID : nil
    }

    // MARK: Measure tool

    private static func distanceToSegment(_ p: Vec2, _ a: Vec2, _ b: Vec2) -> Double {
        let ab = b - a
        let len2 = ab.dot(ab)
        guard len2 > 1e-12 else { return p.distance(to: a) }
        let t = max(0, min(1, (p - a).dot(ab) / len2))
        return p.distance(to: a + ab * t)
    }

    /// One tap of the Measure tool (the caller passes the SNAPPED
    /// point, so endpoints/centers are easy to hit). Resolution, in
    /// order:
    ///  1. An addressable point (line end, center, standalone point)
    ///     starts or completes the two-tap point-to-point flow.
    ///  2. A tap ON a line, away from its ends, measures that line:
    ///     its end refs become A/B, so the length shows with the
    ///     usual markers, span and canvas label.
    ///  3. A tap on a circle's outline measures its diameter.
    /// Each new measurement replaces the previous one.
    private func pickMeasurePoint(at p: Vec2, scale: Double) {
        let threshold = 16 / max(scale, 0.001)
        var best: (ref: SketchPointRef, point: Vec2, dist: Double)?
        for cand in addressablePoints() {
            let d = cand.point.distance(to: p)
            guard d <= threshold else { continue }
            if let b = best {
                if d < b.dist { best = (cand.ref, cand.point, d) }
            } else {
                best = (cand.ref, cand.point, d)
            }
        }
        if let hit = best {
            measureDiaCenter = nil
            measureDiaRadius = nil
            if measureA == nil || measureB != nil {
                // Start (or restart) the pair.
                measureA = hit.ref
                measureB = nil
                measureText = ""
            } else {
                measureB = hit.ref
                refreshMeasureText()
            }
            return
        }
        // Entity taps: nearest line (by segment distance) or circle
        // (by outline distance) within the same threshold.
        var bestEntity: (id: Int, dist: Double)?
        for e in working.entities {
            let d: Double
            switch e {
            case .line(_, let a, let b, _):
                d = Self.distanceToSegment(p, a, b)
            case .circle(_, let c, let r, _):
                d = abs(p.distance(to: c) - r)
            default:
                continue
            }
            guard d <= threshold else { continue }
            if d < (bestEntity?.dist ?? Double.greatestFiniteMagnitude) {
                bestEntity = (e.id, d)
            }
        }
        guard let hitEntity = bestEntity,
              let e = working.entity(hitEntity.id) else { return }
        switch e {
        case .line(let id, _, _, _):
            measureDiaCenter = nil
            measureDiaRadius = nil
            measureA = SketchPointRef(entityID: id, kind: .start)
            measureB = SketchPointRef(entityID: id, kind: .end)
            refreshMeasureText()
        case .circle(_, let c, let r, _):
            measureA = nil
            measureB = nil
            measureText = ""
            measureDiaCenter = c
            measureDiaRadius = r
        default:
            break
        }
    }

    /// Clear every part of the current measurement (point pair and
    /// diameter alike) — the canvas span/label and the readouts all
    /// key off this state.
    private func clearMeasurement() {
        measureA = nil
        measureB = nil
        measureText = ""
        measureDiaCenter = nil
        measureDiaRadius = nil
    }

    /// True while any measurement is on display (a picked point, a
    /// finished pair, or a circle diameter).
    private var hasMeasurement: Bool {
        measureA != nil || measureDiaCenter != nil
    }

    private var measureReadoutText: String {
        if let r = measureDiaRadius {
            return "Ø \(mcFmt(r * 2)) mm"
        }
        if let a = measureA?.resolve(in: working),
           let b = measureB?.resolve(in: working) {
            return "Distance \(mcFmt(a.distance(to: b))) mm"
        }
        if measureA != nil { return "Tap the second point" }
        return ""
    }

    /// The measurement, kept on screen after the Measure tool is
    /// switched away (the full card only shows with the tool): a
    /// slim row under the toolbar with the value and its Clear.
    private var measureReadoutRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "ruler")
                .mcFont(20, weight: .bold)
                .foregroundStyle(accent)
            Text(measureReadoutText)
                .mcFont(19, weight: .semibold)
            Spacer()
            Button("Clear") { clearMeasurement() }
                .mcFont(19, weight: .semibold)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06)))
    }

    private func refreshMeasureText() {
        if let a = measureA?.resolve(in: working), let b = measureB?.resolve(in: working) {
            measureText = mcFmt(a.distance(to: b))
        }
    }

    /// The headline interaction: type the distance a line should be
    /// (14.3 → 14) and the sketch obeys. If a Distance dimension joins
    /// the two points, its value is updated; otherwise point B is moved
    /// along the A→B direction (a direct edit); then the sketch solves
    /// and the part rebuilds.
    private func applyMeasure() {
        guard let a = measureA, let b = measureB,
              let value = Double(measureText), value > 0 else { return }
        if distanceConstraintIndex(a, b) != nil {
            applyDrivingDistance(a, b, value: value)
            return
        }
        var moved = false
        if let pa = a.resolve(in: working), let pb = b.resolve(in: working) {
            let d = pa.distance(to: pb)
            if d > 1e-9 {
                moved = movePoint(b, to: pa + (pb - pa) * (value / d))
            } else {
                moved = movePoint(b, to: pa + Vec2(value, 0))
            }
        }
        if !moved {
            // B cannot be moved directly (an arc end) — drive it with a
            // dimension + solver instead of pretending.
            applyDrivingDistance(a, b, value: value)
            return
        }
        changed()
        solve()
        refreshMeasureText()
    }

    private var measureCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Measure — tap two points, a line for its length, or a circle for its diameter")
                .mcFont(20, weight: .bold)
            HStack(spacing: 18) {
                Text("A: \(measureA?.shortLabel ?? "—")")
                Text("B: \(measureB?.shortLabel ?? "—")")
            }
            .mcFont(19, weight: .semibold)
            if let r = measureDiaRadius {
                HStack(spacing: 10) {
                    Text("Circle diameter")
                        .mcFont(20, weight: .semibold)
                    Text("Ø \(mcFmt(r * 2)) mm")
                        .mcFont(22, weight: .bold)
                        .foregroundStyle(accent)
                    Button("Clear") { clearMeasurement() }
                        .mcFont(20, weight: .semibold)
                    Spacer()
                }
            }
            if measureA != nil && measureB != nil {
                HStack(spacing: 10) {
                    Text("Distance")
                        .mcFont(20, weight: .semibold)
                    TextField("Distance (mm)", text: $measureText)
                        .keyboardType(.numbersAndPunctuation)
                        .mcFont(22, weight: .bold)
                        .frame(width: 130)
                        .textFieldStyle(.roundedBorder)
                    Text("mm")
                        .mcFont(20, weight: .semibold)
                    Button("Apply") { applyMeasure() }
                        .mcFont(20, weight: .bold)
                        .foregroundStyle(.black)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(accent))
                    Button("Clear") { clearMeasurement() }
                    .mcFont(20, weight: .semibold)
                    Spacer()
                }
                Text("Type a new distance and Apply: an existing Distance dimension is updated, otherwise point B moves to the new distance and the sketch re-solves.")
                    .mcFont(16)
                    .foregroundStyle(.secondary)
            } else if measureDiaRadius == nil {
                Text(measureA == nil ? "Tap the first point." : "Tap the second point.")
                    .mcFont(18, weight: .semibold)
                    .foregroundStyle(.yellow)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06)))
    }

    // MARK: Text tool (CoreText outlines — emboss / engrave source)

    private var textCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Text — real letter outlines, added as line loops")
                .mcFont(20, weight: .bold)
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Text")
                        .mcFont(15, weight: .semibold)
                        .foregroundStyle(.secondary)
                    TextField("Text", text: $textString)
                        .mcFont(20, weight: .semibold)
                        .frame(minWidth: 160)
                        .textFieldStyle(.roundedBorder)
                }
                field("Height mm", $textSize)
            }
            HStack(spacing: 8) {
                field("Baseline X", $textX)
                field("Baseline Y", $textY)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Font")
                        .mcFont(15, weight: .semibold)
                        .foregroundStyle(.secondary)
                    Picker("Font", selection: $textFont) {
                        ForEach(Self.textFonts, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .pickerStyle(.menu)
                    .mcFont(19, weight: .semibold)
                }
            }
            HStack(spacing: 12) {
                Button("Add Text") { addTextEntities() }
                    .mcFont(20, weight: .bold)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(accent))
                Spacer()
            }
            Text("Tap the canvas to set the baseline start. Then Extrude the sketch — Join embosses the letters, Cut engraves them. Text adds many small lines, so the sketch may go “heavy” (solver skipped).")
                .mcFont(16)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06)))
    }

    // MARK: Selection editing (move / rotate / scale / mirror / pattern / offset / project)

    private var selectionOpsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text("Edit geometry")
                    .mcFont(20, weight: .bold)
                Spacer()
                Picker("Applies to", selection: $opScope) {
                    Text("Selected item").tag("selected")
                    Text("Whole sketch").tag("all")
                }
                .pickerStyle(.segmented)
                .frame(width: 300)
            }
            if opScope == "selected" && selectedID == nil {
                Text("Nothing is selected — the operations apply to the whole sketch. Tap an item above the canvas or in the list to target just it.")
                    .mcFont(16)
                    .foregroundStyle(.secondary)
            }
            // Move
            HStack(spacing: 8) {
                Text("Move")
                    .mcFont(20, weight: .semibold)
                    .frame(width: 90, alignment: .leading)
                field("ΔX mm", $moveDX)
                field("ΔY mm", $moveDY)
                Button("Apply") { applyMoveSelection() }
                    .mcFont(20, weight: .semibold)
                Spacer()
            }
            // Rotate
            HStack(spacing: 8) {
                Text("Rotate")
                    .mcFont(20, weight: .semibold)
                    .frame(width: 90, alignment: .leading)
                field("Degrees", $rotateDeg)
                field("Center X", $rotateCX)
                field("Center Y", $rotateCY)
                Button("Apply") { applyRotateSelection() }
                    .mcFont(20, weight: .semibold)
                Spacer()
            }
            Text("A blank rotate/scale center uses the middle of what's being edited.")
                .mcFont(15)
                .foregroundStyle(.secondary)
            // Scale
            HStack(spacing: 8) {
                Text("Scale")
                    .mcFont(20, weight: .semibold)
                    .frame(width: 90, alignment: .leading)
                field("Factor", $scaleFactor)
                field("Center X", $scaleCX)
                field("Center Y", $scaleCY)
                Button("Apply") { applyScaleSelection() }
                    .mcFont(20, weight: .semibold)
                Spacer()
            }
            // Mirror
            HStack(spacing: 10) {
                Text("Mirror")
                    .mcFont(20, weight: .semibold)
                    .frame(width: 90, alignment: .leading)
                Button("Vertical axis") { applyMirrorSelection(phi: Double.pi / 2) }
                    .mcFont(20, weight: .semibold)
                Button("Horizontal axis") { applyMirrorSelection(phi: 0) }
                    .mcFont(20, weight: .semibold)
                Button("Across selected line") { mirrorAcrossSelectedLine() }
                    .mcFont(20, weight: .semibold)
                    .disabled(selectedLineID == nil)
                Spacer()
            }
            Text("Vertical/horizontal mirror the edit set across the axis through its middle, in place. “Across selected line” mirrors the whole sketch across the selected line (the line itself stays).")
                .mcFont(15)
                .foregroundStyle(.secondary)
            Divider()
            // Pattern
            HStack(spacing: 12) {
                Text("Pattern selection")
                    .mcFont(20, weight: .bold)
                Spacer()
                Picker("Pattern kind", selection: $patternMode) {
                    Text("Rectangular").tag("rect")
                    Text("Circular").tag("circular")
                }
                .pickerStyle(.segmented)
                .frame(width: 280)
            }
            if patternMode == "rect" {
                HStack(spacing: 8) {
                    field("Rows", $patRows)
                    field("Columns", $patCols)
                    field("Spacing X", $patSX)
                    field("Spacing Y", $patSY)
                    Button("Apply") { applyPatternSelection() }
                        .mcFont(20, weight: .semibold)
                    Spacer()
                }
            } else {
                HStack(spacing: 8) {
                    field("Copies", $patCount)
                    field("Total °", $patTotal)
                    field("Center X", $patCX)
                    field("Center Y", $patCY)
                    Button("Apply") { applyPatternSelection() }
                        .mcFont(20, weight: .semibold)
                    Spacer()
                }
                Text("Copies counts the original. A blank center uses the middle of the edit set.")
                    .mcFont(15)
                    .foregroundStyle(.secondary)
            }
            Divider()
            // Offset + project
            HStack(spacing: 8) {
                Text("Offset profile")
                    .mcFont(20, weight: .semibold)
                field("Distance mm", $offsetDist)
                Button("Apply") { applyOffsetProfile() }
                    .mcFont(20, weight: .semibold)
                Spacer()
            }
            Text("Offsets the first closed profile of the sketch (+ grows it, − shrinks it) into a new line loop.")
                .mcFont(15)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Text("Project")
                    .mcFont(20, weight: .semibold)
                Button("Body edges") { projectBodyEdges() }
                    .mcFont(20, weight: .semibold)
                Button("Face outline") { projectFaceOutline() }
                    .mcFont(20, weight: .semibold)
                    .disabled(guideOutline.count < 2)
                Spacer()
            }
            Text("Project Geometry drops the body's sharp edges (or this sketch's host-face outline) into the sketch as gray construction lines to draw against.")
                .mcFont(15)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06)))
    }

    // MARK: Driving dimensions (constraint value edits + solver)

    private func distanceConstraintIndex(_ a: SketchPointRef, _ b: SketchPointRef) -> Int? {
        working.constraints.firstIndex { c in
            if case .distancePoints(let ea, let ka, let eb, let kb, _) = c {
                return (ea == a.entityID && ka == a.kind && eb == b.entityID && kb == b.kind)
                    || (ea == b.entityID && ka == b.kind && eb == a.entityID && kb == a.kind)
            }
            return false
        }
    }

    private func constraintValue(_ c: SketchConstraint) -> Double? {
        switch c {
        case .distancePoints(_, _, _, _, let v): return v
        case .radius(_, let v): return v
        case .diameter(_, let v): return v
        case .angleBetween(_, _, let v): return v
        default: return nil
        }
    }

    private func constraint(_ c: SketchConstraint, withValue v: Double) -> SketchConstraint {
        switch c {
        case .distancePoints(let a, let ka, let b, let kb, _):
            return .distancePoints(entityA: a, kindA: ka, entityB: b, kindB: kb, value: v)
        case .radius(let e, _):
            return .radius(entity: e, value: v)
        case .diameter(let e, _):
            return .diameter(entity: e, value: v)
        case .angleBetween(let a, let b, _):
            return .angleBetween(entityA: a, entityB: b, degrees: v)
        default:
            return c
        }
    }

    /// Solve a modified copy of the sketch and adopt it on success.
    /// Returns false (leaving `working` untouched) when the solver
    /// cannot hold the new value, so callers can fall back honestly.
    private func trySolveCopy(_ copyIn: Sketch, note: String) -> Bool {
        // Heavy sketches skip the solver — callers fall back to the
        // direct edit, which is the honest behavior there.
        if isHeavy { return false }
        var copy = copyIn
        do {
            let result = try SketchSolver.solve(&copy)
            working = copy
            solveError = nil
            var n = note
            if let w = result.warnings.first {
                n += " \(w.userMessage) (\(w.code))"
            }
            solveNote = n
            changed()
            loadInspector()
            refreshMeasureText()
            return true
        } catch {
            return false
        }
    }

    /// Update-or-create a Distance dimension between two points and
    /// solve. If the solver cannot hold it (conflicting constraints),
    /// fall back to the direct edit: move B along the A→B direction.
    private func applyDrivingDistance(_ a: SketchPointRef, _ b: SketchPointRef, value: Double) {
        var copy = working
        if let i = distanceConstraintIndex(a, b) {
            copy.constraints[i] = constraint(copy.constraints[i], withValue: value)
        } else {
            copy.constraints.append(.distancePoints(entityA: a.entityID, kindA: a.kind,
                                                    entityB: b.entityID, kindB: b.kind,
                                                    value: value))
        }
        if trySolveCopy(copy, note: "Dimension set to \(mcFmt(value)) mm — the sketch now drives from it.") {
            return
        }
        solveNote = nil
        if let pa = a.resolve(in: working), let pb = b.resolve(in: working) {
            let d = pa.distance(to: pb)
            if d > 1e-9 {
                _ = movePoint(b, to: pa + (pb - pa) * (value / d))
            } else {
                _ = movePoint(b, to: pa + Vec2(value, 0))
            }
        }
        changed()
        loadInspector()
        refreshMeasureText()
    }

    /// Update-or-create a Radius dimension (a Diameter dimension is
    /// updated in diameter units) and solve; falls back to setting the
    /// radius directly when the solver cannot hold it.
    private func applyDrivingRadius(entityID: Int, value: Double) {
        var copy = working
        var handled = false
        for i in copy.constraints.indices {
            switch copy.constraints[i] {
            case .radius(let e, _) where e == entityID:
                copy.constraints[i] = .radius(entity: e, value: value)
                handled = true
            case .diameter(let e, _) where e == entityID:
                copy.constraints[i] = .diameter(entity: e, value: value * 2)
                handled = true
            default:
                break
            }
        }
        if !handled {
            copy.constraints.append(.radius(entity: entityID, value: value))
        }
        if trySolveCopy(copy, note: "Radius driven to \(mcFmt(value)) mm.") { return }
        if let idx = working.entities.firstIndex(where: { $0.id == entityID }),
           case .circle(let id, let c, _, let cons) = working.entities[idx] {
            working.entities[idx] = .circle(id: id, center: c, radius: value, construction: cons)
        }
        changed()
        loadInspector()
    }

    // MARK: Constraints list (values editable in place)

    private var constraintsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Constraints — edit a value, Apply, and the sketch drives from it")
                .mcFont(19, weight: .bold)
            ForEach(Array(working.constraints.enumerated()), id: \.offset) { i, c in
                ConstraintRow(
                    constraint: c,
                    onApplyValue: { v in updateConstraintValue(at: i, value: v) },
                    onDelete: { deleteConstraint(at: i) }
                )
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06)))
    }

    private func updateConstraintValue(at index: Int, value: Double) {
        guard working.constraints.indices.contains(index) else { return }
        working.constraints[index] = constraint(working.constraints[index], withValue: value)
        changed()
        solve()
        refreshMeasureText()
    }

    private func deleteConstraint(at index: Int) {
        guard working.constraints.indices.contains(index) else { return }
        working.constraints.remove(at: index)
        changed()
    }

    // MARK: Tools + inspector

    private var toolBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                // Measure is PINNED outside the scrolling tool row:
                // always visible, never scrolled off or in a submenu
                // — measuring is a universal action, not one tool
                // among many. Same styling as the tool capsules.
                Button {
                    tool = .measure
                    pending = nil
                    splinePoints = []
                    slotTaps = []
                } label: {
                    Label("Measure", systemImage: "ruler")
                }
                .mcFont(20, weight: .semibold)
                .foregroundStyle(tool == .measure ? .black : .accentColor)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Capsule().fill(tool == .measure ? Color.yellow : Color.clear))
                .overlay(Capsule().stroke(Color.yellow.opacity(tool == .measure ? 0 : 0.45),
                                          lineWidth: 1))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Tool.allCases.filter { $0 != .measure }, id: \.self) { option in
                            Button(option.rawValue) {
                                tool = option
                                pending = nil
                                splinePoints = []
                                slotTaps = []
                            }
                            .mcFont(20, weight: .semibold)
                            .foregroundStyle(tool == option ? .black : .accentColor)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(Capsule().fill(tool == option ? Color.yellow : Color.clear))
                        }
                    }
                }
            }
            HStack(spacing: 14) {
                Toggle("Snap", isOn: $snapEnabled)
                    .mcFont(20, weight: .semibold)
                    .fixedSize()
                if pending != nil {
                    Text("Tap the second point…")
                        .mcFont(18)
                        .foregroundStyle(.yellow)
                    Button("Cancel") { pending = nil }
                        .mcFont(20, weight: .semibold)
                }
                Spacer()
                Button("Fit") { frozenTransform = nil }
                    .mcFont(20, weight: .semibold)
                Button("Solve") { solve() }
                    .mcFont(20, weight: .semibold)
            }
            if let lineID = selectedLineID {
                HStack(spacing: 10) {
                    Text("Line #\(lineID):")
                        .mcFont(20, weight: .semibold)
                    Button("Horizontal") {
                        working.constraints.append(.horizontal(entity: lineID))
                        changed()
                    }
                    Button("Vertical") {
                        working.constraints.append(.vertical(entity: lineID))
                        changed()
                    }
                    Spacer()
                }
                .mcFont(20, weight: .semibold)
            }
        }
    }

    /// Contextual options for the tap-tools that need them (spline
    /// finish, polygon sides, slot progress, trim hint).
    @ViewBuilder
    private var toolOptionsRow: some View {
        switch tool {
        case .spline:
            HStack(spacing: 12) {
                Text(splinePoints.isEmpty
                     ? "Spline: tap points — the curve flows through them."
                     : "Spline: \(splinePoints.count) point\(splinePoints.count == 1 ? "" : "s") placed.")
                    .mcFont(18, weight: .semibold)
                    .foregroundStyle(.yellow)
                Spacer()
                if splinePoints.count >= 2 {
                    Button("Finish Spline") { finishSpline() }
                        .mcFont(20, weight: .semibold)
                        .foregroundStyle(.black)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(Capsule().fill(accent))
                }
                if !splinePoints.isEmpty {
                    Button("Cancel") { splinePoints = [] }
                        .mcFont(20, weight: .semibold)
                }
            }
        case .polygon:
            HStack(spacing: 12) {
                Stepper("Sides: \(polygonSides)", value: $polygonSides, in: 3...12)
                    .mcFont(20, weight: .semibold)
                    .fixedSize()
                Text("Tap the center, then a corner.")
                    .mcFont(18)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        case .slot:
            Text(slotTaps.isEmpty
                 ? "Slot: tap the first center, then the second center, then a point at the radius."
                 : (slotTaps.count == 1 ? "Slot: tap the second center." : "Slot: tap a point at the slot's radius."))
                .mcFont(18, weight: .semibold)
                .foregroundStyle(.yellow)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .trim:
            Text("Trim: tap a line — the piece between its crossings with other lines is removed. Lines only; a line with no crossings is deleted whole.")
                .mcFont(18, weight: .semibold)
                .foregroundStyle(.yellow)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .ellipse:
            Text("Ellipse: tap the center, then a corner of its bounding box.")
                .mcFont(18)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        default:
            EmptyView()
        }
    }

    private var selectedLineID: Int? {
        guard let id = selectedID, let e = working.entity(id) else { return nil }
        if case .line = e { return id }
        return nil
    }

    @ViewBuilder
    private func inspector(for id: Int) -> some View {
        if let e = working.entity(id) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Edit — \(describe(e))")
                    .mcFont(21, weight: .bold)
                switch e {
                case .line:
                    HStack(spacing: 8) {
                        field("A X", $fAX); field("A Y", $fAY)
                        field("B X", $fBX); field("B Y", $fBY)
                    }
                    HStack(spacing: 8) {
                        field("Length mm", $fLength)
                        Button("Apply") { applyLineEdits(id: id) }
                            .mcFont(20, weight: .semibold)
                        Spacer()
                    }
                    Text("Length is a driving dimension: Apply sets (or updates) a Distance constraint between the line's ends and solves — change 14.3 to 14 and the sketch follows.")
                        .mcFont(16)
                        .foregroundStyle(.secondary)
                case .circle:
                    HStack(spacing: 8) {
                        field("Center X", $fCX); field("Center Y", $fCY); field("Radius", $fRadius)
                    }
                    HStack {
                        Button("Apply") { applyCircleEdits(id: id) }
                            .mcFont(20, weight: .semibold)
                        Spacer()
                    }
                    Text("Radius is a driving dimension too: Apply sets (or updates) a Radius constraint and solves.")
                        .mcFont(16)
                        .foregroundStyle(.secondary)
                case .point:
                    HStack(spacing: 8) {
                        field("X", $fCX); field("Y", $fCY)
                        Button("Apply") { applyPointEdits(id: id) }
                            .mcFont(20, weight: .semibold)
                        Spacer()
                    }
                case .arc:
                    HStack(spacing: 8) {
                        field("Center X", $fCX); field("Center Y", $fCY); field("Radius", $fRadius)
                    }
                    HStack {
                        Button("Apply") { applyArcEdits(id: id) }
                            .mcFont(20, weight: .semibold)
                        Spacer()
                    }
                }
                HStack(spacing: 10) {
                    Text("Construction (reference only — not built)")
                        .mcFont(17, weight: .semibold)
                    Spacer()
                    Button(e.isConstruction ? "On" : "Off") { toggleConstruction(id: id) }
                        .mcFont(20, weight: .semibold)
                        .foregroundStyle(.black)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(Capsule().fill(e.isConstruction ? Color.yellow : Color.white.opacity(0.15)))
                }
                Text("Type exact numbers, then Apply. Dragging a white point also moves it (with snapping).")
                    .mcFont(16)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06)))
        }
    }

    private func field(_ label: String, _ binding: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .mcFont(15, weight: .semibold)
                .foregroundStyle(.secondary)
            TextField(label, text: binding)
                .keyboardType(.numbersAndPunctuation)
                .mcFont(20, weight: .semibold)
                .frame(minWidth: 70)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func loadInspector() {
        guard let id = selectedID, let e = working.entity(id) else { return }
        switch e {
        case .line(_, let a, let b, _):
            fAX = mcFmt(a.x); fAY = mcFmt(a.y); fBX = mcFmt(b.x); fBY = mcFmt(b.y)
            fLength = mcFmt(a.distance(to: b))
        case .circle(_, let c, let r, _):
            fCX = mcFmt(c.x); fCY = mcFmt(c.y); fRadius = mcFmt(r)
        case .point(_, let at, _):
            fCX = mcFmt(at.x); fCY = mcFmt(at.y)
        case .arc(_, let c, let r, _, _, _):
            fCX = mcFmt(c.x); fCY = mcFmt(c.y); fRadius = mcFmt(r)
        }
    }

    private func num(_ s: String, fallback: Double) -> Double { Double(s) ?? fallback }

    private func applyLineEdits(id: Int) {
        guard let idx = working.entities.firstIndex(where: { $0.id == id }),
              case .line(_, let a0, let b0, let cons) = working.entities[idx] else { return }
        let a = Vec2(num(fAX, fallback: a0.x), num(fAY, fallback: a0.y))
        let b = Vec2(num(fBX, fallback: b0.x), num(fBY, fallback: b0.y))
        working.entities[idx] = .line(id: id, a: a, b: b, construction: cons)
        changed()
        // Length drives parametrically when it was actually changed.
        if let wanted = Double(fLength), wanted > 0 {
            let current = a.distance(to: b)
            if abs(wanted - current) > 1e-9 {
                applyDrivingDistance(SketchPointRef(entityID: id, kind: .start),
                                     SketchPointRef(entityID: id, kind: .end),
                                     value: wanted)
            }
        }
        loadInspector()
    }

    private func applyCircleEdits(id: Int) {
        guard let idx = working.entities.firstIndex(where: { $0.id == id }),
              case .circle(_, let c0, let r0, let cons) = working.entities[idx] else { return }
        let c = Vec2(num(fCX, fallback: c0.x), num(fCY, fallback: c0.y))
        working.entities[idx] = .circle(id: id, center: c, radius: r0, construction: cons)
        changed()
        if let wanted = Double(fRadius), wanted > 0.05, abs(wanted - r0) > 1e-9 {
            applyDrivingRadius(entityID: id, value: wanted)
        }
        loadInspector()
    }

    private func applyPointEdits(id: Int) {
        guard let idx = working.entities.firstIndex(where: { $0.id == id }),
              case .point(_, let at0, let cons) = working.entities[idx] else { return }
        let at = Vec2(num(fCX, fallback: at0.x), num(fCY, fallback: at0.y))
        working.entities[idx] = .point(id: id, at: at, construction: cons)
        changed()
        loadInspector()
    }

    private func applyArcEdits(id: Int) {
        guard let idx = working.entities.firstIndex(where: { $0.id == id }),
              case .arc(_, let c0, let r0, let a0, let a1, let cons) = working.entities[idx] else { return }
        let c = Vec2(num(fCX, fallback: c0.x), num(fCY, fallback: c0.y))
        let r = max(0.1, num(fRadius, fallback: r0))
        working.entities[idx] = .arc(id: id, center: c, radius: r,
                                       startAngle: a0, endAngle: a1, construction: cons)
        changed()
        loadInspector()
    }

    private var entityList: some View {
        VStack(spacing: 0) {
            ForEach(working.entities, id: \.id) { e in
                HStack(spacing: 12) {
                    Text(describe(e))
                        .mcFont(19, weight: e.id == selectedID ? .bold : .regular)
                        .foregroundStyle(e.id == selectedID ? accent : .primary)
                    Spacer()
                    Button(role: .destructive) {
                        deleteEntity(e.id)
                    } label: {
                        Image(systemName: "trash")
                            .mcFont(20)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 8)
                .contentShape(Rectangle())
                .onTapGesture { selectedID = e.id }
                Divider()
            }
        }
    }

    // MARK: Actions

    private func changed() {
        model.replaceSketch(working)
        refresh()
    }

    private func refresh() {
        dof = SketchSolver.degreesOfFreedom(working)
        health = working.validate()
    }

    private func deleteEntity(_ id: Int) {
        working.removeEntity(id)
        working.constraints.removeAll { $0.referencedEntities.contains(id) }
        if selectedID == id { selectedID = nil }
        if measureA?.entityID == id { measureA = nil }
        if measureB?.entityID == id { measureB = nil }
        changed()
    }

    private func solve() {
        if isHeavy {
            solveError = nil
            solveNote = "Heavy sketch (\(working.entities.count) items) — solver passes are skipped."
            return
        }
        var copy = working
        do {
            let result = try SketchSolver.solve(&copy)
            working = copy
            solveError = nil
            var note = "Solved in \(result.iterations) iterations."
            if let w = result.warnings.first {
                note += " \(w.userMessage) (\(w.code))"
            }
            solveNote = note
            changed()
            loadInspector()
        } catch let e as CADError {
            solveError = e
            solveNote = nil
            MCLog.shared.log(error: e, category: .solver)
        } catch {
            solveError = .unknown("\(error)")
            solveNote = nil
        }
    }

    private func describe(_ e: SketchEntity) -> String {
        switch e {
        case .point(let id, let at, _):
            return "Point #\(id) · (\(mcFmt(at.x)), \(mcFmt(at.y)))"
        case .line(let id, let a, let b, _):
            return "Line #\(id) · \(mcFmt(a.distance(to: b))) mm"
        case .circle(let id, _, let r, _):
            return "Circle #\(id) · r \(mcFmt(r))"
        case .arc(let id, _, let r, _, _, _):
            return "Arc #\(id) · r \(mcFmt(r))"
        }
    }

    // MARK: v4 entity transforms (move / rotate / scale / mirror / copies)

    private func definingPoints(_ e: SketchEntity) -> [Vec2] {
        switch e {
        case .point(_, let at, _): return [at]
        case .line(_, let a, let b, _): return [a, b]
        case .circle(_, let c, _, _): return [c]
        case .arc:
            var pts: [Vec2] = []
            if let c = e.resolve(.center) { pts.append(c) }
            if let s = e.resolve(.start) { pts.append(s) }
            if let en = e.resolve(.end) { pts.append(en) }
            return pts
        }
    }

    private func centroid(of entities: [SketchEntity]) -> Vec2 {
        var pts: [Vec2] = []
        for e in entities { pts += definingPoints(e) }
        guard !pts.isEmpty else { return .zero }
        return pts.reduce(.zero, +) * (1.0 / Double(pts.count))
    }

    /// The entities an edit operation applies to: the selection when
    /// the scope says so and something is selected, else everything.
    private func scopedEntities() -> [SketchEntity] {
        if opScope == "selected", let id = selectedID, let e = working.entity(id) {
            return [e]
        }
        return working.entities
    }

    private func mapScoped(_ f: (SketchEntity) -> SketchEntity) {
        let ids = Set(scopedEntities().map { $0.id })
        guard !ids.isEmpty else { return }
        working.entities = working.entities.map { ids.contains($0.id) ? f($0) : $0 }
        changed()
    }

    private func translatedEntity(_ e: SketchEntity, by d: Vec2) -> SketchEntity {
        switch e {
        case .point(let id, let at, let c):
            return .point(id: id, at: at + d, construction: c)
        case .line(let id, let a, let b, let c):
            return .line(id: id, a: a + d, b: b + d, construction: c)
        case .circle(let id, let ctr, let r, let c):
            return .circle(id: id, center: ctr + d, radius: r, construction: c)
        case .arc(let id, let ctr, let r, let a0, let a1, let c):
            return .arc(id: id, center: ctr + d, radius: r,
                        startAngle: a0, endAngle: a1, construction: c)
        }
    }

    private func rotatePoint(_ p: Vec2, center: Vec2, _ th: Double) -> Vec2 {
        let d = p - center
        return center + Vec2(d.x * cos(th) - d.y * sin(th),
                             d.x * sin(th) + d.y * cos(th))
    }

    private func rotatedEntity(_ e: SketchEntity, center: Vec2, radians th: Double) -> SketchEntity {
        switch e {
        case .point(let id, let at, let c):
            return .point(id: id, at: rotatePoint(at, center: center, th), construction: c)
        case .line(let id, let a, let b, let c):
            return .line(id: id, a: rotatePoint(a, center: center, th),
                         b: rotatePoint(b, center: center, th), construction: c)
        case .circle(let id, let ctr, let r, let c):
            return .circle(id: id, center: rotatePoint(ctr, center: center, th),
                           radius: r, construction: c)
        case .arc(let id, let ctr, let r, let a0, let a1, let c):
            return .arc(id: id, center: rotatePoint(ctr, center: center, th), radius: r,
                        startAngle: a0 + th, endAngle: a1 + th, construction: c)
        }
    }

    private func scaledEntity(_ e: SketchEntity, center: Vec2, factor s: Double) -> SketchEntity {
        func sp(_ p: Vec2) -> Vec2 { center + (p - center) * s }
        switch e {
        case .point(let id, let at, let c):
            return .point(id: id, at: sp(at), construction: c)
        case .line(let id, let a, let b, let c):
            return .line(id: id, a: sp(a), b: sp(b), construction: c)
        case .circle(let id, let ctr, let r, let c):
            return .circle(id: id, center: sp(ctr), radius: r * abs(s), construction: c)
        case .arc(let id, let ctr, let r, let a0, let a1, let c):
            return .arc(id: id, center: sp(ctr), radius: r * abs(s),
                        startAngle: a0, endAngle: a1, construction: c)
        }
    }

    /// Reflect across the line through `linePoint` with direction
    /// angle `phi`. Arc sweeps flip, so start/end angles swap.
    private func reflectedEntity(_ e: SketchEntity, linePoint: Vec2, phi: Double) -> SketchEntity {
        let u = Vec2(cos(phi), sin(phi))
        func rp(_ p: Vec2) -> Vec2 {
            let d = p - linePoint
            let along = u * d.dot(u)
            return linePoint + along - (d - along)
        }
        switch e {
        case .point(let id, let at, let c):
            return .point(id: id, at: rp(at), construction: c)
        case .line(let id, let a, let b, let c):
            return .line(id: id, a: rp(a), b: rp(b), construction: c)
        case .circle(let id, let ctr, let r, let c):
            return .circle(id: id, center: rp(ctr), radius: r, construction: c)
        case .arc(let id, let ctr, let r, let a0, let a1, let c):
            return .arc(id: id, center: rp(ctr), radius: r,
                        startAngle: 2 * phi - a1, endAngle: 2 * phi - a0,
                        construction: c)
        }
    }

    private func entityWithID(_ e: SketchEntity, _ newID: Int) -> SketchEntity {
        switch e {
        case .point(_, let at, let c):
            return .point(id: newID, at: at, construction: c)
        case .line(_, let a, let b, let c):
            return .line(id: newID, a: a, b: b, construction: c)
        case .circle(_, let ctr, let r, let c):
            return .circle(id: newID, center: ctr, radius: r, construction: c)
        case .arc(_, let ctr, let r, let a0, let a1, let c):
            return .arc(id: newID, center: ctr, radius: r,
                        startAngle: a0, endAngle: a1, construction: c)
        }
    }

    private func setConstruction(_ e: SketchEntity, _ flag: Bool) -> SketchEntity {
        switch e {
        case .point(let id, let at, _):
            return .point(id: id, at: at, construction: flag)
        case .line(let id, let a, let b, _):
            return .line(id: id, a: a, b: b, construction: flag)
        case .circle(let id, let ctr, let r, _):
            return .circle(id: id, center: ctr, radius: r, construction: flag)
        case .arc(let id, let ctr, let r, let a0, let a1, _):
            return .arc(id: id, center: ctr, radius: r,
                        startAngle: a0, endAngle: a1, construction: flag)
        }
    }

    private func toggleConstruction(id: Int) {
        guard let idx = working.entities.firstIndex(where: { $0.id == id }) else { return }
        let e = working.entities[idx]
        working.entities[idx] = setConstruction(e, !e.isConstruction)
        changed()
    }

    /// Center for rotate/scale/pattern: the typed center when both
    /// fields parse, else the middle of the edit set.
    private func opCenter(xText: String, yText: String, scoped: [SketchEntity]) -> Vec2 {
        if let x = Double(xText), let y = Double(yText) { return Vec2(x, y) }
        return centroid(of: scoped)
    }

    private func applyMoveSelection() {
        let d = Vec2(num(moveDX, fallback: 0), num(moveDY, fallback: 0))
        mapScoped { translatedEntity($0, by: d) }
    }

    private func applyRotateSelection() {
        let scoped = scopedEntities()
        guard !scoped.isEmpty else { return }
        let center = opCenter(xText: rotateCX, yText: rotateCY, scoped: scoped)
        let th = num(rotateDeg, fallback: 0) * Double.pi / 180
        mapScoped { rotatedEntity($0, center: center, radians: th) }
    }

    private func applyScaleSelection() {
        let scoped = scopedEntities()
        guard !scoped.isEmpty else { return }
        let s = num(scaleFactor, fallback: 1)
        guard s > 0 else {
            solveError = nil
            solveNote = "Scale factor must be above 0."
            return
        }
        let center = opCenter(xText: scaleCX, yText: scaleCY, scoped: scoped)
        mapScoped { scaledEntity($0, center: center, factor: s) }
    }

    /// Mirror the edit set in place across the axis (direction phi)
    /// through its own middle.
    private func applyMirrorSelection(phi: Double) {
        let scoped = scopedEntities()
        guard !scoped.isEmpty else { return }
        let mid = centroid(of: scoped)
        mapScoped { reflectedEntity($0, linePoint: mid, phi: phi) }
    }

    /// Mirror everything except the selected line across that line.
    private func mirrorAcrossSelectedLine() {
        guard let lineID = selectedLineID,
              let e = working.entity(lineID),
              case .line(_, let a, let b, _) = e else { return }
        let phi = atan2(b.y - a.y, b.x - a.x)
        working.entities = working.entities.map { ent in
            ent.id == lineID ? ent : reflectedEntity(ent, linePoint: a, phi: phi)
        }
        changed()
    }

    private func applyPatternSelection() {
        let sources = scopedEntities()
        guard !sources.isEmpty else { return }
        var copies: [SketchEntity] = []
        if patternMode == "rect" {
            let rows = max(1, Int(patRows) ?? 1)
            let cols = max(1, Int(patCols) ?? 1)
            let dx = num(patSX, fallback: 0)
            let dy = num(patSY, fallback: 0)
            for r in 0..<rows {
                for c in 0..<cols where !(r == 0 && c == 0) {
                    for e in sources {
                        copies.append(translatedEntity(e, by: Vec2(dx * Double(c), dy * Double(r))))
                    }
                }
            }
        } else {
            let count = max(2, Int(patCount) ?? 2)
            let total = num(patTotal, fallback: 360)
            let center = opCenter(xText: patCX, yText: patCY, scoped: sources)
            // A full circle divides by the copy count (no duplicate at
            // 360°); a partial fan divides by count − 1 so the first
            // and last copies land on the fan's ends.
            let step = total >= 359.999
                ? total / Double(count)
                : total / Double(max(1, count - 1))
            for i in 1..<count {
                let th = step * Double(i) * Double.pi / 180
                for e in sources {
                    copies.append(rotatedEntity(e, center: center, radians: th))
                }
            }
        }
        for copy in copies {
            working.add(entityWithID(copy, working.allocateID()))
        }
        if !copies.isEmpty {
            solveNote = "Patterned \(copies.count) new item\(copies.count == 1 ? "" : "s")."
        }
        changed()
    }

    private func applyOffsetProfile() {
        do {
            let (profiles, _) = try working.extractProfiles()
            guard let profile = profiles.first else { throw CADError.padNoProfile }
            let d = num(offsetDist, fallback: 0)
            guard d != 0 else { return }
            guard let outer = Tessellation.offsetPolygon(profile.outer, by: d) else {
                solveError = .booleanFailed("that offset collapses the profile — try a smaller distance")
                solveNote = nil
                return
            }
            addLoop(outer)
            for hole in profile.holes {
                if let h = Tessellation.offsetPolygon(hole, by: -d) { addLoop(h) }
            }
            solveError = nil
            solveNote = "Offset the profile by \(mcFmt(d)) mm into a new loop."
            changed()
        } catch let e as CADError {
            solveError = e
            solveNote = nil
            MCLog.shared.log(error: e, category: .sketch)
        } catch {
            solveError = .unknown("\(error)")
            solveNote = nil
        }
    }

    private func addLoop(_ pts: [Vec2]) {
        guard pts.count >= 3 else { return }
        for i in pts.indices {
            working.addLine(pts[i], pts[(i + 1) % pts.count])
        }
    }

    // MARK: v4 project geometry

    private func projectBodyEdges() {
        guard let mesh = model.rebuild?.mesh, mesh.triangleCount > 0 else {
            solveNote = "There is no body to project yet."
            return
        }
        let segs = ProjectGeometry.edgeSegments(body: mesh, onto: working.plane)
        var added = 0
        for (a, b) in segs where a.distance(to: b) > 1e-6 {
            working.addLine(a, b, construction: true)
            added += 1
        }
        solveNote = "Projected \(added) body edge\(added == 1 ? "" : "s") as construction lines."
        changed()
    }

    private func projectFaceOutline() {
        let outline = guideOutline
        guard outline.count > 1 else {
            solveNote = "This sketch is not on a model face, so there is no face outline to project."
            return
        }
        for i in outline.indices {
            working.addLine(outline[i], outline[(i + 1) % outline.count], construction: true)
        }
        solveNote = "Projected the host face outline as construction lines."
        changed()
    }

    // MARK: v4 shape builders (spline / ellipse / polygon / slot)

    /// Catmull-Rom samples through the points (endpoints duplicated),
    /// ~8 samples per span — smooth to look at, plain lines to build.
    private func catmullRomSamples(_ pts: [Vec2], samplesPerSpan: Int = 8) -> [Vec2] {
        guard pts.count >= 2 else { return pts }
        if pts.count == 2 { return pts }
        let ext = [pts[0]] + pts + [pts[pts.count - 1]]
        var out: [Vec2] = []
        for i in 1..<(ext.count - 2) {
            let p0 = ext[i - 1], p1 = ext[i], p2 = ext[i + 1], p3 = ext[i + 2]
            for s in 0..<samplesPerSpan {
                let t = Double(s) / Double(samplesPerSpan)
                let t2 = t * t
                let t3 = t2 * t
                let q = (p1 * 2 + (p2 - p0) * t
                         + (p0 * 2 - p1 * 5 + p2 * 4 - p3) * t2
                         + (p1 * 3 - p0 - p2 * 3 + p3) * t3) * 0.5
                out.append(q)
            }
        }
        out.append(pts[pts.count - 1])
        return out
    }

    private func finishSpline() {
        guard splinePoints.count >= 2 else { return }
        let samples = catmullRomSamples(splinePoints)
        for i in 0..<(samples.count - 1) {
            if samples[i].distance(to: samples[i + 1]) > 1e-6 {
                working.addLine(samples[i], samples[i + 1])
            }
        }
        splinePoints = []
        changed()
    }

    private func addEllipseLoop(center: Vec2, rx: Double, ry: Double) {
        let n = 48
        var prev = center + Vec2(rx, 0)
        for i in 1...n {
            let a = Double(i) / Double(n) * 2 * Double.pi
            let p = center + Vec2(rx * cos(a), ry * sin(a))
            working.addLine(prev, p)
            prev = p
        }
    }

    private func polygonVertices(center: Vec2, vertex: Vec2, sides: Int) -> [Vec2] {
        let r = center.distance(to: vertex)
        let a0 = atan2(vertex.y - center.y, vertex.x - center.x)
        return (0..<sides).map { i in
            let a = a0 + Double(i) * 2 * Double.pi / Double(sides)
            return center + Vec2(r * cos(a), r * sin(a))
        }
    }

    private func addPolygonLoop(center: Vec2, vertex: Vec2, sides: Int) {
        let verts = polygonVertices(center: center, vertex: vertex, sides: sides)
        for i in verts.indices {
            working.addLine(verts[i], verts[(i + 1) % verts.count])
        }
    }

    /// Slot geometry shared by the entity builder and the outline
    /// preview: two straight runs + two semicircular caps, as proper
    /// line and arc entities.
    private func slotParts(a: Vec2, b: Vec2, r: Double)
        -> (topA: Vec2, topB: Vec2, botA: Vec2, botB: Vec2,
            perpAngle: Double) {
        let dir = (b - a).normalized
        let perp = dir.perpendicular
        return (a + perp * r, b + perp * r, a - perp * r, b - perp * r,
                atan2(perp.y, perp.x))
    }

    private func addSlotEntities(a: Vec2, b: Vec2, r: Double) {
        let parts = slotParts(a: a, b: b, r: r)
        let pa = parts.perpAngle
        working.addLine(parts.topB, parts.topA)
        working.addLine(parts.botA, parts.botB)
        // Cap at B sweeps CCW from −perp through the outward (+dir)
        // side to +perp; cap at A from +perp through −dir to −perp.
        working.add(.arc(id: working.allocateID(), center: b, radius: r,
                         startAngle: pa - Double.pi, endAngle: pa,
                         construction: false))
        working.add(.arc(id: working.allocateID(), center: a, radius: r,
                         startAngle: pa, endAngle: pa + Double.pi,
                         construction: false))
    }

    private func slotOutlinePoints(a: Vec2, b: Vec2, r: Double) -> [Vec2] {
        let parts = slotParts(a: a, b: b, r: r)
        let pa = parts.perpAngle
        let arcB = arcPoints(center: b, radius: r, from: pa - Double.pi, to: pa,
                             sagitta: 0.05, closed: false)
        let arcA = arcPoints(center: a, radius: r, from: pa, to: pa + Double.pi,
                             sagitta: 0.05, closed: false)
        var pts: [Vec2] = [parts.topA]
        pts += arcB.reversed()          // top of B around the cap to bottom of B
        pts += arcA.reversed().dropLast()
        return pts
    }

    // MARK: v4 trim (lines only)

    private func pointSegmentDistance(_ p: Vec2, _ a: Vec2, _ b: Vec2) -> Double {
        let ab = b - a
        let len2 = ab.lengthSquared
        if len2 < 1e-12 { return p.distance(to: a) }
        let t = min(1, max(0, (p - a).dot(ab) / len2))
        return p.distance(to: a + ab * t)
    }

    /// Trim: split the tapped line at its crossings with other lines
    /// and remove the piece that was tapped; the rest stays. A line
    /// with no crossings is removed whole.
    private func trimTappedLine(at p: Vec2, scale: Double) {
        var target: (id: Int, a: Vec2, b: Vec2, cons: Bool, dist: Double)?
        for e in working.entities {
            if case .line(let id, let a, let b, let cons) = e {
                let d = pointSegmentDistance(p, a, b)
                if target == nil || d < target!.dist {
                    target = (id, a, b, cons, d)
                }
            }
        }
        guard let t = target, t.dist <= 16 / max(scale, 0.001) else {
            solveNote = "Trim: tap a line (lines only)."
            return
        }
        let ab = t.b - t.a
        let len2 = ab.lengthSquared
        guard len2 > 1e-12 else { return }
        var cuts: [Double] = [0, 1]
        for e in working.entities where e.id != t.id {
            if case .line(_, let c, let d, _) = e,
               let hit = segmentsCross(t.a, t.b, c, d) {
                cuts.append((hit - t.a).dot(ab) / len2)
            }
        }
        cuts.sort()
        let tTap = min(1, max(0, (p - t.a).dot(ab) / len2))
        working.removeEntity(t.id)
        // Trimming can orphan constraints that referenced the line.
        working.constraints.removeAll { $0.referencedEntities.contains(t.id) }
        if selectedID == t.id { selectedID = nil }
        if cuts.count == 2 {
            solveNote = "Trimmed the whole line — it crossed no other line."
        } else {
            for i in 0..<(cuts.count - 1) {
                let lo = cuts[i], hi = cuts[i + 1]
                if tTap >= lo && tTap <= hi { continue }  // the tapped piece goes
                let p0 = t.a + ab * lo
                let p1 = t.a + ab * hi
                if p0.distance(to: p1) > 1e-9 {
                    working.addLine(p0, p1, construction: t.cons)
                }
            }
            solveNote = "Trimmed — the tapped piece is gone, the rest stays."
        }
        changed()
    }

    // MARK: v4 text (CoreText glyph outlines)

    private func addTextEntities() {
        let size = max(2, num(textSize, fallback: 20))
        let origin = Vec2(num(textX, fallback: 0), num(textY, fallback: 0))
        let loops = textOutlines(text: textString, fontName: textFont,
                                 size: size, origin: origin)
        var added = 0
        for loop in loops where loop.count >= 2 {
            for i in loop.indices {
                let a = loop[i]
                let b = loop[(i + 1) % loop.count]
                if a.distance(to: b) > 0.005 {
                    working.addLine(a, b)
                    added += 1
                }
            }
        }
        if added == 0 {
            solveNote = "No outlines came out of that text and font — try different words."
        } else {
            solveError = nil
            solveNote = "Added \(added) text segments. Extrude with Join to emboss, Cut to engrave."
        }
        changed()
    }

    /// Flattened glyph outlines for a string, in sketch coordinates
    /// (CoreText glyph space is y-up, like the sketch). Curves are
    /// sampled at 8 steps — plenty at text sizes.
    private func textOutlines(text: String, fontName: String, size: Double,
                              origin: Vec2) -> [[Vec2]] {
        let font = CTFontCreateWithName(fontName as CFString, CGFloat(size), nil)
        var utf16 = Array(text.utf16)
        guard !utf16.isEmpty else { return [] }
        var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
        CTFontGetGlyphsForCharacters(font, &utf16, &glyphs, utf16.count)
        var advances = [CGSize](repeating: .zero, count: utf16.count)
        CTFontGetAdvancesForGlyphs(font, .default, glyphs, &advances, utf16.count)
        var loops: [[Vec2]] = []
        var penX = 0.0
        for i in glyphs.indices {
            if glyphs[i] != 0, let path = CTFontCreatePathForGlyph(font, glyphs[i], nil) {
                loops += flattenGlyphPath(path, offset: Vec2(origin.x + penX, origin.y))
            }
            penX += Double(advances[i].width)
        }
        return loops
    }

    private func flattenGlyphPath(_ path: CGPath, offset: Vec2) -> [[Vec2]] {
        var loops: [[Vec2]] = []
        var current: [Vec2] = []
        var last = Vec2.zero
        func conv(_ p: CGPoint) -> Vec2 { offset + Vec2(Double(p.x), Double(p.y)) }
        func flush() {
            if current.count > 1 { loops.append(current) }
            current = []
        }
        path.applyWithBlock { elementPtr in
            let el = elementPtr.pointee
            switch el.type {
            case .moveToPoint:
                flush()
                let p = conv(el.points[0])
                current = [p]
                last = p
            case .addLineToPoint:
                let p = conv(el.points[0])
                current.append(p)
                last = p
            case .addQuadCurveToPoint:
                let c = conv(el.points[0])
                let e = conv(el.points[1])
                for s in 1...8 {
                    let t = Double(s) / 8
                    let u = 1 - t
                    current.append(last * (u * u) + c * (2 * u * t) + e * (t * t))
                }
                last = e
            case .addCurveToPoint:
                let c1 = conv(el.points[0])
                let c2 = conv(el.points[1])
                let e = conv(el.points[2])
                for s in 1...8 {
                    let t = Double(s) / 8
                    let u = 1 - t
                    current.append(last * (u * u * u) + c1 * (3 * u * u * t)
                                   + c2 * (3 * u * t * t) + e * (t * t * t))
                }
                last = e
            case .closeSubpath:
                flush()
            @unknown default:
                break
            }
        }
        flush()
        return loops
    }
}

// MARK: - Constraint row (value editable in place)

struct ConstraintRow: View {
    let constraint: SketchConstraint
    let onApplyValue: (Double) -> Void
    let onDelete: () -> Void

    @State private var text: String

    init(constraint: SketchConstraint,
         onApplyValue: @escaping (Double) -> Void,
         onDelete: @escaping () -> Void) {
        self.constraint = constraint
        self.onApplyValue = onApplyValue
        self.onDelete = onDelete
        _text = State(initialValue: Self.value(of: constraint).map(mcFmt) ?? "")
    }

    private static func value(of c: SketchConstraint) -> Double? {
        switch c {
        case .distancePoints(_, _, _, _, let v): return v
        case .radius(_, let v): return v
        case .diameter(_, let v): return v
        case .angleBetween(_, _, let v): return v
        default: return nil
        }
    }

    private var hasValue: Bool { Self.value(of: constraint) != nil }

    private var detail: String {
        switch constraint {
        case .coincident(let a, _, let b, _): return "#\(a) ↔ #\(b)"
        case .horizontal(let e), .vertical(let e): return "line #\(e)"
        case .distancePoints(let a, _, let b, _, _): return "#\(a) ↔ #\(b)"
        case .radius(let e, _): return "circle #\(e)"
        case .diameter(let e, _): return "circle #\(e)"
        case .equalRadius(let a, let b), .equalLength(let a, let b),
             .parallel(let a, let b), .perpendicular(let a, let b):
            return "#\(a) ↔ #\(b)"
        case .pointOnLine(let p, _, let l): return "#\(p) on line #\(l)"
        case .pointOnCircle(let p, _, let c): return "#\(p) on circle #\(c)"
        case .fixedPoint(let e, _, let at): return "#\(e) at (\(mcFmt(at.x)), \(mcFmt(at.y)))"
        case .angleBetween(let a, let b, _): return "lines #\(a) ↔ #\(b)"
        case .tangentLineCircle(let l, let c): return "line #\(l) ↔ circle #\(c)"
        case .symmetric(let a, _, let b, _, let axis): return "#\(a) ↔ #\(b) over line #\(axis)"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(constraint.displayName)
                    .mcFont(19, weight: .semibold)
                Text(detail)
                    .mcFont(16)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if hasValue {
                TextField("Value", text: $text)
                    .keyboardType(.numbersAndPunctuation)
                    .multilineTextAlignment(.trailing)
                    .mcFont(20, weight: .bold)
                    .frame(width: 100)
                    .textFieldStyle(.roundedBorder)
                Button("Apply") {
                    if let v = Double(text) { onApplyValue(v) }
                }
                .mcFont(19, weight: .bold)
            }
            Button(role: .destructive) {
                onDelete()
            } label: {
                Image(systemName: "trash")
                    .mcFont(19)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 5)
        .onChange(of: constraint) { _, newValue in
            text = Self.value(of: newValue).map(mcFmt) ?? ""
        }
    }
}
