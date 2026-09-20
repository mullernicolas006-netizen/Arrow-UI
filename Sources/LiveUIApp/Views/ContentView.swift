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
        } content: {
            OverlayView()
        } detail: {
            ChangesView()
        }
        .alert("LiveUI", isPresented: .constant(state.lastError != nil), presenting: state.lastError) { _ in
            Button("OK") { state.lastError = nil }
        } message: { message in
            Text(message)
        }
    }
}
