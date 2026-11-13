import Foundation

// Syntax for source files and scripts (shell, Python, JavaScript/TypeScript, Swift, Go, Rust, C-family, …), markdown
// and diffs, without drawing: shared by the Mac and Windows like the config formats in Syntax.swift. Each language is
// one regex whose alternatives are tried left to right at each place in the text, so whatever starts first claims its
// text (a `#` inside a string stays part of the string), and a plain word is taken whole so a keyword is never found
// inside an identifier.

enum CodeLanguage: String, CaseIterable {
    case shell, python, javascript, swift, go, rust, c, java, kotlin, scala, groovy, csharp, ruby, php, lua, sql, r, perl,
         powershell, batch, dart, terraform, toml, ini, dockerfile, makefile, css, markdown, diff

    /// From VS Code's language id (see VSCodeLanguages); nil for the ones colored elsewhere or not at all.
    init?(vscodeId id: String) {
        switch id {
        case "shellscript": self = .shell
        case "python": self = .python
        case "javascript", "javascriptreact", "typescript", "typescriptreact", "coffeescript": self = .javascript
        case "swift": self = .swift
        case "go": self = .go
        case "rust": self = .rust
        case "c", "cpp", "objective-c", "objective-cpp", "cuda-cpp", "hlsl", "shaderlab": self = .c
        case "java": self = .java
        case "kotlin": self = .kotlin
        case "scala": self = .scala
        case "groovy": self = .groovy
        case "csharp": self = .csharp
        case "ruby": self = .ruby
        case "php": self = .php
        case "lua": self = .lua
        case "sql": self = .sql
        case "r": self = .r
        case "perl", "raku": self = .perl
        case "powershell": self = .powershell
        case "bat": self = .batch
        case "dart": self = .dart
        case "terraform": self = .terraform
        case "toml": self = .toml
        case "ini", "properties", "dotenv", "ignore": self = .ini
        case "dockerfile": self = .dockerfile
        case "makefile": self = .makefile
        case "css", "scss", "less": self = .css
        case "markdown", "skill", "instructions", "prompt", "chatagent": self = .markdown
        case "diff": self = .diff
        default: return nil
        }
    }

    /// From a script's `#!` line, for files without an extension that says.
    init?(shebang line: Substring) {
        guard line.hasPrefix("#!") else { return nil }
        // The interpreter: the last part of its path, or what `env` runs.
        let words = line.dropFirst(2).split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard var exe = words.first.map({ String($0.split(separator: "/").last ?? $0) }) else { return nil }
        if exe == "env" { exe = words.dropFirst().first { !$0.hasPrefix("-") }.map(String.init) ?? "" }
        let name = exe.trimmingCharacters(in: CharacterSet(charactersIn: "0123456789.")).lowercased()
        switch name {
        case "sh", "bash", "zsh", "ksh", "dash", "ash", "fish", "mksh", "yash": self = .shell
        case "python", "pypy": self = .python
        case "node", "nodejs", "deno", "bun", "ts-node", "tsx": self = .javascript
        case "ruby": self = .ruby
        case "perl": self = .perl
        case "php": self = .php
        case "lua", "luajit": self = .lua
        case "rscript": self = .r
        case "pwsh", "powershell": self = .powershell
        case "swift": self = .swift
        case "groovy": self = .groovy
        case "make", "gmake": self = .makefile
        default: return nil
        }
    }

    /// Its compiled grammar (built on first use: some are long).
    var grammar: CodeGrammar {
        CodeGrammar.lock.lock()
        defer { CodeGrammar.lock.unlock() }
        if let g = CodeGrammar.cache[self] { return g }
        let g = CodeGrammar.build(self)
        CodeGrammar.cache[self] = g
        return g
    }
}

/// One language's regex, and what each of its capture groups is (nil: a group that's only there to match, such as a
/// heredoc's closing word).
struct CodeGrammar {
    let regex: NSRegularExpression
    let kinds: [SyntaxToken?]
    /// Grammars run again inside the tokens of a kind, their tokens painted over it (an ini value's `${…}`).
    var nested: [SyntaxToken: CodeGrammar] = [:]

    fileprivate static let lock = NSLock()
    fileprivate static var cache: [CodeLanguage: CodeGrammar] = [:]

    /// Each token in `text` (UTF-16 ranges), in order.
    func tokens(in text: String, range whole: NSRange, into out: inout [(range: NSRange, token: SyntaxToken)]) {
        // A loop over the matches, not enumerateMatches: its closure is escaping in Windows' Foundation, so it can't
        // add to `out`.
        for m in regex.matches(in: text, range: whole) {
            for (i, k) in kinds.enumerated() {
                guard let k else { continue }
                let r = m.range(at: i + 1)
                if r.location != NSNotFound, r.length > 0 {
                    out.append((r, k))
                    nested[k]?.tokens(in: text, range: r, into: &out)
                }
            }
        }
    }

