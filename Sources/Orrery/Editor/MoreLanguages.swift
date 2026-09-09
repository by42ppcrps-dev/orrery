import Foundation

/// The second half of the registry: languages added for breadth. Each is a table entry for the
/// generic scanner, so the audit's per-language sweep (comment, keyword and string tokens from
/// the language's own rules; unique ids; unambiguous extensions) applies to every one.
extension Languages {
    private static let codeSymbol = "chevron.left.forwardslash.chevron.right"

    static let csharp = Language(
        id: "csharp", name: "C#", extensions: ["cs", "csx"],
        grammar: .code(CodeRules(
            docLineComments: ["///"], docBlockOpen: "/**",
            strings: [StringRule(open: "$\"", close: "\"", interpolation: "{"),
                      StringRule(open: "@\"", close: "\"", escape: nil, multiline: true),
                      .double, .single],
            keywords: ["abstract", "as", "base", "break", "case", "catch", "checked", "class", "const",
                       "continue", "default", "delegate", "do", "else", "enum", "event", "explicit",
                       "extern", "finally", "fixed", "for", "foreach", "goto", "if", "implicit", "in",
                       "interface", "internal", "is", "lock", "namespace", "new", "operator", "out",
                       "override", "params", "private", "protected", "public", "readonly", "ref",
                       "return", "sealed", "sizeof", "stackalloc", "static", "struct", "switch", "this",
                       "throw", "try", "typeof", "unchecked", "unsafe", "using", "virtual", "volatile",
                       "while", "var", "async", "await", "yield", "get", "set", "value", "where",
                       "record", "init", "required", "with", "when", "nameof"],
            types: ["int", "long", "short", "byte", "sbyte", "uint", "ulong", "ushort", "float",
                    "double", "decimal", "bool", "char", "string", "object", "void", "dynamic",
                    "Task", "List", "Dictionary", "IEnumerable", "IList", "Action", "Func", "Span"],
            builtins: ["true", "false", "null", "Console", "Math", "String"],
            directiveStarts: ["#"], honorsShebang: false)),
        lineComment: "//", blockComment: ("/*", "*/"), symbol: codeSymbol)

    static let dart = Language(
        id: "dart", name: "Dart", extensions: ["dart"],
        grammar: .code(CodeRules(
            docLineComments: ["///"], docBlockOpen: "/**",
            strings: [StringRule(open: "\"\"\"", close: "\"\"\"", multiline: true, interpolation: "${"),
                      StringRule(open: "'''", close: "'''", multiline: true, interpolation: "${"),
                      StringRule(open: "r\"", close: "\"", escape: nil),
                      StringRule(open: "r'", close: "'", escape: nil),
                      StringRule(open: "\"", close: "\"", interpolation: "${"),
                      StringRule(open: "'", close: "'", interpolation: "${")],
            keywords: ["abstract", "as", "assert", "async", "await", "break", "case", "catch", "class",
                       "const", "continue", "covariant", "default", "deferred", "do", "dynamic", "else",
                       "enum", "export", "extends", "extension", "external", "factory", "final",
                       "finally", "for", "get", "hide", "if", "implements", "import", "in", "interface",
                       "is", "late", "library", "mixin", "new", "on", "operator", "part", "required",
                       "rethrow", "return", "set", "show", "static", "super", "switch", "sync", "this",
                       "throw", "try", "typedef", "var", "void", "while", "with", "yield", "sealed",
                       "base", "when"],
            types: ["int", "double", "num", "bool", "String", "List", "Map", "Set", "Future", "Stream",
                    "Object", "Iterable", "Duration", "Function", "Widget", "BuildContext"],
            builtins: ["true", "false", "null", "print", "runApp"],
            attributeStarts: ["@"], honorsShebang: false)),
        lineComment: "//", blockComment: ("/*", "*/"), indentUnit: "  ", symbol: codeSymbol)

