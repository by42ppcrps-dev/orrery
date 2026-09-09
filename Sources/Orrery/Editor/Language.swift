import Foundation

// MARK: - Tokens

/// What the highlighter can label a run of characters as. Kept deliberately small: every
/// extra kind is another colour a reader has to learn, and most languages do not earn one.
enum TokenKind: String, Sendable {
    case plain
    case keyword
    case type
    case builtin        // true / false / nil / self / print — language-provided names
    case string
    case escape         // \n inside a string
    case interpolation  // \(x) in Swift, ${x} in JS/shell
    case number
    case comment
    case docComment
    case function       // an identifier immediately followed by (
    case attribute      // @IBAction, @dataclass, #[derive]
    case directive      // #if, #include, shebang
    case key            // JSON/YAML/TOML/INI key, XML attribute name
    case tag            // <div>
    case regex
    case punctuation
    case op
    case heading        // markdown
    case emphasis
    case link
    case invalid
}

struct Token: Equatable, Sendable {
    var range: NSRange
    var kind: TokenKind
}

// MARK: - String rules

struct StringRule: Sendable, Equatable {
    var open: String
    var close: String
    /// nil means the language has no escape character inside this string form (raw strings).
    var escape: Character? = "\\"
    /// A string that may span lines. Anything else terminates at the newline.
    var multiline: Bool = false
    /// Opening delimiter for interpolation, e.g. `\(` or `${`. The closing brace is matched
    /// by counting, so nested parens inside the interpolation do not end it early.
    var interpolation: String? = nil
    /// Highlight as a regex literal rather than a string.
    var isRegex: Bool = false

    static let double = StringRule(open: "\"", close: "\"")
    static let single = StringRule(open: "'", close: "'")
    static let backtick = StringRule(open: "`", close: "`", multiline: true, interpolation: "${")
}

// MARK: - Code rules

/// Everything the generic scanner needs to tokenize one language. A language is data, not code,
/// so adding one is a table entry rather than a new scanner.
struct CodeRules: Sendable {
    var lineComments: [String] = ["//"]
    /// Doc comments are checked before line comments, so `///` must sort before `//`.
    var docLineComments: [String] = []
    var blockCommentOpen: String? = "/*"
    var blockCommentClose: String? = "*/"
    var docBlockOpen: String? = nil
    var nestedBlockComments = false
    var strings: [StringRule] = [.double, .single]
    var keywords: Set<String> = []
    var types: Set<String> = []
    var builtins: Set<String> = []
    /// Characters that may appear inside an identifier beyond letters and digits.
    var identifierExtras: Set<Character> = ["_"]
    /// A character that starts an annotation run: `@` in Swift/Python/Java, `#` in Rust's `#[`.
    var attributeStarts: Set<Character> = []
    /// A character that starts a preprocessor/compiler directive at the head of a token.
    var directiveStarts: Set<Character> = []
    var caseInsensitiveKeywords = false
    /// `#!/usr/bin/env python3` on line 1.
    var honorsShebang = true
    /// Treat a bare identifier followed by `(` as a call site.
    var marksFunctionCalls = true
    /// Digits may be broken up by these, e.g. `1_000_000`.
    var digitSeparators: Set<Character> = ["_"]
}

// MARK: - Grammar

/// Most languages are close enough to each other that one parameterized scanner covers them.
/// The rest get a purpose-built one, because pretending YAML is C-like produces nonsense.
enum Grammar: Sendable {
    case code(CodeRules)
    case json
    case markdown
    case xml
    case yaml
    case ini
    case plain
}

// MARK: - Language

struct Language: Identifiable, Sendable {
    var id: String
    var name: String
    var extensions: [String] = []
    /// Exact filenames — Makefile, Dockerfile, .gitignore.
    var filenames: [String] = []
    var grammar: Grammar = .plain
    var lineComment: String? = nil
    var blockComment: (open: String, close: String)? = nil
    /// What one indent level looks like in this language's own convention.
    var indentUnit: String = "    "
    /// A line ending with one of these opens a block, so the next line indents.
    var indentAfterSuffixes: [String] = ["{", "(", "[", ":"]
    /// A line starting with one of these closes a block, so it dedents relative to the previous.
    var dedentPrefixes: [String] = ["}", ")", "]"]
    /// Pairs the editor closes for you. The closer is skipped over if you type it yourself.
    var autoClosePairs: [(String, String)] = [("(", ")"), ("[", "]"), ("{", "}"),
                                              ("\"", "\""), ("'", "'")]
    /// SFSymbol for the file tree and tab bar.
    var symbol: String = "doc.text"

