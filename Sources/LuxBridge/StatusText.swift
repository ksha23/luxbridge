import Foundation
import LuxBridgeCore

/// Human-readable names and the one-line status under each display in the menu.
@MainActor
enum StatusText {
    static func line(for runtime: RuleRuntime, hub: SensorHub, mac: MacSensorStatus) -> String {
        if let problem = runtime.ddcProblem { return problem }
        let snapshot = runtime.snapshot
        switch snapshot.phase {
        case .noDisplay:
            return runtime.rule.display == nil ? "Choose a display in Settings" : "Not connected"
        case .displayAsleep:
            return "Display asleep"
        case .disabled:
            return snapshot.changedByHand
                ? "Auto turned off by a manual change"
                : "Automatic brightness is off"
        case .waitingForSensor:
            return waitingReason(for: runtime.rule, hub: hub, mac: mac)
        case .following:
            let source = runtime.rule.sources.first { $0.id == snapshot.activeSource }
            var text = source.map { name(of: $0, hub: hub) + ": " } ?? ""
            if let percent = snapshot.sensorPercent {
                text += "\(Int(percent.rounded()))%"
            } else if let lux = snapshot.lux {
                text += "\(formatLux(lux)) lux"
            }
            if let target = snapshot.target { text += " → \(target)%" }
            if snapshot.adjusting { text += ", adjusting" }
            return text
        }
    }

    static func name(of source: LightSource, hub: SensorHub) -> String {
        switch source.kind {
        case .macSensor:
            return "Mac sensor"
        case .homeAssistant:
            if source.entityID.isEmpty { return "Home Assistant" }
            return hub.states[source.entityID]?.name ?? source.entityID
        }
    }

    static func formatLux(_ lux: Double) -> String {
        lux < 10 ? String(format: "%.1f", lux) : String(Int(lux.rounded()))
    }

    /// Why no source has a reading: the reason for the first enabled source, in priority order.
    private static func waitingReason(for rule: DisplayRule, hub: SensorHub, mac: MacSensorStatus) -> String {
        let enabled = rule.sources.filter(\.enabled)
        guard !enabled.isEmpty else { return "Turn on a light source in Settings" }
        let reasons = enabled.map { reason(for: $0, hub: hub, mac: mac) }
        return reasons.joined(separator: ". ") + ". Holding the current brightness"
    }

    private static func reason(for source: LightSource, hub: SensorHub, mac: MacSensorStatus) -> String {
        switch source.kind {
        case .macSensor:
            switch mac {
            case .notPresent: return "This Mac has no light sensor"
            case .lidClosed: return "Lid closed"
            case .reading: return "Waiting for the Mac sensor"
            }
        case .homeAssistant:
            if source.entityID.isEmpty { return "No Home Assistant sensor chosen" }
            switch hub.status {
            case .notConfigured: return "Home Assistant is not set up"
            case .failing(let error): return error.localizedDescription
            case .idle, .connected: break
            }
            if let error = hub.entityErrors[source.entityID] { return error.localizedDescription }
            if let state = hub.states[source.entityID], state.number == nil { return "\(state.name) is \(state.state)" }
            return "Waiting for \(name(of: source, hub: hub))"
        }
    }
}
