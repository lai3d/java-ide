import Foundation
import Testing
@testable import JavaIDECore

@Suite struct DAPModelTests {
    @Test func parsesFramesAndVariables() {
        let frames = StackFrameInfo.parseAll(["stackFrames": [
            ["id": 3, "name": "square", "line": 2, "column": 1, "source": ["path": "/p/main.py"]],
            ["id": 4, "name": "<module>", "line": 5, "column": 1],
        ]])
        #expect(frames.map(\.name) == ["square", "<module>"])
        #expect(frames[0].path == "/p/main.py" && frames[1].path == nil)
        let vars = VariableInfo.parseAll(["variables": [
            ["name": "n", "value": "7", "type": "int", "variablesReference": 0],
            ["name": "items", "value": "[1, 2]", "type": "list", "variablesReference": 12],
        ]])
        #expect(vars.map(\.reference) == [0, 12])
        #expect(VariableInfo.parseAll(["scopes": [["name": "Locals", "variablesReference": 5, "expensive": false]]])
                .first?.reference == 5)
    }

    @Test func sha1MatchesKnownVectors() {
        #expect(SHA1.hex(Data()) == "da39a3ee5e6b4b0d3255bfef95601890afd80709")
        #expect(SHA1.hex(Data("abc".utf8)) == "a9993e364706816aba3e25717850c26c9cd0d89d")
        #expect(SHA1.hex(Data(String(repeating: "a", count: 1000).utf8)) == "291e9a6c66994949b57ba5e650361e98fc36b1ba")
    }

    @Test func locatesJavaDebugJar() {
        #expect(JavaDebugLocator.jarName == "com.microsoft.java.debug.plugin-\(JavaDebugLocator.version).jar")
        #expect(JavaDebugLocator.downloadURL.absoluteString.hasPrefix("https://repo1.maven.org/maven2/com/microsoft/java/"))
        let options = LanguageServerSpec.initializationOptions(jdk: nil, bundles: [URL(fileURLWithPath: "/x/debug.jar")])
        #expect(options["bundles"] == ["/x/debug.jar"])
    }
}

/// Collects DAP events for the end-to-end test.
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [(String, JSONValue)] = []
    func add(_ event: String, _ body: JSONValue) { lock.withLock { events.append((event, body)) } }
    func first(_ name: String) -> JSONValue? { lock.withLock { events.first { $0.0 == name }?.1 } }
    func count(_ name: String) -> Int { lock.withLock { events.filter { $0.0 == name }.count } }
}

@Suite(.serialized) struct JavaDebugEndToEndTests {
    static let canRun = hasJdtls && JavaDebugLocator.installedJar != nil && JDK.locate() != nil

