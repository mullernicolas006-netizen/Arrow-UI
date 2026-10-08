import SwiftUI

/// Renders a unified diff, monospaced (§28, §45).
struct DiffView: View {
    let diff: String

    var body: some View {
        ScrollView {
            Text(diff)
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .textSelection(.enabled)
        }
        .background(Color.black.opacity(0.85))
        .foregroundStyle(.white)
    }
}
