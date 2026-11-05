import XCTest
@testable import LuxBridgeCore

/// Replays recorded sensor readings through the engine and reports how often the brightness would
/// change at each sensitivity. A tuning tool, skipped unless a recording is given:
///
///     LUXBRIDGE_REPLAY=history.json swift test --filter ReplayTests
///
/// The file is either Home Assistant history JSON (`/api/history/period/...`) or text lines of
/// "unix-seconds lux". LUXBRIDGE_REPLAY_GAIN sets the source's gain (default 1), and
/// LUXBRIDGE_REPLAY_CURVE a curve as "lux:percent,lux:percent,..." (default: the app's default curve).
final class ReplayTests: XCTestCase {
    func testReplay() throws {
        guard let path = ProcessInfo.processInfo.environment["LUXBRIDGE_REPLAY"] else {
            throw XCTSkip("set LUXBRIDGE_REPLAY to a recording")
        }
        let gain = ProcessInfo.processInfo.environment["LUXBRIDGE_REPLAY_GAIN"].flatMap(Double.init) ?? 1
        let curve = ProcessInfo.processInfo.environment["LUXBRIDGE_REPLAY_CURVE"].map { text in
            BrightnessCurve(points: text.split(separator: ",").compactMap { pair in
                let parts = pair.split(separator: ":").compactMap { Double($0) }
                return parts.count == 2 ? CurvePoint(lux: parts[0], brightness: parts[1]) : nil
            })
        } ?? BrightnessCurve.standard
        let readings = try Self.load(path)
        let first = try XCTUnwrap(readings.first?.0), last = try XCTUnwrap(readings.last?.0)
        let days = max((last - first) / 86400, 1 / 24)
        print(String(format: "replay: %d readings over %.1f h, gain %.2f", readings.count, (last - first) / 3600, gain))

        let stabilities: [(String, Stability)] = [("none", .none)] + Sensitivity.allCases.map { ($0.rawValue, $0.stability) }
        for (name, stability) in stabilities {
            let source = UUID()
            let engine = BrightnessEngine(settings: .init(curve: curve, sources: [.init(id: source, gain: gain, staleAfter: 3600)], stability: stability))
            engine.displayAppeared(brightness: nil)
            var index = 0
            var writes: [(TimeInterval, Int)] = []
            var t = first
            while t <= last {
                // Poll every 2 s, like the app, and tick every 0.2 s.
                if Int(((t - first) * 10).rounded()) % 20 == 0 {
                    while index + 1 < readings.count, readings[index + 1].0 <= t { index += 1 }
                    engine.sourceValue(readings[index].1, unit: "lx", source: source, at: Date(timeIntervalSince1970: t))
                }
                if let value = engine.nextWrite(at: Date(timeIntervalSince1970: t)) {
                    writes.append((t, value))
                    engine.didWrite(value, at: Date(timeIntervalSince1970: t))
                }
                t += 0.2
            }
            // Group fade steps into changes: a write within 1.5 s of the previous one continues it.
            var changes: [(start: TimeInterval, from: Int, to: Int)] = []
            var previous = writes.first ?? (first, 0)
            for (time, value) in writes.dropFirst() {
                if !changes.isEmpty, time - previous.0 < 1.5 {
                    changes[changes.count - 1].to = value
                } else {
                    changes.append((time, previous.1, value))
                }
                previous = (time, value)
            }
            let reversals = zip(changes, changes.dropFirst()).filter { a, b in
                b.start - a.start < 300 && (a.to - a.from) * (b.to - b.from) < 0
            }.count
            let sizes = changes.map { abs($0.to - $0.from) }.sorted()
            print(String(format: "  %-7@ %6.0f changes/day  %5.0f reversed within 5 min/day  median size %d",
                         name as NSString, Double(changes.count) / days, Double(reversals) / days, sizes.isEmpty ? 0 : sizes[sizes.count / 2]))
        }
    }

    private static func load(_ path: String) throws -> [(TimeInterval, Double)] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        if let history = try? JSONSerialization.jsonObject(with: data) as? [[[String: Any]]] {
            let parser = ISO8601DateFormatter()
            parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return history.flatMap { $0 }.compactMap { row in
                guard let state = (row["state"] as? String).flatMap(Double.init),
                      let stamp = (row["last_changed"] ?? row["last_updated"]) as? String,
                      let date = parser.date(from: stamp) ?? ISO8601DateFormatter().date(from: stamp)
                else { return nil }
                return (date.timeIntervalSince1970, state)
            }
        }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ")
            guard fields.count >= 2, let t = Double(fields[0]), let v = Double(fields[1]) else { return nil }
            return (t, v)
        }
    }
}
