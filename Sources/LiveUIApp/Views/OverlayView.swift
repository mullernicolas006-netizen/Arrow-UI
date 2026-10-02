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

                    if let hitID = dragStartRuntimeID, let geometry = state.runtimeGeometry[hitID], let image = mirror.frame {
                        draggedContentPreview(image: image, geometry: geometry, transform: transform, canvasSize: proxy.size)
                    }

                    // Drawn after the content preview so the selection
                    // outline stays visible as a border around it, instead
                    // of being covered by it.
                    ForEach(Array(state.runtimeGeometry.keys.sorted()), id: \.self) { id in
                        if let geometry = state.runtimeGeometry[id] {
                            boxView(id: id, geometry: geometry, transform: transform)
                        }
                    }
                }
                .contentShape(Rectangle())
                .gesture(dragGesture(transform: transform))
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
        let isSelected = state.selection?.description == id
        let isDragging = dragStartRuntimeID == id
        let isHovered = hoveredRuntimeID == id

        if isSelected || isDragging || isHovered {
            let origin = transform.point(CGPoint(x: geometry.x, y: geometry.y))
            let size = transform.size(CGSize(width: geometry.width, height: geometry.height))

            // White stroke + .difference blend mode (the same trick Xcode/
            // design tools use for selection outlines): renders black
            // against light backgrounds and white against dark ones
            // automatically, so it's never invisible regardless of what's
            // under it.
            Rectangle()
                .strokeBorder(Color.white, lineWidth: isSelected || isDragging ? 2.5 : 1)
                .frame(width: max(size.width, 1), height: max(size.height, 1))
                .position(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
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
        }
    }

    /// While dragging, shows a floating "cutout" of the real mirrored
    /// pixels for the dragged view, following the cursor — not just an
    /// empty outline. The mirror itself is still only a polled screenshot
    /// (ARCHITECTURE.md's known limitation; it doesn't repaint mid-drag),
    /// so this is necessarily the view's last-known appearance rather
    /// than a true live re-render, but it's a real content preview, not a
    /// blank box: you see the actual button/text moving, and only the
    /// final rebuild (after the gesture ends) reflects any layout change
    /// the move itself causes.
    ///
    /// Built by re-rendering the *same already-loaded* mirror image, not
    /// by copying pixels out of it: shift the whole image so the dragged
    /// view's own region lands at the origin, constrain to a
    /// `size`-sized frame, and clip — a standard SwiftUI "window into a
    /// larger image" trick. That also means it's automatically aligned
    /// with `CanvasTransform`, since it reuses the exact `origin`/`size`
    /// math `boxView` uses for the selection outline.
    private func draggedContentPreview(image: NSImage, geometry: RuntimeGeometry, transform: CanvasTransform, canvasSize: CGSize) -> some View {
        let origin = transform.point(CGPoint(x: geometry.x, y: geometry.y))
        let size = transform.size(CGSize(width: geometry.width, height: geometry.height))

        return Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: canvasSize.width, height: canvasSize.height)
            .offset(x: -origin.x, y: -origin.y)
            .frame(width: max(size.width, 1), height: max(size.height, 1), alignment: .topLeading)
            .clipped()
            .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
            .position(
                x: origin.x + size.width / 2 + dragTranslation.width,
                y: origin.y + size.height / 2 + dragTranslation.height
            )
            .allowsHitTesting(false)
    }

    /// §21-26, transactional per §26: only the box being dragged previews
    /// the movement (via `dragTranslation`), and nothing is written to
    /// source until the gesture ends, at which point the raw drag is
    /// translated into a `Mutation` via `LayoutEngine.offsetMutation`.
    ///
    /// Writes `.offset(x:, y:)` on the dragged view itself — an explicit
    /// product decision (see ARCHITECTURE.md): earlier versions tried to
    /// approximate a drag with a semantic layout property (VStack
    /// `spacing`, then edge-specific `padding`), but that never lands
    /// exactly where the cursor was released and, worse, can visibly
    /// nudge a sibling as a side effect of changing a *shared* layout
    /// number. `.offset` is a pure rendering displacement — it never
    /// participates in the parent's layout pass, so it can't resize a
    /// stack or move anything else, and the view moves by exactly the
    /// delta given.
    ///
    /// Unlike the old single-axis approach, both components of the drag
    /// are applied — a diagonal drag no longer silently drops whichever
    /// axis moved less.
    private func dragGesture(transform: CanvasTransform) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .local)
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
                        } else {
                            print("[LiveUI] canvas: could NOT resolve '\(hitID)' to an indexed node")
                            state.lastError = "Couldn't match runtime view '\(hitID)' back to a node in the indexed source — check that its .liveUITag(file:) matches the file SourceIndexer sees."
                        }
                    } else {
                        print("[LiveUI] canvas: no hit at \(devicePoint)")
                    }
                }
                dragTranslation = value.translation
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
                if abs(deltaX) >= 1 {
                    applyOffset(hitID: hitID, axis: .horizontal, delta: deltaX)
                }
                if abs(deltaY) >= 1 {
                    applyOffset(hitID: hitID, axis: .vertical, delta: deltaY)
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
}
