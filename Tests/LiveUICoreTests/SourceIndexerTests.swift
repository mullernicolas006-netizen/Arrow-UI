import XCTest
@testable import LiveUICore

final class SourceIndexerTests: XCTestCase {

    func testFindsTopLevelAndNestedViews() {
        let source = """
        struct ContentView: View {
            var body: some View {
                VStack(spacing: 20) {
                    Text("Hello")
                    Button("Continue") { login() }
                }
            }
        }
        """
        let index = SourceIndexer.index(source: source, filePath: "ContentView.swift")

        XCTAssertEqual(index.roots.count, 1)
        let vstack = index.roots[0]
        XCTAssertEqual(vstack.id.typeName, "VStack")
        XCTAssertEqual(vstack.children.map(\.id.typeName), ["Text", "Button"])
    }

    func testDoesNotTreatPlainFunctionCallsAsViews() {
        let source = """
        struct ContentView: View {
            var body: some View {
                Button("Continue") { login() }
            }
        }
        """
        let index = SourceIndexer.index(source: source, filePath: "ContentView.swift")
        XCTAssertEqual(index.roots.count, 1)
        XCTAssertEqual(index.roots[0].id.typeName, "Button")
        XCTAssertTrue(index.roots[0].children.isEmpty, "login() must not be indexed as a nested view")
    }

    func testStructuralPathsAreStableAndUnique() {
        let source = """
        struct ContentView: View {
            var body: some View {
                VStack {
                    Text("A")
                    Text("B")
                }
            }
        }
        """
        let index1 = SourceIndexer.index(source: source, filePath: "ContentView.swift")
        let index2 = SourceIndexer.index(source: source, filePath: "ContentView.swift")

        XCTAssertEqual(index1.roots[0].children[0].id.path, index2.roots[0].children[0].id.path)
        XCTAssertNotEqual(index1.roots[0].children[0].id.path, index1.roots[0].children[1].id.path)
    }
}
