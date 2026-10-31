import Foundation

/// A Maven module or Gradle subproject.
public struct ProjectModule: Sendable, Hashable, Codable {
    /// Display name (the folder name, or the Gradle project name).
    public let name: String
    /// Path relative to the project root, "" for the root project.
    public let relativePath: String
    /// Gradle project path (":services:api", ":" for the root); Maven uses `relativePath`.
    public let gradlePath: String

    public init(name: String, relativePath: String, gradlePath: String = ":") {
        self.name = name
        self.relativePath = relativePath
        self.gradlePath = gradlePath
    }

    public var isRoot: Bool { relativePath.isEmpty }

    public func directory(root: URL) -> URL {
        relativePath.isEmpty ? root : root.appendingPathComponent(relativePath)
    }
}

public enum ProjectModules {
    /// Every module of the project, root first. Plain projects have just the root.
    public static func discover(root: URL, buildSystem: BuildSystem) -> [ProjectModule] {
        let rootModule = ProjectModule(name: root.lastPathComponent, relativePath: "", gradlePath: ":")
        switch buildSystem {
        case .plain: return [rootModule]
        case .maven: return [rootModule] + mavenModules(root: root, relative: "", depth: 0)
        case .gradle: return [rootModule] + gradleModules(root: root)
        }
    }

    /// The deepest module containing `file`.
    public static func module(containing file: URL, in modules: [ProjectModule], root: URL) -> ProjectModule? {
        let path = file.standardizedFileURL.path
        return modules
            .filter { module in
                let dir = module.directory(root: root).standardizedFileURL.path
                return path == dir || path.hasPrefix(dir + "/")
            }
            .max { $0.relativePath.count < $1.relativePath.count }
    }

    static func mavenModules(root: URL, relative: String, depth: Int) -> [ProjectModule] {
        guard depth < 6 else { return [] }
        let dir = relative.isEmpty ? root : root.appendingPathComponent(relative)
        guard let pom = try? String(contentsOf: dir.appendingPathComponent("pom.xml"), encoding: .utf8) else { return [] }
        var result: [ProjectModule] = []
        for name in parseMavenModules(pom) {
            let child = relative.isEmpty ? name : relative + "/" + name
            let childDir = root.appendingPathComponent(child)
            guard FileManager.default.fileExists(atPath: childDir.appendingPathComponent("pom.xml").path) else { continue }
            result.append(ProjectModule(name: childDir.lastPathComponent, relativePath: child))
            result += mavenModules(root: root, relative: child, depth: depth + 1)
        }
        return result
    }

    /// `<module>` entries of a pom (comments stripped).
    public static func parseMavenModules(_ pom: String) -> [String] {
        let text = pom.replacingOccurrences(of: #"<!--[\s\S]*?-->"#, with: "", options: .regularExpression)
        let regex = try! NSRegularExpression(pattern: #"<module>\s*([^<\s]+)\s*</module>"#)
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range(at: 1)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
    }

    static func gradleModules(root: URL) -> [ProjectModule] {
        for name in ["settings.gradle", "settings.gradle.kts"] {
            guard let text = try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8) else { continue }
            return parseGradleIncludes(text).compactMap { path in
                let relative = path.split(separator: ":").joined(separator: "/")
                guard !relative.isEmpty else { return nil }
                let name = String(path.split(separator: ":").last ?? "")
                return ProjectModule(name: name, relativePath: relative, gradlePath: path)
            }
        }
        return []
    }

    /// Drops `/* */` blocks and whole-line `//` comments (keeping strings, which hold the plugin ids).
    static func withoutBuildScriptComments(_ text: String) -> String {
        text.replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)^\s*//.*$"#, with: "", options: .regularExpression)
    }

    /// Project paths from `include 'a', ':b:c'` / `include("a", "b")` lines, normalized to ":a".
    public static func parseGradleIncludes(_ settings: String) -> [String] {
        let text = withoutBuildScriptComments(settings)
        let lineRegex = try! NSRegularExpression(pattern: #"(?m)^\s*include\b\s*\(?([^\n)]*)"#)
        let quoted = try! NSRegularExpression(pattern: #"['"]([^'"]+)['"]"#)
        let ns = text as NSString
        var result: [String] = []
        for line in lineRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let args = ns.substring(with: line.range(at: 1)) as NSString
            for match in quoted.matches(in: args as String, range: NSRange(location: 0, length: args.length)) {
                var path = args.substring(with: match.range(at: 1))
                if !path.hasPrefix(":") { path = ":" + path }
                if !result.contains(path) { result.append(path) }
            }
        }
        return result
    }
}

/// Spring Boot detection.
public enum SpringBoot {
    /// Whether the module (or a parent build file up to the root) uses Spring Boot.
    public static func uses(module: ProjectModule, root: URL, buildSystem: BuildSystem) -> Bool {
        var dir = module.directory(root: root).standardizedFileURL
        let rootPath = root.standardizedFileURL.path
        while true {
            if buildFileMentionsSpringBoot(dir: dir, buildSystem: buildSystem) { return true }
            if dir.path == rootPath || dir.path.count <= rootPath.count { return false }
            dir.deleteLastPathComponent()
        }
    }

