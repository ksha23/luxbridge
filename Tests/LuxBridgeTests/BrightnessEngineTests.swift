import XCTest
@testable import LuxBridgeCore

final class BrightnessEngineTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)
    // 10 lux -> 20%, 1000 lux -> 80%, so 100 lux -> 50%.
    private let curve = BrightnessCurve(points: [
        CurvePoint(lux: 10, brightness: 20),
        CurvePoint(lux: 1000, brightness: 80),
    ])

    private let primary = UUID()
    private let secondary = UUID()

    private func makeEngine(secondaryGain: Double = 1) -> BrightnessEngine {
        // A response of 0 disables smoothing, which keeps the arithmetic below exact.
        BrightnessEngine(settings: .init(
            curve: curve,
            sources: [
                .init(id: primary, gain: 1, staleAfter: 180),
                .init(id: secondary, gain: secondaryGain, staleAfter: 10),
            ],
            stability: .none,
            responseSeconds: 0
        ))
    }

    private func at(_ seconds: TimeInterval) -> Date {
        start.addingTimeInterval(seconds)
    }

    /// Runs the tick loop for `seconds`, applying every write as the app would.
    @discardableResult
    private func run(_ engine: BrightnessEngine, from: TimeInterval, for seconds: TimeInterval) -> [Int] {
        var writes: [Int] = []
        for tick in stride(from: from, to: from + seconds, by: 0.05) {
            if let value = engine.nextWrite(at: at(tick)) {
                writes.append(value)
                engine.didWrite(value, at: at(tick))
            }
        }
        return writes
    }

    func testWritesNothingWithoutADisplay() {
        let engine = makeEngine()
        engine.feed(100, unit: "lx", at: at(0))
        XCTAssertNil(engine.nextWrite(at: at(0)))
        XCTAssertEqual(engine.phase(at: at(0)), .noDisplay)
    }

    func testWritesNothingWithoutASensorValue() {
        let engine = makeEngine()
        engine.displayAppeared(brightness: 10)
        XCTAssertNil(engine.nextWrite(at: at(0)))
        XCTAssertEqual(engine.phase(at: at(0)), .waitingForSensor)
    }

    func testRampsToTheTarget() {
        let engine = makeEngine()
        engine.displayAppeared(brightness: 10)
        engine.feed(100, unit: "lx", at: at(0))
        let writes = run(engine, from: 0, for: 8)
        XCTAssertEqual(writes.last, 50)
        XCTAssertGreaterThan(writes.count, 3, "a 40 point change should be ramped, not jumped")
        XCTAssertEqual(writes, writes.sorted())
        XCTAssertEqual(engine.brightness, 50)
        XCTAssertFalse(engine.isAdjusting)
    }

    func testChangesFadeOnePercentAtATime() throws {
        let engine = makeEngine()
        engine.displayAppeared(brightness: 10)
        engine.sourceValue(100, unit: "lx", source: primary, at: at(0))
        var writes: [(TimeInterval, Int)] = []
        for tick in stride(from: 0.0, to: 10, by: 0.05) {
            if let value = engine.nextWrite(at: at(tick)) {
                writes.append((tick, value))
                engine.didWrite(value, at: at(tick))
            }
        }
        XCTAssertEqual(writes.map(\.1), Array(11...50), "every step is one percent, always upward")
        let first = try XCTUnwrap(writes.first?.0), last = try XCTUnwrap(writes.last?.0)
        // A 40 point change gets the longest fade, 5 s. Eased in and out, its first and last
        // one-percent steps fall about 0.3 s inside that.
        XCTAssertLessThanOrEqual(last, 5.05)
        XCTAssertGreaterThan(last - first, 4)
        // Eased: the steps are further apart at the start than in the middle.
        let gaps = zip(writes, writes.dropFirst()).map { $1.0 - $0.0 }
        XCTAssertGreaterThan(gaps[0], gaps[gaps.count / 2] * 1.5)
    }

    func testAManualChangeIsNotFaded() {
        let engine = makeEngine()
        engine.displayAppeared(brightness: 10)
        engine.sourceValue(100, unit: "lx", source: primary, at: at(0))
        engine.userSet(80, at: at(1))
        XCTAssertEqual(engine.nextWrite(at: at(1)), 80)
    }

    func testJumpsWhenTheCurrentBrightnessIsUnknown() {
        let engine = makeEngine()
        engine.displayAppeared(brightness: nil)
        engine.feed(100, unit: "lx", at: at(0))
        XCTAssertEqual(engine.nextWrite(at: at(0)), 50)
    }

    func testIgnoresChangesInsideTheDeadband() {
        let engine = makeEngine()
        engine.displayAppeared(brightness: 49)
        engine.feed(100, unit: "lx", at: at(0))
        XCTAssertNil(engine.nextWrite(at: at(0)))
    }

    func testPercentSensorsSetBrightnessDirectly() {
        let engine = makeEngine()
        engine.displayAppeared(brightness: nil)
        engine.feed(37, unit: "%", at: at(0))
        XCTAssertEqual(engine.nextWrite(at: at(0)), 37)
    }

    func testHoldsWhenTheSensorGoesStale() {
        let engine = makeEngine()
        engine.displayAppeared(brightness: 10)
        engine.feed(100, unit: "lx", at: at(0))
        run(engine, from: 0, for: 8)
        XCTAssertEqual(engine.phase(at: at(179)), .following)
        XCTAssertEqual(engine.phase(at: at(181)), .waitingForSensor)
        XCTAssertNil(engine.nextWrite(at: at(181)))
        XCTAssertEqual(engine.brightness, 50, "the display keeps its last brightness")
    }

    func testAManualChangeOnTheMonitorTurnsAutoOff() {
        let engine = makeEngine()
        engine.displayAppeared(brightness: 50)
        engine.feed(100, unit: "lx", at: at(0))
        // Someone presses the monitor's buttons.
        engine.observed(70, at: at(10))
        XCTAssertFalse(engine.enabled)
        XCTAssertTrue(engine.changedByHand)
        XCTAssertEqual(engine.phase(at: at(10)), .disabled)
        engine.feed(100, unit: "lx", at: at(99_999))
        XCTAssertNil(engine.nextWrite(at: at(99_999)), "off for good, so the manual 70% stays")
        // Turned back on, it fades back to the curve.
        engine.enabled = true
        XCTAssertFalse(engine.changedByHand)
        let writes = run(engine, from: 99_999, for: 8)
        XCTAssertEqual(writes.last, 50)
    }

    func testReadBacksRightAfterAWriteAreIgnored() {
        let engine = makeEngine()
        engine.displayAppeared(brightness: nil)
        engine.feed(100, unit: "lx", at: at(0))
        engine.didWrite(engine.nextWrite(at: at(0))!, at: at(0))
        // The display still reports the old value for a moment.
        engine.observed(10, at: at(1))
        XCTAssertEqual(engine.phase(at: at(1)), .following)
        XCTAssertEqual(engine.brightness, 50)
    }

    func testAMatchingReadBackLeavesAutoOn() {
        let engine = makeEngine()
        engine.displayAppeared(brightness: 50)
        engine.feed(100, unit: "lx", at: at(0))
        engine.observed(51, at: at(20))
        XCTAssertEqual(engine.phase(at: at(20)), .following)
        XCTAssertFalse(engine.changedByHand)
    }

    func testUserSetWritesAndTurnsAutoOff() {
        let engine = makeEngine()
        engine.displayAppeared(brightness: 50)
        engine.feed(100, unit: "lx", at: at(0))
        engine.userSet(15, at: at(1))
        XCTAssertEqual(engine.nextWrite(at: at(1)), 15)
        engine.didWrite(15, at: at(1))
        XCTAssertEqual(engine.phase(at: at(99_999)), .disabled)
        XCTAssertNil(engine.nextWrite(at: at(99_999)))
        engine.enabled = true
        engine.feed(100, unit: "lx", at: at(100_000))
        XCTAssertEqual(run(engine, from: 100_000, for: 8).last, 50)
    }

    func testAManualChangeMidFadeStopsTheFade() {
        let engine = makeEngine()
        engine.displayAppeared(brightness: 20)
        engine.feed(1000, unit: "lx", at: at(0))
        run(engine, from: 0, for: 1)
        XCTAssertTrue(engine.isAdjusting)
        engine.userSet(30, at: at(1))
        let writes = run(engine, from: 1, for: 10)
        XCTAssertEqual(writes, [30], "only the manual value is written")
        XCTAssertEqual(engine.brightness, 30)
    }

    func testDisabledEngineOnlyWritesManualChanges() {
        let engine = makeEngine()
        engine.enabled = false
        engine.displayAppeared(brightness: 10)
        engine.feed(100, unit: "lx", at: at(0))
        XCTAssertNil(engine.nextWrite(at: at(0)))
        engine.userSet(30, at: at(1))
        XCTAssertEqual(engine.nextWrite(at: at(1)), 30)
        XCTAssertEqual(engine.phase(at: at(1)), .disabled)
        XCTAssertTrue(engine.changedByHand)
    }

    func testNothingIsWrittenWhileTheDisplaySleeps() {
        let engine = makeEngine()
        engine.displayAppeared(brightness: 10)
        engine.feed(100, unit: "lx", at: at(0))
        engine.setDisplayAsleep(true)
        XCTAssertNil(engine.nextWrite(at: at(0)))
        XCTAssertEqual(engine.phase(at: at(0)), .displayAsleep)
    }

    func testANewBaselineAfterReconnectIsNotAManualChange() {
        let engine = makeEngine()
        engine.displayAppeared(brightness: 50)
        engine.feed(100, unit: "lx", at: at(0))
        engine.displayDisappeared()
        // The monitor comes back at its own power-on brightness.
        engine.displayAppeared(brightness: 80)
        XCTAssertEqual(engine.phase(at: at(5)), .following)
        XCTAssertEqual(run(engine, from: 5, for: 8).last, 50)
    }

    // MARK: Several sources

    func testTheFirstSourceWithAReadingWins() {
        let engine = makeEngine()
        engine.displayAppeared(brightness: nil)
        engine.sourceValue(1000, unit: "lx", source: secondary, at: at(0))
        XCTAssertEqual(engine.target(at: at(0)), 80, "only the second source has a reading")
        engine.sourceValue(100, unit: "lx", source: primary, at: at(1))
        XCTAssertEqual(engine.target(at: at(1)), 50, "the first source takes over as soon as it reads")
        XCTAssertEqual(engine.activeReading(at: at(1))?.source, primary)
    }

    func testALostSourceHandsOverAtOnce() {
        let engine = makeEngine()
        engine.displayAppeared(brightness: nil)
        engine.sourceValue(100, unit: "lx", source: primary, at: at(0))
        engine.sourceValue(1000, unit: "lx", source: secondary, at: at(0))
        engine.sourceLost(primary)
        XCTAssertEqual(engine.target(at: at(0)), 80)
    }

    func testAStaleSourceHandsOver() {
        let engine = makeEngine()
        engine.displayAppeared(brightness: nil)
        engine.sourceValue(1000, unit: "lx", source: primary, at: at(0))
        for second in stride(from: 0.0, through: 200, by: 1) {
            engine.sourceValue(10, unit: "lx", source: secondary, at: at(second))
        }
        XCTAssertEqual(engine.target(at: at(179)), 80)
        XCTAssertEqual(engine.target(at: at(181)), 20)
    }

    func testGainScalesASourceOntoTheSharedCurve() throws {
        // A laptop sensor that sees a tenth of the light the window sensor sees.
        let engine = makeEngine(secondaryGain: 10)
        engine.displayAppeared(brightness: nil)
        engine.sourceValue(10, unit: "lx", source: secondary, at: at(0))
        let reading = try XCTUnwrap(engine.activeReading(at: at(0)))
        XCTAssertEqual(try XCTUnwrap(reading.rawLux), 10, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(reading.lux), 100, accuracy: 1e-9)
        XCTAssertEqual(engine.target(at: at(0)), 50)
    }

    func testAGainChangeAppliesAtOnce() {
        let engine = makeEngine(secondaryGain: 1)
        engine.displayAppeared(brightness: nil)
        engine.sourceValue(10, unit: "lx", source: secondary, at: at(0))
        XCTAssertEqual(engine.target(at: at(0)), 20)
        engine.settings.sources[1].gain = 100
        XCTAssertEqual(engine.target(at: at(0)), 80)
    }

    func testRemovingASourceForgetsItsReadings() {
        let engine = makeEngine()
        engine.displayAppeared(brightness: nil)
        engine.sourceValue(100, unit: "lx", source: primary, at: at(0))
        engine.settings.sources.removeFirst()
        XCTAssertNil(engine.target(at: at(0)))
    }
}

