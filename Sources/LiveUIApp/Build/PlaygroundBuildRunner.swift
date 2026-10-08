import Foundation

/// Automatically rebuilds, reinstalls, and relaunches the app under
/// development after a mutation is applied — the point being that you
/// never touch Xcode/the Simulator manually to see a drag's real result.
///
/// Uses only public Apple tooling (`xcodebuild`, `xcrun simctl`), the same
/// choice made for screen mirroring: slower than a true hot-reload tool,
/// but nothing here can silently break across an Xcode update the way an
/// undocumented API could.
@MainActor
public final class PlaygroundBuildRunner: ObservableObject {
    @Published public private(set) var isBuilding = false
    @Published public private(set) var lastStatus: String?
    @Published public private(set) var lastError: String?

    private var pendingTask: Task<Void, Never>?
    private let debounceNanoseconds: UInt64

    public init(debounceSeconds: Double = 1.5) {
        self.debounceNanoseconds = UInt64(debounceSeconds * 1_000_000_000)
    }

    /// Debounced: if called again before the delay elapses, the previously
    /// scheduled build is cancelled and replaced — several quick drags in
    /// a row trigger one real build, not one per drag.
    public func scheduleRebuild(xcodeProjectPath: URL, scheme: String, bundleIdentifier: String) {
        pendingTask?.cancel()
        pendingTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: self?.debounceNanoseconds ?? 0)
            guard !Task.isCancelled else { return }
            await self?.rebuildInstallAndLaunch(xcodeProjectPath: xcodeProjectPath, scheme: scheme, bundleIdentifier: bundleIdentifier)
        }
    }

    private func rebuildInstallAndLaunch(xcodeProjectPath: URL, scheme: String, bundleIdentifier: String) async {
        guard !isBuilding else { return }
        isBuilding = true
        lastError = nil
        defer { isBuilding = false }

        lastStatus = "Finding booted Simulator…"
        guard let device = await SimulatorDeviceFinder.bootedDevice() else {
            lastError = "No booted Simulator found — start one from Xcode first."
            lastStatus = nil
            return
        }

        let derivedData = FileManager.default.temporaryDirectory.appendingPathComponent("LiveUI-DerivedData", isDirectory: true)

        lastStatus = "Building \(scheme) for \(device.name)…"
        let buildArgs = [
            "-project", xcodeProjectPath.path,
            "-scheme", scheme,
            "-configuration", "Debug",
            "-destination", "platform=iOS Simulator,id=\(device.udid)",
            "-derivedDataPath", derivedData.path,
            "build"
        ]
        print("[LiveUI] Build: xcodebuild \(buildArgs.joined(separator: " "))")
        let buildResult = await run("/usr/bin/xcodebuild", buildArgs)
        guard buildResult.exitCode == 0 else {
            lastError = "Build failed (exit \(buildResult.exitCode)) — see the LiveUIApp terminal for the full xcodebuild log."
            lastStatus = nil
            print("[LiveUI] Build: FAILED\n\(buildResult.output)")
            return
        }

        let productsDir = derivedData.appendingPathComponent("Build/Products/Debug-iphonesimulator", isDirectory: true)
        guard let appPath = try? FileManager.default.contentsOfDirectory(at: productsDir, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }) else {
            lastError = "Build succeeded but no .app was found in \(productsDir.path)."
            lastStatus = nil
            return
        }

        lastStatus = "Installing…"
        let installResult = await run("/usr/bin/xcrun", ["simctl", "install", device.udid, appPath.path])
        guard installResult.exitCode == 0 else {
            lastError = "Install failed (exit \(installResult.exitCode))."
            lastStatus = nil
            print("[LiveUI] Build: install FAILED\n\(installResult.output)")
            return
        }

        lastStatus = "Launching…"
        let launchResult = await run("/usr/bin/xcrun", ["simctl", "launch", device.udid, bundleIdentifier])
        guard launchResult.exitCode == 0 else {
            lastError = "Launch failed (exit \(launchResult.exitCode))."
            lastStatus = nil
            print("[LiveUI] Build: launch FAILED\n\(launchResult.output)")
            return
        }

        lastStatus = "Relaunched \(Date().formatted(date: .omitted, time: .standard))"
        print("[LiveUI] Build: relaunched \(bundleIdentifier) on \(device.name)")
    }

    private func run(_ executablePath: String, _ arguments: [String]) async -> (exitCode: Int32, output: String) {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
            } catch {
                return (Int32(-1), "\(error)")
            }
        }.value
    }
}
