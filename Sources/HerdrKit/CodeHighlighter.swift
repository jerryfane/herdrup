import Foundation

/// What a piece of code is, for the chat's syntax colours (omp's theme draws each kind in
/// its own colour). `inserted` and `deleted` are a diff's added and removed lines.
public enum CodeTokenKind: Sendable, Equatable {
    case keyword, string, comment, function, number, type, op
    case inserted, deleted
}

/// A run of code with one kind; `kind` is nil for plain text. The spans of a block, joined,
/// are its code unchanged.
public struct CodeSpan: Sendable, Equatable {
    public let text: String
    public let kind: CodeTokenKind?

    public init(_ text: String, _ kind: CodeTokenKind?) {
        self.text = text
        self.kind = kind
    }
}

/// The languages the highlighter knows. A fence names one of them, or an alias.
public enum CodeLanguage: String, Sendable, Hashable, CaseIterable {
    case swift, rust, javascript, python, bash, json, yaml, go, diff

    /// The language a code fence names (` ```ts `, ` ```sh `), or nil for one the
    /// highlighter does not know: that block stays plain.
    public init?(fence: String?) {
        guard let fence else { return nil }
        switch fence.trimmingCharacters(in: .whitespaces).lowercased() {
        case "swift": self = .swift
        case "rust", "rs": self = .rust
        case "javascript", "js", "jsx", "mjs", "cjs", "typescript", "ts", "tsx": self = .javascript
        case "python", "py", "python3": self = .python
        case "bash", "sh", "shell", "zsh", "console": self = .bash
        case "json", "jsonc": self = .json
        case "yaml", "yml": self = .yaml
        case "go", "golang": self = .go
        case "diff", "patch": self = .diff
        default: return nil
        }
    }
}

/// A small tokenizer for the chat's code blocks: keywords, strings, comments, function
/// calls, numbers, types and operators for the common languages agents write. It is not a
/// parser: it reads one pass left to right and only needs to look right, never to be exact.
public enum CodeHighlighter {
    /// The spans of `code` in the fence's language, or nil when the language is unknown
    /// (no fence, or one the highlighter does not know).
    public static func spans(_ code: String, language: String?) -> [CodeSpan]? {
        CodeLanguage(fence: language).map { spans(code, in: $0) }
    }

    public static func spans(_ code: String, in language: CodeLanguage) -> [CodeSpan] {
        let scalars = Array(code.unicodeScalars)
        switch language {
        case .diff:
            return DiffScanner(s: scalars).run()
        case .bash:
            var scanner = BashScanner(s: scalars)
            return scanner.run()
        default:
            var scanner = CodeScanner(s: scalars, language: language, rules: Rules.of(language))
            return scanner.run()
        }
    }
}

// MARK: - Spans

/// Collects spans, joining neighbours of the same kind so a block has few runs.
private struct SpanBuilder {
    let s: [Unicode.Scalar]
    private(set) var spans: [CodeSpan] = []
    private var runStart = 0
    private var runEnd = 0
    private var runKind: CodeTokenKind?

    init(_ s: [Unicode.Scalar]) { self.s = s }

    mutating func add(_ start: Int, _ end: Int, _ kind: CodeTokenKind?) {
        guard end > start else { return }
        if kind == runKind, start == runEnd {
            runEnd = end
            return
        }
        flush()
        runStart = start
        runEnd = end
        runKind = kind
    }

    mutating func finish() -> [CodeSpan] {
        flush()
        return spans
    }

    private mutating func flush() {
        guard runEnd > runStart else { return }
        var text = String.UnicodeScalarView()
        text.append(contentsOf: s[runStart..<runEnd])
        spans.append(CodeSpan(String(text), runKind))
        runStart = runEnd
    }
}

private extension Unicode.Scalar {
    var isAsciiLetter: Bool { ("a"..."z").contains(self) || ("A"..."Z").contains(self) }
    var isDigit: Bool { ("0"..."9").contains(self) }
    var isIdentifierStart: Bool { isAsciiLetter || self == "_" || (value > 0x7F && properties.isAlphabetic) }
    var isIdentifierPart: Bool { isIdentifierStart || isDigit }
    var isSpace: Bool { self == " " || self == "\t" }
    var isUppercaseLetter: Bool { ("A"..."Z").contains(self) || (value > 0x7F && properties.isUppercase) }
}

