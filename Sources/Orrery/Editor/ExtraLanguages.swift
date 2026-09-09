import Foundation

/// The third batch of the registry: older, scientific, hardware, scripting and build languages.
/// Same rule as the rest — every entry is data for the generic scanner, so the audit's
/// per-language sweep applies unchanged.
extension Languages {
    private static let codeSymbol = "chevron.left.forwardslash.chevron.right"
    private static let doubleNoEscape = StringRule(open: "\"", close: "\"", escape: nil)
    private static let singleNoEscape = StringRule(open: "'", close: "'", escape: nil)

    static let fortran = Language(
        id: "fortran", name: "Fortran", extensions: ["f90", "f95", "f03", "f08", "f", "for", "f77", "fpp"],
        grammar: .code(CodeRules(
            lineComments: ["!"], blockCommentOpen: nil, blockCommentClose: nil,
            strings: [doubleNoEscape, singleNoEscape],
            keywords: ["program", "end", "subroutine", "function", "module", "use", "implicit", "none",
                       "if", "then", "else", "elseif", "endif", "do", "while", "enddo", "select", "case",
                       "call", "return", "contains", "type", "interface", "procedure", "pure",
                       "elemental", "recursive", "intent", "in", "out", "inout", "parameter", "save",
                       "data", "common", "print", "write", "read", "open", "close", "format", "stop",
                       "go", "to", "continue", "where", "forall", "cycle", "exit", "public", "private",
                       "kind", "len", "result", "only", "allocate", "deallocate", "allocatable",
                       "dimension", "pointer", "target", "block", "associate", "submodule", "import"],
            types: ["integer", "real", "double", "precision", "character", "logical", "complex"],
            builtins: ["size", "len_trim", "trim", "abs", "sqrt", "sin", "cos", "exp", "log", "mod",
                       "max", "min", "sum", "present", "allocated", "nint", "int", "dble"],
            caseInsensitiveKeywords: true, honorsShebang: false)),
        lineComment: "!", symbol: codeSymbol)

    static let cobol = Language(
        id: "cobol", name: "COBOL", extensions: ["cob", "cbl", "cpy"],
        grammar: .code(CodeRules(
            lineComments: ["*>"], blockCommentOpen: nil, blockCommentClose: nil,
            strings: [doubleNoEscape, singleNoEscape],
            keywords: ["identification", "division", "program-id", "environment", "data",
                       "working-storage", "section", "procedure", "pic", "picture", "value", "move",
                       "to", "display", "accept", "perform", "until", "varying", "by", "from", "if",
                       "else", "end-if", "evaluate", "when", "end-evaluate", "compute", "add",
                       "subtract", "multiply", "divide", "giving", "stop", "run", "call", "using",
                       "open", "close", "read", "write", "into", "file", "fd", "select", "assign",
                       "organization", "sequential", "exit", "goback", "inspect", "string", "unstring",
                       "initialize", "set", "occurs", "times", "redefines", "copy", "end-perform",
                       "not", "and", "or", "input", "output", "returning", "linkage"],
            identifierExtras: ["_", "-"], caseInsensitiveKeywords: true, honorsShebang: false,
            marksFunctionCalls: false)),
        lineComment: "*>", symbol: codeSymbol)

    static let ada = Language(
        id: "ada", name: "Ada", extensions: ["adb", "ads", "ada"],
        grammar: .code(CodeRules(
            lineComments: ["--"], blockCommentOpen: nil, blockCommentClose: nil,
            strings: [doubleNoEscape],
            keywords: ["abort", "abs", "abstract", "accept", "access", "aliased", "all", "and", "array", "at", "begin", "body", "case", "constant", "declare", "delay", "delta", "digits", "do", "else", "elsif", "end", "entry", "exception", "exit", "for", "function", "generic", "goto", "if", "in", "interface", "is", "limited", "loop", "mod", "new", "not", "null", "of", "or", "others", "out", "overriding", "package", "pragma", "private", "procedure", "protected", "raise", "range", "record", "rem", "renames", "requeue", "return", "reverse", "select", "separate", "some", "subtype", "synchronized", "tagged", "task", "terminate", "then", "type", "until", "use", "when", "while", "with", "xor"],
            types: ["integer", "natural", "positive", "float", "boolean", "character", "string", "long_integer", "duration"],
            builtins: ["put_line", "put", "get_line", "new_line", "image", "length"],
            caseInsensitiveKeywords: true, honorsShebang: false)),
        lineComment: "--", symbol: codeSymbol)

