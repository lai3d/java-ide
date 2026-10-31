import Foundation
import Testing
@testable import JavaIDECore

private let examples = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Examples")

private func javaFiles(in root: URL) -> [URL] {
    let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
    return (enumerator?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "java" && !$0.path.contains("/target/") }
}

@Suite struct ProjectModuleTests {
    @Test func parsesMavenModules() {
        let pom = "<project><modules>\n<module>common</module>\n<!-- <module>old</module> -->\n<module> apps/web/ </module></modules></project>"
        #expect(ProjectModules.parseMavenModules(pom) == ["common", "apps/web"])
    }

    @Test func parsesGradleIncludes() {
        let settings = """
            rootProject.name = 'x'
            include 'api', ':services:web'
            // include 'old'
            include("tools")
            include(":a", ":b")
            """
        #expect(ProjectModules.parseGradleIncludes(settings) == [":api", ":services:web", ":tools", ":a", ":b"])
    }

    @Test func discoversExampleModulesAndTargets() {
        let root = examples.appendingPathComponent("spring-cloud-demo")
        let modules = ProjectModules.discover(root: root, buildSystem: .maven)
        #expect(modules.map(\.relativePath) == ["", "common", "greeting-service", "gateway"])
        let targets = RunTarget.discover(files: javaFiles(in: root), root: root, buildSystem: .maven, modules: modules)
        #expect(targets.map(\.mainClass) == ["com.example.gateway.GatewayApplication",
                                             "com.example.greeting.GreetingServiceApplication"])
        #expect(targets.allSatisfy { $0.isSpringBoot })
        #expect(targets[0].displayName == "GatewayApplication (gateway)")
        let file = root.appendingPathComponent("common/src/main/java/com/example/common/Greeting.java")
        #expect(ProjectModules.module(containing: file, in: modules, root: root)?.name == "common")
    }

    @Test func detectsGradleSpringBoot() {
        let root = examples.appendingPathComponent("spring-boot-demo")
        let modules = ProjectModules.discover(root: root, buildSystem: .gradle)
        #expect(modules.count == 1)
        let targets = RunTarget.discover(files: javaFiles(in: root), root: root, buildSystem: .gradle, modules: modules)
        #expect(targets.map(\.mainClass) == ["com.example.demo.DemoApplication"])
        #expect(targets.first?.isSpringBoot == true)
        // A plain Maven project is not Spring Boot.
        let maven = examples.appendingPathComponent("maven-demo")
        #expect(!SpringBoot.uses(module: ProjectModule(name: "maven-demo", relativePath: ""), root: maven, buildSystem: .maven))
    }
}

@Suite struct RunConfigurationTests {
    @Test func splitsArguments() {
        #expect(ArgumentSplitter.split(#"--a=1  "two words" 'it''s' x\ y """#) == ["--a=1", "two words", "its", "x y", ""])
        #expect(ArgumentSplitter.split("   ") == [])
    }

    @Test func buildsEnvironment() {
        let config = RunConfiguration(profiles: "dev, local", environment: "# comment\nFOO=bar=baz\n BAD\nEMPTY=\n")
        #expect(config.environmentVariables == ["FOO": "bar=baz", "EMPTY": "", "SPRING_PROFILES_ACTIVE": "dev,local"])
        #expect(RunConfiguration().isEmpty)
    }

