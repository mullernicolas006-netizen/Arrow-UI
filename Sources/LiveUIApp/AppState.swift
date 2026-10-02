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

    /// The `.xcodeproj` auto-detected near `projectRoot` (§6.1) — needed to
    /// drive `xcodebuild` for the automatic rebuild-and-relaunch loop.
    @Published public private(set) var xcodeProjectPath: URL?
    @Published public private(set) var scheme: String?
    /// From the runtime's `.hello` message — needed to `simctl launch` the
    /// rebuilt app.
    @Published public private(set) var connectedBundleIdentifier: String?
    @Published public private(set) var isBuilding: Bool = false
    @Published public private(set) var buildStatus: String?

    public let history = HistoryEngine()
    private let bridge = BridgeServer()
    private let buildRunner = PlaygroundBuildRunner()
    private var cancellables = Set<AnyCancellable>()

    public init() {
        bridge.onMessage = { [weak self] message in
            guard let self else { return }
            Task { @MainActor in self.handle(message) }
        }
        // Surfaces a listener failure discovered *after* startBridge()
        // already returned successfully (e.g. "port already in use" from
        // another still-running LiveUIApp instance) — see BridgeServer
        // .lastError's doc comment for why this can't just be a thrown error.
        bridge.$lastError
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in self?.lastError = message }
            .store(in: &cancellables)

        buildRunner.$isBuilding
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.isBuilding = value }
            .store(in: &cancellables)
        buildRunner.$lastStatus
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.buildStatus = value }
            .store(in: &cancellables)
        buildRunner.$lastError
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in self?.lastError = message }
            .store(in: &cancellables)
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
        case .hello(_, let bundleIdentifier, let screenWidth, let screenHeight):
            isRuntimeConnected = true
            connectedBundleIdentifier = bundleIdentifier
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
        xcodeProjectPath = Self.findXcodeProject(near: url)
        scheme = xcodeProjectPath?.deletingPathExtension().lastPathComponent
        if xcodeProjectPath == nil {
            lastError = "Couldn't find a .xcodeproj near \(url.path) — automatic rebuild-and-relaunch after a drag won't be available for this project (everything else still works)."
        }
        reindex()
    }

    /// Looks in `root` and up to 4 parent directories for a single
    /// `.xcodeproj` — `root` is usually the source folder *inside* the
    /// Xcode project directory (e.g. `MyApp/MyApp/`), so the project file
    /// itself is typically one level up (`MyApp/MyApp.xcodeproj`).
    private static func findXcodeProject(near root: URL) -> URL? {
        var directory = root
        for _ in 0..<5 {
            if let found = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "xcodeproj" }) {
                return found
            }
            let parent = directory.deletingLastPathComponent()
            if parent == directory { break }
            directory = parent
        }
        return nil
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

            if let xcodeProjectPath, let scheme, let bundleIdentifier = connectedBundleIdentifier {
                buildRunner.scheduleRebuild(xcodeProjectPath: xcodeProjectPath, scheme: scheme, bundleIdentifier: bundleIdentifier)
            }
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

    /// The immediate enclosing view call for `childID`, if any — e.g. the
    /// `VStack` `IndexedNode` for a `Button` nested directly inside it.
    ///
    /// This is what lets a canvas drag take `LayoutEngine`'s "grow the
    /// VStack's spacing" path instead of always falling back to padding
    /// the dragged view itself: without a parent, every drag — on a
    /// Button, a Text, or the VStack itself — can only pad its own target,
    /// which both moves the target *and* visibly changes the gap to its
    /// sibling, in a way that doesn't read as "the view moved to where I
    /// dragged it."
    public func parent(of childID: ViewNodeID) -> IndexedNode? {
        for index in fileIndexes.values {
            if let found = parent(of: childID, in: index.roots, parent: nil) {
                return found
            }
        }
        return nil
    }

    private func parent(of childID: ViewNodeID, in nodes: [IndexedNode], parent: IndexedNode?) -> IndexedNode? {
        for node in nodes {
            if node.id == childID { return parent }
            if let found = self.parent(of: childID, in: node.children, parent: node) {
                return found
            }
        }
        return nil
    }
}
