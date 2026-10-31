import Foundation
import Testing
@testable import JavaIDECore

@Suite struct JavaHighlighterTests {
    private func kinds(_ source: String) -> [(String, TokenKind)] {
        let ns = source as NSString
        return JavaHighlighter.tokenize(source).map { (ns.substring(with: $0.range), $0.kind) }
    }

    private func kind(of word: String, in source: String) -> TokenKind? {
        kinds(source).first { $0.0 == word }?.1
    }

    @Test func classifiesTokens() {
        let src = """
            package demo;
            // a comment
            @Override
            public final class Greeter extends Base {
                private static final int MAX_COUNT = 0x1F;
                String s = "hi // not a comment";
                /* block */ char c = '\\n';
                void greet() { System.out.println(s); return; }
                boolean ok = true; Object o = null; double d = 1.5e3;
            }
            """
        #expect(kind(of: "package", in: src) == .keyword)
        #expect(kind(of: "// a comment", in: src) == .comment)
        #expect(kind(of: "@Override", in: src) == .annotation)
        #expect(kind(of: "Greeter", in: src) == .type)
        #expect(kind(of: "Base", in: src) == .type)
        #expect(kind(of: "int", in: src) == .keyword)
        #expect(kind(of: "MAX_COUNT", in: src) == .literal)
        #expect(kind(of: "0x1F", in: src) == .number)
        #expect(kind(of: "\"hi // not a comment\"", in: src) == .string)
        #expect(kind(of: "/* block */", in: src) == .comment)
        #expect(kind(of: "'\\n'", in: src) == .string)
        #expect(kind(of: "greet", in: src) == .function)
        #expect(kind(of: "println", in: src) == .function)
        #expect(kind(of: "true", in: src) == .literal)
        #expect(kind(of: "null", in: src) == .literal)
        #expect(kind(of: "1.5e3", in: src) == .number)
        #expect(kind(of: "s", in: src) == nil)
    }

    @Test func textBlocksAndContextualKeywords() {
        let src = "var text = \"\"\"\n  hello \"quoted\"\n  \"\"\";\nrecord Point(int x, int y) {}\nint var2 = 1;\n"
        #expect(kinds(src).contains { $0.0.hasPrefix("\"\"\"") && $0.0.hasSuffix("\"\"\"") && $0.1 == .string })
        #expect(kind(of: "var", in: src) == .keyword)
        #expect(kind(of: "record", in: src) == .keyword)
        #expect(kind(of: "Point", in: src) == .type)
        #expect(kind(of: "var2", in: src) == nil)
    }
}

@Suite struct JavaIndentTests {
    @Test func indentsAfterOpenBraceAndCase() {
        #expect(JavaIndent.indentAfter(line: "    public void run() {") == "        ")
        #expect(JavaIndent.indentAfter(line: "    foo(") == "        ")
        #expect(JavaIndent.indentAfter(line: "        case 1:") == "            ")
        #expect(JavaIndent.indentAfter(line: "    x = 1; // {") == "    ")
        #expect(JavaIndent.indentAfter(line: "    list.forEach(x ->") == "        ")
    }

    @Test func splitsBracePairs() {
        let (text, caret) = JavaIndent.newline(before: "    void f() {", after: "}")
        #expect(text == "\n        \n    ")
        #expect(caret == 9)
    }

    @Test func continuesJavadoc() {
        let open = JavaIndent.newline(before: "    /**", after: "")
        #expect(open.text == "\n     * \n     */")
        #expect(open.caret == 8)
        let middle = JavaIndent.newline(before: "     * Returns x.", after: "")
        #expect(middle.text == "\n     * ")
    }

    @Test func findsClosingBraceIndent() {
        let text = "class A {\n    void f() {\n        if (x) {\n        \n"
        #expect(JavaIndent.closingBraceIndent(in: text, at: (text as NSString).length - 1) == "        ")
        let text2 = "class A {\n    void f() {\n    }\n  "
        #expect(JavaIndent.closingBraceIndent(in: text2, at: (text2 as NSString).length) == "")
        let text3 = "class A {\n    String s = \"{\";\n    "
        #expect(JavaIndent.closingBraceIndent(in: text3, at: (text3 as NSString).length) == "")
    }
}

@Suite struct JavaProjectTests {
    @Test func readsPackageAndMain() {
        let src = "/* package fake; */\n// package fake2;\npackage com.example.app;\n\npublic class Main {\n  public static void main(String[] args) {}\n}\n"
        #expect(JavaProject.packageName(in: src) == "com.example.app")
        #expect(JavaProject.qualifiedClassName(file: URL(fileURLWithPath: "/x/Main.java"), source: src) == "com.example.app.Main")
        #expect(JavaProject.hasMainMethod(src))
        #expect(JavaProject.hasMainMethod("class A { static void main(String... a) {} }"))
        #expect(JavaProject.hasMainMethod("void main() { }"))  // JDK 21+ instance main
        #expect(!JavaProject.hasMainMethod("class A { // void main() {}\n void mainLoop() {} }"))
        #expect(JavaProject.packageName(in: "class A {}") == nil)
    }

    @Test func detectsBuildSystem() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("javaide-bs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(BuildSystem.detect(root: dir) == .plain)
        try "plugins { id 'application' }".write(to: dir.appendingPathComponent("build.gradle"), atomically: true, encoding: .utf8)
        #expect(BuildSystem.detect(root: dir) == .gradle)
        #expect(RunCommand.usesApplicationPlugin(root: dir))
        try "<project/>".write(to: dir.appendingPathComponent("pom.xml"), atomically: true, encoding: .utf8)
        #expect(BuildSystem.detect(root: dir) == .maven)
    }

