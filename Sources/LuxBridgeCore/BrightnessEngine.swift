import Foundation

/// How readily the brightness follows the light. A sensor's lux wobbles all the time (an Aqara FP2
/// steps by 4 lux, a laptop sensor by 1, shadows and clouds come and go), so the brightness only
/// moves once a change in the light has lasted. Changes smaller than `ratio` are ignored. A change
/// of exactly `ratio` has to last `dwell` seconds; the wait shrinks with the size of the change,
/// down to `bigDwell` at `bigRatio` and beyond (a lamp switched on or off).
public struct Stability: Equatable, Sendable {
    public var ratio: Double
    public var dwell: TimeInterval
    public var bigRatio: Double
    public var bigDwell: TimeInterval = 3

    public init(ratio: Double, dwell: TimeInterval, bigRatio: Double = 2) {
        self.ratio = ratio
        self.dwell = dwell
        self.bigRatio = bigRatio
    }

    /// The wait for a change by `ratio` (above 1): geometric between `dwell` at `self.ratio` and
    /// `bigDwell` at `bigRatio`. At Normal, 1.3x waits 60 s, 1.5x about 22 s, 1.9x about 4 s.
    public func dwell(forRatio change: Double) -> TimeInterval {
        guard bigRatio > ratio, dwell > 0 else { return change > bigRatio ? bigDwell : dwell }
        let fraction = min(max((log(change) - log(ratio)) / (log(bigRatio) - log(ratio)), 0), 1)
        return dwell * pow(bigDwell / dwell, fraction)
    }

    /// Follows every reading at once.
    public static let none: Stability = {
        var stability = Stability(ratio: 1, dwell: 0)
        stability.bigDwell = 0
        return stability
    }()
}

/// Decides the brightness of one display from its light sources.
///
/// It does no I/O and owns no timers. The app reports what happened (the display appeared, a
/// source produced a reading or went away, a read-back of the display's brightness) and calls
/// `nextWrite(at:)` on every tick to get the next brightness to send, if any. The first source in
/// priority order with a fresh reading drives the display. With none, nothing is written and the
/// display keeps whatever brightness it has. A manual change turns automatic control off until it
/// is turned back on.
public final class BrightnessEngine {
    public struct Source: Equatable, Sendable {
        public var id: UUID
        /// Multiplies the source's lux, so that sources placed differently (a window sill, a laptop
        /// bezel) can share one curve.
        public var gain: Double
        /// A reading older than this is not acted on, and the next source in line takes over.
        public var staleAfter: TimeInterval

        public init(id: UUID, gain: Double = 1, staleAfter: TimeInterval = 60) {
            self.id = id
            self.gain = gain
            self.staleAfter = staleAfter
        }
    }

    public struct Settings: Equatable, Sendable {
        public var curve: BrightnessCurve
        /// Enabled sources in priority order.
        public var sources: [Source]
        public var stability: Stability
        /// Smoothing time constant for lux, in seconds.
        public var responseSeconds: TimeInterval
        /// Target changes smaller than this many percent are ignored.
        public var deadband = 2
        /// Automatic changes fade over `transitionSecondsPerPoint` per percent changed, kept within
        /// `minTransition...maxTransition`, eased in and out, one percent at a time.
        public var transitionSecondsPerPoint = 0.25
        public var minTransition: TimeInterval = 1.5
        public var maxTransition: TimeInterval = 5
        /// A read-back further than this from the known brightness counts as a manual change.
        public var readbackTolerance = 2
        /// Read-backs this soon after a write are ignored, since some displays report late.
        public var readbackGrace: TimeInterval = 3

        public init(
            curve: BrightnessCurve,
            sources: [Source],
            stability: Stability,
            responseSeconds: TimeInterval = 3
        ) {
            self.curve = curve
            self.sources = sources
            self.stability = stability
            self.responseSeconds = responseSeconds
        }
    }

    public enum Phase: Equatable, Sendable {
        case noDisplay
        case displayAsleep
        case disabled
        case waitingForSensor
        case following
    }

    /// What a source currently says: smoothed lux with and without its gain, or a percentage to
    /// use as the brightness.
    public struct Reading: Equatable, Sendable {
        public var source: UUID
        public var lux: Double?
        public var rawLux: Double?
        /// The latest reading with gain, before smoothing.
        public var latestLux: Double?
        public var percent: Double?
    }

