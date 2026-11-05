import Foundation
import IOKit

public struct DDCReading: Equatable, Sendable {
    public var current: Int
    public var maximum: Int
}

/// DDC/CI access to one external display through its IOAVService.
///
/// Calls block for tens to hundreds of milliseconds, so use each channel from one serial queue.
/// The timing (two writes per request, 50 ms before reading, a few retries) follows
/// MonitorControl, which found that many monitors drop the first message.
public final class DDCChannel: @unchecked Sendable {
    /// The IORegistry entry ID of the DCPAVServiceProxy, stable while the display stays connected.
    public let serviceID: UInt64
    private let service: CFTypeRef

    private static let chipAddress: UInt32 = 0x37

    init?(entry: io_service_t, serviceID: UInt64) {
        guard let create = PrivateAPI.createAVService,
              let service = create(kCFAllocatorDefault, entry)?.takeRetainedValue()
        else { return nil }
        self.service = service
        self.serviceID = serviceID
    }

    public func read(_ code: VCP) -> DDCReading? {
        guard let write = PrivateAPI.writeI2C, let read = PrivateAPI.readI2C else { return nil }
        var request = DDCPacket.getVCP(code.rawValue)
        for attempt in 0..<4 {
            if attempt > 0 { usleep(20_000) }
            for _ in 0..<2 {
                usleep(10_000)
                _ = write(service, Self.chipAddress, UInt32(DDCPacket.hostAddress), &request, UInt32(request.count))
            }
            usleep(50_000)
            var reply = [UInt8](repeating: 0, count: 11)
            guard read(service, Self.chipAddress, UInt32(DDCPacket.hostAddress), &reply, UInt32(reply.count)) == kIOReturnSuccess
            else { continue }
            if let value = DDCPacket.parseReply(reply, code: code.rawValue) {
                return DDCReading(current: Int(value.current), maximum: Int(value.maximum))
            }
        }
        return nil
    }

    /// Returns true if the display accepted the message at the I2C level. That does not prove the
    /// monitor applied it; a later `read` does.
    public func write(_ code: VCP, value: Int) -> Bool {
        guard let write = PrivateAPI.writeI2C else { return false }
        var packet = DDCPacket.setVCP(code.rawValue, value: UInt16(clamping: value))
        var accepted = false
        for _ in 0..<2 {
            usleep(10_000)
            if write(service, Self.chipAddress, UInt32(DDCPacket.hostAddress), &packet, UInt32(packet.count)) == kIOReturnSuccess {
                accepted = true
            }
        }
        return accepted
    }
}
