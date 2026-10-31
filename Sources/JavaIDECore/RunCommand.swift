import Foundation

/// A shell command for running, testing or building a project, plus what to show the user.
/// The last tool is `exec`'d so the IDE's SIGINT (Stop) reaches it directly.
public struct RunCommand: Sendable, Hashable {
    public let shell: String
    public let display: String

    public init(shell: String, display: String) {
        self.shell = shell
        self.display = display
    }

    /// Runs `mainClass` (in the root project). See `run(target:...)`.
    public static func run(mainClass: String, file: URL, buildSystem: BuildSystem, root: URL, jdk: JDK,
                           sources: [URL]) -> RunCommand? {
        let target = RunTarget(mainClass: mainClass, file: file,
                               module: ProjectModule(name: root.lastPathComponent, relativePath: ""), isSpringBoot: false)
        return run(target: target, configuration: RunConfiguration(), buildSystem: buildSystem, root: root, jdk: jdk,
                   sources: sources)
    }

    /// Runs a target with its run configuration.
    /// - Maven: Spring Boot apps use `spring-boot:run`, others `exec:java`. A submodule is first installed
    ///   with its sibling dependencies (`-pl <module> -am install`) unless `prebuilt` (Run All did it).
    /// - Gradle: `bootRun` for Spring Boot, `run` with the application plugin, else a `javaideRun` JavaExec
    ///   task (main runtime class path) added by an init script, which also sets the main class and JVM options.
    /// - Plain: javac into the cache folder, then java.
    /// Spring profiles and environment variables are passed through the environment (`RunConfiguration`).
    public static func run(target: RunTarget, configuration: RunConfiguration, buildSystem: BuildSystem, root: URL,
                           jdk: JDK, sources: [URL], prebuilt: Bool = false) -> RunCommand? {
        let mainClass = target.mainClass
        let args = configuration.programArgumentList
        let vmOptions = configuration.vmOptionList
        switch buildSystem {
        case .maven:
            guard let mvn = buildSystem.executable(root: root) else { return nil }
            var shell = ""
            var display = ""
            var pomArgs: [String] = []
            if !target.module.isRoot {
                pomArgs = ["-f", target.module.relativePath + "/pom.xml"]
                if !prebuilt {
                    shell = quote(mvn.path, ["-q", "-B", "-ntp", "-pl", target.module.relativePath, "-am", "install",
                                             "-DskipTests"]) + " && "
                    display = "\(mvn.lastPathComponent) -pl \(target.module.relativePath) -am install && "
                }
            }
            var goalArgs: [String]
            if target.isSpringBoot {
                goalArgs = ["org.springframework.boot:spring-boot-maven-plugin:run",
                            "-Dspring-boot.run.main-class=\(mainClass)"]
                if !args.isEmpty { goalArgs.append("-Dspring-boot.run.arguments=" + configuration.programArguments) }
                if !vmOptions.isEmpty { goalArgs.append("-Dspring-boot.run.jvmArguments=" + configuration.vmOptions) }
                display += "\(mvn.lastPathComponent) \(pomArgs.joined(separator: " ")) spring-boot:run"
            } else {
                goalArgs = ["compile", "exec:java", "-Dexec.mainClass=\(mainClass)", "-Dexec.cleanupDaemonThreads=false"]
                if !args.isEmpty { goalArgs.append("-Dexec.args=" + configuration.programArguments) }
                display += "\(mvn.lastPathComponent) \(pomArgs.joined(separator: " ")) compile exec:java -Dexec.mainClass=\(mainClass)"
            }
            // exec:java runs inside Maven's JVM, so its JVM options go to MAVEN_OPTS.
            if !target.isSpringBoot, !vmOptions.isEmpty {
                shell += "MAVEN_OPTS=\"$MAVEN_OPTS \"" + shellQuote(configuration.vmOptions) + " "
            }
            shell += "exec " + quote(mvn.path, ["-q", "-B", "-ntp"] + pomArgs + goalArgs)
            return RunCommand(shell: shell, display: display.replacingOccurrences(of: "  ", with: " "))
        case .gradle:
            guard let gradle = buildSystem.executable(root: root) else { return nil }
            let task: String
            if target.isSpringBoot {
                task = "bootRun"
            } else if usesApplicationPlugin(root: target.module.directory(root: root)) {
                task = "run"
            } else {
                task = "javaideRun"
            }
            guard let initScript = writeGradleInitScript(root: root, mainClass: mainClass, vmOptions: vmOptions) else { return nil }
            let path = target.module.gradlePath == ":" ? ":" + task : target.module.gradlePath + ":" + task
            var gradleArgs = ["-q", "--console=plain", "--init-script", initScript.path, path]
            if !args.isEmpty { gradleArgs.append("--args=" + configuration.programArguments) }
            return RunCommand(shell: "exec " + quote(gradle.path, gradleArgs),
                              display: "\(gradle.lastPathComponent) \(path)" + (args.isEmpty ? "" : " --args=…"))
        case .plain:
            let out = JavaProject.plainOutputDirectory(root: root)
            guard let argFile = writeSourceList(sources: sources, root: root) else { return nil }
            let shell = compileCommand(jdk: jdk, out: out, argFile: argFile, lint: false)
                + " && exec " + quote(jdk.java.path, vmOptions + ["-cp", out.path, mainClass] + args)
            return RunCommand(shell: shell, display: "javac -d <cache> *.java && java \(mainClass)")
        }
    }

