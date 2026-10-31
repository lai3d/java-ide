import Foundation
import Testing
@testable import JavaIDECore

@Suite struct OutputLinksTests {
    @Test func findsCompilerErrors() {
        let text = """
            [ERROR] /p/src/main/java/com/example/App.java:[12,5] cannot find symbol
            /p/Main.java:7: error: ';' expected
            e: file:///p/build.gradle.kts:3:1: Unresolved reference
            """
        let targets = OutputLinks.find(in: text).map(\.target)
        #expect(targets == [
            .file(path: "/p/src/main/java/com/example/App.java", line: 12, column: 5),
            .file(path: "/p/Main.java", line: 7, column: nil),
            .file(path: "/p/build.gradle.kts", line: 3, column: 1),
        ])
    }

    @Test func findsStackFramesAndLinksTheLocation() throws {
        let text = """
            Exception in thread "main" java.lang.IllegalStateException: boom
            \tat com.example.App$Inner.run(App.java:42)
            \tat java.base/java.util.ArrayList.forEach(ArrayList.java:1596)
            \tat Main.main(Main.java:9)
            """
        let links = OutputLinks.find(in: text)
        #expect(links.count == 3)
        guard case .stackFrame(let cls, let file, let line, let lineText) = links[0].target else {
            Issue.record("not a frame"); return
        }
        #expect(cls == "com.example.App" && file == "App.java" && line == 42)
        #expect(lineText == "at com.example.App$Inner.run(App.java:42)")
        #expect((text as NSString).substring(with: links[0].range) == "(App.java:42)")
        #expect(OutputLinks.relativePath(className: "com.example.App", fileName: "App.java") == "com/example/App.java")
        #expect(OutputLinks.relativePath(className: "Main", fileName: "Main.java") == "Main.java")
        guard case .stackFrame(let jdkClass, _, _, _) = links[1].target else { Issue.record("no jdk frame"); return }
        #expect(jdkClass == "java.util.ArrayList")
    }

    @Test func roundTripsURLs() {
        let targets: [OutputLinks.Target] = [
            .file(path: "/a b/C.java", line: 3, column: 4),
            .stackFrame(className: "a.B", fileName: "B.java", line: 5, text: "at a.B.m(B.java:5)"),
        ]
        for target in targets { #expect(OutputLinks.target(from: OutputLinks.url(for: target)) == target) }
        #expect(OutputLinks.target(from: URL(string: "https://example.com")!) == nil)
    }

    @Test func attachesLinksToAttributedOutput() {
        let attributed = OutputLinks.attributed("x\n\tat Main.main(Main.java:9)\n")
        let links = attributed.runs.compactMap(\.link)
        #expect(links.count == 1)
        #expect(links.first?.scheme == "javaide")
    }
}