    static let scala = Language(
        id: "scala", name: "Scala", extensions: ["scala", "sc", "sbt"],
        grammar: .code(CodeRules(
            docBlockOpen: "/**",
            strings: [StringRule(open: "\"\"\"", close: "\"\"\"", escape: nil, multiline: true),
                      StringRule(open: "s\"", close: "\"", interpolation: "${"),
                      StringRule(open: "f\"", close: "\"", interpolation: "${"),
                      .double, .single],
            keywords: ["abstract", "case", "catch", "class", "def", "do", "else", "enum", "extends",
                       "final", "finally", "for", "forSome", "given", "if", "implicit", "import", "lazy",
                       "match", "new", "object", "override", "package", "private", "protected", "return",
                       "sealed", "super", "then", "this", "throw", "trait", "try", "type", "using",
                       "val", "var", "while", "with", "yield", "extension", "derives", "end", "export",
                       "inline", "opaque", "transparent"],
            types: ["Int", "Long", "Double", "Float", "Boolean", "String", "Char", "Unit", "Any",
                    "AnyRef", "Nothing", "Option", "Some", "None", "List", "Seq", "Map", "Set",
                    "Either", "Future", "Vector", "Array"],
            builtins: ["true", "false", "null", "println", "print"],
            attributeStarts: ["@"], honorsShebang: false)),
        lineComment: "//", blockComment: ("/*", "*/"), indentUnit: "  ", symbol: codeSymbol)

    static let perl = Language(
        id: "perl", name: "Perl", extensions: ["pl", "pm", "t", "pod"],
        grammar: .code(CodeRules(
            lineComments: ["#"], blockCommentOpen: nil, blockCommentClose: nil,
            strings: [StringRule(open: "\"", close: "\"", interpolation: "${"),
                      .single, StringRule(open: "`", close: "`")],
            keywords: ["my", "our", "local", "sub", "return", "if", "elsif", "else", "unless", "while",
                       "until", "for", "foreach", "do", "last", "next", "redo", "package", "use", "no",
                       "require", "BEGIN", "END", "die", "warn", "eval", "defined", "undef", "ref",
                       "bless", "shift", "unshift", "push", "pop", "splice", "scalar", "wantarray",
                       "and", "or", "not", "xor", "lt", "gt", "le", "ge", "eq", "ne", "cmp", "x"],
            types: [],
            builtins: ["print", "printf", "say", "open", "close", "chomp", "chop", "split", "join",
                       "map", "grep", "sort", "reverse", "keys", "values", "each", "exists", "delete",
                       "length", "substr", "index", "sprintf", "STDIN", "STDOUT", "STDERR", "__PACKAGE__",
                       "__FILE__", "__LINE__"])),
        lineComment: "#", symbol: codeSymbol)

    static let r = Language(
        id: "r", name: "R", extensions: ["r", "rprofile"],
        grammar: .code(CodeRules(
            lineComments: ["#"], blockCommentOpen: nil, blockCommentClose: nil,
            strings: [.double, .single],
            keywords: ["if", "else", "repeat", "while", "function", "for", "in", "next", "break",
                       "library", "require", "return", "TRUE", "FALSE", "NULL", "Inf", "NaN", "NA",
                       "NA_integer_", "NA_real_", "NA_character_"],
            types: [],
            builtins: ["c", "print", "paste", "paste0", "cat", "length", "names", "data.frame", "list",
                       "vector", "matrix", "apply", "lapply", "sapply", "mapply", "seq", "rep", "sum",
                       "mean", "median", "sd", "max", "min", "nrow", "ncol", "stop", "warning"],
            identifierExtras: ["_", "."], marksFunctionCalls: true)),
        lineComment: "#", indentUnit: "  ", symbol: codeSymbol)

    static let zig = Language(
        id: "zig", name: "Zig", extensions: ["zig", "zon"],
        grammar: .code(CodeRules(
            docLineComments: ["///", "//!"], blockCommentOpen: nil, blockCommentClose: nil,
            strings: [.double, .single],
            keywords: ["const", "var", "fn", "pub", "return", "if", "else", "while", "for", "switch",
                       "break", "continue", "defer", "errdefer", "try", "catch", "orelse", "unreachable",
                       "struct", "enum", "union", "error", "comptime", "inline", "export", "extern",
                       "packed", "align", "volatile", "allowzero", "async", "await", "suspend", "resume",
                       "nosuspend", "test", "and", "or", "usingnamespace", "threadlocal", "linksection",
                       "callconv", "anytype", "noalias", "opaque"],
            types: ["u8", "u16", "u32", "u64", "u128", "i8", "i16", "i32", "i64", "i128", "f16", "f32",
                    "f64", "f128", "usize", "isize", "bool", "void", "noreturn", "type", "anyerror",
                    "comptime_int", "comptime_float", "anyopaque"],
            builtins: ["true", "false", "null", "undefined"],
            attributeStarts: ["@"], honorsShebang: false)),
        lineComment: "//", symbol: codeSymbol)

