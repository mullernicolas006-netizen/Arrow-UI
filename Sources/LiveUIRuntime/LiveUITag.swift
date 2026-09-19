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

    public func body(content: Content) -> some View {
        content.background(
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
