import Foundation

struct SimulatorDevice {
    let udid: String
    let name: String
}

enum SimulatorDeviceFinder {
    /// Finds the currently booted Simulator device via `xcrun simctl list
    /// devices booted -j`. Returns nil (rather than throwing) if none is
    /// booted or the output can't be parsed — callers should surface that
    /// as "boot a Simulator first," not as a build failure.
    static func bootedDevice() async -> SimulatorDevice? {
        await Task.detached(priority: .utility) { () -> SimulatorDevice? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["simctl", "list", "devices", "booted", "-j"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { return nil }

                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let devicesByRuntime = json["devices"] as? [String: [[String: Any]]] else {
                    return nil
                }
                for (_, devices) in devicesByRuntime {
                    for device in devices {
                        if (device["state"] as? String) == "Booted",
                           let udid = device["udid"] as? String,
                           let name = device["name"] as? String {
                            return SimulatorDevice(udid: udid, name: name)
                        }
                    }
                }
                return nil
            } catch {
                return nil
            }
        }.value
    }
}
