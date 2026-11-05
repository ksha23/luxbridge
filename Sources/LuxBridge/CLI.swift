import DDCKit
import Foundation
import LuxBridgeCore

/// A few commands for checking DDC from a terminal, independent of the app's settings.
enum CLI {
    static let usage = """
        usage: LuxBridge list             list external displays
               LuxBridge get <n>          print display n's brightness
               LuxBridge set <n> <0-100>  set display n's brightness in percent
               LuxBridge config           print the settings as JSON
               LuxBridge config import    replace the settings with JSON from standard input
               LuxBridge token            store a Home Assistant token read from standard input
        Quit the app before changing its settings from here.
        """

    /// Returns an exit status, or nil when the arguments are not a command and the app should start.
    static func run(_ arguments: [String]) -> Int32? {
        guard let command = arguments.first,
              ["list", "get", "set", "config", "token", "help", "--help", "-h"].contains(command)
        else { return nil }
        switch command {
        case "config":
            return arguments.dropFirst().first == "import" ? importConfig() : printConfig()
        case "token":
            return storeToken()
        default:
            break
        }
        let displays = DisplayScanner.scan()
        switch command {
        case "list":
            if displays.isEmpty { print("No external displays") }
            for (index, display) in displays.enumerated() {
                let ddc = display.channel == nil ? "no DDC service" : "DDC service found"
                print("[\(index + 1)] \(display.name)  vendor \(display.vendor) model \(display.model) serial \(display.serial)  \(ddc)")
            }
            return 0
        case "get":
            guard arguments.count == 2, let channel = channel(arguments[1], in: displays) else { return fail() }
            guard let reading = channel.read(.brightness) else { return fail("The display did not answer") }
            print("\(reading.current) of \(reading.maximum)")
            return 0
        case "set":
            guard arguments.count == 3, let channel = channel(arguments[1], in: displays),
                  let percent = Int(arguments[2]), (0...100).contains(percent)
            else { return fail() }
            let maximum = channel.read(.brightness)?.maximum ?? 100
            let value = Int((Double(percent) * Double(maximum) / 100).rounded())
            guard channel.write(.brightness, value: value) else { return fail("The display did not accept the write") }
            print("Set \(value) of \(maximum)")
            return 0
        default:
            print(usage)
            return 0
        }
    }

    private static func printConfig() -> Int32 {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(ConfigStore.load()) else { return fail("Could not encode the settings") }
        print(String(decoding: data, as: UTF8.self))
        return 0
    }

    private static func importConfig() -> Int32 {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        do {
            ConfigStore.save(try JSONDecoder().decode(AppConfig.self, from: data))
            return 0
        } catch {
            return fail("Not valid LuxBridge settings: \(error)")
        }
    }

    /// Reads the token from standard input so it never appears in the process list or shell history.
    private static func storeToken() -> Int32 {
        let token = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return fail("No token on standard input") }
        return Keychain.save(token) ? 0 : fail("Could not save the token to the Keychain")
    }

    private static func channel(_ argument: String, in displays: [ExternalDisplay]) -> DDCChannel? {
        guard let index = Int(argument), displays.indices.contains(index - 1) else { return nil }
        return displays[index - 1].channel
    }

    private static func fail(_ message: String = usage) -> Int32 {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        return 1
    }
}