    // Not Equatable because of the tuple; identity is the id.
    static func == (a: Language, b: Language) -> Bool { a.id == b.id }
}

// MARK: - Registry

/// The set of languages the editor knows. Everything here is exercised by `--audit`.
enum Languages {
    // ---- shared keyword sets -------------------------------------------------------------

    private static let cCommonTypes: Set<String> = [
        "int", "long", "short", "char", "float", "double", "void", "unsigned", "signed",
        "bool", "size_t", "ssize_t", "int8_t", "int16_t", "int32_t", "int64_t",
        "uint8_t", "uint16_t", "uint32_t", "uint64_t", "wchar_t", "FILE",
    ]

    // ---- individual languages ------------------------------------------------------------

    static let swift = Language(
        id: "swift", name: "Swift", extensions: ["swift"],
        grammar: .code(CodeRules(
            lineComments: ["//"], docLineComments: ["///"],
            blockCommentOpen: "/*", blockCommentClose: "*/", docBlockOpen: "/**",
            nestedBlockComments: true,
            strings: [
                StringRule(open: "\"\"\"", close: "\"\"\"", multiline: true, interpolation: "\\("),
                StringRule(open: "#\"", close: "\"#", escape: nil),
                StringRule(open: "\"", close: "\"", interpolation: "\\("),
            ],
            keywords: [
                "associatedtype", "borrowing", "case", "catch", "class", "consuming", "continue",
                "default", "defer", "deinit", "do", "each", "else", "enum", "extension",
                "fallthrough", "fileprivate", "for", "func", "guard", "if", "import", "in",
                "indirect", "init", "inout", "internal", "let", "macro", "nonisolated",
                "open", "operator", "private", "protocol", "public", "package", "repeat",
                "rethrows", "return", "sending", "some", "static", "struct", "subscript",
                "switch", "throw", "throws", "try", "typealias", "var", "where", "while",
                "async", "await", "actor", "isolated", "lazy", "mutating", "nonmutating",
                "override", "required", "convenience", "dynamic", "final", "optional",
                "weak", "unowned", "willSet", "didSet", "get", "set", "as", "is", "any",
            ],
            types: [
                "Int", "Int8", "Int16", "Int32", "Int64", "UInt", "UInt8", "UInt16", "UInt32",
                "UInt64", "Double", "Float", "Bool", "String", "Character", "Substring",
                "Array", "Dictionary", "Set", "Optional", "Result", "Error", "Any", "AnyObject",
                "Void", "Never", "Data", "Date", "URL", "UUID", "Task", "Sendable", "Codable",
                "Encodable", "Decodable", "Equatable", "Hashable", "Comparable", "Identifiable",
                "Sequence", "Collection", "Range", "ClosedRange", "Self",
            ],
            builtins: ["true", "false", "nil", "self", "super", "print", "assert",
                       "precondition", "fatalError", "type", "Type", "Protocol"],
            attributeStarts: ["@"], directiveStarts: ["#"], honorsShebang: false)),
        lineComment: "//", blockComment: ("/*", "*/"),
        indentAfterSuffixes: ["{", "(", "[", ":"],
        symbol: "swift")

    static let python = Language(
        id: "python", name: "Python", extensions: ["py", "pyi", "pyw"],
        grammar: .code(CodeRules(
            lineComments: ["#"], blockCommentOpen: nil, blockCommentClose: nil,
            strings: [
                StringRule(open: "\"\"\"", close: "\"\"\"", multiline: true),
                StringRule(open: "'''", close: "'''", multiline: true),
                StringRule(open: "r\"", close: "\"", escape: nil),
                StringRule(open: "r'", close: "'", escape: nil),
                StringRule(open: "f\"", close: "\"", interpolation: "{"),
                StringRule(open: "f'", close: "'", interpolation: "{"),
                StringRule(open: "b\"", close: "\""),
                StringRule(open: "b'", close: "'"),
                .double, .single,
            ],
            keywords: [
                "and", "as", "assert", "async", "await", "break", "class", "continue", "def",
                "del", "elif", "else", "except", "finally", "for", "from", "global", "if",
                "import", "in", "is", "lambda", "nonlocal", "not", "or", "pass", "raise",
                "return", "try", "while", "with", "yield", "match", "case",
            ],
            types: [
                "int", "float", "complex", "bool", "str", "bytes", "bytearray", "list", "tuple",
                "dict", "set", "frozenset", "object", "type", "Any", "Optional", "Union",
                "List", "Dict", "Tuple", "Set", "Callable", "Iterator", "Iterable", "Sequence",
                "Mapping", "TypeVar", "Generic", "Protocol", "Final", "Literal", "Self",
            ],
            builtins: [
                "True", "False", "None", "self", "cls", "print", "len", "range", "enumerate",
                "zip", "map", "filter", "sorted", "reversed", "sum", "min", "max", "abs",
                "round", "open", "input", "isinstance", "issubclass", "getattr", "setattr",
                "hasattr", "delattr", "super", "property", "staticmethod", "classmethod",
                "repr", "hash", "id", "iter", "next", "any", "all", "format", "vars", "dir",
                "__init__", "__name__", "__main__", "__file__", "NotImplemented", "Ellipsis",
            ],
            attributeStarts: ["@"])),
        lineComment: "#",
        indentAfterSuffixes: [":", "{", "(", "["],
        dedentPrefixes: ["}", ")", "]", "else:", "elif", "except", "finally:"],
        symbol: "chevron.left.forwardslash.chevron.right")

