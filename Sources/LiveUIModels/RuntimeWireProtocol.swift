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
    case hello(appName: String, bundleIdentifier: String)
    case snapshot(views: [RuntimeViewInfo])
    case ack
}

/// App (desktop) -> Runtime (app) messages.
public enum BridgeMessage: Codable, Sendable {
    case requestSnapshot
    /// An in-flight drag/resize preview (§25): applied transiently in the
    /// runtime, never written to source until the gesture ends.
    case previewMutation(nodeID: String, property: String, value: Double)
    case clearPreview
}
