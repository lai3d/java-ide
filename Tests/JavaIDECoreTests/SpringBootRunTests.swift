import Foundation
import Testing
@testable import JavaIDECore

/// Runs the Spring Boot examples with the commands Run generates and talks to them over HTTP.
/// Slow (downloads dependencies the first time), so opt-in: `JAVAIDE_SPRING_E2E=1 swift test --filter SpringBootRun`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["JAVAIDE_SPRING_E2E"] == "1"), .serialized)
struct SpringBootRunTests {
    private static let examples = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Examples")

    /// A started command; output is collected for failure messages.
    final class Running: @unchecked Sendable {
        let process = Process()
        private let lock = NSLock()
        private var text = ""
        var output: String { lock.withLock { text } }

        init(_ command: RunCommand, root: URL, environment: [String: String]) throws {
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command.shell]
            process.currentDirectoryURL = root
            process.environment = environment
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = Pipe()
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { handle.readabilityHandler = nil; return }
                self?.lock.withLock { self?.text += String(decoding: data, as: UTF8.self) }
            }
            try process.run()
        }

        /// Stops it the way the Stop button does (SIGINT) and waits for it to exit.
        func stop() async -> Bool {
            guard process.isRunning else { return true }
            process.interrupt()
            for _ in 0..<150 {
                if !process.isRunning { return true }
                try? await Task.sleep(for: .milliseconds(100))
            }
            process.terminate()
            return false
        }
    }

    private static func get(_ url: String, until deadline: Duration, running: Running) async -> String? {
        let clock = ContinuousClock()
        let end = clock.now + deadline
        while clock.now < end, running.process.isRunning {
            if let (data, response) = try? await URLSession.shared.data(from: URL(string: url)!),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                return String(decoding: data, as: UTF8.self)
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return nil
    }

    private static func environment(jdk: JDK, extra: [String: String]) -> [String: String] {
        var env = ToolLocator.environment(jdk: jdk)
        env["MAVEN_OPTS"] = "-Djansi.passthrough=false"
        env.merge(extra) { $1 }
        return env
    }

    @Test func gradleBootRunWithProfileAndArguments() async throws {
        let jdk = try #require(JDK.locate())
        let root = Self.examples.appendingPathComponent("spring-boot-demo")
        let modules = ProjectModules.discover(root: root, buildSystem: .gradle)
        let files = [root.appendingPathComponent("src/main/java/com/example/demo/DemoApplication.java")]
        let target = try #require(RunTarget.discover(files: files, root: root, buildSystem: .gradle, modules: modules).first)
        let config = RunConfiguration(profiles: "dev", programArguments: "--demo.greeting=Yo")
        let command = try #require(RunCommand.run(target: target, configuration: config, buildSystem: .gradle, root: root,
                                                  jdk: jdk, sources: files))
        let running = try Running(command, root: root, environment: Self.environment(jdk: jdk, extra: config.environmentVariables))
        // The dev profile moves the port to 18071; the argument overrides the greeting.
        let body = await Self.get("http://localhost:18071/hello?name=IDE", until: .seconds(300), running: running)
        let stopped = await running.stop()
        #expect(body == "Yo, IDE!", "output:\n\(running.output.suffix(3000))")
        #expect(stopped, "bootRun did not stop on SIGINT")
    }

    @Test func mavenMultiModuleServicesThroughGateway() async throws {
        let jdk = try #require(JDK.locate())
        let root = Self.examples.appendingPathComponent("spring-cloud-demo")
        let modules = ProjectModules.discover(root: root, buildSystem: .maven)
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        let files = (enumerator?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "java" && !$0.path.contains("/target/") }
        let targets = RunTarget.discover(files: files, root: root, buildSystem: .maven, modules: modules)
        let service = try #require(targets.first { $0.module.name == "greeting-service" })
        let gateway = try #require(targets.first { $0.module.name == "gateway" })

        // The service the way Run starts a submodule (install its dependencies, then spring-boot:run)…
        let serviceCommand = try #require(RunCommand.run(target: service, configuration: RunConfiguration(),
                                                         buildSystem: .maven, root: root, jdk: jdk, sources: files))
        let serviceRun = try Running(serviceCommand, root: root, environment: Self.environment(jdk: jdk, extra: [:]))
        let direct = await Self.get("http://localhost:18081/greetings/Ann", until: .seconds(400), running: serviceRun)
        #expect(direct?.contains("Hello, Ann!") == true, "service output:\n\(serviceRun.output.suffix(3000))")

        // …and the gateway the way Run All does (already built).
        let gatewayCommand = try #require(RunCommand.run(target: gateway, configuration: RunConfiguration(),
                                                         buildSystem: .maven, root: root, jdk: jdk, sources: files,
                                                         prebuilt: true))
        let gatewayRun = try Running(gatewayCommand, root: root, environment: Self.environment(jdk: jdk, extra: [:]))
        let routed = await Self.get("http://localhost:18080/api/greetings/Bob", until: .seconds(400), running: gatewayRun)
        let stoppedGateway = await gatewayRun.stop()
        let stoppedService = await serviceRun.stop()
        #expect(routed?.contains("\"message\":\"Hello, Bob!\"") == true, "gateway output:\n\(gatewayRun.output.suffix(3000))")
        #expect(routed?.contains("greeting-service") == true)
        #expect(stoppedGateway && stoppedService, "spring-boot:run did not stop on SIGINT")
    }
}
