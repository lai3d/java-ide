import Foundation

/// Finds command-line tools. GUI apps launched from Finder get a minimal PATH, so we
/// also look in the usual Homebrew, SDKMAN and user install locations.
public enum ToolLocator {
    public static func searchDirectories(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var dirs = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        dirs += ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.sdkman/candidates/maven/current/bin",
                 "\(home)/.sdkman/candidates/gradle/current/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen = Set<String>()
        return dirs.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Looks in `extraDirectories` first (e.g. the JDK's `bin`), then the search path.
    public static func find(
        _ name: String,
        in extraDirectories: [String] = [],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        for dir in extraDirectories + searchDirectories(environment: environment) {
            let path = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    /// The current environment with PATH widened to every search directory. With a JDK, its
    /// `bin` goes first and `JAVA_HOME` points at it, so Maven/Gradle use the same JDK.
    public static func environment(
        jdk: JDK? = nil,
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var env = base
        var dirs = searchDirectories(environment: base)
        if let jdk {
            env["JAVA_HOME"] = jdk.home.path
            dirs.insert(jdk.home.appendingPathComponent("bin").path, at: 0)
        }
        var seen = Set<String>()
        env["PATH"] = dirs.filter { seen.insert($0).inserted }.joined(separator: ":")
        return env
    }
}

/// A Java Development Kit installation.
public struct JDK: Sendable, Hashable {
    public let home: URL
    /// e.g. "21.0.5" (from the `release` file), if known.
    public let version: String?

    public init(home: URL, version: String? = nil) {
        self.home = home
        self.version = version ?? Self.readVersion(home: home)
    }

    public var java: URL { home.appendingPathComponent("bin/java") }
    public var javac: URL { home.appendingPathComponent("bin/javac") }
    public var jshell: URL { home.appendingPathComponent("bin/jshell") }

    /// The feature release (21 for "21.0.5", 8 for "1.8.0_402").
    public var majorVersion: Int? {
        guard let version else { return nil }
        let parts = version.split(separator: ".").compactMap { Int($0) }
        guard let first = parts.first else { return nil }
        return first == 1 && parts.count > 1 ? parts[1] : first
    }

    public var label: String { version.map { "JDK \($0)" } ?? home.lastPathComponent }

    public var isValid: Bool { FileManager.default.isExecutableFile(atPath: javac.path) }

    static func readVersion(home: URL) -> String? {
        guard let release = try? String(contentsOf: home.appendingPathComponent("release"), encoding: .utf8) else { return nil }
        return parseRelease(release)
    }

    /// Reads `JAVA_VERSION="21.0.5"` from a JDK `release` file.
    public static func parseRelease(_ text: String) -> String? {
        for line in text.split(separator: "\n") where line.hasPrefix("JAVA_VERSION=") {
            return line.dropFirst("JAVA_VERSION=".count).trimmingCharacters(in: CharacterSet(charactersIn: "\" \r"))
        }
        return nil
    }

    /// `$JAVA_HOME`, else `/usr/libexec/java_home` (the default macOS JDK), else Homebrew's openjdk.
    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment) -> JDK? {
        if let home = environment["JAVA_HOME"], !home.isEmpty {
            let jdk = JDK(home: URL(fileURLWithPath: home))
            if jdk.isValid { return jdk }
        }
        if let home = runJavaHome([]) {
            let jdk = JDK(home: URL(fileURLWithPath: home))
            if jdk.isValid { return jdk }
        }
        for path in ["/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home",
                     "/usr/local/opt/openjdk/libexec/openjdk.jdk/Contents/Home"] {
            let jdk = JDK(home: URL(fileURLWithPath: path))
            if jdk.isValid { return jdk }
        }
        return nil
    }

    /// Every JDK registered with macOS (`/usr/libexec/java_home -X`), plus Homebrew's openjdk.
    public static func installed() -> [JDK] {
        var homes: [String] = []
        if let xml = runJavaHomeData(["-X"]),
           let list = try? PropertyListSerialization.propertyList(from: xml, format: nil) as? [[String: Any]] {
            homes = list.compactMap { $0["JVMHomePath"] as? String }
        }
        homes += ["/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home"]
        var seen = Set<String>()
        return homes
            .map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() }
            .filter { seen.insert($0.path).inserted }
            .map { JDK(home: $0) }
            .filter(\.isValid)
    }

    private static func runJavaHome(_ arguments: [String]) -> String? {
        runJavaHomeData(arguments).map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func runJavaHomeData(_ arguments: [String]) -> Data? {
        let tool = "/usr/libexec/java_home"
        guard FileManager.default.isExecutableFile(atPath: tool) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }
}

/// How a project is built: Maven, Gradle, or plain `javac` over the source files.
public enum BuildSystem: String, Sendable, Hashable {
    case maven, gradle, plain

    public var displayName: String {
        switch self {
        case .maven: "Maven"
        case .gradle: "Gradle"
        case .plain: "javac"
        }
    }

    public static func detect(root: URL) -> BuildSystem {
        let fm = FileManager.default
        if fm.fileExists(atPath: root.appendingPathComponent("pom.xml").path) { return .maven }
        for name in ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"]
        where fm.fileExists(atPath: root.appendingPathComponent(name).path) {
            return .gradle
        }
        return .plain
    }

    /// The wrapper script in the project (`mvnw` / `gradlew`) if present, else the tool on PATH.
    public func executable(root: URL, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        switch self {
        case .maven:
            let wrapper = root.appendingPathComponent("mvnw")
            if FileManager.default.isExecutableFile(atPath: wrapper.path) { return wrapper }
            return ToolLocator.find("mvn", environment: environment)
        case .gradle:
            let wrapper = root.appendingPathComponent("gradlew")
            if FileManager.default.isExecutableFile(atPath: wrapper.path) { return wrapper }
            return ToolLocator.find("gradle", environment: environment)
        case .plain:
            return nil
        }
    }

    /// Compiled main classes, used as the jshell class path.
    public func classOutputDirectories(root: URL) -> [URL] {
        switch self {
        case .maven: [root.appendingPathComponent("target/classes")]
        case .gradle: [root.appendingPathComponent("build/classes/java/main")]
        case .plain: [JavaProject.plainOutputDirectory(root: root)]
        }
    }
}

/// Facts about Java sources needed to run them.
public enum JavaProject {
    /// The `package` declaration of a source file, if any.
    public static func packageName(in source: String) -> String? {
        let pattern = #"(?m)^\s*package\s+([\p{L}_$][\p{L}\p{Nd}_$]*(?:\s*\.\s*[\p{L}_$][\p{L}\p{Nd}_$]*)*)\s*;"#
        let stripped = stripComments(source)
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: stripped, range: NSRange(location: 0, length: (stripped as NSString).length))
        else { return nil }
        return (stripped as NSString).substring(with: match.range(at: 1)).filter { !$0.isWhitespace }
    }

    /// Fully qualified class name of the file's top-level class (package + file name).
    public static func qualifiedClassName(file: URL, source: String) -> String {
        let simple = file.deletingPathExtension().lastPathComponent
        return packageName(in: source).map { "\($0).\(simple)" } ?? simple
    }

    /// Whether the source declares a `main` method (classic `public static void main(String[] args)`,
    /// or a JDK 21+ instance main `void main()`).
    public static func hasMainMethod(_ source: String) -> Bool {
        let stripped = stripComments(source)
        let pattern = #"\b(?:public\s+)?(?:static\s+)?void\s+main\s*\(\s*(?:(?:final\s+)?String\s*(?:\[\s*\]|\.\.\.)\s*[\p{L}_$][\p{L}\p{Nd}_$]*(?:\s*\[\s*\])?)?\s*\)"#
        return stripped.range(of: pattern, options: .regularExpression) != nil
    }

    /// Whether the file looks like a JUnit test.
    public static func isTestSource(file: URL, source: String) -> Bool {
        let path = file.path
        return path.contains("/src/test/") || source.contains("@Test")
    }

    /// Where plain (non-Maven/Gradle) projects are compiled, outside the project folder.
    public static func plainOutputDirectory(root: URL) -> URL {
        cacheDirectory(for: root).appendingPathComponent("classes")
    }

    /// Per-project cache folder (jdtls workspace data, compiled classes, decompiled sources).
    public static func cacheDirectory(for root: URL) -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("JavaIDE")
        let path = root.resolvingSymlinksInPath().path
        let slug = root.lastPathComponent.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return base.appendingPathComponent("\(slug)-\(stableHash(path))")
    }

    /// FNV-1a, so the cache folder is the same across launches (Swift's `hashValue` is seeded).
    static func stableHash(_ s: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    /// Replaces comments and string contents with spaces, keeping offsets and newlines.
    public static func stripComments(_ source: String) -> String {
        var out = [Character]()
        out.reserveCapacity(source.count)
        let chars = Array(source)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            if c == "/" && next == "/" {
                while i < chars.count && chars[i] != "\n" { out.append(" "); i += 1 }
            } else if c == "/" && next == "*" {
                out.append(" "); out.append(" "); i += 2
                while i < chars.count && !(chars[i] == "*" && i + 1 < chars.count && chars[i + 1] == "/") {
                    out.append(chars[i] == "\n" ? "\n" : " "); i += 1
                }
                if i < chars.count { out.append(" "); out.append(" "); i += 2 }
            } else if c == "\"" || c == "'" {
                out.append(c); i += 1
                while i < chars.count && chars[i] != c && chars[i] != "\n" {
                    if chars[i] == "\\" && i + 1 < chars.count { out.append(" "); i += 1 }
                    out.append(" "); i += 1
                }
                if i < chars.count && chars[i] == c { out.append(c); i += 1 }
            } else {
                out.append(c); i += 1
            }
        }
        return String(out)
    }
}

/// The Eclipse JDT language server.
public enum LanguageServerSpec {
    public static let name = "jdtls"
    public static let installHint = "brew install jdtls"

    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        ToolLocator.find("jdtls", environment: environment)
    }

