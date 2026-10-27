import Foundation

/// Severity of a CAD failure. Mirrors ERRORS.md.
public enum CADSeverity: String, Codable {
    case warning = "W"
    case error = "E"
    case fatal = "F"
}

/// Every distinct failure in MetalCAD. The `code` is stable forever:
/// never reused, never renumbered (see ERRORS.md).
public enum CADError: Error, Equatable {
    // GN — general
    case unknown(String)
    case outOfMemory
    case cancelledByUser
    case notImplementedYet(String)
    case invariantBroken(String)
    // DC — document
    case documentNotFound(String)
    case documentCorruptJSON(String)
    case documentVersionTooNew(found: Int, supported: Int)
    case documentVersionTooOld(found: Int)
    case duplicateName(String)
    case nameNotFound(String)
    case featureRebuildFailed(feature: String, underlyingCode: String)
    case circularDependency([String])
    case parameterOutOfRange(name: String, value: Double, clamped: Double)
    case snapshotWriteFailed(String)
    case equationParseError(String, position: Int)
    case equationEvalError(String)
    // SK — sketch
    case sketchPlaneLost(sketch: String)
    case entityNotFound(Int)
    case degenerateEntity(Int)
    case profileOpen(gapA: Vec2, gapB: Vec2)
    case profileSelfIntersecting(at: Vec2)
    case profileNestedTooDeep(Int)
    case duplicateEntity(Int)
    case splineTooFewPoints(Int)
    case arcInvalidGeometry
    case projectionSourceGone(entity: Int)
    case sketchEmpty
    // SV — solver
    case solverDidNotConverge(residual: Double, iterations: Int)
    case conflictingConstraints([String])
    case redundantConstraint(String)
    case overConstrained(dofBefore: Int, dofAfter: Int)
    case solverSingular
    case danglingConstraint(String)
    case solveTimeout
    // FT — features
    case padNoProfile
    case padLengthInvalid(Double)
    case revolveAxisMissing
    case revolveProfileCrossesAxis
    case booleanFailed(String)
    case booleanEmptyResult
    case filletFailed(String)
    case filletRadiusTooLarge(requested: Double, maxFeasible: Double)
    case chamferInvalid(String)
    case shellFailed(String)
    case patternCountInvalid(Int)
    case transformInvalid(String)
    case primitiveParamInvalid(String)
    case sweepPathInvalid(String)
    case loftProfileMismatch
    case holeSpecInvalid(String)
    case directEditHealFailed
    // TH — threads
    case threadPitchInvalid(Double)
    case threadDiameterInvalid(major: Double, minor: Double)
    case threadProfileInvalid(String)
    case threadStartsInvalid(Int)
    case threadTooLong(requested: Double, clamped: Double)
    case threadSweepFailed(String)
    case threadTaperInvalid(Double)
    case threadFitOutOfRange(clamped: Double)
    case threadPresetUnknown(String)
    // KN — kernel
    case kernelUnavailable
    case kernelOperationFailed(String)
    case kernelShapeInvalid(String)
    case kernelTessellationFailed(String)
    case kernelTimeout
    // IO
    case importFormatUnsupported(String)
    case importFileUnreadable(String)
    case importGeometryInvalid(String)
    case exportNotWatertight(openEdges: Int)
    case exportWriteFailed(String)
    case stepWriteFailed(String)
    case meshTooLarge(triangles: Int, budget: Int)

