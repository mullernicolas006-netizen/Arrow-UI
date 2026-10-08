import AppKit
import Foundation

/// Mirrors the currently-booted iOS Simulator's screen into `frame`, by
/// polling `xcrun simctl io booted screenshot`.
///
/// Deliberately built on fully public, documented Apple tooling rather
/// than a video stream or any private CoreSimulator API: it's a
/// still-image poll, so it tops out at a few frames per second, but it
/// has no third-party dependency and nothing here can break across an
/// Xcode update the way an undocumented API could. See ARCHITECTURE.md
/// for the plan to upgrade to real streaming (e.g. via `idb`) if this
/// polling cadence turns out to feel too choppy in practice — that's a
/// separate, swappable piece from everything else in this file.
private struct CaptureFailure: Error {
    let message: String
}

@MainActor
public final class SimulatorScreenMirror: ObservableObject {
    @Published public private(set) var frame: NSImage?
    @Published public private(set) var lastError: String?

    private var pollTask: Task<Void, Never>?
    private let interval: TimeInterval
    private let screenshotURL: URL

    public init(interval: TimeInterval = 0.5) {
        self.interval = interval
        self.screenshotURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("liveui-mirror-\(UUID().uuidString).png")
    }

    public func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.captureOnce()
                try? await Task.sleep(nanoseconds: UInt64(self.interval * 1_000_000_000))
            }
        }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
        try? FileManager.default.removeItem(at: screenshotURL)
    }

    /// Runs `xcrun simctl` (a blocking `Process`) off the main actor, then
    /// hops back to publish the result — polling shouldn't stall the UI.
    private func captureOnce() async {
        let url = screenshotURL
        let outcome = await Task.detached(priority: .utility) { () -> Result<NSImage, CaptureFailure> in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["simctl", "io", "booted", "screenshot", url.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    return .failure(CaptureFailure(message: "`xcrun simctl io booted screenshot` exited with status \(process.terminationStatus) — is a Simulator booted?"))
                }
                guard let image = NSImage(contentsOf: url) else {
                    return .failure(CaptureFailure(message: "Could not decode the Simulator screenshot."))
                }
                return .success(image)
            } catch {
                return .failure(CaptureFailure(message: "Could not run xcrun simctl: \(error)"))
            }
        }.value

        switch outcome {
        case .success(let image):
            frame = image
            lastError = nil
        case .failure(let failure):
            lastError = failure.message
        }
    }
}
