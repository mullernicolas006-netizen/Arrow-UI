import Foundation

/// A structural address of a node inside a source file, expressed as a path
/// of child indices from the file's top level down to the node.
///
/// This is the fallback layer of the identity scheme in the LiveUI design
/// (§9: Explicit ID + AST Identity + Source Location + Hierarchy Path +
/// Runtime Identity). It is stable across formatting/whitespace changes but
/// *not* across structural edits above the node (e.g. inserting a sibling
/// before it) — `SwiftSyntaxEngine.resolve` falls back to a nearest-match
/// search by type name when an exact path lookup fails.
public struct StructuralPath: Codable, Hashable, CustomStringConvertible, Sendable {
    public var components: [Int]

    public init(_ components: [Int]) {
        self.components = components
    }

    public var description: String {
        components.map(String.init).joined(separator: ".")
    }

    public func appending(_ index: Int) -> StructuralPath {
        StructuralPath(components + [index])
    }
}

/// Identifies a single view-producing call expression (e.g. `VStack(...)`,
/// `Button(...)`) within a specific source file.
public struct ViewNodeID: Codable, Hashable, CustomStringConvertible, Sendable {
    public var file: String
    public var path: StructuralPath
    public var typeName: String

    public init(file: String, path: StructuralPath, typeName: String) {
        self.file = file
        self.path = path
        self.typeName = typeName
    }

    public var description: String { "\(typeName)@\(file)#\(path)" }
}

/// A literal value that can be written into (or read out of) a Swift source
/// argument. Intentionally small: it covers exactly the property types the
/// LiveUI MVP scope needs (§65) — numeric layout values and simple flags.
public enum MutationValue: Codable, Equatable, Sendable {
    case integer(Int)
    case double(Double)
    case string(String)
    case boolean(Bool)
}

public struct MutationArgument: Codable, Equatable, Sendable {
    public var label: String?
    public var value: MutationValue

    public init(label: String?, value: MutationValue) {
        self.label = label
        self.value = value
    }
}

/// A single, structurally-targeted change to a Swift source file.
///
/// Mutations never describe raw text ranges — only *what* changed
/// semantically (an argument's value, a modifier's argument, a new
/// modifier). `MutationEngine` is the only thing that turns a `Mutation`
/// into an actual text edit, by locating the corresponding AST node and
/// rewriting only that node (§11-13: Minimal Source Modification).
public enum Mutation: Codable, Equatable, Sendable {
    /// `VStack(spacing: 20)` -> `VStack(spacing: 34)`
    case modifyArgument(
        target: ViewNodeID,
        callName: String,
        argumentLabel: String?,
        argumentIndex: Int,
        oldValue: MutationValue,
        newValue: MutationValue
    )

    /// `.frame(width: 200)` -> `.frame(width: 240)` on a modifier already
    /// present in the chain rooted at `target`.
    case modifyModifierArgument(
        target: ViewNodeID,
        modifierName: String,
        argumentLabel: String?,
        argumentIndex: Int,
        oldValue: MutationValue,
        newValue: MutationValue
    )

    /// Appends a brand-new trailing modifier call to the chain rooted at
    /// `target`, e.g. adding `.padding(12)`.
    case addModifier(
        target: ViewNodeID,
        modifierName: String,
        arguments: [MutationArgument]
    )

    /// The node this mutation targets, common to every case.
    public var target: ViewNodeID {
        switch self {
        case .modifyArgument(let target, _, _, _, _, _): return target
        case .modifyModifierArgument(let target, _, _, _, _, _): return target
        case .addModifier(let target, _, _): return target
        }
    }
}

/// One entry in the undo/redo timeline (§27-28). Keeps both full-file
/// snapshots so undo/redo never has to re-run the mutation logic — it just
/// restores text, which is what makes rollback (§55) unconditionally safe.
public struct MutationRecord: Codable, Identifiable, Sendable {
    public var id: UUID
    public var timestamp: Date
    public var mutation: Mutation
    public var file: String
    public var oldSource: String
    public var newSource: String
    public var diff: String

    public init(id: UUID, timestamp: Date, mutation: Mutation, file: String, oldSource: String, newSource: String, diff: String) {
        self.id = id
        self.timestamp = timestamp
        self.mutation = mutation
        self.file = file
        self.oldSource = oldSource
        self.newSource = newSource
        self.diff = diff
    }
}