    static let javascript = Language(
        id: "javascript", name: "JavaScript", extensions: ["js", "mjs", "cjs", "jsx"],
        grammar: .code(CodeRules(
            docLineComments: [], docBlockOpen: "/**",
            strings: [.backtick, .double, .single],
            keywords: [
                "async", "await", "break", "case", "catch", "class", "const", "continue",
                "debugger", "default", "delete", "do", "else", "export", "extends", "finally",
                "for", "from", "function", "get", "if", "import", "in", "instanceof", "let",
                "new", "of", "return", "set", "static", "super", "switch", "this", "throw",
                "try", "typeof", "var", "void", "while", "with", "yield",
            ],
            types: ["Array", "Object", "String", "Number", "Boolean", "Symbol", "BigInt",
                    "Function", "Promise", "Map", "Set", "WeakMap", "WeakSet", "Date", "RegExp",
                    "Error", "JSON", "Math", "Proxy", "Reflect"],
            builtins: ["true", "false", "null", "undefined", "NaN", "Infinity", "console",
                       "window", "document", "globalThis", "process", "require", "module",
                       "exports", "__dirname", "__filename", "fetch", "setTimeout",
                       "setInterval", "clearTimeout", "clearInterval"],
            identifierExtras: ["_", "$"])),
        lineComment: "//", blockComment: ("/*", "*/"), indentUnit: "  ",
        symbol: "curlybraces")

    static let typescript = Language(
        id: "typescript", name: "TypeScript", extensions: ["ts", "tsx", "mts", "cts"],
        grammar: .code(CodeRules(
            docBlockOpen: "/**",
            strings: [.backtick, .double, .single],
            keywords: [
                "abstract", "any", "as", "asserts", "async", "await", "break", "case", "catch",
                "class", "const", "continue", "declare", "default", "delete", "do", "else",
                "enum", "export", "extends", "finally", "for", "from", "function", "get",
                "implements", "import", "in", "infer", "instanceof", "interface", "is",
                "keyof", "let", "namespace", "new", "of", "override", "private", "protected",
                "public", "readonly", "return", "satisfies", "set", "static", "super",
                "switch", "this", "throw", "try", "type", "typeof", "var", "void", "while",
                "yield",
            ],
            types: ["string", "number", "boolean", "bigint", "symbol", "object", "unknown",
                    "never", "Array", "Promise", "Record", "Partial", "Required", "Readonly",
                    "Pick", "Omit", "Exclude", "Extract", "ReturnType", "Parameters", "Map",
                    "Set", "Date", "RegExp", "Error", "JSON", "Math"],
            builtins: ["true", "false", "null", "undefined", "NaN", "Infinity", "console",
                       "window", "document", "globalThis", "process", "require", "module"],
            identifierExtras: ["_", "$"])),
        lineComment: "//", blockComment: ("/*", "*/"), indentUnit: "  ",
        symbol: "curlybraces")

    static let json = Language(
        id: "json", name: "JSON", extensions: ["json", "jsonc", "geojson", "webmanifest", "ipynb"],
        filenames: ["package.json", "tsconfig.json", ".eslintrc.json"],
        grammar: .json, lineComment: nil, indentUnit: "  ",
        indentAfterSuffixes: ["{", "["], dedentPrefixes: ["}", "]"],
        autoClosePairs: [("{", "}"), ("[", "]"), ("\"", "\"")],
        symbol: "list.bullet.indent")

