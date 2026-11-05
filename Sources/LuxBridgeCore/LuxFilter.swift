import Foundation

/// Smooths lux so brief changes (someone walking past the sensor, a passing cloud) barely move the
/// brightness, while a lamp switching on still shows up within seconds.
///
/// A sensor reading holds until the next one arrives, so the filter is a continuous first-order
/// lag of that held value, in log space, with time constant `timeConstant`. The output can be read
/// at any time and glides toward the latest reading between polls.
public struct LuxFilter: Sendable {
    public var timeConstant: TimeInterval
    /// log1p(lux) of the output at `levelTime`.
    private var level: Double?
    private var levelTime: Date?
    /// log1p(lux) of the latest reading.
    private var held: Double?

    public init(timeConstant: TimeInterval) {
        self.timeConstant = timeConstant
    }

    public mutating func add(_ lux: Double, at time: Date) {
        let input = log1p(max(lux, 0))
        // After a long gap (the display was unplugged, the Mac slept) the old value means nothing.
        guard let current = value(at: time), let levelTime,
              time.timeIntervalSince(levelTime) >= 0,
              time.timeIntervalSince(levelTime) < max(timeConstant * 10, 60)
        else {
            level = input
            levelTime = time
            held = input
            return
        }
        level = log1p(current)
        self.levelTime = time
        held = input
    }

    /// The latest reading, before smoothing.
    public var latest: Double? { held.map(expm1) }

    public func value(at time: Date) -> Double? {
        guard let level, let levelTime, let held else { return nil }
        guard timeConstant > 0 else { return expm1(held) }
        let elapsed = max(0, time.timeIntervalSince(levelTime))
        return expm1(held + (level - held) * exp(-elapsed / timeConstant))
    }

    public mutating func reset() {
        level = nil
        levelTime = nil
        held = nil
    }
}