    static let elixir = Language(
        id: "elixir", name: "Elixir", extensions: ["ex", "exs", "eex", "heex"],
        grammar: .code(CodeRules(
            lineComments: ["#"], blockCommentOpen: nil, blockCommentClose: nil,
            strings: [StringRule(open: "\"\"\"", close: "\"\"\"", multiline: true, interpolation: "#{"),
                      StringRule(open: "\"", close: "\"", interpolation: "#{"), .single],
            keywords: ["def", "defp", "defmodule", "defmacro", "defmacrop", "defstruct", "defprotocol",
                       "defimpl", "defguard", "defdelegate", "do", "end", "fn", "if", "else", "unless",
                       "case", "cond", "when", "and", "or", "not", "in", "with", "receive", "after",
                       "raise", "rescue", "try", "catch", "throw", "import", "alias", "require", "use",
                       "quote", "unquote", "for", "reraise"],
            types: ["Integer", "Float", "String", "Atom", "List", "Map", "Tuple", "Keyword", "Enum",
                    "IO", "Kernel", "GenServer", "Agent", "Task", "Process"],
            builtins: ["true", "false", "nil", "self", "__MODULE__", "__ENV__", "is_atom", "is_binary",
                       "is_list", "is_map", "is_nil", "is_integer", "inspect", "length", "hd", "tl"],
            identifierExtras: ["_", "?", "!"], attributeStarts: ["@"])),
        lineComment: "#", indentUnit: "  ",
        indentAfterSuffixes: ["do", "->", "fn", "(", "[", "{"],
        dedentPrefixes: ["end", "else", "after", "rescue", "catch", ")", "]", "}"],
        symbol: codeSymbol)

    static let haskell = Language(
        id: "haskell", name: "Haskell", extensions: ["hs", "lhs"],
        grammar: .code(CodeRules(
            lineComments: ["--"], blockCommentOpen: "{-", blockCommentClose: "-}",
            nestedBlockComments: true,
            strings: [.double, .single],
            keywords: ["module", "import", "where", "let", "in", "do", "case", "of", "if", "then",
                       "else", "data", "type", "newtype", "class", "instance", "deriving", "forall",
                       "foreign", "infix", "infixl", "infixr", "default", "qualified", "as", "hiding",
                       "mdo", "rec", "proc"],
            types: ["Int", "Integer", "Double", "Float", "Bool", "Char", "String", "Maybe", "Either",
                    "IO", "Ordering", "Text", "Map", "Set"],
            builtins: ["True", "False", "Nothing", "Just", "Left", "Right", "map", "filter", "foldr",
                       "foldl", "putStrLn", "print", "show", "read", "return", "pure", "fmap", "mapM_",
                       "otherwise", "undefined", "error"],
            identifierExtras: ["_", "'"], honorsShebang: false)),
        lineComment: "--", blockComment: ("{-", "-}"), indentUnit: "  ", symbol: codeSymbol)

