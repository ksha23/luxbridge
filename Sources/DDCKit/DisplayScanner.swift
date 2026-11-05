import CoreGraphics
import Foundation
import IOKit

/// A connected external display and, if macOS offers one, its DDC channel.
public struct ExternalDisplay: Equatable, Sendable {
    public let displayID: CGDirectDisplayID
    public let name: String
    public let vendor: UInt32
    public let model: UInt32
    public let serial: UInt32
    public let channel: DDCChannel?

    public static func == (lhs: ExternalDisplay, rhs: ExternalDisplay) -> Bool {
        lhs.displayID == rhs.displayID && lhs.vendor == rhs.vendor && lhs.model == rhs.model
            && lhs.serial == rhs.serial && lhs.name == rhs.name
            && lhs.channel?.serviceID == rhs.channel?.serviceID
    }
}

public enum DisplayScanner {
    /// Lists connected external displays and pairs each with its DDC service.
    /// Channels in `existing` whose service is still registered are reused rather than recreated.
    public static func scan(reusing existing: [DDCChannel] = []) -> [ExternalDisplay] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else { return [] }
        let externals = ids.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) == 0 }

        let services = externalAVServices()
        defer { services.forEach { IOObjectRelease($0.entry) } }

        var used = Set<UInt64>()
        return externals.map { displayID in
            let info = PrivateAPI.displayInfo?(displayID)?.takeRetainedValue() as? [String: Any]
            var service = (info?["IODisplayLocation"] as? String).flatMap { location in
                services.first { !used.contains($0.id) && pairs(framebufferPath: location, servicePath: $0.path) }
            }
            // Older chips name their registry nodes differently. With one display and one service
            // there is nothing to confuse.
            if service == nil, externals.count == 1, services.count == 1 {
                service = services.first
            }
            var channel: DDCChannel?
            if let service {
                used.insert(service.id)
                channel = existing.first { $0.serviceID == service.id }
                    ?? DDCChannel(entry: service.entry, serviceID: service.id)
            }
            return ExternalDisplay(
                displayID: displayID,
                name: productName(info) ?? "Display \(displayID)",
                vendor: CGDisplayVendorNumber(displayID),
                model: CGDisplayModelNumber(displayID),
                serial: CGDisplaySerialNumber(displayID),
                channel: channel
            )
        }
    }

    /// The framebuffer ".../dispext1@0/IOMobileFramebufferShim" belongs with the service
    /// ".../dcpext1@.../dispext1:dcpav-service-epic:0/DCPAVServiceProxy".
    static func pairs(framebufferPath: String, servicePath: String) -> Bool {
        let components = framebufferPath.split(separator: "/")
        guard components.count >= 2 else { return false }
        let parent = components[components.count - 2]
        let node = parent.split(separator: "@").first ?? parent
        return servicePath.contains("/\(node):")
    }

    // MARK: Private

    private struct AVService {
        let entry: io_service_t
        let id: UInt64
        let path: String
    }

    private static func externalAVServices() -> [AVService] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }
        var services: [AVService] = []
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            var id: UInt64 = 0
            var path = [CChar](repeating: 0, count: 1024)
            guard location == "External",
                  IORegistryEntryGetRegistryEntryID(entry, &id) == KERN_SUCCESS,
                  IORegistryEntryGetPath(entry, kIOServicePlane, &path) == KERN_SUCCESS
            else {
                IOObjectRelease(entry)
                continue
            }
            services.append(AVService(entry: entry, id: id, path: String(cString: path)))
        }
        return services
    }

    private static func productName(_ info: [String: Any]?) -> String? {
        guard let names = info?["DisplayProductName"] as? [String: String] else { return nil }
        return names["en_US"] ?? names.values.sorted().first
    }
}
