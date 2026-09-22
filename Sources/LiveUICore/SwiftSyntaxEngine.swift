import SwiftSyntax
import LiveUIModels

public enum SwiftSyntaxEngineError: Error, CustomStringConvertible {
    case nodeNotFound(ViewNodeID)
    case modifierNotFound(String)
    case argumentNotFound(String)
    case unsupportedLiteral

    public var description: String {
        switch self {
        case .nodeNotFound(let id):
            return "Could not resolve view node \(id) in the current source — the file may have changed underneath this mutation."
        case .modifierNotFound(let name):
            return "Could not find an existing '.\(name)(...)' modifier on this view's chain."
        case .argumentNotFound(let label):
            return "Could not find argument '\(label)'."
        case .unsupportedLiteral:
            return "This literal kind is not yet supported for in-place mutation."
        }
    }
}

/// Locates AST nodes corresponding to a `ViewNodeID` and performs the
/// actual structural rewrites (§11, §49-51: SwiftSyntax / AST, Source
/// Mapper, Layout Engine support).
///
/// Every rewrite here follows the same rule (§13, Minimal Source
/// Modification): copy the existing node, change exactly the one token
/// that needs to change, and preserve every other token — including
/// trivia (whitespace/comments) — untouched.
public enum SwiftSyntaxEngine {

    // MARK: - Resolution (§9: multi-layered view identity)

    /// Resolves a `ViewNodeID` back to its node in a freshly-parsed
    /// `FileIndex`. Tries an exact structural-path match first; if the
    /// source shifted slightly (e.g. a line was added above), falls back
    /// to the nearest node of the same type name.
    public static func resolve(_ id: ViewNodeID, in index: FileIndex) -> IndexedNode? {
        if let exact = find(path: id.path, in: index.roots) {
            return exact
        }
        return findByTypeName(id.typeName, nearestTo: id.path, in: index.roots)
    }

    private static func find(path: StructuralPath, in nodes: [IndexedNode]) -> IndexedNode? {
        for node in nodes {
            if node.id.path == path { return node }
            if let found = find(path: path, in: node.children) { return found }
        }
        return nil
    }

    private static func findByTypeName(_ typeName: String, nearestTo path: StructuralPath, in nodes: [IndexedNode]) -> IndexedNode? {
        var candidates: [IndexedNode] = []
        func collect(_ nodes: [IndexedNode]) {
            for node in nodes {
                if node.id.typeName == typeName { candidates.append(node) }
                collect(node.children)
            }
        }
        collect(nodes)
        return candidates.min { distance($0.id.path, path) < distance($1.id.path, path) }
    }

    private static func distance(_ a: StructuralPath, _ b: StructuralPath) -> Int {
        var d = abs(a.components.count - b.components.count)
        for (x, y) in zip(a.components, b.components) where x != y { d += 1 }
        return d
    }

    // MARK: - Modifier chain traversal (§50-51)

    /// Given the initializer call at the root of a modifier chain (e.g. the
    /// `Button(...)` in `Button(...).padding().frame(width: 200)`), finds an
    /// existing `.name(...)` call further out in the same chain.
    public static func findModifierCall(named name: String, startingFrom call: FunctionCallExprSyntax) -> FunctionCallExprSyntax? {
        var current = call
        while true {
            guard let parent = Syntax(current).parent,
                  let member = parent.as(MemberAccessExprSyntax.self),
                  let outerCall = member.parent?.as(FunctionCallExprSyntax.self) else {
                return nil
            }
            if member.declName.baseName.text == name {
                return outerCall
            }
            current = outerCall
        }
    }

    /// Walks outward through the modifier chain rooted at `call` and
    /// returns the outermost call expression — i.e. the full
    /// `Foo(...).bar().baz()` expression, which is what a new trailing
    /// modifier must be appended to.
    public static func outermostChainedExpr(startingFrom call: FunctionCallExprSyntax) -> ExprSyntax {
        var current = call
        while let parent = Syntax(current).parent,
              let member = parent.as(MemberAccessExprSyntax.self),
              let outerCall = member.parent?.as(FunctionCallExprSyntax.self) {
            current = outerCall
        }
        return ExprSyntax(current)
    }

    // MARK: - Argument access

    public static func argument(in call: FunctionCallExprSyntax, label: String?, index: Int) -> LabeledExprSyntax? {
        let args = Array(call.arguments)
        if let label {
            return args.first { $0.label?.text == label }
        }
        guard args.indices.contains(index) else { return nil }
        return args[index]
    }