    /// `-data` keeps jdtls' per-project index outside the project folder.
    public static func arguments(root: URL) -> [String] {
        ["-data", JavaProject.cacheDirectory(for: root).appendingPathComponent("jdtls-data").path,
         "--jvm-arg=-Xmx2G"]
    }

    /// jdtls runs on its own (Homebrew) JDK; a project `JAVA_HOME` older than 21 would stop it starting.
    public static func environment(base: [String: String]) -> [String: String] {
        var env = ToolLocator.environment(base: base)
        env.removeValue(forKey: "JAVA_HOME")
        return env
    }

    /// Settings sent in `initializationOptions` and `workspace/didChangeConfiguration`.
    public static func settings(jdk: JDK?) -> JSONValue {
        var java: [String: JSONValue] = [
            "format": ["enabled": true],
            "signatureHelp": ["enabled": true],
            "contentProvider": ["preferred": "fernflower"],
            "completion": ["importOrder": ["java", "javax", "org", "com"]],
            "sources": ["organizeImports": ["starThreshold": 99, "staticStarThreshold": 99]],
            "configuration": ["updateBuildConfiguration": "automatic"],
            "autobuild": ["enabled": true],
        ]
        if let jdk, let major = jdk.majorVersion {
            let name = major <= 8 ? "JavaSE-1.\(major)" : "JavaSE-\(major)"
            java["configuration"] = [
                "updateBuildConfiguration": "automatic",
                "runtimes": [["name": .string(name), "path": .string(jdk.home.path), "default": true]],
            ]
            java["home"] = .string(jdk.home.path)
        }
        return ["java": .object(java)]
    }

    public static func initializationOptions(jdk: JDK?, bundles: [URL] = []) -> JSONValue {
        [
            "bundles": .array(bundles.map { .string($0.path) }),
            "settings": settings(jdk: jdk),
            "extendedClientCapabilities": [
                "classFileContentsSupport": true,
                "progressReportProvider": false,
                "advancedOrganizeImportsSupport": false,
                "generateToStringPromptSupport": false,
                "hashCodeEqualsPromptSupport": false,
                "moveRefactoringSupport": false,
                "overrideMethodsPromptSupport": false,
            ],
        ]
    }

    /// Answers `workspace/configuration` with the matching section of `settings`.
    public static func configuration(items: [JSONValue], jdk: JDK?) -> JSONValue {
        let all = settings(jdk: jdk)
        return .array(items.map { item in
            guard let section = item["section"]?.stringValue else { return all }
            var value: JSONValue? = all
            for part in section.split(separator: ".") { value = value?[String(part)] }
            return value ?? .null
        })
    }
}