private let operatorScalars: Set<Unicode.Scalar> = ["+", "-", "*", "/", "%", "=", "<", ">", "!", "&", "|", "^", "~", "?", ":"]

private func matches(_ s: [Unicode.Scalar], _ literal: String, at index: Int) -> Bool {
    var i = index
    for scalar in literal.unicodeScalars {
        guard i < s.count, s[i] == scalar else { return false }
        i += 1
    }
    return true
}

/// The end of the line `index` is on (the newline's index, or the end).
private func lineEnd(_ s: [Unicode.Scalar], from index: Int) -> Int {
    var i = index
    while i < s.count, s[i] != "\n" { i += 1 }
    return i
}

/// The end of a quoted string that opens at `index`. A backslash escapes the next scalar
/// when `escapes`; the string ends at the close, or at the line's end unless `multiline`.
private func quotedEnd(_ s: [Unicode.Scalar], from index: Int, quote: Unicode.Scalar,
                       escapes: Bool, multiline: Bool) -> Int {
    var i = index + 1
    while i < s.count {
        let c = s[i]
        if escapes, c == "\\" { i += 2; continue }
        if c == quote { return i + 1 }
        if c == "\n", !multiline { return i }
        i += 1
    }
    return s.count
}

private let radixMarks: Set<Unicode.Scalar> = ["x", "X", "o", "O", "b", "B"]

/// The end of a number that starts at `index`: decimal with `_`, a fraction and an
/// exponent, `0x`/`0o`/`0b` forms, and a type suffix (`1u8`, `2.0f`, `10n`).
private func numberEnd(_ s: [Unicode.Scalar], from index: Int) -> Int {
    var i = index
    if s[i] == "0", i + 1 < s.count, radixMarks.contains(s[i + 1]) {
        i += 2
        while i < s.count, s[i].isIdentifierPart { i += 1 }
        return i
    }
    while i < s.count, s[i].isDigit || s[i] == "_" { i += 1 }
    if i + 1 < s.count, s[i] == ".", s[i + 1].isDigit {
        i += 1
        while i < s.count, s[i].isDigit || s[i] == "_" { i += 1 }
    }
    if i < s.count, s[i] == "e" || s[i] == "E" {
        var j = i + 1
        if j < s.count, s[j] == "+" || s[j] == "-" { j += 1 }
        if j < s.count, s[j].isDigit {
            i = j
            while i < s.count, s[i].isDigit { i += 1 }
        }
    }
    while i < s.count, s[i].isIdentifierPart { i += 1 }
    return i
}

// MARK: - C-like, Python, JSON, YAML

private struct Rules {
    var lineComments: [String] = []
    var blockComment: (open: String, close: String)?
    var quotes: Set<Unicode.Scalar> = []
    /// Quotes whose strings may run over several lines (js template strings, Go raw strings).
    var multilineQuotes: Set<Unicode.Scalar> = []
    /// `"""` (Swift, Python) and `'''` (Python) strings.
    var tripleQuotes: [String] = []
    var keywords: Set<String> = []
    var types: Set<String> = []
    /// A capitalised name is a type (Swift, Rust, Go, JS and Python classes).
    var capitalisedTypes = false
    /// `$` starts an identifier (Swift's `$0`, JavaScript's `$el`).
    var dollarIdentifiers = false
    /// `@name` (Swift attributes, Python decorators) is a keyword.
    var atAttributes = false
    /// `#if`, `#available`: Swift's compiler directives are keywords.
    var hashDirectives = false
    /// Rust: `'a` is a lifetime, only `'x'` and `'\n'` are character literals.
    var rustChars = false

