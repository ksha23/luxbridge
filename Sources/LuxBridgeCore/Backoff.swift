import Foundation

/// Exponential retry delay: base, 2 x base, 4 x base, ... up to cap.
public struct Backoff: Sendable {
    public let base: TimeInterval
    public let cap: TimeInterval
    public private(set) var failures = 0

    public init(base: TimeInterval, cap: TimeInterval) {
        self.base = base
        self.cap = cap
    }

    public mutating func nextDelay() -> TimeInterval {
        failures += 1
        return min(cap, base * pow(2, Double(failures - 1)))
    }

    public mutating func reset() {
        failures = 0
    }
}
