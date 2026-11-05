import XCTest
@testable import LuxBridgeCore

final class HomeAssistantTests: XCTestCase {
    func testDecodesAnIlluminanceState() throws {
        let json = """
            {"entity_id":"sensor.living_room_illuminance","state":"33",
             "attributes":{"unit_of_measurement":"lx","device_class":"illuminance",
                           "friendly_name":"Living Room Illuminance","state_class":"measurement"},
             "last_changed":"2026-10-18T00:26:04.472501+00:00"}
            """
        let state = try JSONDecoder().decode(HAEntityState.self, from: Data(json.utf8))
        XCTAssertEqual(state.number, 33)
        XCTAssertTrue(state.isIlluminance)
        XCTAssertFalse(state.isPercent)
        XCTAssertEqual(state.name, "Living Room Illuminance")
    }

    func testUnavailableIsNotANumber() {
        XCTAssertNil(HAEntityState(entityID: "sensor.x", state: "unavailable").number)
        XCTAssertNil(HAEntityState(entityID: "sensor.x", state: "nan").number)
    }

    func testOddAttributeTypesDoNotBreakDecoding() throws {
        let json = """
            [{"entity_id":"sensor.a","state":"1","attributes":{"friendly_name":["not","a","string"]}},
             {"entity_id":"sensor.b","state":"2","attributes":{}}]
            """
        let states = try JSONDecoder().decode([HAEntityState].self, from: Data(json.utf8))
        XCTAssertEqual(states.map(\.name), ["sensor.a", "sensor.b"])
    }

    func testServerURLAcceptsWhatPeopleType() {
        XCTAssertEqual(HomeAssistantClient.serverURL(from: "192.168.0.10:8123")?.absoluteString, "http://192.168.0.10:8123")
        XCTAssertEqual(HomeAssistantClient.serverURL(from: " https://ha.example.com/api/ ")?.absoluteString, "https://ha.example.com")
        XCTAssertEqual(HomeAssistantClient.serverURL(from: "homeassistant.local:8123/")?.absoluteString, "http://homeassistant.local:8123")
        XCTAssertNil(HomeAssistantClient.serverURL(from: ""))
        XCTAssertNil(HomeAssistantClient.serverURL(from: "ftp://example.com"))
    }

    func testDescribesNetworkErrors() {
        XCTAssertEqual(HomeAssistantClient.describe(URLError(.timedOut)), .unreachable("timed out"))
        XCTAssertEqual(HomeAssistantClient.describe(URLError(.cannotConnectToHost)), .unreachable("connection refused"))
    }

    func testSettingsWithMissingKeysStillLoad() throws {
        let json = """
            {"servers":["http://ha:8123"],"rules":[{"sources":[{"kind":"homeAssistant","entityID":"sensor.lux"}]}]}
            """
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        let rule = try XCTUnwrap(config.rules.first)
        XCTAssertEqual(config.pollSeconds, 2)
        XCTAssertTrue(config.showReadingsInMenuBar)
        XCTAssertEqual(rule.entityIDs, ["sensor.lux"])
        XCTAssertEqual(rule.sources.first?.gain, 1)
        XCTAssertEqual(rule.curve, .standard)
        XCTAssertTrue(rule.enabled)
        XCTAssertFalse(rule.usesMacSensor)
    }

    func testANewRuleTriesTheMacSensorFirst() {
        XCTAssertEqual(DisplayRule().sources.map(\.kind), [.macSensor, .homeAssistant])
    }

    func testBackoffDoublesUpToTheCap() {
        var backoff = Backoff(base: 2, cap: 30)
        XCTAssertEqual((0..<6).map { _ in backoff.nextDelay() }, [2, 4, 8, 16, 30, 30])
        backoff.reset()
        XCTAssertEqual(backoff.nextDelay(), 2)
    }
}