    static func of(_ language: CodeLanguage) -> Rules {
        var r = Rules()
        switch language {
        case .swift:
            r.lineComments = ["//"]
            r.blockComment = ("/*", "*/")
            r.quotes = ["\""]
            r.tripleQuotes = ["\"\"\""]
            r.keywords = [
                "associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func", "import",
                "init", "inout", "internal", "let", "open", "operator", "private", "precedencegroup",
                "protocol", "public", "rethrows", "static", "struct", "subscript", "typealias", "var",
                "break", "case", "catch", "continue", "default", "defer", "do", "else", "fallthrough",
                "for", "guard", "if", "in", "repeat", "return", "throw", "switch", "where", "while", "as",
                "false", "is", "nil", "self", "Self", "super", "throws", "true", "try", "await", "async",
                "actor", "some", "any", "weak", "unowned", "lazy", "mutating", "nonmutating", "override",
                "final", "required", "convenience", "dynamic", "indirect", "willSet", "didSet",
                "nonisolated", "isolated", "consuming", "borrowing", "package", "macro",
            ]
            r.capitalisedTypes = true
            r.dollarIdentifiers = true
            r.atAttributes = true
            r.hashDirectives = true
        case .rust:
            r.lineComments = ["//"]
            r.blockComment = ("/*", "*/")
            r.quotes = ["\""]
            r.multilineQuotes = ["\""]
            r.keywords = [
                "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum",
                "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move",
                "mut", "pub", "ref", "return", "self", "Self", "static", "struct", "super", "trait", "true",
                "type", "unsafe", "use", "where", "while", "yield",
            ]
            r.types = [
                "i8", "i16", "i32", "i64", "i128", "isize", "u8", "u16", "u32", "u64", "u128", "usize",
                "f32", "f64", "bool", "char", "str",
            ]
            r.capitalisedTypes = true
            r.rustChars = true
        case .javascript:
            r.lineComments = ["//"]
            r.blockComment = ("/*", "*/")
            r.quotes = ["\"", "'", "`"]
            r.multilineQuotes = ["`"]
            r.keywords = [
                "break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete",
                "do", "else", "export", "extends", "false", "finally", "for", "function", "if", "import",
                "in", "instanceof", "new", "null", "return", "super", "switch", "this", "throw", "true",
                "try", "typeof", "var", "void", "while", "with", "yield", "let", "static", "async",
                "await", "of", "undefined", "interface", "type", "enum", "implements", "private",
                "protected", "public", "readonly", "abstract", "declare", "namespace", "as", "from",
                "keyof", "satisfies",
            ]
            r.types = ["string", "number", "boolean", "any", "unknown", "never", "object", "bigint", "symbol"]
            r.capitalisedTypes = true
            r.dollarIdentifiers = true
        case .python:
            r.lineComments = ["#"]
            r.quotes = ["\"", "'"]
            r.tripleQuotes = ["\"\"\"", "'''"]
            r.keywords = [
                "False", "None", "True", "and", "as", "assert", "async", "await", "break", "class",
                "continue", "def", "del", "elif", "else", "except", "finally", "for", "from", "global",
                "if", "import", "in", "is", "lambda", "nonlocal", "not", "or", "pass", "raise", "return",
                "try", "while", "with", "yield", "self", "match", "case",
            ]
            r.types = ["int", "str", "float", "bool", "list", "dict", "set", "tuple", "bytes", "object"]
            r.capitalisedTypes = true
            r.atAttributes = true
        case .go:
            r.lineComments = ["//"]
            r.blockComment = ("/*", "*/")
            r.quotes = ["\"", "'", "`"]
            r.multilineQuotes = ["`"]
            r.keywords = [
                "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough",
                "for", "func", "go", "goto", "if", "import", "interface", "map", "package", "range",
                "return", "select", "struct", "switch", "type", "var", "nil", "true", "false", "iota",
            ]
            r.types = [
                "bool", "byte", "complex64", "complex128", "error", "float32", "float64", "int", "int8",
                "int16", "int32", "int64", "rune", "string", "uint", "uint8", "uint16", "uint32",
                "uint64", "uintptr", "any",
            ]
            r.capitalisedTypes = true
        case .json:
            r.lineComments = ["//"]
            r.quotes = ["\""]
            r.keywords = ["true", "false", "null"]
        case .yaml:
            r.lineComments = ["#"]
            r.quotes = ["\"", "'"]
            r.keywords = ["true", "false", "null", "yes", "no", "on", "off", "True", "False", "Null", "~"]
        case .bash, .diff:
            break
        }
        return r
    }
}

