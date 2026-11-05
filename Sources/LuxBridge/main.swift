import AppKit

// `LuxBridge list|get|set|config|token|help` runs a one-shot command. Anything else starts the app.
if let status = CLI.run(Array(CommandLine.arguments.dropFirst())) {
    exit(status)
}
MainActor.assumeIsolated {
    let delegate = AppDelegate()
    NSApplication.shared.delegate = delegate
    withExtendedLifetime(delegate) { NSApplication.shared.run() }
}
