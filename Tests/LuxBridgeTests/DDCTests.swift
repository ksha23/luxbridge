import XCTest
@testable import DDCKit

final class DDCTests: XCTestCase {
    func testSetBrightnessPacket() {
        // 0x84 0x03 0x10 0x00 0x28, checksum 0x6E ^ 0x51 ^ each byte.
        XCTAssertEqual(DDCPacket.setVCP(0x10, value: 40), [0x84, 0x03, 0x10, 0x00, 0x28, 0x80])
    }

    func testGetBrightnessPacket() {
        XCTAssertEqual(DDCPacket.getVCP(0x10), [0x82, 0x01, 0x10, 0xFD])
    }

    func testParsesTheReplyAnLGUltraGearSentToAnM4Pro() throws {
        // Captured 2026-10-17. Byte 1 is 0x51 where the standard has the length byte 0x88.
        let reply: [UInt8] = [0x6E, 0x51, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x0A, 0xCA]
        let value = try XCTUnwrap(DDCPacket.parseReply(reply, code: 0x10))
        XCTAssertEqual(value.current, 10)
        XCTAssertEqual(value.maximum, 100)
    }

    func testParsesAStandardReply() throws {
        let reply: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x12, 0x00, 0x00, 0x64, 0x00, 0x46, 0x84]
        XCTAssertEqual(try XCTUnwrap(DDCPacket.parseReply(reply, code: 0x12)).current, 70)
    }

    func testRejectsTheNullReplyAMonitorSendsWhenNotReady() {
        let reply: [UInt8] = [0x6E, 0x80, 0xBE, 0xFF, 0x00, 0xE6, 0xD2, 0xD0, 0xA4, 0x0A, 0xF9]
        XCTAssertNil(DDCPacket.parseReply(reply, code: 0x10))
    }

    func testRejectsACorruptedReply() {
        let reply: [UInt8] = [0x6E, 0x51, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x0B, 0xCA]
        XCTAssertNil(DDCPacket.parseReply(reply, code: 0x10))
    }

    func testRejectsAReplyForAnotherCode() {
        let reply: [UInt8] = [0x6E, 0x51, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x0A, 0xCA]
        XCTAssertNil(DDCPacket.parseReply(reply, code: 0x12))
    }

    func testPairsFramebuffersWithTheirServices() {
        let framebuffer = "IOService:/AppleARMPE/arm-io@10F00000/AppleH16GFamilyIO/dispext1@0/IOMobileFramebufferShim"
        let own = "IOService:/AppleARMPE/arm-io@10F00000/AppleH16GFamilyIO/dcpext1@2E00000/AppleASCWrapV6/iop-dcpext1-nub/RTBuddy(DCPEXT1)/DCPEXT1Endpoint11/AFKDCPEXT1Endpoint11/AFKEPInterfaceServiceKextV2/dispext1:dcpav-service-epic:0/DCPAVServiceProxy"
        let other = "IOService:/AppleARMPE/arm-io@10F00000/AppleH16GFamilyIO/dcpext0@A2E00000/AppleASCWrapV6/iop-dcpext0-nub/RTBuddy(DCPEXT0)/DCPEXT0Endpoint11/AFKDCPEXT0Endpoint11/AFKEPInterfaceServiceKextV2/dispext0:dcpav-service-epic:0/DCPAVServiceProxy"
        XCTAssertTrue(DisplayScanner.pairs(framebufferPath: framebuffer, servicePath: own))
        XCTAssertFalse(DisplayScanner.pairs(framebufferPath: framebuffer, servicePath: other))
    }
}