private struct CodeScanner {
    let s: [Unicode.Scalar]
    let language: CodeLanguage
    let rules: Rules
    private var out: SpanBuilder
    private var i = 0
    /// The identifier before this token, past whitespace: `fn`/`func`/`def`/`function`
    /// make the next name a function's.
    private var previousWord = ""
    private static let definers: Set<String> = ["fn", "func", "def", "function"]

    init(s: [Unicode.Scalar], language: CodeLanguage, rules: Rules) {
        self.s = s
        self.language = language
        self.rules = rules
        out = SpanBuilder(s)
    }

    mutating func run() -> [CodeSpan] {
        while i < s.count {
            let start = i
            let c = s[i]
            var word: String?
            if language == .yaml, let end = yamlKeyEnd() {
                out.add(start, end, .function)
                i = end
            } else if let end = commentEnd() {
                out.add(start, end, .comment)
                i = end
            } else if let end = stringEnd() {
                // A JSON key (a string before its colon) in the function colour, as omp draws it.
                out.add(start, end, language == .json && nextNonSpace(from: end) == ":" ? .function : .string)
                i = end
            } else if c.isDigit, !(start > 0 && (s[start - 1].isIdentifierPart || s[start - 1] == "$")) {
                i = numberEnd(s, from: start)
                out.add(start, i, .number)
            } else if c.isIdentifierStart || (rules.dollarIdentifiers && c == "$") {
                i += 1
                while i < s.count, s[i].isIdentifierPart || (rules.dollarIdentifiers && s[i] == "$") { i += 1 }
                var view = String.UnicodeScalarView()
                view.append(contentsOf: s[start..<i])
                let name = String(view)
                out.add(start, i, identifierKind(name, start, i))
                word = name
            } else if rules.atAttributes, c == "@", i + 1 < s.count, s[i + 1].isIdentifierStart {
                i += 1
                while i < s.count, s[i].isIdentifierPart || s[i] == "." { i += 1 }
                out.add(start, i, .keyword)
            } else if rules.hashDirectives, c == "#", i + 1 < s.count, s[i + 1].isAsciiLetter {
                i += 1
                while i < s.count, s[i].isIdentifierPart { i += 1 }
                out.add(start, i, .keyword)
            } else if language == .yaml, c == "~", isStandaloneYamlNull(at: start) {
                i += 1
                out.add(start, i, .keyword)
            } else {
                i += 1
                // JSON and YAML punctuation stays plain: `-` in `dark-tokyo-night` is text.
                let plainPunctuation = language == .json || language == .yaml
                out.add(start, i, !plainPunctuation && operatorScalars.contains(c) ? .op : nil)
            }
            if let word {
                previousWord = word
            } else if !c.isSpace, c != "\n" {
                previousWord = ""
            }
        }
        return out.finish()
    }

    private func commentEnd() -> Int? {
        for prefix in rules.lineComments where matches(s, prefix, at: i) {
            // YAML's `#` starts a comment only at a word's start (`a#b` is a value).
            if language == .yaml, i > 0, !s[i - 1].isSpace, s[i - 1] != "\n" { continue }
            return lineEnd(s, from: i)
        }
        if let block = rules.blockComment, matches(s, block.open, at: i) {
            var j = i + block.open.unicodeScalars.count
            while j < s.count {
                if matches(s, block.close, at: j) { return j + block.close.unicodeScalars.count }
                j += 1
            }
            return s.count
        }
        return nil
    }