    static let markdown = Language(
        id: "markdown", name: "Markdown", extensions: ["md", "markdown", "mdx"],
        grammar: .markdown, lineComment: nil, indentUnit: "  ",
        indentAfterSuffixes: [], dedentPrefixes: [],
        autoClosePairs: [("(", ")"), ("[", "]"), ("`", "`")],
        symbol: "doc.richtext")

    static let yaml = Language(
        id: "yaml", name: "YAML", extensions: ["yaml", "yml"],
        filenames: [".clang-format", "docker-compose.yml"],
        grammar: .yaml, lineComment: "#", indentUnit: "  ",
        indentAfterSuffixes: [":", "-"], dedentPrefixes: [],
        symbol: "list.bullet.indent")

    static let toml = Language(
        id: "toml", name: "TOML", extensions: ["toml", "ini", "cfg", "conf", "properties"],
        filenames: ["Cargo.toml", "pyproject.toml", ".gitconfig", "config.toml"],
        grammar: .ini, lineComment: "#", indentUnit: "  ",
        indentAfterSuffixes: [], dedentPrefixes: [],
        symbol: "slider.horizontal.3")

    static let html = Language(
        id: "html", name: "HTML", extensions: ["html", "htm", "xhtml", "vue", "svelte"],
        grammar: .xml, lineComment: nil, blockComment: ("<!--", "-->"),
        indentUnit: "  ", indentAfterSuffixes: [">"], dedentPrefixes: ["</"],
        autoClosePairs: [("(", ")"), ("[", "]"), ("{", "}"), ("\"", "\""), ("'", "'")],
        symbol: "chevron.left.slash.chevron.right")

    static let xml = Language(
        id: "xml", name: "XML", extensions: ["xml", "svg", "plist", "xib", "storyboard", "xsd"],
        grammar: .xml, lineComment: nil, blockComment: ("<!--", "-->"),
        indentUnit: "  ", indentAfterSuffixes: [">"], dedentPrefixes: ["</"],
        symbol: "chevron.left.slash.chevron.right")

    static let css = Language(
        id: "css", name: "CSS", extensions: ["css", "scss", "sass", "less"],
        grammar: .code(CodeRules(
            lineComments: ["//"],
            strings: [.double, .single],
            keywords: ["import", "media", "keyframes", "supports", "font-face", "charset",
                       "namespace", "page", "mixin", "include", "extend", "use", "forward",
                       "if", "else", "each", "for", "while", "function", "return"],
            types: [],
            builtins: ["inherit", "initial", "unset", "revert", "none", "auto", "important",
                       "var", "calc", "rgb", "rgba", "hsl", "hsla", "url", "linear-gradient"],
            identifierExtras: ["_", "-"], attributeStarts: [], directiveStarts: ["@"],
            honorsShebang: false)),
        lineComment: "//", blockComment: ("/*", "*/"), indentUnit: "  ",
        symbol: "paintbrush")

    static let shell = Language(
        id: "shell", name: "Shell", extensions: ["sh", "bash", "zsh", "fish", "ksh", "command"],
        filenames: [".bashrc", ".zshrc", ".bash_profile", ".profile", ".zprofile", ".zshenv"],
        grammar: .code(CodeRules(
            lineComments: ["#"], blockCommentOpen: nil, blockCommentClose: nil,
            // `$` rather than `${`: shell expands both `$NAME` and `${NAME}` inside quotes,
            // and the scanner's bare-`$` path handles the braced form too.
            strings: [StringRule(open: "\"", close: "\"", interpolation: "$"),
                      StringRule(open: "'", close: "'", escape: nil)],
            keywords: ["if", "then", "elif", "else", "fi", "for", "while", "until", "do",
                       "done", "case", "esac", "in", "function", "select", "time", "return",
                       "break", "continue", "local", "export", "readonly", "declare",
                       "typeset", "shift", "trap", "set", "unset", "source", "alias"],
            types: [],
            builtins: ["echo", "printf", "cd", "pwd", "read", "test", "exit", "eval", "exec",
                       "true", "false", "cat", "grep", "sed", "awk", "cut", "sort", "uniq",
                       "head", "tail", "find", "xargs", "mkdir", "rm", "cp", "mv", "chmod",
                       "touch", "ls", "git", "curl", "wget", "env"],
            identifierExtras: ["_"], directiveStarts: ["$"], marksFunctionCalls: false)),
        lineComment: "#", symbol: "terminal")

