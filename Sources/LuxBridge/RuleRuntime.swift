import DDCKit
import Foundation
import LuxBridgeCore

/// Runs one rule: owns its engine, talks to its display over DDC on a private serial queue, and
/// publishes a snapshot for the UI. At most one DDC call is in flight at a time.
@MainActor
final class RuleRuntime: ObservableObject, Identifiable {
    struct Snapshot: Equatable {
        var phase = BrightnessEngine.Phase.noDisplay
        var brightness: Int?
        var target: Int?
        /// The source driving the display, and what it reads.
        var activeSource: UUID?
        var lux: Double?
        var sensorPercent: Double?
        /// Smoothed lux of every source with a fresh reading, before its gain.
        var rawLuxBySource: [UUID: Double] = [:]
        var adjusting = false
        /// The brightness was changed by hand since automatic control was last on.
        var changedByHand = false
    }

    let id: UUID
    @Published private(set) var rule: DisplayRule
    @Published private(set) var display: ExternalDisplay?
    @Published private(set) var snapshot = Snapshot()
    @Published private(set) var ddcProblem: String?

    /// Called when DDC keeps failing, so the model can rescan for a fresh service.
    var onDisplayTrouble: (() -> Void)?
    /// Called when a manual change turned automatic control off, so the model can save that.
    var onManualChange: (() -> Void)?

    private let engine: BrightnessEngine
    private let queue: DispatchQueue
    private var busy = false
    private var needsBaseline = false
    private var maximum = 100
    private var writeBackoff = Backoff(base: 1, cap: 30)
    private var nextWriteAt = Date.distantPast
    private var nextReadAt = Date.distantPast
    private var readFailures = 0

    private static let readInterval: TimeInterval = 15
    private static let slowReadInterval: TimeInterval = 120

    init(rule: DisplayRule) {
        id = rule.id
        self.rule = rule
        engine = BrightnessEngine(settings: Self.settings(for: rule))
        engine.enabled = rule.enabled
        queue = DispatchQueue(label: "LuxBridge.ddc.\(rule.id.uuidString)")
    }

    /// Readings are only needed while the display can be controlled.
    private var wantsReadings: Bool { display?.channel != nil }

    /// Home Assistant entities to poll right now.
    var wantedEntities: [String] { wantsReadings ? rule.entityIDs : [] }

    var wantsMacSensor: Bool { wantsReadings && rule.usesMacSensor }

    /// The active lux (after gain) and the brightness the display has now, for adding to the curve.
    var currentPoint: CurvePoint? {
        guard let lux = engine.activeReading(at: Date())?.lux, let brightness = engine.brightness else { return nil }
        return CurvePoint(lux: max(lux, 0.5), brightness: Double(brightness))
    }

    /// How much the whole curve would have to be scaled to give the display's current brightness at
    /// the current light: below 1 when the user turned it down.
    var curveMatchFactor: Double? {
        guard let brightness = engine.brightness, let target = engine.target(at: Date()), target > 0 else { return nil }
        return Double(brightness) / Double(target)
    }

    func update(_ newRule: DisplayRule) {
        // A source that now reads a different entity must not keep the old entity's readings.
        for source in newRule.sources {
            if let old = rule.sources.first(where: { $0.id == source.id }), old.entityID != source.entityID {
                engine.sourceLost(source.id)
            }
        }
        rule = newRule
        engine.settings = Self.settings(for: newRule)
        engine.enabled = newRule.enabled
        refreshSnapshot()
    }

    func attach(_ newDisplay: ExternalDisplay?) {
        guard newDisplay != display else { return }
        display = newDisplay
        ddcProblem = nil
        writeBackoff.reset()
        nextWriteAt = .distantPast
        readFailures = 0
        // Until the first read of the new display finishes, nothing is written.
        engine.displayDisappeared()
        needsBaseline = newDisplay?.channel != nil
        if newDisplay != nil, newDisplay?.channel == nil {
            ddcProblem = "macOS offers no DDC connection to this display"
        }
        refreshSnapshot()
    }

    func homeAssistantState(_ state: HAEntityState) {
        for source in rule.sources where source.enabled && source.kind == .homeAssistant && source.entityID == state.entityID {
            if let value = state.number {
                engine.sourceValue(value, unit: state.attributes.unit, source: source.id, at: Date())
            } else {
                // "unavailable" or "unknown": fall through to the next source at once.
                engine.sourceLost(source.id)
            }
        }
        refreshSnapshot()
    }

    func homeAssistantEntityMissing(_ entityID: String) {
        for source in rule.sources where source.kind == .homeAssistant && source.entityID == entityID {
            engine.sourceLost(source.id)
        }
        refreshSnapshot()
    }

    /// The Mac's light sensor, or nil when it can't be used (the lid is closed, no sensor).
    func macSensor(_ lux: Double?) {
        for source in rule.sources where source.enabled && source.kind == .macSensor {
            if let lux {
                engine.sourceValue(lux, unit: "lx", source: source.id, at: Date())
            } else {
                engine.sourceLost(source.id)
            }
        }
    }