    @Test func mavenSpringBootSubmoduleCommand() throws {
        let root = examples.appendingPathComponent("spring-cloud-demo")
        let target = RunTarget(mainClass: "com.example.gateway.GatewayApplication", file: root,
                               module: ProjectModule(name: "gateway", relativePath: "gateway"), isSpringBoot: true)
        let config = RunConfiguration(programArguments: "--server.port=9000", vmOptions: "-Xmx256m")
        let jdk = JDK(home: URL(fileURLWithPath: "/jdk"), version: "21")
        let cmd = try #require(RunCommand.run(target: target, configuration: config, buildSystem: .maven, root: root,
                                              jdk: jdk, sources: []))
        #expect(cmd.shell.contains("-pl gateway -am install -DskipTests && exec "))
        #expect(cmd.shell.contains("-f gateway/pom.xml org.springframework.boot:spring-boot-maven-plugin:run"))
        #expect(cmd.shell.contains("-Dspring-boot.run.main-class=com.example.gateway.GatewayApplication"))
        #expect(cmd.shell.contains("-Dspring-boot.run.arguments=--server.port=9000"))
        #expect(cmd.shell.contains("-Dspring-boot.run.jvmArguments=-Xmx256m"))
        let prebuilt = try #require(RunCommand.run(target: target, configuration: config, buildSystem: .maven, root: root,
                                                   jdk: jdk, sources: [], prebuilt: true))
        #expect(!prebuilt.shell.contains("install"))
    }

    @Test func gradleCommandsUseInitScript() throws {
        let root = examples.appendingPathComponent("spring-boot-demo")
        let jdk = JDK(home: URL(fileURLWithPath: "/jdk"), version: "21")
        let boot = RunTarget(mainClass: "com.example.demo.DemoApplication", file: root,
                             module: ProjectModule(name: "demo", relativePath: ""), isSpringBoot: true)
        let cmd = try #require(RunCommand.run(target: boot, configuration: RunConfiguration(programArguments: "--debug"),
                                              buildSystem: .gradle, root: root, jdk: jdk, sources: []))
        #expect(cmd.shell.contains(" :bootRun --args=--debug"))
        let script = try #require(cmd.shell.range(of: #"--init-script (\S+)"#, options: .regularExpression)
            .map { String(cmd.shell[$0].dropFirst("--init-script ".count)) })
        let text = try String(contentsOfFile: script, encoding: .utf8)
        #expect(text.contains("t.mainClass.set('com.example.demo.DemoApplication')"))
        let plain = RunTarget(mainClass: "a.Main", file: root,
                              module: ProjectModule(name: "api", relativePath: "api", gradlePath: ":api"), isSpringBoot: false)
        let plainCmd = try #require(RunCommand.run(target: plain, configuration: RunConfiguration(vmOptions: "-Da='x y'"),
                                                   buildSystem: .gradle, root: root, jdk: jdk, sources: []))
        #expect(plainCmd.shell.contains(" :api:javaideRun"))
        let plainScript = try String(contentsOfFile: plainCmd.shell.components(separatedBy: "--init-script ")[1]
            .components(separatedBy: " ")[0], encoding: .utf8)
        #expect(plainScript.contains("t.jvmArgs(['-Da=x y'])"))
    }
}

@Suite struct ConfigHighlighterTests {
    private func kinds(_ tokens: [Token], _ text: String) -> [(String, TokenKind)] {
        tokens.map { ((text as NSString).substring(with: $0.range), $0.kind) }
    }

    @Test func highlightsProperties() {
        let text = "# comment\nserver.port=8081\nspring.datasource.url = jdbc:h2:${DB:mem}\nflag: true\n"
        let result = kinds(ConfigHighlighter.tokenizeProperties(text), text)
        #expect(result.contains { $0 == ("# comment", .comment) })
        #expect(result.contains { $0 == ("server.port", .function) })
        #expect(result.contains { $0 == ("8081", .number) })
        #expect(result.contains { $0 == ("spring.datasource.url", .function) })
        #expect(result.contains { $0 == ("jdbc:h2:${DB:mem}", .string) })
        #expect(result.contains { $0 == ("${DB:mem}", .annotation) })
        #expect(result.contains { $0 == ("true", .literal) })
    }

    @Test func highlightsYAML() {
        let text = "spring:\n  application:\n    name: demo   # the name\n  profiles: [dev]\nlist:\n  - item\n  - key: \"a # b\"\n---\nport: 8080\n"
        let result = kinds(ConfigHighlighter.tokenizeYAML(text), text)
        #expect(result.contains { $0 == ("spring", .function) })
        #expect(result.contains { $0 == ("name", .function) })
        #expect(result.contains { $0 == ("demo", .string) })
        #expect(result.contains { $0 == ("# the name", .comment) })
        #expect(result.contains { $0 == ("key", .function) })
        #expect(result.contains { $0 == ("\"a # b\"", .string) })
        #expect(result.contains { $0 == ("---", .keyword) })
        #expect(result.contains { $0 == ("8080", .number) })
        #expect(SyntaxLanguage.forFile(URL(fileURLWithPath: "/a/application-dev.yml")) == .yaml)
    }
}
