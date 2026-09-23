import SwiftSyntax
import LiveUIModels

/// Turns a `Mutation` into a new version of a source file's text, plus a
/// human-readable diff (§28, §52: Mutation Engine + Code Diff).
///
/// This is the only place that writes new source text. Everything upstream
/// (LayoutEngine, the Inspector UI, a future AI layer per §43) only ever
/// produces `Mutation` values — never raw text — which is what keeps every
/// caller's output validate-able and undo-able in the same way.
public enum MutationEngine {

    public static func apply(_ mutation: Mutation, toSource source: String, filePath: String) throws -> (newSource: String, diff: String) {
        let index = SourceIndexer.index(source: source, filePath: filePath)

        switch mutation {
        case .modifyArgument(let target, _, let label, let argIndex, _, let newValue):
            guard let node = SwiftSyntaxEngine.resolve(target, in: index) else {
                throw SwiftSyntaxEngineError.nodeNotFound(target)
            }
            let newCall = try SwiftSyntaxEngine.replacingArgumentValue(
                in: node.callExpression, label: label, index: argIndex, newValue: newValue
            )
            return rewrite(index: index, targetID: node.callExpression.id, replacement: ExprSyntax(newCall), filePath: filePath)

        case .modifyModifierArgument(let target, let modifierName, let label, let argIndex, let oldValue, let newValue):
            guard let node = SwiftSyntaxEngine.resolve(target, in: index) else {
                throw SwiftSyntaxEngineError.nodeNotFound(target)
            }
            // Disambiguates by the *current value* at argIndex, not just
            // the modifier's name — a chain can have several modifiers
            // sharing a name (e.g. `.padding(.top, 20)` and
            // `.padding(.leading, 8)` are both named "padding"), and only
            // the value at the target argument position identifies which
            // one a given mutation actually meant.
            guard let modifierCall = SwiftSyntaxEngine.findModifierCall(
                named: modifierName, argumentIndex: argIndex, matching: oldValue, startingFrom: node.callExpression
            ) else {
                throw SwiftSyntaxEngineError.modifierNotFound(modifierName)
            }
            let newModifierCall = try SwiftSyntaxEngine.replacingArgumentValue(
                in: modifierCall, label: label, index: argIndex, newValue: newValue
            )
            return rewrite(index: index, targetID: modifierCall.id, replacement: ExprSyntax(newModifierCall), filePath: filePath)

        case .addModifier(let target, let modifierName, let arguments):
            guard let node = SwiftSyntaxEngine.resolve(target, in: index) else {
                throw SwiftSyntaxEngineError.nodeNotFound(target)
            }
            let outermost = SwiftSyntaxEngine.outermostChainedExpr(startingFrom: node.callExpression)
            let newExpr = try SwiftSyntaxEngine.appendingModifier(to: outermost, modifierName: modifierName, arguments: arguments)
            return rewrite(index: index, targetID: outermost.id, replacement: ExprSyntax(newExpr), filePath: filePath)
        }
    }

    /// Replaces exactly the node with `targetID` inside `index.sourceFile`
    /// and renders the whole tree back to text. Because SwiftSyntax trees
    /// are trivia-preserving, every token outside the replaced node is
    /// emitted byte-for-byte as it was parsed.
    private static func rewrite(index: FileIndex, targetID: SyntaxIdentifier, replacement: ExprSyntax, filePath: String) -> (String, String) {
        let rewriter = ReplacingExprRewriter(targetID: targetID, replacement: replacement)
        let newTree = rewriter.visit(index.sourceFile)
        let oldSource = index.sourceFile.description
        let newSource = newTree.description
        return (newSource, Diagnostics.unifiedDiff(old: oldSource, new: newSource, filePath: filePath))
    }
}

/// Replaces a single expression node, matched by `SyntaxIdentifier`, during
/// a full-tree rewrite. Both `FunctionCallExprSyntax` mutation and the
/// wider `addModifier` replacement (which swaps in a whole new call at the
/// outermost point of a chain) go through this same visitor.
private final class ReplacingExprRewriter: SyntaxRewriter {
    let targetID: SyntaxIdentifier
    let replacement: ExprSyntax

    init(targetID: SyntaxIdentifier, replacement: ExprSyntax) {
        self.targetID = targetID
        self.replacement = replacement
    }

    override func visit(_ node: FunctionCallExprSyntax) -> ExprSyntax {
        if node.id == targetID {
            return replacement
        }
        return super.visit(node)
    }
}
