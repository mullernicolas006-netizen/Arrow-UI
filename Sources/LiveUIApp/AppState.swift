import Foundation
import CoreGraphics
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
    /// The connected device's logical screen size in points, from the
    /// runtime's `.hello` message — used to scale the mirrored screenshot
    /// and the geometry overlay by the same factor (see `CanvasTransform`).
    @Published public var deviceScreenSize: CGSize?
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
        case .hello(_, _, let screenWidth, let screenHeight):
            isRuntimeConnected = true
            if screenWidth > 0, screenHeight > 0 {
                deviceScreenSize = CGSize(width: screenWidth, height: screenHeight)
            }
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

    // MARK: - Canvas hit-testing (§21-26: direct manipulation)

    /// Resolves a runtime-reported id (a `ViewNodeID.description` string,
    /// as sent in `RuntimeViewInfo`) back to the `IndexedNode` it came
    /// from, so the canvas can turn "the box the user just clicked" into
    /// something `LayoutEngine`/`MutationEngine` can act on.
    ///
    /// Two-tier match, both ignoring the `file` component's directory
    /// (a hand-written `.liveUITag(file: "ContentView.swift")` call reports
    /// just a bare filename, while `SourceIndexer` computes each node's
    /// `file` as the full absolute path it read from disk):
    ///  1. Exact: type name + structural path + filename.
    ///  2. Fallback: type name + filename alone, but *only* when that's
    ///     unambiguous (exactly one node of that type in the file) — a
    ///     hand-typed `.liveUITag(path:)` is realistic to get wrong (the
    ///     real structural paths SourceIndexer computes are long and not
    ///     hand-predictable), so this lets manual tagging work today
    ///     without requiring the exact path, without ever guessing between
    ///     multiple same-typed views.
    public func node(forRuntimeID runtimeID: String) -> IndexedNode? {
        guard let parsed = ViewNodeID.parse(runtimeDescription: runtimeID) else { return nil }
        var exactMatch: IndexedNode?
        var typeMatches: [IndexedNode] = []
        for index in fileIndexes.values {
            collect(parsed, in: index.roots, exact: &exactMatch, typeMatches: &typeMatches)
        }
        return exactMatch ?? (typeMatches.count == 1 ? typeMatches[0] : nil)
    }

    private func collect(_ parsed: ViewNodeID.RuntimeIDComponents, in nodes: [IndexedNode], exact: inout IndexedNode?, typeMatches: inout [IndexedNode]) {
        for node in nodes {
            let sameFile = (node.id.file as NSString).lastPathComponent == (parsed.file as NSString).lastPathComponent
            if node.id.typeName == parsed.typeName, sameFile {
                if node.id.path == parsed.path {
                    exact = node
                } else {
                    typeMatches.append(node)
                }
            }
            collect(parsed, in: node.children, exact: &exact, typeMatches: &typeMatches)
        }
    }
}
