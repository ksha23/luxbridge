import Charts
import LuxBridgeCore
import SwiftUI

/// Edits a curve as a chart and as a table of numbers. Every edit (dragging, adding or deleting a
/// point, typing a number, Dimmer, Brighter, Use Default) changes a pending copy that the chart
/// shows next to the saved curve. The display keeps using the saved curve until Apply; Reset
/// discards the pending changes.
struct CurveEditorView: View {
    /// The saved curve, which the display uses.
    @Binding var curve: BrightnessCurve
    var currentLux: Double?

    /// Changes not yet applied, as the table shows them: in the order they were typed, not yet
    /// sorted or cleaned up, so a row does not jump while its lux is being typed. nil when there
    /// are none.
    @State private var pending: [CurvePoint]?
    /// The points while a drag is in progress.
    @State private var draft: [CurvePoint]?
    @State private var dragIndex: Int?
    @State private var selected: Int?
    @State private var hovered: Int?
    @FocusState private var focusedField: FieldID?

    /// The curve as edited.
    private var edited: BrightnessCurve { pending.map { BrightnessCurve(points: $0) } ?? curve }
    private var rows: [CurvePoint] { pending ?? curve.points }
    /// The points on the chart, sorted by lux.
    private var points: [CurvePoint] { draft ?? edited.points }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            chart
            HStack {
                Button { setPending(edited.scaled(by: 0.9).points) } label: { Label("Dimmer", systemImage: "sun.min") }
                    .help("Makes the whole curve 10% dimmer")
                Button { setPending(edited.scaled(by: 1 / 0.9).points) } label: { Label("Brighter", systemImage: "sun.max") }
                    .help("Makes the whole curve 10% brighter")
                Spacer()
                Button("Delete Point", action: deleteSelected)
                    .disabled(selected == nil || points.count <= 1)
                Button("Use Default") {
                    selected = nil
                    setPending(BrightnessCurve.standard.points)
                }
                .help("Replaces the curve with the default one")
            }
            Text("Drag a point to move it. Double-click the chart to add one. Click a point and press Delete to remove it.")
                .font(.caption)
                .foregroundStyle(.secondary)
            numbers
            Divider()
            HStack {
                Text(pending == nil ? "The display follows this curve." : "Not applied yet. The display follows the saved curve, shown dashed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reset", action: reset)
                    .disabled(pending == nil)
                    .help("Discards the changes")
                Button("Apply", action: apply)
                    .buttonStyle(.borderedProminent)
                    .disabled(pending == nil)
            }
        }
    }

    // MARK: Pending changes

    private func setPending(_ points: [CurvePoint]) {
        pending = BrightnessCurve(points: points) == curve ? nil : points
    }

    private func apply() {
        curve = edited
        pending = nil
        focusedField = nil
    }

    private func reset() {
        pending = nil
        selected = nil
        focusedField = nil
    }

    // MARK: Chart

    private var chart: some View {
        let domain = luxDomain
        let shown = BrightnessCurve(points: points)
        return Chart {
            if pending != nil {
                ForEach(samples(of: curve, in: domain), id: \.lux) { point in
                    LineMark(x: .value("Lux", point.lux), y: .value("Brightness", point.brightness), series: .value("Curve", "Saved"))
                        .foregroundStyle(.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
            }
            ForEach(samples(of: shown, in: domain), id: \.lux) { point in
                LineMark(x: .value("Lux", point.lux), y: .value("Brightness", point.brightness), series: .value("Curve", "Edited"))
            }
            if let currentLux {
                let lux = min(max(currentLux, domain.lowerBound), domain.upperBound)
                RuleMark(x: .value("Now", lux))
                    .foregroundStyle(.orange)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, spacing: 2) {
                        Text("now, \(StatusText.formatLux(currentLux)) lux").font(.caption2).foregroundStyle(.orange)
                    }
            }
            ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                let active = index == selected || index == hovered || index == dragIndex
                PointMark(x: .value("Lux", point.lux), y: .value("Brightness", point.brightness))
                    .symbolSize(active ? 150 : 70)
                    .foregroundStyle(index == selected ? Color.orange : Color.accentColor)
                    .annotation(position: .top, spacing: 6, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        Text(Self.pointLabel(point))
                            .font(active ? .caption.weight(.semibold) : .caption2)
                            .foregroundStyle(active ? AnyShapeStyle(index == selected ? Color.orange : Color.primary) : AnyShapeStyle(.secondary))
                            .monospacedDigit()
                    }
            }
        }
        .chartXScale(domain: domain, type: .log)
        .chartYScale(domain: 0...100)
        .chartXAxis {
            AxisMarks(values: decades(in: domain)) { value in
                AxisGridLine()
                // Labels at the ends of the axis sit inside it rather than being cut off.
                let lux = value.as(Double.self) ?? 0
                AxisValueLabel(anchor: lux >= domain.upperBound ? .topTrailing : lux <= domain.lowerBound ? .topLeading : .top) {
                    Text(Self.luxLabel(lux))
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 25, 50, 75, 100]) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let percent = value.as(Int.self) { Text("\(percent)%") }
                }
            }
        }
        .chartXAxisLabel("Room light, lux", alignment: .center)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { drag($0, proxy, geometry) }
                            .onEnded { _ in endDrag() }
                    )
                    .simultaneousGesture(
                        SpatialTapGesture(count: 2).onEnded { addPoint(at: $0.location, proxy, geometry) }
                    )
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location): hovered = nearestPoint(to: location, proxy, geometry)
                        case .ended: hovered = nil
                        }
                    }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .onDeleteCommand(perform: deleteSelected)
        .frame(height: 240)
        .padding(.top, 16)
    }

    private func drag(_ value: DragGesture.Value, _ proxy: ChartProxy, _ geometry: GeometryProxy) {
        guard let plot = proxy.plotFrame.map({ geometry[$0] }) else { return }
        if dragIndex == nil {
            guard let nearest = nearestPoint(to: value.startLocation, proxy, geometry) else {
                selected = nil
                return
            }
            dragIndex = nearest
            selected = nearest
            draft = edited.points
        }
        let location = CGPoint(x: value.location.x - plot.minX, y: value.location.y - plot.minY)
        guard let index = dragIndex, var moved = draft, moved.indices.contains(index),
              let (lux, brightness) = proxy.value(at: location, as: (Double, Double).self)
        else { return }
        // A point stays between its neighbours, so dragging never reorders the curve.
        let lower = index > 0 ? moved[index - 1].lux * 1.05 : luxDomain.lowerBound
        let upper = index < moved.count - 1 ? moved[index + 1].lux / 1.05 : luxDomain.upperBound
        moved[index] = CurvePoint(lux: Self.niceLux(min(max(lux, lower), upper)), brightness: min(max(brightness, 0), 100).rounded())
        draft = moved
    }

    private func endDrag() {
        if let draft, draft != edited.points { setPending(draft) }
        draft = nil
        dragIndex = nil
    }

    private func addPoint(at location: CGPoint, _ proxy: ChartProxy, _ geometry: GeometryProxy) {
        guard let plot = proxy.plotFrame.map({ geometry[$0] }),
              let (lux, brightness) = proxy.value(at: CGPoint(x: location.x - plot.minX, y: location.y - plot.minY), as: (Double, Double).self),
              lux > 0
        else { return }
        let point = CurvePoint(lux: Self.niceLux(lux), brightness: min(max(brightness, 0), 100).rounded())
        setPending(edited.points + [point])
        selected = edited.points.firstIndex { $0.lux == point.lux }
    }

    private func deleteSelected() {
        guard let selected, edited.points.indices.contains(selected), edited.points.count > 1 else { return }
        var remaining = edited.points
        remaining.remove(at: selected)
        setPending(remaining)
        self.selected = nil
    }

    /// The point within 14 pixels of `location` (in the overlay's coordinates), if any.
    private func nearestPoint(to location: CGPoint, _ proxy: ChartProxy, _ geometry: GeometryProxy) -> Int? {
        guard let plot = proxy.plotFrame.map({ geometry[$0] }) else { return nil }
        let inPlot = CGPoint(x: location.x - plot.minX, y: location.y - plot.minY)
        let distances = points.indices.map { (index: $0, distance: distance(points[$0], inPlot, proxy)) }
        guard let nearest = distances.min(by: { $0.distance < $1.distance }), nearest.distance < 14 else { return nil }
        return nearest.index
    }

    private func distance(_ point: CurvePoint, _ location: CGPoint, _ proxy: ChartProxy) -> CGFloat {
        guard let x = proxy.position(forX: point.lux), let y = proxy.position(forY: point.brightness) else { return .infinity }
        return hypot(x - location.x, y - location.y)
    }

    // MARK: Numbers

    private var numbers: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
            GridRow {
                Text("Room light").font(.caption).foregroundStyle(.secondary).gridCellColumns(2)
                Text("Brightness").font(.caption).foregroundStyle(.secondary).gridCellColumns(2)
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { index, point in
                GridRow {
                    NumberField(value: point.lux, width: 80, focus: $focusedField, id: FieldID(row: index, column: 0)) {
                        setRow(index, \.lux, to: $0)
                    }
                    Text("lux").foregroundStyle(.secondary)
                    NumberField(value: point.brightness, width: 56, focus: $focusedField, id: FieldID(row: index, column: 1)) {
                        setRow(index, \.brightness, to: $0)
                    }
                    Text("%").foregroundStyle(.secondary)
                    Button {
                        var remaining = rows
                        remaining.remove(at: index)
                        setPending(remaining)
                        selected = nil
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(rows.count <= 1)
                    .help("Remove this point")
                }
            }
            GridRow {
                Button(action: addRow) { Label("Add Point", systemImage: "plus.circle") }
                    .buttonStyle(.borderless)
                    .gridCellColumns(5)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func setRow(_ index: Int, _ keyPath: WritableKeyPath<CurvePoint, Double>, to value: Double) {
        guard rows.indices.contains(index) else { return }
        var changed = rows
        changed[index][keyPath: keyPath] = value
        setPending(changed)
    }

    /// Adds a point on the curve, in the middle of its widest gap, so the curve does not change
    /// until its numbers are edited.
    private func addRow() {
        let sorted = edited.points
        let gaps = zip(sorted, sorted.dropFirst()).map { (low: $0.lux, high: $1.lux) }
        let lux: Double
        if let widest = gaps.max(by: { $0.high / $0.low < $1.high / $1.low }) {
            lux = Self.niceLux(sqrt(widest.low * widest.high))
        } else {
            lux = Self.niceLux((sorted.first?.lux ?? 50) * 2)
        }
        setPending(rows + [CurvePoint(lux: lux, brightness: edited.brightness(forLux: lux).rounded())])
    }

    // MARK: Axis helpers

    private var luxDomain: ClosedRange<Double> {
        let all = edited.points + curve.points
        let low = min(1, (all.map(\.lux).min() ?? 1) / 2)
        let high = max(10_000, (all.map(\.lux).max() ?? 10_000) * 2)
        return low...high
    }

    private func decades(in domain: ClosedRange<Double>) -> [Double] {
        let first = Int(floor(log10(domain.lowerBound))), last = Int(ceil(log10(domain.upperBound)))
        return (first...last).map { pow(10, Double($0)) }.filter { domain.contains($0) }
    }

    private func samples(of curve: BrightnessCurve, in domain: ClosedRange<Double>) -> [CurvePoint] {
        let steps = 120
        let low = log(domain.lowerBound), high = log(domain.upperBound)
        return (0...steps).map { step in
            let lux = exp(low + (high - low) * Double(step) / Double(steps))
            return CurvePoint(lux: lux, brightness: curve.brightness(forLux: lux))
        }
    }

    /// A point's label on the chart, such as "36 lx · 10%".
    static func pointLabel(_ point: CurvePoint) -> String {
        let lux = point.lux >= 1000 ? String(format: "%gk", (point.lux / 100).rounded() / 10) : StatusText.formatLux(point.lux)
        return "\(lux) lx · \(Int(point.brightness.rounded()))%"
    }

    static func luxLabel(_ lux: Double) -> String {
        lux >= 1000 ? "\(Int(lux / 1000))k" : lux >= 1 ? "\(Int(lux))" : String(format: "%.1f", lux)
    }

    /// Rounds lux to a number worth typing: 0.1 below 10, whole numbers below 100, two significant
    /// digits above.
    static func niceLux(_ lux: Double) -> Double {
        if lux < 10 { return max((lux * 10).rounded() / 10, 0.1) }
        if lux < 100 { return lux.rounded() }
        let magnitude = pow(10, floor(log10(lux)) - 1)
        return (lux / magnitude).rounded() * magnitude
    }
}

/// A cell of the numbers table.
private struct FieldID: Hashable {
    var row: Int
    var column: Int
}

/// A boxed number field that reports each value as it is typed, so Apply never misses one that
/// has not been confirmed with Return. The grouped form style would otherwise draw a field as
/// plain text.
private struct NumberField: View {
    var value: Double
    var width: CGFloat
    var focus: FocusState<FieldID?>.Binding
    var id: FieldID
    var onChange: (Double) -> Void

    @State private var text = ""

    private var isFocused: Bool { focus.wrappedValue == id }

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.roundedBorder)
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .frame(width: width)
            .focused(focus, equals: id)
            .onAppear { text = Self.format(value) }
            // Changed elsewhere (the chart, Reset): show it, unless this field is being typed in.
            .onChange(of: value) { _, new in
                if !isFocused { text = Self.format(new) }
            }
            .onChange(of: isFocused) { _, focused in
                if !focused { text = Self.format(value) }
            }
            .onChange(of: text) { _, new in
                let cleaned = new.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
                if let number = Double(cleaned), number.isFinite, number != value { onChange(number) }
            }
    }

    static func format(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : String(format: "%g", value)
    }
}
