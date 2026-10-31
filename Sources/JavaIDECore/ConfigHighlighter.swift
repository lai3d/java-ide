import Foundation

/// Which highlighter an editor uses.
public enum SyntaxLanguage: Sendable, Equatable {
    case java, properties, yaml, none

    public static func forFile(_ url: URL) -> SyntaxLanguage {
        switch url.pathExtension.lowercased() {
        case "java", "jsh": .java
        case "properties": .properties
        case "yml", "yaml": .yaml
        default: .none
        }
    }

    public func tokenize(_ text: String) -> [Token] {
        switch self {
        case .java: JavaHighlighter.tokenize(text)
        case .properties: ConfigHighlighter.tokenizeProperties(text)
        case .yaml: ConfigHighlighter.tokenizeYAML(text)
        case .none: []
        }
    }
}

/// Highlighting for Spring Boot `application.properties` and `application.yml`:
/// keys, values, comments, `${placeholders}`, numbers and booleans.
public enum ConfigHighlighter {
    public static func tokenizeProperties(_ text: String) -> [Token] {
        var tokens: [Token] = []
        let ns = text as NSString
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byLines, .substringNotRequired]) { _, lineRange, _, _ in
            let line = ns.substring(with: lineRange) as NSString
            let indent = leadingWhitespace(line)
            guard indent < line.length else { return }
            let first = line.character(at: indent)
            if first == 0x23 || first == 0x21 {  // # or !
                tokens.append(Token(range: NSRange(location: lineRange.location + indent, length: line.length - indent), kind: .comment))
                return
            }
            // Key ends at the first unescaped '=', ':' or whitespace.
            var i = indent
            while i < line.length {
                let c = line.character(at: i)
                if c == 0x5C { i += 2; continue }  // backslash escape
                if c == 0x3D || c == 0x3A || c == 0x20 || c == 0x09 { break }
                i += 1
            }
            i = min(i, line.length)
            tokens.append(Token(range: NSRange(location: lineRange.location + indent, length: i - indent), kind: .function))
            var valueStart = i
            while valueStart < line.length, [0x20, 0x09].contains(line.character(at: valueStart)) { valueStart += 1 }
            if valueStart < line.length, [0x3D, 0x3A].contains(line.character(at: valueStart)) { valueStart += 1 }
            while valueStart < line.length, [0x20, 0x09].contains(line.character(at: valueStart)) { valueStart += 1 }
            tokens += valueTokens(line.substring(from: valueStart), offset: lineRange.location + valueStart)
        }
        return tokens
    }

    public static func tokenizeYAML(_ text: String) -> [Token] {
        var tokens: [Token] = []
        let ns = text as NSString
        let keyRegex = try! NSRegularExpression(pattern: #"^(\s*(?:-\s+)?)((?:"[^"]*"|'[^']*'|[^\s#:][^#:]*?))\s*:(?=\s|$)"#)
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byLines, .substringNotRequired]) { _, lineRange, _, _ in
            let line = ns.substring(with: lineRange)
            let lineNS = line as NSString
            let indent = leadingWhitespace(lineNS)
            guard indent < lineNS.length else { return }
            let rest = lineNS.substring(from: indent)
            if rest.hasPrefix("#") {
                tokens.append(Token(range: NSRange(location: lineRange.location + indent, length: lineNS.length - indent), kind: .comment))
                return
            }
            if rest.hasPrefix("---") || rest.hasPrefix("...") {
                tokens.append(Token(range: NSRange(location: lineRange.location + indent, length: 3), kind: .keyword))
                return
            }
            var valueStart = indent
            if let match = keyRegex.firstMatch(in: line, range: NSRange(location: 0, length: lineNS.length)) {
                let key = match.range(at: 2)
                tokens.append(Token(range: NSRange(location: lineRange.location + key.location, length: key.length), kind: .function))
                valueStart = NSMaxRange(match.range)
            } else if rest.hasPrefix("- ") || rest == "-" {
                tokens.append(Token(range: NSRange(location: lineRange.location + indent, length: 1), kind: .keyword))
                valueStart = indent + 1
            }
            // Value, up to a ` #` comment.
            var valueText = lineNS.substring(from: valueStart)
            if let hash = commentStart(in: valueText) {
                let commentOffset = valueStart + hash
                tokens.append(Token(range: NSRange(location: lineRange.location + commentOffset, length: lineNS.length - commentOffset),
                                    kind: .comment))
                valueText = (valueText as NSString).substring(to: hash)
            }
            let trimmedLead = leadingWhitespace(valueText as NSString)
            tokens += valueTokens((valueText as NSString).substring(from: trimmedLead), offset: lineRange.location + valueStart + trimmedLead)
        }
        return tokens
    }

    /// Offset of a YAML comment (`#` at the start or after whitespace, outside quotes).
    static func commentStart(in text: String) -> Int? {
        let ns = text as NSString
        var quote: unichar?
        for i in 0..<ns.length {
            let c = ns.character(at: i)
            if let q = quote {
                if c == q { quote = nil }
            } else if c == 0x22 || c == 0x27 {
                quote = c
            } else if c == 0x23, i == 0 || [0x20, 0x09].contains(ns.character(at: i - 1)) {
                return i
            }
        }
        return nil
    }

    private static func valueTokens(_ value: String, offset: Int) -> [Token] {
        let ns = value as NSString
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        let length = (value.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) as NSString).length
        let whole = NSRange(location: offset, length: length)
        if ["true", "false", "null", "~", "yes", "no", "on", "off"].contains(trimmed.lowercased()) {
            return [Token(range: whole, kind: .literal)]
        }
        if trimmed.range(of: #"^-?(\d+(\.\d+)?|0x[0-9a-fA-F]+)([a-zA-Z]{1,2})?$"#, options: .regularExpression) != nil {
            return [Token(range: whole, kind: .number)]
        }
        var tokens = [Token(range: whole, kind: .string)]
        let placeholder = try! NSRegularExpression(pattern: #"\$\{[^}]*\}"#)
        for match in placeholder.matches(in: value, range: NSRange(location: 0, length: ns.length)) {
            tokens.append(Token(range: NSRange(location: offset + match.range.location, length: match.range.length), kind: .annotation))
        }
        return tokens
    }

    private static func leadingWhitespace(_ line: NSString) -> Int {
        var i = 0
        while i < line.length, [0x20, 0x09].contains(line.character(at: i)) { i += 1 }
        return i
    }
}