    public var code: String {
        switch self {
        case .unknown: return "MCAD-GN001"
        case .outOfMemory: return "MCAD-GN002"
        case .cancelledByUser: return "MCAD-GN003"
        case .notImplementedYet: return "MCAD-GN004"
        case .invariantBroken: return "MCAD-GN005"
        case .documentNotFound: return "MCAD-DC101"
        case .documentCorruptJSON: return "MCAD-DC102"
        case .documentVersionTooNew: return "MCAD-DC103"
        case .documentVersionTooOld: return "MCAD-DC104"
        case .duplicateName: return "MCAD-DC105"
        case .nameNotFound: return "MCAD-DC106"
        case .featureRebuildFailed: return "MCAD-DC107"
        case .circularDependency: return "MCAD-DC108"
        case .parameterOutOfRange: return "MCAD-DC109"
        case .snapshotWriteFailed: return "MCAD-DC110"
        case .equationParseError: return "MCAD-DC111"
        case .equationEvalError: return "MCAD-DC112"
        case .sketchPlaneLost: return "MCAD-SK201"
        case .entityNotFound: return "MCAD-SK202"
        case .degenerateEntity: return "MCAD-SK203"
        case .profileOpen: return "MCAD-SK204"
        case .profileSelfIntersecting: return "MCAD-SK205"
        case .profileNestedTooDeep: return "MCAD-SK206"
        case .duplicateEntity: return "MCAD-SK207"
        case .splineTooFewPoints: return "MCAD-SK208"
        case .arcInvalidGeometry: return "MCAD-SK209"
        case .projectionSourceGone: return "MCAD-SK211"
        case .sketchEmpty: return "MCAD-SK212"
        case .solverDidNotConverge: return "MCAD-SV301"
        case .conflictingConstraints: return "MCAD-SV302"
        case .redundantConstraint: return "MCAD-SV303"
        case .overConstrained: return "MCAD-SV304"
        case .solverSingular: return "MCAD-SV305"
        case .danglingConstraint: return "MCAD-SV306"
        case .solveTimeout: return "MCAD-SV307"
        case .padNoProfile: return "MCAD-FT401"
        case .padLengthInvalid: return "MCAD-FT402"
        case .revolveAxisMissing: return "MCAD-FT403"
        case .revolveProfileCrossesAxis: return "MCAD-FT404"
        case .booleanFailed: return "MCAD-FT405"
        case .booleanEmptyResult: return "MCAD-FT406"
        case .filletFailed: return "MCAD-FT407"
        case .filletRadiusTooLarge: return "MCAD-FT408"
        case .chamferInvalid: return "MCAD-FT409"
        case .shellFailed: return "MCAD-FT410"
        case .patternCountInvalid: return "MCAD-FT411"
        case .transformInvalid: return "MCAD-FT412"
        case .primitiveParamInvalid: return "MCAD-FT413"
        case .sweepPathInvalid: return "MCAD-FT414"
        case .loftProfileMismatch: return "MCAD-FT415"
        case .holeSpecInvalid: return "MCAD-FT416"
        case .directEditHealFailed: return "MCAD-FT417"
        case .threadPitchInvalid: return "MCAD-TH501"
        case .threadDiameterInvalid: return "MCAD-TH502"
        case .threadProfileInvalid: return "MCAD-TH503"
        case .threadStartsInvalid: return "MCAD-TH504"
        case .threadTooLong: return "MCAD-TH505"
        case .threadSweepFailed: return "MCAD-TH506"
        case .threadTaperInvalid: return "MCAD-TH507"
        case .threadFitOutOfRange: return "MCAD-TH508"
        case .threadPresetUnknown: return "MCAD-TH509"
        case .kernelUnavailable: return "MCAD-KN601"
        case .kernelOperationFailed: return "MCAD-KN602"
        case .kernelShapeInvalid: return "MCAD-KN603"
        case .kernelTessellationFailed: return "MCAD-KN604"
        case .kernelTimeout: return "MCAD-KN605"
        case .importFormatUnsupported: return "MCAD-IO701"
        case .importFileUnreadable: return "MCAD-IO702"
        case .importGeometryInvalid: return "MCAD-IO703"
        case .exportNotWatertight: return "MCAD-IO704"
        case .exportWriteFailed: return "MCAD-IO705"
        case .stepWriteFailed: return "MCAD-IO706"
        case .meshTooLarge: return "MCAD-IO707"
        }
    }

    public var severity: CADSeverity {
        switch self {
        case .outOfMemory, .invariantBroken: return .fatal
        case .cancelledByUser, .documentVersionTooOld, .duplicateName,
             .parameterOutOfRange, .degenerateEntity, .profileNestedTooDeep,
             .duplicateEntity, .projectionSourceGone, .redundantConstraint,
             .solveTimeout, .filletRadiusTooLarge, .threadTooLong,
             .threadFitOutOfRange, .threadPresetUnknown,
             .importGeometryInvalid, .exportNotWatertight, .meshTooLarge,
             .loftProfileMismatch, .notImplementedYet:
            return .warning
        default: return .error
        }
    }

