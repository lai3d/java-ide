import Foundation
import Testing
@testable import JavaIDECore

let hasJdtls = LanguageServerSpec.locate() != nil

/// Collects server notifications so tests can wait for diagnostics.
final class NotificationLog: @unchecked Sendable {
    private let lock = NSLock()
    private var diagnostics: [String: [Diagnostic]] = [:]
    private var statuses: [String] = []

    func record(_ method: String, _ params: JSONValue) {
        lock.withLock {
            if method == "textDocument/publishDiagnostics", let published = Diagnostic.parsePublish(params) {
                diagnostics[published.uri] = published.diagnostics
            } else if method == "language/status", let type = params["type"]?.stringValue {
                statuses.append(type)
            }
            if ProcessInfo.processInfo.environment["JDTLS_TRACE"] != nil { print("<<", method, params["uri"]?.stringValue ?? "", params["diagnostics"]?.arrayValue?.count ?? -1) }
        }
    }

    func diagnostics(for uri: String) -> [Diagnostic]? { lock.withLock { diagnostics[uri] } }
    var allURIs: [String] { lock.withLock { Array(diagnostics.keys) } }
    var isReady: Bool { lock.withLock { statuses.contains("ServiceReady") } }

    func wait(timeout: Duration = .seconds(90), until condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return condition()
    }
}

@Suite(.serialized) struct JdtlsEndToEndTests {
    static let main = """
        public class Main {
            public static void main(String[] args) {
                ArrayList<String> names = new ArrayList<>();
                int count = Helper.twice(3);
                System.out.println(count + names.size());
            }
        }

        """

    static let helper = """
        public class Helper {
          static int twice( int x ){ return x*2; }
        }

        """

