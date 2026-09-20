import SwiftUI
import Combine
import SimulatorBridge
import LiveUIModels

#if canImport(UIKit)
import UIKit
#endif

/// Wrap your app's root view in this to turn on LiveUI's Edit Mode (§57):
/// it collects every `.liveUITag(...)`'d view's geometry via
/// `LiveUIGeometryPreferenceKey` and forwards periodic snapshots to the
/// LiveUI desktop app over `BridgeClient`.
///
/// ```swift
/// WindowGroup {
///     LiveUIEditModeRoot(appName: "MyApp", bundleIdentifier: Bundle.main.bundleIdentifier ?? "") {
///         ContentView()
///     }
/// }
/// ```
public struct LiveUIEditModeRoot<Content: View>: View {
    @StateObject private var client: BridgeClient
    private let appName: String
    private let bundleIdentifier: String
    private let content: Content

    public init(appName: String, bundleIdentifier: String, host: String = "127.0.0.1", port: UInt16 = 51820, @ViewBuilder content: () -> Content) {
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.content = content()
        _client = StateObject(wrappedValue: BridgeClient(host: host, port: port))
    }

    public var body: some View {
        content
            .onPreferenceChange(LiveUIGeometryPreferenceKey.self) { views in
                client.send(.snapshot(views: views))
            }
            .onAppear {
                client.connect(appName: appName, bundleIdentifier: bundleIdentifier, screenSize: currentScreenSize())
            }
    }

    /// `UIScreen` is iOS-only — this whole type also has to type-check when
    /// the package is built for macOS (that's how the package itself is
    /// developed/tested), so this falls back to `.zero` there. It's never
    /// actually exercised on macOS: `LiveUIEditModeRoot` is meant to wrap an
    /// iOS app's root view.
    private func currentScreenSize() -> CGSize {
        #if canImport(UIKit)
        return UIScreen.main.bounds.size
        #else
        return .zero
        #endif
    }
}