    /// Builds every module once before Run All starts the apps side by side (so they don't race on
    /// `target/` or the local repository): Maven installs the reactor, Gradle compiles all classes.
    public static func prebuildAll(buildSystem: BuildSystem, root: URL) -> RunCommand? {
        guard let tool = buildSystem.executable(root: root) else { return nil }
        switch buildSystem {
        case .maven:
            return RunCommand(shell: "exec " + quote(tool.path, ["-q", "-B", "-ntp", "install", "-DskipTests"]),
                              display: "\(tool.lastPathComponent) install -DskipTests")
        case .gradle:
            return RunCommand(shell: "exec " + quote(tool.path, ["-q", "--console=plain", "classes"]),
                              display: "\(tool.lastPathComponent) classes")
        case .plain:
            return nil
        }
    }

    /// Gradle init script: sets the main class and JVM options of `bootRun` / `run`, and adds `javaideRun`
    /// for projects without either.
    static func writeGradleInitScript(root: URL, mainClass: String, vmOptions: [String]) -> URL? {
        func groovy(_ s: String) -> String {
            "'" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
        }
        let jvmArgs = "[" + vmOptions.map(groovy).joined(separator: ", ") + "]"
        let script = """
            // Generated by JavaIDE for Run.
            allprojects { p ->
                p.tasks.withType(JavaExec).configureEach { t ->
                    if (t.name == 'bootRun' || t.name == 'run' || t.name == 'javaideRun') {
                        t.mainClass.set(\(groovy(mainClass)))
                        t.jvmArgs(\(jvmArgs))
                    }
                }
                p.plugins.withId('java') {
                    if (p.tasks.findByName('javaideRun') == null) {
                        p.tasks.register('javaideRun', JavaExec) { t ->
                            t.group = 'application'
                            t.classpath = p.sourceSets.main.runtimeClasspath
                            t.standardInput = System.in
                        }
                    }
                }
            }

            """
        let folder = JavaProject.cacheDirectory(for: root)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("javaide-run-\(fnv(mainClass)).gradle")
        do {
            try script.write(to: file, atomically: true, encoding: .utf8)
            return file
        } catch {
            return nil
        }
    }

    private static func fnv(_ s: String) -> String {
        var hash: UInt32 = 2166136261
        for byte in s.utf8 { hash = (hash ^ UInt32(byte)) &* 16777619 }
        return String(hash, radix: 16)
    }

