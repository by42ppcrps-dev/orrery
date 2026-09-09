import Foundation

/// Project and single-file tasks for the breadth ecosystems. Same rule as the core table:
/// derived from files that exist, and a missing tool is named instead of the task vanishing.
extension TaskCatalog {
    private static func exists(_ name: String, in project: URL) -> Bool {
        FileManager.default.fileExists(atPath: project.appendingPathComponent(name).path)
    }
    private static func firstFile(withExtension ext: String, in project: URL) -> URL? {
        (try? FileManager.default.contentsOfDirectory(at: project, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == ext }.sorted { $0.lastPathComponent < $1.lastPathComponent }.first
    }
    private static func tool(_ candidates: [String], _ name: String) -> String? {
        Executables.find(candidates, orNamed: name)
    }

    static func moreProjectTasks(_ project: URL) -> [RunTask] {
        var tasks: [RunTask] = []
        func add(_ id: String, _ title: String, _ executable: String?, _ arguments: [String],
                 _ kind: RunTask.Kind, _ source: String, _ toolName: String) {
            tasks.append(RunTask(id: id, title: title, executable: executable, arguments: arguments,
                                 directory: project, kind: kind, source: source,
                                 missingTool: executable == nil ? toolName : nil))
        }
        if exists("build.gradle", in: project) || exists("build.gradle.kts", in: project) {
            let wrapper = project.appendingPathComponent("gradlew")
            let gradle = FileManager.default.isExecutableFile(atPath: wrapper.path) ? wrapper.path
                : tool(["/opt/homebrew/bin/gradle", "/usr/local/bin/gradle"], "gradle")
            let source = exists("build.gradle.kts", in: project) ? "build.gradle.kts" : "build.gradle"
            for (verb, kind) in [("build", RunTask.Kind.build), ("test", .test), ("run", .run)] {
                add("gradle-\(verb)", "gradle \(verb)", gradle, [verb, "--console=plain"], kind, source, "gradle")
            }
        }
        if exists("pom.xml", in: project) {
            let mvn = tool(["/opt/homebrew/bin/mvn", "/usr/local/bin/mvn"], "mvn")
            for (verb, kind) in [("compile", RunTask.Kind.build), ("test", .test), ("package", .script)] {
                add("mvn-\(verb)", "mvn \(verb)", mvn, ["-q", "-B", verb], kind, "pom.xml", "mvn")
            }
        }
        if exists("CMakeLists.txt", in: project) {
            let cmake = tool(["/opt/homebrew/bin/cmake", "/usr/local/bin/cmake", "/Applications/CMake.app/Contents/bin/cmake"], "cmake")
            add("cmake-configure", "cmake -S . -B build", cmake, ["-S", ".", "-B", "build"], .script, "CMakeLists.txt", "cmake")
            add("cmake-build", "cmake --build build", cmake, ["--build", "build"], .build, "CMakeLists.txt", "cmake")
            let ctest = tool(["/opt/homebrew/bin/ctest", "/usr/local/bin/ctest"], "ctest")
            add("cmake-test", "ctest --test-dir build", ctest, ["--test-dir", "build", "--output-on-failure"], .test, "CMakeLists.txt", "ctest")
        }
        if let projectFile = firstFile(withExtension: "csproj", in: project) ?? firstFile(withExtension: "sln", in: project)
            ?? firstFile(withExtension: "fsproj", in: project) {
            let dotnet = tool(["/usr/local/share/dotnet/dotnet", "/opt/homebrew/bin/dotnet"], "dotnet")
            let source = projectFile.lastPathComponent
            for (verb, kind) in [("build", RunTask.Kind.build), ("test", .test), ("run", .run)] {
                add("dotnet-\(verb)", "dotnet \(verb)", dotnet, [verb], kind, source, "dotnet")
            }
        }
        if exists("mix.exs", in: project) {
            let mix = tool(["/opt/homebrew/bin/mix", "/usr/local/bin/mix"], "mix")
            for (verb, kind) in [("compile", RunTask.Kind.build), ("test", .test), ("run", .run)] {
                add("mix-\(verb)", "mix \(verb)", mix, [verb], kind, "mix.exs", "mix")
            }
        }
        if exists("build.zig", in: project) {
            let zig = tool(["/opt/homebrew/bin/zig", "/usr/local/bin/zig"], "zig")
            add("zig-build", "zig build", zig, ["build"], .build, "build.zig", "zig")
            add("zig-test", "zig build test", zig, ["build", "test"], .test, "build.zig", "zig")
            add("zig-run", "zig build run", zig, ["build", "run"], .run, "build.zig", "zig")
        }
        if exists("pubspec.yaml", in: project) {
            let dart = tool(["/opt/homebrew/bin/dart", "/usr/local/bin/dart"], "dart")
            add("dart-run", "dart run", dart, ["run"], .run, "pubspec.yaml", "dart")
            add("dart-test", "dart test", dart, ["test"], .test, "pubspec.yaml", "dart")
            add("dart-analyze", "dart analyze", dart, ["analyze"], .build, "pubspec.yaml", "dart")
        }
        if exists("pyproject.toml", in: project) || exists("setup.py", in: project) || exists("pytest.ini", in: project)
            || exists("requirements.txt", in: project) {
            let python = tool(["/opt/homebrew/bin/python3", "/usr/bin/python3"], "python3")
            let source = ["pyproject.toml", "setup.py", "pytest.ini", "requirements.txt"].first { exists($0, in: project) } ?? "pyproject.toml"
            add("python-pytest", "python3 -m pytest", python, ["-m", "pytest", "-q"], .test, source, "python3")
            add("python-compileall", "python3 -m compileall .", python, ["-m", "compileall", "-q", "."], .build, source, "python3")
        }
        if exists("Rakefile", in: project) {
            let rake = tool(["/usr/bin/rake", "/opt/homebrew/bin/rake"], "rake")
            add("rake-test", "rake test", rake, ["test"], .test, "Rakefile", "rake")
            add("rake-default", "rake", rake, [], .build, "Rakefile", "rake")
        }
        if exists("stack.yaml", in: project) {
            let stack = tool(["/opt/homebrew/bin/stack", "/usr/local/bin/stack", "\(NSHomeDirectory())/.ghcup/bin/stack"], "stack")
            add("stack-build", "stack build", stack, ["build"], .build, "stack.yaml", "stack")
            add("stack-test", "stack test", stack, ["test"], .test, "stack.yaml", "stack")
        } else if let cabal = firstFile(withExtension: "cabal", in: project) {
            let tool = tool(["/opt/homebrew/bin/cabal", "/usr/local/bin/cabal", "\(NSHomeDirectory())/.ghcup/bin/cabal"], "cabal")
            add("cabal-build", "cabal build", tool, ["build"], .build, cabal.lastPathComponent, "cabal")
            add("cabal-test", "cabal test", tool, ["test"], .test, cabal.lastPathComponent, "cabal")
        }
        if exists("deno.json", in: project) || exists("deno.jsonc", in: project) {
            let deno = tool(["/opt/homebrew/bin/deno", "/usr/local/bin/deno", "\(NSHomeDirectory())/.deno/bin/deno"], "deno")
            add("deno-test", "deno test", deno, ["test"], .test, "deno.json", "deno")
            add("deno-check", "deno check .", deno, ["check", "."], .build, "deno.json", "deno")
        }
        return tasks + extraProjectTasks(project)
    }

    static func moreFileTasks(_ file: URL, language: Language, project: URL) -> [RunTask] {
        let name = file.lastPathComponent
        func task(_ id: String, _ title: String, _ executable: String?, _ arguments: [String],
                  _ toolName: String, kind: RunTask.Kind = .run) -> [RunTask] {
            [RunTask(id: id, title: title, executable: executable, arguments: arguments, directory: project,
                     kind: kind, source: "current file", missingTool: executable == nil ? toolName : nil)]
        }
        switch language.id {
        case "go":
            return task("file-go", "go run \(name)", tool(["/opt/homebrew/bin/go", "/usr/local/go/bin/go"], "go"), ["run", file.path], "go")
        case "php":
            return task("file-php", "php \(name)", tool(["/opt/homebrew/bin/php", "/usr/local/bin/php"], "php"), [file.path], "php")
        case "perl":
            return task("file-perl", "perl \(name)", tool(["/usr/bin/perl", "/opt/homebrew/bin/perl"], "perl"), [file.path], "perl")
        case "lua":
            return task("file-lua", "lua \(name)", tool(["/opt/homebrew/bin/lua", "/usr/local/bin/lua"], "lua"), [file.path], "lua")
        case "r":
            return task("file-r", "Rscript \(name)", tool(["/usr/local/bin/Rscript", "/opt/homebrew/bin/Rscript",
                        "/Library/Frameworks/R.framework/Resources/bin/Rscript"], "Rscript"), ["--vanilla", file.path], "Rscript")
        case "java":
            // Single-file source launch (JDK 11+); a build tool handles multi-file projects.
            return task("file-java", "java \(name)", tool(["/usr/bin/java"], "java"), [file.path], "java")
        case "kotlin" where file.pathExtension == "kts":
            return task("file-kotlin", "kotlinc -script \(name)", tool(["/opt/homebrew/bin/kotlinc", "/usr/local/bin/kotlinc"], "kotlinc"), ["-script", file.path], "kotlinc")
        case "zig":
            return task("file-zig", "zig run \(name)", tool(["/opt/homebrew/bin/zig", "/usr/local/bin/zig"], "zig"), ["run", file.path], "zig")
        case "dart":
            return task("file-dart", "dart run \(name)", tool(["/opt/homebrew/bin/dart", "/usr/local/bin/dart"], "dart"), ["run", file.path], "dart")
        case "elixir" where file.pathExtension == "exs":
            return task("file-elixir", "elixir \(name)", tool(["/opt/homebrew/bin/elixir", "/usr/local/bin/elixir"], "elixir"), [file.path], "elixir")
        case "julia":
            return task("file-julia", "julia \(name)", tool(["/opt/homebrew/bin/julia", "/usr/local/bin/julia",
                        "/Applications/Julia.app/Contents/Resources/julia/bin/julia"], "julia"), ["--startup-file=no", file.path], "julia")
        case "powershell":
            return task("file-pwsh", "pwsh \(name)", tool(["/usr/local/bin/pwsh", "/opt/homebrew/bin/pwsh"], "pwsh"), ["-NoProfile", "-File", file.path], "pwsh")
        case "haskell":
            return task("file-haskell", "runghc \(name)", tool(["/opt/homebrew/bin/runghc", "/usr/local/bin/runghc", "\(NSHomeDirectory())/.ghcup/bin/runghc"], "runghc"), [file.path], "runghc")
        case "groovy" where file.pathExtension == "groovy":
            return task("file-groovy", "groovy \(name)", tool(["/opt/homebrew/bin/groovy", "/usr/local/bin/groovy"], "groovy"), [file.path], "groovy")
        case "typescript":
            // Deno runs TypeScript directly; Node needs a transpiler, which is a project choice.
            return task("file-deno", "deno run \(name)", tool(["/opt/homebrew/bin/deno", "/usr/local/bin/deno", "\(NSHomeDirectory())/.deno/bin/deno"], "deno"), ["run", "--allow-all", file.path], "deno")
        case "rust" where !exists("Cargo.toml", in: project):
            let out = NSTemporaryDirectory() + "orrery-rustc-" + file.deletingPathExtension().lastPathComponent
            return task("file-rustc", "rustc \(name)", tool(["\(NSHomeDirectory())/.cargo/bin/rustc", "/opt/homebrew/bin/rustc"], "rustc"),
                        ["--edition", "2021", file.path, "-o", out], "rustc", kind: .build)
        case "csharp" where file.pathExtension == "csx":
            return task("file-dotnet-script", "dotnet script \(name)", tool(["/usr/local/share/dotnet/dotnet", "/opt/homebrew/bin/dotnet"], "dotnet"), ["script", file.path], "dotnet")
        case "clojure" where file.pathExtension != "edn":
            return task("file-clojure", "clojure -M \(name)", tool(["/opt/homebrew/bin/clojure", "/usr/local/bin/clojure"], "clojure"), ["-M", file.path], "clojure")
        case "ocaml" where file.pathExtension == "ml":
            return task("file-ocaml", "ocaml \(name)", tool(["/opt/homebrew/bin/ocaml", "/usr/local/bin/ocaml", "\(NSHomeDirectory())/.opam/default/bin/ocaml"], "ocaml"), [file.path], "ocaml")
        case "fsharp" where file.pathExtension == "fsx":
            return task("file-fsi", "dotnet fsi \(name)", tool(["/usr/local/share/dotnet/dotnet", "/opt/homebrew/bin/dotnet"], "dotnet"), ["fsi", file.path], "dotnet")
        default:
            return extraFileTasks(file, language: language, project: project)
        }
    }
}
