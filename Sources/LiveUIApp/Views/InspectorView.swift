import SwiftUI
import SwiftSyntax
import LiveUICore
import LiveUIModels

/// The Property Inspector (§20): shows the selected node's location, and —
/// for the MVP — an editable `spacing` field for `VStack`/`HStack`, wired
/// straight into `MutationEngine` through `AppState.apply`. This is the
/// smallest possible end-to-end slice of §69's "holy grail": move a
/// number here, watch the real Swift source change.
struct InspectorView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Group {
            if let selection = state.selection, let node = findNode(selection) {
                Form {
                    Section("Selected") {
                        LabeledContent("Type", value: node.id.typeName)
                        LabeledContent("File", value: (node.id.file as NSString).lastPathComponent)
                        LabeledContent("Path", value: node.id.path.description)
                    }

                    if node.id.typeName == "VStack" || node.id.typeName == "HStack" {
                        SpacingEditor(node: node)
                    }

                    if let geometry = state.runtimeGeometry[node.id.description] {
                        Section("Live Geometry") {
                            LabeledContent("x", value: geometry.x, format: .number)
                            LabeledContent("y", value: geometry.y, format: .number)
                            LabeledContent("width", value: geometry.width, format: .number)
                            LabeledContent("height", value: geometry.height, format: .number)
                        }
                    }
                }
                .formStyle(.grouped)
            } else {
                ContentUnavailableView("No Selection", systemImage: "cursorarrow.click")
            }
        }
    }

    private func findNode(_ id: ViewNodeID) -> IndexedNode? {
        for index in state.fileIndexes.values {
            if let found = search(id, in: index.roots) { return found }
        }
        return nil
    }

    private func search(_ id: ViewNodeID, in nodes: [IndexedNode]) -> IndexedNode? {
        for node in nodes {
            if node.id == id { return node }
            if let found = search(id, in: node.children) { return found }
        }
        return nil
    }
}

private struct SpacingEditor: View {
    let node: IndexedNode
    @EnvironmentObject var state: AppState

    /// Deliberately *not* `@State` — this always reads the live value out of
    /// `node.callExpression`, which is refreshed from `state.fileIndexes` on
    /// every apply/undo/redo. Caching this in local `@State` was the bug:
    /// `node.id` (file + structural path + type name) doesn't change when a
    /// mutation only changes `spacing`'s *value*, so SwiftUI kept the view's
    /// identity across undo and the cached number never got refreshed — the
    /// file on disk was correctly reverting, only the displayed stepper
    /// value was stale.
    private var spacing: Int { currentSpacing() ?? 0 }

    var body: some View {
        Section("Layout") {
            Stepper(
                value: Binding(get: { spacing }, set: { commit(newValue: $0) }),
                in: 0...400,
                step: 4
            ) {
                Text("Spacing: \(spacing)")
            }
        }
    }

    private func currentSpacing() -> Int? {
        guard let arg = node.callExpression.arguments.first(where: { $0.label?.text == "spacing" }) else { return nil }
        return Int(arg.expression.description.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func commit(newValue: Int) {
        guard let old = currentSpacing(), old != newValue else { return }
        state.apply(.modifyArgument(
            target: node.id,
            callName: node.id.typeName,
            argumentLabel: "spacing",
            argumentIndex: 0,
            oldValue: .integer(old),
            newValue: .integer(newValue)
        ))
    }
}
