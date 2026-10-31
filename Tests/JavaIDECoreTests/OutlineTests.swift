import Foundation
import Testing
@testable import JavaIDECore

@Suite struct OutlineTests {
    private func range(_ a: Int, _ b: Int) -> JSONValue {
        ["start": ["line": .int(a), "character": 0], "end": ["line": .int(b), "character": 0]]
    }

    @Test func parsesHierarchicalSymbols() {
        let result: JSONValue = [
            ["name": "main", "kind": 12, "range": range(10, 14), "selectionRange": range(10, 10)],
            ["name": "Greeter", "kind": 5, "range": range(2, 8), "selectionRange": range(2, 2), "children": [
                ["name": "greet", "kind": 6, "range": range(5, 8), "selectionRange": range(5, 5)],
                ["name": "punctuation", "kind": 13, "range": range(3, 3), "selectionRange": range(3, 3)],
            ]],
        ]
        let symbols = OutlineSymbol.parse(result)
        #expect(symbols.map(\.name) == ["Greeter", "main"])
        #expect(symbols[0].children?.map(\.name) == ["punctuation", "greet"])
        #expect(symbols[0].kind == .classType && symbols[1].children == nil)
        #expect(OutlineSymbol.innermost(containing: 6, in: symbols)?.name == "greet")
        #expect(OutlineSymbol.innermost(containing: 9, in: symbols) == nil)
    }

    @Test func nestsFlatSymbolInformation() {
        func info(_ name: String, _ kind: Int, _ a: Int, _ b: Int) -> JSONValue {
            ["name": .string(name), "kind": .int(kind), "location": ["uri": "file:///a.py", "range": range(a, b)]]
        }
        let symbols = OutlineSymbol.parse([info("A", 5, 0, 5), info("m", 6, 1, 3), info("f", 12, 7, 9)])
        #expect(symbols.map(\.name) == ["A", "f"])
        #expect(symbols[0].children?.map(\.name) == ["m"])
    }
}
