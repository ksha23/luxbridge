import AppKit
import DDCKit
import LuxBridgeCore
import SystemSensors

enum MacSensorStatus: Equatable {
    case notPresent
    case lidClosed
    case reading(Double)
}

/// Ties the pieces together: settings, the display scan, the sensor hub and one runtime per rule.
/// A 0.2 s tick drives everything, so there is a single place where time moves forward.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var config: AppConfig
    @Published private(set) var displays: [ExternalDisplay] = []
    @Published private(set) var runtimes: [RuleRuntime] = []
    @Published private(set) var hasToken: Bool
    @Published private(set) var menuBarSymbol = "sun.min"
    /// The light and the brightness shown next to the icon, such as "77 lx · 18%".
    @Published private(set) var menuBarText: String?
    @Published private(set) var macSensorStatus = MacSensorStatus.notPresent

    let hub: SensorHub
    private let lightSensor = AmbientLightSensor.open()
    private var nextMacSensorRead = Date.distantPast
    private let client: HomeAssistantClient
    private var events: SystemEvents?
    private var nextScan = Date.distantPast
    private var systemAsleep = false
    private var networkTask: Task<Void, Never>?

    private static let tickInterval: Duration = .milliseconds(200)
    /// Faster while a display is fading, so its one-percent steps are evenly spaced.
    private static let fadeTickInterval: Duration = .milliseconds(50)
    private static let scanInterval: TimeInterval = 10

    init() {
        let config = ConfigStore.load()
        let token = Keychain.read() ?? ""
        self.config = config
        hasToken = !token.isEmpty
        client = HomeAssistantClient(servers: config.serverURLs, token: token)
        hub = SensorHub(client: client, pollSeconds: config.pollSeconds)
        hub.isConfigured = !config.serverURLs.isEmpty && !token.isEmpty
        hub.onState = { [weak self] state in
            self?.runtimes.forEach { $0.homeAssistantState(state) }
        }
        hub.onEntityMissing = { [weak self] entity in
            self?.runtimes.forEach { $0.homeAssistantEntityMissing(entity) }
        }
        syncRuntimes()
        events = SystemEvents(handlers: .init(
            displaysChanged: { [weak self] in self?.displaysChanged() },
            systemWillSleep: { [weak self] in self?.systemWillSleep() },
            systemDidWake: { [weak self] in self?.systemDidWake() },
            screensDidSleep: { [weak self] in self?.runtimes.forEach { $0.setDisplayAsleep(true) } },
            screensDidWake: { [weak self] in self?.screensDidWake() },
            networkChanged: { [weak self] in self?.networkChanged() }
        ))
        Task { [weak self] in
            while let self {
                self.tick()
                let fading = self.runtimes.contains { $0.snapshot.adjusting }
                try? await Task.sleep(for: fading ? Self.fadeTickInterval : Self.tickInterval)
            }
        }
    }

    // MARK: Settings

    func updateRule(_ rule: DisplayRule) {
        guard let index = config.rules.firstIndex(where: { $0.id == rule.id }), config.rules[index] != rule else { return }
        let displayChanged = config.rules[index].display != rule.display
        config.rules[index] = rule
        saveAndSync()
        if displayChanged { nextScan = .distantPast }
    }

    func setEnabled(_ enabled: Bool, ruleID: UUID) {
        guard var rule = config.rules.first(where: { $0.id == ruleID }) else { return }
        rule.enabled = enabled
        updateRule(rule)
    }

    /// Adds a rule for the first connected display that has none yet, copying the sources of the
    /// first rule since most people have the same sensors for every display.
    func addRule() -> UUID {
        let taken = Set(config.rules.compactMap(\.display))
        let display = displays.map(\.identity).first { !taken.contains($0) }
        let sources = config.rules.first?.sources.map { LightSource(kind: $0.kind, enabled: $0.enabled, entityID: $0.entityID, gain: $0.gain) }
        let rule = DisplayRule(display: display, sources: sources ?? DisplayRule.defaultSources)
        config.rules.append(rule)
        saveAndSync()
        nextScan = .distantPast
        return rule.id
    }

    func removeRule(id: UUID) {
        config.rules.removeAll { $0.id == id }
        saveAndSync()
    }

    func setServers(_ servers: [String]) {
        config.servers = servers.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        saveAndSync()
        reconfigureClient()
    }

    func setToken(_ token: String) {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        hasToken = Keychain.save(token)
        reconfigureClient(token: token)
    }

    func setShowReadingsInMenuBar(_ show: Bool) {
        config.showReadingsInMenuBar = show
        saveAndSync()
    }

    func setPollSeconds(_ seconds: Double) {
        config.pollSeconds = min(max(seconds, 1), 60)
        hub.pollSeconds = config.pollSeconds
        saveAndSync()
    }

    /// Adds the current lux and brightness of a rule to its curve, then turns Auto back on.
    func saveCurvePoint(ruleID: UUID) {
        guard let runtime = runtimes.first(where: { $0.id == ruleID }), let point = runtime.currentPoint,
              var rule = config.rules.first(where: { $0.id == ruleID })
        else { return }
        rule.curve = rule.curve.setting(point)
        rule.enabled = true
        updateRule(rule)
    }

    /// Scales a rule's whole curve so it gives the brightness the user chose at the current light,
    /// then turns Auto back on.
    func scaleCurveToMatch(ruleID: UUID) {
        guard let runtime = runtimes.first(where: { $0.id == ruleID }), let factor = runtime.curveMatchFactor,
              var rule = config.rules.first(where: { $0.id == ruleID })
        else { return }
        rule.curve = rule.curve.scaled(by: factor)
        rule.enabled = true
        updateRule(rule)
    }

    /// The source another source's gain can be matched to: the first other source with a reading.
    func matchReference(ruleID: UUID, sourceID: UUID) -> LightSource? {
        guard let runtime = runtimes.first(where: { $0.id == ruleID }), runtime.snapshot.rawLuxBySource[sourceID] != nil,
              let rule = config.rules.first(where: { $0.id == ruleID })
        else { return nil }
        return rule.sources.first { $0.id != sourceID && $0.enabled && runtime.snapshot.rawLuxBySource[$0.id] != nil }
    }

    /// Sets a source's gain so that, right now, it reads the same lux as `matchReference`.
    func matchGain(ruleID: UUID, sourceID: UUID) {
        guard let reference = matchReference(ruleID: ruleID, sourceID: sourceID),
              let runtime = runtimes.first(where: { $0.id == ruleID }),
              let raw = runtime.snapshot.rawLuxBySource[sourceID], raw >= 0.5,
              let referenceRaw = runtime.snapshot.rawLuxBySource[reference.id],
              var rule = config.rules.first(where: { $0.id == ruleID }),
              let index = rule.sources.firstIndex(where: { $0.id == sourceID })
        else { return }
        rule.sources[index].gain = ((referenceRaw * reference.gain / raw) * 100).rounded() / 100
        updateRule(rule)
    }

    func testConnection() async -> Result<String, Error> {
        guard !config.serverURLs.isEmpty else {
            return .failure(config.servers.isEmpty ? HAError.notConfigured : HAError.unreachable("the address is not valid"))
        }
        do {
            let info = try await client.serverInfo()
            let place = info.locationName.map { " \"\($0)\"" } ?? ""
            let version = info.version.map { " \($0)" } ?? ""
            return .success("Connected to\(place), Home Assistant\(version)")
        } catch {
            return .failure(error)
        }
    }

    func sensorChoices() async throws -> [HAEntityState] {
        try await client.states()
            .filter { $0.entityID.hasPrefix("sensor.") || $0.entityID.hasPrefix("input_number.") }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: Tick

    private func tick() {
        let now = Date()
        guard !systemAsleep else { return }
        if now >= nextScan { scanDisplays(now: now) }
        if now >= nextMacSensorRead { readMacSensor(now: now) }
        hub.tick(now: now, wanted: Set(runtimes.flatMap(\.wantedEntities)))
        for runtime in runtimes { runtime.tick(now: now) }
        let symbol = computeMenuBarSymbol()
        if symbol != menuBarSymbol { menuBarSymbol = symbol }
        let text = config.showReadingsInMenuBar ? computeMenuBarText() : nil
        if text != menuBarText { menuBarText = text }
    }

    private func scanDisplays(now: Date) {
        let channels = displays.compactMap(\.channel)
        let scanned = DisplayScanner.scan(reusing: channels)
        if scanned != displays { displays = scanned }
        nextScan = now.addingTimeInterval(Self.scanInterval)
        for runtime in runtimes { attach(runtime) }
    }

    /// Reads the built-in light sensor once a second while some rule uses it. A closed lid covers
    /// the sensor, so its reading (0) is not passed on.
    private func readMacSensor(now: Date) {
        nextMacSensorRead = now.addingTimeInterval(1)
        guard config.rules.contains(where: \.usesMacSensor) else { return }
        let lux: Double?
        if lightSensor == nil {
            lux = nil
            macSensorStatus = .notPresent
        } else if AmbientLightSensor.isLidClosed {
            lux = nil
            macSensorStatus = .lidClosed
        } else {
            lux = lightSensor?.lux()
            if let lux, macSensorStatus != .reading(lux) { macSensorStatus = .reading(lux) }
        }
        for runtime in runtimes where runtime.wantsMacSensor { runtime.macSensor(lux) }
    }

    private func attach(_ runtime: RuleRuntime) {
        let match = runtime.rule.display.flatMap { identity in displays.first { $0.identity == identity } }
        let wasConnected = runtime.display != nil
        runtime.attach(match)
        if match != nil, !wasConnected { runtime.rule.entityIDs.forEach(hub.pollSoon) }
    }

    /// The first connected display's light and brightness. The light is left out while no source
    /// has a reading, and a source that reports a percentage has no lux to show.
    private func computeMenuBarText() -> String? {
        guard let snapshot = runtimes.first(where: { $0.display != nil && $0.snapshot.brightness != nil })?.snapshot,
              let brightness = snapshot.brightness
        else { return nil }
        guard let lux = snapshot.lux else { return "\(brightness)%" }
        return "\(StatusText.formatLux(lux)) lx · \(brightness)%"
    }

    private func computeMenuBarSymbol() -> String {
        let active = runtimes.filter { $0.display != nil }
        if active.contains(where: { $0.ddcProblem != nil }) { return "exclamationmark.triangle" }
        if active.contains(where: { $0.snapshot.phase == .waitingForSensor }), case .failing = hub.status {
            return "exclamationmark.triangle"
        }
        if active.contains(where: { $0.snapshot.phase == .following }) { return "sun.max" }
        return "sun.min"
    }

    // MARK: System events

    private func displaysChanged() {
        // DDC services register a moment after the display does, so look twice.
        nextScan = min(nextScan, Date().addingTimeInterval(1.5))
        Task {
            try? await Task.sleep(for: .seconds(5))
            nextScan = .distantPast
        }
    }

    private func systemWillSleep() {
        systemAsleep = true
        runtimes.forEach { $0.setDisplayAsleep(true) }
    }

    private func systemDidWake() {
        Task {
            try? await Task.sleep(for: .seconds(3))
            systemAsleep = false
            nextScan = .distantPast
            runtimes.forEach { $0.setDisplayAsleep(false) }
            networkChanged()
        }
    }

    private func screensDidWake() {
        Task {
            try? await Task.sleep(for: .seconds(2))
            runtimes.forEach { $0.setDisplayAsleep(false) }
            nextScan = .distantPast
        }
    }

    private func networkChanged() {
        networkTask?.cancel()
        networkTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await client.resetConnections()
            hub.pollAllSoon()
        }
    }

    // MARK: Private

    private func saveAndSync() {
        ConfigStore.save(config)
        syncRuntimes()
    }

    private func syncRuntimes() {
        var next: [RuleRuntime] = []
        for rule in config.rules {
            if let existing = runtimes.first(where: { $0.id == rule.id }) {
                let displayChanged = existing.rule.display != rule.display
                existing.update(rule)
                if displayChanged { existing.attach(nil) }
                next.append(existing)
            } else {
                let runtime = RuleRuntime(rule: rule)
                runtime.onDisplayTrouble = { [weak self] in self?.nextScan = .distantPast }
                runtime.onManualChange = { [weak self] in self?.setEnabled(false, ruleID: rule.id) }
                next.append(runtime)
            }
        }
        runtimes = next
        for runtime in runtimes where runtime.display == nil { attach(runtime) }
    }

    private func reconfigureClient(token: String? = nil) {
        let token = token ?? Keychain.read() ?? ""
        let servers = config.serverURLs
        hub.isConfigured = !servers.isEmpty && !token.isEmpty
        Task {
            await client.configure(servers: servers, token: token)
            await client.resetConnections()
            hub.pollAllSoon()
        }
    }
}

extension ExternalDisplay {
    var identity: DisplayIdentity {
        DisplayIdentity(vendor: vendor, model: model, serial: serial, name: name)
    }
}
