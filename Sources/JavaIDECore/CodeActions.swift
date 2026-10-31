import Foundation

/// An LSP `CodeAction` (or bare `Command`) offered for a range: quick fixes, organize imports, refactorings.
public struct CodeAction: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let title: String
    public let kind: String?
    public let isPreferred: Bool
    /// The raw `edit` (a WorkspaceEdit) if the action carries one.
    public let edit: JSONValue?
    /// A command to run with `workspace/executeCommand` (after applying `edit`).
    public let command: JSONValue?
    /// The raw action, for `codeAction/resolve` when neither edit nor command is present.
    public let raw: JSONValue

    public init(title: String, kind: String? = nil, isPreferred: Bool = false, edit: JSONValue? = nil,
                command: JSONValue? = nil, raw: JSONValue = .null) {
        self.id = UUID()
        self.title = title
        self.kind = kind
        self.isPreferred = isPreferred
        self.edit = edit
        self.command = command
        self.raw = raw
    }

    public var needsResolve: Bool { edit == nil && command == nil }

    public static func parse(_ value: JSONValue) -> CodeAction? {
        guard let title = value["title"]?.stringValue else { return nil }
        // A bare Command has `command` as a string; a CodeAction has it as an object.
        if value["command"]?.stringValue != nil {
            return CodeAction(title: title, command: value, raw: value)
        }
        return CodeAction(title: title, kind: value["kind"]?.stringValue,
                          isPreferred: value["isPreferred"]?.boolValue ?? false,
                          edit: value["edit"], command: value["command"], raw: value)
    }

    /// Parses a `textDocument/codeAction` result: quick fixes first, preferred ones on top.
    public static func parseList(_ result: JSONValue) -> [CodeAction] {
        let actions = (result.arrayValue ?? []).compactMap(parse)
        func rank(_ a: CodeAction) -> Int {
            if a.isPreferred { return 0 }
            if a.kind?.hasPrefix("quickfix") == true { return 1 }
            if a.kind?.hasPrefix("refactor") == true { return 2 }
            return 3
        }
        return actions.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
    }
}

/// jdtls `jdt://` URIs point into JARs and the JDK; we fetch their source with `java/classFileContents`.
public enum ClassFileURI {
    public static func isClassFile(_ uri: String) -> Bool { uri.hasPrefix("jdt://") }

    /// A readable file name for a `jdt://contents/java.base/java.lang/String.class?=…` URI: `String.java`.
    public static func fileName(for uri: String) -> String {
        let path = uri.split(separator: "?", maxSplits: 1).first.map(String.init) ?? uri
        let last = path.split(separator: "/").last.map(String.init) ?? "Class.class"
        let decoded = last.removingPercentEncoding ?? last
        let base = decoded.hasSuffix(".class") ? String(decoded.dropLast(6)) : decoded
        return base + ".java"
    }

    /// The package-like folder for the URI (`java.lang`), to keep same-named classes apart.
    public static func packagePath(for uri: String) -> String {
        let path = uri.split(separator: "?", maxSplits: 1).first.map(String.init) ?? uri
        let parts = path.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
        guard parts.count >= 2 else { return "unknown" }
        return parts[parts.count - 2]
    }
}
