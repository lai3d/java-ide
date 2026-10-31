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

    /// Runs `mainClass`. Maven uses exec:java (project dependencies on the class path); Gradle uses
    /// `run` with the application plugin, else compiles and runs the classes; plain projects are
    /// compiled with javac into the cache folder.
    public static func run(mainClass: String, file: URL, buildSystem: BuildSystem, root: URL, jdk: JDK,
                           sources: [URL]) -> RunCommand? {
        switch buildSystem {
        case .maven:
            guard let mvn = buildSystem.executable(root: root) else { return nil }
            let args = ["-q", "-B", "-ntp", "compile", "exec:java", "-Dexec.mainClass=\(mainClass)",
                        "-Dexec.cleanupDaemonThreads=false"]
            return RunCommand(shell: "exec " + quote(mvn.path, args),
                              display: "\(mvn.lastPathComponent) compile exec:java -Dexec.mainClass=\(mainClass)")
        case .gradle:
            guard let gradle = buildSystem.executable(root: root) else { return nil }
            if usesApplicationPlugin(root: root) {
                return RunCommand(shell: "exec " + quote(gradle.path, ["-q", "--console=plain", "run"]),
                                  display: "\(gradle.lastPathComponent) run")
            }
            let classPath = ["build/classes/java/main", "build/resources/main"].joined(separator: ":")
            let shell = quote(gradle.path, ["-q", "--console=plain", "classes"])
                + " && exec " + quote(jdk.java.path, ["-cp", classPath, mainClass])
            return RunCommand(shell: shell, display: "\(gradle.lastPathComponent) classes && java \(mainClass)")
        case .plain:
            let out = JavaProject.plainOutputDirectory(root: root)
            guard let argFile = writeSourceList(sources: sources, root: root) else { return nil }
            let shell = compileCommand(jdk: jdk, out: out, argFile: argFile, lint: false)
                + " && exec " + quote(jdk.java.path, ["-cp", out.path, mainClass])
            return RunCommand(shell: shell, display: "javac -d <cache> *.java && java \(mainClass)")
        }
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
