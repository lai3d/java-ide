import Foundation

/// One configuration property from Spring Boot's configuration metadata.
public struct ConfigPropertyInfo: Sendable, Hashable {
    public let name: String
    public let type: String?
    public let description: String?
    public let defaultValue: String?
    public let deprecated: Bool

    public init(name: String, type: String? = nil, description: String? = nil, defaultValue: String? = nil,
                deprecated: Bool = false) {
        self.name = name
        self.type = type
        self.description = description
        self.defaultValue = defaultValue
        self.deprecated = deprecated
    }

    /// `java.util.Map<java.lang.String,java.lang.String>` → `Map<String,String>`.
    public var shortType: String? {
        type?.replacingOccurrences(of: #"\b[a-z][a-z0-9_]*\."#, with: "", options: .regularExpression)
    }

    public var isMap: Bool { type?.hasPrefix("java.util.Map<") == true }
    public var isBoolean: Bool { type == "java.lang.Boolean" || type == "boolean" }

    public var markdown: String {
        var text = "**\(name)**"
        if let shortType { text += "  `\(shortType)`" }
        if deprecated { text += "\n\n*Deprecated*" }
        if let description, !description.isEmpty { text += "\n\n" + description }
        if let defaultValue { text += "\n\nDefault: `\(defaultValue)`" }
        return text
    }
}

public struct ConfigValueHint: Sendable, Hashable {
    public let value: String
    public let description: String?
}

/// Every configuration property on a module's class path, read from the
/// `META-INF/spring-configuration-metadata.json` files that Spring Boot jars (and the
/// configuration processor) produce.
public struct SpringConfigIndex: Sendable {
    public private(set) var properties: [String: ConfigPropertyInfo] = [:]
    public private(set) var hints: [String: [ConfigValueHint]] = [:]
    public private(set) var names: [String] = []

    public init() {}

    public var isEmpty: Bool { properties.isEmpty }

    /// Adds one metadata file.
    public mutating func merge(json data: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        for item in root["properties"] as? [[String: Any]] ?? [] {
            guard let name = item["name"] as? String else { continue }
            let deprecation = item["deprecation"] as? [String: Any]
            let deprecated = (item["deprecated"] as? Bool ?? false) || deprecation != nil
            if deprecation?["level"] as? String == "error" { continue }  // removed properties
            // The same key can appear in both metadata files; keep fields the later one leaves out.
            let old = properties[name]
            properties[name] = ConfigPropertyInfo(
                name: name, type: item["type"] as? String ?? old?.type,
                description: item["description"] as? String ?? old?.description,
                defaultValue: item["defaultValue"].flatMap(Self.describe) ?? old?.defaultValue,
                deprecated: deprecated || old?.deprecated == true)
        }
        for item in root["hints"] as? [[String: Any]] ?? [] {
            guard let name = item["name"] as? String else { continue }
            let values = (item["values"] as? [[String: Any]] ?? []).compactMap { value -> ConfigValueHint? in
                guard let v = value["value"].flatMap(Self.describe) else { return nil }
                return ConfigValueHint(value: v, description: value["description"] as? String)
            }
            if !values.isEmpty { hints[name] = values }
        }
        names = properties.keys.sorted()
    }

    private static func describe(_ value: Any) -> String? {
        switch value {
        case let s as String: return s
        case let n as NSNumber:
            return CFGetTypeID(n) == CFBooleanGetTypeID() ? (n.boolValue ? "true" : "false") : n.stringValue
        case let a as [Any]: return a.compactMap(describe).joined(separator: ",")
        default: return nil
        }
    }

    /// Relaxed binding: `server.servlet.contextPath` and `SERVER_PORT`-style keys map to the kebab-case name.
    public static func canonical(_ key: String) -> String {
        var out = ""
        for ch in key {
            if ch.isUppercase {
                if let last = out.last, last != ".", last != "-" { out.append("-") }
                out.append(Character(ch.lowercased()))
            } else if ch == "_" {
                out.append("-")
            } else {
                out.append(ch)
            }
        }
        return out
    }

    /// The property for a key, also inside maps (`logging.level.com.example` → `logging.level`).
    public func lookup(_ key: String) -> ConfigPropertyInfo? {
        let key = key.hasPrefix("[") ? key : Self.canonical(key)
        if let exact = properties[key] { return exact }
        var prefix = key
        while let dot = prefix.lastIndex(of: ".") {
            prefix = String(prefix[..<dot])
            if let property = properties[prefix], property.isMap { return property }
        }
        return nil
    }

    /// Suggested values for a key: metadata hints, else `true` / `false` for booleans.
    public func values(for key: String) -> [ConfigValueHint] {
        let canonicalKey = Self.canonical(key)
        if let direct = hints[canonicalKey] { return direct }
        guard let property = lookup(canonicalKey) else { return [] }
        if let values = hints[property.name + ".values"] ?? hints[property.name] { return values }
        if property.isBoolean {
            return [ConfigValueHint(value: "true", description: nil), ConfigValueHint(value: "false", description: nil)]
        }
        return []
    }

    // MARK: Loading

