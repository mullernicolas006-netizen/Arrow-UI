import Foundation

/// The messages exchanged between `LiveUIRuntime` (inside the app under
/// development, running in the Simulator) and `SimulatorBridge`'s server
/// (inside the LiveUI desktop app), per §7 and §50.
///
/// Framing is newline-delimited JSON (see `SimulatorBridge/Framing.swift`),
/// deliberately simple enough to debug with `nc localhost <port>`.

public struct RuntimeGeometry: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// One entry in the running app's View Registry (§8), as reported over the
/// wire. `id` matches the `ViewNodeID.description` the app was tagged with
/// via `.liveUITag(...)`.
public struct RuntimeViewInfo: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var typeName: String
    public var file: String
    public var structuralPath: String
    public var geometry: RuntimeGeometry
    public var parentID: String?

    public init(id: String, typeName: String, file: String, structuralPath: String, geometry: RuntimeGeometry, parentID: String?) {
        self.id = id
        self.typeName = typeName
        self.file = file
        self.structuralPath = structuralPath
        self.geometry = geometry
        self.parentID = parentID
    }
}

/// Runtime (app) -> App (desktop) messages.
public enum RuntimeMessage: Codable, Sendable {
    /// `screenWidth`/`screenHeight` are the device's logical screen size in
    /// points (`UIScreen.main.bounds.size`) — needed so the desktop app can
    /// scale the mirrored screenshot and the geometry overlay by the same
    /// factor and have them land in the same place.
    case hello(appName: String, bundleIdentifier: String, screenWidth: Double, screenHeight: Double)
    case snapshot(views: [RuntimeViewInfo])
    case ack
}

/// App (desktop) -> Runtime (app) messages.
public enum BridgeMessage: Codable, Sendable {
    case requestSnapshot
    /// An in-flight drag preview (§25): applied transiently in the
    /// runtime, never written to source until the gesture ends. `x`/`y`
    /// are sent together, atomically, in one message — splitting them
    /// into two separate messages (as an earlier revision of this case
    /// did) meant the runtime applied two separate `@Published` updates,
    /// and therefore two separate renders, per drag tick, which was
    /// visibly less smooth than a single combined update.
    case previewOffset(nodeID: String, x: Double, y: Double)
    /// An in-flight resize preview — the resize counterpart of
    /// `previewOffset`. Applied as a transient `.scaleEffect`, anchored
    /// at the corner *opposite* the handle being dragged (so that corner
    /// stays visually fixed while the dragged corner grows/shrinks with
    /// the cursor), the same purely-compositor-level technique design
    /// tools like Figma use for live interactive resize — cheap enough
    /// to apply every drag tick with no real layout pass, with the true
    /// `.frame(width:,height:)` only written once the gesture ends.
    /// `anchorX`/`anchorY` are `UnitPoint` components (0...1).
    case previewScale(nodeID: String, scaleX: Double, scaleY: Double, anchorX: Double, anchorY: Double)
    case clearPreview
}