    static func buildFileMentionsSpringBoot(dir: URL, buildSystem: BuildSystem) -> Bool {
        let names: [String]
        switch buildSystem {
        case .maven: names = ["pom.xml"]
        case .gradle: names = ["build.gradle", "build.gradle.kts"]
        case .plain: return false
        }
        for name in names {
            guard let text = try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8) else { continue }
            let code = buildSystem == .maven
                ? text.replacingOccurrences(of: #"<!--[\s\S]*?-->"#, with: "", options: .regularExpression)
                : ProjectModules.withoutBuildScriptComments(text)
            let markers = buildSystem == .maven
                ? ["spring-boot-starter-parent", "spring-boot-maven-plugin", "spring-boot-dependencies", "spring-boot-starter"]
                : ["org.springframework.boot"]
            if markers.contains(where: code.contains) { return true }
        }
        return false
    }

    public static func isApplicationClass(_ source: String) -> Bool {
        JavaProject.stripComments(source).contains("@SpringBootApplication")
    }
}

/// Something the Run button can start: a class with a `main` method, in a module.
public struct RunTarget: Sendable, Hashable, Identifiable {
    public let mainClass: String
    public let file: URL
    public let module: ProjectModule
    public let isSpringBoot: Bool

    public init(mainClass: String, file: URL, module: ProjectModule, isSpringBoot: Bool) {
        self.mainClass = mainClass
        self.file = file
        self.module = module
        self.isSpringBoot = isSpringBoot
    }

    public var id: String { mainClass }

    public var simpleName: String { String(mainClass.split(separator: ".").last ?? Substring(mainClass)) }

    public var displayName: String { module.isRoot ? simpleName : "\(simpleName) (\(module.name))" }

    /// Finds the main classes among `files` (test sources skipped), Spring Boot applications first.
    public static func discover(files: [URL], root: URL, buildSystem: BuildSystem,
                                modules: [ProjectModule]) -> [RunTarget] {
        var springModules: [String: Bool] = [:]
        var targets: [RunTarget] = []
        for file in files where file.pathExtension == "java" && !file.path.contains("/src/test/") {
            guard let source = try? String(contentsOf: file, encoding: .utf8), source.contains("main"),
                  JavaProject.hasMainMethod(source), !JavaProject.isTestSource(file: file, source: source) else { continue }
            let module = ProjectModules.module(containing: file, in: modules, root: root) ?? modules[0]
            var spring = false
            if SpringBoot.isApplicationClass(source) {
                if springModules[module.relativePath] == nil {
                    springModules[module.relativePath] = SpringBoot.uses(module: module, root: root, buildSystem: buildSystem)
                }
                spring = springModules[module.relativePath] ?? false
            }
            targets.append(RunTarget(mainClass: JavaProject.qualifiedClassName(file: file, source: source),
                                     file: file, module: module, isSpringBoot: spring))
        }
        return targets.sorted {
            if $0.isSpringBoot != $1.isSpringBoot { return $0.isSpringBoot }
            if $0.module.relativePath != $1.module.relativePath { return $0.module.relativePath < $1.module.relativePath }
            return $0.mainClass < $1.mainClass
        }
    }
}

/// Per-target run settings: Spring profiles, arguments, JVM options and environment variables.
public struct RunConfiguration: Sendable, Hashable, Codable {
    public var profiles = ""
    public var programArguments = ""
    public var vmOptions = ""
    /// One `NAME=value` per line.
    public var environment = ""

    public init(profiles: String = "", programArguments: String = "", vmOptions: String = "", environment: String = "") {
        self.profiles = profiles
        self.programArguments = programArguments
        self.vmOptions = vmOptions
        self.environment = environment
    }

    public var isEmpty: Bool { self == RunConfiguration() }

    /// The environment variables to add, including `SPRING_PROFILES_ACTIVE` for the profiles.
    public var environmentVariables: [String: String] {
        var result: [String: String] = [:]
        for line in environment.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { continue }
            let name = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            result[name] = String(trimmed[trimmed.index(after: eq)...])
        }
        let profileList = profiles.split(whereSeparator: { $0 == "," || $0.isWhitespace }).joined(separator: ",")
        if !profileList.isEmpty { result["SPRING_PROFILES_ACTIVE"] = profileList }
        return result
    }

    public var programArgumentList: [String] { ArgumentSplitter.split(programArguments) }
    public var vmOptionList: [String] { ArgumentSplitter.split(vmOptions) }
}

/// Splits a command line the way a shell would (quotes and backslashes), without expansion.
public enum ArgumentSplitter {
    public static func split(_ line: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inArgument = false
        var quote: Character?
        var escaped = false
        for ch in line {
            if escaped {
                current.append(ch)
                escaped = false
            } else if ch == "\\" && quote != "'" {
                escaped = true
                inArgument = true
            } else if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
            } else if ch == "\"" || ch == "'" {
                quote = ch
                inArgument = true
            } else if ch.isWhitespace {
                if inArgument {
                    result.append(current)
                    current = ""
                    inArgument = false
                }
            } else {
                current.append(ch)
                inArgument = true
            }
        }
        if inArgument { result.append(current) }
        return result
    }
}