    public var settings: Settings {
        didSet {
            let ids = Set(settings.sources.map(\.id))
            sourceStates = sourceStates.filter { ids.contains($0.key) }
            for id in sourceStates.keys { sourceStates[id]?.filter.timeConstant = settings.responseSeconds }
        }
    }
    /// Automatic control. A manual change turns it off; turning it back on aims at the curve's
    /// value for the light right now.
    public var enabled = true {
        didSet {
            guard enabled != oldValue else { return }
            transition = nil
            if enabled {
                changedByHand = false
                resetSettled()
            }
        }
    }
    /// The brightness was changed by hand since automatic control was last on.
    public private(set) var changedByHand = false

    public private(set) var displayConnected = false
    public private(set) var displayAsleep = false
    /// The display's brightness in percent, as last written or read. nil until known.
    public private(set) var brightness: Int?

    private struct SourceState {
        var filter: LuxFilter
        var percent: Double?
        var time: Date
    }

    private var sourceStates: [UUID: SourceState] = [:]
    /// log1p of the lux the target is based on; see `Stability`.
    private var settledLevel: Double?
    private var pendingChange: (direction: Int, since: Date)?
    private var lastSettleTime: Date?
    /// A fade in progress from one brightness to another.
    private struct Transition {
        var from: Int
        var to: Int
        var start: Date
        var duration: TimeInterval
    }

    private var transition: Transition?
    private var pendingManual: Int?
    private var lastWriteTime: Date?

    public init(settings: Settings) {
        self.settings = settings
    }

    /// True while a fade or a manual change is being written.
    public var isAdjusting: Bool { transition != nil || pendingManual != nil }

    public func phase(at now: Date) -> Phase {
        if !displayConnected { return .noDisplay }
        if displayAsleep { return .displayAsleep }
        if !enabled { return .disabled }
        if activeReading(at: now) == nil { return .waitingForSensor }
        return .following
    }

    /// The reading of the first source, in priority order, that is fresh.
    public func activeReading(at now: Date) -> Reading? {
        settings.sources.lazy.compactMap { self.reading(of: $0, at: now) }.first
    }

    /// The reading of one source, or nil if it has none or it is stale.
    public func reading(of sourceID: UUID, at now: Date) -> Reading? {
        settings.sources.first { $0.id == sourceID }.flatMap { reading(of: $0, at: now) }
    }

    public func target(at now: Date) -> Int? {
        guard let reading = activeReading(at: now) else { return nil }
        if let percent = reading.percent { return Self.percent(percent) }
        guard let lux = settledLux(for: reading, at: now) else { return nil }
        return Self.percent(settings.curve.brightness(forLux: lux))
    }

    /// The lux the target is based on. It moves to the current reading only when the light has
    /// clearly changed (see `Stability`), so wobble in the readings leaves the brightness alone.
    private func settledLux(for reading: Reading, at now: Date) -> Double? {
        guard let lux = reading.lux else { return nil }
        // Asked about an earlier moment (the UI lags the tick slightly): report, don't advance.
        if let lastSettleTime, now < lastSettleTime { return settledLevel.map(expm1) }
        lastSettleTime = now
        let level = log1p(lux)
        // A fresh start (first reading, reconnect, turned back on) aims at the light right now.
        guard let settled = settledLevel else {
            let latest = reading.latestLux ?? lux
            settledLevel = log1p(latest)
            return latest
        }
        let difference = level - settled
        let stability = settings.stability
        guard abs(difference) > log(stability.ratio) else {
            pendingChange = nil
            return expm1(settled)
        }
        let direction = difference > 0 ? 1 : -1
        if pendingChange?.direction != direction { pendingChange = (direction, now) }
        let big = abs(difference) > log(stability.bigRatio)
        guard let since = pendingChange?.since, now.timeIntervalSince(since) >= stability.dwell(forRatio: exp(abs(difference))) else {
            return expm1(settled)
        }
        // After a big change the smoothed value is still catching up, so settle on the latest reading.
        settledLevel = big ? log1p(reading.latestLux ?? lux) : level
        pendingChange = nil
        return expm1(settledLevel ?? level)
    }

    // MARK: Events

    /// The display is reachable. `brightness` is a fresh read, or nil if the read failed.
    /// This sets a new baseline, so a display that restored its own brightness after waking
    /// is not mistaken for a manual change.
    public func displayAppeared(brightness: Int?) {
        displayConnected = true
        self.brightness = brightness
        transition = nil
        lastWriteTime = nil
        resetSettled()
    }

