import Foundation
import Testing
@testable import JavaIDECore

/// jdtls (with java-debug) for one throwaway plain-Java project.
private struct DebugHarness {
    let dir: URL
    let file: URL
    let lsp: LSPClient
    let log: NotificationLog
    let jdk: JDK
    let projectName: String

    static func start(source: String) async throws -> DebugHarness {
        let tmp = URL(fileURLWithPath: String(cString: realpath(FileManager.default.temporaryDirectory.path, nil)))
        let dir = tmp.appendingPathComponent("javaide-dbg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("Main.java")
        try source.write(to: file, atomically: true, encoding: .utf8)
        let jdk = try #require(JDK.locate())
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
        return DebugHarness(dir: dir, file: file, lsp: lsp, log: log, jdk: jdk,
                            projectName: mains.first?["projectName"]?.stringValue ?? "")
    }

    func adapter(events: EventLog) async throws -> DAPClient {
        let port = try #require(try await lsp.request("workspace/executeCommand",
                                                       params: ["command": "vscode.java.startDebugSession"]).intValue)
        let dap = DAPClient()
        dap.onEvent = { event, body in events.add(event, body) }
        try dap.connect(port: port)
        _ = try await dap.request("initialize", arguments: [
            "adapterID": "java", "linesStartAt1": true, "columnsStartAt1": true, "pathFormat": "path",
            "supportsRunInTerminalRequest": true,
        ])
        return dap
    }

    func breakpoint(_ dap: DAPClient, line: Int) async throws {
        let set = try await dap.request("setBreakpoints", arguments: [
            "source": ["path": .string(file.path)], "breakpoints": [SourceBreakpoint(line: line).json],
        ])
        #expect(set["breakpoints"]?[0]?["verified"] == .bool(true))
    }

    func shutdown() async {
        await lsp.shutdown()
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.removeItem(at: JavaProject.cacheDirectory(for: dir))
    }
}

@Suite(.serialized) struct DebuggerExtrasEndToEndTests {
    static let canRun = hasJdtls && JavaDebugLocator.installedJar != nil && JDK.locate() != nil

    static let source = """
        public class Main {
            static int value() { return 1; }

            public static void main(String[] args) throws Exception {
                int[] data = {3, 4};
                for (int i = 0; i < 2; i++) {
                    System.out.println("value=" + value() + " i=" + i);
                }
            }
        }

        """

