import SwiftUI
import UniformTypeIdentifiers

/// Left panel: project controls on top, then one shared `List` containing
/// both the Hierarchy and the Inspector as sections (§20, §23).
///
/// This used to be a `List` (hierarchy) and a `Form` (inspector) stacked
/// in a plain `VStack`. Two different scrollable container types fighting
/// over layout inside a `NavigationSplitView` sidebar column produced
/// broken results — the inspector would detach from the column instead of
/// sitting cleanly below the hierarchy. One `List` with multiple
/// `Section`s is the standard, robust macOS sidebar shape, so that's what
/// `HierarchyRows`/`InspectorRows` are written to plug into here.
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

            List(selection: $state.selection) {
                HierarchyRows()
                InspectorRows()
            }
            .overlay {
                if state.fileIndexes.isEmpty {
                    ContentUnavailableView(
                        "No Project Open",
                        systemImage: "folder",
                        description: Text("Open a SwiftUI project to see its view hierarchy.")
                    )
                }
            }
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            _ = url.startAccessingSecurityScopedResource()
            state.openProject(at: url)
        }
    }
}
