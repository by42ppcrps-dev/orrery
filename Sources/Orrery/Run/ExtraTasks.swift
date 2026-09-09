import Foundation

/// Project and single-file tasks for the third language batch, derived from files that exist.
extension TaskCatalog {
    private static func has(_ name: String, in project: URL) -> Bool {
        FileManager.default.fileExists(atPath: project.appendingPathComponent(name).path)
    }
    private static func anyFile(withExtension ext: String, in project: URL) -> Bool {
        ((try? FileManager.default.contentsOfDirectory(at: project, includingPropertiesForKeys: nil)) ?? []).contains { $0.pathExtension == ext }
    }
    private static func find(_ name: String, extra: [String] = []) -> String? {
        Executables.find(["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"] + extra, orNamed: name)
    }
    private static func scratch(_ prefix: String) -> String {
        let path = NSTemporaryDirectory() + prefix + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    static func extraProjectTasks(_ project: URL) -> [RunTask] {
        var tasks: [RunTask] = []
        func add(_ id: String, _ title: String, _ executable: String?, _ arguments: [String],
                 _ kind: RunTask.Kind, _ source: String, _ toolName: String) {
            tasks.append(RunTask(id: id, title: title, executable: executable, arguments: arguments,
                                 directory: project, kind: kind, source: source, missingTool: executable == nil ? toolName : nil))
        }
        for marker in ["MODULE.bazel", "WORKSPACE", "WORKSPACE.bazel", "BUILD", "BUILD.bazel"] where has(marker, in: project) {
            let bazel = find("bazel") ?? find("bazelisk")
            add("bazel-build", "bazel build //...", bazel, ["build", "//..."], .build, marker, "bazel")
            add("bazel-test", "bazel test //...", bazel, ["test", "//..."], .test, marker, "bazel")
            break
        }
        if anyFile(withExtension: "nimble", in: project) {
            let nimble = find("nimble", extra: ["\(NSHomeDirectory())/.nimble/bin/nimble"])
            add("nimble-build", "nimble build", nimble, ["build"], .build, "*.nimble", "nimble")
            add("nimble-test", "nimble test", nimble, ["test"], .test, "*.nimble", "nimble")
        }
        if has("shard.yml", in: project) {
            add("shards-build", "shards build", find("shards"), ["build"], .build, "shard.yml", "shards")
            add("crystal-spec", "crystal spec", find("crystal"), ["spec"], .test, "shard.yml", "crystal")
        }
        if has("fpm.toml", in: project) {
            let fpm = find("fpm")
            add("fpm-build", "fpm build", fpm, ["build"], .build, "fpm.toml", "fpm")
            add("fpm-test", "fpm test", fpm, ["test"], .test, "fpm.toml", "fpm")
            add("fpm-run", "fpm run", fpm, ["run"], .run, "fpm.toml", "fpm")
        }
        if has("alire.toml", in: project) {
            add("alr-build", "alr build", find("alr"), ["build"], .build, "alire.toml", "alr")
        }
        if has("project.godot", in: project) {
            let godot = find("godot", extra: ["/Applications/Godot.app/Contents/MacOS/Godot"])
            add("godot-run", "godot --path .", godot, ["--path", "."], .run, "project.godot", "godot")
        }
        return tasks
    }

    static func extraFileTasks(_ file: URL, language: Language, project: URL) -> [RunTask] {
        let name = file.lastPathComponent
        let stem = file.deletingPathExtension().lastPathComponent
        func task(_ id: String, _ title: String, _ executable: String?, _ arguments: [String],
                  _ toolName: String, kind: RunTask.Kind = .run) -> [RunTask] {
            [RunTask(id: id, title: title, executable: executable, arguments: arguments, directory: project,
                     kind: kind, source: "current file", missingTool: executable == nil ? toolName : nil)]
        }
        switch language.id {
        case "fortran":
            return task("file-gfortran", "gfortran \(name)", find("gfortran"), [file.path, "-o", scratch("orrery-gfortran-") + "/" + stem], "gfortran", kind: .build)
        case "cobol":
            return task("file-cobc", "cobc -x \(name)", find("cobc"), ["-x", "-o", scratch("orrery-cobc-") + "/" + stem, file.path], "cobc", kind: .build)
        case "ada" where file.pathExtension == "adb":
            let out = scratch("orrery-gnat-")
            return task("file-gnatmake", "gnatmake \(name)", find("gnatmake"), ["-q", "-D", out, "-o", out + "/" + stem, file.path], "gnatmake", kind: .build)
        case "pascal":
            let out = scratch("orrery-fpc-")
            return task("file-fpc", "fpc \(name)", find("fpc"), ["-FU" + out, "-FE" + out, file.path], "fpc", kind: .build)
        case "nim" where file.pathExtension == "nim":
            return task("file-nim", "nim c -r \(name)", find("nim", extra: ["\(NSHomeDirectory())/.nimble/bin/nim"]), ["c", "-r", "--hints:off", "--outdir:" + scratch("orrery-nim-"), file.path], "nim")
        case "crystal":
            return task("file-crystal", "crystal run \(name)", find("crystal"), ["run", file.path], "crystal")
        case "prolog":
            return task("file-swipl", "swipl \(name)", find("swipl"), ["-q", "-t", "halt", file.path], "swipl")
        case "lisp":
            switch file.pathExtension {
            case "rkt": return task("file-racket", "racket \(name)", find("racket", extra: ["/Applications/Racket/bin/racket"]), [file.path], "racket")
            case "scm", "ss", "sld": return task("file-guile", "guile \(name)", find("guile"), ["--no-auto-compile", file.path], "guile")
            case "el": return task("file-emacs", "emacs --script \(name)", find("emacs"), ["--script", file.path], "emacs")
            case "fnl": return task("file-fennel", "fennel \(name)", find("fennel"), [file.path], "fennel")
            default: return task("file-sbcl", "sbcl --script \(name)", find("sbcl"), ["--script", file.path], "sbcl")
            }
        case "verilog":
            return task("file-iverilog", "iverilog \(name)", find("iverilog"), ["-g2012", "-o", scratch("orrery-iverilog-") + "/" + stem + ".vvp", file.path], "iverilog", kind: .build)
        case "vhdl":
            return task("file-ghdl", "ghdl -a \(name)", find("ghdl"), ["-a", "--std=08", "--workdir=" + scratch("orrery-ghdl-"), file.path], "ghdl", kind: .build)
        case "latex" where file.pathExtension == "tex":
            return task("file-pdflatex", "pdflatex \(name)", find("pdflatex", extra: ["/Library/TeX/texbin/pdflatex"]), ["-interaction=nonstopmode", "-output-directory=" + scratch("orrery-latex-"), file.path], "pdflatex", kind: .build)
        case "matlab":
            return task("file-octave", "octave \(name)", find("octave"), ["--no-gui", "--quiet", file.path], "octave")
        case "solidity":
            return task("file-solc", "solc --bin \(name)", find("solc"), ["--bin", "-o", scratch("orrery-solc-"), file.path], "solc", kind: .build)
        case "cuda":
            return task("file-nvcc", "nvcc \(name)", find("nvcc", extra: ["/usr/local/cuda/bin/nvcc"]), [file.path, "-o", scratch("orrery-nvcc-") + "/" + stem], "nvcc", kind: .build)
        case "vb" where file.pathExtension == "vbs":
            return task("file-cscript", "cscript \(name)", find("cscript"), [file.path], "cscript")
        default:
            return []
        }
    }
}