    @Test(.enabled(if: canRun), .timeLimit(.minutes(4)))
    func breakpointLocalsStdinAndEvaluate() async throws {
        let tmp = URL(fileURLWithPath: String(cString: realpath(FileManager.default.temporaryDirectory.path, nil)))
        let dir = tmp.appendingPathComponent("javaide-debug-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: JavaProject.cacheDirectory(for: dir))
        }
        let source = """
            import java.util.Scanner;

            public class Main {
                public static void main(String[] args) {
                    String name = new Scanner(System.in).nextLine();
                    int total = 0;
                    for (int i = 1; i <= 3; i++) {
                        total += i;
                    }
                    System.out.println("hi " + name + " " + total);
                }
            }

            """
        let file = dir.appendingPathComponent("Main.java")
        try source.write(to: file, atomically: true, encoding: .utf8)
        let jdk = try #require(JDK.locate())

        // jdtls with the java-debug bundle.
        let log = NotificationLog()
        let lsp = LSPClient()
        lsp.onNotification = { method, params in log.record(method, params) }
        lsp.configurationProvider = { items in LanguageServerSpec.configuration(items: items, jdk: jdk) }
        try lsp.start(executable: try #require(LanguageServerSpec.locate()), arguments: LanguageServerSpec.arguments(root: dir),
                      environment: LanguageServerSpec.environment(base: ProcessInfo.processInfo.environment), currentDirectory: dir)
        _ = try await lsp.request("initialize", params: [
            "processId": .int(Int(ProcessInfo.processInfo.processIdentifier)),
            "rootUri": .string(dir.absoluteString),
            "initializationOptions": LanguageServerSpec.initializationOptions(jdk: jdk, bundles: [try #require(JavaDebugLocator.installedJar)]),
            "capabilities": ["workspace": ["configuration": true]],
        ])
        try lsp.notify("initialized", params: [:])
        try lsp.notify("textDocument/didOpen", params: [
            "textDocument": ["uri": .string(file.absoluteString), "languageId": "java", "version": 1, "text": .string(source)],
        ])
        #expect(await log.wait { log.isReady })

        let mains = try await lsp.request("workspace/executeCommand", params: [
            "command": "vscode.java.resolveMainClass", "arguments": [.string(dir.absoluteString)],
        ]).arrayValue ?? []
        let main = try #require(mains.first, "no main class")
        #expect(main["mainClass"]?.stringValue == "Main")
        let projectName = main["projectName"]?.stringValue ?? ""
        let paths = try await lsp.request("workspace/executeCommand", params: [
            "command": "vscode.java.resolveClasspath", "arguments": ["Main", .string(projectName)],
        ])
        let port = try #require(try await lsp.request("workspace/executeCommand",
                                                       params: ["command": "vscode.java.startDebugSession"]).intValue)

        // DAP over TCP; we launch the JVM ourselves (runInTerminal) so we own its stdin.
        let events = EventLog()
        let output = OutputBuffer()
        let dap = DAPClient()
        dap.onEvent = { event, body in events.add(event, body) }
        let debuggee = PipedProcess()
        debuggee.onOutput = { output.append($0) }
        dap.onReverseRequest = { command, arguments in
            guard command == "runInTerminal" else { return nil }
            try debuggee.start(arguments: arguments["args"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                               environment: ProcessInfo.processInfo.environment,
                               currentDirectory: dir)
            return ["processId": .int(Int(debuggee.processIdentifier))]
        }
        try dap.connect(port: port)
        _ = try await dap.request("initialize", arguments: [
            "adapterID": "java", "linesStartAt1": true, "columnsStartAt1": true, "pathFormat": "path",
            "supportsRunInTerminalRequest": true,
        ])
        _ = try await dap.request("launch", arguments: [
            "mainClass": "Main", "projectName": .string(projectName),
            "modulePaths": paths[0] ?? [], "classPaths": paths[1] ?? [],
            "cwd": .string(dir.path), "console": "integratedTerminal", "javaExec": .string(jdk.java.path),
        ])
        #expect(await log.wait(timeout: .seconds(30)) { events.first("initialized") != nil })
        // Conditional breakpoint on `total += i;` (line 8), only when i == 3.
        let set = try await dap.request("setBreakpoints", arguments: [
            "source": ["path": .string(file.path)],
            "breakpoints": [SourceBreakpoint(line: 8, condition: "i == 3").json],
        ])
        #expect(set["breakpoints"]?[0]?["verified"] == .bool(true))
        _ = try await dap.request("configurationDone")

        debuggee.send("Ada\n")
        #expect(await log.wait(timeout: .seconds(30)) { events.first("stopped") != nil })
        let thread = try #require(events.first("stopped")?["threadId"]?.intValue)
        let frames = StackFrameInfo.parseAll(try await dap.request("stackTrace", arguments: ["threadId": .int(thread)]))
        #expect(frames.first?.line == 8 && frames.first?.name.contains("main") == true, "frames: \(frames)")
        let scopes = VariableInfo.parseAll(try await dap.request("scopes", arguments: ["frameId": .int(frames[0].id)]))
        let locals = VariableInfo.parseAll(try await dap.request("variables",
                                                                 arguments: ["variablesReference": .int(scopes[0].reference)]))
        #expect(locals.first { $0.name == "i" }?.value == "3", "locals: \(locals)")
        #expect(locals.first { $0.name == "total" }?.value == "3")
        #expect(locals.first { $0.name == "name" }?.value.contains("Ada") == true)
        let evaluated = try await dap.request("evaluate", arguments: [
            "expression": "total * 10 + i", "frameId": .int(frames[0].id), "context": "repl",
        ])
        #expect(evaluated["result"]?.stringValue == "33")

        _ = try await dap.request("continue", arguments: ["threadId": .int(thread)])
        #expect(await log.wait(timeout: .seconds(30)) { output.text.contains("hi Ada 6") }, "output: \(output.text)")
        dap.terminate()
        debuggee.terminate()
        await lsp.shutdown()
    }
}

final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""
    func append(_ s: String) { lock.withLock { value += s } }
    var text: String { lock.withLock { value } }
}