    /// Reads the metadata of every jar and class folder on a class path (jars without metadata are skipped).
    public static func load(classpath: [String], cache: MetadataCache? = nil) -> SpringConfigIndex {
        var index = SpringConfigIndex()
        for entry in classpath {
            for data in metadataFiles(entry, cache: cache) { index.merge(json: data) }
        }
        return index
    }

    static let metadataEntries = ["META-INF/spring-configuration-metadata.json",
                                  "META-INF/additional-spring-configuration-metadata.json"]

    static func metadataFiles(_ entry: String, cache: MetadataCache?) -> [Data] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: entry, isDirectory: &isDirectory) else { return [] }
        if isDirectory.boolValue {
            return metadataEntries.compactMap { FileManager.default.contents(atPath: entry + "/" + $0) }
        }
        guard entry.hasSuffix(".jar") else { return [] }
        if let cached = cache?.get(entry) { return cached }
        // Jars are immutable in the local repository, so the result is cached by path.
        let files = metadataEntries.compactMap { unzip(jar: entry, member: $0) }
        cache?.set(entry, files)
        return files
    }

    static func unzip(jar: String, member: String) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", jar, member]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 && !data.isEmpty ? data : nil
    }
}

/// Per-jar metadata cache shared across reloads.
public final class MetadataCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: [Data]] = [:]
    public init() {}
    func get(_ key: String) -> [Data]? { lock.withLock { entries[key] } }
    func set(_ key: String, _ value: [Data]) { lock.withLock { entries[key] = value } }
}

/// Completion and hover for `application*.properties` and `application*.yml`.
public enum SpringConfigEditing {
    public enum FileKind: Sendable { case properties, yaml }

    public static func fileKind(_ url: URL) -> FileKind? {
        let name = url.lastPathComponent.lowercased()
        guard name.hasPrefix("application") || name.hasPrefix("bootstrap") else { return nil }
        switch url.pathExtension.lowercased() {
        case "properties": return .properties
        case "yml", "yaml": return .yaml
        default: return nil
        }
    }

    /// Characters of a key (or value) being typed: completion replaces this run before the caret.
    public static func isKeyCharacter(_ c: unichar) -> Bool {
        Identifier.isIdentifier(c) || c == 0x2E || c == 0x2D || c == 0x5B || c == 0x5D  // . - [ ]
    }

    public static func prefixStart(in text: NSString, before offset: Int) -> Int {
        var i = min(max(offset, 0), text.length)
        while i > 0, isKeyCharacter(text.character(at: i - 1)) { i -= 1 }
        return i
    }

