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

    /// A vertical drag must only ever touch the vertical edge — the
    /// unlabeled `.padding(N)` form pads all four sides at once, which
    /// was an earlier real bug (a vertical-only drag also visibly shoved
    /// the view sideways). `.padding(.top, N)` round-tripping through
    /// SwiftSyntax correctly (member-shorthand argument + numeric
    /// argument) is what LayoutEngine's fallback now always produces.
    func testAddEdgeSpecificPaddingModifier() throws {
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
            arguments: [
                MutationArgument(label: nil, value: .memberShorthand("top")),
                MutationArgument(label: nil, value: .integer(12))
            ]
        )

        let (newSource, _) = try MutationEngine.apply(mutation, toSource: source, filePath: "ContentView.swift")
        XCTAssertTrue(newSource.contains(".padding(.top, 12)"))
    }

    /// Reproduces the exact bug seen in real testing: drag vertically,
    /// then horizontally (which becomes the new outermost modifier), then
    /// vertically again. The third drag must find and update the *first*
    /// drag's `.top` modifier — not fail to find it (since it's no longer
    /// outermost) and add a second, competing `.top` call. Two `.top`
    /// modifiers apply additively, which is exactly why a drag's landing
    /// position was drifting away from where the cursor was released.
    func testAlternatingAxisDragsEachUpdateTheirOwnModifier() throws {
        let source = """
        struct ContentView: View {
            var body: some View {
                Text("Title")
            }
        }
        """
        let index = SourceIndexer.index(source: source, filePath: "ContentView.swift")
        let text = try XCTUnwrap(firstNode(named: "Text", in: index.roots))

        // Drag 1 (vertical): adds .padding(.top, 20)
        let addTop = Mutation.addModifier(
            target: text.id, modifierName: "padding",
            arguments: [MutationArgument(label: nil, value: .memberShorthand("top")), MutationArgument(label: nil, value: .integer(20))]
        )
        let (afterTop, _) = try MutationEngine.apply(addTop, toSource: source, filePath: "ContentView.swift")
        XCTAssertTrue(afterTop.contains(".padding(.top, 20)"))

        // Drag 2 (horizontal): adds a SEPARATE .padding(.leading, 8)
        let indexAfterTop = SourceIndexer.index(source: afterTop, filePath: "ContentView.swift")
        let textAfterTop = try XCTUnwrap(firstNode(named: "Text", in: indexAfterTop.roots))
        let addLeading = Mutation.addModifier(
            target: textAfterTop.id, modifierName: "padding",
            arguments: [MutationArgument(label: nil, value: .memberShorthand("leading")), MutationArgument(label: nil, value: .integer(8))]
        )
        let (afterLeading, _) = try MutationEngine.apply(addLeading, toSource: afterTop, filePath: "ContentView.swift")
        XCTAssertTrue(afterLeading.contains(".padding(.top, 20)"))
        XCTAssertTrue(afterLeading.contains(".padding(.leading, 8)"))

        // Drag 3 (vertical again): must UPDATE the original .top modifier,
        // even though .leading is now outermost.
        let indexAfterLeading = SourceIndexer.index(source: afterLeading, filePath: "ContentView.swift")
        let textAfterLeading = try XCTUnwrap(firstNode(named: "Text", in: indexAfterLeading.roots))
        let updateTop = Mutation.modifyModifierArgument(
            target: textAfterLeading.id, modifierName: "padding", argumentLabel: nil, argumentIndex: 1,
            oldValue: .integer(20), newValue: .integer(34)
        )
        let (final, _) = try MutationEngine.apply(updateTop, toSource: afterLeading, filePath: "ContentView.swift")

        XCTAssertTrue(final.contains(".padding(.top, 34)"), "must update the existing .top modifier")
        XCTAssertFalse(final.contains(".padding(.top, 20)"), "the stale .top value must be gone")
        XCTAssertTrue(final.contains(".padding(.leading, 8)"), "the unrelated .leading modifier must be untouched")

        let topModifierCount = final.components(separatedBy: ".padding(.top,").count - 1
        XCTAssertEqual(topModifierCount, 1, "must never end up with two separate .top padding modifiers")
    }

    /// Swift has no single "negative literal" token — `-103` parses as a
    /// prefix `-` operator applied to the positive literal `103`, not one
    /// literal reading "-103". A value written naively as a single token
    /// prints correctly the *first* time, but breaks on the *next* parse,
    /// which is exactly what happened in real testing: dragging a view to
    /// a negative padding worked once, then the following drag on that
    /// same (now negative) value threw "unsupported literal". This test
    /// drives the exact same two-step round trip through MutationEngine.
    func testNegativeValueRoundTripsAcrossTwoMutations() throws {
        let source = """
        struct ContentView: View {
            var body: some View {
                Text("Title")
            }
        }
        """
        let index = SourceIndexer.index(source: source, filePath: "ContentView.swift")
        let text = try XCTUnwrap(firstNode(named: "Text", in: index.roots))

        let firstMutation = Mutation.addModifier(
            target: text.id,
            modifierName: "padding",
            arguments: [MutationArgument(label: nil, value: .integer(-103))]
        )
        let (afterFirst, _) = try MutationEngine.apply(firstMutation, toSource: source, filePath: "ContentView.swift")
        XCTAssertTrue(afterFirst.contains(".padding(-103)"))

        // Re-index the ACTUAL resulting source, exactly as a second drag
        // would: this is what turns "-103" from whatever in-memory shape
        // produced it into the real PrefixOperatorExprSyntax the parser
        // yields for negative numbers.
        let reindexed = SourceIndexer.index(source: afterFirst, filePath: "ContentView.swift")
        let reindexedText = try XCTUnwrap(firstNode(named: "Text", in: reindexed.roots))

        let secondMutation = Mutation.modifyModifierArgument(
            target: reindexedText.id,
            modifierName: "padding",
            argumentLabel: nil,
            argumentIndex: 0,
            oldValue: .integer(-103),
            newValue: .integer(-217)
        )
        let (afterSecond, _) = try MutationEngine.apply(secondMutation, toSource: afterFirst, filePath: "ContentView.swift")
        XCTAssertTrue(afterSecond.contains(".padding(-217)"))
        XCTAssertFalse(afterSecond.contains(".padding(-103)"))
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
