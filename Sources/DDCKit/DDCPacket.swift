import Foundation

/// MCCS feature codes this app uses.
public enum VCP: UInt8, Sendable {
    case brightness = 0x10
    case contrast = 0x12
}

/// Builds and parses DDC/CI messages. Pure functions, so they can be tested without a display.
enum DDCPacket {
    static let displayAddress: UInt8 = 0x6E
    static let hostAddress: UInt8 = 0x51
    static let replyHostAddress: UInt8 = 0x50

    /// Set VCP Feature: length, opcode 0x03, code, value high, value low, checksum.
    static func setVCP(_ code: UInt8, value: UInt16) -> [UInt8] {
        var packet: [UInt8] = [0x84, 0x03, code, UInt8(value >> 8), UInt8(value & 0xFF)]
        packet.append(packet.reduce(displayAddress ^ hostAddress, ^))
        return packet
    }

    /// Get VCP Feature: length, opcode 0x01, code, checksum. The checksum leaves out the host
    /// address, as m1ddc and MonitorControl do, which is what monitors accept from Apple Silicon.
    static func getVCP(_ code: UInt8) -> [UInt8] {
        var packet: [UInt8] = [0x82, 0x01, code]
        packet.append(packet.reduce(displayAddress, ^))
        return packet
    }

    /// Parses a Get VCP Feature reply of 11 bytes:
    /// source 0x6E, length 0x88, opcode 0x02, result, code, type, max (2), current (2), checksum.
    ///
    /// On an M4 Pro the length byte comes back as 0x51 instead of 0x88, so the header bytes are
    /// not trusted and the checksum is computed over the standard header instead.
    static func parseReply(_ reply: [UInt8], code: UInt8) -> (current: UInt16, maximum: UInt16)? {
        guard reply.count >= 11, reply[2] == 0x02, reply[3] == 0x00, reply[4] == code else { return nil }
        let checksum = reply[2...9].reduce(replyHostAddress ^ displayAddress ^ 0x88, ^)
        guard checksum == reply[10] else { return nil }
        let maximum = UInt16(reply[6]) << 8 | UInt16(reply[7])
        let current = UInt16(reply[8]) << 8 | UInt16(reply[9])
        guard maximum > 0 else { return nil }
        return (current, maximum)
    }
}
