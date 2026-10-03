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

    /// Exact-position dragging (the product's eventual choice over the
    /// spacing/padding heuristics above): a vertical drag with no prior
    /// offset must add a fresh `.offset(x: 0, y: <delta>)`, never touch
    /// anything else, and never affect a sibling (unlike spacing/padding,
    /// `.offset` doesn't participate in the parent's layout pass at all).
    func testFirstOffsetDragAddsModifierWithOnlyTheDraggedAxisSet() {
        let target = ViewNodeID(file: "ContentView.swift", path: StructuralPath([0, 1]), typeName: "Button")
        let mutation = LayoutEngine.offsetMutation(target: target, currentOffset: nil, axis: .vertical, delta: 34)

        guard case .addModifier(_, let name, let args) = mutation else {
            return XCTFail("expected a fresh .offset(x:,y:) modifier")
        }
        XCTAssertEqual(name, "offset")
        XCTAssertEqual(args.count, 2)
        XCTAssertEqual(args[0].label, "x")
        XCTAssertEqual(args[0].value, .integer(0))
        XCTAssertEqual(args[1].label, "y")
        XCTAssertEqual(args[1].value, .integer(34))
    }

    /// A second drag along the same axis must update the *existing*
    /// `.offset` modifier's matching component (accumulating onto the old
    /// value), not stack a second `.offset` call — two additive offsets
    /// would make the view drift from wherever it was actually dropped,
    /// exactly the bug the padding fallback had to guard against earlier.
    func testRepeatedOffsetDragUpdatesExistingModifierOnMatchingAxis() {
        let target = ViewNodeID(file: "ContentView.swift", path: StructuralPath([0, 1]), typeName: "Button")
        let mutation = LayoutEngine.offsetMutation(target: target, currentOffset: (x: 0, y: 34), axis: .vertical, delta: 12)

        guard case .modifyModifierArgument(_, let name, let label, let index, let old, let new) = mutation else {
            return XCTFail("expected an update to the existing .offset modifier")
        }
        XCTAssertEqual(name, "offset")
        XCTAssertEqual(label, "y")
        XCTAssertEqual(index, 1)
        XCTAssertEqual(old, .integer(34))
        XCTAssertEqual(new, .integer(46))
    }

    /// Dragging horizontally after a prior vertical drag must update only
    /// the `x` component and leave the accumulated `y` value alone.
    func testHorizontalOffsetDragAfterVerticalDragOnlyTouchesX() {
        let target = ViewNodeID(file: "ContentView.swift", path: StructuralPath([0, 1]), typeName: "Button")
        let mutation = LayoutEngine.offsetMutation(target: target, currentOffset: (x: 0, y: 34), axis: .horizontal, delta: 9)

        guard case .modifyModifierArgument(_, let name, let label, let index, let old, let new) = mutation else {
            return XCTFail("expected an update to the existing .offset modifier")
        }
        XCTAssertEqual(name, "offset")
        XCTAssertEqual(label, "x")
        XCTAssertEqual(index, 0)
        XCTAssertEqual(old, .integer(0))
        XCTAssertEqual(new, .integer(9))
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

    /// Resize-handle dragging. A view with no existing `.frame()` still
    /// has a real, measured size — the first-ever resize must grow from
    /// that measured baseline, never from 0 (which would snap the view
    /// to a tiny, wrong size instead of growing from where it already
    /// visually is).
    func testFirstResizeGrowsFromMeasuredSizeNotZero() {
        let target = ViewNodeID(file: "ContentView.swift", path: StructuralPath([0, 1]), typeName: "Button")
        let mutation = LayoutEngine.sizeMutation(
            target: target, existingFrame: nil, measuredSize: (width: 80, height: 32),
            axis: .horizontal, delta: 20
        )

        guard case .addModifier(_, let name, let args) = mutation else {
            return XCTFail("expected a fresh .frame(width:,height:) modifier")
        }
        XCTAssertEqual(name, "frame")
        XCTAssertEqual(args.count, 2)
        XCTAssertEqual(args[0].label, "width")
        XCTAssertEqual(args[0].value, .integer(100), "must grow from the measured width (80), not 0")
        XCTAssertEqual(args[1].label, "height")
        XCTAssertEqual(args[1].value, .integer(32), "the untouched axis must keep its measured value, not reset to 0")
    }

    /// A second resize must update the *existing* `.frame` modifier's
    /// matching dimension, not stack a second `.frame` call — same
    /// merge-not-stack reasoning as the offset/padding mutations above.
    func testRepeatedResizeUpdatesExistingFrameOnMatchingDimension() {
        let target = ViewNodeID(file: "ContentView.swift", path: StructuralPath([0, 1]), typeName: "Button")
        let mutation = LayoutEngine.sizeMutation(
            target: target, existingFrame: (width: 100, height: 32), measuredSize: (width: 100, height: 32),
            axis: .vertical, delta: 10
        )

        guard case .modifyModifierArgument(_, let name, let label, let index, let old, let new) = mutation else {
            return XCTFail("expected an update to the existing .frame modifier")
        }
        XCTAssertEqual(name, "frame")
        XCTAssertEqual(label, "height")
        XCTAssertEqual(index, 1)
        XCTAssertEqual(old, .integer(32))
        XCTAssertEqual(new, .integer(42))
    }

    /// Shrinking must never collapse a view to zero or negative size.
    func testResizeNeverShrinksBelowOnePoint() {
        let target = ViewNodeID(file: "ContentView.swift", path: StructuralPath([0, 1]), typeName: "Button")
        let mutation = LayoutEngine.sizeMutation(
            target: target, existingFrame: (width: 20, height: 32), measuredSize: (width: 20, height: 32),
            axis: .horizontal, delta: -500
        )

        guard case .modifyModifierArgument(_, _, _, _, _, let new) = mutation else {
            return XCTFail("expected an update to the existing .frame modifier")
        }
        XCTAssertEqual(new, .integer(1))
    }
}
