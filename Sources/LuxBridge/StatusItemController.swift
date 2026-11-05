import AppKit
import Combine
import SwiftUI

/// The menu bar item and the panel it opens.
///
/// The panel is an AppKit panel rather than SwiftUI's MenuBarExtra, whose window grows with its
/// content but never shrinks. Here the content is a hosting view pinned to the panel's edges, so
/// Auto Layout keeps the panel exactly as tall as the content, growing and shrinking it with the
/// top edge fixed under the menu bar. It is a non-activating panel, like the system's own menu bar
/// panels: it takes keyboard focus when it opens without making LuxBridge the active app, so the
/// frontmost app keeps its menu bar. (A popover cannot do that; it opens unfocused unless the app
/// is activated.)
@MainActor
final class StatusItemController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let panel = MenuPanel()
    private var monitors: [Any] = []
    private var subscription: AnyCancellable?

    /// Space between the menu bar and the panel, as the system leaves for its own panels.
    private static let gap: CGFloat = 6
    /// The panel is kept at least this far from the screen's edges.
    private static let margin: CGFloat = 8

    init(model: AppModel, openSettings: @escaping () -> Void) {
        super.init()
        panel.onCancel = { [weak self] in self?.close() }
        panel.setContent(
            MenuView(openSettings: { [weak self] in
                self?.close()
                openSettings()
            })
            .environmentObject(model)
            .environmentObject(model.hub)
        )
        statusItem.autosaveName = "LuxBridge"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggle)
        subscription = model.$menuBarSymbol.combineLatest(model.$menuBarText)
            .sink { [weak self] symbol, text in self?.updateButton(symbol: symbol, text: text) }
    }

    private func updateButton(symbol: String, text: String?) {
        guard let button = statusItem.button else { return }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "LuxBridge")
        image?.isTemplate = true
        button.image = image
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
        button.attributedTitle = NSAttributedString(string: text ?? "", attributes: [.font: font])
        button.imagePosition = text == nil ? .imageOnly : .imageLeading
    }

    @objc private func toggle() {
        panel.isVisible ? close() : show()
    }

    /// The item's frame in screen coordinates.
    private var itemFrame: NSRect? {
        guard let button = statusItem.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    private func show() {
        guard let item = itemFrame else { return }
        let visible = (statusItem.button?.window?.screen ?? NSScreen.main)?.visibleFrame ?? item
        panel.contentView?.layoutSubtreeIfNeeded()
        let width = panel.frame.width
        // Hang from the menu bar, left-aligned with the item, and stay on screen.
        let x = min(max(item.minX, visible.minX + Self.margin), visible.maxX - width - Self.margin)
        panel.setFrameTopLeftPoint(NSPoint(x: x, y: min(item.minY, visible.maxY) - Self.gap))
        panel.makeKeyAndOrderFront(nil)
        startMonitoring()
    }

    private func close() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }

    /// Closes the panel on a click anywhere else: in another app, or in another of our windows.
    /// Clicks on the item itself are left to `toggle`. The system reports those to the global
    /// monitor too, as the menu bar belongs to another process.
    private func startMonitoring() {
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { [weak self] _ in
            MainActor.assumeIsolated {
                if let self, self.itemFrame?.contains(NSEvent.mouseLocation) != true { self.close() }
            }
        }) {
            monitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: clicks, handler: { [weak self] event in
            MainActor.assumeIsolated {
                if let self, event.window !== self.panel, event.window !== self.statusItem.button?.window { self.close() }
            }
            return event
        }) {
            monitors.append(monitor)
        }
    }
}

/// A borderless, non-activating panel styled like the system's menu bar panels.
final class MenuPanel: NSPanel {
    /// Escape was pressed.
    var onCancel: (() -> Void)?

    private static let cornerRadius: CGFloat = 10

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 320, height: 100),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    }

    /// The content decides the panel's size: the hosting view is pinned to every edge.
    func setContent<Content: View>(_ content: Content) {
        let background = NSVisualEffectView()
        background.material = .menu
        background.blendingMode = .behindWindow
        background.state = .active
        background.maskImage = Self.roundedMask(radius: Self.cornerRadius)
        let host = NSHostingView(rootView: content)
        host.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(host)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: background.topAnchor),
            host.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            host.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: background.trailingAnchor),
        ])
        contentView = background
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let size = NSSize(width: radius * 2 + 1, height: radius * 2 + 1)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