    /// Replaces one argument's literal value in place, preserving every
    /// surrounding token and all trivia untouched — the "only `20` becomes
    /// `34`" guarantee from §13/§15.
    public static func replacingArgumentValue(
        in call: FunctionCallExprSyntax,
        label: String?,
        index: Int,
        newValue: MutationValue
    ) throws -> FunctionCallExprSyntax {
        guard let old = argument(in: call, label: label, index: index) else {
            throw SwiftSyntaxEngineError.argumentNotFound(label ?? "#\(index)")
        }
        let newExpr = try replacingLiteral(old.expression, with: newValue)
        let newArg = old.with(\.expression, newExpr)

        var newArgs = Array(call.arguments)
        guard let position = newArgs.firstIndex(where: { $0.id == old.id }) else {
            throw SwiftSyntaxEngineError.argumentNotFound(label ?? "#\(index)")
        }
        newArgs[position] = newArg
        return call.with(\.arguments, LabeledExprListSyntax(newArgs))
    }

    /// Swift has no single "negative literal" token: `-5` parses as a
    /// prefix `-` operator (`PrefixOperatorExprSyntax`) applied to the
    /// *positive* literal `5`, not one `IntegerLiteralExprSyntax` reading
    /// "-5". Writing "-5" as a single literal token prints correctly the
    /// first time (raw text is still valid Swift), but the *next* time
    /// this file is parsed, that text becomes a real
    /// `PrefixOperatorExprSyntax` — which none of this code recognized,
    /// so every mutation after the first one on a negative value threw
    /// `.unsupportedLiteral`. Every read/write of a numeric literal here
    /// goes through this shape deliberately, in both directions.
    private static func replacingLiteral(_ expr: ExprSyntax, with value: MutationValue) throws -> ExprSyntax {
        let leadingTrivia = expr.leadingTrivia
        let trailingTrivia = expr.trailingTrivia

        switch value {
        case .integer(let v):
            guard isNumericLiteral(expr) else { throw SwiftSyntaxEngineError.unsupportedLiteral }
            if isFloatLiteral(expr) {
                return floatLiteralExpr(for: Double(v), leadingTrivia: leadingTrivia, trailingTrivia: trailingTrivia)
            }
            return integerLiteralExpr(for: v, leadingTrivia: leadingTrivia, trailingTrivia: trailingTrivia)

        case .double(let v):
            guard isNumericLiteral(expr) else { throw SwiftSyntaxEngineError.unsupportedLiteral }
            return floatLiteralExpr(for: v, leadingTrivia: leadingTrivia, trailingTrivia: trailingTrivia)

        case .boolean(let v):
            guard let lit = expr.as(BooleanLiteralExprSyntax.self) else {
                throw SwiftSyntaxEngineError.unsupportedLiteral
            }
            let kind: TokenKind = v ? .keyword(.true) : .keyword(.false)
            let token = TokenSyntax(kind, presence: .present)
                .with(\.leadingTrivia, leadingTrivia)
                .with(\.trailingTrivia, trailingTrivia)
            return ExprSyntax(lit.with(\.literal, token))

        case .string:
            // Deliberately unsupported for now: the exact SwiftSyntax type
            // for string literal segments has changed across versions and
            // isn't needed by any MVP property (§65 lists no plain string
            // edits). Implement once this package is building against a
            // pinned swift-syntax version and the real API is in front of you.
            throw SwiftSyntaxEngineError.unsupportedLiteral
        }
    }

    /// True for anything `replacingLiteral`'s `.integer`/`.double` cases
    /// can operate on: a plain integer/float literal, or Swift's
    /// negative-number shape (a prefix `-` applied to one).
    private static func isNumericLiteral(_ expr: ExprSyntax) -> Bool {
        if expr.is(IntegerLiteralExprSyntax.self) || expr.is(FloatLiteralExprSyntax.self) { return true }
        if let prefix = expr.as(PrefixOperatorExprSyntax.self), prefix.operator.text == "-" {
            return prefix.expression.is(IntegerLiteralExprSyntax.self) || prefix.expression.is(FloatLiteralExprSyntax.self)
        }
        return false
    }

    private static func isFloatLiteral(_ expr: ExprSyntax) -> Bool {
        if expr.is(FloatLiteralExprSyntax.self) { return true }
        if let prefix = expr.as(PrefixOperatorExprSyntax.self) {
            return prefix.expression.is(FloatLiteralExprSyntax.self)
        }
        return false
    }