    /// Watches (evaluate with context "watch") and hot code replace of a method body mid-session.
    @Test(.enabled(if: canRun), .timeLimit(.minutes(4)))
    func watchesAndHotCodeReplace() async throws {
        let h = try await DebugHarness.start(source: Self.source)
        let events = EventLog()
        let output = OutputBuffer()
        let debuggee = PipedProcess()
        debuggee.onOutput = { output.append($0) }
        let dap = try await h.adapter(events: events)
        dap.onReverseRequest = { command, arguments in
            guard command == "runInTerminal" else { return nil }
            try debuggee.start(arguments: arguments["args"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                               environment: ProcessInfo.processInfo.environment, currentDirectory: h.dir)
            return ["processId": .int(Int(debuggee.processIdentifier))]
        }
        let paths = try await h.lsp.request("workspace/executeCommand", params: [
            "command": "vscode.java.resolveClasspath", "arguments": ["Main", .string(h.projectName)],
        ])
        _ = try await dap.request("launch", arguments: [
            "mainClass": "Main", "projectName": .string(h.projectName),
            "modulePaths": paths[0] ?? [], "classPaths": paths[1] ?? [],
            "cwd": .string(h.dir.path), "console": "integratedTerminal", "javaExec": .string(h.jdk.java.path),
        ])
        #expect(await h.log.wait(timeout: .seconds(30)) { events.first("initialized") != nil })
        try await h.breakpoint(dap, line: 7)
        _ = try await dap.request("configurationDone")
        #expect(await h.log.wait(timeout: .seconds(30)) { events.count("stopped") == 1 })
        let thread = try #require(events.first("stopped")?["threadId"]?.intValue)
        let frame = try #require(StackFrameInfo.parseAll(try await dap.request("stackTrace", arguments: ["threadId": .int(thread)])).first)

        // Watches: a primitive expression and an expandable array.
        let sum = try await dap.request("evaluate", arguments: ["expression": "data[0] + data[1] * 10", "frameId": .int(frame.id), "context": "watch"])
        #expect(sum["result"]?.stringValue == "43")
        let array = try await dap.request("evaluate", arguments: ["expression": "data", "frameId": .int(frame.id), "context": "watch"])
        #expect((array["variablesReference"]?.intValue ?? 0) > 0, "array: \(array)")

        // Hot code replace: change value() to return 2, rebuild, redefine.
        let changed = Self.source.replacingOccurrences(of: "return 1;", with: "return 2;")
        try changed.write(to: h.file, atomically: true, encoding: .utf8)
        try h.lsp.notify("textDocument/didChange", params: [
            "textDocument": ["uri": .string(h.file.absoluteString), "version": 2], "contentChanges": [["text": .string(changed)]],
        ])
        try h.lsp.notify("textDocument/didSave", params: ["textDocument": ["uri": .string(h.file.absoluteString)]])
        _ = try await h.lsp.request("java/buildWorkspace", params: false)
        let redefined = try await dap.request("redefineClasses")
        let classes = redefined["changedClasses"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(classes.contains("Main"), "redefineClasses: \(redefined)")

        _ = try await dap.request("setBreakpoints", arguments: ["source": ["path": .string(h.file.path)], "breakpoints": []])
        _ = try await dap.request("continue", arguments: ["threadId": .int(thread)])
        #expect(await h.log.wait(timeout: .seconds(30)) { output.text.contains("value=2 i=1") }, "output: \(output.text)")
        dap.terminate()
        debuggee.terminate()
        await h.shutdown()
    }

    /// Attach to a JVM that was started with a JDWP agent (suspended until we connect).
    @Test(.enabled(if: canRun), .timeLimit(.minutes(4)))
    func attachesToRunningJVM() async throws {
        let h = try await DebugHarness.start(source: Self.source)
        // Compile and start the program ourselves with a JDWP agent on a free port.
        let classes = h.dir.appendingPathComponent("classes")
        let javac = Process()
        javac.executableURL = h.jdk.javac
        javac.arguments = ["-g", "-d", classes.path, h.file.path]
        try javac.run()
        javac.waitUntilExit()
        #expect(javac.terminationStatus == 0)
        let jvm = PipedProcess()
        let output = OutputBuffer()
        jvm.onOutput = { output.append($0) }
        try jvm.start(arguments: [h.jdk.java.path, "-agentlib:jdwp=transport=dt_socket,server=y,suspend=y,address=127.0.0.1:0",
                                  "-cp", classes.path, "Main"],
                      environment: ProcessInfo.processInfo.environment, currentDirectory: h.dir)
        #expect(await h.log.wait(timeout: .seconds(20)) { output.text.contains("Listening for transport dt_socket at address:") })
        let portText = output.text.components(separatedBy: "address:").last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let port = try #require(Int(portText.prefix { $0.isNumber }), "jdwp output: \(output.text)")

        let events = EventLog()
        let dap = try await h.adapter(events: events)
        _ = try await dap.request("attach", arguments: [
            "hostName": "127.0.0.1", "port": .int(port), "projectName": .string(h.projectName), "timeout": 15000,
        ])
        #expect(await h.log.wait(timeout: .seconds(30)) { events.first("initialized") != nil })
        try await h.breakpoint(dap, line: 7)
        _ = try await dap.request("configurationDone")
        #expect(await h.log.wait(timeout: .seconds(30)) { events.first("stopped") != nil })
        let thread = try #require(events.first("stopped")?["threadId"]?.intValue)
        let frames = StackFrameInfo.parseAll(try await dap.request("stackTrace", arguments: ["threadId": .int(thread)]))
        #expect(frames.first?.line == 7)
        // Disconnect without terminating: the JVM carries on and finishes by itself.
        _ = try await dap.request("setBreakpoints", arguments: ["source": ["path": .string(h.file.path)], "breakpoints": []])
        _ = try? await dap.request("disconnect", arguments: ["terminateDebuggee": false])
        #expect(await h.log.wait(timeout: .seconds(30)) { output.text.contains("value=1 i=1") }, "output: \(output.text)")
        dap.terminate()
        jvm.terminate()
        await h.shutdown()
    }
}