    static let pascal = Language(
        id: "pascal", name: "Pascal", extensions: ["pas", "pp", "dpr", "lpr"],
        grammar: .code(CodeRules(
            lineComments: ["//"], blockCommentOpen: "{", blockCommentClose: "}",
            strings: [singleNoEscape],
            keywords: ["and", "array", "begin", "case", "const", "div", "do", "downto", "else", "end",
                       "file", "for", "function", "goto", "if", "implementation", "in", "inherited",
                       "interface", "label", "mod", "nil", "not", "object", "of", "or", "packed",
                       "procedure", "program", "record", "repeat", "set", "shl", "shr", "then", "to",
                       "type", "unit", "until", "uses", "var", "while", "with", "xor", "class",
                       "constructor", "destructor", "property", "private", "public", "protected",
                       "published", "override", "virtual", "abstract", "try", "except", "finally",
                       "raise", "initialization", "finalization", "exports", "library", "out", "is",
                       "as", "inline", "operator", "generic", "specialize"],
            types: ["integer", "longint", "int64", "real", "double", "boolean", "char", "byte", "word",
                    "cardinal", "string", "pointer", "single", "extended", "shortint", "smallint"],
            builtins: ["writeln", "write", "readln", "read", "length", "inc", "dec", "ord", "chr",
                       "high", "low", "setlength", "copy", "pos", "true", "false"],
            caseInsensitiveKeywords: true, honorsShebang: false)),
        lineComment: "//", blockComment: ("{", "}"), symbol: codeSymbol)

    /// No exclusive extension: `.m` belongs to Objective-C unless the file's content says MATLAB
    /// (see `Languages.refine`).
    static let matlab = Language(
        id: "matlab", name: "MATLAB / Octave", extensions: [],
        grammar: .code(CodeRules(
            lineComments: ["%", "#"], blockCommentOpen: "%{", blockCommentClose: "%}",
            strings: [.double, singleNoEscape],
            keywords: ["function", "end", "if", "elseif", "else", "for", "while", "switch", "case",
                       "otherwise", "return", "break", "continue", "try", "catch", "classdef",
                       "properties", "methods", "events", "global", "persistent", "parfor", "endfunction",
                       "endif", "endfor", "endwhile", "endswitch"],
            builtins: ["disp", "fprintf", "sprintf", "zeros", "ones", "eye", "size", "length", "numel",
                       "sum", "mean", "max", "min", "abs", "sqrt", "plot", "figure", "hold", "xlabel",
                       "ylabel", "title", "linspace", "rand", "randn", "true", "false", "pi", "inf", "nan"],
            honorsShebang: false)),
        lineComment: "%", blockComment: ("%{", "%}"), symbol: codeSymbol)

    static let assembly = Language(
        id: "asm", name: "Assembly", extensions: ["asm", "s", "nasm"],
        grammar: .code(CodeRules(
            lineComments: [";", "#", "//"], blockCommentOpen: "/*", blockCommentClose: "*/",
            strings: [.double, singleNoEscape],
            keywords: ["mov", "movq", "movl", "movb", "lea", "push", "pop", "call", "ret", "jmp", "je",
                       "jne", "jz", "jnz", "jg", "jl", "jge", "jle", "ja", "jb", "cmp", "test", "add",
                       "sub", "mul", "imul", "div", "idiv", "inc", "dec", "and", "or", "xor", "not",
                       "shl", "shr", "sal", "sar", "nop", "syscall", "int", "leave", "enter", "xchg",
                       "ldr", "str", "bl", "b", "bx", "adr", "adrp", "stp", "ldp", "svc", "cbz", "cbnz",
                       "section", "segment", "global", "globl", "extern", "db", "dw", "dd", "dq",
                       "resb", "resw", "resd", "equ", "times", "text", "data", "bss", "align", "byte",
                       "word", "long", "quad", "ascii", "asciz"],
            builtins: ["rax", "rbx", "rcx", "rdx", "rsi", "rdi", "rbp", "rsp", "eax", "ebx", "ecx",
                       "edx", "esi", "edi", "ebp", "esp", "r8", "r9", "r10", "r11", "r12", "r13", "r14",
                       "r15", "x0", "x1", "x2", "x3", "x4", "x5", "x6", "x7", "x8", "x29", "x30", "sp",
                       "lr", "pc", "w0", "w1", "w2", "w3"],
            identifierExtras: ["_", "."], directiveStarts: ["."], caseInsensitiveKeywords: true,
            honorsShebang: false, marksFunctionCalls: false)),
        lineComment: ";", symbol: codeSymbol)