    static let julia = Language(
        id: "julia", name: "Julia", extensions: ["jl"],
        grammar: .code(CodeRules(
            lineComments: ["#"], blockCommentOpen: "#=", blockCommentClose: "=#",
            strings: [StringRule(open: "\"\"\"", close: "\"\"\"", multiline: true, interpolation: "$("),
                      StringRule(open: "\"", close: "\"", interpolation: "$("), .single],
            keywords: ["function", "end", "if", "elseif", "else", "while", "for", "in", "return",
                       "break", "continue", "begin", "let", "local", "global", "const", "struct",
                       "mutable", "abstract", "type", "primitive", "module", "using", "import", "export",
                       "baremodule", "quote", "do", "try", "catch", "finally", "macro", "where",
                       "isa", "outer"],
            types: ["Int", "Int64", "Int32", "Float64", "Float32", "Bool", "String", "Char", "Array",
                    "Vector", "Matrix", "Dict", "Set", "Tuple", "Any", "Nothing", "Symbol", "Number"],
            builtins: ["true", "false", "nothing", "missing", "println", "print", "length", "push!",
                       "pop!", "typeof", "zeros", "ones", "sum"],
            identifierExtras: ["_", "!"], attributeStarts: ["@"])),
        lineComment: "#", blockComment: ("#=", "=#"), indentUnit: "    ",
        indentAfterSuffixes: ["function", "if", "for", "while", "begin", "let", "do", "try", "(", "["],
        dedentPrefixes: ["end", "else", "elseif", "catch", "finally", ")", "]"],
        symbol: codeSymbol)

    static let powershell = Language(
        id: "powershell", name: "PowerShell", extensions: ["ps1", "psm1", "psd1"],
        grammar: .code(CodeRules(
            lineComments: ["#"], blockCommentOpen: "<#", blockCommentClose: "#>",
            strings: [StringRule(open: "\"", close: "\"", escape: "`", interpolation: "$("), .single],
            keywords: ["function", "param", "begin", "process", "end", "if", "elseif", "else", "switch",
                       "foreach", "for", "while", "do", "until", "break", "continue", "return", "throw",
                       "try", "catch", "finally", "class", "enum", "using", "filter", "workflow", "trap",
                       "in", "exit", "dynamicparam", "hidden", "static"],
            types: ["string", "int", "bool", "array", "hashtable", "object", "switch", "datetime"],
            builtins: ["Write-Host", "Write-Output", "Write-Error", "Get-Item", "Set-Item",
                       "Get-ChildItem", "Get-Content", "Set-Content", "New-Item", "Remove-Item",
                       "ForEach-Object", "Where-Object", "Select-Object", "$true", "$false", "$null",
                       "$_", "$PSScriptRoot", "$args", "$env"],
            identifierExtras: ["_", "-", "$"], caseInsensitiveKeywords: true)),
        lineComment: "#", blockComment: ("<#", "#>"), symbol: "terminal")

    static let groovy = Language(
        id: "groovy", name: "Groovy", extensions: ["groovy", "gvy", "gradle"],
        grammar: .code(CodeRules(
            docBlockOpen: "/**",
            strings: [StringRule(open: "\"\"\"", close: "\"\"\"", multiline: true, interpolation: "${"),
                      StringRule(open: "'''", close: "'''", multiline: true),
                      StringRule(open: "\"", close: "\"", interpolation: "${"), .single],
            keywords: ["as", "assert", "break", "case", "catch", "class", "const", "continue", "def",
                       "default", "do", "else", "enum", "extends", "finally", "for", "goto", "if",
                       "implements", "import", "in", "instanceof", "interface", "new", "package",
                       "return", "super", "switch", "this", "throw", "throws", "trait", "try", "while",
                       "abstract", "final", "native", "private", "protected", "public", "static",
                       "strictfp", "synchronized", "transient", "volatile", "var", "it"],
            types: ["int", "long", "boolean", "double", "float", "char", "byte", "short", "void",
                    "String", "List", "Map", "Object", "Closure", "Integer", "Boolean"],
            builtins: ["true", "false", "null", "println", "print", "apply", "plugins", "dependencies",
                       "repositories", "task", "tasks"],
            attributeStarts: ["@"])),
        lineComment: "//", blockComment: ("/*", "*/"), symbol: codeSymbol)

    static let hcl = Language(
        id: "hcl", name: "Terraform / HCL", extensions: ["tf", "tfvars", "hcl", "nomad"],
        grammar: .code(CodeRules(
            lineComments: ["#", "//"],
            strings: [StringRule(open: "\"", close: "\"", interpolation: "${")],
            keywords: ["resource", "variable", "output", "module", "provider", "data", "locals",
                       "terraform", "for_each", "count", "depends_on", "lifecycle", "dynamic", "content",
                       "if", "else", "for", "in", "backend", "required_providers", "import", "moved",
                       "check", "removed"],
            types: ["string", "number", "bool", "list", "map", "set", "object", "tuple", "any"],
            builtins: ["true", "false", "null", "var", "local", "module", "each", "path", "self"],
            honorsShebang: false)),
        lineComment: "#", blockComment: ("/*", "*/"), indentUnit: "  ", symbol: "cube")

