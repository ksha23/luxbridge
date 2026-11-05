import DDCKit
import LuxBridgeCore
import SwiftUI

struct RuleEditorView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var hub: SensorHub
    let ruleID: UUID
    @State private var sensors: [HAEntityState] = []
    @State private var sensorError: String?

    var body: some View {
        Form {
            Section {
                Picker("Display", selection: binding(\.display)) {
                    Text("Choose…").tag(DisplayIdentity?.none)
                    ForEach(displayChoices, id: \.self) { identity in
                        Text(label(for: identity)).tag(DisplayIdentity?.some(identity))
                    }
                }
                Toggle("Adjust brightness automatically", isOn: binding(\.enabled))
            } header: {
                Text("Display")
            } footer: {
                Text("Changing the brightness yourself, from the menu, the monitor's buttons or another app, turns this off. Turn it back on (Auto in the menu) to follow the light again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                ForEach(Array(rule.sources.enumerated()), id: \.element.id) { index, source in
                    SourceRow(
                        ruleID: ruleID,
                        source: source,
                        isFirst: index == 0,
                        isLast: index == rule.sources.count - 1,
                        sensors: sensors,
                        sensorError: sensorError,
                        update: updateSource,
                        move: moveSource,
                        remove: removeSource,
                        reloadSensors: { Task { await loadSensors() } }
                    )
                }
                HStack {
                    Button("Add Home Assistant sensor") { addSource(.homeAssistant) }
                    Button("Add Mac light sensor") { addSource(.macSensor) }
                        .disabled(rule.sources.contains { $0.kind == .macSensor })
                }
            } header: {
                Text("Light sources")
            } footer: {
                Text("The first source in this list that has a reading drives the display. Gain multiplies a source's lux, so a sensor that sees less of the room's light, such as a laptop facing away from the lamp, can share the curve with one that sees more.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Picker("Sensitivity", selection: binding(\.sensitivity)) {
                    Text("High: follows changes of 15% or more").tag(Sensitivity.high)
                    Text("Normal: follows changes of 30% or more").tag(Sensitivity.normal)
                    Text("Low: follows changes of 50% or more").tag(Sensitivity.low)
                }
            } header: {
                Text("Behavior")
            } footer: {
                Text("Sensors wobble with shadows, clouds and their own rounding, so a change in the light has to last before the brightness follows. The bigger the change, the shorter the wait: at Normal, 30% more or less light waits a minute, 50% about 20 seconds, and a lamp switching on or off (the light doubling or halving) about 3 seconds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                CurveEditorView(curve: binding(\.curve), currentLux: runtime?.snapshot.lux)
            } header: {
                Text("Curve")
            } footer: {
                Text("Lux here is after the active source's gain. A Home Assistant sensor that reports a percentage, such as a template helper, sets the brightness directly and skips the curve.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await loadSensors() }
    }

    private var rule: DisplayRule {
        model.config.rules.first { $0.id == ruleID } ?? DisplayRule(id: ruleID)
    }

    private var runtime: RuleRuntime? {
        model.runtimes.first { $0.id == ruleID }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<DisplayRule, Value>) -> Binding<Value> {
        Binding(
            get: { rule[keyPath: keyPath] },
            set: { value in
                var updated = rule
                updated[keyPath: keyPath] = value
                model.updateRule(updated)
            }
        )
    }

    // MARK: Sources

    private func updateSource(_ source: LightSource) {
        var updated = rule
        guard let index = updated.sources.firstIndex(where: { $0.id == source.id }) else { return }
        updated.sources[index] = source
        model.updateRule(updated)
    }

    private func moveSource(_ id: UUID, _ offset: Int) {
        var updated = rule
        guard let index = updated.sources.firstIndex(where: { $0.id == id }),
              updated.sources.indices.contains(index + offset)
        else { return }
        updated.sources.swapAt(index, index + offset)
        model.updateRule(updated)
    }

    private func removeSource(_ id: UUID) {
        var updated = rule
        updated.sources.removeAll { $0.id == id }
        model.updateRule(updated)
    }

    private func addSource(_ kind: LightSourceKind) {
        var updated = rule
        updated.sources.append(LightSource(kind: kind))
        model.updateRule(updated)
    }

    private func loadSensors() async {
        do {
            sensors = try await model.sensorChoices()
            sensorError = nil
        } catch {
            sensorError = "Couldn't list sensors: \(error.localizedDescription)"
        }
    }

    // MARK: Displays

    private var displayChoices: [DisplayIdentity] {
        var choices: [DisplayIdentity] = []
        for identity in model.displays.map(\.identity) where !choices.contains(identity) {
            choices.append(identity)
        }
        if let current = rule.display, !choices.contains(current) { choices.append(current) }
        return choices
    }

    private func label(for identity: DisplayIdentity) -> String {
        guard let display = model.displays.first(where: { $0.identity == identity }) else {
            return "\(identity.name) (not connected)"
        }
        return display.channel == nil ? "\(display.name) (no DDC)" : display.name
    }
}

/// One light source of a display: on/off, order, its entity, and its gain.
private struct SourceRow: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var hub: SensorHub
    let ruleID: UUID
    let source: LightSource
    let isFirst: Bool
    let isLast: Bool
    let sensors: [HAEntityState]
    let sensorError: String?
    let update: (LightSource) -> Void
    let move: (UUID, Int) -> Void
    let remove: (UUID) -> Void
    let reloadSensors: () -> Void

    private static let ignoredPercentClasses: Set<String> = ["battery", "humidity", "moisture", "power_factor"]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle(isOn: field(\.enabled)) {
                    Text(source.kind == .macSensor ? "Mac light sensor" : "Home Assistant sensor")
                        .fontWeight(.medium)
                }
                if runtime?.snapshot.activeSource == source.id {
                    Text("In use")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.green.opacity(0.2), in: Capsule())
                }
                Spacer()
                Button { move(source.id, -1) } label: { Image(systemName: "chevron.up") }
                    .disabled(isFirst)
                    .help("Try this source earlier")
                Button { move(source.id, 1) } label: { Image(systemName: "chevron.down") }
                    .disabled(isLast)
                    .help("Try this source later")
                Button { remove(source.id) } label: { Image(systemName: "trash") }
                    .help("Remove this source")
            }
            .buttonStyle(.borderless)

            if source.kind == .homeAssistant {
                HStack {
                    TextField("Entity", text: field(\.entityID), prompt: Text("sensor.living_room_illuminance"))
                    sensorMenu
                }
                if let error = hub.entityErrors[source.entityID] {
                    Text(error.localizedDescription).font(.caption).foregroundStyle(.red)
                }
            }

            HStack {
                Text("Gain")
                TextField("Gain", value: field(\.gain), format: .number.precision(.fractionLength(0...2)))
                    .frame(width: 64)
                    .labelsHidden()
                Text(readingText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let reference = model.matchReference(ruleID: ruleID, sourceID: source.id) {
                    Button("Match \(StatusText.name(of: reference, hub: hub))") {
                        model.matchGain(ruleID: ruleID, sourceID: source.id)
                    }
                    .help("Sets the gain so this source reads the same lux as the other one right now")
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var runtime: RuleRuntime? {
        model.runtimes.first { $0.id == ruleID }
    }

    /// What the source reads now: "reads 7 lux × 6 = 42 lux".
    private var readingText: String {
        let raw: Double?
        if let fresh = runtime?.snapshot.rawLuxBySource[source.id] {
            raw = fresh
        } else if source.kind == .homeAssistant, let state = hub.states[source.entityID] {
            if state.isPercent { return "reads \(state.state)%, used as the brightness" }
            raw = state.number
        } else if source.kind == .macSensor {
            switch model.macSensorStatus {
            case .notPresent: return "this Mac has no light sensor"
            case .lidClosed: return "not available while the lid is closed"
            case .reading(let lux): raw = lux
            }
        } else {
            raw = nil
        }
        guard let raw else { return "no reading yet" }
        let text = "reads \(StatusText.formatLux(raw)) lux"
        guard source.gain != 1 else { return text }
        return text + " × \(source.gain.formatted()) = \(StatusText.formatLux(raw * source.gain)) lux"
    }

    private func field<Value>(_ keyPath: WritableKeyPath<LightSource, Value>) -> Binding<Value> {
        Binding(
            get: { source[keyPath: keyPath] },
            set: { value in
                var updated = source
                updated[keyPath: keyPath] = value
                update(updated)
            }
        )
    }

    private var sensorMenu: some View {
        Menu("Choose") {
            let light = sensors.filter(\.isIlluminance)
            let percent = sensors.filter {
                $0.isPercent && !Self.ignoredPercentClasses.contains($0.attributes.deviceClass ?? "")
            }
            if light.isEmpty && percent.isEmpty {
                Text(sensorError ?? "No light sensors found")
            }
            if !light.isEmpty {
                Section("Light sensors") {
                    ForEach(light) { state in
                        Button("\(state.name)  (\(state.state) \(state.attributes.unit ?? ""))") {
                            field(\.entityID).wrappedValue = state.entityID
                        }
                    }
                }
            }
            if !percent.isEmpty {
                Section("Percentage sensors") {
                    ForEach(percent) { state in
                        Button("\(state.name)  (\(state.state)%)") {
                            field(\.entityID).wrappedValue = state.entityID
                        }
                    }
                }
            }
            Divider()
            Button("Refresh list", action: reloadSensors)
        }
        .fixedSize()
    }
}