    @Test(.enabled(if: hasJdtls), .timeLimit(.minutes(4)))
    func languageFeatures() async throws {
        // jdtls reports canonical paths (/private/var/…), so resolve the temp dir's symlinks up front.
        // (Foundation's resolvingSymlinksInPath strips /private, so use realpath.)
        let tmp = URL(fileURLWithPath: String(cString: realpath(FileManager.default.temporaryDirectory.path, nil)))
        let dir = tmp
            .appendingPathComponent("javaide-jdtls-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: JavaProject.cacheDirectory(for: dir))
        }
        let mainURL = dir.appendingPathComponent("Main.java")
        let helperURL = dir.appendingPathComponent("Helper.java")
        try Self.main.write(to: mainURL, atomically: true, encoding: .utf8)
        try Self.helper.write(to: helperURL, atomically: true, encoding: .utf8)
        let mainURI = mainURL.absoluteString, helperURI = helperURL.absoluteString
        if ProcessInfo.processInfo.environment["JDTLS_TRACE"] != nil { print("main:", mainURI) }

        let jdk = JDK.locate()
        let log = NotificationLog()
        let client = LSPClient()
        client.onNotification = { method, params in log.record(method, params) }
        client.configurationProvider = { items in LanguageServerSpec.configuration(items: items, jdk: jdk) }
        try client.start(executable: try #require(LanguageServerSpec.locate()),
                         arguments: LanguageServerSpec.arguments(root: dir),
                         environment: LanguageServerSpec.environment(base: ProcessInfo.processInfo.environment),
                         currentDirectory: dir)
        _ = try await client.request("initialize", params: [
            "processId": .int(Int(ProcessInfo.processInfo.processIdentifier)),
            "rootUri": .string(dir.absoluteString),
            "workspaceFolders": [["uri": .string(dir.absoluteString), "name": "demo"]],
            "initializationOptions": LanguageServerSpec.initializationOptions(jdk: jdk),
            "capabilities": [
                "workspace": ["configuration": true, "workspaceFolders": true, "applyEdit": true,
                              "workspaceEdit": ["documentChanges": true]],
                "textDocument": [
                    "documentSymbol": ["hierarchicalDocumentSymbolSupport": true],
                    "rename": ["prepareSupport": true],
                    "codeAction": ["codeActionLiteralSupport": ["codeActionKind": ["valueSet": ["quickfix", "source", "source.organizeImports"]]]],
                    "signatureHelp": ["signatureInformation": ["parameterInformation": ["labelOffsetSupport": true]]],
                ],
            ],
        ])
        try client.notify("initialized", params: [:])
        for (uri, text) in [(mainURI, Self.main), (helperURI, Self.helper)] {
            try client.notify("textDocument/didOpen", params: [
                "textDocument": ["uri": .string(uri), "languageId": "java", "version": 1, "text": .string(text)],
            ])
        }
        func at(_ uri: String, _ line: Int, _ character: Int) -> JSONValue {
            ["textDocument": ["uri": .string(uri)], "position": TextPosition(line: line, character: character).json]
        }

        // Diagnostics: ArrayList isn't imported.
        let gotDiagnostics = await log.wait { log.diagnostics(for: mainURI)?.contains { $0.message.contains("ArrayList") } == true }
        #expect(gotDiagnostics, "diagnostics for \(log.allURIs): \(String(describing: log.diagnostics(for: mainURI)))")
        let arrayListError = try #require(log.diagnostics(for: mainURI)?.first { $0.message.contains("ArrayList") })

        // Quick fix offers the import.
        let actionsResult = try await client.request("textDocument/codeAction", params: [
            "textDocument": ["uri": .string(mainURI)],
            "range": ["start": arrayListError.start.json, "end": arrayListError.end.json],
            "context": ["diagnostics": [try #require(arrayListError.raw)]],
        ])
        let actions = CodeAction.parseList(actionsResult)
        #expect(actions.contains { $0.title.contains("Import 'ArrayList'") }, "actions: \(actions.map(\.title))")

        // Organize imports adds java.util.ArrayList.
        let organize = CodeAction.parseList(try await client.request("textDocument/codeAction", params: [
            "textDocument": ["uri": .string(mainURI)],
            "range": ["start": TextPosition(line: 0, character: 0).json, "end": TextPosition(line: 7, character: 0).json],
            "context": ["diagnostics": [], "only": ["source.organizeImports"]],
        ]))
        let organizeEdit = try #require(organize.first?.edit, "organize: \(organize.map(\.title))")
        let organized = TextEdit.apply(try #require(WorkspaceEdit.parse(organizeEdit)[mainURI]), to: Self.main)
        #expect(organized.contains("import java.util.ArrayList;"), "organized: \(organized)")

        // Hover and signature help.
        let hover = HoverContent.parse(try await client.request("textDocument/hover", params: at(mainURI, 4, 22)))
        #expect(hover?.contains("println") == true, "hover: \(String(describing: hover))")
        let help = SignatureInfo.parse(try await client.request("textDocument/signatureHelp", params: at(mainURI, 3, 33)))
        #expect(help?.label.contains("twice") == true, "signature: \(String(describing: help))")

        // Definition: into the other file, and into the JDK (jdt:// + classFileContents).
        let helperDef = Location.parseAll(try await client.request("textDocument/definition", params: at(mainURI, 3, 29)))
        #expect(helperDef.first?.uri.hasSuffix("/Helper.java") == true, "definition: \(helperDef)")
        let stringDef = Location.parseAll(try await client.request("textDocument/definition", params: at(mainURI, 1, 30)))
        let jdtURI = try #require(stringDef.first?.uri, "String definition")
        #expect(ClassFileURI.isClassFile(jdtURI), "uri: \(jdtURI)")
        let contents = try await client.request("java/classFileContents", params: ["uri": .string(jdtURI)])
        #expect(contents.stringValue?.contains("class String") == true)

        // Outline.
        let symbols = OutlineSymbol.parse(try await client.request("textDocument/documentSymbol",
                                                                    params: ["textDocument": ["uri": .string(mainURI)]]))
        #expect(symbols.first?.name == "Main")
        #expect(symbols.first?.children?.contains { $0.name.hasPrefix("main") } == true)

        // Rename across files.
        var renameParams = at(helperURI, 1, 16)
        if case .object(var o) = renameParams { o["newName"] = "doubled"; renameParams = .object(o) }
        let renameEdit = WorkspaceEdit.parse(try await client.request("textDocument/rename", params: renameParams))
        #expect(TextEdit.apply(try #require(renameEdit[mainURI]), to: Self.main).contains("Helper.doubled(3)"))
        #expect(TextEdit.apply(try #require(renameEdit[helperURI]), to: Self.helper).contains("static int doubled("))

        // Formatting.
        let formatEdits = try await client.request("textDocument/formatting", params: [
            "textDocument": ["uri": .string(helperURI)], "options": ["tabSize": 4, "insertSpaces": true],
        ]).arrayValue?.compactMap(TextEdit.parse) ?? []
        let formatted = TextEdit.apply(formatEdits, to: Self.helper)
        #expect(formatted.contains("    static int twice(int x) {"), "formatted: \(formatted)")

        await client.shutdown()
    }
}