    static let graphql = Language(
        id: "graphql", name: "GraphQL", extensions: ["graphql", "gql", "graphqls"],
        grammar: .code(CodeRules(
            lineComments: ["#"], blockCommentOpen: nil, blockCommentClose: nil,
            strings: [StringRule(open: "\"\"\"", close: "\"\"\"", multiline: true), .double],
            keywords: ["query", "mutation", "subscription", "fragment", "on", "type", "interface",
                       "union", "enum", "input", "scalar", "schema", "extend", "directive", "implements",
                       "repeatable"],
            types: ["Int", "Float", "String", "Boolean", "ID"],
            builtins: ["true", "false", "null"],
            attributeStarts: ["@"], honorsShebang: false, marksFunctionCalls: false)),
        lineComment: "#", indentUnit: "  ", symbol: "chart.bar")

    static let protobuf = Language(
        id: "protobuf", name: "Protocol Buffers", extensions: ["proto"],
        grammar: .code(CodeRules(
            strings: [.double, .single],
            keywords: ["syntax", "package", "import", "option", "message", "enum", "service", "rpc",
                       "returns", "stream", "oneof", "map", "repeated", "optional", "required",
                       "reserved", "extend", "extensions", "to", "max", "public", "weak", "edition"],
            types: ["double", "float", "int32", "int64", "uint32", "uint64", "sint32", "sint64",
                    "fixed32", "fixed64", "sfixed32", "sfixed64", "bool", "string", "bytes"],
            builtins: ["true", "false"], honorsShebang: false, marksFunctionCalls: false)),
        lineComment: "//", blockComment: ("/*", "*/"), indentUnit: "  ", symbol: "shippingbox")

    static let erlang = Language(
        id: "erlang", name: "Erlang", extensions: ["erl", "hrl", "escript"],
        grammar: .code(CodeRules(
            lineComments: ["%"], blockCommentOpen: nil, blockCommentClose: nil,
            strings: [.double, .single],
            keywords: ["after", "and", "andalso", "band", "begin", "bnot", "bor", "bsl", "bsr", "bxor",
                       "case", "catch", "cond", "div", "end", "fun", "if", "let", "not", "of", "or",
                       "orelse", "receive", "rem", "try", "when", "xor", "maybe", "else"],
            types: [],
            builtins: ["true", "false", "undefined", "spawn", "self", "io", "lists", "maps", "erlang",
                       "ok", "error", "length", "element", "tuple_size", "is_atom", "is_list"],
            identifierExtras: ["_", "@"])),
        lineComment: "%", indentUnit: "    ", symbol: codeSymbol)

    static let ocaml = Language(
        id: "ocaml", name: "OCaml", extensions: ["ml", "mli", "mll", "mly"],
        grammar: .code(CodeRules(
            lineComments: [], blockCommentOpen: "(*", blockCommentClose: "*)",
            nestedBlockComments: true,
            strings: [.double, .single],
            keywords: ["and", "as", "assert", "begin", "class", "constraint", "do", "done", "downto",
                       "else", "end", "exception", "external", "for", "fun", "function", "functor",
                       "if", "in", "include", "inherit", "initializer", "lazy", "let", "match", "method",
                       "module", "mutable", "new", "nonrec", "object", "of", "open", "or", "private",
                       "rec", "sig", "struct", "then", "to", "try", "type", "val", "virtual", "when",
                       "while", "with", "mod", "land", "lor", "lxor", "lsl", "lsr", "asr"],
            types: ["int", "float", "bool", "char", "string", "unit", "list", "array", "option",
                    "ref", "exn", "bytes"],
            builtins: ["true", "false", "print_string", "print_endline", "print_int", "printf",
                       "List", "Array", "String", "Printf", "Some", "None", "Ok", "Error"],
            identifierExtras: ["_", "'"], honorsShebang: false)),
        blockComment: ("(*", "*)"), indentUnit: "  ", symbol: codeSymbol)

