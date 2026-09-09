import Foundation

/// Real files with real mistakes, run through whichever checker is actually installed.
/// A checker that is missing must be reported by name — an empty problems list that means
/// "nothing ran" is the one outcome this pane must never produce.
@MainActor
enum AuditDiagnostics {

    /// Overlapping checks of one valid file must all come back clean. The shared-scratch-copy
    /// version of the engine failed this: one check's cleanup deleted the copy another was
    /// about to read, and "[Errno 2] No such file" surfaced as an error on line 1 of a valid
    /// buffer — seen live after an orchestrator run fired two refresh bursts.
    private static func concurrentChecks(_ audit: Auditor) async {
        audit.section("Diagnostics — overlapping checks do not sabotage each other")
        await Auditor.withTemporaryDirectory { dir in
            let url = dir.appendingPathComponent("raced.py")
            try? "x = 1\nprint(x)\n".write(to: url, atomically: true, encoding: .utf8)
            let document = CodeDocument(url: url)
            let engine = DiagnosticsEngine()
            engine.isEnabled = true
            for _ in 0..<3 {
                async let first: Void = engine.check(document)
                async let second: Void = engine.check(document)
                async let third: Void = engine.check(document)
                _ = await (first, second, third)
            }
            audit.check("nine overlapping checks of a valid file report nothing",
                        engine.diagnostics(for: url).isEmpty && document.diagnostics.isEmpty,
                        engine.diagnostics(for: url).map(\.message).joined(separator: " | "))
            audit.check("…and leave no note", engine.notes[url] == nil,
                        engine.notes[url] ?? "")
        }
    }

