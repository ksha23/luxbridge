import AppKit
import Network

/// Forwards the system events that matter for DDC and networking to the app model.
@MainActor
final class SystemEvents {
    struct Handlers {
        var displaysChanged: @MainActor () -> Void
        var systemWillSleep: @MainActor () -> Void
        var systemDidWake: @MainActor () -> Void
        var screensDidSleep: @MainActor () -> Void
        var screensDidWake: @MainActor () -> Void
        var networkChanged: @MainActor () -> Void
    }

    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private let pathMonitor = NWPathMonitor()

    init(handlers: Handlers) {
        let workspace = NSWorkspace.shared.notificationCenter
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification, handlers.displaysChanged)
        observe(workspace, NSWorkspace.willSleepNotification, handlers.systemWillSleep)
        observe(workspace, NSWorkspace.didWakeNotification, handlers.systemDidWake)
        observe(workspace, NSWorkspace.screensDidSleepNotification, handlers.screensDidSleep)
        observe(workspace, NSWorkspace.screensDidWakeNotification, handlers.screensDidWake)

        let networkChanged = handlers.networkChanged
        pathMonitor.pathUpdateHandler = { _ in
            Task { @MainActor in networkChanged() }
        }
        pathMonitor.start(queue: DispatchQueue(label: "LuxBridge.network"))
    }

    deinit {
        pathMonitor.cancel()
        for (center, observer) in observers { center.removeObserver(observer) }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ action: @escaping @MainActor () -> Void) {
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { action() }
        }
        observers.append((center, observer))
    }
}