    static let clojure = Language(
        id: "clojure", name: "Clojure", extensions: ["clj", "cljs", "cljc", "edn"],
        grammar: .code(CodeRules(
            lineComments: [";"], blockCommentOpen: nil, blockCommentClose: nil,
            strings: [.double],
            keywords: ["def", "defn", "defn-", "defmacro", "let", "fn", "if", "if-not", "if-let", "do",
                       "loop", "recur", "when", "when-not", "when-let", "cond", "case", "ns", "require",
                       "import", "try", "catch", "finally", "throw", "quote", "var", "deftype",
                       "defrecord", "defprotocol", "reify", "letfn", "for", "doseq", "dotimes", "->",
                       "->>", "as->", "some->"],
            types: [],
            builtins: ["true", "false", "nil", "map", "filter", "reduce", "println", "str", "vec",
                       "conj", "assoc", "dissoc", "get", "first", "rest", "count", "apply", "into",
                       "keyword", "symbol", "atom", "swap!", "reset!", "deref"],
            identifierExtras: ["_", "-", "?", "!", "*", ">", "<", "="], marksFunctionCalls: false)),
        lineComment: ";", indentUnit: "  ", indentAfterSuffixes: ["(", "[", "{"],
        dedentPrefixes: [")", "]", "}"], symbol: codeSymbol)

    static let nix = Language(
        id: "nix", name: "Nix", extensions: ["nix"],
        grammar: .code(CodeRules(
            lineComments: ["#"],
            strings: [StringRule(open: "''", close: "''", escape: nil, multiline: true, interpolation: "${"),
                      StringRule(open: "\"", close: "\"", interpolation: "${")],
            keywords: ["let", "in", "if", "then", "else", "with", "inherit", "rec", "assert", "or"],
            types: [],
            builtins: ["true", "false", "null", "import", "builtins", "derivation", "mkDerivation",
                       "stdenv", "pkgs", "lib", "fetchurl", "fetchFromGitHub", "toString", "map"],
            identifierExtras: ["_", "-", "'"], honorsShebang: false)),
        lineComment: "#", blockComment: ("/*", "*/"), indentUnit: "  ", symbol: "snowflake")

    static let fsharp = Language(
        id: "fsharp", name: "F#", extensions: ["fs", "fsx", "fsi"],
        grammar: .code(CodeRules(
            docLineComments: ["///"], blockCommentOpen: "(*", blockCommentClose: "*)",
            strings: [StringRule(open: "\"\"\"", close: "\"\"\"", multiline: true),
                      StringRule(open: "$\"", close: "\"", interpolation: "{"), .double, .single],
            keywords: ["abstract", "and", "as", "assert", "base", "begin", "class", "default", "delegate",
                       "do", "done", "downcast", "downto", "elif", "else", "end", "exception", "extern",
                       "finally", "for", "fun", "function", "global", "if", "in", "inherit", "inline",
                       "interface", "internal", "lazy", "let", "match", "member", "module", "mutable",
                       "namespace", "new", "null", "of", "open", "or", "override", "private", "public",
                       "rec", "return", "sig", "static", "struct", "then", "to", "try", "type", "upcast",
                       "use", "val", "void", "when", "while", "with", "yield", "async", "task"],
            types: ["int", "float", "bool", "string", "unit", "list", "array", "option", "seq",
                    "char", "byte", "decimal", "Result", "Async", "Task"],
            builtins: ["true", "false", "printfn", "printf", "sprintf", "List", "Seq", "Array",
                       "Option", "Some", "None", "Ok", "Error", "ignore", "not"],
            attributeStarts: ["["], honorsShebang: false)),
        lineComment: "//", blockComment: ("(*", "*)"), indentUnit: "    ", symbol: codeSymbol)

    static let additional: [Language] = [
        csharp, dart, scala, perl, r, zig, elixir, haskell, julia, powershell, groovy, hcl,
        graphql, protobuf, erlang, ocaml, clojure, nix, fsharp,
    ]
}
