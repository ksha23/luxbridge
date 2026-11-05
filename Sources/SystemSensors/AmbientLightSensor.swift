import Foundation
import IOKit

/// The Mac's built-in ambient light sensor (MacBooks and iMacs), read through the private
/// IOHIDEventSystemClient API as Lunar and OpenDisplay do. Desktop Macs without a sensor get nil
/// from `open()`.
public final class AmbientLightSensor: @unchecked Sendable {
    private let client: CFTypeRef
    private let service: CFTypeRef

    private static let eventType: Int64 = 12                   // kIOHIDEventTypeAmbientLightSensor
    private static let levelField = Int32(12 << 16)           // kIOHIDEventFieldAmbientLightSensorLevel

    public static func open() -> AmbientLightSensor? {
        guard let create = HID.clientCreate, let setMatching = HID.setMatching, let copyServices = HID.copyServices,
              let client = create(kCFAllocatorDefault)?.takeRetainedValue()
        else { return nil }
        setMatching(client, ["PrimaryUsagePage": 0xFF00, "PrimaryUsage": 4] as CFDictionary)
        guard let services = copyServices(client)?.takeRetainedValue() as? [CFTypeRef], let service = services.first else {
            return nil
        }
        return AmbientLightSensor(client: client, service: service)
    }

    private init(client: CFTypeRef, service: CFTypeRef) {
        self.client = client
        self.service = service
    }

    /// The current reading in lux, or nil if the sensor did not answer.
    public func lux() -> Double? {
        guard let copyEvent = HID.copyEvent, let getFloat = HID.getFloatValue,
              let event = copyEvent(service, Self.eventType, 0, 0)?.takeRetainedValue()
        else { return nil }
        let lux = getFloat(event, Self.levelField)
        return lux.isFinite && lux >= 0 ? lux : nil
    }

    /// True when a laptop's lid is closed, which covers the sensor. False on Macs without a lid.
    public static var isLidClosed: Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        let state = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool
        return state ?? false
    }
}

/// Private IOKit HID symbols, looked up at run time so a missing one disables the sensor.
private enum HID {
    typealias ClientCreate = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
    typealias SetMatching = @convention(c) (CFTypeRef, CFDictionary) -> Void
    typealias CopyServices = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
    typealias CopyEvent = @convention(c) (CFTypeRef, Int64, Int32, Int64) -> Unmanaged<CFTypeRef>?
    typealias GetFloatValue = @convention(c) (CFTypeRef, Int32) -> Double

    static let clientCreate: ClientCreate? = symbol("IOHIDEventSystemClientCreate")
    static let setMatching: SetMatching? = symbol("IOHIDEventSystemClientSetMatching")
    static let copyServices: CopyServices? = symbol("IOHIDEventSystemClientCopyServices")
    static let copyEvent: CopyEvent? = symbol("IOHIDServiceClientCopyEvent")
    static let getFloatValue: GetFloatValue? = symbol("IOHIDEventGetFloatValue")

    private static let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)

    private static func symbol<T>(_ name: String) -> T? {
        guard let iokit, let address = dlsym(iokit, name) else { return nil }
        return unsafeBitCast(address, to: T.self)
    }
}
