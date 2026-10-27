import Foundation

public struct Vec2: Equatable, Codable, Hashable {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    public static let zero = Vec2(0, 0)
    public static func + (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x + b.x, a.y + b.y) }
    public static func - (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x - b.x, a.y - b.y) }
    public static func * (a: Vec2, s: Double) -> Vec2 { Vec2(a.x * s, a.y * s) }
    public var length: Double { (x * x + y * y).squareRoot() }
    public var lengthSquared: Double { x * x + y * y }
    public func distance(to o: Vec2) -> Double { (self - o).length }
    public func dot(_ o: Vec2) -> Double { x * o.x + y * o.y }
    public func cross(_ o: Vec2) -> Double { x * o.y - y * o.x }
    public var normalized: Vec2 { let l = length; return l > 0 ? self * (1 / l) : .zero }
    public var perpendicular: Vec2 { Vec2(-y, x) }
    public func isFinite() -> Bool { x.isFinite && y.isFinite }
}

public struct Vec3: Equatable, Codable, Hashable {
    public var x: Double
    public var y: Double
    public var z: Double
    public init(_ x: Double, _ y: Double, _ z: Double) { self.x = x; self.y = y; self.z = z }
    public static let zero = Vec3(0, 0, 0)
    public static func + (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x + b.x, a.y + b.y, a.z + b.z) }
    public static func - (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x - b.x, a.y - b.y, a.z - b.z) }
    public static func * (a: Vec3, s: Double) -> Vec3 { Vec3(a.x * s, a.y * s, a.z * s) }
    public var length: Double { (x * x + y * y + z * z).squareRoot() }
    public func dot(_ o: Vec3) -> Double { x * o.x + y * o.y + z * o.z }
    public func cross(_ o: Vec3) -> Vec3 {
        Vec3(y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x)
    }
    public var normalized: Vec3 { let l = length; return l > 0 ? self * (1 / l) : .zero }
    public func distance(to o: Vec3) -> Double { (self - o).length }
    public func isFinite() -> Bool { x.isFinite && y.isFinite && z.isFinite }
}

public struct BoundingBox: Equatable, Codable {
    public var min: Vec3
    public var max: Vec3
    public init(min: Vec3, max: Vec3) { self.min = min; self.max = max }
    public static let empty = BoundingBox(min: Vec3(.infinity, .infinity, .infinity),
                                          max: Vec3(-.infinity, -.infinity, -.infinity))
    public var isEmpty: Bool { min.x > max.x }
    public mutating func include(_ p: Vec3) {
        min = Vec3(Swift.min(min.x, p.x), Swift.min(min.y, p.y), Swift.min(min.z, p.z))
        max = Vec3(Swift.max(max.x, p.x), Swift.max(max.y, p.y), Swift.max(max.z, p.z))
    }
    public var size: Vec3 { isEmpty ? .zero : max - min }
    public var center: Vec3 { isEmpty ? .zero : (min + max) * 0.5 }
    public var volume: Double { let s = size; return s.x * s.y * s.z }
}

/// A sketch plane in 3D space. Sketch (u,v) maps to origin + u*xAxis + v*yAxis.
public struct Plane3: Equatable, Codable {
    public var origin: Vec3
    public var xAxis: Vec3
    public var yAxis: Vec3
    public init(origin: Vec3, xAxis: Vec3, yAxis: Vec3) {
        self.origin = origin; self.xAxis = xAxis.normalized; self.yAxis = yAxis.normalized
    }
    public var normal: Vec3 { xAxis.cross(yAxis).normalized }
    public func toWorld(_ p: Vec2) -> Vec3 { origin + xAxis * p.x + yAxis * p.y }
    public static let xy = Plane3(origin: .zero, xAxis: Vec3(1, 0, 0), yAxis: Vec3(0, 1, 0))
    public static let xz = Plane3(origin: .zero, xAxis: Vec3(1, 0, 0), yAxis: Vec3(0, 0, 1))
    public static let yz = Plane3(origin: .zero, xAxis: Vec3(0, 1, 0), yAxis: Vec3(0, 0, 1))
}

/// Segment intersection test (proper crossing, not just touching).
public func segmentsCross(_ a: Vec2, _ b: Vec2, _ c: Vec2, _ d: Vec2) -> Vec2? {
    let r = b - a, s = d - c
    let denom = r.cross(s)
    if abs(denom) < 1e-12 { return nil }
    let t = (c - a).cross(s) / denom
    let u = (c - a).cross(r) / denom
    if t > 1e-9 && t < 1 - 1e-9 && u > 1e-9 && u < 1 - 1e-9 {
        return a + r * t
    }
    return nil
}
