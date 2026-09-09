import Foundation

/// Checks that the highlighter labels real code correctly, rather than merely running.
/// Each check names the exact substring it expects a kind for, so a failure says what broke.
@MainActor
enum AuditTokenizer {

    /// Kind of the token that exactly covers the nth occurrence of `needle`, or the token that
    /// contains it when no token matches exactly.
    static func kind(of needle: String, in text: String, _ language: Language,
                     occurrence: Int = 1) -> TokenKind? {
        let nsText = text as NSString
        var searchFrom = 0
        var found = NSRange(location: NSNotFound, length: 0)
        for _ in 0..<occurrence {
            found = nsText.range(of: needle,
                                 range: NSRange(location: searchFrom,
                                                length: nsText.length - searchFrom))
            guard found.location != NSNotFound else { return nil }
            searchFrom = found.location + max(1, found.length)
        }
        guard found.location != NSNotFound else { return nil }
        let tokens = Tokenizer.tokens(for: text, language: language)
        if let exact = tokens.last(where: { NSEqualRanges($0.range, found) }) { return exact.kind }
        // Otherwise: the token covering the first character of the match. Later tokens win,
        // matching how attributes are applied to the text storage.
        return tokens.last {
            $0.range.location <= found.location
                && $0.range.location + $0.range.length > found.location
        }?.kind
    }