    private static func integerLiteralExpr(for value: Int, leadingTrivia: Trivia, trailingTrivia: Trivia) -> ExprSyntax {
        guard value < 0 else {
            let token = TokenSyntax.integerLiteral(String(value))
                .with(\.leadingTrivia, leadingTrivia)
                .with(\.trailingTrivia, trailingTrivia)
            return ExprSyntax(IntegerLiteralExprSyntax(literal: token))
        }
        let minusToken = TokenSyntax.prefixOperator("-").with(\.leadingTrivia, leadingTrivia)
        let magnitudeToken = TokenSyntax.integerLiteral(String(-value)).with(\.trailingTrivia, trailingTrivia)
        let prefix = PrefixOperatorExprSyntax(
            operator: minusToken,
            expression: ExprSyntax(IntegerLiteralExprSyntax(literal: magnitudeToken))
        )
        return ExprSyntax(prefix)
    }

    private static func floatLiteralExpr(for value: Double, leadingTrivia: Trivia, trailingTrivia: Trivia) -> ExprSyntax {
        guard value < 0 else {
            let token = TokenSyntax.floatLiteral(formatted(value))
                .with(\.leadingTrivia, leadingTrivia)
                .with(\.trailingTrivia, trailingTrivia)
            return ExprSyntax(FloatLiteralExprSyntax(literal: token))
        }
        let minusToken = TokenSyntax.prefixOperator("-").with(\.leadingTrivia, leadingTrivia)
        let magnitudeToken = TokenSyntax.floatLiteral(formatted(-value)).with(\.trailingTrivia, trailingTrivia)
        let prefix = PrefixOperatorExprSyntax(
            operator: minusToken,
            expression: ExprSyntax(FloatLiteralExprSyntax(literal: magnitudeToken))
        )
        return ExprSyntax(prefix)
    }

    private static func formatted(_ v: Double) -> String {
        if v == v.rounded() && abs(v) < 1e15 {
            return String(format: "%.1f", v)
        }
        return String(v)
    }

    // MARK: - Adding a new modifier (§18-19, §69)

    /// Appends a new trailing modifier call, e.g. turning `Text("Title")`
    /// into `Text("Title")\n    .padding(12)`.
    ///
    /// MVP scope: arguments are plain literals (labeled or positional).
    /// Enum-shorthand arguments like `.top` in `.padding(.top, 12)` aren't
    /// representable by `MutationValue` yet, so modifiers requiring them
    /// (edge-specific padding, alignment) are out of scope until the model
    /// grows a `.memberShorthand(String)` case — tracked in ARCHITECTURE.md.
    public static func appendingModifier(
        to expr: ExprSyntax,
        modifierName: String,
        arguments: [MutationArgument]
    ) throws -> FunctionCallExprSyntax {
        let argList = try buildArgumentList(arguments)
        let member = MemberAccessExprSyntax(
            base: expr,
            declName: DeclReferenceExprSyntax(baseName: .identifier(modifierName))
        )
        return FunctionCallExprSyntax(
            calledExpression: ExprSyntax(member),
            leftParen: .leftParenToken(),
            arguments: argList,
            rightParen: .rightParenToken()
        )
    }

    private static func buildArgumentList(_ arguments: [MutationArgument]) throws -> LabeledExprListSyntax {
        var elements: [LabeledExprSyntax] = []
        for (i, arg) in arguments.enumerated() {
            let expr = try literalExpr(for: arg.value)
            var element = LabeledExprSyntax(
                label: arg.label.map { TokenSyntax.identifier($0) },
                colon: arg.label != nil ? TokenSyntax.colonToken(trailingTrivia: .space) : nil,
                expression: expr
            )
            if i < arguments.count - 1 {
                element = element.with(\.trailingComma, TokenSyntax.commaToken(trailingTrivia: .space))
            }
            elements.append(element)
        }
        return LabeledExprListSyntax(elements)
    }

    private static func literalExpr(for value: MutationValue) throws -> ExprSyntax {
        switch value {
        case .integer(let v):
            return integerLiteralExpr(for: v, leadingTrivia: [], trailingTrivia: [])
        case .double(let v):
            return floatLiteralExpr(for: v, leadingTrivia: [], trailingTrivia: [])
        case .boolean(let v):
            return ExprSyntax(BooleanLiteralExprSyntax(literal: v ? .keyword(.true) : .keyword(.false)))
        case .memberShorthand(let name):
            return ExprSyntax(MemberAccessExprSyntax(base: nil, declName: DeclReferenceExprSyntax(baseName: .identifier(name))))
        case .string:
            throw SwiftSyntaxEngineError.unsupportedLiteral
        }
    }
}
