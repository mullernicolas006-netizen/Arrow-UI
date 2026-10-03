import SwiftUI

@main
struct LiveUIAppMain: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup("LiveUI") {
            ContentView()
                .environmentObject(state)
                .onAppear { state.startBridge() }
                .frame(minWidth: 960, minHeight: 640)
        }
        .commands {
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { state.undo() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!state.canUndo)
                Button("Redo") { state.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!state.canRedo)
            }
        }
    }
}
