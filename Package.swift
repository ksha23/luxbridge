// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "LuxBridge",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure logic: curve, smoothing, the per-display decision engine, Home Assistant client.
        .target(name: "LuxBridgeCore"),
        // DDC/CI access to external displays on Apple Silicon.
        .target(name: "DDCKit"),
        // The Mac's own ambient light sensor and lid state.
        .target(name: "SystemSensors"),
        // The menu bar app (and a small command line for diagnostics).
        .executableTarget(name: "LuxBridge", dependencies: ["LuxBridgeCore", "DDCKit", "SystemSensors"]),
        .testTarget(name: "LuxBridgeTests", dependencies: ["LuxBridgeCore", "DDCKit"]),
    ]
)