    static let gdscript = Language(
        id: "gdscript", name: "GDScript", extensions: ["gd"],
        grammar: .code(CodeRules(
            lineComments: ["#"], blockCommentOpen: nil, blockCommentClose: nil,
            strings: [StringRule(open: "\"\"\"", close: "\"\"\"", multiline: true), .double, .single],
            keywords: ["func", "var", "const", "extends", "class_name", "signal", "enum", "if", "elif",
                       "else", "for", "while", "match", "return", "pass", "break", "continue", "and",
                       "or", "not", "in", "is", "as", "self", "static", "export", "onready", "tool",
                       "yield", "await", "setget", "preload", "load", "class", "super", "void"],
            types: ["int", "float", "bool", "String", "Array", "Dictionary", "Vector2", "Vector3",
                    "Node", "Node2D", "Node3D", "Color", "Callable", "Signal"],
            builtins: ["true", "false", "null", "print", "len", "range", "str", "get_node", "emit_signal",
                       "connect", "instantiate", "queue_free"],
            attributeStarts: ["@"], honorsShebang: false)),
        lineComment: "#", indentUnit: "\t", symbol: codeSymbol)

    static let solidity = Language(
        id: "solidity", name: "Solidity", extensions: ["sol"],
        grammar: .code(CodeRules(
            docLineComments: ["///"], docBlockOpen: "/**",
            keywords: ["pragma", "solidity", "contract", "interface", "library", "function", "modifier",
                       "event", "emit", "constructor", "returns", "return", "public", "private",
                       "internal", "external", "view", "pure", "payable", "memory", "storage",
                       "calldata", "if", "else", "for", "while", "do", "break", "continue", "require",
                       "revert", "assert", "mapping", "struct", "enum", "import", "is", "new", "delete",
                       "using", "override", "virtual", "abstract", "immutable", "constant", "indexed",
                       "receive", "fallback", "unchecked", "try", "catch", "error", "type", "assembly"],
            types: ["uint", "uint8", "uint16", "uint32", "uint64", "uint128", "uint256", "int", "int256",
                    "address", "bool", "string", "bytes", "bytes32", "bytes4"],
            builtins: ["msg", "block", "tx", "this", "super", "true", "false", "wei", "ether", "gwei",
                       "keccak256", "abi", "now"],
            honorsShebang: false)),
        lineComment: "//", blockComment: ("/*", "*/"), symbol: codeSymbol)

    static let lisp = Language(
        id: "lisp", name: "Lisp / Scheme", extensions: ["lisp", "cl", "el", "scm", "ss", "rkt", "sld", "fnl", "lsp"],
        grammar: .code(CodeRules(
            lineComments: [";"], blockCommentOpen: "#|", blockCommentClose: "|#", nestedBlockComments: true,
            strings: [.double],
            keywords: ["defun", "defvar", "defparameter", "defmacro", "defconstant", "let", "let*",
                       "lambda", "if", "cond", "when", "unless", "loop", "do", "dolist", "dotimes",
                       "progn", "setq", "setf", "quote", "function", "define", "define-syntax",
                       "define-record-type", "begin", "set!", "else", "case", "and", "or", "not",
                       "require", "provide", "import", "export", "module", "defclass", "defmethod",
                       "defstruct", "values", "multiple-value-bind", "return", "return-from", "block",
                       "flet", "labels", "declare", "eval-when", "in-package", "defpackage", "let-values",
                       "call/cc", "syntax-rules"],
            builtins: ["car", "cdr", "cons", "list", "append", "apply", "funcall", "mapcar", "map",
                       "format", "print", "princ", "display", "newline", "length", "reverse", "nil", "t",
                       "null", "eq", "eql", "equal", "assoc", "member", "reduce", "filter", "vector",
                       "string", "error", "lambda"],
            identifierExtras: ["_", "-", "*", "?", "!", "/", "<", ">", "="], honorsShebang: true,
            marksFunctionCalls: false)),
        lineComment: ";", blockComment: ("#|", "|#"), indentUnit: "  ", autoClosePairs: [("(", ")"), ("[", "]"), ("{", "}"), ("\"", "\"")],
        symbol: codeSymbol)

