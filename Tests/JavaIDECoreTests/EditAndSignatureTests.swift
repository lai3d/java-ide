import Foundation
import Testing
@testable import JavaIDECore

@Suite struct TextEditApplyTests {
    private func edit(_ l1: Int, _ c1: Int, _ l2: Int, _ c2: Int, _ text: String) -> TextEdit {
        TextEdit(start: TextPosition(line: l1, character: c1), end: TextPosition(line: l2, character: c2), newText: text)
    }

    @Test func appliesEditsAgainstOriginalPositions() {
        let text = "def helper():\n    return 1\n\nhelper()\nx = helper\n"
        let edits = [edit(0, 4, 0, 10, "assist"), edit(3, 0, 3, 6, "assist"), edit(4, 4, 4, 10, "assist")]
        #expect(TextEdit.apply(edits, to: text) == "def assist():\n    return 1\n\nassist()\nx = assist\n")
        #expect(TextEdit.apply(edits.reversed(), to: text) == TextEdit.apply(edits, to: text))  // order-independent
    }

    @Test func handlesInsertionsDeletionsAndUTF16() {
        #expect(TextEdit.apply([edit(0, 0, 0, 0, "import os\n")], to: "x\n") == "import os\nx\n")
        #expect(TextEdit.apply([edit(0, 3, 0, 4, "")], to: "😀ab") == "😀a")  // emoji is 2 UTF-16 units
    }

    @Test func parsesWorkspaceEditShapes() {
        let range: JSONValue = ["start": ["line": 0, "character": 4], "end": ["line": 0, "character": 10]]
        let changes = WorkspaceEdit.parse(["changes": ["file:///a.py": [["range": range, "newText": "b"]]]])
        #expect(changes["file:///a.py"]?.count == 1)
        let documentChanges = WorkspaceEdit.parse(["documentChanges": [
            ["textDocument": ["uri": "file:///a.py", "version": 3], "edits": [["range": range, "newText": "b"]]],
            ["kind": "rename", "oldUri": "file:///x.py", "newUri": "file:///y.py"],
        ]])
        #expect(Array(documentChanges.keys) == ["file:///a.py"])
    }
}

@Suite struct SignatureParsingTests {
    @Test func parsesOffsetAndStringParameterLabels() throws {
        let result: JSONValue = [
            "signatures": [[
                "label": "(a: int, b: str = \"x\") -> None",
                "documentation": ["kind": "markdown", "value": "Does things."],
                "parameters": [["label": [1, 7]], ["label": "b: str = \"x\""]],
                "activeParameter": 1,
            ]],
            "activeSignature": 0,
        ]
        let info = try #require(SignatureInfo.parse(result))
        let label = info.label as NSString
        #expect(label.substring(with: info.parameters[0]) == "a: int")
        #expect(label.substring(with: try #require(info.activeParameterRange)) == "b: str = \"x\"")
        #expect(info.documentation == "Does things.")
        #expect(info.overloadPosition == nil)
        #expect(SignatureInfo.parse(["signatures": []]) == nil)
        #expect(SignatureInfo.parse(.null) == nil)
    }

    @Test func validatesJavaNames() {
        #expect(Identifier.isValidJavaName("newName2"))
        #expect(Identifier.isValidJavaName("_x"))
        #expect(Identifier.isValidJavaName("$proxy"))
        #expect(!Identifier.isValidJavaName("2x"))
        #expect(!Identifier.isValidJavaName("class"))
        #expect(!Identifier.isValidJavaName("int"))
        #expect(!Identifier.isValidJavaName("null"))
        #expect(!Identifier.isValidJavaName("_"))
        #expect(!Identifier.isValidJavaName("a-b"))
        #expect(!Identifier.isValidJavaName(""))
    }

    @Test func parsesPrepareRename() {
        let range: JSONValue = ["start": ["line": 2, "character": 4], "end": ["line": 2, "character": 10]]
        #expect(PrepareRename.parse(range)?.start == TextPosition(line: 2, character: 4))
        #expect(PrepareRename.parse(["range": range, "placeholder": "helper"])?.placeholder == "helper")
        #expect(PrepareRename.parse(.null) == nil)
    }
}