    public static func wordRange(in text: NSString, at index: Int) -> NSRange? {
        guard index >= 0, index < text.length, isKeyCharacter(text.character(at: index)) else { return nil }
        var start = index, end = index + 1
        while start > 0, isKeyCharacter(text.character(at: start - 1)) { start -= 1 }
        while end < text.length, isKeyCharacter(text.character(at: end)) { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    enum Context: Equatable {
        /// Typing a key. `parent` is the YAML path of the enclosing block ("" at the top / in .properties).
        case key(parent: String, typed: String, indent: Int)
        case value(key: String)
        case none
    }

    static func context(text: String, offset: Int, kind: FileKind) -> Context {
        let ns = text as NSString
        let offset = min(max(offset, 0), ns.length)
        let lineRange = ns.lineRange(for: NSRange(location: offset, length: 0))
        let before = ns.substring(with: NSRange(location: lineRange.location, length: offset - lineRange.location))
        let trimmed = String(before.drop { $0 == " " || $0 == "\t" })
        if trimmed.hasPrefix("#") || trimmed.hasPrefix("!") { return .none }
        let indent = before.prefix { $0 == " " }.count
        switch kind {
        case .properties:
            if let sep = before.firstIndex(where: { $0 == "=" || $0 == ":" }) {
                return .value(key: before[..<sep].trimmingCharacters(in: .whitespaces))
            }
            return .key(parent: "", typed: trimmed, indent: 0)
        case .yaml:
            var linePart = trimmed
            var itemIndent = indent
            if linePart.hasPrefix("- ") {  // list item: its keys sit two columns further in
                linePart = String(linePart.dropFirst(2))
                itemIndent += 2
            }
            let parent = yamlParent(lines: ns.substring(to: lineRange.location), indent: itemIndent)
            if let colon = linePart.range(of: ": ") {
                let key = linePart[..<colon.lowerBound].trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                return .value(key: parent.isEmpty ? key : parent + "." + key)
            }
            if linePart.hasSuffix(":") { return .none }
            if trimmed.hasPrefix("- ") { return .value(key: parent) }  // a list value
            return .key(parent: parent, typed: linePart, indent: itemIndent)
        }
    }

    /// The dotted path of the YAML block enclosing a line indented by `indent`.
    static func yamlParent(lines: String, indent: Int) -> String {
        var path: [String] = []
        var limit = indent
        for raw in lines.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard limit > 0 else { break }
            let line = String(raw)
            let content = line.trimmingCharacters(in: .whitespaces)
            if content.isEmpty || content.hasPrefix("#") { continue }
            if content.hasPrefix("---") { break }
            var lineIndent = line.prefix { $0 == " " }.count
            var body = content
            if body.hasPrefix("- ") {
                body = String(body.dropFirst(2))
                lineIndent += 2
            }
            guard lineIndent < limit, let colon = body.firstIndex(of: ":") else { continue }
            let key = body[..<colon].trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            path.insert(key, at: 0)
            limit = lineIndent
        }
        return path.joined(separator: ".")
    }

    /// Completion items at `offset`. Each item replaces the key / value run before the caret
    /// (`prefixStart(in:before:)`).
    public static func completions(index: SpringConfigIndex, text: String, offset: Int, kind: FileKind) -> [CompletionItem] {
        switch context(text: text, offset: offset, kind: kind) {
        case .none:
            return []
        case .value(let key):
            return index.values(for: key).map {
                CompletionItem(label: $0.value, kind: .value, detail: $0.description, insertText: $0.value)
            }
        case .key(let parent, let typed, let indent):
            return keyCompletions(index: index, parent: SpringConfigIndex.canonical(parent), typed: typed,
                                  indent: indent, kind: kind)
        }
    }

    static func keyCompletions(index: SpringConfigIndex, parent: String, typed: String, indent: Int,
                               kind: FileKind) -> [CompletionItem] {
        let scope = parent.isEmpty ? "" : parent + "."
        let typedDots = typed.filter { $0 == "." }.count
        var seen = Set<String>()
        var items: [CompletionItem] = []
        for name in index.names where name.hasPrefix(scope) {
            let relative = String(name.dropFirst(scope.count))
            guard FuzzyMatch.matches(typed, relative) || relative.hasPrefix(typed) else { continue }
            guard let property = index.properties[name] else { continue }
            switch kind {
            case .properties:
                items.append(CompletionItem(label: name, kind: .property,
                                            detail: property.shortType.map { (property.deprecated ? "deprecated " : "") + $0 },
                                            documentation: property.markdown, insertText: name + "=",
                                            filterText: name, sortText: (property.deprecated ? "1" : "0") + name))
            case .yaml:
                // Offer the next segment(s): as many as the user typed dots, plus one.
                let segments = relative.split(separator: ".", omittingEmptySubsequences: false)
                let candidate = segments.prefix(typedDots + 1).joined(separator: ".")
                guard seen.insert(candidate).inserted else { continue }
                let isLeaf = candidate == relative
                let childIndent = String(repeating: " ", count: indent + 2)
                let insert: String
                if isLeaf && !property.isMap {
                    insert = candidate + ": "
                } else {
                    insert = candidate + ":\n" + childIndent
                }
                items.append(CompletionItem(
                    label: candidate, kind: isLeaf ? .property : .module,
                    detail: isLeaf ? property.shortType.map { (property.deprecated ? "deprecated " : "") + $0 } : scope + candidate,
                    documentation: isLeaf ? property.markdown : nil, insertText: insert, filterText: candidate,
                    sortText: (isLeaf && property.deprecated ? "1" : "0") + candidate))
            }
            if items.count >= 400 { break }
        }
        // Current keys first: deprecated ones (e.g. Gateway's pre-2025 names) sink to the bottom.
        return items.enumerated().sorted { a, b in
            a.element.sortText.first == b.element.sortText.first ? a.offset < b.offset
                : (a.element.sortText.first ?? "0") < (b.element.sortText.first ?? "0")
        }.map(\.element)
    }

    /// Hover text for the key on the line at `offset`.
    public static func hover(index: SpringConfigIndex, text: String, offset: Int, kind: FileKind) -> String? {
        let ns = text as NSString
        guard offset >= 0, offset <= ns.length else { return nil }
        let lineRange = ns.lineRange(for: NSRange(location: offset, length: 0))
        let line = ns.substring(with: lineRange).trimmingCharacters(in: .newlines)
        let content = line.trimmingCharacters(in: .whitespaces)
        guard !content.isEmpty, !content.hasPrefix("#") else { return nil }
        let key: String
        switch kind {
        case .properties:
            guard let sep = content.firstIndex(where: { $0 == "=" || $0 == ":" || $0 == " " }) else { return nil }
            key = String(content[..<sep])
        case .yaml:
            var body = content
            var indent = line.prefix { $0 == " " }.count
            if body.hasPrefix("- ") { body = String(body.dropFirst(2)); indent += 2 }
            guard let colon = body.firstIndex(of: ":") else { return nil }
            let parent = yamlParent(lines: ns.substring(to: lineRange.location), indent: indent)
            let own = body[..<colon].trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            key = parent.isEmpty ? own : parent + "." + own
        }
        if let property = index.lookup(key) { return property.markdown }
        // A YAML group line ("server:"): describe what is under it.
        let prefix = SpringConfigIndex.canonical(key) + "."
        let count = index.names.filter { $0.hasPrefix(prefix) }.count
        return count > 0 ? "**\(SpringConfigIndex.canonical(key))**\n\n\(count) properties" : nil
    }
}