    static let ruby = Language(
        id: "ruby", name: "Ruby", extensions: ["rb", "rake", "gemspec", "ru"],
        filenames: ["Gemfile", "Rakefile", "Guardfile", "Podfile"],
        grammar: .code(CodeRules(
            lineComments: ["#"], blockCommentOpen: "=begin", blockCommentClose: "=end",
            strings: [StringRule(open: "\"", close: "\"", interpolation: "#{"), .single],
            keywords: ["alias", "and", "begin", "break", "case", "class", "def", "defined?",
                       "do", "else", "elsif", "end", "ensure", "for", "if", "in", "module",
                       "next", "not", "or", "redo", "rescue", "retry", "return", "then",
                       "undef", "unless", "until", "when", "while", "yield", "require",
                       "require_relative", "attr_accessor", "attr_reader", "attr_writer"],
            types: ["Integer", "Float", "String", "Symbol", "Array", "Hash", "Range", "Proc",
                    "Struct", "Class", "Module", "Exception", "StandardError"],
            builtins: ["true", "false", "nil", "self", "super", "puts", "print", "p", "pp",
                       "raise", "lambda", "proc", "loop", "gets", "__method__"],
            identifierExtras: ["_", "?", "!"])),
        lineComment: "#", indentUnit: "  ",
        indentAfterSuffixes: ["do", "{", "(", "["],
        dedentPrefixes: ["end", "}", ")", "]", "else", "elsif", "rescue", "ensure", "when"],
        symbol: "diamond")

    static let go = Language(
        id: "go", name: "Go", extensions: ["go"],
        grammar: .code(CodeRules(
            strings: [StringRule(open: "`", close: "`", escape: nil, multiline: true),
                      .double, StringRule(open: "'", close: "'")],
            keywords: ["break", "case", "chan", "const", "continue", "default", "defer",
                       "else", "fallthrough", "for", "func", "go", "goto", "if", "import",
                       "interface", "map", "package", "range", "return", "select", "struct",
                       "switch", "type", "var"],
            types: ["bool", "byte", "complex64", "complex128", "error", "float32", "float64",
                    "int", "int8", "int16", "int32", "int64", "rune", "string", "uint",
                    "uint8", "uint16", "uint32", "uint64", "uintptr", "any"],
            builtins: ["true", "false", "iota", "nil", "append", "cap", "close", "copy",
                       "delete", "len", "make", "new", "panic", "print", "println", "recover"])),
        lineComment: "//", blockComment: ("/*", "*/"), indentUnit: "\t",
        symbol: "hare")

    static let rust = Language(
        id: "rust", name: "Rust", extensions: ["rs"],
        grammar: .code(CodeRules(
            docLineComments: ["///", "//!"], nestedBlockComments: true,
            strings: [StringRule(open: "r#\"", close: "\"#", escape: nil, multiline: true),
                      StringRule(open: "b\"", close: "\""), .double,
                      StringRule(open: "'", close: "'")],
            keywords: ["as", "async", "await", "break", "const", "continue", "crate", "dyn",
                       "else", "enum", "extern", "fn", "for", "if", "impl", "in", "let",
                       "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "self",
                       "Self", "static", "struct", "super", "trait", "type", "unsafe", "use",
                       "where", "while", "union"],
            types: ["bool", "char", "f32", "f64", "i8", "i16", "i32", "i64", "i128", "isize",
                    "str", "u8", "u16", "u32", "u64", "u128", "usize", "String", "Vec",
                    "Option", "Result", "Box", "Rc", "Arc", "HashMap", "HashSet", "BTreeMap"],
            builtins: ["true", "false", "None", "Some", "Ok", "Err", "println", "print",
                       "format", "vec", "panic", "assert", "assert_eq", "write", "writeln",
                       "todo", "unimplemented", "unreachable", "dbg"],
            attributeStarts: ["#"])),
        lineComment: "//", blockComment: ("/*", "*/"), symbol: "gearshape.2")

    static let c = Language(
        id: "c", name: "C", extensions: ["c", "h"],
        grammar: .code(CodeRules(
            keywords: ["auto", "break", "case", "const", "continue", "default", "do", "else",
                       "enum", "extern", "for", "goto", "if", "inline", "register", "restrict",
                       "return", "sizeof", "static", "struct", "switch", "typedef", "union",
                       "volatile", "while", "_Atomic", "_Bool", "_Generic", "_Noreturn"],
            types: cCommonTypes,
            builtins: ["NULL", "true", "false", "printf", "fprintf", "sprintf", "snprintf",
                       "malloc", "calloc", "realloc", "free", "memcpy", "memset", "strlen",
                       "strcmp", "strcpy", "assert"],
            directiveStarts: ["#"])),
        lineComment: "//", blockComment: ("/*", "*/"), symbol: "c.square")

