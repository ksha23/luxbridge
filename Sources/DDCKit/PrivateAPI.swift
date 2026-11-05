import CoreGraphics
import Foundation
import IOKit

/// Private Apple Silicon symbols for DDC, looked up at run time so that a missing symbol on some
/// future macOS disables DDC instead of crashing at launch.
enum PrivateAPI {
    typealias AVServiceCreate = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    typealias AVServiceI2C = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
    typealias DisplayInfo = @convention(c) (CGDirectDisplayID) -> Unmanaged<CFDictionary>?

    static let createAVService: AVServiceCreate? = symbol("IOAVServiceCreateWithService", in: iokit)
    static let readI2C: AVServiceI2C? = symbol("IOAVServiceReadI2C", in: iokit)
    static let writeI2C: AVServiceI2C? = symbol("IOAVServiceWriteI2C", in: iokit)
    static let displayInfo: DisplayInfo? = symbol("CoreDisplay_DisplayCreateInfoDictionary", in: coreDisplay)

    private static let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
    private static let coreDisplay = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY)

    private static func symbol<T>(_ name: String, in handle: UnsafeMutableRawPointer?) -> T? {
        guard let handle, let address = dlsym(handle, name) else { return nil }
        return unsafeBitCast(address, to: T.self)
    }
}
