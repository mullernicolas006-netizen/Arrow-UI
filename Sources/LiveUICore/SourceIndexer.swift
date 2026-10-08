import Foundation
import SwiftSyntax
import SwiftParser
import LiveUIModels

/// A view-producing call expression found while indexing a file, together
/// with its children (nested view calls found in its trailing closure /
/// arguments) and its `ViewNodeID`.
///
/// Deliberately holds the *actual* `FunctionCallExprSyntax` node from the
/// parsed tree (not a detached copy), so `SwiftSyntaxEngine` can walk
/// `.parent` from it to find enclosing modifier calls (§50-51).
public struct IndexedNode {
    public let id: ViewNodeID
    public let callExpression: FunctionCallExprSyntax
    public let children: [IndexedNode]
}

public struct FileIndex {
    public let filePath: String
    public let sourceFile: SourceFileSyntax
    public let roots: [IndexedNode]
}

/// Parses a `.swift` file and builds a tree of `IndexedNode`s for every
/// SwiftUI view-producing call expression it can find (§49: Source Indexer).
///
/// MVP scope, matching §65-67: this recognizes a call as "view-producing"
/// purely syntactically — a capitalized identifier or the innermost
/// identifier of a modifier chain being called as a function. It does not
/// (yet) resolve types, so a capitalized free function call would also be
/// picked up. That's an acceptable false positive for the MVP: worst case
/// LiveUI shows a selectable node in the hierarchy that turns out not to be
/// a view, but it will never *mis-mutate* unrelated code, since mutations
/// are always validated against argument shape at apply time.
public enum SourceIndexer {

    public static func index(filePath: String) throws -> FileIndex {
        let source = try String(contentsOfFile: filePath, encoding: .utf8)
        return index(source: source, filePath: filePath)
    }

    public static func index(source: String, filePath: String) -> FileIndex {
        let tree = Parser.parse(source: source)
        let roots = collectViewCalls(in: Syntax(tree), filePath: filePath, path: StructuralPath([]))
        return FileIndex(filePath: filePath, sourceFile: tree, roots: roots)
    }

    private static func collectViewCalls(in node: Syntax, filePath: String, path: StructuralPath) -> [IndexedNode] {
        var results: [IndexedNode] = []
        for (childIndex, child) in node.children(viewMode: .sourceAccurate).enumerated() {
            let childPath = path.appending(childIndex)
            if let call = child.as(FunctionCallExprSyntax.self), let name = viewTypeName(of: call) {
                // `call` here may be the *outermost* call in a modifier chain
                // (e.g. the `.padding()` in `VStack(spacing: 20) { ... }.padding()`).
                // The node itself — the thing with `spacing`/`width`/etc.
                // arguments — is the root initializer call underneath any
                // chained modifiers, so that's what gets indexed and recursed
                // into. Modifiers are found later, on demand, by walking
                // *outward* from this root call (see SwiftSyntaxEngine).
                let rootCall = rootCallExpr(of: call)
                let nodeID = ViewNodeID(file: filePath, path: childPath, typeName: name)
                let nested = collectViewCalls(in: Syntax(rootCall), filePath: filePath, path: childPath)
                results.append(IndexedNode(id: nodeID, callExpression: rootCall, children: nested))
            } else {
                results.append(contentsOf: collectViewCalls(in: child, filePath: filePath, path: childPath))
            }
        }
        return results
    }

    /// Walks a modifier chain (`Foo(...).bar().baz()`) down to its root
    /// initializer call and returns that call's type name — e.g. "Button"
    /// for `Button("x") { }.padding()` — or nil if the chain doesn't bottom
    /// out in a capitalized initializer call (so plain function calls like
    /// `login()` are not indexed as views).
    private static func viewTypeName(of call: FunctionCallExprSyntax) -> String? {
        guard let name = rootIdentifier(of: ExprSyntax(call)) else { return nil }
        guard let first = name.first, first.isUppercase else { return nil }
        return name
    }

    private static func rootIdentifier(of expr: ExprSyntax) -> String? {
        guard let call = expr.as(FunctionCallExprSyntax.self) else { return nil }
        if let member = call.calledExpression.as(MemberAccessExprSyntax.self) {
            guard let base = member.base else { return nil }
            return rootIdentifier(of: base)
        }
        if let decl = call.calledExpression.as(DeclReferenceExprSyntax.self) {
            return decl.baseName.text
        }
        return nil
    }

    /// Walks a modifier chain (`Foo(...).bar().baz()`) down to the actual
    /// initializer call (`Foo(...)`) and returns *that node* — as opposed
    /// to `rootIdentifier`, which only returns its name.
    private static func rootCallExpr(of call: FunctionCallExprSyntax) -> FunctionCallExprSyntax {
        if let member = call.calledExpression.as(MemberAccessExprSyntax.self),
           let base = member.base,
           let baseCall = base.as(FunctionCallExprSyntax.self) {
            return rootCallExpr(of: baseCall)
        }
        return call
    }
}
