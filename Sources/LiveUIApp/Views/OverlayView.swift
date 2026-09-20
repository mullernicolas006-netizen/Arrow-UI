import SwiftUI
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

        return Rectangle()
            .strokeBorder(isSelected ? Color.accentColor : Color.secondary, lineWidth: isSelected ? 2 : 1)
            .frame(width: max(size.width, 1), height: max(size.height, 1))
            .position(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
            .offset(isDragging ? dragTranslation : .zero)
            .overlay(alignment: .topLeading) {
                Text(id)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
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
                    if let hitID = hitTest(devicePoint: devicePoint) {
                        dragStartRuntimeID = hitID
                        if let node = state.node(forRuntimeID: hitID) {
                            state.selection = node.id
                        }
                    }
                }
                dragTranslation = value.translation
            }
            .onEnded { value in
                defer {
                    dragStartRuntimeID = nil
                    dragTranslation = .zero
                }
                guard let hitID = dragStartRuntimeID, let node = state.node(forRuntimeID: hitID) else { return }

                let axis: DragIntent.Axis = abs(value.translation.width) > abs(value.translation.height) ? .horizontal : .vertical
                let rawDelta = axis == .horizontal ? value.translation.width : value.translation.height
                guard abs(rawDelta) >= 1, transform.scale > 0 else { return }

                let intent = DragIntent(
                    target: node.id,
                    parentType: nil,
                    axis: axis,
                    deltaPoints: rawDelta / transform.scale,
                    currentSpacingValue: nil
                )
                state.apply(LayoutEngine.mutation(for: intent, stackNodeID: nil))
            }
    }

    private func hitTest(devicePoint: CGPoint) -> String? {
        for (id, geometry) in state.runtimeGeometry {
            let rect = CGRect(x: geometry.x, y: geometry.y, width: geometry.width, height: geometry.height)
            if rect.contains(devicePoint) { return id }
        }
        return nil
    }
}
