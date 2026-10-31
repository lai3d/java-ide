import Foundation

public enum TokenKind: Sendable, Hashable {
    case keyword, type, literal, function, annotation, string, comment, number
}

public struct Token: Sendable, Hashable {
    public let range: NSRange
    public let kind: TokenKind

    public init(range: NSRange, kind: TokenKind) {
        self.range = range
        self.kind = kind
    }
}

/// A fast, regex-based Java lexer for syntax highlighting.
public enum JavaHighlighter {
    public static let keywords: Set<String> = [
        "abstract", "assert", "break", "case", "catch", "class", "const", "continue", "default", "do", "else",
        "enum", "extends", "final", "finally", "for", "goto", "if", "implements", "import", "instanceof",
        "interface", "native", "new", "package", "private", "protected", "public", "return", "static",
        "strictfp", "super", "switch", "synchronized", "this", "throw", "throws", "transient", "try",
        "volatile", "while",
    ]

    /// Contextual keywords: only highlighted where they act as keywords.
    public static let contextualKeywords: Set<String> = [
        "var", "record", "yield", "sealed", "permits", "non-sealed", "module", "requires", "exports", "opens", "when",
    ]

    public static let primitiveTypes: Set<String> = [
        "boolean", "byte", "char", "double", "float", "int", "long", "short", "void",
    ]

    public static let literals: Set<String> = ["true", "false", "null"]

    // Alternation order matters: comments and strings win over anything inside them.
    private static let regex = try! NSRegularExpression(pattern: [
        #"(//[^\n]*|/\*[\s\S]*?(?:\*/|$(?![\s\S])))"#,                                     // 1: comment
        #"("""[\s\S]*?(?:"""|$(?![\s\S]))|"(?:\\.|[^"\\\n])*"?|'(?:\\.|[^'\\\n])*'?)"#,     // 2: string / text block / char
        #"(@(?!interface\b)[\p{L}_$][\p{L}\p{Nd}_$]*(?:\.[\p{L}_$][\p{L}\p{Nd}_$]*)*)"#,   // 3: annotation
        #"((?<![\p{L}\p{Nd}_$])(?:0[xX][0-9a-fA-F_]+[lL]?|0[bB][01_]+[lL]?|(?:\d[\d_]*\.?[\d_]*|\.\d[\d_]*)(?:[eE][+-]?\d+)?[fFdDlL]?))"#, // 4: number
        #"([\p{L}_$][\p{L}\p{Nd}_$]*)"#,                                                  // 5: identifier
    ].joined(separator: "|"))

    public static func tokenize(_ text: String) -> [Token] {
        let ns = text as NSString
        var tokens: [Token] = []
        var previousWord: String?
        regex.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match else { return }
            if match.range(at: 1).location != NSNotFound {
                tokens.append(Token(range: match.range(at: 1), kind: .comment))
            } else if match.range(at: 2).location != NSNotFound {
                tokens.append(Token(range: match.range(at: 2), kind: .string))
                previousWord = nil
            } else if match.range(at: 3).location != NSNotFound {
                tokens.append(Token(range: match.range(at: 3), kind: .annotation))
                previousWord = nil
            } else if match.range(at: 4).location != NSNotFound {
                tokens.append(Token(range: match.range(at: 4), kind: .number))
                previousWord = nil
            } else {
                let range = match.range(at: 5)
                let word = ns.substring(with: range)
                defer { previousWord = word }
                if ["class", "interface", "enum", "record"].contains(previousWord ?? "") && !keywords.contains(word) {
                    tokens.append(Token(range: range, kind: .type))
                } else if keywords.contains(word) || primitiveTypes.contains(word) {
                    tokens.append(Token(range: range, kind: .keyword))
                } else if literals.contains(word) {
                    tokens.append(Token(range: range, kind: .literal))
                } else if contextualKeywords.contains(word), isContextualKeyword(word, ns, range: range) {
                    tokens.append(Token(range: range, kind: .keyword))
                } else if isFollowedByParen(ns, at: NSMaxRange(range)) {
                    tokens.append(Token(range: range, kind: .function))
                } else if let first = word.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(first) {
                    // Java convention: types are UpperCamelCase; ALL_CAPS are constants.
                    let isConstant = word.count > 1 && word.allSatisfy { $0.isUppercase || $0.isNumber || $0 == "_" }
                    tokens.append(Token(range: range, kind: isConstant ? .literal : .type))
                }
            }
        }
        return tokens
    }

    private static func isFollowedByParen(_ ns: NSString, at index: Int) -> Bool {
        var i = index
        while i < ns.length {
            let c = ns.character(at: i)
            if c == 0x28 { return true }             // (
            if c != 0x20 && c != 0x09 { return false } // space / tab
            i += 1
        }
        return false
    }

    /// `var x = …`, `record Point(…)`, `yield value;`, `sealed interface …`: the word is followed by
    /// another identifier (or is `yield` starting a statement), not used as a plain name.
    private static func isContextualKeyword(_ word: String, _ ns: NSString, range: NSRange) -> Bool {
        var i = NSMaxRange(range)
        while i < ns.length, ns.character(at: i) == 0x20 || ns.character(at: i) == 0x09 { i += 1 }
        guard i < ns.length, i > NSMaxRange(range) else { return false }
        let c = ns.character(at: i)
        let startsIdentifier = (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F || c == 0x24 || c >= 0x80
        if word == "yield" { return startsIdentifier || c == 0x28 || c == 0x22 || (c >= 0x30 && c <= 0x39) }
        return startsIdentifier
    }
}

