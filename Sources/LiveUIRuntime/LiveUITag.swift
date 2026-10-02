import SwiftUI
import LiveUIModels

/// Tags a view so LiveUI's Edit Mode can select, drag, and resize it, and
/// so the running app can report its live geometry back to the desktop app
/// (§7-8: View Registry).
///
/// This is the one piece of manual instrumentation LiveUI's MVP asks of
/// app code — automatically inserting these tags via a build-time pass
/// (so app authors never have to write them) is future work, not part of
/// this milestone (see ARCHITECTURE.md, "Known gaps").
///
/// `id` should be the same string `SourceIndexer`/`ViewNodeID.description`
/// would produce for the corresponding call in source, e.g.
/// `"Button@ContentView.swift#0.1"`, so the desktop app can match a runtime
/// geometry report back to the AST node that produced it.
public struct LiveUITagModifier: ViewModifier {
    let id: String
    let typeName: String
    let file: String
    let structuralPath: String
    let parentID: String?

    /// Injected by `LiveUIEditModeRoot`. Reading `.offsets[id]` here (and
    /// applying it to `content` below) is what makes a canvas drag move
    /// the *real* view live, before any source mutation or rebuild — see
    /// `LiveUIPreviewStore`'s doc comment.
    @EnvironmentObject private var previewStore: LiveUIPreviewStore

    public func body(content: Content) -> some View {
        let liveOffset = previewStore.offsets[id] ?? .zero
        content
            // Applied to `content` *before* the geometry reader below, so
            // the reported geometry also reflects the live nudge — the
            // desktop app's own selection box and hit-testing stay in
            // sync with the view while it's being dragged, not just the
            // view itself.
            .offset(liveOffset)
            // A short *linear* glide, not a spring: it exists only to
            // paper over small, irregular gaps between network ticks (a
            // message arriving a few extra ms late shouldn't read as a
            // visible jump), not to add a catch-up lag behind the
            // cursor — a spring or anything longer would feel laggier
            // than a plain drag, the opposite of what's wanted here.
            .animation(.linear(duration: 0.05), value: liveOffset)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: LiveUIGeometryPreferenceKey.self,
                        value: [
                            RuntimeViewInfo(
                                id: id,
                                typeName: typeName,
                                file: file,
                                structuralPath: structuralPath,
                                geometry: RuntimeGeometry(
                                    x: proxy.frame(in: .global).minX,
                                    y: proxy.frame(in: .global).minY,
                                    width: proxy.size.width,
                                    height: proxy.size.height
                                ),
                                parentID: parentID
                            )
                        ]
                    )
                }
            )
    }
}

public struct LiveUIGeometryPreferenceKey: PreferenceKey {
    public static var defaultValue: [RuntimeViewInfo] = []

    public static func reduce(value: inout [RuntimeViewInfo], nextValue: () -> [RuntimeViewInfo]) {
        value.append(contentsOf: nextValue())
    }
}

extension View {
    /// Call this on any view you want LiveUI's Edit Mode to be able to
    /// select, drag, and resize.
    public func liveUITag(id: String, type: String, file: String, path: String, parent: String? = nil) -> some View {
        modifier(LiveUITagModifier(id: id, typeName: type, file: file, structuralPath: path, parentID: parent))
    }
}
