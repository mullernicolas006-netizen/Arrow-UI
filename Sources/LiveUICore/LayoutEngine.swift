import Foundation
import LiveUIModels

/// A raw drag gesture on a selected view, already reduced to "how far did
/// it move, along which axis, inside what kind of parent" — the input the
/// Layout Intelligence Engine needs to decide *what in the source* should
/// change (§14-17).
public struct DragIntent {
    public enum Axis { case horizontal, vertical }

    public var target: ViewNodeID
    public var parentType: String?
    public var axis: Axis
    public var deltaPoints: Double
    public var currentSpacingValue: Int?

    public init(target: ViewNodeID, parentType: String?, axis: Axis, deltaPoints: Double, currentSpacingValue: Int?) {
        self.target = target
        self.parentType = parentType
        self.axis = axis
        self.deltaPoints = deltaPoints
        self.currentSpacingValue = currentSpacingValue
    }
}

/// Translates a raw drag gesture into a *semantic* `Mutation` — the central
/// product bet described in §69 ("the holy grail"): dragging a button
/// inside a `VStack` should grow the stack's `spacing`, not bolt on an
/// `.offset()`.
///
/// This is intentionally a small, explicit decision table rather than a
/// general solver. Per §67 ("not too much magic"), the MVP only needs to
/// get a handful of cases right, reliably:
///   - drag along a VStack's own axis (vertical)  -> change `spacing`
///   - drag along an HStack's own axis (horizontal) -> change `spacing`
///   - anything else (ZStack, cross-axis drag, no known parent) -> a
///     padding nudge on the dragged view itself, which is still a
///     legitimate layout property (never a raw `.offset()` — see §5-6).
public enum LayoutEngine {

    public static func mutation(for intent: DragIntent, stackNodeID: ViewNodeID?) -> Mutation {
        switch (intent.parentType, stackNodeID) {
        case ("VStack", .some(let stackID)) where intent.axis == .vertical:
            return spacingMutation(stackID: stackID, callName: "VStack", current: intent.currentSpacingValue, delta: intent.deltaPoints)

        case ("HStack", .some(let stackID)) where intent.axis == .horizontal:
            return spacingMutation(stackID: stackID, callName: "HStack", current: intent.currentSpacingValue, delta: intent.deltaPoints)

        default:
            return .addModifier(
                target: intent.target,
                modifierName: "padding",
                arguments: [MutationArgument(label: nil, value: .integer(Int(intent.deltaPoints.rounded())))]
            )
        }
    }

    private static func spacingMutation(stackID: ViewNodeID, callName: String, current: Int?, delta: Double) -> Mutation {
        let old = current ?? 0
        let new = max(0, old + Int(delta.rounded()))
        return .modifyArgument(
            target: stackID,
            callName: callName,
            argumentLabel: "spacing",
            argumentIndex: 0,
            oldValue: .integer(old),
            newValue: .integer(new)
        )
    }
}