    /// `.pl` stays Perl, which is far more common; Prolog files are recognized by `.pro`/`.prolog`.
    static let prolog = Language(
        id: "prolog", name: "Prolog", extensions: ["pro", "prolog"],
        grammar: .code(CodeRules(
            lineComments: ["%"], blockCommentOpen: "/*", blockCommentClose: "*/",
            strings: [.double, .single],
            keywords: ["is", "not", "mod", "rem", "div", "true", "fail", "false", "assert", "asserta",
                       "assertz", "retract", "findall", "bagof", "setof", "forall", "once", "catch",
                       "throw", "call", "halt", "consult", "use_module", "module", "dynamic",
                       "discontiguous", "initialization", "between", "succ", "plus", "member", "append",
                       "length", "nth0", "nth1", "msort", "sort", "write", "writeln", "print", "nl",
                       "read", "format", "atom", "number", "var", "nonvar", "integer", "atomic",
                       "compound", "functor", "arg", "copy_term", "atom_codes", "atom_length",
                       "number_codes", "sub_atom", "atom_concat"],
            identifierExtras: ["_"], honorsShebang: true)),
        lineComment: "%", blockComment: ("/*", "*/"), symbol: codeSymbol)

    static let nim = Language(
        id: "nim", name: "Nim", extensions: ["nim", "nims", "nimble"],
        grammar: .code(CodeRules(
            lineComments: ["#"], docLineComments: ["##"], blockCommentOpen: "#[", blockCommentClose: "]#",
            nestedBlockComments: true,
            strings: [StringRule(open: "\"\"\"", close: "\"\"\"", escape: nil, multiline: true), .double,
                      StringRule(open: "r\"", close: "\"", escape: nil), .single],
            keywords: ["proc", "func", "method", "iterator", "template", "macro", "converter", "type",
                       "var", "let", "const", "if", "elif", "else", "when", "case", "of", "for", "while",
                       "in", "notin", "is", "isnot", "return", "yield", "discard", "break", "continue",
                       "block", "try", "except", "finally", "raise", "defer", "import", "export", "from",
                       "include", "object", "ref", "ptr", "enum", "tuple", "distinct", "concept",
                       "static", "mixin", "bind", "and", "or", "not", "xor", "shl", "shr", "div", "mod",
                       "as", "asm", "cast", "addr", "using", "do", "out", "interface"],
            types: ["int", "int8", "int16", "int32", "int64", "uint", "uint8", "uint16", "uint32",
                    "uint64", "float", "float32", "float64", "string", "char", "bool", "seq", "array",
                    "openArray", "set", "void", "auto", "cstring", "pointer", "Natural", "Positive"],
            builtins: ["echo", "nil", "true", "false", "result", "len", "add", "high", "low", "inc",
                       "dec", "new", "assert", "quit", "repr", "ord", "chr", "abs", "min", "max"],
            attributeStarts: ["{"], honorsShebang: true)),
        lineComment: "#", blockComment: ("#[", "]#"), indentUnit: "  ", symbol: codeSymbol)

    static let crystal = Language(
        id: "crystal", name: "Crystal", extensions: ["cr"],
        grammar: .code(CodeRules(
            lineComments: ["#"], blockCommentOpen: nil, blockCommentClose: nil,
            strings: [StringRule(open: "\"", close: "\"", interpolation: "#{"), .single],
            keywords: ["def", "end", "class", "module", "struct", "enum", "if", "elsif", "else", "unless",
                       "while", "until", "case", "when", "then", "do", "begin", "rescue", "ensure",
                       "return", "yield", "next", "break", "require", "include", "extend", "self",
                       "and", "or", "not", "private", "protected", "abstract", "macro", "lib", "fun",
                       "alias", "annotation", "of", "as", "as?", "is_a?", "responds_to?", "sizeof",
                       "typeof", "pointerof", "with", "select", "uninitialized", "getter", "setter",
                       "property", "record", "super", "in", "out", "forall", "verbatim"],
            types: ["Int32", "Int64", "UInt8", "Float64", "String", "Char", "Bool", "Array", "Hash",
                    "Nil", "Symbol", "Proc", "Tuple", "NamedTuple", "Pointer", "Slice"],
            builtins: ["puts", "print", "p", "pp", "nil", "true", "false", "raise", "typeof", "loop",
                       "spawn", "sleep", "gets", "exit"],
            identifierExtras: ["_", "?", "!"], attributeStarts: ["@"], honorsShebang: true)),
        lineComment: "#", indentUnit: "  ", symbol: codeSymbol)