    /// Runs the test suite, or one test class.
    public static func test(className: String?, buildSystem: BuildSystem, root: URL) -> RunCommand? {
        guard let tool = buildSystem.executable(root: root) else { return nil }
        switch buildSystem {
        case .maven:
            var args = ["-B", "-ntp", "test"]
            if let className { args += ["-Dtest=\(className)", "-Dsurefire.failIfNoSpecifiedTests=false"] }
            return RunCommand(shell: "exec " + quote(tool.path, args),
                              display: "\(tool.lastPathComponent) test" + (className.map { " -Dtest=\($0)" } ?? ""))
        case .gradle:
            var args = ["--console=plain", "test"]
            if let className { args += ["--tests", className] }
            return RunCommand(shell: "exec " + quote(tool.path, args),
                              display: "\(tool.lastPathComponent) test" + (className.map { " --tests \($0)" } ?? ""))
        case .plain:
            return nil
        }
    }

    /// Compiles main and test sources, reporting errors and (for javac) lint warnings.
    public static func build(buildSystem: BuildSystem, root: URL, jdk: JDK, sources: [URL]) -> RunCommand? {
        switch buildSystem {
        case .maven:
            guard let mvn = buildSystem.executable(root: root) else { return nil }
            return RunCommand(shell: "exec " + quote(mvn.path, ["-B", "-ntp", "test-compile"]),
                              display: "\(mvn.lastPathComponent) test-compile")
        case .gradle:
            guard let gradle = buildSystem.executable(root: root) else { return nil }
            return RunCommand(shell: "exec " + quote(gradle.path, ["--console=plain", "classes", "testClasses"]),
                              display: "\(gradle.lastPathComponent) classes testClasses")
        case .plain:
            let out = JavaProject.plainOutputDirectory(root: root)
            guard let argFile = writeSourceList(sources: sources, root: root) else { return nil }
            return RunCommand(shell: compileCommand(jdk: jdk, out: out, argFile: argFile, lint: true)
                                + " && echo 'Build succeeded.'",
                              display: "javac -Xlint:all -d <cache> \(sources.count) file\(sources.count == 1 ? "" : "s")")
        }
    }

    // MARK: - Helpers

    static func compileCommand(jdk: JDK, out: URL, argFile: URL, lint: Bool) -> String {
        var args = ["-d", out.path, "-encoding", "UTF-8", "-g"]
        if lint { args += ["-Xlint:all"] }
        args.append("@" + argFile.path)
        return quote("/bin/rm", ["-rf", out.path]) + " && " + quote("/bin/mkdir", ["-p", out.path])
            + " && " + quote(jdk.javac.path, args)
    }

    /// Writes the javac argument file listing the project's non-test sources.
    static func writeSourceList(sources: [URL], root: URL) -> URL? {
        let main = sources.filter { url in
            guard !url.path.contains("/src/test/") else { return false }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return true }
            return !text.contains("import org.junit") && !text.contains("import static org.junit")
        }
        guard !main.isEmpty else { return nil }
        let folder = JavaProject.cacheDirectory(for: root)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("sources.txt")
        // javac @file syntax: one argument per line, quoted to allow spaces.
        let body = main.map { "\"" + $0.path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\"" }.joined(separator: "\n") + "\n"
        do {
            try body.write(to: file, atomically: true, encoding: .utf8)
            return file
        } catch {
            return nil
        }
    }

    static func usesApplicationPlugin(root: URL) -> Bool {
        for name in ["build.gradle", "build.gradle.kts"] {
            if let text = try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8),
               text.range(of: #"(\bapplication\b|id\s*\(?\s*['"]application['"])"#, options: .regularExpression) != nil {
                return true
            }
        }
        return false
    }

    public static func quote(_ executable: String, _ arguments: [String]) -> String {
        ([executable] + arguments).map(shellQuote).joined(separator: " ")
    }

    public static func shellQuote(_ s: String) -> String {
        if !s.isEmpty, s.allSatisfy({ $0.isLetter || $0.isNumber || "-_./=:@+,".contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
