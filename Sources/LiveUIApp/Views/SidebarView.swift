import SwiftUI
import UniformTypeIdentifiers

/// Left panel: project controls + hierarchy on top, the property
/// Inspector filling the rest of the space below it (§20, §23).
struct SidebarView: View {
    @EnvironmentObject var state: AppState
    @State private var showingImporter = false

    var body: some View {
        VStack(spacing: 0) {
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
                .frame(maxHeight: .infinity)

            Divider()
            InspectorView()
                .frame(maxHeight: .infinity)
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            _ = url.startAccessingSecurityScopedResource()
            state.openProject(at: url)
        }
    }
}
