import Foundation

/// An entity's state from the Home Assistant REST API (`GET /api/states/<entity_id>`).
public struct HAEntityState: Decodable, Equatable, Identifiable, Sendable {
    public struct Attributes: Decodable, Equatable, Sendable {
        public var unit: String?
        public var deviceClass: String?
        public var friendlyName: String?

        enum CodingKeys: String, CodingKey {
            case unit = "unit_of_measurement"
            case deviceClass = "device_class"
            case friendlyName = "friendly_name"
        }

        public init(unit: String? = nil, deviceClass: String? = nil, friendlyName: String? = nil) {
            self.unit = unit
            self.deviceClass = deviceClass
            self.friendlyName = friendlyName
        }

        // Attributes are free-form, so a key of an unexpected type is skipped, not fatal.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            unit = try? c.decodeIfPresent(String.self, forKey: .unit)
            deviceClass = try? c.decodeIfPresent(String.self, forKey: .deviceClass)
            friendlyName = try? c.decodeIfPresent(String.self, forKey: .friendlyName)
        }
    }

    public var entityID: String
    public var state: String
    public var attributes: Attributes

    enum CodingKeys: String, CodingKey {
        case entityID = "entity_id"
        case state
        case attributes
    }

    public init(entityID: String, state: String, attributes: Attributes = Attributes()) {
        self.entityID = entityID
        self.state = state
        self.attributes = attributes
    }

    public var id: String { entityID }

    /// The state as a number, or nil for "unavailable", "unknown" and other text.
    public var number: Double? {
        guard let value = Double(state), value.isFinite else { return nil }
        return value
    }

    public var name: String { attributes.friendlyName ?? entityID }

    public var isIlluminance: Bool {
        attributes.deviceClass == "illuminance" || ["lx", "lux"].contains(attributes.unit?.lowercased() ?? "")
    }

    public var isPercent: Bool { attributes.unit == "%" }
}

public struct HAServerInfo: Decodable, Sendable {
    public var locationName: String?
    public var version: String?

    enum CodingKeys: String, CodingKey {
        case locationName = "location_name"
        case version
    }
}

public enum HAError: LocalizedError, Equatable, Sendable {
    case notConfigured
    case unauthorized
    case entityNotFound(String)
    case http(Int)
    case badResponse
    case localNetworkDenied
    case unreachable(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Home Assistant is not set up"
        case .unauthorized:
            "Home Assistant rejected the access token"
        case .entityNotFound(let entityID):
            "Home Assistant has no entity \(entityID)"
        case .http(let code):
            "Home Assistant answered with HTTP \(code)"
        case .badResponse:
            "The server's answer did not come from Home Assistant"
        case .localNetworkDenied:
            "macOS is blocking local network access. Allow LuxBridge in System Settings, Privacy & Security, Local Network"
        case .unreachable(let reason):
            "Can't reach Home Assistant (\(reason))"
        }
    }
}

/// A small REST client that tries each configured address in order, starting with the last one
/// that answered. Timeouts are short, since a reading that is seconds late is useless anyway.
public actor HomeAssistantClient {
    public private(set) var servers: [URL]
    private var token: String
    private var preferred = 0
    private var session: URLSession

    public init(servers: [URL] = [], token: String = "") {
        self.servers = servers
        self.token = token
        session = Self.makeSession()
    }

    public var isConfigured: Bool { !servers.isEmpty && !token.isEmpty }

    public func configure(servers: [URL], token: String) {
        self.servers = servers
        self.token = token
        preferred = 0
    }

    /// Drops pooled connections, which can hang for a full timeout after the network changes.
    public func resetConnections() {
        session.invalidateAndCancel()
        session = Self.makeSession()
    }

    public func state(of entityID: String) async throws -> HAEntityState {
        let (data, status) = try await get("api/states/\(entityID)")
        if status == 404 { throw HAError.entityNotFound(entityID) }
        return try Self.decode(HAEntityState.self, from: data)
    }

    public func states() async throws -> [HAEntityState] {
        let (data, status) = try await get("api/states")
        if status == 404 { throw HAError.badResponse }
        return try Self.decode([HAEntityState].self, from: data)
    }

    public func serverInfo() async throws -> HAServerInfo {
        let (data, status) = try await get("api/config")
        if status == 404 { throw HAError.badResponse }
        return try Self.decode(HAServerInfo.self, from: data)
    }

    /// Accepts what people type: a bare host, host:port, or a full URL, with or without /api.
    public static func serverURL(from text: String) -> URL? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "http://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        if text.hasSuffix("/api") { text.removeLast(4) }
        guard let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(), !host.isEmpty
        else { return nil }
        return url
    }

    // MARK: Private

    private func get(_ path: String) async throws -> (Data, Int) {
        guard isConfigured else { throw HAError.notConfigured }
        let servers = self.servers
        let start = preferred < servers.count ? preferred : 0
        let order = Array(servers.indices[start...]) + Array(servers.indices[..<start])
        var lastError = HAError.notConfigured
        for index in order {
            var request = URLRequest(url: servers[index].appendingPathComponent(path))
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let response: URLResponse
            let data: Data
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                lastError = Self.describe(error)
                continue
            }
            guard let http = response as? HTTPURLResponse else { throw HAError.badResponse }
            // This address answered, so the error (if any) is the server's, not the network's.
            preferred = index
            switch http.statusCode {
            case 200..<300, 404: return (data, http.statusCode)
            case 401, 403: throw HAError.unauthorized
            default: throw HAError.http(http.statusCode)
            }
        }
        throw lastError
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw HAError.badResponse
        }
    }

    static func describe(_ error: Error) -> HAError {
        if String(describing: error).contains("Local network prohibited") { return .localNetworkDenied }
        guard let urlError = error as? URLError else { return .unreachable(error.localizedDescription) }
        switch urlError.code {
        case .timedOut: return .unreachable("timed out")
        case .cannotFindHost, .dnsLookupFailed: return .unreachable("address not found")
        case .cannotConnectToHost: return .unreachable("connection refused")
        case .notConnectedToInternet, .networkConnectionLost: return .unreachable("no network")
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
            return .unreachable("secure connection failed")
        case .cancelled: return .unreachable("cancelled")
        default: return .unreachable(urlError.localizedDescription)
        }
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 6
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }
}