    static let cpp = Language(
        id: "cpp", name: "C++", extensions: ["cpp", "cc", "cxx", "hpp", "hh", "hxx", "ipp"],
        grammar: .code(CodeRules(
            docBlockOpen: "/**",
            keywords: ["alignas", "alignof", "and", "asm", "auto", "break", "case", "catch",
                       "class", "co_await", "co_return", "co_yield", "concept", "const",
                       "consteval", "constexpr", "constinit", "const_cast", "continue",
                       "decltype", "default", "delete", "do", "dynamic_cast", "else", "enum",
                       "explicit", "export", "extern", "for", "friend", "goto", "if", "inline",
                       "mutable", "namespace", "new", "noexcept", "operator", "or", "private",
                       "protected", "public", "register", "reinterpret_cast", "requires",
                       "return", "sizeof", "static", "static_assert", "static_cast", "struct",
                       "switch", "template", "this", "thread_local", "throw", "try", "typedef",
                       "typeid", "typename", "union", "using", "virtual", "volatile", "while"],
            types: cCommonTypes.union(["string", "vector", "map", "set", "unordered_map",
                                       "unique_ptr", "shared_ptr", "weak_ptr", "optional",
                                       "variant", "span", "string_view", "array", "pair",
                                       "tuple", "function", "ostream", "istream"]),
            builtins: ["nullptr", "true", "false", "std", "cout", "cerr", "cin", "endl",
                       "printf", "assert", "move", "forward", "make_unique", "make_shared"],
            directiveStarts: ["#"])),
        lineComment: "//", blockComment: ("/*", "*/"), symbol: "plus.square")

    static let objc = Language(
        id: "objc", name: "Objective-C", extensions: ["m", "mm"],
        grammar: .code(CodeRules(
            strings: [StringRule(open: "@\"", close: "\""), .double,
                      StringRule(open: "'", close: "'")],
            keywords: ["auto", "break", "case", "const", "continue", "default", "do", "else",
                       "enum", "extern", "for", "goto", "if", "inline", "return", "sizeof",
                       "static", "struct", "switch", "typedef", "union", "volatile", "while",
                       "in", "out", "inout", "bycopy", "byref", "oneway", "self", "super"],
            types: cCommonTypes.union(["id", "Class", "SEL", "IMP", "BOOL", "NSInteger",
                                       "NSUInteger", "CGFloat", "instancetype", "NSString",
                                       "NSArray", "NSDictionary", "NSObject", "NSError"]),
            builtins: ["nil", "Nil", "YES", "NO", "NULL", "NSLog"],
            attributeStarts: ["@"], directiveStarts: ["#"])),
        lineComment: "//", blockComment: ("/*", "*/"), symbol: "at.square")

    static let java = Language(
        id: "java", name: "Java", extensions: ["java"],
        grammar: .code(CodeRules(
            docBlockOpen: "/**",
            strings: [StringRule(open: "\"\"\"", close: "\"\"\"", multiline: true), .double,
                      StringRule(open: "'", close: "'")],
            keywords: ["abstract", "assert", "break", "case", "catch", "class", "const",
                       "continue", "default", "do", "else", "enum", "extends", "final",
                       "finally", "for", "goto", "if", "implements", "import", "instanceof",
                       "interface", "native", "new", "package", "private", "protected",
                       "public", "record", "return", "sealed", "static", "strictfp", "super",
                       "switch", "synchronized", "this", "throw", "throws", "transient",
                       "try", "var", "void", "volatile", "while", "yield", "permits"],
            types: ["boolean", "byte", "char", "double", "float", "int", "long", "short",
                    "String", "Object", "Integer", "Double", "Boolean", "Character", "Long",
                    "List", "Map", "Set", "ArrayList", "HashMap", "HashSet", "Optional",
                    "Stream", "Exception", "RuntimeException"],
            builtins: ["true", "false", "null", "System", "out", "println", "print"],
            identifierExtras: ["_", "$"], attributeStarts: ["@"])),
        lineComment: "//", blockComment: ("/*", "*/"), symbol: "cup.and.saucer")