    private func stringEnd() -> Int? {
        for triple in rules.tripleQuotes where matches(s, triple, at: i) {
            let width = triple.unicodeScalars.count
            var j = i + width
            while j < s.count {
                if s[j] == "\\" { j += 2; continue }
                if matches(s, triple, at: j) { return j + width }
                j += 1
            }
            return s.count
        }
        let c = s[i]
        guard rules.quotes.contains(c) || (rules.rustChars && c == "'") else { return nil }
        if rules.rustChars, c == "'" {
            // `'x'` and `'\n'` are characters; `'a` (a lifetime) is not a string.
            if i + 2 < s.count, s[i + 1] != "\\", s[i + 2] == "'" { return i + 3 }
            if i + 1 < s.count, s[i + 1] == "\\" {
                var j = i + 2
                while j < s.count, j < i + 12, s[j] != "'", s[j] != "\n" { j += 1 }
                if j < s.count, s[j] == "'" { return j + 1 }
            }
            return nil
        }
        // An apostrophe inside a word (`don't` in YAML prose) does not open a string.
        if language == .yaml, c == "'", i > 0, s[i - 1].isIdentifierPart { return nil }
        return quotedEnd(s, from: i, quote: c, escapes: true,
                         multiline: rules.multilineQuotes.contains(c))
    }

    private func identifierKind(_ word: String, _ start: Int, _ end: Int) -> CodeTokenKind? {
        if rules.keywords.contains(word) { return .keyword }
        if language == .json || language == .yaml { return nil }
        if Self.definers.contains(previousWord) { return .function }
        let next = nextNonSpace(from: end)
        if next == "(" { return .function }
        // Rust macros: `println!(`, `vec![`.
        if language == .rust, next == "!", let after = nextNonSpace(from: indexOfNextNonSpace(from: end) + 1),
           after == "(" || after == "[" || after == "{" {
            return .function
        }
        // Swift trailing closures on a method: `rows.first { … }`.
        if language == .swift, next == "{", start > 0, s[start - 1] == "." { return .function }
        if rules.types.contains(word) { return .type }
        if rules.capitalisedTypes, s[start].isUppercaseLetter { return .type }
        return nil
    }

    private func indexOfNextNonSpace(from index: Int) -> Int {
        var j = index
        while j < s.count, s[j].isSpace { j += 1 }
        return j
    }

    private func nextNonSpace(from index: Int) -> Unicode.Scalar? {
        let j = indexOfNextNonSpace(from: index)
        return j < s.count ? s[j] : nil
    }

    /// A YAML key: at a line's start (after indentation and list dashes), text up to a
    /// colon that ends the line or is followed by a space.
    private func yamlKeyEnd() -> Int? {
        guard s[i] != "#", s[i] != "-", !s[i].isSpace, s[i] != "\n" else { return nil }
        var j = i - 1
        while j >= 0, s[j].isSpace || s[j] == "-" { j -= 1 }
        guard j < 0 || s[j] == "\n" else { return nil }
        var k = i
        while k < s.count, s[k] != "\n", s[k] != "#" {
            if s[k] == ":", k + 1 == s.count || s[k + 1].isSpace || s[k + 1] == "\n" {
                return k > i ? k : nil
            }
            if s[k] == "\"" || s[k] == "'" || s[k] == "{" || s[k] == "[" { return nil }
            k += 1
        }
        return nil
    }

    private func isStandaloneYamlNull(at index: Int) -> Bool {
        let before = index == 0 || s[index - 1].isSpace || s[index - 1] == "\n"
        let after = index + 1 == s.count || s[index + 1].isSpace || s[index + 1] == "\n"
        return before && after
    }
}

// MARK: - Bash

/// Shell: the first word of each command is drawn as a function (`git`, `./build.sh`),
/// shell words (`if`, `then`, `done`) as keywords, `$NAME` and `${…}` as types.
private struct BashScanner {
    let s: [Unicode.Scalar]
    private var out: SpanBuilder
    private var i = 0
    /// The next word starts a command.
    private var commandStart = true

    private static let keywords: Set<String> = [
        "if", "then", "else", "elif", "fi", "case", "esac", "for", "while", "until", "do", "done", "in",
        "function", "select", "time", "return", "local", "export", "declare", "readonly", "unset",
        "break", "continue", "exit",
    ]
    /// Ends a word.
    private static let breaks: Set<Unicode.Scalar> = [" ", "\t", "\n", ";", "|", "&", "(", ")", "<", ">", "\"", "'", "`", "$", "{", "}"]
    /// `$@`, `$?`, `$$`: the shell's one-character parameters.
    private static let specialParameters: Set<Unicode.Scalar> = ["@", "*", "#", "?", "$", "!", "-"]

