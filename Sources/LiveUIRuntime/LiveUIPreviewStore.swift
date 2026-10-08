import SwiftUI
import Combine
import LiveUIModels

/// Live drag-preview state, shared by every `.liveUITag`'d view in the
/// running app (§25). While a canvas drag is in flight on the desktop
/// side, `OverlayView` streams `BridgeMessage.previewOffset` over the
/// existing bridge connection, and this store is what lets the *actual*
/// dragged view move in real time — not a screenshot, not a desktop-side
/// approximation, before any source mutation or rebuild happens.
///
/// Holds only the *delta* of whichever drag is currently in flight, not
/// each view's total offset: whatever `.offset(...)` a previous drag's
/// rebuild already baked into the compiled app stays exactly as
/// compiled, and this is layered on top of it in `LiveUITagModifier`.
/// That's also why nothing needs to explicitly reset this once a drag's
/// rebuild finishes — relaunching is a fresh process, so this transient
/// state is simply gone, replaced by the new compiled `.offset()` that
/// now bakes in the same value for real.
/// A view's in-flight resize preview: a scale factor plus the corner
/// it should grow/shrink *away from* (the corner opposite whichever
/// handle is being dragged, which must stay visually fixed).
public struct LiveUIPreviewScale: Equatable, Sendable {
    public var scaleX: Double
    public var scaleY: Double
    public var anchorX: Double
    public var anchorY: Double

    public init(scaleX: Double, scaleY: Double, anchorX: Double, anchorY: Double) {
        self.scaleX = scaleX
        self.scaleY = scaleY
        self.anchorX = anchorX
        self.anchorY = anchorY
    }
}

@MainActor
public final class LiveUIPreviewStore: ObservableObject {
    @Published public var offsets: [String: CGSize] = [:]
    @Published public var scales: [String: LiveUIPreviewScale] = [:]

    public init() {}

    public func apply(_ message: BridgeMessage) {
        switch message {
        case .previewOffset(let nodeID, let x, let y):
            // One atomic write — both axes change together, in the same
            // render, instead of x and y each triggering their own.
            //
            // Deliberately no print() per update: this fires on every
            // drag tick (dozens of times per second) while a desktop
            // drag is in flight, and real testing showed that logging
            // each one floods Xcode's debug console fast enough to get
            // the app killed outright ("Terminated due to signal 9") —
            // not a bug in this mechanism, which the same flooded log
            // actually proved was working correctly.
            offsets[nodeID] = CGSize(width: x, height: y)
        case .previewScale(let nodeID, let scaleX, let scaleY, let anchorX, let anchorY):
            scales[nodeID] = LiveUIPreviewScale(scaleX: scaleX, scaleY: scaleY, anchorX: anchorX, anchorY: anchorY)
        case .clearPreview:
            offsets.removeAll()
            scales.removeAll()
        case .requestSnapshot:
            break
        }
    }
}
