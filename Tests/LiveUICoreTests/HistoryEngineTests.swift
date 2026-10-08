import XCTest
@testable import LiveUICore
@testable import LiveUIModels

final class HistoryEngineTests: XCTestCase {

    private func record(old: String, new: String, file: String = "ContentView.swift") -> MutationRecord {
        MutationRecord(
            id: UUID(), timestamp: Date(),
            mutation: .modifyArgument(
                target: ViewNodeID(file: file, path: StructuralPath([0]), typeName: "VStack"),
                callName: "VStack", argumentLabel: "spacing", argumentIndex: 0,
                oldValue: .integer(20), newValue: .integer(34)
            ),
            file: file, oldSource: old, newSource: new, diff: ""
        )
    }

    func testUndoRestoresOldSourceRedoRestoresNewSource() {
        let history = HistoryEngine()
        history.record(record(old: "A", new: "B"))

        XCTAssertTrue(history.canUndo)
        XCTAssertFalse(history.canRedo)
        XCTAssertEqual(history.currentSource["ContentView.swift"], "B")

        history.undo()
        XCTAssertEqual(history.currentSource["ContentView.swift"], "A")
        XCTAssertTrue(history.canRedo)

        history.redo()
        XCTAssertEqual(history.currentSource["ContentView.swift"], "B")
    }

    func testNewMutationAfterUndoClearsRedoStack() {
        let history = HistoryEngine()
        history.record(record(old: "A", new: "B"))
        history.undo()
        history.record(record(old: "A", new: "C"))

        XCTAssertFalse(history.canRedo, "a fresh mutation should discard the old redo branch")
        XCTAssertEqual(history.currentSource["ContentView.swift"], "C")
    }
}
