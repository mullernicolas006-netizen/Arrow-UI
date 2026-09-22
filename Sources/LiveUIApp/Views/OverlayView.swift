import SwiftUI
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
                .gesture(dragGesture(transform: transform))
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

    private func boxView(id: String, geometry: RuntimeGeometry, transform: CanvasTransform) -> some View {
        let isSelected = state.selection?.description == id
        let isDragging = dragStartRuntimeID == id
        let origin = transform.point(CGPoint(x: geometry.x, y: geometry.y))
        let size = transform.size(CGSize(width: geometry.width, height: geometry.height))

        // White stroke + .difference blend mode (the same trick Xcode/
        // design tools use for selection outlines): renders black against
        // light backgrounds and white against dark ones automatically, so
        // it's never invisible regardless of what's under it.
        return Rectangle()
            .strokeBorder(Color.white, lineWidth: isSelected || isDragging ? 2.5 : 1)
            .frame(width: max(size.width, 1), height: max(size.height, 1))
            .position(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
            .offset(isDragging ? dragTranslation : .zero)
            .blendMode(.difference)
            .overlay(alignment: .topLeading) {
                Text(id)
                    .font(.system(size: 9))
                    .foregroundStyle(.white)
                    .blendMode(.difference)
            }
            // Hit-testing is done manually below, against `runtimeGeometry`
            // directly, so one gesture on the whole canvas handles both
            // selection and dragging instead of fighting per-box gestures.
            .allowsHitTesting(false)
    }

    /// §21-26, transactional per §26: only the box being dragged previews
    /// the movement (via `dragTranslation`), and nothing is written to
    /// source until the gesture ends, at which point the raw drag is
    /// translated into a semantic `Mutation` via `LayoutEngine`.
    ///
    /// Known limitation (see ARCHITECTURE.md): `parentType`/`stackNodeID`
    /// aren't wired up from the runtime yet (that needs `RuntimeViewInfo
    /// .parentID` to actually be populated, which today's manual
    /// `.liveUITag` call sites don't do), so every canvas drag currently
    /// takes LayoutEngine's padding fallback rather than the "grow the
    /// VStack's spacing" path — that smarter path is already proven end to
    /// end, just via the Inspector's stepper instead of a canvas drag.
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
                guard let node = state.node(forRuntimeID: hitID) else {
                    print("[LiveUI] canvas: drag ended but '\(hitID)' no longer resolves")
                    return
                }

                let axis: DragIntent.Axis = abs(value.translation.width) > abs(value.translation.height) ? .horizontal : .vertical
                let rawDelta = axis == .horizontal ? value.translation.width : value.translation.height
                print("[LiveUI] canvas: drag ended on \(node.id), translation=\(value.translation), axis=\(axis), rawDelta=\(rawDelta)")
                guard abs(rawDelta) >= 1, transform.scale > 0 else {
                    print("[LiveUI] canvas: delta too small or bad scale — no mutation")
                    return
                }

                let intent = DragIntent(
                    target: node.id,
                    parentType: nil,
                    axis: axis,
                    deltaPoints: rawDelta / transform.scale,
                    currentSpacingValue: nil,
                    currentPaddingValue: currentEdgePadding(of: node, edge: LayoutEngine.edgeName(for: axis))
                )
                let mutation = LayoutEngine.mutation(for: intent, stackNodeID: nil)
                print("[LiveUI] canvas: applying \(mutation)")
                state.apply(mutation)
            }
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

    /// Reads back the value of an existing `.padding(<edge>, N)` modifier
    /// on `node` *for the given edge*, but only when it's the outermost
    /// modifier in the chain — i.e. exactly where our own `addModifier`/
    /// drag mutations always land.
    ///
    /// The edge check matters as much as the outermost check: a vertical
    /// drag must only ever merge into an existing `.top` padding, never a
    /// `.leading` one left over from an earlier horizontal drag (that
    /// would silently apply a vertical delta to a horizontal value).
    ///
    /// Deliberately does not use `findModifierCall`, which returns the
    /// first "padding" match anywhere in the chain: a pre-existing,
    /// differently-shaped `.padding()` earlier in the chain (e.g. hand-
    /// written boilerplate) would match that lookup, fail the shape check
    /// below, and cause every drag to fall back to *adding* a new
    /// modifier forever — which is exactly what produced eleven stacked
    /// `.padding(...)` calls in testing. Checking specifically the
    /// outermost modifier means we only ever merge into a modifier we
    /// know we (or an equivalent edit) actually added.
    private func currentEdgePadding(of node: IndexedNode, edge: String) -> Int? {
        let outermost = SwiftSyntaxEngine.outermostChainedExpr(startingFrom: node.callExpression)
        guard let call = outermost.as(FunctionCallExprSyntax.self),
              let member = call.calledExpression.as(MemberAccessExprSyntax.self),
              member.declName.baseName.text == "padding" else {
            return nil
        }
        let args = Array(call.arguments)
        guard args.count == 2, args[0].label == nil, args[1].label == nil,
              let edgeMember = args[0].expression.as(MemberAccessExprSyntax.self),
              edgeMember.declName.baseName.text == edge else {
            return nil
        }
        return Int(args[1].expression.description.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
