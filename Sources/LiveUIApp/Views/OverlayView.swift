import SwiftUI
import LiveUIModels

/// The middle panel: a geometry-driven wireframe of whatever the connected
/// runtime last reported (§8, §22-23), plus the diff from the most recent
/// mutation (§28).
///
/// Note (see ARCHITECTURE.md "Known gaps"): this draws boxes from reported
/// `RuntimeGeometry`, it does not mirror the Simulator's actual pixels.
/// True click-through-to-real-pixels embedding is a separate integration
/// (screen capture + input forwarding) layered on top of this same data.
struct OverlayView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Circle()
                    .fill(state.isRuntimeConnected ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(state.isRuntimeConnected ? "Runtime connected" : "Waiting for runtime…")
                    .font(.caption)
                Spacer()
            }
            .padding(8)

            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(Color.gray.opacity(0.08))
                    ForEach(Array(state.runtimeGeometry.keys.sorted()), id: \.self) { id in
                        if let geometry = state.runtimeGeometry[id] {
                            boxView(id: id, geometry: geometry)
                        }
                    }
                }
            }
            .clipped()

            if !state.lastDiff.isEmpty {
                Divider()
                DiffView(diff: state.lastDiff)
                    .frame(maxHeight: 180)
            }
        }
    }

    private func boxView(id: String, geometry: RuntimeGeometry) -> some View {
        let isSelected = state.selection?.description == id
        return Rectangle()
            .strokeBorder(isSelected ? Color.accentColor : Color.secondary, lineWidth: isSelected ? 2 : 1)
            .frame(width: max(geometry.width, 1), height: max(geometry.height, 1))
            .position(x: geometry.x + geometry.width / 2, y: geometry.y + geometry.height / 2)
            .overlay(alignment: .topLeading) {
                Text(id)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .padding(2)
                    .position(x: geometry.x + 24, y: geometry.y - 6)
            }
    }
}