    /// Plain-words message for the user. The code is shown separately.
    public var userMessage: String {
        switch self {
        case .unknown(let d): return "Something went wrong. (\(d))"
        case .outOfMemory: return "The iPad ran out of memory during a rebuild. Your last good model is safe."
        case .cancelledByUser: return "Cancelled. Nothing was changed."
        case .notImplementedYet(let f): return "\(f) isn't built yet — it's planned for a later phase."
        case .invariantBroken(let d): return "An internal check failed (\(d)). Your document was snapshotted first."
        case .documentNotFound(let n): return "Couldn't find the document \"\(n)\"."
        case .documentCorruptJSON: return "This document file is damaged and can't be opened. The latest snapshot is available instead."
        case .documentVersionTooNew(let f, let s): return "This document was made by a newer MetalCAD (format \(f)); this app supports up to \(s)."
        case .documentVersionTooOld: return "This document was upgraded to the current format. A copy of the original was kept."
        case .duplicateName(let n): return "\"\(n)\" already exists, so the new one was renamed."
        case .nameNotFound(let n): return "Couldn't find \"\(n)\"."
        case .featureRebuildFailed(let f, _): return "Feature \"\(f)\" failed to rebuild. Everything after it is paused."
        case .circularDependency(let names): return "These depend on each other in a loop: \(names.joined(separator: ", "))."
        case .parameterOutOfRange(let n, _, _): return "\(n) was outside its allowed range and was adjusted."
        case .snapshotWriteFailed: return "Autosave couldn't write — storage may be full. Export your document now to keep it safe."
        case .equationParseError(let e, let p): return "Formula problem at character \(p) in \"\(e)\"."
        case .equationEvalError(let e): return "Formula \"\(e)\" couldn't be calculated (check for divide-by-zero or an unknown name)."
        case .sketchPlaneLost(let s): return "Sketch \"\(s)\" lost the face or plane it was drawn on."
        case .entityNotFound: return "That sketch item no longer exists."
        case .degenerateEntity: return "A sketch item became zero-size. It's flagged in the sketch health check."
        case .profileOpen: return "The outline isn't closed, so it can't make a solid. The gap is marked."
        case .profileSelfIntersecting: return "The outline crosses itself. Fix the crossing to continue."
        case .profileNestedTooDeep: return "Too many nested outline islands; the profile was simplified."
        case .duplicateEntity: return "Two sketch items exactly overlap."
        case .splineTooFewPoints(let n): return "A spline needs more points (has \(n))."
        case .arcInvalidGeometry: return "Those three points are in a straight line — no arc fits them."
        case .projectionSourceGone: return "A projected item lost its source and was frozen as construction geometry."
        case .sketchEmpty: return "The sketch is empty."
        case .solverDidNotConverge: return "The sketch couldn't settle into a solution. The last good shape was kept."
        case .conflictingConstraints(let names): return "Constraints fight each other: \(names.joined(separator: ", "))."
        case .redundantConstraint(let n): return "\"\(n)\" is already implied by other constraints."
        case .overConstrained: return "That would over-define the sketch, so it wasn't added."
        case .solverSingular: return "The sketch hit a shape the solver can't pass through. The last good shape was kept."
        case .danglingConstraint(let n): return "Constraint \"\(n)\" points at something that was deleted. It was set aside."
        case .solveTimeout: return "Solving took too long on this big sketch."
        case .padNoProfile: return "Pad needs a closed outline in its sketch."
        case .padLengthInvalid: return "Pad length must be more than zero."
        case .revolveAxisMissing: return "Pick an axis to revolve around."
        case .revolveProfileCrossesAxis: return "The outline crosses the revolve axis, which would fold the solid into itself."
        case .booleanFailed(let d): return "The combine operation failed (\(d)). Both shapes are unchanged."
        case .booleanEmptyResult: return "That operation would leave nothing behind."
        case .filletFailed(let d): return "Couldn't round those edges (\(d)). A smaller radius may work."
        case .filletRadiusTooLarge(let r, let m): return "Radius \(String(format: "%.2f", r)) is too big here; the largest that fits is \(String(format: "%.2f", m))."
        case .chamferInvalid(let d): return "That chamfer doesn't fit (\(d))."
        case .shellFailed(let d): return "Couldn't hollow this shape (\(d))."
        case .patternCountInvalid: return "A pattern needs at least 1 copy and non-zero spacing."
        case .transformInvalid(let d): return "That move isn't valid (\(d))."
        case .primitiveParamInvalid(let d): return "Invalid shape setting (\(d))."
        case .sweepPathInvalid(let d): return "The sweep path isn't usable (\(d))."
        case .loftProfileMismatch: return "The two outlines are very different shapes; the loft will be straight-ruled."
        case .holeSpecInvalid(let d): return "That hole doesn't fit (\(d))."
        case .directEditHealFailed: return "Deleting that face left a gap that couldn't be closed."
        case .threadPitchInvalid: return "Thread pitch must be more than zero and smaller than the diameter."
        case .threadDiameterInvalid: return "Thread major diameter must be bigger than the minor diameter."
        case .threadProfileInvalid(let d): return "Thread profile problem (\(d))."
        case .threadStartsInvalid(let n): return "Thread starts must be 1 to 4 (got \(n))."
        case .threadTooLong: return "The thread was longer than its shaft and was shortened."
        case .threadSweepFailed(let d): return "The thread ridge folded into itself (\(d)). Try a coarser pitch."
        case .threadTaperInvalid: return "That taper would make the thread disappear before its end."
        case .threadFitOutOfRange: return "Thread fit was adjusted so the pair can't collide."
        case .threadPresetUnknown(let n): return "No preset named \"\(n)\". Parameters were left as they are."
        case .kernelUnavailable: return "The geometry engine isn't available in this build."
        case .kernelOperationFailed(let d): return "The geometry engine refused that operation (\(d))."
        case .kernelShapeInvalid(let d): return "The engine produced an invalid shape (\(d)). The previous solid is kept."
        case .kernelTessellationFailed: return "Couldn't turn that solid into a displayable mesh."
        case .kernelTimeout: return "The geometry engine took too long and was stopped. Nothing changed."
        case .importFormatUnsupported(let f): return "MetalCAD can't import .\(f) files."
        case .importFileUnreadable(let d): return "Couldn't read that file (\(d))."
        case .importGeometryInvalid(let d): return "Imported with defects (\(d)). Repair is available."
        case .exportNotWatertight(let n): return "Exported, but the mesh has \(n) open edges — it isn't fully watertight. Check it in your slicer."
        case .exportWriteFailed(let d): return "Export failed (\(d))."
        case .stepWriteFailed(let d): return "STEP export failed (\(d))."
        case .meshTooLarge(let t, let b): return "The mesh has \(t) triangles, over the \(b) budget; detail was coarsened once."
        }
    }
}

