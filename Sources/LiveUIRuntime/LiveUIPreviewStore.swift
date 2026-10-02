import SwiftUI
import Combine
import LiveUIModels

/// Live drag-preview state, shared by every `.liveUITag`'d view in the
/// running app (§25). While a canvas drag is in flight on the desktop
/// side, `OverlayView` streams `BridgeMessage.previewMutation` over the
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
@MainActor
public final class LiveUIPreviewStore: ObservableObject {
    @Published public var offsets: [String: CGSize] = [:]

    public init() {}

    public func apply(_ message: BridgeMessage) {
        switch message {
        case .previewMutation(let nodeID, let property, let value):
            var size = offsets[nodeID] ?? .zero
            switch property {
            case "offsetX": size.width = value
            case "offsetY": size.height = value
            default: return
            }
            offsets[nodeID] = size
        case .clearPreview:
            offsets.removeAll()
        case .requestSnapshot:
            break
        }
    }
}
