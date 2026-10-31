import Foundation

/// Finds clickable locations in build / run output: compiler errors (javac, Maven, Gradle)
/// and stack-trace frames.
public enum OutputLinks {
    public enum Target: Sendable, Hashable {
        /// An absolute source path with a 1-based line (and column, if known).
        case file(path: String, line: Int, column: Int?)
        /// `at com.example.App.main(App.java:12)`: the declaring class, its file name and a 1-based line.
        case stackFrame(className: String, fileName: String, line: Int, text: String)
    }

    public struct Link: Sendable, Hashable {
        /// UTF-16 range in the searched text.
        public let range: NSRange
        public let target: Target
    }

    // Maven:  /abs/App.java:[12,5] message
    // javac / Gradle:  /abs/App.java:12: error: message   (also file:/// prefixes, and Kotlin-style "e: file:///…:12:5")
    private static let pathRegex = try! NSRegularExpression(
        pattern: #"(?:file://)?(/[^\s:\[\]"'()]+\.(?:java|kt|xml|gradle|kts|properties)):(?:\[(\d+),(\d+)\]|(\d+)(?::(\d+))?)"#)
    // Stack frame:  at com.example.App$Inner.method(App.java:12)   (optionally with module prefix "java.base/")
    private static let frameRegex = try! NSRegularExpression(
        pattern: #"\bat\s+(?:[\w.$-]+/)?([\p{L}_$][\p{L}\p{Nd}_$.]*)\.[\p{L}_$<>][\p{L}\p{Nd}_$<>]*\(([\p{L}\p{Nd}_$]+\.java):(\d+)\)"#)

    public static func find(in text: String) -> [Link] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var links: [Link] = []
        for match in pathRegex.matches(in: text, range: full) {
            let path = ns.substring(with: match.range(at: 1))
            func int(_ i: Int) -> Int? {
                let r = match.range(at: i)
                return r.location == NSNotFound ? nil : Int(ns.substring(with: r))
            }
            guard let line = int(2) ?? int(4) else { continue }
            links.append(Link(range: match.range, target: .file(path: path, line: line, column: int(3) ?? int(5))))
        }
        for match in frameRegex.matches(in: text, range: full) {
            var className = ns.substring(with: match.range(at: 1))
            if let dollar = className.firstIndex(of: "$") { className = String(className[..<dollar]) }
            let fileName = ns.substring(with: match.range(at: 2))
            guard let line = Int(ns.substring(with: match.range(at: 3))) else { continue }
            let lineRange = ns.lineRange(for: match.range)
            let text = ns.substring(with: lineRange).trimmingCharacters(in: .whitespacesAndNewlines)
            // Link just the "(App.java:12)" part, like IDEs do.
            let start = match.range(at: 2).location - 1
            let range = NSRange(location: start, length: NSMaxRange(match.range) - start)
            links.append(Link(range: range, target: .stackFrame(className: className, fileName: fileName, line: line, text: text)))
        }
        return links.sorted { $0.range.location < $1.range.location }
    }

    /// The relative path a stack frame's file lives at: `com/example/App.java`.
    public static func relativePath(className: String, fileName: String) -> String {
        let parts = className.split(separator: ".")
        let package = parts.dropLast().joined(separator: "/")
        return package.isEmpty ? fileName : package + "/" + fileName
    }

    // MARK: - URLs (links inside an AttributedString)

    public static let scheme = "javaide"

    public static func url(for target: Target) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "open"
        switch target {
        case .file(let path, let line, let column):
            components.queryItems = [URLQueryItem(name: "path", value: path), URLQueryItem(name: "line", value: String(line))]
                + (column.map { [URLQueryItem(name: "column", value: String($0))] } ?? [])
        case .stackFrame(let className, let fileName, let line, let text):
            components.queryItems = [
                URLQueryItem(name: "class", value: className), URLQueryItem(name: "file", value: fileName),
                URLQueryItem(name: "line", value: String(line)), URLQueryItem(name: "text", value: text),
            ]
        }
        return components.url!
    }

    public static func target(from url: URL) -> Target? {
        guard url.scheme == scheme, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard let line = value("line").flatMap(Int.init) else { return nil }
        if let path = value("path") { return .file(path: path, line: line, column: value("column").flatMap(Int.init)) }
        if let className = value("class"), let file = value("file") {
            return .stackFrame(className: className, fileName: file, line: line, text: value("text") ?? "")
        }
        return nil
    }

    /// Output text with links attached (for SwiftUI `Text`). Very large outputs are left plain.
    public static func attributed(_ text: String, limit: Int = 400_000) -> AttributedString {
        var result = AttributedString(text)
        guard text.utf16.count <= limit else { return result }
        for link in find(in: text) {
            guard let range = Range(link.range, in: text),
                  let lower = AttributedString.Index(range.lowerBound, within: result),
                  let upper = AttributedString.Index(range.upperBound, within: result) else { continue }
            result[lower..<upper].link = url(for: link.target)
        }
        return result
    }
}