    init(s: [Unicode.Scalar]) {
        self.s = s
        out = SpanBuilder(s)
    }

    mutating func run() -> [CodeSpan] {
        while i < s.count {
            let start = i
            let c = s[i]
            switch c {
            case " ", "\t":
                i += 1
                out.add(start, i, nil)
            case "\n", ";", "|", "&", "(", "{", "`":
                i += 1
                out.add(start, i, c == ";" || c == "|" || c == "&" ? .op : nil)
                commandStart = true
            case ")", "}", "<", ">":
                i += 1
                out.add(start, i, c == "<" || c == ">" ? .op : nil)
            case "#" where start == 0 || Self.breaks.contains(s[start - 1]):
                i = lineEnd(s, from: start)
                out.add(start, i, .comment)
            case "\"":
                i = quotedEnd(s, from: start, quote: "\"", escapes: true, multiline: true)
                out.add(start, i, .string)
                commandStart = false
            case "'":
                i = quotedEnd(s, from: start, quote: "'", escapes: false, multiline: true)
                out.add(start, i, .string)
                commandStart = false
            case "$":
                variable()
            default:
                word()
            }
        }
        return out.finish()
    }

    private mutating func variable() {
        let start = i
        i += 1
        guard i < s.count else { return out.add(start, i, nil) }
        if s[i] == "(" {
            // `$(…)`: a command inside.
            i += 1
            out.add(start, i, .op)
            commandStart = true
            return
        }
        if s[i] == "{" {
            while i < s.count, s[i] != "}", s[i] != "\n" { i += 1 }
            if i < s.count, s[i] == "}" { i += 1 }
        } else if s[i].isIdentifierStart {
            while i < s.count, s[i].isIdentifierPart { i += 1 }
        } else if s[i].isDigit || Self.specialParameters.contains(s[i]) {
            i += 1
        }
        out.add(start, i, i > start + 1 ? .type : nil)
        commandStart = false
    }

    private mutating func word() {
        let start = i
        while i < s.count, !Self.breaks.contains(s[i]) { i += 1 }
        if i == start { i += 1 }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: s[start..<i])
        let word = String(view)
        if Self.keywords.contains(word), commandStart || word == "in" {
            out.add(start, i, .keyword)
            commandStart = !["fi", "done", "esac", "in"].contains(word)
            return
        }
        if commandStart {
            if let equals = word.firstIndex(of: "="), equals != word.startIndex {
                // `NAME=value cmd`: an assignment, the command comes after it.
                out.add(start, i, nil)
                return
            }
            commandStart = false
            out.add(start, i, word.allSatisfy({ $0 == "[" || $0 == "]" }) ? .op : .function)
            return
        }
        if word.unicodeScalars.allSatisfy(\.isDigit) {
            out.add(start, i, .number)
        } else {
            out.add(start, i, nil)
        }
    }
}

// MARK: - Diff

/// A unified diff, line by line: added and removed lines, hunk headers, file headers.
private struct DiffScanner {
    let s: [Unicode.Scalar]

    func run() -> [CodeSpan] {
        var out = SpanBuilder(s)
        var i = 0
        while i < s.count {
            let end = lineEnd(s, from: i)
            let kind: CodeTokenKind?
            if matches(s, "+++", at: i) || matches(s, "---", at: i) {
                kind = .keyword
            } else if matches(s, "@@", at: i) {
                kind = .function
            } else if matches(s, "diff ", at: i) || matches(s, "index ", at: i) {
                kind = .comment
            } else if i < end, s[i] == "+" {
                kind = .inserted
            } else if i < end, s[i] == "-" {
                kind = .deleted
            } else {
                kind = nil
            }
            out.add(i, end, kind)
            if end < s.count { out.add(end, end + 1, nil) }
            i = end + 1
        }
        return out.finish()
    }
}