    static func run(_ audit: Auditor) async {
        await concurrentChecks(audit)
        audit.section("Diagnostics — JSON (built in)")
        let jsonURL = URL(fileURLWithPath: "/tmp/audit.json")
        audit.check("valid JSON reports nothing",
                    DiagnosticsEngine.checkJSON(#"{"a": [1, 2], "b": null}"#, url: jsonURL)
                        .isEmpty)
        audit.check("an empty file is not an error",
                    DiagnosticsEngine.checkJSON("\n  \n", url: jsonURL).isEmpty)
        let trailingComma = DiagnosticsEngine.checkJSON("{\n  \"a\": 1,\n}\n", url: jsonURL)
        audit.equal("a trailing comma is one error", trailingComma.count, 1)
        audit.equal("…on the closing brace's line", trailingComma.first?.line, 3)
        audit.equal("…attributed to the JSON parser", trailingComma.first?.source, "JSON")
        let unquoted = DiagnosticsEngine.checkJSON("{\n  \"a\": 1,\n  b: 2\n}\n", url: jsonURL)
        audit.equal("an unquoted key is found on its own line", unquoted.first?.line, 3)
        let deep = DiagnosticsEngine.checkJSON(
            "{\n  \"x\": {\n    \"y\": [1, 2,,]\n  }\n}\n", url: jsonURL)
        audit.equal("a nested error keeps its line", deep.first?.line, 3)

        /// One case: source text in, expected (line, column, fragment of the message) out.
        func expectJSON(_ label: String, _ text: String, line: Int?, contains fragment: String,
                        severity: Diagnostic.Severity = .error) {
            let found = DiagnosticsEngine.checkJSON(text, url: jsonURL)
            guard let first = found.first(where: { $0.severity == severity }) else {
                audit.check("JSON: \(label)", false, "nothing reported")
                return
            }
            audit.check("JSON: \(label)",
                        (line == nil || first.line == line)
                        && first.message.lowercased().contains(fragment.lowercased()),
                        "line \(first.line) col \(first.column): \(first.message)")
        }

        expectJSON("single quotes are rejected", "{'a': 1}", line: 1, contains: "double quotes")
        expectJSON("a bare key is rejected", "{a: 1}", line: 1, contains: "quoted key")
        expectJSON("a missing colon is named", "{\"a\" 1}", line: 1, contains: "expected :")
        expectJSON("an unterminated string is named", "{\"a\": \"oops}", line: 1,
                   contains: "unterminated string")
        expectJSON("a newline inside a string is named", "{\"a\": \"one\ntwo\"}", line: 1,
                   contains: "newline")
        expectJSON("a leading zero is rejected", "{\"a\": 007}", line: 1, contains: "leading zero")
        expectJSON("a bare decimal point is rejected", "{\"a\": 1.}", line: 1,
                   contains: "after the decimal point")
        expectJSON("an empty exponent is rejected", "{\"a\": 1e}", line: 1, contains: "exponent")
        expectJSON("NaN is not JSON", "{\"a\": NaN}", line: 1, contains: "expected")
        expectJSON("a bad escape is named", "{\"a\": \"x\\qy\"}", line: 1,
                   contains: "not a valid escape")
        expectJSON("two top-level values are rejected", "{\"a\": 1} {\"b\": 2}", line: 1,
                   contains: "after the end")
        expectJSON("a comment in plain JSON is rejected", "// note\n{\"a\": 1}", line: 1,
                   contains: "expected a value")
        expectJSON("an error deep in the file keeps its line",
                   "{\n\"a\": 1,\n\"b\": 2,\n\"c\": 3,\n\"d\": ,\n\"e\": 5\n}",
                   line: 5, contains: "expected a value")
        expectJSON("a duplicate key is a warning, not an error",
                   "{\"a\": 1,\n \"b\": 2,\n \"a\": 3}", line: 3, contains: "duplicate key",
                   severity: .warning)

        audit.check("JSON: a duplicate key does not stop the file being valid",
                    DiagnosticsEngine.checkJSON("{\"a\": 1, \"a\": 2}", url: jsonURL)
                        .allSatisfy { $0.severity == .warning })
        audit.check("JSON: nested structures validate",
                    DiagnosticsEngine.checkJSON(
                        #"{"a":[{"b":[1,2,{"c":null}]},true],"d":{"e":-1.5e-3}}"#,
                        url: jsonURL).isEmpty)
        audit.check("JSON: a bare top-level string is valid",
                    DiagnosticsEngine.checkJSON("\"hello\"", url: jsonURL).isEmpty)
        audit.check("JSON: escapes are accepted",
                    DiagnosticsEngine.checkJSON(#"{"a": "line\nbreak \u00e9 \\ \" ok"}"#,
                                                url: jsonURL).isEmpty)
        audit.check("JSON: a tab inside a string is rejected",
                    !DiagnosticsEngine.checkJSON("{\"a\": \"x\ty\"}", url: jsonURL).isEmpty)

        // .jsonc and tsconfig.json conventionally allow comments; plain .json does not.
        let jsoncURL = URL(fileURLWithPath: "/tmp/audit.jsonc")
        audit.check("JSONC: comments are allowed",
                    DiagnosticsEngine.checkJSON("// note\n{\"a\": 1 /* inline */}",
                                                url: jsoncURL).isEmpty)
        audit.check("tsconfig.json: comments are allowed",
                    DiagnosticsEngine.checkJSON("{\n// note\n\"a\": 1}",
                                                url: URL(fileURLWithPath: "/x/tsconfig.json"))
                        .isEmpty)
        audit.check("JSONC: an unterminated block comment is still an error",
                    !DiagnosticsEngine.checkJSON("{\"a\": 1} /* open", url: jsoncURL).isEmpty)
        audit.check("JSON: 300 levels of nesting is refused rather than crashing",
                    !DiagnosticsEngine.checkJSON(String(repeating: "[", count: 300)
                                                 + String(repeating: "]", count: 300),
                                                 url: jsonURL).isEmpty)

        audit.equal("byte offset 0 is line 1 column 1",
                    "\(DiagnosticsEngine.position(ofByteOffset: 0, in: "abc"))", "(1, 1)")
        audit.equal("offsets count multi-byte characters once",
                    "\(DiagnosticsEngine.position(ofByteOffset: 6, in: "é\nabc"))", "(2, 4)")

        audit.section("Diagnostics — the process runner")
        // Every checker, task and terminal command goes through this. A runner that loses
        // output one run in twenty makes the whole diagnostics pane untrustworthy, and the
        // failure looks like a language bug rather than a plumbing bug.
        var lostOutput = 0
        var wrongStatus = 0
        for index in 0..<120 {
            guard let result = try? await ProcessRunner.run(
                "/bin/echo", ["run-\(index)"], timeout: 10) else {
                lostOutput += 1
                continue
            }
            if !result.standardOutput.contains("run-\(index)") { lostOutput += 1 }
            if result.status != 0 { wrongStatus += 1 }
        }
        audit.check("120 runs all returned their output", lostOutput == 0,
                    "\(lostOutput) runs came back empty or wrong")
        audit.check("120 runs all reported exit 0", wrongStatus == 0, "\(wrongStatus) wrong")

        var stderrLost = 0
        for index in 0..<40 {
            guard let result = try? await ProcessRunner.run(
                "/bin/sh", ["-c", "echo out-\(index); echo err-\(index) >&2; exit 3"],
                timeout: 10) else { stderrLost += 1; continue }
            if !result.standardOutput.contains("out-\(index)") { stderrLost += 1 }
            if !result.standardError.contains("err-\(index)") { stderrLost += 1 }
            if result.status != 3 { stderrLost += 1 }
        }
        audit.check("stdout, stderr and exit status all survive 40 runs", stderrLost == 0,
                    "\(stderrLost) mismatches")

        if let big = try? await ProcessRunner.run(
            "/bin/sh", ["-c", "for i in $(seq 1 20000); do echo line-$i; done"], timeout: 20) {
            // A child that fills the pipe while the parent waits on the other one deadlocks.
            audit.equal("a chatty child does not deadlock or truncate",
                        big.standardOutput.components(separatedBy: "\n")
                            .filter { $0.hasPrefix("line-") }.count, 20_000)
        } else {
            audit.check("a chatty child does not deadlock or truncate", false, "run failed")
        }

        if let slow = try? await ProcessRunner.run("/bin/sleep", ["30"], timeout: 1) {
            audit.check("a hanging command is killed at the deadline", slow.timedOut)
        } else {
            audit.check("a hanging command is killed at the deadline", false, "run threw")
        }
        audit.check("a missing executable throws rather than hanging",
                    (try? await ProcessRunner.run("/nope/nothing", [])) == nil)

        if let path = try? await ProcessRunner.run(
            "/bin/sh", ["-c", "printf '%s' \"$PATH\""],
            environment: ["PATH": "/usr/bin:/bin"], timeout: 5) {
            audit.check("a stripped PATH still receives Homebrew and /usr/local/bin",
                        path.standardOutput.contains("/opt/homebrew/bin")
                        && path.standardOutput.contains("/usr/local/bin")
                        && path.standardOutput.contains("/usr/bin"),
                        path.standardOutput)
        } else {
            audit.check("a stripped PATH still receives Homebrew and /usr/local/bin", false,
                        "run failed")
        }

        audit.section("Diagnostics — installed checkers")
        let engine = DiagnosticsEngine()

        // What is actually present on this machine decides what can be asserted. Say so, rather
        // than passing checks that never ran.
        for language in [Languages.swift, Languages.python, Languages.shell, Languages.c,
                         Languages.javascript, Languages.ruby, Languages.go,
                         Languages.typescript] {
            let resolved = Checkers.resolve(for: language)
            audit.check("\(language.name): \(resolved.map { "uses \($0.0.name)" } ?? "no checker installed — \(Checkers.unavailableNote(for: language))")",
                        true)
        }

        await Auditor.withTemporaryDirectory { dir in
            /// Write a file, open it, check it, and hand back what came out.
            @MainActor func diagnose(_ name: String, _ text: String) async -> (CodeDocument, [Diagnostic]) {
                let url = dir.appendingPathComponent(name)
                try? text.write(to: url, atomically: true, encoding: .utf8)
                let document = CodeDocument(url: url)
                await engine.check(document)
                return (document, document.diagnostics)
            }

            if Checkers.resolve(for: Languages.swift) != nil {
                let (_, broken) = await diagnose("Broken.swift", """
                import Foundation

                func good() -> Int { return 1 }

                func bad( -> Int {
                    return 2
                }
                """)
                audit.check("Swift: a syntax error is found", !broken.isEmpty,
                            "\(broken.count) diagnostics")
                audit.equal("Swift: reported on the offending line", broken.first?.line, 5)
                audit.equal("Swift: reported as an error", broken.first?.severity,
                            Diagnostic.Severity.error)
                audit.equal("Swift: attributed to swiftc", broken.first?.source, "swiftc")

                let (_, clean) = await diagnose("Clean.swift", """
                import Foundation

                struct Widget {
                    let name: String
                    func describe() -> String { "a \\(name)" }
                }
                """)
                audit.check("Swift: a clean file reports nothing", clean.isEmpty,
                            clean.map(\.message).joined(separator: " | "))
            }

            if Checkers.resolve(for: Languages.python) != nil {
                let (_, broken) = await diagnose("broken.py", """
                def good():
                    return 1


                def bad(:
                    return 2
                """)
                audit.check("Python: a syntax error is found", !broken.isEmpty)
                audit.equal("Python: reported on the offending line", broken.first?.line, 5)

                let (_, clean) = await diagnose("clean.py", """
                from typing import Optional


                def add(a: int, b: int = 0) -> Optional[int]:
                    return a + b
                """)
                audit.check("Python: a clean file reports nothing", clean.isEmpty,
                            clean.map(\.message).joined(separator: " | "))
            }

            if Checkers.resolve(for: Languages.shell) != nil {
                let (_, found) = await diagnose("script.sh", """
                #!/bin/bash
                name=world
                echo "hello $nmae"
                """)
                audit.check("Shell: shellcheck's findings come through", !found.isEmpty,
                            "\(found.count) diagnostics")
                audit.check("Shell: attributed to shellcheck",
                            found.first?.source == "shellcheck")
                audit.check("Shell: the finding has a column",
                            (found.first?.column ?? 0) >= 1)
            }

            if Checkers.resolve(for: Languages.c) != nil {
                let (_, found) = await diagnose("prog.c", """
                #include <stdio.h>

                int main(void) {
                    int x = ;
                    return 0;
                }
                """)
                audit.check("C: a syntax error is found", !found.isEmpty)
                audit.equal("C: reported on the offending line", found.first?.line, 4)
            }

            if Checkers.resolve(for: Languages.javascript) != nil {
                let (_, found) = await diagnose("app.js", """
                const a = 1;
                const b = ;
                """)
                audit.check("JavaScript: a syntax error is found", !found.isEmpty)
                audit.equal("JavaScript: reported on the offending line", found.first?.line, 2)
            }

            if Checkers.resolve(for: Languages.ruby) != nil {
                let (_, found) = await diagnose("thing.rb", """
                def greet(name)
                  puts name
                """)
                audit.check("Ruby: a syntax error is found", !found.isEmpty)
            }

            // The buffer, not the file on disk, is what gets checked.
            audit.section("Diagnostics — checks the buffer, not the disk")
            if Checkers.resolve(for: Languages.python) != nil {
                let url = dir.appendingPathComponent("live.py")
                try? "x = 1\n".write(to: url, atomically: true, encoding: .utf8)
                let document = CodeDocument(url: url)
                await engine.check(document)
                audit.check("the saved file is clean", document.diagnostics.isEmpty)

                document.storage.replaceCharacters(
                    in: NSRange(location: 0, length: document.storage.length),
                    with: "def broken(:\n    pass\n")
                await engine.check(document)
                audit.check("an unsaved edit is checked", !document.diagnostics.isEmpty,
                            "nothing found for the edited buffer")
                audit.equal("the file on disk is untouched",
                            try? String(contentsOf: url, encoding: .utf8), "x = 1\n")
                audit.equal("the diagnostic points at the real file, not the scratch copy",
                            document.diagnostics.first?.file.lastPathComponent, "live.py")
            }

            audit.section("Diagnostics — nothing is silently skipped")
            // A language with no checker must produce a note that names what is missing.
            let missing = Languages.all.filter { !engine.hasChecker(for: $0) }
            audit.check("languages without a checker are known",
                        !missing.isEmpty, "every language has one, unexpectedly")
            for language in [Languages.markdown, Languages.yaml] where !engine.hasChecker(for: language) {
                let note = Checkers.unavailableNote(for: language)
                audit.check("\(language.name): the empty list is explained",
                            note.contains(language.name), note)
            }
            if Checkers.resolve(for: Languages.go) == nil {
                let note = Checkers.unavailableNote(for: Languages.go)
                audit.check("Go: the missing tool is named", note.contains("gofmt"), note)
                audit.check("Go: and it says nothing was checked",
                            note.lowercased().contains("not"), note)
            }

            let markdownURL = dir.appendingPathComponent("notes.md")
            try? "# Title\n".write(to: markdownURL, atomically: true, encoding: .utf8)
            let markdown = CodeDocument(url: markdownURL)
            await engine.check(markdown)
            audit.check("a language with no checker gets a note, not silence",
                        engine.notes[markdownURL] != nil,
                        engine.notes[markdownURL] ?? "no note recorded")
            audit.check("…and the description says the same thing",
                        engine.description(for: markdown).contains("Markdown"),
                        engine.description(for: markdown))

            // Turning it off must stop work and say so.
            engine.isEnabled = false
            audit.equal("switched off, the description says so",
                        engine.description(for: markdown), "Checking is off.")
            engine.isEnabled = true
        }
    }
}