    public func displayDisappeared() {
        displayConnected = false
        brightness = nil
        transition = nil
        pendingManual = nil
    }

    public func setDisplayAsleep(_ asleep: Bool) {
        displayAsleep = asleep
        transition = nil
    }

    /// A reading from a source. A unit of "%" means the value is the brightness itself.
    public func sourceValue(_ value: Double, unit: String?, source: UUID, at now: Date) {
        var state = sourceStates[source]
            ?? SourceState(filter: LuxFilter(timeConstant: settings.responseSeconds), percent: nil, time: now)
        state.time = now
        if unit == "%" {
            state.percent = value
            state.filter.reset()
        } else {
            state.percent = nil
            state.filter.add(value, at: now)
        }
        sourceStates[source] = state
    }

    /// The source is known to be unusable right now (the lid closed, the entity disappeared),
    /// so the next one takes over at once instead of after `staleAfter`.
    public func sourceLost(_ source: UUID) {
        sourceStates[source] = nil
    }

    /// A brightness read back from the display. A value that moved since the last write means
    /// someone changed it (the monitor's own buttons, another app), so automatic control turns off.
    public func observed(_ value: Int, at now: Date) {
        if let lastWriteTime, now.timeIntervalSince(lastWriteTime) < settings.readbackGrace { return }
        if isAdjusting { return }
        if let known = brightness, abs(value - known) > settings.readbackTolerance { manualChange() }
        brightness = value
    }

    /// The user picked a brightness in LuxBridge itself. It is written next, and automatic
    /// control turns off.
    public func userSet(_ value: Int, at now: Date) {
        pendingManual = Self.percent(Double(value))
        manualChange()
    }

    // MARK: Writing

    /// The brightness to send now, if any. Automatic changes fade (see `Settings`); a brightness
    /// the user picked is sent at once.
    public func nextWrite(at now: Date) -> Int? {
        guard displayConnected, !displayAsleep else { return nil }
        if let pendingManual { return pendingManual }
        guard enabled, let goal = target(at: now) else {
            transition = nil
            return nil
        }
        guard let current = brightness else { return goal }
        if transition?.to != goal {
            // A new goal, or a different one mid-fade: fade from where the display is now.
            guard goal != current, transition != nil || abs(goal - current) >= settings.deadband else {
                transition = nil
                return nil
            }
            let duration = Double(abs(goal - current)) * settings.transitionSecondsPerPoint
            transition = Transition(
                from: current, to: goal, start: now,
                duration: min(max(duration, settings.minTransition), settings.maxTransition)
            )
        }
        guard let transition else { return nil }
        let progress = min(max(now.timeIntervalSince(transition.start) / transition.duration, 0), 1)
        let eased = progress * progress * (3 - 2 * progress)
        let value = Int((Double(transition.from) + eased * Double(transition.to - transition.from)).rounded())
        guard value != current else {
            if current == transition.to { self.transition = nil }
            return nil
        }
        // One percent at a time, so a late tick never shows as a jump.
        return current + (value > current ? 1 : -1)
    }

    public func didWrite(_ value: Int, at now: Date) {
        brightness = value
        lastWriteTime = now
        if pendingManual == value { pendingManual = nil }
        if transition?.to == value { transition = nil }
    }

    /// Drops a manual change that could not be written, so a failing display is not retried forever.
    public func dropPendingManual() {
        pendingManual = nil
    }

    // MARK: Private

    private func reading(of source: Source, at now: Date) -> Reading? {
        guard let state = sourceStates[source.id], now.timeIntervalSince(state.time) < source.staleAfter else {
            return nil
        }
        if let percent = state.percent {
            return Reading(source: source.id, lux: nil, rawLux: nil, latestLux: nil, percent: percent)
        }
        // The filter works on raw lux, so a gain change applies at once.
        guard let raw = state.filter.value(at: now) else { return nil }
        let gain = max(source.gain, 0)
        return Reading(source: source.id, lux: raw * gain, rawLux: raw, latestLux: state.filter.latest.map { $0 * gain }, percent: nil)
    }

    private func resetSettled() {
        settledLevel = nil
        pendingChange = nil
        lastSettleTime = nil
    }

    private func manualChange() {
        enabled = false
        changedByHand = true
        transition = nil
    }

    static func percent(_ value: Double) -> Int {
        Int(min(max(value, 0), 100).rounded())
    }
}