    static func run(_ audit: Auditor) {
        audit.section("Tokenizer — languages")

        func expect(_ label: String, _ needle: String, _ text: String, _ language: Language,
                    _ expected: TokenKind, occurrence: Int = 1) {
            let actual = kind(of: needle, in: text, language, occurrence: occurrence)
            audit.check("\(language.name): \(label)", actual == expected,
                        "\(needle.debugDescription) → \(actual.map(\.rawValue) ?? "no token"), "
                        + "expected \(expected.rawValue)")
        }

        // ---- Swift ----------------------------------------------------------------------
        let swiftSample = """
        import Foundation

        /// Doc comment.
        @MainActor
        final class Parser {
            let limit = 1_000
            var name: String = "hello \\(world) there"
            #if DEBUG
            let raw = #"no \\(escape) here"#
            #endif
            /* outer /* nested */ still comment */
            func parse() throws -> Int? {
                print("value: \\(limit)")
                return nil
            }
        }
        """
        expect("keyword", "import", swiftSample, Languages.swift, .keyword)
        expect("keyword let", "let", swiftSample, Languages.swift, .keyword)
        expect("type", "String", swiftSample, Languages.swift, .type)
        expect("doc comment", "/// Doc comment.", swiftSample, Languages.swift, .docComment)
        expect("attribute", "@MainActor", swiftSample, Languages.swift, .attribute)
        expect("number with separator", "1_000", swiftSample, Languages.swift, .number)
        expect("directive", "#if", swiftSample, Languages.swift, .directive)
        expect("builtin nil", "nil", swiftSample, Languages.swift, .builtin)
        expect("known builtin stays a builtin", "print", swiftSample, Languages.swift, .builtin)
        expect("user function call", "parse", swiftSample, Languages.swift, .function)
        expect("interpolation opens", "\\(", swiftSample, Languages.swift, .interpolation)
        audit.check("Swift: interpolated identifier is code, not string",
                    kind(of: "world", in: swiftSample, Languages.swift) == nil,
                    "got \(kind(of: "world", in: swiftSample, Languages.swift)?.rawValue ?? "nil")")
        audit.check("Swift: nested block comment closes only at the outer */",
                    kind(of: "still comment", in: swiftSample, Languages.swift) == .comment,
                    "got \(kind(of: "still comment", in: swiftSample, Languages.swift)?.rawValue ?? "none")")
        audit.check("Swift: raw string suppresses interpolation",
                    kind(of: "escape", in: swiftSample, Languages.swift) == .string,
                    "got \(kind(of: "escape", in: swiftSample, Languages.swift)?.rawValue ?? "none")")

        // ---- Python ----------------------------------------------------------------------
        let pythonSample = #"""
        #!/usr/bin/env python3
        import os
        from typing import Optional

        @dataclass
        class Point:
            \"\"\"A point.\"\"\"
            x: int = 0

            def dist(self, other: "Point") -> float:
                total = 0x1f + 1_000 + 2.5e3
                label = f"x={self.x} y={other.x}"
                raw = r"C:\nope"
                return total  # trailing comment
        """#
        expect("shebang", "#!/usr/bin/env python3", pythonSample, Languages.python, .comment)
        expect("keyword", "class Point", pythonSample, Languages.python, .keyword)
        expect("decorator", "@dataclass", pythonSample, Languages.python, .attribute)
        expect("type", "int = 0", pythonSample, Languages.python, .type)
        expect("builtin self", "self", pythonSample, Languages.python, .builtin)
        expect("hex number", "0x1f", pythonSample, Languages.python, .number)
        expect("float exponent", "2.5e3", pythonSample, Languages.python, .number)
        expect("trailing comment", "# trailing comment", pythonSample, Languages.python, .comment)
        audit.check("Python: raw string keeps its backslash as string, not escape",
                    kind(of: #"\n"#, in: pythonSample, Languages.python) == .string,
                    "got \(kind(of: #"\n"#, in: pythonSample, Languages.python)?.rawValue ?? "none")")
        audit.check("Python: triple-quoted docstring is one string",
                    kind(of: "A point.", in: pythonSample, Languages.python) == .string,
                    "got \(kind(of: "A point.", in: pythonSample, Languages.python)?.rawValue ?? "none")")

        // ---- JSON ------------------------------------------------------------------------
        let jsonSample = """
        {
          "name": "grok-studio",
          "version": 2,
          "nested": { "enabled": true, "ratio": -1.5e-3, "missing": null },
          "list": ["a", "b"]
        }
        """
        expect("key", "\"name\"", jsonSample, Languages.json, .key)
        expect("string value", "\"grok-studio\"", jsonSample, Languages.json, .string)
        expect("number", "2", jsonSample, Languages.json, .number)
        expect("negative exponent", "-1.5e-3", jsonSample, Languages.json, .number)
        expect("true", "true", jsonSample, Languages.json, .builtin)
        expect("null", "null", jsonSample, Languages.json, .builtin)
        expect("array element is a value, not a key", "\"a\"", jsonSample, Languages.json, .string)
        audit.check("JSON: a bare word is flagged invalid",
                    kind(of: "oops", in: "{\"k\": oops}", Languages.json) == .invalid)

        // ---- JavaScript / TypeScript -----------------------------------------------------
        let jsSample = """
        const greet = (name) => {
          // say hello
          console.log(`hi ${name.trim()}, you are ${age} years old`);
          return /^[a-z]+$/.test(name);
        };
        """
        expect("keyword const", "const", jsSample, Languages.javascript, .keyword)
        expect("builtin console", "console", jsSample, Languages.javascript, .builtin)
        expect("template literal", "hi ", jsSample, Languages.javascript, .string)
        expect("template interpolation", "${", jsSample, Languages.javascript, .interpolation)
        audit.check("JavaScript: identifier inside ${} is code",
                    kind(of: "trim", in: jsSample, Languages.javascript) == .function,
                    "got \(kind(of: "trim", in: jsSample, Languages.javascript)?.rawValue ?? "none")")

        let tsSample = "export interface Config { readonly retries: number; name?: string }"
        expect("interface keyword", "interface", tsSample, Languages.typescript, .keyword)
        expect("primitive type", "number", tsSample, Languages.typescript, .type)

        // ---- Markdown --------------------------------------------------------------------
        let markdownSample = """
        # Title

        Some **bold** and `inline code` and a [link](https://x.ai).

        ```python
        def f(): return 1
        ```

        > quoted
        """
        expect("heading", "# Title", markdownSample, Languages.markdown, .heading)
        expect("bold", "**bold**", markdownSample, Languages.markdown, .emphasis)
        expect("inline code", "`inline code`", markdownSample, Languages.markdown, .string)
        expect("link text", "[link]", markdownSample, Languages.markdown, .link)
        expect("blockquote", "> quoted", markdownSample, Languages.markdown, .comment)
        audit.check("Markdown: fenced python is highlighted as python",
                    kind(of: "def", in: markdownSample, Languages.markdown) == .keyword,
                    "got \(kind(of: "def", in: markdownSample, Languages.markdown)?.rawValue ?? "none")")

        // ---- YAML ------------------------------------------------------------------------
        let yamlSample = """
        # comment
        version: 2
        jobs:
          - name: build
            enabled: true
            script: |
              echo hi
              echo there
          - name: test
        """
        expect("comment", "# comment", yamlSample, Languages.yaml, .comment)
        expect("top-level key", "version", yamlSample, Languages.yaml, .key)
        expect("nested key", "enabled", yamlSample, Languages.yaml, .key)
        expect("boolean", "true", yamlSample, Languages.yaml, .builtin)
        audit.check("YAML: block scalar body is a string",
                    kind(of: "echo hi", in: yamlSample, Languages.yaml) == .string,
                    "got \(kind(of: "echo hi", in: yamlSample, Languages.yaml)?.rawValue ?? "none")")
        audit.check("YAML: block scalar ends at the dedent",
                    kind(of: "- name: test", in: yamlSample, Languages.yaml) != .string)

        // ---- TOML ------------------------------------------------------------------------
        let tomlSample = """
        # config
        [server]
        host = "0.0.0.0"
        port = 8080
        debug = false
        """
        expect("section", "[server]", tomlSample, Languages.toml, .heading)
        expect("key", "host ", tomlSample, Languages.toml, .key)
        expect("string value", "\"0.0.0.0\"", tomlSample, Languages.toml, .string)
        expect("number value", "8080", tomlSample, Languages.toml, .number)

        // ---- HTML ------------------------------------------------------------------------
        let htmlSample = """
        <!DOCTYPE html>
        <div class="row" id='main'>
          <!-- a comment -->
          &amp;
          <script>const x = 1;</script>
        </div>
        """
        expect("doctype", "<!DOCTYPE html>", htmlSample, Languages.html, .directive)
        expect("tag", "<div", htmlSample, Languages.html, .tag)
        expect("attribute name", "class", htmlSample, Languages.html, .key)
        expect("attribute value", "\"row\"", htmlSample, Languages.html, .string)
        expect("comment", "<!-- a comment -->", htmlSample, Languages.html, .comment)
        expect("entity", "&amp;", htmlSample, Languages.html, .escape)
        audit.check("HTML: <script> body is JavaScript",
                    kind(of: "const", in: htmlSample, Languages.html) == .keyword,
                    "got \(kind(of: "const", in: htmlSample, Languages.html)?.rawValue ?? "none")")

        // ---- Shell -----------------------------------------------------------------------
        let shellSample = """
        #!/usr/bin/env bash
        set -euo pipefail
        NAME="${1:-world}"
        if [ -n "$NAME" ]; then
          echo "hello $NAME"   # greet
        fi
        """
        expect("shebang", "#!/usr/bin/env bash", shellSample, Languages.shell, .comment)
        expect("keyword if", "if", shellSample, Languages.shell, .keyword)
        expect("builtin echo", "echo", shellSample, Languages.shell, .builtin)
        expect("variable", "$NAME", shellSample, Languages.shell, .interpolation, occurrence: 2)

        // ---- SQL (case-insensitive keywords) ---------------------------------------------
        let sqlSample = "SELECT id, name FROM users where active = TRUE -- note\nlimit 10;"
        expect("uppercase keyword", "SELECT", sqlSample, Languages.sql, .keyword)
        expect("lowercase keyword", "where", sqlSample, Languages.sql, .keyword)
        expect("line comment", "-- note", sqlSample, Languages.sql, .comment)
        expect("builtin TRUE", "TRUE", sqlSample, Languages.sql, .builtin)

        // ---- Go / Rust / C / Java ---------------------------------------------------------
        let goSample = "package main\nfunc main() { s := `raw\nstring`; fmt.Println(s) }"
        expect("keyword", "package", goSample, Languages.go, .keyword)
        audit.check("Go: backtick string spans lines",
                    kind(of: "string`", in: goSample, Languages.go) == .string,
                    "got \(kind(of: "string`", in: goSample, Languages.go)?.rawValue ?? "none")")

        let rustSample = "#[derive(Debug)]\npub fn main() { let v: Vec<u8> = vec![1u8]; }"
        expect("attribute", "#[", rustSample, Languages.rust, .attribute)
        expect("keyword", "fn", rustSample, Languages.rust, .keyword)
        expect("type", "Vec", rustSample, Languages.rust, .type)
        expect("suffixed literal", "1u8", rustSample, Languages.rust, .number)

        let cSample = "#include <stdio.h>\nint main(void) { printf(\"hi\\n\"); return 0; }"
        expect("include directive", "#include", cSample, Languages.c, .directive)
        expect("type", "int", cSample, Languages.c, .type)
        expect("escape in string", "\\n", cSample, Languages.c, .escape)

        let javaSample = "@Override\npublic static void main(String[] args) { System.out.println(1); }"
        expect("annotation", "@Override", javaSample, Languages.java, .attribute)
        expect("keyword", "public", javaSample, Languages.java, .keyword)

        // ---- Ruby / Lua / Makefile / Dockerfile -------------------------------------------
        let rubySample = "def greet(name)\n  puts \"hi #{name.upcase}\"\nend"
        expect("keyword def", "def", rubySample, Languages.ruby, .keyword)
        expect("interpolation", "#{", rubySample, Languages.ruby, .interpolation)

        let luaSample = "-- note\nlocal t = [[multi\nline]]\nprint(t)"
        expect("comment", "-- note", luaSample, Languages.lua, .comment)
        expect("long string", "line]]", luaSample, Languages.lua, .string)

        let makeSample = "CC = clang\n.PHONY: all\nall:\n\t$(CC) -o out main.c  # build"
        expect("directive", ".PHONY", makeSample, Languages.makefile, .keyword)
        expect("variable", "$(", makeSample, Languages.makefile, .directive)

        let dockerSample = "# base\nFROM swift:6.0 AS build\nRUN swift build -c release"
        expect("instruction", "FROM", dockerSample, Languages.dockerfile, .keyword)
        expect("comment", "# base", dockerSample, Languages.dockerfile, .comment)

        // ---- Detection -------------------------------------------------------------------
        audit.section("Tokenizer — file detection")
        let expectedLanguage: [(String, String)] = [
            ("a/b/main.swift", "swift"), ("x.py", "python"), ("data.json", "json"),
            ("Package.swift", "swift"), ("Makefile", "makefile"), ("Dockerfile", "dockerfile"),
            ("readme.MD", "markdown"), ("style.SCSS", "css"), ("q.SQL", "sql"),
            ("app.tsx", "typescript"), ("index.html", "html"), ("icon.svg", "xml"),
            ("Info.plist", "xml"), ("config.toml", "toml"), (".zshrc", "shell"),
            ("deploy.yml", "yaml"), ("main.go", "go"), ("lib.rs", "rust"),
            ("View.m", "objc"), ("App.kt", "kotlin"), ("index.php", "php"),
            ("notes.txt", "text"), ("no-extension-at-all", "text"),
        ]
        for (path, languageID) in expectedLanguage {
            let detected = Languages.forFile(URL(fileURLWithPath: path))
            audit.check("detect \(path)", detected.id == languageID,
                        "got \(detected.id), expected \(languageID)")
        }

        // ---- Invariants ------------------------------------------------------------------
        audit.section("Tokenizer — invariants")
        let corpus: [(String, Language)] = [
            (swiftSample, Languages.swift), (pythonSample, Languages.python),
            (jsonSample, Languages.json), (jsSample, Languages.javascript),
            (markdownSample, Languages.markdown), (yamlSample, Languages.yaml),
            (tomlSample, Languages.toml), (htmlSample, Languages.html),
            (shellSample, Languages.shell), (sqlSample, Languages.sql),
            (goSample, Languages.go), (rustSample, Languages.rust), (cSample, Languages.c),
            (javaSample, Languages.java), (rubySample, Languages.ruby),
            (luaSample, Languages.lua), (makeSample, Languages.makefile),
            (dockerSample, Languages.dockerfile), (tsSample, Languages.typescript),
        ]
        var badRange = 0
        for (text, language) in corpus {
            let length = (text as NSString).length
            for token in Tokenizer.tokens(for: text, language: language)
            where token.range.location < 0 || token.range.length < 0
                || token.range.location + token.range.length > length {
                badRange += 1
            }
        }
        audit.check("every token range is inside its document", badRange == 0,
                    "\(badRange) out-of-bounds token(s)")

        // Truncating a file at every prefix must never crash or run away — this is the shape
        // an editor sees on every keystroke.
        var prefixFailures = 0
        for (text, language) in corpus {
            let characters = Array(text)
            var step = 1
            while step < characters.count {
                let prefix = String(characters[0..<step])
                let length = (prefix as NSString).length
                for token in Tokenizer.tokens(for: prefix, language: language)
                where token.range.location + token.range.length > length { prefixFailures += 1 }
                step += 7
            }
        }
        audit.check("every truncated prefix tokenizes in bounds", prefixFailures == 0,
                    "\(prefixFailures) bad token(s)")

        // Every registered language must tokenize without producing nonsense on empty input.
        var emptyFailures = 0
        for language in Languages.all where !Tokenizer.tokens(for: "", language: language).isEmpty {
            emptyFailures += 1
        }
        audit.check("empty input yields no tokens for all \(Languages.all.count) languages",
                    emptyFailures == 0)

        // Adversarial input. An editor tokenizes on every keystroke, so a scanner that walks
        // off the end is a crash in the user's document, not a cosmetic bug. Deterministic
        // seed, so a failure here is replayable.
        struct Rand {
            var state: UInt64
            mutating func next() -> UInt64 {
                state ^= state << 13; state ^= state >> 7; state ^= state << 17; return state
            }
            mutating func int(_ bound: Int) -> Int { Int(next() % UInt64(max(1, bound))) }
        }
        let atoms = ["{", "}", "[", "]", "(", ")", "<", ">", "\"", "'", "`", "\\", "/", "*", "-",
                     "#", "@", "$", "!", "?", ":", ";", ",", ".", "=", "+", "|", "&", "^", "~",
                     "_", " ", "\n", "\t", "a", "XYZ", "0", "19", "\"\"\"", "'''", "```",
                     "<!--", "-->", "]]>", "${", "\\(", "#{", "r\"", "f\"", "b'", "0x1f", "1_0",
                     "--", "//", "/*", "*/", "<script>", "</script>", "&amp;", "---", "...",
                     "[[", "]]", "=begin", "=end", "#!", "def", "class", "end", "é", "中", "😀",
                     "\r\n", "#\"", "\"#", "r#\""]
        var rand = Rand(state: 0x9E37_79B9_7F4A_7C15)
        var fuzzed = 0
        var outOfBounds = 0
        for language in Languages.all {
            for _ in 0..<60 {
                var text = ""
                for _ in 0..<(rand.int(60) + 1) { text += atoms[rand.int(atoms.count)] }
                let characters = Array(text)
                let stride = max(1, characters.count / 6)
                var step = stride
                while step <= characters.count {
                    let prefix = String(characters[0..<step])
                    let length = (prefix as NSString).length
                    for token in Tokenizer.tokens(for: prefix, language: language)
                    where token.range.location < 0 || token.range.length < 0
                        || token.range.location + token.range.length > length { outOfBounds += 1 }
                    fuzzed += 1
                    step += stride
                }
            }
        }
        audit.check("fuzz: \(fuzzed) adversarial documents tokenize in bounds without crashing",
                    outOfBounds == 0, "\(outOfBounds) bad token(s)")

        // Every language must have a unique id and at least one way to be detected.
        let ids = Set(Languages.all.map(\.id))
        audit.check("language ids are unique", ids.count == Languages.all.count)
        // MATLAB shares `.m` with Objective-C and is reached by content instead.
        let contentDetected: Set<String> = ["matlab"]
        let undetectable = Languages.all.filter { $0.extensions.isEmpty && $0.filenames.isEmpty && !contentDetected.contains($0.id) }
        audit.check("every language is reachable from a filename or, for MATLAB, from content",
                    undetectable.isEmpty && Languages.refine(Languages.objc, url: URL(fileURLWithPath: "/tmp/a.m"), content: "function r = f()\nend\n")?.id == "matlab",
                    undetectable.map(\.id).joined(separator: ","))
    }
}
