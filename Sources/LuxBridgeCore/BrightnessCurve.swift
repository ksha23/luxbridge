import Foundation

/// One point on a curve: at `lux` of room light the display should be at `brightness` percent.
public struct CurvePoint: Codable, Hashable, Sendable {
    public var lux: Double
    public var brightness: Double

    public init(lux: Double, brightness: Double) {
        self.lux = lux
        self.brightness = brightness
    }
}

/// Maps room light to display brightness.
///
/// Between points the curve is linear in log(lux): a room that gets twice as bright looks about
/// one step brighter whether it went from 5 to 10 lux or from 500 to 1000. Below the first point
/// and above the last the curve is flat.
public struct BrightnessCurve: Codable, Hashable, Sendable {
    /// Sorted by lux, all lux positive, brightness within 0...100.
    public let points: [CurvePoint]

    public init(points: [CurvePoint]) {
        self.points = Self.normalized(points)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(points: try container.decode([CurvePoint].self, forKey: .points))
    }

    public static let standard = BrightnessCurve(points: [
        CurvePoint(lux: 5, brightness: 10),
        CurvePoint(lux: 100, brightness: 40),
        CurvePoint(lux: 1000, brightness: 80),
        CurvePoint(lux: 5000, brightness: 100),
    ])

    public func brightness(forLux lux: Double) -> Double {
        guard let first = points.first, let last = points.last else { return 50 }
        if lux <= first.lux { return first.brightness }
        if lux >= last.lux { return last.brightness }
        for (low, high) in zip(points, points.dropFirst()) where lux <= high.lux {
            let t = (log(lux) - log(low.lux)) / (log(high.lux) - log(low.lux))
            return low.brightness + t * (high.brightness - low.brightness)
        }
        return last.brightness
    }

    /// Returns the curve with `point` added. Points within 20% of its lux are replaced, and the
    /// curve is kept rising: points at lower lux are capped at the new brightness and points at
    /// higher lux are raised to it, so a brighter room never gets a dimmer screen.
    public func setting(_ point: CurvePoint) -> BrightnessCurve {
        guard point.lux.isFinite, point.lux > 0, point.brightness.isFinite else { return self }
        let brightness = Self.clampPercent(point.brightness)
        let others = points
            .filter { abs(log($0.lux / point.lux)) > log(1.2) }
            .map { other in
                CurvePoint(lux: other.lux, brightness: other.lux < point.lux
                    ? min(other.brightness, brightness)
                    : max(other.brightness, brightness))
            }
        return BrightnessCurve(points: others + [CurvePoint(lux: point.lux, brightness: brightness)])
    }

    /// Returns the curve with every brightness multiplied by `factor`, to make it dimmer or brighter
    /// everywhere while keeping its shape.
    public func scaled(by factor: Double) -> BrightnessCurve {
        guard factor.isFinite, factor > 0 else { return self }
        return BrightnessCurve(points: points.map { CurvePoint(lux: $0.lux, brightness: ($0.brightness * factor * 10).rounded() / 10) })
    }

    static func normalized(_ points: [CurvePoint]) -> [CurvePoint] {
        var brightnessByLux: [Double: Double] = [:]
        for point in points where point.lux.isFinite && point.lux > 0 && point.brightness.isFinite {
            brightnessByLux[point.lux] = clampPercent(point.brightness)
        }
        return brightnessByLux.keys.sorted().map { CurvePoint(lux: $0, brightness: brightnessByLux[$0]!) }
    }

    static func clampPercent(_ value: Double) -> Double {
        min(max(value, 0), 100)
    }
}
