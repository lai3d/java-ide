import Foundation
import Testing
@testable import JavaIDECore

@Suite struct SpringConfigTests {
    static let metadata = """
        {"properties": [
          {"name": "server.port", "type": "java.lang.Integer", "description": "Server HTTP port.", "defaultValue": 8080},
          {"name": "server.servlet.context-path", "type": "java.lang.String", "description": "Context path."},
          {"name": "server.ssl.enabled", "type": "java.lang.Boolean", "defaultValue": true},
          {"name": "logging.level", "type": "java.util.Map<java.lang.String,java.lang.String>", "description": "Log levels."},
          {"name": "spring.application.name", "type": "java.lang.String"},
          {"name": "server.old", "type": "java.lang.String", "deprecated": true, "deprecation": {"level": "warning"}},
          {"name": "server.gone", "type": "java.lang.String", "deprecation": {"level": "error"}}
        ],
        "hints": [{"name": "logging.level.values", "values": [{"value": "info"}, {"value": "debug"}]}]}
        """

    static var index: SpringConfigIndex {
        var index = SpringConfigIndex()
        index.merge(json: Data(metadata.utf8))
        return index
    }

    private func labels(_ text: String, _ kind: SpringConfigEditing.FileKind, at marker: String = "|") -> [String] {
        let offset = (text as NSString).range(of: marker).location
        let clean = text.replacingOccurrences(of: marker, with: "")
        return SpringConfigEditing.completions(index: Self.index, text: clean, offset: offset, kind: kind).map(\.label)
    }

    @Test func parsesMetadata() {
        let index = Self.index
        #expect(index.properties["server.port"]?.defaultValue == "8080")
        #expect(index.properties["server.ssl.enabled"]?.defaultValue == "true")
        #expect(index.properties["server.gone"] == nil)
        #expect(index.properties["server.old"]?.deprecated == true)
        #expect(index.lookup("logging.level.com.example")?.name == "logging.level")
        #expect(index.lookup("server.servlet.contextPath")?.name == "server.servlet.context-path")
        #expect(index.values(for: "logging.level.org.springframework").map(\.value) == ["info", "debug"])
        #expect(index.values(for: "server.ssl.enabled").map(\.value) == ["true", "false"])
        #expect(index.properties["logging.level"]?.shortType == "Map<String,String>")
    }

    @Test func completesPropertiesKeysAndValues() {
        let keys = SpringConfigEditing.completions(index: Self.index, text: "server.po", offset: 9, kind: .properties)
        #expect(keys.first?.label == "server.port")
        #expect(keys.first?.insertText == "server.port=")
        #expect(labels("server.ssl.enabled=|", .properties) == ["true", "false"])
        #expect(labels("# server|", .properties).isEmpty)
        #expect(labels("server.|", .properties).last == "server.old")
    }

    @Test func completesNestedYAML() {
        let yaml = "spring:\n  application:\n    name: x\nserver:\n  ss|\n"
        #expect(labels(yaml, .yaml) == ["ssl"])
        let items = SpringConfigEditing.completions(index: Self.index, text: "server:\n  ss", offset: 12, kind: .yaml)
        #expect(items.first?.insertText == "ssl:\n    ")
        #expect(labels("server:\n  ssl:\n    |", .yaml) == ["enabled"])
        #expect(labels("server:\n  servlet.c|", .yaml) == ["servlet.context-path"])
        #expect(labels("serv|", .yaml) == ["server"])
        #expect(labels("server:\n  ssl:\n    enabled: |", .yaml) == ["true", "false"])
        #expect(labels("logging:\n  level:\n    com.example: |", .yaml) == ["info", "debug"])
        // Leaves insert "key: "; maps open a block.
        let leaf = SpringConfigEditing.completions(index: Self.index, text: "server:\n  po", offset: 12, kind: .yaml)
        #expect(leaf.first?.insertText == "port: ")
    }

    @Test func hoversKeys() {
        let yaml = "server:\n  port: 8081\n"
        #expect(SpringConfigEditing.hover(index: Self.index, text: yaml, offset: 12, kind: .yaml)?.contains("Server HTTP port.") == true)
        #expect(SpringConfigEditing.hover(index: Self.index, text: yaml, offset: 2, kind: .yaml)?.contains("properties") == true)
        let props = "logging.level.org.springframework=DEBUG"
        #expect(SpringConfigEditing.hover(index: Self.index, text: props, offset: 5, kind: .properties)?.contains("Log levels.") == true)
        #expect(SpringConfigEditing.fileKind(URL(fileURLWithPath: "/r/application-dev.yml")) == .yaml)
        #expect(SpringConfigEditing.fileKind(URL(fileURLWithPath: "/r/messages.properties")) == nil)
    }

    static let autoconfigureJar = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".m2/repository/org/springframework/boot/spring-boot-autoconfigure/3.5.16/spring-boot-autoconfigure-3.5.16.jar")

    /// Needs Spring Boot in the local Maven repository (run the Spring examples once); skipped otherwise, e.g. on CI.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: SpringConfigTests.autoconfigureJar.path)))
    func readsMetadataFromRealJar() throws {
        let jar = Self.autoconfigureJar
        let cache = MetadataCache()
        let index = SpringConfigIndex.load(classpath: [jar.path, "/nonexistent.jar"], cache: cache)
        #expect(index.properties["server.port"]?.type == "java.lang.Integer")
        #expect(index.names.count > 1000)
    }
}

/// jdtls gives the module class path for a resource file; its jars carry the configuration metadata.
@Suite(.enabled(if: hasJdtls && ProcessInfo.processInfo.environment["JAVAIDE_SPRING_E2E"] == "1"))
struct SpringConfigClasspathTests {
    @Test(.timeLimit(.minutes(5)))
    func metadataFromJdtlsClasspath() async throws {
        let tmp = URL(fileURLWithPath: String(cString: realpath(FileManager.default.temporaryDirectory.path, nil)))
        let dir = tmp.appendingPathComponent("javaide-springcfg-\(UUID().uuidString)")
        let example = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Examples/spring-cloud-demo")
        try FileManager.default.copyItem(at: example, to: dir)
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: JavaProject.cacheDirectory(for: dir))
        }
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
            "capabilities": ["workspace": ["configuration": true, "workspaceFolders": true]],
        ])
        try client.notify("initialized", params: [:])
        #expect(await log.wait(timeout: .seconds(240)) { log.isReady })

        let gatewayConfig = dir.appendingPathComponent("gateway/src/main/resources/application.yml")
        let result = try await client.request("workspace/executeCommand", params: [
            "command": "java.project.getClasspaths",
            "arguments": [.string(gatewayConfig.absoluteString), .string(#"{"scope":"runtime"}"#)],
        ])
        let classpath = result["classpaths"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(classpath.contains { $0.contains("spring-cloud-gateway") }, "\(classpath)")
        let index = SpringConfigIndex.load(classpath: classpath)
        #expect(index.properties["server.port"] != nil)
        #expect(index.names.contains { $0.hasPrefix("spring.cloud.gateway.") })
        await client.shutdown()
    }
}

@Suite struct SpringConfigPrefixTests {
    @Test func replacesWholeDottedKey() {
        let text = "server:\n  servlet.co" as NSString
        #expect(SpringConfigEditing.prefixStart(in: text, before: text.length) == 10)
        let props = "spring.datasource.url=jdbc" as NSString
        #expect(SpringConfigEditing.prefixStart(in: props, before: props.length) == 22)
        #expect(SpringConfigEditing.wordRange(in: props, at: 3) == NSRange(location: 0, length: 21))
    }
}
