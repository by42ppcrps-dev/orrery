import Foundation

/// Language breadth: every registered language highlights from its own rules, every declared
/// extension maps back to its language, the breadth checkers parse their tools' real output
/// formats (and run live where the tool is installed), project and single-file tasks are
/// derived for the added ecosystems with missing tools named, and the language-server table
/// names each server honestly whether or not it is installed.
@MainActor
enum AuditLanguages {
    static func run(_ audit: Auditor) async {
        audit.section("Languages — every registered language highlights from its own rules")
        audit.check("the registry covers the major languages (67 or more)", Languages.all.count >= 67, "\(Languages.all.count)")
        let objcFile = URL(fileURLWithPath: "/tmp/sample.m")
        audit.check(".m with Objective-C content stays Objective-C",
                    Languages.refine(Languages.objc, url: objcFile, content: "#import <Foundation/Foundation.h>\n@interface A : NSObject\n@end\n") == nil)
        audit.equal(".m with MATLAB content becomes MATLAB",
                    Languages.refine(Languages.objc, url: objcFile, content: "% add two numbers\nfunction r = add(a, b)\n  r = a + b;\nend\n")?.id, "matlab")
        audit.check(".m with nothing telling stays Objective-C", Languages.refine(Languages.objc, url: objcFile, content: "x = 1\n") == nil)
        audit.check("refine never touches other extensions", Languages.refine(Languages.objc, url: URL(fileURLWithPath: "/tmp/a.mm"), content: "function r = f()\n") == nil)
        for language in Languages.all {
            guard case let .code(rules) = language.grammar else { continue }
            var sample = ""
            if let comment = rules.lineComments.first { sample += comment + " note\n" }
            else if let open = rules.blockCommentOpen, let close = rules.blockCommentClose { sample += open + " note " + close + "\n" }
            if let keyword = rules.keywords.sorted().first { sample += keyword + " x\n" }
            if let rule = rules.strings.first(where: { $0.interpolation == nil && !$0.isRegex }) ?? rules.strings.first {
                sample += rule.open + "text" + rule.close + "\n"
            }
            let kinds = Set(Tokenizer.tokens(for: sample, language: language).map(\.kind))
            audit.check("\(language.name) highlights a comment, a keyword and a string from its own rules",
                        kinds.isSuperset(of: [.comment, .keyword, .string]), "\(kinds.map(\.rawValue).sorted())")
            audit.check("\(language.name) tokenizes a broken input without crashing",
                        !Tokenizer.tokens(for: sample + rule(rules) + "\n\"unterminated\n(* {- /* --[[ #= <#", language: language).isEmpty)
        }
        for language in Languages.all {
            for ext in language.extensions {
                let detected = Languages.forFile(URL(fileURLWithPath: "sample." + ext))
                audit.equal("extension .\(ext) maps to \(language.name)", detected.id, language.id)
            }
        }

        audit.section("Languages — checkers parse their tools' real output and are named when missing")
        let file = URL(fileURLWithPath: "/tmp/sample.txt")
        func result(_ text: String, status: Int32 = 1) -> ProcessRunner.Result {
            ProcessRunner.Result(status: status, standardOutput: "", standardError: text, timedOut: false)
        }
        let php = Checkers.php.parse(result("PHP Parse error:  syntax error, unexpected token \"}\" in /tmp/sample.php on line 3\nErrors parsing /tmp/sample.php"), file)
        audit.check("php -l output parses to the right line", php.first?.line == 3 && php.first?.message.contains("unexpected token") == true, "\(php)")
        let perl = Checkers.perl.parse(result("syntax error at /tmp/sample.pl line 4, near \"print\"\n/tmp/sample.pl had compilation errors."), file)
        audit.check("perl -c output parses to the right line", perl.first?.line == 4 && perl.first?.message == "syntax error", "\(perl)")
        audit.check("perl's syntax OK line is not a diagnostic", Checkers.perl.parse(result("/tmp/sample.pl syntax OK", status: 0), file).isEmpty)
        let lua = Checkers.lua.parse(result("luac: /tmp/sample.lua:2: '=' expected near 'x'"), file)
        audit.check("luac -p output parses to the right line", lua.first?.line == 2 && lua.first?.message == "'=' expected near 'x'", "\(lua)")
        let java = Checkers.java.parse(result("/tmp/Sample.java:5: error: ';' expected\n    int x = 1\n             ^\n1 error"), file)
        audit.check("javac output parses to the right line", java.first?.line == 5 && java.first?.message == "';' expected", "\(java)")
        let zig = Checkers.zig.parse(result("/tmp/sample.zig:3:5: error: expected ';' after statement"), file)
        audit.check("zig ast-check output parses line and column", zig.first?.line == 3 && zig.first?.column == 5, "\(zig)")
        let r = Checkers.r.parse(result("Error in parse(file = commandArgs(trailingOnly = TRUE)[1]) : \n  /tmp/sample.R:2:3: unexpected symbol\n1: x <- 1\n2: y z"), file)
        audit.check("Rscript parse output parses line and column", r.first?.line == 2 && r.first?.column == 3 && r.first?.message == "unexpected symbol", "\(r)")
        let dart = Checkers.dart.parse(result("ERROR|SYNTACTIC_ERROR|EXPECTED_TOKEN|/tmp/sample.dart|3|5|1|Expected to find ';'."), file)
        audit.check("dart analyze machine output parses", dart.first?.line == 3 && dart.first?.column == 5 && dart.first?.message == "Expected to find ';'.", "\(dart)")
        let haskell = Checkers.haskell.parse(result("/tmp/sample.hs:3:5: error: [GHC-58481]\n    parse error on input 'x'\n"), file)
        audit.check("ghc output joins its indented message", haskell.first?.line == 3 && haskell.first?.message.contains("parse error on input") == true, "\(haskell)")
        for (id, name) in [("php", "php -l"), ("perl", "perl -c"), ("lua", "luac -p"), ("java", "javac"), ("zig", "zig ast-check"),
                           ("r", "Rscript parse"), ("dart", "dart analyze"), ("haskell", "ghc -fno-code")] {
            guard let language = Languages.byID(id) else { audit.check("language \(id) exists", false); continue }
            audit.check("\(language.name) has a checker candidate named \(name)", Checkers.candidates(for: language).first?.name == name)
            if Checkers.resolve(for: language) == nil {
                audit.check("\(language.name) names its missing checker instead of reporting clean",
                            Checkers.unavailableNote(for: language).contains(name) && Checkers.unavailableNote(for: language).contains("not installed"))
            }
        }
        for (id, name) in [("csharp", "C#"), ("scala", "Scala"), ("kotlin", "Kotlin")] {
            if let language = Languages.byID(id), Checkers.candidates(for: language).isEmpty {
                audit.check("\(name) without a checker says so", Checkers.unavailableNote(for: language).contains("No checker"))
            }
        }
        await Auditor.withTemporaryDirectory { directory in
            // Live checks for tools present on this Mac. Absent tools are covered by the fixtures above.
            let live: [(Language, Checker, String, String, Int)] = [
                (Languages.perl, Checkers.perl, "broken.pl", "print \"hi\"\nmy $x = ;\n", 2),
                (Languages.java, Checkers.java, "Sample.java", "class Sample {\n    void run() {\n        int x = 1\n    }\n}\n", 3),
                (Languages.php, Checkers.php, "broken.php", "<?php\necho 'a';\nfunction f( {\n", 3),
                (Languages.lua, Checkers.lua, "broken.lua", "local x = 1\nlocal y = = 2\n", 2),
                (Languages.zig, Checkers.zig, "broken.zig", "const std = @import(\"std\");\npub fn main() void {\n    var x = \n}\n", 3),
            ]
            for (language, checker, name, text, expectedLine) in live {
                guard let path = checker.locate() else { continue }
                let url = directory.appendingPathComponent(name)
                try? text.write(to: url, atomically: true, encoding: .utf8)
                let output = try? await ProcessRunner.run(path, checker.arguments(url), cwd: directory, timeout: 30)
                let diagnostics = output.map { checker.parse($0, url) } ?? []
                audit.check("\(language.name): \(checker.name) reports the broken line live",
                            diagnostics.contains { $0.line == expectedLine }, "\(output?.combined.prefix(300) ?? "no output")")
            }
        }

        audit.section("Languages — project and single-file tasks for the added ecosystems")
        await Auditor.withTemporaryDirectory { directory in
            let project = directory.appendingPathComponent("polyglot")
            try? FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            for name in ["build.gradle.kts", "pom.xml", "CMakeLists.txt", "app.csproj", "mix.exs", "build.zig", "pubspec.yaml",
                         "pyproject.toml", "Rakefile", "stack.yaml", "deno.json"] {
                try? "".write(to: project.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
            let tasks = TaskCatalog.tasks(project: project, activeFile: nil, language: nil)
            let titles = Set(tasks.map(\.title))
            for expected in ["gradle build", "gradle test", "gradle run", "mvn compile", "mvn test", "cmake -S . -B build",
                             "cmake --build build", "ctest --test-dir build", "dotnet build", "dotnet test", "dotnet run",
                             "mix compile", "mix test", "zig build", "zig build test", "dart run", "dart test",
                             "python3 -m pytest", "rake test", "stack build", "stack test", "deno test"] {
                audit.check("detects \(expected)", titles.contains(expected))
            }
            audit.check("every task names its source file", tasks.allSatisfy { !$0.source.isEmpty })
            for task in tasks where task.executable == nil {
                audit.check("\(task.title) names its missing tool", task.missingTool != nil && !task.missingTool!.isEmpty)
            }
            for task in tasks where task.executable != nil {
                audit.check("\(task.title) points at an executable", FileManager.default.isExecutableFile(atPath: task.executable!))
            }
            audit.check("gradle build is classified as a build", tasks.first { $0.title == "gradle build" }?.kind == .build)
            audit.check("mix test is classified as a test", tasks.first { $0.title == "mix test" }?.kind == .test)
            let fileCases: [(String, String, String)] = [
                ("main.go", "go", "go run main.go"), ("index.php", "php", "php index.php"), ("tool.pl", "perl", "perl tool.pl"),
                ("game.lua", "lua", "lua game.lua"), ("stats.R", "r", "Rscript stats.R"), ("Main.java", "java", "java Main.java"),
                ("build.main.kts", "kotlin", "kotlinc -script build.main.kts"), ("main.zig", "zig", "zig run main.zig"),
                ("main.dart", "dart", "dart run main.dart"), ("script.exs", "elixir", "elixir script.exs"),
                ("sim.jl", "julia", "julia sim.jl"), ("deploy.ps1", "powershell", "pwsh deploy.ps1"),
                ("Main.hs", "haskell", "runghc Main.hs"), ("build.groovy", "groovy", "groovy build.groovy"),
                ("app.ts", "typescript", "deno run app.ts"), ("lone.rs", "rust", "rustc lone.rs"),
                ("script.csx", "csharp", "dotnet script script.csx"), ("core.clj", "clojure", "clojure -M core.clj"),
                ("main.ml", "ocaml", "ocaml main.ml"), ("script.fsx", "fsharp", "dotnet fsi script.fsx"),
            ]
            for (name, languageID, title) in fileCases {
                let language = Languages.byID(languageID)!
                let fileTasks = TaskCatalog.tasks(project: nil, activeFile: project.appendingPathComponent(name), language: language)
                audit.check("\(language.name) file offers \(title)", fileTasks.contains { $0.title == title && ($0.executable != nil || $0.missingTool != nil) },
                            fileTasks.map(\.title).joined(separator: ", "))
            }
            audit.check("a .edn data file offers no run task", TaskCatalog.tasks(project: nil, activeFile: project.appendingPathComponent("data.edn"), language: Languages.clojure).isEmpty)
            audit.check("a Kotlin source file without a script extension offers no run task", TaskCatalog.tasks(project: nil, activeFile: project.appendingPathComponent("Main.kt"), language: Languages.kotlin).isEmpty)
        }

        audit.section("Languages — third-batch checkers parse their tools' output and never run the file")
        let f90 = URL(fileURLWithPath: "/tmp/sample.f90")
        let fortran = Checkers.gfortran.parse(result("/tmp/sample.f90:3:10:\n\n    3 |   x = \n      |          1\nError: Invalid character in name at (1)\n/tmp/sample.f90:5:1:\n\nWarning: Unused variable 'y' declared at (1) [-Wunused-variable]\n"), f90)
        audit.check("gfortran attaches each message to the location line before it",
                    fortran.count == 2 && fortran[0].line == 3 && fortran[0].column == 10 && fortran[0].message.hasPrefix("Invalid character")
                    && fortran[1].line == 5 && fortran[1].severity == .warning, "\(fortran)")
        let cobol = Checkers.cobc.parse(result("/tmp/sample.cob:5: error: syntax error, unexpected Identifier\n/tmp/sample.cob:9: warning: 'X' defined here\n"), file)
        audit.check("cobc line messages parse with severity", cobol.count == 2 && cobol[0].line == 5 && cobol[0].severity == .error && cobol[1].severity == .warning, "\(cobol)")
        let ada = Checkers.gnat.parse(result("/tmp/sample.adb:3:05: missing \";\"\n"), file)
        audit.check("gnat line:column messages parse", ada.first?.line == 3 && ada.first?.column == 5 && ada.first?.message == "missing \";\"", "\(ada)")
        let pascal = Checkers.fpc.parse(result("/tmp/sample.pas(3,5) Error: Identifier not found \"x\"\n/tmp/sample.pas(7,1) Note: Local variable \"y\" not used\n"), file)
        audit.check("fpc (line,col) messages parse", pascal.count == 2 && pascal[0].line == 3 && pascal[0].column == 5 && pascal[1].severity == .warning, "\(pascal)")
        let nim = Checkers.nim.parse(result("/tmp/sample.nim(3, 5) Error: undeclared identifier: 'x'\n"), file)
        audit.check("nim check messages parse", nim.first?.line == 3 && nim.first?.column == 5 && nim.first?.message == "undeclared identifier: 'x'", "\(nim)")
        let crystal = Checkers.crystal.parse(result("Error: undefined method 'foo' for Nil\n\nIn /tmp/sample.cr:2:1\n\n 2 | foo\n     ^--\n"), file)
        let crystalSyntax = Checkers.crystal.parse(result("Syntax error in /tmp/sample.cr:4: unexpected token: EOF\n"), file)
        audit.check("crystal semantic and syntax shapes parse", crystal.first?.line == 2 && crystal.first?.message.hasPrefix("undefined method") == true
                    && crystalSyntax.first?.line == 4 && crystalSyntax.first?.message.contains("unexpected token") == true, "\(crystal) \(crystalSyntax)")
        let verilog = Checkers.iverilog.parse(result("/tmp/sample.v:3: syntax error\n/tmp/sample.v:3: error: Invalid module instantiation\n"), file)
        audit.check("iverilog line messages parse", verilog.count == 2 && verilog[0].line == 3 && verilog[0].message == "syntax error", "\(verilog)")
        let vhdl = Checkers.ghdl.parse(result("/tmp/sample.vhd:3:5:error: ';' is expected instead of 'x'\n"), file)
        audit.check("ghdl line:column messages parse", vhdl.first?.line == 3 && vhdl.first?.column == 5, "\(vhdl)")
        let tex = Checkers.chktex.parse(result("/tmp/sample.tex:4:12:Command terminated with space.\n"), file)
        audit.check("chktex fixed-format lines parse as warnings", tex.first?.line == 4 && tex.first?.column == 12 && tex.first?.severity == .warning, "\(tex)")
        let asm = Checkers.nasm.parse(result("/tmp/sample.asm:3: error: symbol `x' undefined\n"), file)
        audit.check("nasm messages parse", asm.first?.line == 3 && asm.first?.message.contains("undefined") == true, "\(asm)")
        let sol = Checkers.solc.parse(result("Error: Expected ';' but got 'x'\n --> /tmp/sample.sol:3:5:\n  |\n3 |     uint x\n  |     ^\n"), file)
        audit.check("solc arrow locations attach to the message above", sol.first?.line == 3 && sol.first?.column == 5 && sol.first?.message == "Expected ';' but got 'x'", "\(sol)")
        let bzl = Checkers.buildifier.parse(result("/tmp/BUILD:3:5: syntax error near )\n"), file)
        let bzlLint = Checkers.buildifier.parse(result("/tmp/BUILD:3: module-docstring: The file has no module docstring.\n"), file)
        audit.check("buildifier syntax and lint shapes parse", bzl.first?.line == 3 && bzl.first?.column == 5 && bzlLint.first?.line == 3 && bzlLint.first?.severity == .warning, "\(bzl) \(bzlLint)")
        let rst = Checkers.rst.parse(result("/tmp/sample.rst:3: (ERROR/3) Unexpected indentation.\n/tmp/sample.rst:5: (WARNING/2) Title underline too short.\n"), file)
        audit.check("rst2html system messages parse", rst.count == 2 && rst[0].line == 3 && rst[0].severity == .error && rst[1].severity == .warning, "\(rst)")
        for (id, name) in [("fortran", "gfortran -fsyntax-only"), ("cobol", "cobc -fsyntax-only"), ("ada", "gnatmake -gnatc"), ("pascal", "fpc"), ("nim", "nim check"),
                           ("crystal", "crystal build --no-codegen"), ("verilog", "iverilog -t null"), ("vhdl", "ghdl -s"), ("latex", "chktex"),
                           ("asm", "nasm -o /dev/null"), ("solidity", "solc --stop-after parsing"), ("starlark", "buildifier -lint=warn"), ("rst", "rst2html --exit-status=2")] {
            let language = Languages.byID(id)!
            audit.check("\(language.name) has a checker candidate named \(name)", Checkers.candidates(for: language).first?.name == name)
            if Checkers.resolve(for: language) == nil {
                audit.check("\(language.name) names its missing checker instead of reporting clean",
                            Checkers.unavailableNote(for: language).contains(name) && Checkers.unavailableNote(for: language).contains("not installed"))
            }
        }
        for id in ["prolog", "gdscript", "matlab", "batch", "vb", "csv"] {
            let language = Languages.byID(id)!
            audit.check("\(language.name) without a checker says so", Checkers.candidates(for: language).isEmpty && Checkers.unavailableNote(for: language).contains("No checker"))
        }
        await Auditor.withTemporaryDirectory { project in
            try? "cc_binary(name = \"app\")\n".write(to: project.appendingPathComponent("BUILD.bazel"), atomically: true, encoding: .utf8)
            try? "name = \"tool\"\n".write(to: project.appendingPathComponent("tool.nimble"), atomically: true, encoding: .utf8)
            try? "name: app\n".write(to: project.appendingPathComponent("shard.yml"), atomically: true, encoding: .utf8)
            try? "name = \"sim\"\n".write(to: project.appendingPathComponent("fpm.toml"), atomically: true, encoding: .utf8)
            let titles = Set(TaskCatalog.tasks(project: project, activeFile: nil, language: nil).map(\.title))
            for expected in ["bazel build //...", "bazel test //...", "nimble build", "nimble test", "shards build", "crystal spec", "fpm build", "fpm test", "fpm run"] {
                audit.check("detects \(expected)", titles.contains(expected))
            }
            let cases: [(String, String, String)] = [
                ("sim.f90", "fortran", "gfortran sim.f90"), ("payroll.cob", "cobol", "cobc -x payroll.cob"), ("main.adb", "ada", "gnatmake main.adb"),
                ("hello.pas", "pascal", "fpc hello.pas"), ("main.nim", "nim", "nim c -r main.nim"), ("app.cr", "crystal", "crystal run app.cr"),
                ("facts.pro", "prolog", "swipl facts.pro"), ("core.lisp", "lisp", "sbcl --script core.lisp"), ("main.rkt", "lisp", "racket main.rkt"),
                ("counter.v", "verilog", "iverilog counter.v"), ("alu.vhd", "vhdl", "ghdl -a alu.vhd"), ("paper.tex", "latex", "pdflatex paper.tex"),
                ("Token.sol", "solidity", "solc --bin Token.sol"), ("kernel.cu", "cuda", "nvcc kernel.cu"), ("script.vbs", "vb", "cscript script.vbs"),
            ]
            for (name, languageID, title) in cases {
                let language = Languages.byID(languageID)!
                let fileTasks = TaskCatalog.tasks(project: nil, activeFile: project.appendingPathComponent(name), language: language)
                audit.check("\(language.name) file offers \(title)", fileTasks.contains { $0.title == title && ($0.executable != nil || $0.missingTool != nil) },
                            fileTasks.map(\.title).joined(separator: ", "))
            }
            audit.check("an Ada spec offers no build task", TaskCatalog.tasks(project: nil, activeFile: project.appendingPathComponent("pkg.ads"), language: Languages.ada).isEmpty)
            audit.check("a Windows batch file offers no task on macOS", TaskCatalog.tasks(project: nil, activeFile: project.appendingPathComponent("run.bat"), language: Languages.batch).isEmpty)
        }

        audit.section("Languages — language servers are wired by name and honest about installation")
        let manager = LSPManager()
        for (id, server) in [("go", "gopls"), ("rust", "rust-analyzer"), ("python", "pyright-langserver"), ("typescript", "typescript-language-server"),
                             ("javascript", "typescript-language-server"), ("lua", "lua-language-server"), ("zig", "zls"), ("ruby", "solargraph"),
                             ("dart", "dart language-server"), ("haskell", "haskell-language-server"), ("kotlin", "kotlin-language-server"),
                             ("shell", "bash-language-server"), ("swift", "sourcekit-lsp"), ("c", "clangd"),
                             ("fortran", "fortls"), ("nim", "nimlangserver"), ("crystal", "crystalline"), ("latex", "texlab"),
                             ("solidity", "nomicfoundation-solidity-language-server"), ("ada", "ada_language_server"), ("pascal", "pasls"),
                             ("cmake", "cmake-language-server"), ("verilog", "verible-verilog-ls"), ("vhdl", "vhdl_ls")] {
            let language = Languages.byID(id)!
            audit.check("\(language.name) is wired to \(server)", manager.isSupported(language) && LSPManager.serverName(for: language) == server)
            let note = manager.unavailableNote(for: language)
            if manager.executable(for: language) == nil {
                audit.check("\(language.name) names the missing \(server)", note?.contains(server) == true && note?.contains("not installed") == true, note ?? "nil")
            } else {
                audit.check("\(language.name) has \(server) available or running", note == nil || note?.contains(server) == true, note ?? "nil")
            }
        }
        for id in ["csharp", "scala", "php", "elixir"] {
            let language = Languages.byID(id)!
            audit.check("\(language.name) says no language server is wired", !manager.isSupported(language) && manager.unavailableNote(for: language)?.contains("No language server wired") == true)
        }
        audit.check("a stopped breadth server names a generic fallback", LSPManager.stoppedNote(server: "gopls").contains("one-shot checker"))
        audit.check("a stopped clangd still names clang", LSPManager.stoppedNote(server: "clangd").contains("clang -fsyntax-only"))
        manager.shutdownAll()
    }

    private static func rule(_ rules: CodeRules) -> String {
        (rules.strings.first?.open ?? "\"") + "still open"
    }
}
