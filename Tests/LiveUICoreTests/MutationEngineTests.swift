import XCTest
@testable import LiveUICore
@testable import LiveUIModels

/// These tests are the executable version of the LiveUI spec's own
/// motivating example (§15, §69): a user drags a view, and the *only*
/// thing that changes in the file is the one number that captures their
/// intent — nothing else is reformatted, reordered, or rewritten.
final class MutationEngineTests: XCTestCase {

    func testVStackSpacingMutationProducesMinimalDiff() throws {
        let source = """
        struct ContentView: View {
            var body: some View {
                VStack(spacing: 20) {
                    Text("Welcome")
                    Button("Continue") {
                        login()
                    }
                }
                .padding()
            }
        }
        """
        let index = SourceIndexer.index(source: source, filePath: "ContentView.swift")
        let vstack = try XCTUnwrap(firstNode(named: "VStack", in: index.roots))

        let mutation = Mutation.modifyArgument(
            target: vstack.id,
            callName: "VStack",
            argumentLabel: "spacing",
            argumentIndex: 0,
            oldValue: .integer(20),
            newValue: .integer(34)
        )

        let (newSource, diff) = try MutationEngine.apply(mutation, toSource: source, filePath: "ContentView.swift")

        XCTAssertTrue(newSource.contains("VStack(spacing: 34)"))
        XCTAssertFalse(newSource.contains("VStack(spacing: 20)"))

        // "Minimal source modification" (§13): exactly one line differs.
        let oldLines = source.components(separatedBy: "\n")
        let newLines = newSource.components(separatedBy: "\n")
        XCTAssertEqual(oldLines.count, newLines.count, "line count must be unchanged")
        let changedLines = zip(oldLines, newLines).filter { $0 != $1 }
        XCTAssertEqual(changedLines.count, 1, "exactly one line should differ")

        XCTAssertTrue(diff.contains("20"))
        XCTAssertTrue(diff.contains("34"))
    }

    func testModifierArgumentMutationOnExistingFrame() throws {
        let source = """
        struct ContentView: View {
            var body: some View {
                Button("Continue") { login() }
                    .frame(width: 200)
            }
        }
        """
        let index = SourceIndexer.index(source: source, filePath: "ContentView.swift")
        let button = try XCTUnwrap(firstNode(named: "Button", in: index.roots))

        // `.frame(width: 200)` is a modifier on the Button's chain, not an
        // argument of `Button(...)` itself — this exercises §50-51's
        // modifier-chain traversal, not the simpler direct-argument path.
        let mutation = Mutation.modifyModifierArgument(
            target: button.id,
            modifierName: "frame",
            argumentLabel: "width",
            argumentIndex: 0,
            oldValue: .integer(200),
            newValue: .integer(240)
        )

        let (newSource, _) = try MutationEngine.apply(mutation, toSource: source, filePath: "ContentView.swift")
        XCTAssertTrue(newSource.contains(".frame(width: 240)"))
        XCTAssertFalse(newSource.contains(".frame(width: 200)"))
    }

    func testAddPaddingModifierAppendsToChain() throws {
        let source = """
        struct ContentView: View {
            var body: some View {
                Text("Title")
            }
        }
        """
        let index = SourceIndexer.index(source: source, filePath: "ContentView.swift")
        let text = try XCTUnwrap(firstNode(named: "Text", in: index.roots))

        let mutation = Mutation.addModifier(
            target: text.id,
            modifierName: "padding",
            arguments: [MutationArgument(label: nil, value: .integer(12))]
        )

        let (newSource, _) = try MutationEngine.apply(mutation, toSource: source, filePath: "ContentView.swift")
        XCTAssertTrue(newSource.contains(".padding(12)"))
        XCTAssertTrue(newSource.contains("Text(\"Title\")"), "the original call must be preserved verbatim")
    }

    func testMutationOnStaleTargetThrowsRatherThanCorrupting() {
        let source = """
        struct ContentView: View {
            var body: some View {
                Text("Title")
            }
        }
        """
        let bogusTarget = ViewNodeID(file: "ContentView.swift", path: StructuralPath([9, 9, 9]), typeName: "VStack")
        let mutation = Mutation.modifyArgument(
            target: bogusTarget, callName: "VStack", argumentLabel: "spacing",
            argumentIndex: 0, oldValue: .integer(20), newValue: .integer(34)
        )

        XCTAssertThrowsError(try MutationEngine.apply(mutation, toSource: source, filePath: "ContentView.swift")) { error in
            XCTAssertTrue("\(error)".contains("Could not resolve") || error is SwiftSyntaxEngineError)
        }
    }

    private func firstNode(named typeName: String, in nodes: [IndexedNode]) -> IndexedNode? {
        for node in nodes {
            if node.id.typeName == typeName { return node }
            if let found = firstNode(named: typeName, in: node.children) { return found }
        }
        return nil
    }
}
