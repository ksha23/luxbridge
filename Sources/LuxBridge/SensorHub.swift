import Foundation
import LuxBridgeCore

/// Polls the Home Assistant entities that some connected display needs, and nothing else.
/// Failures back off from 2 s to 30 s. A network change or wake polls again at once.
@MainActor
final class SensorHub: ObservableObject {
    enum Status: Equatable {
        case idle
        case notConfigured
        case connected
        case failing(HAError)
    }

    @Published private(set) var status = Status.idle
    @Published private(set) var states: [String: HAEntityState] = [:]
    @Published private(set) var entityErrors: [String: HAError] = [:]

    var onState: ((HAEntityState) -> Void)?
    var onEntityMissing: ((String) -> Void)?
    var pollSeconds: TimeInterval
    var isConfigured = false

    private let client: HomeAssistantClient
    private var due: [String: Date] = [:]
    private var inFlight: Set<String> = []
    private var backoff = Backoff(base: 2, cap: 30)

    init(client: HomeAssistantClient, pollSeconds: TimeInterval) {
        self.client = client
        self.pollSeconds = pollSeconds
    }

    func tick(now: Date, wanted: Set<String>) {
        guard !wanted.isEmpty else {
            if status != .idle, inFlight.isEmpty { status = .idle }
            return
        }
        guard isConfigured else {
            status = .notConfigured
            return
        }
        for entity in wanted where !inFlight.contains(entity) && now >= due[entity, default: .distantPast] {
            poll(entity)
        }
    }

    func pollSoon(_ entity: String) {
        due[entity] = nil
    }

    func pollAllSoon() {
        due.removeAll()
        backoff.reset()
    }

    private func poll(_ entity: String) {
        inFlight.insert(entity)
        Task {
            defer { inFlight.remove(entity) }
            do {
                let state = try await client.state(of: entity)
                backoff.reset()
                status = .connected
                states[entity] = state
                entityErrors[entity] = nil
                due[entity] = Date().addingTimeInterval(pollSeconds)
                onState?(state)
            } catch let error as HAError {
                failed(entity, error)
            } catch {
                failed(entity, .unreachable(error.localizedDescription))
            }
        }
    }

    private func failed(_ entity: String, _ error: HAError) {
        if case .entityNotFound = error {
            // The server is fine; this entity is wrong. Check now and then in case it appears.
            status = .connected
            entityErrors[entity] = error
            states[entity] = nil
            due[entity] = Date().addingTimeInterval(30)
            onEntityMissing?(entity)
        } else {
            status = .failing(error)
            due[entity] = Date().addingTimeInterval(backoff.nextDelay())
        }
    }
}