    static let cuda: Language = {
        var rules = CodeRules()
        if case let .code(cppRules) = cpp.grammar { rules = cppRules }
        rules.keywords.formUnion(["__global__", "__device__", "__host__", "__shared__", "__constant__",
                                  "__managed__", "__restrict__", "__syncthreads", "__launch_bounds__"])
        rules.builtins.formUnion(["threadIdx", "blockIdx", "blockDim", "gridDim", "warpSize", "cudaMalloc",
                                  "cudaMemcpy", "cudaFree", "cudaDeviceSynchronize", "cudaGetLastError",
                                  "cudaMemcpyHostToDevice", "cudaMemcpyDeviceToHost"])
        rules.types.formUnion(["dim3", "cudaError_t", "cudaStream_t", "float4", "int2"])
        return Language(id: "cuda", name: "CUDA", extensions: ["cu", "cuh"], grammar: .code(rules),
                        lineComment: "//", blockComment: ("/*", "*/"), symbol: codeSymbol)
    }()

    static let verilog = Language(
        id: "verilog", name: "Verilog / SystemVerilog", extensions: ["v", "sv", "svh", "vh"],
        grammar: .code(CodeRules(
            keywords: ["module", "endmodule", "input", "output", "inout", "wire", "reg", "logic", "always",
                       "always_ff", "always_comb", "always_latch", "assign", "begin", "end", "if", "else",
                       "case", "casez", "casex", "endcase", "for", "while", "repeat", "forever",
                       "initial", "parameter", "localparam", "function", "endfunction", "task",
                       "endtask", "posedge", "negedge", "generate", "endgenerate", "genvar", "package",
                       "endpackage", "import", "typedef", "struct", "union", "enum", "interface",
                       "endinterface", "modport", "class", "endclass", "program", "endprogram",
                       "default", "or", "and", "not", "signed", "unsigned", "return", "void",
                       "automatic", "static", "virtual", "extends", "new", "this", "super", "assert",
                       "property", "endproperty", "sequence", "endsequence", "cover", "wait",
                       "disable", "fork", "join", "join_any", "join_none", "unique", "priority"],
            types: ["bit", "byte", "int", "integer", "longint", "shortint", "real", "time", "string",
                    "shortreal", "chandle", "event"],
            builtins: ["$display", "$monitor", "$finish", "$time", "$clog2", "$random", "$stop",
                       "$signed", "$unsigned", "$bits", "$fopen", "$fclose", "$readmemh", "$write"],
            identifierExtras: ["_", "$"], directiveStarts: ["`"], honorsShebang: false)),
        lineComment: "//", blockComment: ("/*", "*/"), symbol: codeSymbol)

    static let vhdl = Language(
        id: "vhdl", name: "VHDL", extensions: ["vhd", "vhdl"],
        grammar: .code(CodeRules(
            lineComments: ["--"], blockCommentOpen: "/*", blockCommentClose: "*/",
            strings: [doubleNoEscape],
            keywords: ["library", "use", "entity", "architecture", "of", "is", "port", "in", "out", "inout",
                       "buffer", "signal", "variable", "constant", "begin", "end", "process", "if", "then",
                       "elsif", "else", "case", "when", "others", "for", "loop", "while", "generate",
                       "component", "map", "generic", "package", "body", "function", "procedure",
                       "return", "type", "subtype", "array", "record", "range", "to", "downto", "wait",
                       "until", "after", "null", "and", "or", "not", "xor", "nand", "nor", "xnor",
                       "report", "assert", "severity", "attribute", "configuration", "block", "exit",
                       "next", "alias", "file", "access", "new", "shared", "impure", "pure", "all"],
            types: ["std_logic", "std_logic_vector", "std_ulogic", "unsigned", "signed", "integer",
                    "natural", "positive", "boolean", "bit", "bit_vector", "real", "time", "string",
                    "character"],
            builtins: ["rising_edge", "falling_edge", "to_integer", "to_unsigned", "to_signed",
                       "resize", "std_logic_1164", "numeric_std", "ieee", "work", "true", "false"],
            caseInsensitiveKeywords: true, honorsShebang: false)),
        lineComment: "--", symbol: codeSymbol)

