import SwiftUI

/// Right panel: the diff from the most recent mutation (§28, §45 — "what
/// did the tool just do to my code?").
struct ChangesView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Code Changes")
                .font(.headline)
                .padding(8)
            Divider()

            Group {
                if state.lastDiff.isEmpty {
                    ContentUnavailableView(
                        "No Changes Yet",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text("Edit a property in the Inspector to see the resulting source diff here.")
                    )
                } else {
                    DiffView(diff: state.lastDiff)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
