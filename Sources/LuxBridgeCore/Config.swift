import Foundation

/// Identifies a monitor across reconnects by the vendor, model and serial numbers from its EDID.
/// The name is only for display and is ignored when comparing.
public struct DisplayIdentity: Codable, Hashable, Sendable {
    public var vendor: UInt32
    public var model: UInt32
    public var serial: UInt32
    public var name: String

    public init(vendor: UInt32, model: UInt32, serial: UInt32, name: String) {
        self.vendor = vendor
        self.model = model
        self.serial = serial
        self.name = name
    }

    public static func == (lhs: DisplayIdentity, rhs: DisplayIdentity) -> Bool {
        lhs.vendor == rhs.vendor && lhs.model == rhs.model && lhs.serial == rhs.serial
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(vendor)
        hasher.combine(model)
        hasher.combine(serial)
    }
}

public enum LightSourceKind: String, Codable, CaseIterable, Sendable {
    /// The Mac's built-in ambient light sensor, usable while the lid is open.
    case macSensor
    /// A Home Assistant entity reporting lux, or a percentage used as the brightness.
    case homeAssistant
}

/// How readily a display follows changes in the light; see `Stability`.
public enum Sensitivity: String, Codable, CaseIterable, Sendable {
    case high
    case normal
    case low

    public var stability: Stability {
        switch self {
        case .high: Stability(ratio: 1.15, dwell: 20, bigRatio: 1.6)
        case .normal: Stability(ratio: 1.3, dwell: 60, bigRatio: 2)
        case .low: Stability(ratio: 1.5, dwell: 180, bigRatio: 2.5)
        }
    }
}

/// One place to get room light from.
public struct LightSource: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var kind: LightSourceKind
    public var enabled: Bool
    /// The Home Assistant entity, for `.homeAssistant` sources.
    public var entityID: String
    /// Multiplies this source's lux before the curve. Sensors in different places (a window sill
    /// next to the room's light, a laptop bezel facing away from it) see different amounts of
    /// light in the same room; the gain lets them share one curve.
    public var gain: Double

    public init(
        id: UUID = UUID(),
        kind: LightSourceKind,
        enabled: Bool = true,
        entityID: String = "",
        gain: Double = 1
    ) {
        self.id = id
        self.kind = kind
        self.enabled = enabled
        self.entityID = entityID
        self.gain = gain
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decode(LightSourceKind.self, forKey: .kind)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        entityID = try c.decodeIfPresent(String.self, forKey: .entityID) ?? ""
        gain = try c.decodeIfPresent(Double.self, forKey: .gain) ?? 1
    }
}

/// One display and the light sources that drive it, in priority order.
public struct DisplayRule: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var display: DisplayIdentity?
    /// Tried in order. The first enabled source with a fresh reading drives the display.
    public var sources: [LightSource]
    /// Maps lux (after the source's gain) to brightness.
    public var curve: BrightnessCurve
    /// Automatic brightness. A manual change turns it off.
    public var enabled: Bool
    public var sensitivity: Sensitivity

    public static let defaultSources: [LightSource] = [
        LightSource(kind: .macSensor),
        LightSource(kind: .homeAssistant),
    ]

    public init(
        id: UUID = UUID(),
        display: DisplayIdentity? = nil,
        sources: [LightSource] = DisplayRule.defaultSources,
        curve: BrightnessCurve = .standard,
        enabled: Bool = true,
        sensitivity: Sensitivity = .normal
    ) {
        self.id = id
        self.display = display
        self.sources = sources
        self.curve = curve
        self.enabled = enabled
        self.sensitivity = sensitivity
    }

    // Missing keys take their defaults, so settings saved by an older version still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = DisplayRule()
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? defaults.id
        display = try c.decodeIfPresent(DisplayIdentity.self, forKey: .display)
        sources = try c.decodeIfPresent([LightSource].self, forKey: .sources) ?? defaults.sources
        curve = try c.decodeIfPresent(BrightnessCurve.self, forKey: .curve) ?? defaults.curve
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
        sensitivity = try c.decodeIfPresent(Sensitivity.self, forKey: .sensitivity) ?? defaults.sensitivity
    }

    /// Home Assistant entities of the enabled sources.
    public var entityIDs: [String] {
        sources.filter { $0.enabled && $0.kind == .homeAssistant && !$0.entityID.isEmpty }.map(\.entityID)
    }

    public var usesMacSensor: Bool {
        sources.contains { $0.enabled && $0.kind == .macSensor }
    }
}

public struct AppConfig: Codable, Equatable, Sendable {
    /// Home Assistant addresses, tried in order.
    public var servers: [String]
    public var pollSeconds: Double
    public var rules: [DisplayRule]
    /// Shows the light and the brightness next to the menu bar icon.
    public var showReadingsInMenuBar: Bool

    public init(servers: [String] = [], pollSeconds: Double = 2, rules: [DisplayRule] = [], showReadingsInMenuBar: Bool = true) {
        self.servers = servers
        self.pollSeconds = pollSeconds
        self.rules = rules
        self.showReadingsInMenuBar = showReadingsInMenuBar
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppConfig()
        servers = try c.decodeIfPresent([String].self, forKey: .servers) ?? defaults.servers
        pollSeconds = try c.decodeIfPresent(Double.self, forKey: .pollSeconds) ?? defaults.pollSeconds
        rules = try c.decodeIfPresent([DisplayRule].self, forKey: .rules) ?? defaults.rules
        showReadingsInMenuBar = try c.decodeIfPresent(Bool.self, forKey: .showReadingsInMenuBar) ?? defaults.showReadingsInMenuBar
    }

    public var serverURLs: [URL] {
        servers.compactMap(HomeAssistantClient.serverURL(from:))
    }
}
