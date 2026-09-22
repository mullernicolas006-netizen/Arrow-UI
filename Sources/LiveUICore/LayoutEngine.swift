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
    /// The value of an existing `.padding(<edge>, N)` modifier *matching
    /// this drag's axis* on the dragged view, if one already exists — lets
    /// the padding fallback merge into it (old + delta) instead of
    /// stacking a new `.padding()` call on every drag. Must be for the
    /// same edge the fallback would itself target (see `edgeName`) —
    /// mixing edges here would silently merge a vertical drag's delta
    /// into a horizontal padding value or vice versa.
    public var currentPaddingValue: Int?

    public init(target: ViewNodeID, parentType: String?, axis: Axis, deltaPoints: Double, currentSpacingValue: Int?, currentPaddingValue: Int? = nil) {
        self.target = target
        self.parentType = parentType
        self.axis = axis
        self.deltaPoints = deltaPoints
        self.currentSpacingValue = currentSpacingValue
        self.currentPaddingValue = currentPaddingValue
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
///
/// The padding fallback is deliberately edge-specific (`.padding(.top,
/// N)` / `.padding(.leading, N)`), not the unlabeled `.padding(N)` form
/// that pads all four sides — a vertical-only drag must never also shift
/// the view horizontally, and vice versa. Using the all-edges form here
/// was an earlier bug: a pure vertical drag was silently also padding
/// left/right equally, visibly shoving the view sideways.
public enum LayoutEngine {

    public static func mutation(for intent: DragIntent, stackNodeID: ViewNodeID?) -> Mutation {
        switch (intent.parentType, stackNodeID) {
        case ("VStack", .some(let stackID)) where intent.axis == .vertical:
            return spacingMutation(stackID: stackID, callName: "VStack", current: intent.currentSpacingValue, delta: intent.deltaPoints)

        case ("HStack", .some(let stackID)) where intent.axis == .horizontal:
            return spacingMutation(stackID: stackID, callName: "HStack", current: intent.currentSpacingValue, delta: intent.deltaPoints)

        default:
            let edge = edgeName(for: intent.axis)
            if let current = intent.currentPaddingValue {
                let new = current + Int(intent.deltaPoints.rounded())
                return .modifyModifierArgument(
                    target: intent.target,
                    modifierName: "padding",
                    argumentLabel: nil,
                    argumentIndex: 1,
                    oldValue: .integer(current),
                    newValue: .integer(new)
                )
            }
            return .addModifier(
                target: intent.target,
                modifierName: "padding",
                arguments: [
                    MutationArgument(label: nil, value: .memberShorthand(edge)),
                    MutationArgument(label: nil, value: .integer(Int(intent.deltaPoints.rounded())))
                ]
            )
        }
    }

    /// Which `Edge` a fallback padding drag should target for a given
    /// axis. Callers (the canvas gesture) must use the same mapping when
    /// reading back an existing padding value for `currentPaddingValue`.
    public static func edgeName(for axis: DragIntent.Axis) -> String {
        axis == .vertical ? "top" : "leading"
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