    static let kotlin = Language(
        id: "kotlin", name: "Kotlin", extensions: ["kt", "kts"],
        grammar: .code(CodeRules(
            docBlockOpen: "/**", nestedBlockComments: true,
            strings: [StringRule(open: "\"\"\"", close: "\"\"\"", multiline: true,
                                 interpolation: "$"),
                      StringRule(open: "\"", close: "\"", interpolation: "$"),
                      StringRule(open: "'", close: "'")],
            keywords: ["as", "break", "by", "catch", "class", "companion", "const",
                       "constructor", "continue", "crossinline", "data", "do", "else", "enum",
                       "external", "false", "final", "finally", "for", "fun", "get", "if",
                       "import", "in", "infix", "init", "inline", "inner", "interface",
                       "internal", "is", "lateinit", "noinline", "object", "open", "operator",
                       "out", "override", "package", "private", "protected", "public",
                       "reified", "return", "sealed", "set", "super", "suspend", "tailrec",
                       "this", "throw", "try", "typealias", "val", "var", "vararg", "when",
                       "where", "while"],
            types: ["Int", "Long", "Short", "Byte", "Float", "Double", "Boolean", "Char",
                    "String", "Array", "List", "MutableList", "Map", "MutableMap", "Set",
                    "Unit", "Any", "Nothing", "Pair", "Triple"],
            builtins: ["true", "false", "null", "it", "this", "println", "print", "TODO",
                       "require", "check", "error", "let", "run", "apply", "also", "with"],
            attributeStarts: ["@"])),
        lineComment: "//", blockComment: ("/*", "*/"), symbol: "k.square")

    static let php = Language(
        id: "php", name: "PHP", extensions: ["php", "phtml"],
        grammar: .code(CodeRules(
            lineComments: ["//", "#"], docBlockOpen: "/**",
            strings: [StringRule(open: "\"", close: "\"", interpolation: "$"), .single],
            keywords: ["abstract", "and", "array", "as", "break", "callable", "case", "catch",
                       "class", "clone", "const", "continue", "declare", "default", "do",
                       "echo", "else", "elseif", "empty", "enddeclare", "endfor", "endforeach",
                       "endif", "endswitch", "endwhile", "enum", "extends", "final", "finally",
                       "fn", "for", "foreach", "function", "global", "goto", "if", "implements",
                       "include", "include_once", "instanceof", "insteadof", "interface",
                       "isset", "list", "match", "namespace", "new", "or", "print", "private",
                       "protected", "public", "readonly", "require", "require_once", "return",
                       "static", "switch", "throw", "trait", "try", "unset", "use", "var",
                       "while", "xor", "yield"],
            types: ["int", "float", "string", "bool", "object", "mixed", "void", "never",
                    "iterable", "self", "parent", "static"],
            builtins: ["true", "false", "null", "this", "count", "strlen", "var_dump",
                       "print_r", "implode", "explode", "array_map", "array_filter"],
            identifierExtras: ["_"], attributeStarts: ["#"], directiveStarts: ["$"])),
        lineComment: "//", blockComment: ("/*", "*/"), symbol: "p.square")

    static let sql = Language(
        id: "sql", name: "SQL", extensions: ["sql", "psql", "mysql"],
        grammar: .code(CodeRules(
            lineComments: ["--"],
            strings: [.single, StringRule(open: "\"", close: "\"", escape: nil)],
            keywords: ["select", "from", "where", "insert", "into", "values", "update", "set",
                       "delete", "create", "alter", "drop", "table", "index", "view", "join",
                       "inner", "left", "right", "full", "outer", "cross", "on", "group",
                       "order", "by", "having", "limit", "offset", "union", "all", "distinct",
                       "as", "and", "or", "not", "in", "exists", "between", "like", "ilike",
                       "is", "case", "when", "then", "else", "end", "with", "recursive",
                       "primary", "key", "foreign", "references", "unique", "check",
                       "default", "constraint", "cascade", "begin", "commit", "rollback",
                       "transaction", "returning", "conflict", "do", "nothing"],
            types: ["int", "integer", "bigint", "smallint", "serial", "bigserial", "text",
                    "varchar", "char", "boolean", "date", "time", "timestamp", "timestamptz",
                    "numeric", "decimal", "real", "double", "precision", "json", "jsonb",
                    "uuid", "bytea", "array"],
            builtins: ["null", "true", "false", "count", "sum", "avg", "min", "max", "coalesce",
                       "nullif", "cast", "now", "current_timestamp", "current_date"],
            caseInsensitiveKeywords: true, honorsShebang: false)),
        lineComment: "--", blockComment: ("/*", "*/"), indentUnit: "  ", symbol: "cylinder")