    func setDisplayAsleep(_ asleep: Bool) {
        engine.setDisplayAsleep(asleep)
        // After waking, take a fresh baseline: a monitor that restored its own brightness
        // should not count as a manual change.
        if !asleep, display?.channel != nil { needsBaseline = true }
        refreshSnapshot()
    }

    func userSet(_ value: Int) {
        engine.userSet(value, at: Date())
        reportManualChange()
        refreshSnapshot()
    }

    func tick(now: Date) {
        defer { refreshSnapshot(now: now) }
        guard !busy, let channel = display?.channel else { return }

        if needsBaseline {
            needsBaseline = false
            run(channel, { $0.read(.brightness) }) { [self] reading in
                if let reading {
                    maximum = reading.maximum
                    engine.displayAppeared(brightness: percent(reading.current))
                } else {
                    readFailures += 1
                    engine.displayAppeared(brightness: nil)
                }
                nextReadAt = Date().addingTimeInterval(Self.readInterval)
            }
            return
        }

        if now >= nextWriteAt, let value = engine.nextWrite(at: now) {
            let raw = Int((Double(value) * Double(maximum) / 100).rounded())
            run(channel, { $0.write(.brightness, value: raw) }) { [self] accepted in
                let finished = Date()
                if accepted {
                    engine.didWrite(value, at: finished)
                    writeBackoff.reset()
                    ddcProblem = nil
                    nextReadAt = max(nextReadAt, finished.addingTimeInterval(5))
                } else {
                    nextWriteAt = finished.addingTimeInterval(writeBackoff.nextDelay())
                    if writeBackoff.failures >= 3 {
                        ddcProblem = "The display isn't answering brightness commands"
                        engine.dropPendingManual()
                        onDisplayTrouble?()
                    }
                }
            }
            return
        }

        if engine.displayConnected, !engine.displayAsleep, !engine.isAdjusting, now >= nextReadAt {
            run(channel, { $0.read(.brightness) }) { [self] reading in
                let finished = Date()
                if let reading {
                    maximum = reading.maximum
                    readFailures = 0
                    engine.observed(percent(reading.current), at: finished)
                    reportManualChange()
                } else {
                    readFailures += 1
                }
                // A display that cannot be read can still be written; just stop asking often.
                nextReadAt = finished.addingTimeInterval(readFailures >= 3 ? Self.slowReadInterval : Self.readInterval)
            }
        }
    }

    // MARK: Private

    private func reportManualChange() {
        if rule.enabled, !engine.enabled { onManualChange?() }
    }

    /// Runs blocking DDC work on this rule's queue, then `completion` on the main actor, unless
    /// the display changed in the meantime.
    private func run<T: Sendable>(
        _ channel: DDCChannel,
        _ work: @escaping @Sendable (DDCChannel) -> T,
        completion: @escaping (T) -> Void
    ) {
        busy = true
        let queue = self.queue
        let serviceID = channel.serviceID
        Task {
            let result = await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
                queue.async { continuation.resume(returning: work(channel)) }
            }
            busy = false
            guard display?.channel?.serviceID == serviceID else { return }
            completion(result)
            refreshSnapshot()
        }
    }

    private func percent(_ raw: Int) -> Int {
        guard maximum > 0 else { return raw }
        return Int((Double(raw) * 100 / Double(maximum)).rounded())
    }

    private func refreshSnapshot(now: Date = Date()) {
        // Lux is rounded so the UI only redraws when a shown number could change.
        func rounded(_ lux: Double?) -> Double? { lux.map { ($0 * 10).rounded() / 10 } }
        let active = engine.activeReading(at: now)
        var rawLuxBySource: [UUID: Double] = [:]
        for source in rule.sources {
            if let raw = rounded(engine.reading(of: source.id, at: now)?.rawLux) { rawLuxBySource[source.id] = raw }
        }
        let next = Snapshot(
            phase: engine.phase(at: now),
            brightness: engine.brightness,
            target: engine.target(at: now),
            activeSource: active?.source,
            lux: rounded(active?.lux),
            sensorPercent: active?.percent,
            rawLuxBySource: rawLuxBySource,
            adjusting: engine.isAdjusting,
            changedByHand: engine.changedByHand
        )
        if next != snapshot { snapshot = next }
    }

    private static func settings(for rule: DisplayRule) -> BrightnessEngine.Settings {
        BrightnessEngine.Settings(
            curve: rule.curve,
            sources: rule.sources.filter(\.enabled).map { source in
                // The Mac sensor is read every second; Home Assistant can take up to 30 s between
                // polls while it is failing, so its readings are trusted for longer.
                BrightnessEngine.Source(id: source.id, gain: source.gain, staleAfter: source.kind == .macSensor ? 10 : 60)
            },
            stability: rule.sensitivity.stability
        )
    }
}
