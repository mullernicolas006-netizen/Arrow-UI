import XCTest
@testable import LiveUICore
@testable import LiveUIModels

/// Encodes the LayoutEngine decision table from §14-17: the product's core
/// bet is that a drag should change the *right* semantic property, not
/// bolt on an offset.
final class LayoutEngineTests: XCTestCase {

    func testVerticalDragInsideVStackChangesSpacingNotOffset() {
        let target = ViewNodeID(file: "ContentView.swift", path: StructuralPath([0, 1]), typeName: "Button")
        let stackID = ViewNodeID(file: "ContentView.swift", path: StructuralPath([0]), typeName: "VStack")

        let intent = DragIntent(target: target, parentType: "VStack", axis: .vertical, deltaPoints: 14, currentSpacingValue: 20)
        let mutation = LayoutEngine.mutation(for: intent, stackNodeID: stackID)

        guard case .modifyArgument(_, let callName, let label, _, let old, let new) = mutation else {
            return XCTFail("expected a spacing mutation, not an offset/frame hack")
        }
        XCTAssertEqual(callName, "VStack")
        XCTAssertEqual(label, "spacing")
        XCTAssertEqual(old, .integer(20))
        XCTAssertEqual(new, .integer(34))
    }

    func testHorizontalDragInsideHStackChangesSpacing() {
        let target = ViewNodeID(file: "ContentView.swift", path: StructuralPath([0, 1]), typeName: "Text")
        let stackID = ViewNodeID(file: "ContentView.swift", path: StructuralPath([0]), typeName: "HStack")

        let intent = DragIntent(target: target, parentType: "HStack", axis: .horizontal, deltaPoints: 8, currentSpacingValue: 12)
        let mutation = LayoutEngine.mutation(for: intent, stackNodeID: stackID)

        guard case .modifyArgument(_, let callName, let label, _, let old, let new) = mutation else {
            return XCTFail("expected a spacing mutation")
        }
        XCTAssertEqual(callName, "HStack")
        XCTAssertEqual(label, "spacing")
        XCTAssertEqual(old, .integer(12))
        XCTAssertEqual(new, .integer(20))
    }

    func testFreeformZStackDragFallsBackToPaddingNotOffset() {
        let target = ViewNodeID(file: "ContentView.swift", path: StructuralPath([0, 1]), typeName: "Button")
        let intent = DragIntent(target: target, parentType: "ZStack", axis: .vertical, deltaPoints: 12, currentSpacingValue: nil)
        let mutation = LayoutEngine.mutation(for: intent, stackNodeID: nil)

        guard case .addModifier(_, let name, let args) = mutation else {
            return XCTFail("expected a padding fallback for a free-form ZStack")
        }
        XCTAssertEqual(name, "padding")
        XCTAssertEqual(args.count, 2, "padding must be edge-specific (.padding(.top, 12)), not all-edges (.padding(12)) — an all-edges fallback silently pads the cross axis too")
        XCTAssertEqual(args[0].value, .memberShorthand("top"), "a vertical drag must target the top edge, never left/right")
        XCTAssertEqual(args[1].value, .integer(12))
    }

    func testHorizontalFreeformDragTargetsLeadingEdge() {
        let target = ViewNodeID(file: "ContentView.swift", path: StructuralPath([0, 1]), typeName: "Button")
        let intent = DragIntent(target: target, parentType: "ZStack", axis: .horizontal, deltaPoints: 9, currentSpacingValue: nil)
        let mutation = LayoutEngine.mutation(for: intent, stackNodeID: nil)

        guard case .addModifier(_, _, let args) = mutation else {
            return XCTFail("expected a padding fallback")
        }
        XCTAssertEqual(args[0].value, .memberShorthand("leading"), "a horizontal drag must target the leading edge, never top/bottom")
        XCTAssertEqual(args[1].value, .integer(9))
    }

    func testRepeatedFreeformDragMergesIntoExistingPaddingInsteadOfStacking() {
        let target = ViewNodeID(file: "ContentView.swift", path: StructuralPath([0, 1]), typeName: "Button")
        let intent = DragIntent(target: target, parentType: "ZStack", axis: .vertical, deltaPoints: 12, currentSpacingValue: nil, currentPaddingValue: 75)
        let mutation = LayoutEngine.mutation(for: intent, stackNodeID: nil)

        guard case .modifyModifierArgument(_, let name, let label, _, let old, let new) = mutation else {
            return XCTFail("expected an update to the existing padding modifier, not a new one stacked on top")
        }
        XCTAssertEqual(name, "padding")
        XCTAssertNil(label)
        XCTAssertEqual(old, .integer(75))
        XCTAssertEqual(new, .integer(87))
    }

    func testSpacingNeverGoesNegative() {
        let target = ViewNodeID(file: "ContentView.swift", path: StructuralPath([0, 1]), typeName: "Text")
        let stackID = ViewNodeID(file: "ContentView.swift", path: StructuralPath([0]), typeName: "VStack")

        let intent = DragIntent(target: target, parentType: "VStack", axis: .vertical, deltaPoints: -50, currentSpacingValue: 20)
        let mutation = LayoutEngine.mutation(for: intent, stackNodeID: stackID)

        guard case .modifyArgument(_, _, _, _, _, let new) = mutation else {
            return XCTFail("expected a spacing mutation")
        }
        XCTAssertEqual(new, .integer(0))
    }
}
