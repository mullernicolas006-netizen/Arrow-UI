import SwiftUI
import LiveUICore
import LiveUIModels

/// The View Hierarchy section (§23): one disclosure tree per indexed file.
///
/// Content only — deliberately *not* wrapped in its own `List`. It's
/// embedded as sections inside `SidebarView`'s single shared List
/// alongside `InspectorRows` (see that file's doc comment for why they
/// share one List instead of being stacked as separate containers).
struct HierarchyRows: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ForEach(Array(state.fileIndexes.keys.sorted()), id: \.self) { file in
            Section((file as NSString).lastPathComponent) {
                ForEach(state.fileIndexes[file]?.roots ?? [], id: \.id) { node in
                    NodeRow(node: node)
                }
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
