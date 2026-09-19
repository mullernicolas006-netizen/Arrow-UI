import SwiftUI
import LiveUICore
import LiveUIModels

/// The View Hierarchy panel (§23): one disclosure tree per indexed file,
/// selection here drives both the Inspector and the overlay highlight.
struct HierarchyView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        List(selection: $state.selection) {
            ForEach(Array(state.fileIndexes.keys.sorted()), id: \.self) { file in
                Section((file as NSString).lastPathComponent) {
                    ForEach(state.fileIndexes[file]?.roots ?? [], id: \.id) { node in
                        NodeRow(node: node)
                    }
                }
            }
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
}

private struct NodeRow: View {
    let node: IndexedNode

    var body: some View {
        if node.children.isEmpty {
            Label(node.id.typeName, systemImage: icon(for: node.id.typeName))
                .tag(node.id)
        } else {
            DisclosureGroup {
                ForEach(node.children, id: \.id) { child in
                    NodeRow(node: child)
                }
            } label: {
                Label(node.id.typeName, systemImage: icon(for: node.id.typeName))
                    .tag(node.id)
            }
        }
    }

    private func icon(for typeName: String) -> String {
        switch typeName {
        case "VStack", "HStack", "ZStack": return "square.stack.3d.up"
        case "Text": return "textformat"
        case "Button": return "hand.tap"
        case "Image": return "photo"
        case "TextField": return "text.cursor"
        default: return "square.dashed"
        }
    }
}
