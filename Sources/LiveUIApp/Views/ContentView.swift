import SwiftUI

/// Three-panel layout: hierarchy + inspector on the left, the visual
/// canvas in the middle (today: a geometry wireframe; the planned next
/// step is mirroring the Simulator's real pixels into this same spot),
/// and the code diff on the right (§20, §23, §28).
struct ContentView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } content: {
            OverlayView()
                .navigationSplitViewColumnWidth(min: 360, ideal: 520)
        } detail: {
            ChangesView()
                .navigationSplitViewColumnWidth(min: 320, ideal: 420)
        }
        .alert("LiveUI", isPresented: .constant(state.lastError != nil), presenting: state.lastError) { _ in
            Button("OK") { state.lastError = nil }
        } message: { message in
            Text(message)
        }
    }
}