    @Test func parsesJDKRelease() {
        #expect(JDK.parseRelease("IMPLEMENTOR=\"Microsoft\"\nJAVA_VERSION=\"21.0.5\"\n") == "21.0.5")
        #expect(JDK(home: URL(fileURLWithPath: "/nope"), version: "1.8.0_402").majorVersion == 8)
        #expect(JDK(home: URL(fileURLWithPath: "/nope"), version: "17.0.1").majorVersion == 17)
    }

    @Test func cacheDirectoryIsStable() {
        let root = URL(fileURLWithPath: "/tmp/my project")
        #expect(JavaProject.cacheDirectory(for: root) == JavaProject.cacheDirectory(for: root))
        #expect(JavaProject.cacheDirectory(for: root).lastPathComponent.hasPrefix("myproject-"))
    }

    @Test func quotesShellArguments() {
        #expect(RunCommand.shellQuote("-Dexec.mainClass=a.B") == "-Dexec.mainClass=a.B")
        #expect(RunCommand.shellQuote("/tmp/my dir") == "'/tmp/my dir'")
        #expect(RunCommand.shellQuote("it's") == "'it'\\''s'")
    }

    @Test func buildsMavenAndGradleTestCommands() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("javaide-cmd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let mvnw = dir.appendingPathComponent("mvnw")
        try "#!/bin/sh\n".write(to: mvnw, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mvnw.path)
        let test = try #require(RunCommand.test(className: "a.FooTest", buildSystem: .maven, root: dir))
        #expect(test.shell.hasPrefix("exec \(RunCommand.shellQuote(mvnw.path)) -B -ntp test -Dtest=a.FooTest"))
        #expect(RunCommand.test(className: nil, buildSystem: .plain, root: dir) == nil)
    }

    @Test func plainRunCompilesThenExecs() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("javaide-plain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: JavaProject.cacheDirectory(for: dir))
        }
        let main = dir.appendingPathComponent("Main.java")
        try "public class Main { public static void main(String[] a) { System.out.println(\"hi\"); } }"
            .write(to: main, atomically: true, encoding: .utf8)
        let test = dir.appendingPathComponent("MainTest.java")
        try "import org.junit.jupiter.api.Test; class MainTest {}".write(to: test, atomically: true, encoding: .utf8)
        let jdk = JDK(home: URL(fileURLWithPath: "/jdk"), version: "21")
        let cmd = try #require(RunCommand.run(mainClass: "Main", file: main, buildSystem: .plain, root: dir, jdk: jdk,
                                              sources: [main, test]))
        #expect(cmd.shell.contains("/jdk/bin/javac"))
        #expect(cmd.shell.contains("exec /jdk/bin/java -cp"))
        let list = try String(contentsOf: JavaProject.cacheDirectory(for: dir).appendingPathComponent("sources.txt"), encoding: .utf8)
        #expect(list.contains("Main.java") && !list.contains("MainTest.java"))
    }
}

@Suite struct CodeActionTests {
    @Test func parsesAndRanksActions() {
        let result: JSONValue = [
            ["title": "Organize imports", "kind": "source.organizeImports", "edit": ["changes": [:]]],
            ["title": "Import 'List' (java.util)", "kind": "quickfix", "edit": ["changes": [:]]],
            ["title": "Extract to method", "kind": "refactor.extract", "command": ["title": "x", "command": "java.action.x"]],
            ["title": "Bare command", "command": "java.apply.workspaceEdit", "arguments": []],
            ["title": "Preferred fix", "kind": "quickfix", "isPreferred": true, "data": ["id": 1]],
        ]
        let actions = CodeAction.parseList(result)
        #expect(actions.map(\.title) == ["Preferred fix", "Import 'List' (java.util)", "Extract to method",
                                          "Organize imports", "Bare command"])
        #expect(actions[0].needsResolve)
        #expect(actions[4].command?["command"]?.stringValue == "java.apply.workspaceEdit")
    }

    @Test func namesClassFiles() {
        let uri = "jdt://contents/java.base/java.lang/String.class?=demo/%5C/Library%5C/Java"
        #expect(ClassFileURI.isClassFile(uri))
        #expect(ClassFileURI.fileName(for: uri) == "String.java")
        #expect(ClassFileURI.packagePath(for: uri) == "java.lang")
        #expect(!ClassFileURI.isClassFile("file:///tmp/A.java"))
    }

    @Test func answersConfigurationSections() {
        let jdk = JDK(home: URL(fileURLWithPath: "/jdk"), version: "21.0.1")
        let result = LanguageServerSpec.configuration(items: [["section": "java.format"], ["section": "java"], ["section": "nope"]], jdk: jdk)
        #expect(result[0]?["enabled"] == .bool(true))
        #expect(result[1]?["home"]?.stringValue == "/jdk")
        #expect(result[1]?["configuration"]?["runtimes"]?[0]?["name"]?.stringValue == "JavaSE-21")
        #expect(result[2] == .null)
    }

    @Test func preparesJShellSnippets() {
        #expect(JShellREPL.prepareForSending("\n    int x = 1;\n    x + 1\n\n") == "int x = 1;\nx + 1\n")
        #expect(JShellREPL.prepareForSending("  \n") == "")
    }

    @Test func parsesAttachAddress() {
        #expect(JavaDebugLocator.parseAddress("localhost:5005")! == ("localhost", 5005))
        #expect(JavaDebugLocator.parseAddress("5005")! == ("localhost", 5005))
        #expect(JavaDebugLocator.parseAddress(":8000")! == ("localhost", 8000))
        #expect(JavaDebugLocator.parseAddress("10.0.0.2:5005")! == ("10.0.0.2", 5005))
        #expect(JavaDebugLocator.parseAddress("host:99999") == nil)
        #expect(JavaDebugLocator.parseAddress("nope") == nil)
    }
}
