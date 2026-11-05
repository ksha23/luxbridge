import AppKit
import LuxBridgeCore
import SwiftUI

struct MenuView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var hub: SensorHub
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.runtimes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No display set up yet").font(.headline)
                    Text("Pick a display and a Home Assistant light sensor in Settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(model.runtimes) { runtime in
                RuleStatusView(runtime: runtime)
                if runtime.id != model.runtimes.last?.id { Divider() }
            }
            Divider()
            HStack(spacing: 6) {
                Circle().fill(serverColor).frame(width: 7, height: 7)
                Text(serverText).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            HStack {
                Button("Settings…", action: openSettings)
                Spacer()
                Button("Quit LuxBridge") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 320)
        // Exactly as tall as the content, so the panel fits it.
        .fixedSize(horizontal: false, vertical: true)
    }

    private var serverText: String {
        switch hub.status {
        case .idle: "Home Assistant: not needed while no display is connected"
        case .notConfigured: "Home Assistant: not set up"
        case .connected: "Home Assistant: connected"
        case .failing(let error): error.localizedDescription
        }
    }

    private var serverColor: Color {
        switch hub.status {
        case .idle: .gray
        case .notConfigured: .orange
        case .connected: .green
        case .failing: .red
        }
    }
}

private struct RuleStatusView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var hub: SensorHub
    @ObservedObject var runtime: RuleRuntime
    @State private var dragValue: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "display")
                Text(runtime.rule.display?.name ?? "No display chosen").font(.headline).lineLimit(1)
                Spacer()
                Toggle("Auto", isOn: Binding(
                    get: { runtime.rule.enabled },
                    set: { model.setEnabled($0, ruleID: runtime.id) }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
            }
            HStack(spacing: 6) {
                Image(systemName: "sun.min").foregroundStyle(.secondary)
                Slider(value: sliderValue, in: 0...100) { editing in
                    if !editing { dragValue = nil }
                }
                Image(systemName: "sun.max").foregroundStyle(.secondary)
                Text(runtime.snapshot.brightness.map { "\($0)%" } ?? "–")
                    .monospacedDigit()
                    .frame(width: 38, alignment: .trailing)
            }
            .disabled(runtime.snapshot.brightness == nil)
            Text(StatusText.line(for: runtime, hub: hub, mac: model.macSensorStatus))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if offersCalibration, let point = runtime.currentPoint {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Keep this brightness?").font(.caption).foregroundStyle(.secondary)
                    Button("Remember \(Int(point.brightness))% for \(StatusText.formatLux(point.lux)) lux") {
                        model.saveCurvePoint(ruleID: runtime.id)
                    }
                    .help("Adds this point to the curve and turns Auto back on")
                    if let factor = runtime.curveMatchFactor, abs(factor - 1) >= 0.02 {
                        Button(factor < 1
                            ? "Make the whole curve \(Int(((1 - factor) * 100).rounded()))% dimmer"
                            : "Make the whole curve \(Int(((factor - 1) * 100).rounded()))% brighter") {
                            model.scaleCurveToMatch(ruleID: runtime.id)
                        }
                        .help("Scales every point of the curve so it gives this brightness at this light, then turns Auto back on")
                    }
                }
                .controlSize(.small)
            }
        }
    }

    /// After a manual change turned Auto off, offer to teach the curve the brightness chosen.
    private var offersCalibration: Bool {
        runtime.snapshot.phase == .disabled && runtime.snapshot.changedByHand
    }

    private var sliderValue: Binding<Double> {
        Binding(
            get: { dragValue ?? Double(runtime.snapshot.brightness ?? 0) },
            set: { value in
                dragValue = value
                runtime.userSet(Int(value.rounded()))
            }
        )
    }
}
