import Foundation
import Combine
import SimulatorBridge
import LiveUICore
import LiveUIModels

/// The desktop app's single source of application state (§6.1, §50):
/// which project is open, what's indexed, what's selected, what the
/// connected runtime is reporting, and the undo/redo timeline.
@MainActor
public final class AppState: ObservableObject {
    @Published public var projectRoot: URL?
    @Published public var fileIndexes: [String: FileIndex] = [:]
    @Published public var selection: ViewNodeID?
    @Published public var runtimeGeometry: [String: RuntimeGeometry] = [:]
    @Published public var isRuntimeConnected: Bool = false
    @Published public var lastDiff: String = ""
    @Published public var lastError: String?
    @Published public private(set) var canUndo: Bool = false
    @Published public private(set) var canRedo: Bool = false

    public let history = HistoryEngine()
    private let bridge = BridgeServer()

    public init() {
        bridge.onMessage = { [weak self] message in
            guard let self else { return }
            Task { @MainActor in self.handle(message) }
        }
    }

    public func startBridge() {
        do {
            try bridge.start()
        } catch {
            lastError = "Could not start the LiveUI bridge listener: \(error)"
        }
    }

    private func handle(_ message: RuntimeMessage) {
        switch message {
        case .hello:
            isRuntimeConnected = true
        case .snapshot(let views):
            for view in views {
                runtimeGeometry[view.id] = view.geometry
            }
        case .ack:
            break
        }
    }

    // MARK: - Project / indexing (§49)

    public func openProject(at url: URL) {
        projectRoot = url
        reindex()
    }

    public func reindex() {
        guard let root = projectRoot,
              let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return }

        var indexes: [String: FileIndex] = [:]
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            guard let source = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            indexes[fileURL.path] = SourceIndexer.index(source: source, filePath: fileURL.path)
        }
        fileIndexes = indexes
    }

    // MARK: - Mutations (§27-28, §52-55)

    public func apply(_ mutation: Mutation) {
        let file = mutation.target.file
        guard let currentSource = currentSource(for: file) else {
            lastError = "Could not read \(file)."
            return
        }
        do {
            let (newSource, diff) = try MutationEngine.apply(mutation, toSource: currentSource, filePath: file)
            try newSource.write(toFile: file, atomically: true, encoding: .utf8)

            history.record(MutationRecord(
                id: UUID(), timestamp: Date(), mutation: mutation,
                file: file, oldSource: currentSource, newSource: newSource, diff: diff
            ))
            refreshHistoryFlags()

            lastDiff = diff
            lastError = nil
            fileIndexes[file] = SourceIndexer.index(source: newSource, filePath: file)
        } catch {
            // §29: a mutation that can't be safely applied must never touch
            // the file on disk — currentSource/fileIndexes are untouched here.
            lastError = "Mutation failed: \(error)"
        }
    }

    public func undo() {
        guard let record = history.undo() else { return }
        try? record.oldSource.write(toFile: record.file, atomically: true, encoding: .utf8)
        fileIndexes[record.file] = SourceIndexer.index(source: record.oldSource, filePath: record.file)
        refreshHistoryFlags()
    }

    public func redo() {
        guard let record = history.redo() else { return }
        try? record.newSource.write(toFile: record.file, atomically: true, encoding: .utf8)
        fileIndexes[record.file] = SourceIndexer.index(source: record.newSource, filePath: record.file)
        refreshHistoryFlags()
    }

    private func refreshHistoryFlags() {
        canUndo = history.canUndo
        canRedo = history.canRedo
    }

    private func currentSource(for file: String) -> String? {
        history.currentSource[file] ?? (try? String(contentsOfFile: file, encoding: .utf8))
    }
}