    /// Inline math `$…$` is the "string" form; control words are directives.
    static let latex = Language(
        id: "latex", name: "LaTeX", extensions: ["tex", "sty", "cls", "ltx", "bib"],
        grammar: .code(CodeRules(
            lineComments: ["%"], blockCommentOpen: nil, blockCommentClose: nil,
            strings: [StringRule(open: "$", close: "$", escape: nil)],
            keywords: ["begin", "end", "section", "subsection", "subsubsection", "chapter", "part",
                       "documentclass", "usepackage", "item", "label", "ref", "cite", "textbf", "textit",
                       "emph", "include", "input", "newcommand", "renewcommand", "title", "author",
                       "date", "maketitle", "tableofcontents", "caption", "figure", "table", "itemize",
                       "enumerate", "equation", "align", "document", "footnote", "hline", "centering",
                       "includegraphics", "bibliography", "bibliographystyle", "paragraph", "verbatim",
                       "def", "let", "frac", "sum", "int", "left", "right", "mathbb", "text"],
            directiveStarts: ["\\"], honorsShebang: false, marksFunctionCalls: false)),
        lineComment: "%", autoClosePairs: [("{", "}"), ("[", "]"), ("(", ")"), ("$", "$")], symbol: codeSymbol)

    static let cmake = Language(
        id: "cmake", name: "CMake", extensions: ["cmake"], filenames: ["CMakeLists.txt"],
        grammar: .code(CodeRules(
            lineComments: ["#"], blockCommentOpen: "#[[", blockCommentClose: "]]",
            strings: [.double],
            keywords: ["cmake_minimum_required", "project", "add_executable", "add_library", "target_link_libraries", "target_include_directories", "target_sources", "target_compile_options", "target_compile_definitions", "target_compile_features", "set", "unset", "if", "elseif", "else", "endif", "foreach", "endforeach", "while", "endwhile", "function", "endfunction", "macro", "endmacro", "include", "find_package", "find_library", "find_program", "option", "message", "install", "add_subdirectory", "add_custom_command", "add_custom_target", "enable_testing", "add_test", "list", "string", "file", "configure_file", "set_target_properties", "return", "break", "continue", "export", "get_target_property", "math", "add_definitions", "include_directories", "link_directories", "add_dependencies", "cmake_policy", "fetchcontent_declare", "fetchcontent_makeavailable"],
            builtins: ["on", "off", "true", "false", "public", "private", "interface", "static", "shared", "required", "status", "fatal_error", "warning", "cmake_cxx_standard", "cmake_build_type", "project_source_dir", "cmake_source_dir", "cmake_binary_dir"],
            caseInsensitiveKeywords: true, honorsShebang: false)),
        lineComment: "#", indentUnit: "  ", symbol: codeSymbol)

    static let starlark = Language(
        id: "starlark", name: "Bazel / Starlark", extensions: ["bzl", "bazel", "star"],
        filenames: ["BUILD", "BUILD.bazel", "WORKSPACE", "WORKSPACE.bazel", "MODULE.bazel"],
        grammar: .code(CodeRules(
            lineComments: ["#"], blockCommentOpen: nil, blockCommentClose: nil,
            strings: [StringRule(open: "\"\"\"", close: "\"\"\"", multiline: true), .double, .single],
            keywords: ["def", "return", "if", "elif", "else", "for", "in", "not", "and", "or", "load",
                       "pass", "break", "continue", "lambda"],
            builtins: ["True", "False", "None", "cc_library", "cc_binary", "cc_test", "py_binary",
                       "py_library", "py_test", "java_binary", "java_library", "java_test", "go_binary",
                       "go_library", "genrule", "filegroup", "package", "glob", "select", "native",
                       "rule", "attr", "ctx", "struct", "fail", "print", "len", "range", "str", "dict",
                       "list", "http_archive", "git_repository", "bazel_dep", "toolchain", "alias",
                       "exports_files", "visibility", "name", "srcs", "deps", "hdrs", "data"],
            honorsShebang: false)),
        lineComment: "#", symbol: codeSymbol)

