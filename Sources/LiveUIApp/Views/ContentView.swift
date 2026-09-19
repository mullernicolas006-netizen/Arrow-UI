import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @State private var showingImporter = false

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Button("Open Project…") { showingImporter = true }
                    Spacer()
                    Button {
                        state.reindex()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Re-index (pick up external code changes, §24 Code → Editor)")
                }
                .padding(8)

                Divider()
                HierarchyView()
            }
        } content: {
            OverlayView()
        } detail: {
            InspectorView()
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            _ = url.startAccessingSecurityScopedResource()
            state.openProject(at: url)
        }
        .alert("LiveUI", isPresented: .constant(state.lastError != nil), presenting: state.lastError) { _ in
            Button("OK") { state.lastError = nil }
        } message: { message in
            Text(message)
        }
    }
}