/// Brace-based indentation rules for the editor (4-space indents).
public enum JavaIndent {
    public static let unit = "    "

    /// Indentation for the line after `line` (the text before the caret on the current line).
    public static func indentAfter(line: String) -> String {
        let indent = leadingWhitespace(line)
        let code = stripLineComment(line).trimmingCharacters(in: .whitespaces)
        if code.hasSuffix("{") || code.hasSuffix("(") || code.hasSuffix("[") || code.hasSuffix("->") {
            return indent + unit
        }
        if (code.hasPrefix("case ") || code.hasPrefix("default")) && code.hasSuffix(":") {
            return indent + unit
        }
        return indent
    }

    /// What to insert for ↩ when the caret is between `before` and `after` on one line.
    /// Returns the inserted text and the caret offset inside it.
    public static func newline(before: String, after: String, continueJavadoc: Bool = true) -> (text: String, caret: Int) {
        let indent = leadingWhitespace(before)
        let trimmedBefore = before.trimmingCharacters(in: .whitespaces)
        let trimmedAfter = after.trimmingCharacters(in: .whitespaces)

        // Javadoc / block comments: continue with " * ".
        if continueJavadoc {
            if trimmedBefore.hasPrefix("/*") && !trimmedBefore.contains("*/") {
                let text = "\n" + indent + " * "
                if trimmedAfter.isEmpty && trimmedBefore.hasPrefix("/**") {
                    let full = text + "\n" + indent + " */"
                    return (full, (text as NSString).length)
                }
                return (text, (text as NSString).length)
            }
            if trimmedBefore.hasPrefix("*") && !trimmedBefore.hasPrefix("*/") && !trimmedBefore.contains("*/") {
                let star = before.prefix { $0 == " " || $0 == "\t" }
                let text = "\n" + star + "* "
                return (text, (text as NSString).length)
            }
        }

        let next = indentAfter(line: before)
        // `{|}` or `(|)`: open the block on its own line with the closer below.
        if let open = stripLineComment(before).trimmingCharacters(in: .whitespaces).last,
           let close = trimmedAfter.first,
           (open == "{" && close == "}") || (open == "(" && close == ")") || (open == "[" && close == "]") {
            let middle = "\n" + next
            return (middle + "\n" + indent, (middle as NSString).length)
        }
        let text = "\n" + next
        return (text, (text as NSString).length)
    }

    /// The indentation a `}` typed at `offset` should have: that of the line holding the matching `{`.
    public static func closingBraceIndent(in text: String, at offset: Int) -> String? {
        let ns = text as NSString
        let stripped = JavaProject.stripComments(text) as NSString
        var depth = 0
        var i = min(offset, stripped.length) - 1
        while i >= 0 {
            let c = stripped.character(at: i)
            if c == 0x7D { depth += 1 }                // }
            else if c == 0x7B {                         // {
                if depth == 0 {
                    let line = ns.substring(with: ns.lineRange(for: NSRange(location: i, length: 0)))
                    return leadingWhitespace(line)
                }
                depth -= 1
            }
            i -= 1
        }
        return nil
    }

    /// Number of spaces to delete when backspacing at `column` in an all-space indent.
    public static func dedentWidth(column: Int) -> Int {
        guard column > 0 else { return 0 }
        let remainder = column % unit.count
        return remainder == 0 ? unit.count : remainder
    }

    static func leadingWhitespace(_ line: String) -> String {
        String(line.prefix { $0 == " " || $0 == "\t" })
    }

    /// Removes a trailing `// comment` that isn't inside a string literal.
    static func stripLineComment(_ line: String) -> String {
        var quote: Character?
        var escaped = false
        var previous: Character?
        for (i, ch) in zip(line.indices, line) {
            defer { previous = ch }
            if escaped { escaped = false; continue }
            if ch == "\\" { escaped = true; continue }
            if let q = quote {
                if ch == q { quote = nil }
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch == "/" && previous == "/" {
                return String(line[..<line.index(before: i)])
            }
        }
        return line
    }
}

public extension Identifier {
    /// Whether `name` is a valid Java identifier (and not a reserved word).
    static func isValidJavaName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first,
              first == "_" || first == "$" || CharacterSet.letters.contains(first) else { return false }
        let ok = name.unicodeScalars.allSatisfy { $0 == "_" || $0 == "$" || CharacterSet.alphanumerics.contains($0) }
        return ok && name != "_" && !JavaHighlighter.keywords.contains(name)
            && !JavaHighlighter.primitiveTypes.contains(name) && !JavaHighlighter.literals.contains(name)
    }
}