    /// Alternatives in order, each a pattern with exactly as many capture groups as it has kinds.
    private struct Rules {
        var parts: [(String, [SyntaxToken?])] = []
        mutating func add(_ pattern: String, _ kinds: SyntaxToken?...) { parts.append((pattern, kinds)) }
        /// A whole-word list (`caseInsensitive` for SQL, batch, PowerShell…). Not after a `.`: `obj.default` is a
        /// property, not the keyword.
        mutating func words(_ list: [String], _ kind: SyntaxToken, caseInsensitive: Bool = false) {
            guard !list.isEmpty else { return }
            let alt = list.sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
            parts.append(("(?<![\\w$.])\(caseInsensitive ? "(?i:" : "(?:")\(alt))(?!\\w)", [kind]))
        }
        /// Each part is wrapped in a group of its own (its first kind); its inner groups, in order, take the rest, and
        /// any it has beyond those (named ones, for a heredoc's closing word) are only there to match.
        func compile() -> CodeGrammar {
            var kinds: [SyntaxToken?] = []
            for (pattern, k) in parts {
                let inner = (try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]))?.numberOfCaptureGroups ?? 0
                kinds.append(k.first ?? nil)
                for i in 0..<inner { kinds.append(i + 1 < k.count ? k[i + 1] : nil) }
            }
            let pattern = parts.map { "(" + $0.0 + ")" }.joined(separator: "|")
            let regex = (try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]))
                ?? (try! NSRegularExpression(pattern: "(?!)"))
            return CodeGrammar(regex: regex, kinds: kinds)
        }
    }

    // MARK: Shared pieces

    private static let dq = #""(?:[^"\\\n]|\\.)*""#
    private static let sq = #"'(?:[^'\\\n]|\\.)*'"#
    private static let backtick = #"`(?:[^`\\]|\\.)*`"#
    private static let cChar = #"'(?:\\(?:x[0-9a-fA-F]+|u\{?[0-9a-fA-F]+\}?|[0-7]{1,3}|.)|[^'\\\n])'"#
    private static let cComment = #"//[^\n]*|/\*[\s\S]*?\*/"#
    private static let hashComment = #"#[^\n]*"#
    private static let number = #"\b(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|0[oO][0-7_]+|\d[\d_]*(?:\.\d[\d_]*)?(?:[eE][+-]?\d+)?)(?:[a-zA-Z]\w*)?\b|(?<![\w.])\.\d[\d_]*(?:[eE][+-]?\d+)?\b"#
    private static let call = #"\b[A-Za-z_]\w*(?=[ \t]*\()"#
    private static let capitalType = #"\b_?[A-Z][a-z0-9]\w*\b"#
    /// Any other word, taken whole so nothing above matches part of it.
    private static let word = #"\b\w+\b"#

    /// Inside an ini / .properties value: a number or true/false only when it's the whole value (`server.port=8080`,
    /// `enabled = true`, `timeout=30s`), and anywhere in it `${…}` / `$VAR` / `%(name)s` / `@maven.property@`
    /// placeholders, `\` escapes, and a `\` that carries the value onto the next line.
    private static let iniValue: CodeGrammar = {
        var r = Rules()
        r.add(#"\A[ \t]*-?(?:\d+(?:\.\d+)?|\.\d+)(?:[A-Za-z%]{1,3})?\s*\z"#, .number)
        r.add(#"(?i:\A[ \t]*(?:true|false|yes|no|on|off|null|none)\s*\z)"#, .literal)
        r.add(#"\$\{[^}\n]*\}|\$[A-Za-z_]\w*|%\([\w.]+\)s|@[A-Za-z][\w.-]*@"#, .variable)
        r.add(#"\\(?=\r?\n)"#, .punctuation)
        r.add(#"\\(?:u[0-9a-fA-F]{4}|.)"#, .entity)
        return r.compile()
    }()

    /// The usual order: comments, strings, then `extra` (language specifics), numbers, keywords, literals, types,
    /// calls, capitalized names as types, and any other word.
    private static func clike(comments: String = cComment, strings: [String], extra: (inout Rules) -> Void = { _ in },
                              definitions: (functions: [String], types: [String]) = ([], []),
                              keywords: [String], literals: [String], variables: [String] = [], types: [String] = [],
                              capitalTypes: Bool = true, caseInsensitive: Bool = false) -> CodeGrammar {
        var r = Rules()
        r.add(comments, .comment)
        r.add(strings.joined(separator: "|"), .string)
        extra(&r)
        r.add(number, .number)
        // `def name`, `class Name`: the name's what's being defined.
        if !definitions.functions.isEmpty {
            r.add("\\b(\(definitions.functions.joined(separator: "|")))[ \\t]+([A-Za-z_]\\w*)", nil, .keyword, .function)
        }
        if !definitions.types.isEmpty {
            r.add("\\b(\(definitions.types.joined(separator: "|")))[ \\t]+([A-Za-z_]\\w*)", nil, .keyword, .type)
        }
        r.words(keywords, .keyword, caseInsensitive: caseInsensitive)
        r.words(literals, .literal, caseInsensitive: caseInsensitive)
        r.words(variables, .variable)
        r.words(types, .type, caseInsensitive: caseInsensitive)
        r.add(call, .function)
        if capitalTypes { r.add(capitalType, .type) }
        r.add(word, nil)
        return r.compile()
    }

    // MARK: Languages

    fileprivate static func build(_ language: CodeLanguage) -> CodeGrammar {
        switch language {
        case .shell:
            var r = Rules()
            r.add(#"(?:^|(?<=[\s;|&(]))#[^\n]*"#, .comment)
            // A heredoc, whole, as a string.
            r.add(#"<<-?[ \t]*(?<hq>['"]?)(?<ht>[A-Za-z_]\w*)\k<hq>[^\n]*\n[\s\S]*?^[ \t]*\k<ht>$"#, .string, nil, nil)
            r.add(#""(?:[^"\\]|\\[\s\S])*"|'[^']*'|\$'(?:[^'\\]|\\.)*'"#, .string)
            r.add(#"\$\{[^}\n]*\}|\$[A-Za-z_]\w*|\$[0-9@#?*!$-]"#, .variable)
            r.add(#"(?<=[\s=])--?[A-Za-z][\w-]*"#, .attribute)
            r.add(number, .number)
            r.add(#"\b(function)[ \t]+([A-Za-z_][\w-]*)"#, nil, .keyword, .function)
            r.words(["if", "then", "else", "elif", "fi", "case", "esac", "for", "select", "while", "until", "do", "done", "in",
                     "function", "time", "coproc", "return", "exit", "break", "continue", "local", "export", "readonly",
                     "declare", "typeset", "unset", "shift", "source", "alias", "unalias", "trap", "eval", "exec", "set"], .keyword)
            r.words(["true", "false"], .literal)
            r.words(["echo", "printf", "cd", "pwd", "read", "test", "pushd", "popd", "kill", "wait", "jobs", "bg", "fg", "umask",
                     "ulimit", "getopts", "hash", "type", "command", "builtin", "let", "mapfile", "readarray", "dirs", "disown",
                     "history", "sudo"], .function)
            r.add(#"\b[A-Za-z_][\w-]*(?=[ \t]*\(\))"#, .function)
            r.add(word, nil)
            return r.compile()

        case .python:
            return clike(comments: hashComment,
                         strings: [#"(?:\b[rRbBuUfF]{1,2})?(?:"""[\s\S]*?"""|'''[\s\S]*?'''|"(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*')"#],
                         extra: { $0.add(#"^[ \t]*@[A-Za-z_][\w.]*"#, .attribute) },
                         definitions: (["def"], ["class"]),
                         keywords: ["and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else",
                                    "except", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "nonlocal",
                                    "not", "or", "pass", "raise", "return", "try", "while", "with", "yield", "match", "case"],
                         literals: ["True", "False", "None", "NotImplemented", "Ellipsis"],
                         variables: ["self", "cls"],
                         types: ["int", "float", "str", "bool", "list", "dict", "set", "tuple", "bytes", "bytearray", "object",
                                 "complex", "frozenset", "type"])

        case .javascript:
            return clike(strings: [dq, sq, backtick],
                         extra: { $0.add(#"(?<![\w$])@[A-Za-z_][\w.]*"#, .attribute) },
                         definitions: (["function"], ["class", "interface", "enum", "type", "namespace"]),
                         keywords: ["break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do",
                                    "else", "export", "extends", "finally", "for", "from", "function", "if", "import", "in",
                                    "instanceof", "let", "new", "of", "return", "super", "switch", "throw", "try", "typeof",
                                    "var", "void", "while", "with", "yield", "async", "await", "static", "get", "set", "as",
                                    "implements", "interface", "package", "private", "protected", "public", "type", "enum",
                                    "declare", "namespace", "module", "abstract", "readonly", "keyof", "infer", "is", "satisfies",
                                    "override", "unique"],
                         literals: ["true", "false", "null", "undefined", "NaN", "Infinity"],
                         variables: ["this"],
                         types: ["string", "number", "boolean", "any", "unknown", "never", "object", "symbol", "bigint"])

        case .swift:
            return clike(strings: [##"#*"""[\s\S]*?"""#*"##, ##"#+"[^\n]*?"#+"##, dq],
                         extra: { $0.add(#"(?<![\w.])[@#][A-Za-z_]\w*"#, .attribute) },
                         definitions: (["func"], ["class", "struct", "enum", "protocol", "extension", "actor", "typealias"]),
                         keywords: ["associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func", "import", "init",
                                    "inout", "internal", "let", "open", "operator", "private", "precedencegroup", "protocol",
                                    "public", "rethrows", "static", "struct", "subscript", "typealias", "var", "break", "case",
                                    "catch", "continue", "default", "defer", "do", "else", "fallthrough", "for", "guard", "if",
                                    "in", "repeat", "return", "throw", "switch", "where", "while", "as", "is", "try", "await",
                                    "async", "throws", "some", "any", "super", "convenience", "dynamic", "final", "indirect",
                                    "lazy", "mutating", "nonmutating", "optional", "override", "required", "unowned", "weak",
                                    "willSet", "didSet", "get", "set", "nonisolated", "actor", "macro", "package", "consuming",
                                    "borrowing", "sending"],
                         literals: ["true", "false", "nil"],
                         variables: ["self", "Self"])

        case .go:
            return clike(strings: [dq, backtick, cChar],
                         definitions: (["func"], ["type"]),
                         keywords: ["break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "for",
                                    "func", "go", "goto", "if", "import", "interface", "map", "package", "range", "return",
                                    "select", "struct", "switch", "type", "var"],
                         literals: ["true", "false", "nil", "iota"],
                         types: ["bool", "byte", "complex64", "complex128", "error", "float32", "float64", "int", "int8", "int16",
                                 "int32", "int64", "rune", "string", "uint", "uint8", "uint16", "uint32", "uint64", "uintptr", "any"])

        case .rust:
            return clike(strings: [##"b?r#*"[\s\S]*?"#*"##, #"b?"(?:[^"\\]|\\[\s\S])*""#, "b?" + cChar],
                         extra: {
                             $0.add(#"#!?\[[^\]\n]*\]"#, .attribute)
                             $0.add(#"\b[A-Za-z_]\w*!(?=[ \t]*[(\[{])"#, .function)
                         },
                         definitions: (["fn"], ["struct", "enum", "trait", "type", "union", "mod"]),
                         keywords: ["as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern",
                                    "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref",
                                    "return", "static", "struct", "super", "trait", "type", "unsafe", "use", "where", "while",
                                    "macro_rules", "union", "yield"],
                         literals: ["true", "false", "None", "Some", "Ok", "Err"],
                         variables: ["self", "Self"],
                         types: ["i8", "i16", "i32", "i64", "i128", "isize", "u8", "u16", "u32", "u64", "u128", "usize", "f32",
                                 "f64", "bool", "char", "str"])

        case .c:
            return clike(strings: [#"(?:\b(?:u8|u|U|L)|@)?"(?:[^"\\\n]|\\.)*""#, cChar],
                         extra: {
                             $0.add(#"^([ \t]*#[ \t]*\w+)(?:[ \t]*(<[^>\n]*>))?"#, nil, .keyword, .string)
                             $0.add(#"@(?:interface|implementation|end|protocol|property|synthesize|selector|class|autoreleasepool|try|catch|finally|optional|required|import)\b"#, .keyword)
                         },
                         definitions: ([], ["class", "struct", "enum", "union", "namespace", "typedef"]),
                         keywords: ["auto", "break", "case", "catch", "class", "const", "constexpr", "consteval", "constinit",
                                    "continue", "decltype", "default", "delete", "do", "else", "enum", "explicit", "export",
                                    "extern", "final", "for", "friend", "goto", "if", "inline", "mutable", "namespace", "new",
                                    "noexcept", "operator", "override", "private", "protected", "public", "register",
                                    "reinterpret_cast", "static_cast", "dynamic_cast", "const_cast", "return", "sizeof", "static",
                                    "static_assert", "struct", "switch", "template", "throw", "try", "typedef", "typename",
                                    "union", "using", "virtual", "volatile", "while", "co_await", "co_return", "co_yield",
                                    "concept", "requires", "alignas", "alignof", "restrict", "__kernel", "__global__", "__device__"],
                         literals: ["true", "false", "NULL", "nullptr", "nil", "Nil", "YES", "NO"],
                         variables: ["this", "self"],
                         types: ["void", "char", "short", "int", "long", "float", "double", "signed", "unsigned", "bool", "_Bool",
                                 "size_t", "ssize_t", "ptrdiff_t", "int8_t", "int16_t", "int32_t", "int64_t", "uint8_t",
                                 "uint16_t", "uint32_t", "uint64_t", "intptr_t", "uintptr_t", "wchar_t", "char8_t",
                                 "char16_t", "char32_t", "id", "instancetype", "BOOL", "SEL"])

        case .java, .groovy:
            var keywords = ["abstract", "assert", "break", "case", "catch", "class", "continue", "default", "do", "else", "enum",
                            "extends", "final", "finally", "for", "if", "implements", "import", "instanceof", "interface", "native",
                            "new", "package", "private", "protected", "public", "return", "static", "strictfp", "super", "switch",
                            "synchronized", "throw", "throws", "transient", "try", "volatile", "while", "var", "record", "sealed",
                            "permits", "yield"]
            if language == .groovy { keywords += ["def", "as", "in", "trait"] }
            return clike(strings: language == .groovy ? [#"'''[\s\S]*?'''"#, #""""[\s\S]*?""""#, dq, sq, #"/(?![/*\s])(?:[^/\\\n]|\\.)+/"#]
                                                     : [#""""[\s\S]*?""""#, dq, cChar],
                         extra: { $0.add(#"(?<![\w.])@[A-Za-z_][\w.]*"#, .attribute) },
                         definitions: ([], ["class", "interface", "enum", "record"]),
                         keywords: keywords,
                         literals: ["true", "false", "null"],
                         variables: ["this"],
                         types: ["boolean", "byte", "char", "double", "float", "int", "long", "short", "void"])

        case .kotlin:
            return clike(strings: [#""""[\s\S]*?""""#, dq, cChar],
                         extra: { $0.add(#"(?<![\w.])@[A-Za-z_][\w.:]*"#, .attribute) },
                         definitions: (["fun"], ["class", "interface", "object", "typealias"]),
                         keywords: ["as", "break", "class", "continue", "do", "else", "for", "fun", "if", "in", "interface", "is",
                                    "object", "package", "return", "super", "throw", "try", "typealias", "val", "var", "when",
                                    "while", "by", "catch", "constructor", "finally", "get", "import", "init", "set", "where",
                                    "actual", "abstract", "annotation", "companion", "const", "crossinline", "data", "enum",
                                    "expect", "external", "final", "infix", "inline", "inner", "internal", "lateinit", "noinline",
                                    "open", "operator", "out", "override", "private", "protected", "public", "reified", "sealed",
                                    "suspend", "tailrec", "vararg", "value"],
                         literals: ["true", "false", "null"],
                         variables: ["this", "it"])

        case .scala:
            return clike(strings: [#""""[\s\S]*?""""#, #"\b[sfr]?"(?:[^"\\\n]|\\.)*""#, cChar],
                         extra: { $0.add(#"(?<![\w.])@[A-Za-z_][\w.]*"#, .attribute) },
                         definitions: (["def"], ["class", "trait", "object", "type", "enum"]),
                         keywords: ["abstract", "case", "catch", "class", "def", "do", "else", "extends", "final", "finally", "for",
                                    "forSome", "if", "implicit", "import", "lazy", "match", "new", "object", "override", "package",
                                    "private", "protected", "return", "sealed", "super", "throw", "trait", "try", "type", "val",
                                    "var", "while", "with", "yield", "given", "using", "enum", "then", "export", "extension"],
                         literals: ["true", "false", "null"],
                         variables: ["this"])

        case .csharp:
            return clike(strings: [#"\$?@"(?:[^"]|"")*""#, #"""""[\s\S]*?""""#, #"\$?"(?:[^"\\\n]|\\.)*""#, cChar],
                         extra: { $0.add(#"^[ \t]*#[ \t]*\w+"#, .keyword) },
                         definitions: ([], ["class", "struct", "interface", "enum", "record", "namespace"]),
                         keywords: ["abstract", "as", "base", "break", "case", "catch", "checked", "class", "const", "continue",
                                    "default", "delegate", "do", "else", "enum", "event", "explicit", "extern", "finally", "fixed",
                                    "for", "foreach", "goto", "if", "implicit", "in", "interface", "internal", "is", "lock",
                                    "namespace", "new", "operator", "out", "override", "params", "private", "protected", "public",
                                    "readonly", "ref", "return", "sealed", "sizeof", "stackalloc", "static", "struct", "switch",
                                    "throw", "try", "typeof", "unchecked", "unsafe", "using", "virtual", "volatile", "while",
                                    "async", "await", "dynamic", "get", "set", "init", "var", "when", "where", "yield", "record",
                                    "required", "with", "nameof", "partial", "global", "from", "select", "orderby", "group",
                                    "into", "join", "let", "on", "equals", "by", "ascending", "descending"],
                         literals: ["true", "false", "null"],
                         variables: ["this", "value"],
                         types: ["bool", "byte", "char", "decimal", "double", "float", "int", "long", "object", "sbyte", "short",
                                 "string", "uint", "ulong", "ushort", "void", "nint", "nuint"])

        case .ruby:
            return clike(comments: #"^=begin\b[\s\S]*?^=end\b[^\n]*|#[^\n]*"#,
                         strings: [dq, sq, backtick, #"%[qQwWiI]?\{[^}]*\}"#, #"%[qQwWiI]?\([^)]*\)"#],
                         extra: {
                             $0.add(#"@{1,2}[A-Za-z_]\w*|\$[A-Za-z_]\w*"#, .variable)
                             $0.add(#"(?<![:\w]):[A-Za-z_]\w*[?!]?|\b[A-Za-z_]\w*:(?=[ \t])"#, .literal)
                         },
                         definitions: (["def"], ["class", "module"]),
                         keywords: ["BEGIN", "END", "alias", "and", "begin", "break", "case", "class", "def", "defined?", "do",
                                    "else", "elsif", "end", "ensure", "for", "if", "in", "module", "next", "not", "or", "redo",
                                    "rescue", "retry", "return", "super", "then", "undef", "unless", "until", "when", "while",
                                    "yield", "require", "require_relative", "attr_accessor", "attr_reader", "attr_writer",
                                    "include", "extend", "private", "protected", "public", "raise", "lambda", "proc"],
                         literals: ["true", "false", "nil"],
                         variables: ["self"])

        case .php:
            return clike(comments: #"//[^\n]*|#(?!\[)[^\n]*|/\*[\s\S]*?\*/"#,
                         strings: [#""(?:[^"\\]|\\[\s\S])*""#, #"'(?:[^'\\]|\\[\s\S])*'"#],
                         extra: {
                             $0.add(#"<\?(?:php|=)?|\?>"#, .tag)
                             $0.add(#"\$[A-Za-z_]\w*"#, .variable)
                             $0.add(#"#\[[^\]\n]*\]"#, .attribute)
                         },
                         definitions: (["function", "fn"], ["class", "interface", "trait", "enum"]),
                         keywords: ["abstract", "and", "as", "break", "callable", "case", "catch", "class", "clone", "const",
                                    "continue", "declare", "default", "do", "echo", "else", "elseif", "empty", "enddeclare",
                                    "endfor", "endforeach", "endif", "endswitch", "endwhile", "enum", "extends", "final",
                                    "finally", "fn", "for", "foreach", "function", "global", "goto", "if", "implements",
                                    "include", "include_once", "instanceof", "insteadof", "interface", "isset", "list", "match",
                                    "namespace", "new", "or", "print", "private", "protected", "public", "readonly", "require",
                                    "require_once", "return", "static", "switch", "throw", "trait", "try", "unset", "use", "var",
                                    "while", "xor", "yield"],
                         literals: ["true", "false", "null", "TRUE", "FALSE", "NULL"],
                         types: ["int", "float", "string", "bool", "array", "object", "mixed", "void", "never", "iterable"])

        case .lua:
            var r = Rules()
            r.add(#"--\[(?<lc>=*)\[[\s\S]*?\]\k<lc>\]|--[^\n]*"#, .comment, nil)
            r.add(#"\[(?<ls>=*)\[[\s\S]*?\]\k<ls>\]|"(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*'"#, .string, nil)
            r.add(number, .number)
            r.add(#"\b(function)[ \t]+([A-Za-z_][\w.:]*)"#, nil, .keyword, .function)
            r.words(["and", "break", "do", "else", "elseif", "end", "for", "function", "goto", "if", "in", "local", "not", "or",
                     "repeat", "return", "then", "until", "while"], .keyword)
            r.words(["nil", "true", "false"], .literal)
            r.words(["self"], .variable)
            r.add(call, .function)
            r.add(word, nil)
            return r.compile()

        case .sql:
            return clike(comments: #"--[^\n]*|/\*[\s\S]*?\*/|#[^\n]*"#,
                         strings: [#"'(?:[^']|'')*'"#, #""(?:[^"]|"")*""#, #"`[^`\n]*`"#],
                         extra: { $0.add(#"[@:$][A-Za-z_]\w*"#, .variable) },
                         keywords: ["select", "from", "where", "and", "or", "not", "insert", "into", "values", "update", "set",
                                    "delete", "create", "table", "alter", "drop", "index", "view", "as", "join", "inner", "left",
                                    "right", "outer", "full", "cross", "on", "group", "by", "order", "having", "limit", "offset",
                                    "union", "all", "distinct", "case", "when", "then", "else", "end", "is", "like", "ilike", "in",
                                    "between", "exists", "primary", "key", "foreign", "references", "default", "unique", "check",
                                    "constraint", "begin", "commit", "rollback", "transaction", "with", "recursive", "returning",
                                    "if", "replace", "trigger", "procedure", "function", "database", "schema", "grant", "revoke",
                                    "asc", "desc", "top", "over", "partition", "using", "natural", "declare", "return", "returns",
                                    "language", "execute", "exec", "merge", "matched", "upsert", "conflict", "do", "nothing",
                                    "cascade", "temporary", "temp", "materialized", "explain", "analyze", "lateral", "window",
                                    "fetch", "next", "rows", "only", "add", "column", "rename", "to", "truncate", "sequence"],
                         literals: ["true", "false", "null"],
                         types: ["int", "integer", "bigint", "smallint", "tinyint", "varchar", "nvarchar", "char", "nchar", "text",
                                 "date", "time", "timestamp", "timestamptz", "datetime", "interval", "boolean", "bool", "decimal",
                                 "numeric", "float", "real", "double", "precision", "serial", "bigserial", "blob", "clob", "json",
                                 "jsonb", "uuid", "bytea", "varchar2", "number"],
                         capitalTypes: false, caseInsensitive: true)

        case .r:
            return clike(comments: hashComment, strings: [dq, sq, #"`[^`\n]*`"#],
                         keywords: ["if", "else", "repeat", "while", "function", "for", "in", "next", "break", "return", "library",
                                    "require", "source"],
                         literals: ["TRUE", "FALSE", "NULL", "Inf", "NaN", "NA", "NA_integer_", "NA_real_", "NA_character_", "T", "F"],
                         capitalTypes: false)

        case .perl:
            return clike(comments: #"^=[a-zA-Z][\s\S]*?^=cut\b[^\n]*|#[^\n]*"#,
                         strings: [#""(?:[^"\\]|\\[\s\S])*""#, #"'(?:[^'\\]|\\[\s\S])*'"#, backtick, #"\bq[qwx]?\{[^}]*\}"#, #"\bq[qwx]?\([^)]*\)"#],
                         extra: { $0.add(#"[$@%]\{?[A-Za-z_]\w*(?:::\w+)*\}?|\$[0-9_&!@]"#, .variable) },
                         definitions: (["sub"], ["package"]),
                         keywords: ["my", "our", "local", "sub", "if", "elsif", "else", "unless", "while", "until", "for", "foreach",
                                    "do", "last", "next", "redo", "return", "use", "no", "require", "package", "and", "or", "not",
                                    "eq", "ne", "lt", "gt", "le", "ge", "cmp", "x", "print", "printf", "die", "warn", "eval",
                                    "bless", "ref", "defined", "undef", "wantarray", "BEGIN", "END", "__END__", "__DATA__"],
                         literals: [], capitalTypes: false)

        case .powershell:
            return clike(comments: #"<#[\s\S]*?#>|#[^\n]*"#,
                         strings: [#"@"[\s\S]*?^"@"#, #"@'[\s\S]*?^'@"#, #""(?:[^"`]|`[\s\S]|"")*""#, #"'(?:[^']|'')*'"#],
                         extra: {
                             $0.add(#"\$(?:\{[^}\n]*\}|[A-Za-z_][\w:]*|[?^$_])"#, .variable)
                             $0.add(#"\[[A-Za-z_][\w.\[\]`,]*\](?=[\w$:\[\s(.]|$)"#, .type)
                             $0.add(#"(?<=\s)-[A-Za-z]\w*"#, .attribute)
                             $0.add(#"\b[A-Za-z]+-[A-Za-z]\w*\b"#, .function)
                         },
                         definitions: (["function", "filter"], ["class", "enum"]),
                         keywords: ["begin", "break", "catch", "class", "continue", "data", "define", "do", "dynamicparam", "else",
                                    "elseif", "end", "enum", "exit", "filter", "finally", "for", "foreach", "from", "function",
                                    "hidden", "if", "in", "param", "process", "return", "static", "switch", "throw", "trap", "try",
                                    "until", "using", "var", "while", "workflow", "parallel", "sequence"],
                         literals: [], capitalTypes: false, caseInsensitive: true)

        case .batch:
            var r = Rules()
            r.add(#"(?i:^[ \t]*@?rem\b[^\n]*)|^[ \t]*::[^\n]*"#, .comment)
            r.add(#""[^"\n]*""#, .string)
            r.add(#"%~?[\w$:]*%|%%~?\w|![\w:~,=-]+!"#, .variable)
            r.add(#"^[ \t]*:[A-Za-z_][\w.-]*"#, .function)
            r.add(number, .number)
            r.words(["if", "else", "for", "in", "do", "goto", "call", "set", "setlocal", "endlocal", "exit", "not", "exist",
                     "defined", "errorlevel", "echo", "shift", "pushd", "popd", "start", "cd", "chdir", "equ", "neq", "lss",
                     "leq", "gtr", "geq", "nul", "off", "on", "enabledelayedexpansion", "enableextensions", "pause", "cls",
                     "title", "type", "copy", "del", "move", "mkdir", "md", "rmdir", "rd", "ren", "where", "choice"],
                    .keyword, caseInsensitive: true)
            r.add(#"(?<=\s)/[A-Za-z?]\w*"#, .attribute)
            r.add(word, nil)
            return r.compile()

        case .dart:
            return clike(strings: [#"r?'''[\s\S]*?'''"#, #"r?"""[\s\S]*?""""#, "r?" + dq, "r?" + sq],
                         extra: { $0.add(#"(?<![\w.])@[A-Za-z_][\w.]*"#, .attribute) },
                         definitions: ([], ["class", "mixin", "enum", "extension", "typedef"]),
                         keywords: ["abstract", "as", "assert", "async", "await", "base", "break", "case", "catch", "class", "const",
                                    "continue", "covariant", "default", "deferred", "do", "dynamic", "else", "enum", "export",
                                    "extends", "extension", "external", "factory", "final", "finally", "for", "get", "hide", "if",
                                    "implements", "import", "in", "interface", "is", "late", "library", "mixin", "new", "on",
                                    "operator", "part", "required", "rethrow", "return", "sealed", "set", "show", "static",
                                    "super", "switch", "sync", "throw", "try", "typedef", "var", "when", "while", "with", "yield"],
                         literals: ["true", "false", "null"],
                         variables: ["this"],
                         types: ["int", "double", "num", "bool", "void"])

        case .terraform:
            return clike(comments: #"#[^\n]*|//[^\n]*|/\*[\s\S]*?\*/"#,
                         strings: [#"<<-?(?<tf>\w+)\n[\s\S]*?^[ \t]*\k<tf>$"#, dq],
                         extra: { $0.add(#"^[ \t]*[A-Za-z_][\w-]*(?=[ \t]*=(?!=))"#, .key) },
                         keywords: ["resource", "data", "variable", "output", "locals", "module", "provider", "terraform", "for",
                                    "in", "if", "each", "count", "dynamic", "content", "lifecycle", "depends_on", "for_each",
                                    "moved", "import", "check", "backend", "required_providers"],
                         literals: ["true", "false", "null"],
                         types: ["string", "number", "bool", "list", "map", "set", "object", "tuple", "any"],
                         capitalTypes: false)

        case .toml:
            var r = Rules()
            r.add(hashComment, .comment)
            r.add(#""""[\s\S]*?"""|'''[\s\S]*?'''|"(?:[^"\\\n]|\\.)*"|'[^'\n]*'"#, .string)
            r.add(#"^[ \t]*\[\[?[^\]\n]*\]\]?"#, .type)
            r.add(#"^[ \t]*[\w.\-]+(?=[ \t]*=)"#, .key)
            r.add(#"\b\d{4}-\d{2}-\d{2}(?:[T ]\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}:\d{2})?)?\b"#, .number)
            r.add(number, .number)
            r.words(["true", "false", "inf", "nan"], .literal)
            r.add(word, nil)
            return r.compile()

        case .ini:
            // ini, Java .properties, .env, git config: a line at a time. A setting's value is all one string (to the end
            // of the line, and on past one ending in `\` in a .properties file), so a password or a URL is never taken
            // apart into numbers and words; only what's inside it is picked out (see `iniValue`).
            var r = Rules()
            r.add(#"^[ \t]*[#;!][^\n]*"#, .comment)
            r.add(#"^[ \t]*\[[^\]\n]*\]"#, .type)
            r.add(#"^[ \t]*(export[ \t]+)?((?:[^\s=:#;!\[\\]|\\.)(?:[^=:\n\\]|\\.)*?)[ \t]*([=:])[ \t]*((?:[^\n\\]|\\(?:\r?\n|.)|\\$)*)"#,
                  nil, .keyword, .key, .punctuation, .string)
            r.add(#"[^\n]+"#, nil)
            var g = r.compile()
            g.nested[.string] = iniValue
            return g

        case .dockerfile:
            var r = Rules()
            r.add(#"^[ \t]*#[^\n]*"#, .comment)
            r.add(dq + "|" + sq, .string)
            r.add(#"\$\{[^}\n]*\}|\$[A-Za-z_]\w*"#, .variable)
            r.add(#"(?i:^[ \t]*(?:FROM|RUN|CMD|LABEL|MAINTAINER|EXPOSE|ENV|ADD|COPY|ENTRYPOINT|VOLUME|USER|WORKDIR|ARG|ONBUILD|STOPSIGNAL|HEALTHCHECK|SHELL)\b)"#, .keyword)
            r.add(#"(?i:\bAS\b)"#, .keyword)
            r.add(#"(?<=\s)--[A-Za-z][\w-]*"#, .attribute)
            r.add(number, .number)
            r.add(word, nil)
            return r.compile()

        case .makefile:
            var r = Rules()
            r.add(#"(?:^|(?<=\s))#[^\n]*"#, .comment)
            r.add(dq + "|" + sq, .string)
            r.add(#"\$\([^)\n]*\)|\$\{[^}\n]*\}|\$[@<^+?*%|]"#, .variable)
            r.add(#"^(?:ifeq|ifneq|ifdef|ifndef|else|endif|include|-include|sinclude|define|endef|export|unexport|override|vpath)\b"#, .keyword)
            r.add(#"^[ \t]*[A-Za-z_][\w.]*(?=[ \t]*(?:[:?+!]?=))"#, .key)
            r.add(#"^[^\s:#=][^:#=\n]*?(?=:(?!=))"#, .function)
            r.add(word, nil)
            return r.compile()

        case .css:
            var r = Rules()
            r.add(#"/\*[\s\S]*?\*/|(?<![:\w])//[^\n]*"#, .comment)
            r.add(dq + "|" + sq, .string)
            r.add(#"@[A-Za-z][\w-]*"#, .keyword)
            r.add(#"--[A-Za-z_][\w-]*|\$[A-Za-z_][\w-]*"#, .variable)
            r.add(#"(?:^[ \t]+|(?<=[{;])[ \t]*)-?[A-Za-z][\w-]*(?=[ \t]*:(?!:)[^{\n]*(?:;|$|\}))"#, .key)
            r.add(#"#[0-9a-fA-F]{3,8}\b"#, .number)
            r.add(#"(?<![\w-])-?(?:\d+\.?\d*|\.\d+)(?:%|[a-zA-Z]+)?"#, .number)
            r.add(#"![A-Za-z]+"#, .keyword)
            r.add(#"\b[A-Za-z][\w-]*(?=\()"#, .function)
            r.add(#"\.[A-Za-z_-][\w-]*|::?[A-Za-z-]+(?=[^;{}\n]*\{)"#, .type)
            r.add(#"[\w-]+"#, nil)
            return r.compile()

        case .markdown:
            var r = Rules()
            r.add(#"\A---\n[\s\S]*?\n---[ \t]*$"#, .comment)
            r.add(#"^[ \t]*(?:```|~~~)[^\n]*\n[\s\S]*?^[ \t]*(?:```|~~~)[ \t]*$"#, .string)
            r.add(#"^#{1,6}[ \t][^\n]*|^[^\n]+\n(?:=+|-+)[ \t]*$"#, .key)
            r.add(#"^[ \t]*>[^\n]*"#, .comment)
            r.add(#"^[ \t]*(?:-{3,}|\*{3,}|_{3,})[ \t]*$"#, .punctuation)
            r.add(#"^[ \t]*(?:[-*+]|\d+[.)])(?=[ \t])(?:[ \t]+\[[ xX]\])?"#, .keyword)
            r.add(#"`+[^`\n]+`+"#, .string)
            r.add(#"(!?\[[^\]\n]*\])(\([^)\n]*\)|\[[^\]\n]*\])"#, nil, .type, .comment)
            r.add(#"<https?://[^>\s]+>|\bhttps?://[^\s)>\]]+"#, .comment)
            r.add(#"\*\*[^*\n]+\*\*|__[^_\n]+__"#, .attribute)
            r.add(#"(?<![*\w])\*(?![*\s])[^*\n]+(?<!\s)\*(?!\*)|(?<![_\w])_(?![_\s])[^_\n]+(?<!\s)_(?![_\w])"#, .literal)
            r.add(#"~~[^~\n]+~~"#, .comment)
            r.add(#"</?[A-Za-z][^>\n]*>"#, .tag)
            r.add(#"^[ \t]*\|?(?:[ \t]*:?-+:?[ \t]*\|)+[ \t]*:?-*:?[ \t]*$|\|"#, .punctuation)
            r.add(#"\w+"#, nil)
            return r.compile()

        case .diff:
            var r = Rules()
            r.add(#"^(?:diff |index |--- |\+\+\+ |new file|deleted file|similarity|rename |old mode|new mode)[^\n]*"#, .key)
            r.add(#"^@@[^\n]*"#, .type)
            r.add(#"^\+[^\n]*"#, .string)
            r.add(#"^-[^\n]*"#, .removed)
            r.add(#"^\\[^\n]*"#, .comment)
            return r.compile()
        }
    }
}