/// All codes that exist — used by the test suite to prove distinctness.
public enum CADErrorCatalog {
    public static let allCodes: [String] = [
        "MCAD-GN001","MCAD-GN002","MCAD-GN003","MCAD-GN004","MCAD-GN005",
        "MCAD-DC101","MCAD-DC102","MCAD-DC103","MCAD-DC104","MCAD-DC105",
        "MCAD-DC106","MCAD-DC107","MCAD-DC108","MCAD-DC109","MCAD-DC110",
        "MCAD-DC111","MCAD-DC112",
        "MCAD-SK201","MCAD-SK202","MCAD-SK203","MCAD-SK204","MCAD-SK205",
        "MCAD-SK206","MCAD-SK207","MCAD-SK208","MCAD-SK209","MCAD-SK211","MCAD-SK212",
        "MCAD-SV301","MCAD-SV302","MCAD-SV303","MCAD-SV304","MCAD-SV305","MCAD-SV306","MCAD-SV307",
        "MCAD-FT401","MCAD-FT402","MCAD-FT403","MCAD-FT404","MCAD-FT405","MCAD-FT406",
        "MCAD-FT407","MCAD-FT408","MCAD-FT409","MCAD-FT410","MCAD-FT411","MCAD-FT412",
        "MCAD-FT413","MCAD-FT414","MCAD-FT415","MCAD-FT416","MCAD-FT417",
        "MCAD-TH501","MCAD-TH502","MCAD-TH503","MCAD-TH504","MCAD-TH505",
        "MCAD-TH506","MCAD-TH507","MCAD-TH508","MCAD-TH509",
        "MCAD-KN601","MCAD-KN602","MCAD-KN603","MCAD-KN604","MCAD-KN605",
        "MCAD-IO701","MCAD-IO702","MCAD-IO703","MCAD-IO704","MCAD-IO705","MCAD-IO706","MCAD-IO707",
    ]
}