    static let batch = Language(
        id: "batch", name: "Windows Batch", extensions: ["bat", "cmd"],
        grammar: .code(CodeRules(
            lineComments: ["::", "rem ", "REM ", "Rem "], blockCommentOpen: nil, blockCommentClose: nil,
            strings: [doubleNoEscape],
            keywords: ["echo", "set", "if", "else", "for", "in", "do", "goto", "call", "exit", "setlocal",
                       "endlocal", "pause", "rem", "not", "exist", "defined", "errorlevel", "equ", "neq",
                       "lss", "leq", "gtr", "geq", "cd", "dir", "copy", "xcopy", "del", "move", "mkdir",
                       "md", "rmdir", "rd", "type", "start", "shift", "pushd", "popd", "choice",
                       "findstr", "find", "title", "color", "cls", "off", "on", "enabledelayedexpansion",
                       "enableextensions", "timeout", "ping", "net", "reg", "wmic", "powershell"],
            identifierExtras: ["_", "%", "!"], caseInsensitiveKeywords: true, honorsShebang: false,
            marksFunctionCalls: false)),
        lineComment: "::", symbol: codeSymbol)

    static let visualBasic = Language(
        id: "vb", name: "Visual Basic", extensions: ["vb", "vbs", "bas", "vba", "frm"],
        grammar: .code(CodeRules(
            lineComments: ["'", "REM ", "Rem ", "rem "], blockCommentOpen: nil, blockCommentClose: nil,
            strings: [doubleNoEscape],
            keywords: ["sub", "end", "function", "dim", "as", "if", "then", "else", "elseif", "for", "to", "next", "step", "each", "in", "while", "wend", "do", "loop", "until", "select", "case", "return", "exit", "call", "set", "let", "get", "public", "private", "protected", "friend", "shared", "static", "module", "class", "structure", "enum", "interface", "namespace", "imports", "inherits", "implements", "overrides", "overridable", "mustinherit", "notinheritable", "new", "me", "mybase", "nothing", "and", "or", "not", "xor", "andalso", "orelse", "is", "isnot", "typeof", "try", "catch", "finally", "throw", "with", "property", "readonly", "writeonly", "byval", "byref", "optional", "paramarray", "const", "delegate", "event", "raiseevent", "addhandler", "removehandler", "handles", "goto", "on", "error", "resume", "option", "explicit", "strict", "attribute", "declare", "lib", "redim", "preserve"],
            types: ["integer", "long", "string", "boolean", "double", "single", "object", "variant", "date", "byte", "char", "decimal", "short", "uinteger", "ulong"],
            builtins: ["true", "false", "msgbox", "inputbox", "len", "mid", "left", "right", "trim", "ucase", "lcase", "cstr", "cint", "cdbl", "isnumeric", "format", "now", "debug", "console", "wscript"],
            caseInsensitiveKeywords: true, honorsShebang: false)),
        lineComment: "'", symbol: codeSymbol)

    static let csv = Language(id: "csv", name: "CSV", extensions: ["csv", "tsv"], grammar: .plain,
                              lineComment: nil, indentUnit: "", indentAfterSuffixes: [], dedentPrefixes: [],
                              symbol: "tablecells")

    static let restructuredText = Language(id: "rst", name: "reStructuredText", extensions: ["rst", "rest"],
                                           grammar: .plain, lineComment: nil, indentUnit: "   ",
                                           indentAfterSuffixes: [], dedentPrefixes: [], symbol: "doc.text")

    static let extra: [Language] = [
        fortran, cobol, ada, pascal, matlab, assembly, gdscript, solidity, lisp, prolog, nim, crystal,
        cuda, verilog, vhdl, latex, cmake, starlark, batch, visualBasic, csv, restructuredText,
    ]

    /// `.m` is Objective-C unless the text is unmistakably MATLAB/Octave. Called once a document's
    /// content is known; returns nil when the detected language stands.
    static func refine(_ detected: Language, url: URL, content: String) -> Language? {
        guard detected.id == "objc", url.pathExtension.lowercased() == "m" else { return nil }
        let head = String(content.prefix(4096))
        if ["#import", "#include", "@interface", "@implementation", "@end", "@class", "NSString"].contains(where: head.contains) {
            return nil
        }
        let matlabSigns = ["function ", "disp(", "fprintf(", "%{", "end\n", "endfunction", "zeros(", "linspace("]
        let commentLines = head.split(separator: "\n").filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("%") }.count
        return matlabSigns.contains(where: head.contains) || commentLines > 0 ? matlab : nil
    }
}
