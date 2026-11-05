import XCTest
@testable import LuxBridgeCore

final class BrightnessCurveTests: XCTestCase {
    private let curve = BrightnessCurve(points: [
        CurvePoint(lux: 10, brightness: 20),
        CurvePoint(lux: 1000, brightness: 80),
    ])

    func testFlatOutsidePoints() {
        XCTAssertEqual(curve.brightness(forLux: 0), 20)
        XCTAssertEqual(curve.brightness(forLux: 10), 20)
        XCTAssertEqual(curve.brightness(forLux: 5000), 80)
    }

    func testLinearInLogLux() {
        // 100 lux is halfway between 10 and 1000 on a log axis.
        XCTAssertEqual(curve.brightness(forLux: 100), 50, accuracy: 1e-9)
    }

    func testNormalizesPoints() {
        let messy = BrightnessCurve(points: [
            CurvePoint(lux: 100, brightness: 150),
            CurvePoint(lux: -5, brightness: 10),
            CurvePoint(lux: 0, brightness: 10),
            CurvePoint(lux: 10, brightness: -3),
            CurvePoint(lux: .nan, brightness: 10),
        ])
        XCTAssertEqual(messy.points, [CurvePoint(lux: 10, brightness: 0), CurvePoint(lux: 100, brightness: 100)])
    }

    func testSettingAPointKeepsTheCurveRising() {
        let updated = BrightnessCurve.standard.setting(CurvePoint(lux: 33, brightness: 60))
        XCTAssertEqual(updated.points.map(\.lux), [5, 33, 100, 1000, 5000])
        XCTAssertEqual(updated.points.map(\.brightness), [10, 60, 60, 80, 100])
        XCTAssertEqual(updated.brightness(forLux: 33), 60, accuracy: 1e-9)
    }

    func testSettingAPointReplacesNearbyPoints() {
        let updated = BrightnessCurve.standard.setting(CurvePoint(lux: 110, brightness: 35))
        XCTAssertEqual(updated.points.map(\.lux), [5, 110, 1000, 5000])
        XCTAssertEqual(updated.points[0].brightness, 10)
    }

    func testScalingKeepsTheShape() {
        let dimmer = BrightnessCurve.standard.scaled(by: 0.8)
        XCTAssertEqual(dimmer.points.map(\.lux), BrightnessCurve.standard.points.map(\.lux))
        XCTAssertEqual(dimmer.points.map(\.brightness), [8, 32, 64, 80])
        XCTAssertEqual(BrightnessCurve.standard.scaled(by: 2).points.map(\.brightness), [20, 80, 100, 100])
        XCTAssertEqual(BrightnessCurve.standard.scaled(by: 0), .standard)
    }

    func testRoundTripsThroughJSON() throws {
        let data = try JSONEncoder().encode(curve)
        XCTAssertEqual(try JSONDecoder().decode(BrightnessCurve.self, from: data), curve)
    }
}

final class LuxFilterTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 0)

    private func at(_ seconds: TimeInterval) -> Date {
        start.addingTimeInterval(seconds)
    }

    func testFirstValuePassesThrough() {
        var filter = LuxFilter(timeConstant: 3)
        filter.add(40, at: at(0))
        XCTAssertEqual(try XCTUnwrap(filter.value(at: at(0))), 40, accuracy: 1e-9)
    }

    func testALampShowsUpWithinSeconds() throws {
        var filter = LuxFilter(timeConstant: 3)
        filter.add(5, at: at(0))
        filter.add(500, at: at(10))
        XCTAssertEqual(try XCTUnwrap(filter.value(at: at(10))), 5, accuracy: 1e-9, "no jump at the moment of the reading")
        XCTAssertGreaterThan(try XCTUnwrap(filter.value(at: at(13))), 50, "most of the way in log terms after one time constant")
        XCTAssertGreaterThan(try XCTUnwrap(filter.value(at: at(25))), 470)
    }

    func testABriefSpikeBarelyMovesIt() throws {
        var filter = LuxFilter(timeConstant: 3)
        filter.add(30, at: at(0))
        filter.add(3000, at: at(10))
        filter.add(30, at: at(10.2))
        XCTAssertLessThan(try XCTUnwrap(filter.value(at: at(10.2))), 45)
        XCTAssertLessThan(try XCTUnwrap(filter.value(at: at(25))), 31)
    }

    func testZeroTimeConstantFollowsInstantly() throws {
        var filter = LuxFilter(timeConstant: 0)
        filter.add(5, at: at(0))
        filter.add(500, at: at(1))
        XCTAssertEqual(try XCTUnwrap(filter.value(at: at(1))), 500, accuracy: 1e-9)
    }

    func testResetsAfterALongGap() throws {
        var filter = LuxFilter(timeConstant: 3)
        filter.add(5, at: at(0))
        filter.add(800, at: at(3600))
        XCTAssertEqual(try XCTUnwrap(filter.value(at: at(3600))), 800, accuracy: 1e-9)
    }
}