    static let dockerfile = Language(
        id: "dockerfile", name: "Dockerfile", extensions: ["dockerfile"],
        filenames: ["Dockerfile", "Containerfile", "dockerfile"],
        grammar: .code(CodeRules(
            lineComments: ["#"], blockCommentOpen: nil, blockCommentClose: nil,
            strings: [.double, .single],
            keywords: ["FROM", "RUN", "CMD", "LABEL", "MAINTAINER", "EXPOSE", "ENV", "ADD",
                       "COPY", "ENTRYPOINT", "VOLUME", "USER", "WORKDIR", "ARG", "ONBUILD",
                       "STOPSIGNAL", "HEALTHCHECK", "SHELL", "AS"],
            types: [], builtins: [], marksFunctionCalls: false)),
        lineComment: "#", symbol: "shippingbox")

    static let makefile = Language(
        id: "makefile", name: "Makefile", extensions: ["mk", "mak"],
        filenames: ["Makefile", "makefile", "GNUmakefile"],
        grammar: .code(CodeRules(
            lineComments: ["#"], blockCommentOpen: nil, blockCommentClose: nil,
            strings: [.double, .single],
            keywords: ["ifeq", "ifneq", "ifdef", "ifndef", "else", "endif", "include",
                       "define", "endef", "export", "unexport", "override", "vpath",
                       ".PHONY", ".DEFAULT", ".SUFFIXES"],
            types: [], builtins: ["shell", "wildcard", "patsubst", "subst", "foreach", "call",
                                  "eval", "origin", "notdir", "dir", "basename", "addprefix"],
            identifierExtras: ["_", "-", "."], directiveStarts: ["$"],
            marksFunctionCalls: false)),
        lineComment: "#", indentUnit: "\t", symbol: "hammer")

    static let lua = Language(
        id: "lua", name: "Lua", extensions: ["lua"],
        grammar: .code(CodeRules(
            lineComments: ["--"], blockCommentOpen: "--[[", blockCommentClose: "]]",
            strings: [StringRule(open: "[[", close: "]]", escape: nil, multiline: true),
                      .double, .single],
            keywords: ["and", "break", "do", "else", "elseif", "end", "for", "function",
                       "goto", "if", "in", "local", "not", "or", "repeat", "return", "then",
                       "until", "while"],
            types: [],
            builtins: ["true", "false", "nil", "self", "print", "pairs", "ipairs", "type",
                       "tostring", "tonumber", "pcall", "error", "require", "setmetatable",
                       "getmetatable", "table", "string", "math", "io", "os"])),
        lineComment: "--", indentUnit: "  ",
        indentAfterSuffixes: ["then", "do", "{", "(", "["],
        dedentPrefixes: ["end", "else", "elseif", "until", "}", ")", "]"],
        symbol: "moon")

    static let plainText = Language(id: "text", name: "Plain Text",
                                    extensions: ["txt", "log", "text"],
                                    grammar: .plain, symbol: "doc.plaintext")

    // ---- lookup ----------------------------------------------------------------------------

    static let builtIn: [Language] = [
        swift, python, javascript, typescript, json, markdown, yaml, toml, html, xml, css,
        shell, ruby, go, rust, c, cpp, objc, java, kotlin, php, sql, dockerfile, makefile,
        lua,
    ] + additional + extra + [plainText]

    /// Built-in languages plus whatever the registry files add (see `Registry`).
    static var all: [Language] { builtIn + RegistrySnapshot.shared.languages }

    private static let byExtension: [String: Language] = {
        var map: [String: Language] = [:]
        for language in builtIn {
            for ext in language.extensions where map[ext] == nil { map[ext] = language }
        }
        return map
    }()

    private static let byFilename: [String: Language] = {
        var map: [String: Language] = [:]
        for language in builtIn {
            for name in language.filenames { map[name.lowercased()] = language }
        }
        return map
    }()

    /// Registry entries first (they are the user's explicit choice), then filename (Makefile has
    /// no extension), then extension, then plain text.
    static func forFile(_ url: URL) -> Language {
        let name = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        let registry = RegistrySnapshot.shared
        if let match = registry.language(forFilename: name) { return match }
        if !ext.isEmpty, let match = registry.language(forExtension: ext) { return match }
        if let match = byFilename[name.lowercased()] { return match }
        if !ext.isEmpty, let match = byExtension[ext] { return match }
        // A dotfile with no extension: `.zshrc` arrives as extension "" and name ".zshrc".
        if name.hasPrefix("."), let match = byFilename[name.lowercased()] { return match }
        return plainText
    }

    static func byID(_ id: String) -> Language? { all.first { $0.id == id } }
}