private extension BrightnessEngine {
    /// A reading from the first source, which most tests use alone.
    func feed(_ value: Double, unit: String?, at now: Date) {
        sourceValue(value, unit: unit, source: settings.sources[0].id, at: now)
    }
}

/// The stability rule against real sensor wobble: an Aqara FP2 stepping by 4 lux and a
/// MacBook's sensor stepping by 1 lux in a dim room.
final class StabilityTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)
    private let source = UUID()
    // A curve tuned by hand for a dim room, flat from 5 to 37 lux.
    private let curve = BrightnessCurve(points: [
        CurvePoint(lux: 5, brightness: 10), CurvePoint(lux: 37, brightness: 10), CurvePoint(lux: 100, brightness: 40),
        CurvePoint(lux: 1000, brightness: 80), CurvePoint(lux: 5000, brightness: 100),
    ])

    private func makeEngine(gain: Double = 1) -> BrightnessEngine {
        let engine = BrightnessEngine(settings: .init(
            curve: curve,
            sources: [.init(id: source, gain: gain)],
            stability: Sensitivity.normal.stability
        ))
        engine.displayAppeared(brightness: nil)
        return engine
    }

    /// Polls `lux(t)` every 2 s and ticks every 0.2 s like the app, applying each write.
    /// Returns the writes as (seconds, brightness).
    @discardableResult
    private func run(_ engine: BrightnessEngine, from: TimeInterval = 0, to: TimeInterval, lux: (TimeInterval) -> Double) -> [(TimeInterval, Int)] {
        var writes: [(TimeInterval, Int)] = []
        var t = from
        while t < to {
            let now = start.addingTimeInterval(t)
            if Int((t * 20).rounded()) % 40 == 0 { engine.sourceValue(lux(t), unit: "lx", source: source, at: now) }
            if let value = engine.nextWrite(at: now) {
                writes.append((t, value))
                engine.didWrite(value, at: now)
            }
            t += 0.05
        }
        return writes
    }

    func testMacSensorRoundingDoesNotMoveTheBrightness() {
        // A MacBook sensor reading 5, 6, 7, 6, 5 ... lux at a gain of 7.4. Followed reading by
        // reading, this made the display pump up and down.
        let engine = makeEngine(gain: 7.4)
        let pattern: [Double] = [5, 6, 7, 6, 5, 7, 6, 6, 5, 7]
        let writes = run(engine, to: 600) { pattern[Int($0 / 2) % pattern.count] }
        XCTAssertEqual(Set(writes.map(\.1)).count, 1, "one write to reach the target, then nothing: \(writes)")
    }

    func testFP2StepsDoNotMoveTheBrightness() {
        let engine = makeEngine()
        let writes = run(engine, to: 600) { Int($0 / 14) % 2 == 0 ? 33 : 37 }
        XCTAssertEqual(Set(writes.map(\.1)).count, 1, "\(writes)")
    }

    func testTheWaitShrinksWithTheChange() {
        let normal = Sensitivity.normal.stability
        XCTAssertEqual(normal.dwell(forRatio: 1.3), 60, accuracy: 1e-9)
        XCTAssertEqual(normal.dwell(forRatio: 2), 3, accuracy: 1e-9)
        XCTAssertEqual(normal.dwell(forRatio: 5), 3, accuracy: 1e-9)
        XCTAssertEqual(normal.dwell(forRatio: 1.5), 22, accuracy: 1)
        XCTAssertEqual(Stability.none.dwell(forRatio: 1.5), 0)
    }

    func testASmallChangeWaitsMostOfAMinute() throws {
        let engine = makeEngine()
        run(engine, to: 60) { _ in 40 }
        let writes = run(engine, from: 60, to: 200) { _ in 55 }
        let first = try XCTUnwrap(writes.first)
        XCTAssertGreaterThan(first.0, 60 + 35)
        XCTAssertLessThan(first.0, 60 + 60)
        XCTAssertEqual(engine.brightness, Int(curve.brightness(forLux: 55).rounded()))
    }

    func testTurningOnALightIsFollowedInSeconds() throws {
        // What an FP2 reported when the room's lights came back on: 41, then 77 lux.
        // The old rule waited a full minute for this, since 77 is just under twice 41.
        let engine = makeEngine()
        run(engine, to: 60) { _ in 41 }
        let writes = run(engine, from: 60, to: 120) { _ in 77 }
        let first = try XCTUnwrap(writes.first)
        XCTAssertLessThan(first.0, 60 + 12)
        XCTAssertEqual(try XCTUnwrap(engine.brightness), Int(curve.brightness(forLux: 77).rounded()), accuracy: 1)
    }

    func testAChangeThatDoesNotLastIsIgnored() {
        let engine = makeEngine()
        run(engine, to: 60) { _ in 40 }
        // A shadow: 55 lux for 30 s, then back.
        let writes = run(engine, from: 60, to: 400) { $0 < 90 ? 55 : 40 }
        XCTAssertTrue(writes.isEmpty, "\(writes)")
    }

    func testALampIsFollowedWithinSeconds() throws {
        let engine = makeEngine()
        run(engine, to: 60) { _ in 0 }
        XCTAssertEqual(engine.brightness, 10)
        let writes = run(engine, from: 60, to: 80) { _ in 300 }
        let first = try XCTUnwrap(writes.first)
        XCTAssertLessThan(first.0, 60 + 5, "the lamp starts showing within a few seconds")
        XCTAssertEqual(engine.brightness, Int(curve.brightness(forLux: 300).rounded()), "and in one step, not several")
    }

    func testTurningAutoBackOnAimsAtTheCurrentLight() {
        let engine = makeEngine()
        run(engine, to: 60) { _ in 40 }
        engine.userSet(70, at: start.addingTimeInterval(60))
        run(engine, from: 60, to: 62) { _ in 40 }
        engine.enabled = true
        run(engine, from: 62, to: 80) { _ in 45 }
        XCTAssertEqual(engine.brightness, Int(curve.brightness(forLux: 45).rounded()))
    }
}
