import SwiftUI
import AppKit
import SwiftSyntax
import LiveUICore
import LiveUIModels

/// The middle panel — the canvas (§8, §22-23). Shows the mirrored
/// Simulator screen with a selection/drag overlay on top, and is the
/// actual direct-manipulation surface described in §21-26: click a view
/// to select it, drag it to nudge its layout — no Inspector required.
///
/// The mirrored image is a polled screenshot (see `SimulatorScreenMirror`
/// — a deliberate, honest limitation: a few frames per second, not true
/// video). The overlay boxes come from `RuntimeGeometry`, and both are
/// aligned through the same `CanvasTransform` so they land in the same
/// place regardless of window size.
struct OverlayView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var mirror = SimulatorScreenMirror()
    @State private var dragStartRuntimeID: String?
    @State private var dragTranslation: CGSize = .zero
    /// The innermost view currently under the mouse (hit-tested the same
    /// way a click is), so the canvas can show *one* outline at a time
    /// instead of every view's box simultaneously. Showing all of them at
    /// once — e.g. a VStack's box and its Button child's box, which always
    /// overlap since the parent encloses the child — was indistinguishable
    /// from "the wrong view moved" and made the canvas look like visual
    /// noise; this is the actual fix for both complaints.
    @State private var hoveredRuntimeID: String?
    /// Which view (if any) a resize handle is currently being dragged
    /// for, which corner, and the raw canvas-space translation so far —
    /// the resize counterpart to `dragStartRuntimeID`/`dragTranslation`.
    @State private var resizingRuntimeID: String?
    @State private var resizeHandle: ResizeHandle?
    @State private var resizeTranslation: CGSize = .zero

    var body: some View {
        VStack(spacing: 0) {
            statusBar

            GeometryReader { proxy in
                let transform = CanvasTransform(deviceSize: state.deviceScreenSize, canvasSize: proxy.size)

                ZStack(alignment: .topLeading) {
                    Rectangle().fill(Color.gray.opacity(0.08))

                    if let image = mirror.frame {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .allowsHitTesting(false)
                    }

                    ForEach(Array(state.runtimeGeometry.keys.sorted()), id: \.self) { id in
                        if let geometry = state.runtimeGeometry[id] {
                            boxView(id: id, geometry: geometry, transform: transform)
                        }
                    }
                }
                .contentShape(Rectangle())
                // Selection and move/resize are two separate gestures,
                // composed with .simultaneously — see tapGesture's doc
                // comment for why a plain DragGesture alone (even at
                // minimumDistance: 0) isn't reliable for "click selects."
                .gesture(dragGesture(transform: transform).simultaneously(with: tapGesture(transform: transform)))
                .onContinuousHover { phase in
                    // Suppressed mid-drag: otherwise the mouse passing over
                    // a different view while dragging would show a second,
                    // unrelated box alongside the one actually being
                    // dragged.
                    guard dragStartRuntimeID == nil else { return }
                    switch phase {
                    case .active(let location):
                        hoveredRuntimeID = hitTest(devicePoint: transform.devicePoint(location))
                    case .ended:
                        hoveredRuntimeID = nil
                    }
                }
            }
            .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { mirror.start() }
        .onDisappear { mirror.stop() }
    }

    private var statusBar: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(state.isRuntimeConnected ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            Text(state.isRuntimeConnected ? "Runtime connected" : "Waiting for runtime…")
                .font(.caption)
            Text("· \(state.runtimeGeometry.count) view(s)")
                .font(.caption)
                .foregroundStyle(.secondary)
            if state.isBuilding {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 12, height: 12)
            }
            if let status = state.buildStatus {
                Text("· \(status)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if let error = mirror.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .help(error)
            }
        }
        .padding(8)
    }

    /// Only draws a box for the view that's selected, actively being
    /// dragged, or directly under the mouse right now — never all known
    /// views at once. A parent's box always encloses its children's (a
    /// VStack always contains its Button), so drawing every box
    /// permanently made the canvas an unreadable stack of overlapping
    /// rectangles and looked like dragging one view moved another one.
    @ViewBuilder
    private func boxView(id: String, geometry: RuntimeGeometry, transform: CanvasTransform) -> some View {
        let isSelected = state.selectedRuntimeID == id
        let isDragging = dragStartRuntimeID == id
        let isHovered = hoveredRuntimeID == id
        let isResizing = resizingRuntimeID == id

        if isSelected || isDragging || isHovered {
            let origin = transform.point(CGPoint(x: geometry.x, y: geometry.y))
            let size = transform.size(CGSize(width: geometry.width, height: geometry.height))
            // Live-previews a resize locally (zero network latency) by
            // adjusting the box's own rect per the active handle, before
            // any mutation/rebuild — the resize counterpart to
            // `dragTranslation` nudging the box during a move.
            let rect = isResizing
                ? resizedRect(origin: origin, size: size, handle: resizeHandle, translation: resizeTranslation)
                : CGRect(origin: origin, size: size)

            // White stroke + .difference blend mode (the same trick Xcode/
            // design tools use for selection outlines): renders black
            // against light backgrounds and white against dark ones
            // automatically, so it's never invisible regardless of what's
            // under it.
            Rectangle()
                .strokeBorder(Color.white, lineWidth: isSelected || isDragging || isResizing ? 2.5 : 1)
                .frame(width: max(rect.width, 1), height: max(rect.height, 1))
                .position(x: rect.midX, y: rect.midY)
                .offset(isDragging ? dragTranslation : .zero)
                .blendMode(.difference)
                .overlay(alignment: .topLeading) {
                    // Just the type name ("Button"), not the full
                    // "Button@ContentView.swift#1" runtime id — that's
                    // debugging detail, not something a user needs to see
                    // on every hover.
                    Text(id.components(separatedBy: "@").first ?? id)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white)
                        .blendMode(.difference)
                        .padding(.leading, 2)
                }
                // Hit-testing is done manually below, against
                // `runtimeGeometry` directly, so one gesture on the whole
                // canvas handles both selection and dragging instead of
                // fighting per-box gestures.
                .allowsHitTesting(false)

            // Resize handles only ever show on the *selected* view, not
            // on hover — unlike the outline itself, which is also shown
            // on hover so you can see what you're about to click.
            if isSelected {
                ForEach(ResizeHandle.allCases, id: \.self) { handle in
                    resizeHandleView(id: id, handle: handle, rect: rect, transform: transform)
                }
            }
        }
    }

    /// One corner of a selected view's resize affordance. `isLeft`/
    /// `isTop` say which edges that corner sits on — used both to pick
    /// the right sign for the size delta and to decide whether dragging
    /// it should *also* nudge the view's offset (so the opposite corner
    /// stays anchored in place, the way every other design tool's corner
    /// handles behave: dragging the top-left handle grows the view
    /// toward the top-left, it doesn't grow away from it).
    private enum ResizeHandle: CaseIterable, Hashable {
        case topLeft, topRight, bottomLeft, bottomRight

        var isLeft: Bool { self == .topLeft || self == .bottomLeft }
        var isTop: Bool { self == .topLeft || self == .topRight }
    }

    /// `rect` adjusted for the in-flight resize translation, purely for
    /// the local, zero-latency on-canvas preview — the same sign logic
    /// `resizeGesture`'s `onEnded` uses to build the real mutations.
    private func resizedRect(origin: CGPoint, size: CGSize, handle: ResizeHandle?, translation: CGSize) -> CGRect {
        guard let handle else { return CGRect(origin: origin, size: size) }
        var x = origin.x, y = origin.y, width = size.width, height = size.height
        if handle.isLeft {
            x += translation.width
            width -= translation.width
        } else {
            width += translation.width
        }
        if handle.isTop {
            y += translation.height
            height -= translation.height
        } else {
            height += translation.height
        }
        return CGRect(x: x, y: y, width: max(width, 1), height: max(height, 1))
    }

    /// The handle's visible dot is small (so it doesn't obscure the
    /// content at the corner it sits on), but its *hit area* is much
    /// bigger — a 9pt dot is a genuinely hard target to land a mouse on,
    /// especially since the canvas itself is scaled by `CanvasTransform`.
    /// `hitAreaSize` is the actual draggable region; only `dotSize` of it
    /// is drawn.
    private let resizeHandleHitAreaSize: CGFloat = 22
    private let resizeHandleDotSize: CGFloat = 9

    private func resizeHandleView(id: String, handle: ResizeHandle, rect: CGRect, transform: CanvasTransform) -> some View {
        let point: CGPoint
        switch handle {
        case .topLeft: point = CGPoint(x: rect.minX, y: rect.minY)
        case .topRight: point = CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeft: point = CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomRight: point = CGPoint(x: rect.maxX, y: rect.maxY)
        }
        return ZStack {
            Color.clear
                .frame(width: resizeHandleHitAreaSize, height: resizeHandleHitAreaSize)
                .contentShape(Rectangle())
            Circle()
                .fill(Color.white)
                .overlay(Circle().strokeBorder(Color.black.opacity(0.4), lineWidth: 1))
                .frame(width: resizeHandleDotSize, height: resizeHandleDotSize)
                .shadow(color: .black.opacity(0.3), radius: 1.5)
                .allowsHitTesting(false)
        }
        .position(point)
        // highPriorityGesture, not gesture: a handle sits right at
        // the edge of the view it belongs to, so the same touch is
        // also inside the canvas-wide move-drag gesture's hit area.
        // Without this, a drag started exactly on a handle could
        // trigger *both* gestures — a resize and a conflicting move
        // — instead of just the resize.
        .highPriorityGesture(resizeGesture(id: id, handle: handle, transform: transform))
        // SwiftUI never changes the cursor on its own — this is the
        // part that makes a handle actually *feel* like a resize
        // control rather than just another draggable dot. AppKit has no
        // public diagonal-resize NSCursor (only resizeLeftRight /
        // resizeUpDown), so this builds one from an SF Symbol instead of
        // reaching for a private/undocumented cursor selector.
        .onHover { isHovering in
            if isHovering {
                resizeCursor(for: handle).set()
            } else {
                NSCursor.arrow.set()
            }
        }
    }

    /// AppKit's public `NSCursor` API has no diagonal resize cursor —
    /// only `.resizeLeftRight`/`.resizeUpDown`. Building one from an SF
    /// Symbol (`arrow.up.left.and.arrow.down.right` /
    /// `arrow.up.right.and.arrow.down.left`, both literally diagonal
    /// double-headed arrows) is the honest way to get that look without
    /// a private API or a shipped image asset.
    private func resizeCursor(for handle: ResizeHandle) -> NSCursor {
        let alongTopLeftToBottomRight = handle == .topLeft || handle == .bottomRight
        let symbolName = alongTopLeftToBottomRight ? "arrow.up.left.and.arrow.down.right" : "arrow.up.right.and.arrow.down.left"
        guard let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) else {
            return .arrow
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: image.size.width / 2, y: image.size.height / 2))
    }

    /// Dragging a corner handle: the two edges meeting at that corner
    /// move with the cursor, the two opposite edges stay put — exactly
    /// like `.offsetMutation`, this writes `.frame(width:, height:)` (and,
    /// for top/left handles, also `.offset(x:, y:)`), never a spacing or
    /// padding hack, so a resize can never affect a sibling.
    ///
    /// Unlike the move-drag gesture, this doesn't yet stream a live
    /// preview to the running app over the bridge — only the local
    /// outline previews the resize in flight. Adding that hit a real
    /// composition problem a move-drag doesn't: a repeated resize's live
    /// override would need to apply *outside* whatever `.frame()` a
    /// previous resize's rebuild already compiled in, but `.liveUITag`
    /// sits *inside* the modifier chain, so a second live-preview resize
    /// would just get re-constrained by the already-compiled outer
    /// `.frame()`. Left as a known gap (see ARCHITECTURE.md) rather than
    /// worked around here.
    private func resizeGesture(id: String, handle: ResizeHandle, transform: CanvasTransform) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .local)
            .onChanged { value in
                resizingRuntimeID = id
                resizeHandle = handle
                resizeTranslation = value.translation
            }
            .onEnded { value in
                defer {
                    resizingRuntimeID = nil
                    resizeHandle = nil
                    resizeTranslation = .zero
                    // Belt-and-suspenders alongside the handle's own
                    // .onHover: during an active drag, the mouse is often
                    // far from the handle's hit area by the time the
                    // gesture ends, and hover-exit tracking isn't fully
                    // reliable mid-gesture — this guarantees the cursor
                    // doesn't get stuck as a resize icon.
                    NSCursor.arrow.set()
                }
                guard transform.scale > 0 else {
                    print("[LiveUI] canvas: resize ended — bad scale, no mutation")
                    return
                }

                let deltaX = value.translation.width / transform.scale
                let deltaY = value.translation.height / transform.scale
                let widthDelta = handle.isLeft ? -deltaX : deltaX
                let heightDelta = handle.isTop ? -deltaY : deltaY
                print("[LiveUI] canvas: resize ended on \(id) via \(handle), translation=\(value.translation) -> width delta=\(widthDelta), height delta=\(heightDelta)")

                if abs(widthDelta) >= 1 {
                    applySize(hitID: id, axis: .horizontal, delta: widthDelta)
                }
                if handle.isLeft, abs(deltaX) >= 1 {
                    applyOffset(hitID: id, axis: .horizontal, delta: deltaX)
                }
                if abs(heightDelta) >= 1 {
                    applySize(hitID: id, axis: .vertical, delta: heightDelta)
                }
                if handle.isTop, abs(deltaY) >= 1 {
                    applyOffset(hitID: id, axis: .vertical, delta: deltaY)
                }
            }
    }

    /// A dedicated gesture purely for "click selects" — separate from
    /// `dragGesture`, which handles move/mutate. A plain `DragGesture`,
    /// even with `minimumDistance: 0`, is built around tracking *motion*:
    /// on macOS it's driven by `mouseDragged` events, which a genuinely
    /// stationary click (`mouseDown` immediately followed by `mouseUp`,
    /// no movement in between) never generates — so `onChanged` can
    /// simply never fire for a real click, no matter how low
    /// `minimumDistance` is set, and nothing gets selected. That was the
    /// actual cause of "clicking doesn't select, and resize handles never
    /// show up" — not a hit-testing or handle-size problem (both already
    /// fixed, but neither mattered if selection itself never happened).
    ///
    /// `SpatialTapGesture` is built on an actual click recognizer
    /// (`mouseDown`/`mouseUp`), not motion-tracking, so it fires reliably
    /// for a real click regardless of whether the mouse moved at all.
    /// Composed with `dragGesture` via `.simultaneously(with:)` so both
    /// can recognize independently on the same view — a plain click
    /// selects via this gesture even if `dragGesture` never starts, and
    /// an actual drag still moves/resizes via `dragGesture` as before.
    private func tapGesture(transform: CanvasTransform) -> some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                let devicePoint = transform.devicePoint(value.location)
                print("[LiveUI] canvas: tap at canvas=\(value.location) -> device=\(devicePoint)")
                guard let hitID = hitTest(devicePoint: devicePoint) else {
                    print("[LiveUI] canvas: tap hit nothing")
                    return
                }
                guard let node = state.node(forRuntimeID: hitID) else {
                    print("[LiveUI] canvas: tap hit '\(hitID)' but it doesn't resolve to an indexed node")
                    return
                }
                state.selection = node.id
                state.selectedRuntimeID = hitID
            }
    }

    /// §21-26, transactional per §26: nothing is written to source until
    /// the gesture ends, at which point the raw drag is translated into a
    /// `Mutation` via `LayoutEngine.offsetMutation`.
    ///
    /// While the drag is *in flight*, every `.onChanged` tick also streams
    /// a live preview straight to the running app over the existing
    /// bridge connection (`BridgeMessage.previewOffset`, §25) — the
    /// *actual* button/text in the Simulator moves in real time, not a
    /// screenshot crop and not just the desktop-side outline box. See
    /// `LiveUIPreviewStore` on the runtime side for how that's applied.
    /// This needs a connected runtime to do anything visible; with none
    /// connected it's a harmless no-op and the outline box is all you see,
    /// same as before.
    ///
    /// Writes `.offset(x:, y:)` on the dragged view itself once the drag
    /// ends — an explicit product decision (see ARCHITECTURE.md): earlier
    /// versions tried to approximate a drag with a semantic layout
    /// property (VStack `spacing`, then edge-specific `padding`), but
    /// that never lands exactly where the cursor was released and, worse,
    /// can visibly nudge a sibling as a side effect of changing a
    /// *shared* layout number. `.offset` is a pure rendering displacement
    /// — it never participates in the parent's layout pass, so it can't
    /// resize a stack or move anything else, and the view moves by
    /// exactly the delta given. Both axes of a diagonal drag are applied
    /// independently, not just whichever moved more.
    ///
    /// `minimumDistance: 0` deliberately: selection (`state.selection`,
    /// which is what makes resize handles show up at all) only ever
    /// happens here, in `onChanged`. With a larger minimum distance, a
    /// plain click with no mouse movement never fired `onChanged` at
    /// all, so a stationary click never selected anything — the view
    /// could only be selected as a side effect of also nudging it. At
    /// 0, `onChanged` fires immediately on mouse-down, so a plain click
    /// selects the view; `onEnded`'s own `abs(delta) >= 1` thresholds
    /// still mean a click with no real movement never writes a mutation.
    private func dragGesture(transform: CanvasTransform) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                if dragStartRuntimeID == nil {
                    let devicePoint = transform.devicePoint(value.startLocation)
                    print("[LiveUI] canvas: drag started at canvas=\(value.startLocation) -> device=\(devicePoint), \(state.runtimeGeometry.count) known views")
                    if let hitID = hitTest(devicePoint: devicePoint) {
                        print("[LiveUI] canvas: hit '\(hitID)'")
                        dragStartRuntimeID = hitID
                        if let node = state.node(forRuntimeID: hitID) {
                            print("[LiveUI] canvas: resolved to node \(node.id)")
                            state.selection = node.id
                            state.selectedRuntimeID = hitID
                        } else {
                            print("[LiveUI] canvas: could NOT resolve '\(hitID)' to an indexed node")
                            state.lastError = "Couldn't match runtime view '\(hitID)' back to a node in the indexed source — check that its .liveUITag(file:) matches the file SourceIndexer sees."
                        }
                    } else {
                        print("[LiveUI] canvas: no hit at \(devicePoint)")
                    }
                }
                dragTranslation = value.translation

                if let hitID = dragStartRuntimeID, transform.scale > 0 {
                    let deltaX = value.translation.width / transform.scale
                    let deltaY = value.translation.height / transform.scale
                    // One message per tick, both axes together — two
                    // separate messages meant two separate `@Published`
                    // updates (and renders) on the runtime side per tick,
                    // which looked like the view taking two small steps
                    // instead of one smooth one.
                    //
                    // Deliberately no print() here: a drag gesture's
                    // onChanged can fire dozens of times per second, and
                    // real testing showed that logging every single tick
                    // (here and in LiveUIPreviewStore.apply) floods
                    // Xcode's debug console fast enough to get the app
                    // killed outright ("Terminated due to signal 9") —
                    // not a bug in the preview mechanism itself, which
                    // the same flooded log actually proved was working.
                    state.sendPreview(.previewOffset(nodeID: hitID, x: deltaX, y: deltaY))
                }
            }
            .onEnded { value in
                defer {
                    dragStartRuntimeID = nil
                    dragTranslation = .zero
                }
                guard let hitID = dragStartRuntimeID else {
                    print("[LiveUI] canvas: drag ended with no active hit — nothing to do")
                    return
                }
                guard transform.scale > 0 else {
                    print("[LiveUI] canvas: bad scale — no mutation")
                    state.sendPreview(.clearPreview)
                    return
                }

                let deltaX = value.translation.width / transform.scale
                let deltaY = value.translation.height / transform.scale
                print("[LiveUI] canvas: drag ended on \(hitID), translation=\(value.translation) -> device delta=(\(deltaX), \(deltaY))")

                // Both axes are applied independently (each as its own
                // mutation, re-resolving the node in between so the second
                // one sees the first one's on-disk result) — a diagonal
                // drag must move the view diagonally, not just along
                // whichever axis happened to be larger.
                var mutated = false
                if abs(deltaX) >= 1 {
                    applyOffset(hitID: hitID, axis: .horizontal, delta: deltaX)
                    mutated = true
                }
                if abs(deltaY) >= 1 {
                    applyOffset(hitID: hitID, axis: .vertical, delta: deltaY)
                    mutated = true
                }

                // A real drag leaves the live preview exactly where it
                // was — it bridges smoothly into the rebuild/relaunch
                // that's now in flight, since the relaunched app is a
                // fresh process where this transient state no longer
                // exists anyway, replaced by the newly-compiled real
                // .offset(). A no-op drag (below the threshold on both
                // axes) wrote nothing to source, so the preview has to be
                // reverted here instead, or the real app would be left
                // visibly nudged by an amount nothing on disk accounts
                // for.
                if !mutated {
                    state.sendPreview(.clearPreview)
                }
            }
    }

    private func applyOffset(hitID: String, axis: DragIntent.Axis, delta: Double) {
        guard let node = state.node(forRuntimeID: hitID) else {
            print("[LiveUI] canvas: drag ended but '\(hitID)' no longer resolves")
            return
        }
        let offset = currentOffset(of: node)
        let mutation = LayoutEngine.offsetMutation(target: node.id, currentOffset: offset, axis: axis, delta: delta)
        print("[LiveUI] canvas: applying \(mutation)")
        state.apply(mutation)
    }

    private func applySize(hitID: String, axis: DragIntent.Axis, delta: Double) {
        guard let node = state.node(forRuntimeID: hitID) else {
            print("[LiveUI] canvas: resize ended but '\(hitID)' no longer resolves")
            return
        }
        guard let geometry = state.runtimeGeometry[hitID] else {
            print("[LiveUI] canvas: resize ended but '\(hitID)' has no known geometry")
            return
        }
        let existingFrame = currentFrame(of: node)
        let measured = (width: Int(geometry.width.rounded()), height: Int(geometry.height.rounded()))
        let mutation = LayoutEngine.sizeMutation(target: node.id, existingFrame: existingFrame, measuredSize: measured, axis: axis, delta: delta)
        print("[LiveUI] canvas: applying \(mutation)")
        state.apply(mutation)
    }

    /// A parent container's box always encloses its children's boxes —
    /// dragging the Button inside a VStack means the click point is
    /// simultaneously "inside" both the Button's and the VStack's
    /// geometry. Picking the *smallest* enclosing box (not just any
    /// match) is what makes this behave like every other design tool:
    /// click/drag always targets the most specific thing under the
    /// cursor, not an arbitrary ancestor.
    private func hitTest(devicePoint: CGPoint) -> String? {
        var best: (id: String, area: Double)?
        for (id, geometry) in state.runtimeGeometry {
            let rect = CGRect(x: geometry.x, y: geometry.y, width: geometry.width, height: geometry.height)
            guard rect.contains(devicePoint) else { continue }
            let area = geometry.width * geometry.height
            if best == nil || area < best!.area {
                best = (id, area)
            }
        }
        return best?.id
    }

    /// Reads back an existing `.offset(x:, y:)` modifier on `node`, if any
    /// — searching the *entire* modifier chain, not just the outermost
    /// link, since earlier modifiers (like this one, once added) can be
    /// pushed inward by whatever gets appended after them. Lets
    /// `LayoutEngine.offsetMutation` accumulate onto the existing value
    /// instead of stacking a second `.offset` call on every drag.
    private func currentOffset(of node: IndexedNode) -> (x: Int, y: Int)? {
        guard let call = SwiftSyntaxEngine.findModifierCall(named: "offset", startingFrom: node.callExpression),
              let xArg = SwiftSyntaxEngine.argument(in: call, label: "x", index: 0),
              let yArg = SwiftSyntaxEngine.argument(in: call, label: "y", index: 1),
              let x = Int(xArg.expression.description.trimmingCharacters(in: .whitespacesAndNewlines)),
              let y = Int(yArg.expression.description.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return (x, y)
    }

    /// Reads back an existing `.frame(width:, height:)` modifier on
    /// `node`, if any — same whole-chain search and the same reason as
    /// `currentOffset`. `nil` means "no explicit frame yet," which
    /// `LayoutEngine.sizeMutation` treats as "fall back to the view's
    /// measured size," not as "treat the missing dimension as 0."
    private func currentFrame(of node: IndexedNode) -> (width: Int, height: Int)? {
        guard let call = SwiftSyntaxEngine.findModifierCall(named: "frame", startingFrom: node.callExpression),
              let widthArg = SwiftSyntaxEngine.argument(in: call, label: "width", index: 0),
              let heightArg = SwiftSyntaxEngine.argument(in: call, label: "height", index: 1),
              let width = Int(widthArg.expression.description.trimmingCharacters(in: .whitespacesAndNewlines)),
              let height = Int(heightArg.expression.description.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return (width, height)
    }
}
