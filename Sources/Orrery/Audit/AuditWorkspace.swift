import AppKit

/// Documents, tabs, file operations, quick-open ranking and project search — exercised against
/// real files in a scratch directory.
@MainActor
enum AuditWorkspace {

    static func run(_ audit: Auditor) async {
        audit.section("Workspace — line endings")
        do {
            let crlf = "one\r\ntwo\r\nthree\r\n"
            let document = CodeDocument(name: "crlf.swift", language: Languages.swift, text: crlf)
            audit.equal("CRLF file counts as 4 lines, not 1",
                        document.decorator.lineStartOffsets.count, 4)
            let tokens = Tokenizer.tokens(for: "// a\r\nlet x = 1\r\n", language: Languages.swift)
            let hasKeyword = tokens.contains { $0.kind == .keyword }
            audit.check("CRLF: code after a comment line still highlights", hasKeyword)
        }
        do {
            let noTrailing = CodeDocument(name: "a.swift", language: Languages.swift,
                                          text: "one\ntwo")
            audit.equal("a file with no trailing newline has no phantom last line",
                        noTrailing.decorator.lineStartOffsets.count, 2)
            let trailing = CodeDocument(name: "b.swift", language: Languages.swift,
                                        text: "one\ntwo\n")
            audit.equal("a file ending in a newline has an empty last line",
                        trailing.decorator.lineStartOffsets.count, 3)
        }

        audit.section("Workspace — quick open ranking")
        func best(_ query: String, _ candidates: [String]) -> String? {
            candidates
                .compactMap { path -> (String, Int)? in
                    FuzzyMatcher.score(query: query, candidate: path).map { (path, $0.score) }
                }
                .max { $0.1 < $1.1 }?.0
        }
        audit.equal("basename beats a parent-folder match",
                    best("model", ["model/util.swift", "Sources/AppModel.swift"]),
                    "Sources/AppModel.swift")
        audit.equal("an exact filename wins",
                    best("appmodel", ["Sources/AppModel.swift", "Sources/AppModelExtras.swift"]),
                    "Sources/AppModel.swift")
        audit.equal("camelCase initials work",
                    best("ctv", ["Editor/CodeTextView.swift", "a/c/t/v.txt"]),
                    "Editor/CodeTextView.swift")
        audit.check("a non-subsequence does not match",
                    FuzzyMatcher.score(query: "zzz", candidate: "AppModel.swift") == nil)
        audit.check("query longer than the candidate does not match",
                    FuzzyMatcher.score(query: "abcdefghij", candidate: "abc") == nil)
        audit.check("matching is case-insensitive",
                    FuzzyMatcher.score(query: "APPM", candidate: "AppModel.swift") != nil)
        do {
            let result = FuzzyMatcher.score(query: "am", candidate: "AppModel.swift")
            audit.equal("highlight positions point at the matched characters",
                        result?.positions ?? [], [0, 3])
        }

        audit.section("Workspace — globs")
        let globCases: [(String, String, Bool)] = [
            ("*.swift", "Sources/App.swift", true),
            ("*.swift", "Sources/App.py", false),
            ("Sources/*.swift", "Sources/App.swift", true),
            ("Sources/*.swift", "Sources/Sub/App.swift", false),
            ("Sources/**/*.swift", "Sources/Sub/Deep/App.swift", true),
            ("**/test_*.py", "a/b/test_x.py", true),
            ("**/test_*.py", "a/b/x.py", false),
            ("?.txt", "a.txt", true),
            ("?.txt", "ab.txt", false),
        ]
        for (glob, path, expected) in globCases {
            audit.check("glob \(glob) vs \(path)",
                        ProjectSearch.matches(glob: glob, path: path) == expected)
        }

        await Auditor.withTemporaryDirectory { root in
            let manager = FileManager.default
            try? manager.createDirectory(at: root.appendingPathComponent("src/deep"),
                                         withIntermediateDirectories: true)
            try? manager.createDirectory(at: root.appendingPathComponent("node_modules/pkg"),
                                         withIntermediateDirectories: true)
            let alpha = root.appendingPathComponent("src/alpha.py")
            let beta = root.appendingPathComponent("src/deep/beta.swift")
            let noise = root.appendingPathComponent("node_modules/pkg/index.js")
            let binary = root.appendingPathComponent("src/blob.bin")
            try? "needle = 1\nother\nneedle again\n".write(to: alpha, atomically: true,
                                                           encoding: .utf8)
            try? "let x = 1\n// needle here\n".write(to: beta, atomically: true, encoding: .utf8)
            try? "needle in a dependency\n".write(to: noise, atomically: true, encoding: .utf8)
            try? Data([0x00, 0x6E, 0x65, 0x65, 0x64, 0x6C, 0x65]).write(to: binary)

            audit.section("Workspace — project index")
            let index = ProjectIndex()
            index.scan(root: root)
            for _ in 0..<200 where index.isScanning {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            audit.check("scan finished", !index.isScanning)
            let paths = Set(index.files.map { index.relativePath($0) })
            audit.check("indexes project files", paths.contains("src/alpha.py")
                        && paths.contains("src/deep/beta.swift"), paths.sorted().joined(separator: ","))
            audit.check("skips node_modules", !paths.contains("node_modules/pkg/index.js"))
            audit.equal("quick open finds a file by fragment",
                        index.matches("beta").first?.display, "src/deep/beta.swift")

            audit.section("Workspace — project search")
            let search = ProjectSearch()
            search.run(query: "needle", options: SearchOptions(), files: index.files, root: root)
            for _ in 0..<200 where search.isSearching {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            audit.check("search finished", !search.isSearching)
            for candidate in index.files where !candidate.path.hasSuffix(".bin") {
                do { _ = try WorkspaceFileAccess(root: root).read(candidate.path) }
                catch { audit.check("indexed file can be read safely", false, "\(root.path) → \(candidate.path): \(error.localizedDescription)") }
            }
            audit.equal("total hits across the project", search.totalHits, 3)
            audit.equal("hits are grouped by file", search.results.count, 2)
            if let first = search.results.first(where: { $0.relativePath == "src/alpha.py" }) {
                audit.equal("first hit is on line 1", first.hits.first?.lineNumber, 1)
                audit.equal("first hit column is 1", first.hits.first?.column, 1)
                audit.equal("second hit is on line 3", first.hits.last?.lineNumber, 3)
                audit.equal("preview is the whole matching line",
                            first.hits.first?.preview, "needle = 1")
            } else {
                audit.check("alpha.py appears in the results", false)
            }
            if let swiftFile = search.results.first(where: {
                $0.relativePath == "src/deep/beta.swift"
            }) {
                audit.equal("column is measured from the line start",
                            swiftFile.hits.first?.column, 4)
            }
            audit.check("binary file is skipped, not shown as a match",
                        !search.results.contains { $0.relativePath.hasSuffix(".bin") })

            search.run(query: "NEEDLE",
                       options: SearchOptions(caseSensitive: true),
                       files: index.files, root: root)
            for _ in 0..<200 where search.isSearching {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            audit.equal("case-sensitive search respects case", search.totalHits, 0)

            search.run(query: "needle", options: SearchOptions(include: "*.py"),
                       files: index.files, root: root)
            for _ in 0..<200 where search.isSearching {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            audit.equal("include filter limits the files searched", search.results.count, 1)

            search.run(query: "need(le|les)", options: SearchOptions(isRegex: true),
                       files: index.files, root: root)
            for _ in 0..<200 where search.isSearching {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            audit.equal("regex search works", search.totalHits, 3)

            search.run(query: "[unclosed", options: SearchOptions(isRegex: true),
                       files: index.files, root: root)
            audit.check("an invalid regex is reported rather than crashing",
                        search.note?.contains("valid") == true, search.note ?? "no note")

            audit.section("Workspace — replace in files")
            search.run(query: "needle", options: SearchOptions(include: "*.py"),
                       files: index.files, root: root)
            for _ in 0..<200 where search.isSearching {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            let replaced = try? search.replaceAll(with: "pin", query: "needle",
                                                  options: SearchOptions(include: "*.py"))
            audit.equal("replace touched one file", replaced?.files, 1)
            audit.equal("replace changed two occurrences", replaced?.hits, 2)
            let afterReplace = (try? String(contentsOf: alpha, encoding: .utf8)) ?? ""
            audit.equal("file contents were rewritten", afterReplace, "pin = 1\nother\npin again\n")
            let untouched = (try? String(contentsOf: beta, encoding: .utf8)) ?? ""
            audit.check("a filtered-out file was not touched", untouched.contains("needle"))

            audit.section("Workspace — documents and tabs")
            let store = DocumentStore()
            let first = store.open(alpha)
            audit.check("opening a file returns a document", first != nil)
            audit.equal("language is detected from the extension", first?.language.id, "python")
            let again = store.open(alpha)
            audit.check("opening the same file reuses the tab", again === first)
            audit.equal("one tab, not two", store.documents.count, 1)
            _ = store.open(beta)
            audit.equal("two tabs", store.documents.count, 2)
            audit.equal("the newest is active", store.active?.name, "beta.swift")
            store.selectNext(1)
            audit.equal("cycling tabs wraps around", store.active?.name, "alpha.py")
            audit.check("opening a directory is refused",
                        store.open(root.appendingPathComponent("src")) == nil)

            audit.section("Workspace — saving")
            guard let document = store.document(for: beta) else {
                audit.check("beta document present", false)
                return
            }
            document.storage.replaceCharacters(in: NSRange(location: 0, length: 0),
                                               with: "// edited\n")
            audit.check("editing marks the tab dirty", document.isDirty)
            audit.check("save succeeds", store.save(document))
            let onDisk = (try? String(contentsOf: beta, encoding: .utf8)) ?? ""
            audit.check("the edit reached disk", onDisk.hasPrefix("// edited"))
            audit.check("saving clears the dirty flag", !document.isDirty)

            // A file changed underneath an open tab must never be clobbered.
            document.storage.replaceCharacters(in: NSRange(location: 0, length: 0),
                                               with: "// local\n")
            try? await Task.sleep(nanoseconds: 1_100_000_000)   // mtime has 1s granularity
            try? "written by an agent\n".write(to: beta, atomically: true, encoding: .utf8)
            store.notice = nil
            audit.check("save refuses when the file changed on disk", !store.save(document))
            audit.check("the conflict is explained", store.notice?.contains("changed on disk") == true)
            audit.equal("the agent's write survives",
                        (try? String(contentsOf: beta, encoding: .utf8)), "written by an agent\n")
            audit.check("the tab is flagged", document.changedOnDisk)
            audit.check("save anyway overwrites deliberately",
                        { if case .saved = document.forceSave() { return true }; return false }())
            audit.check("forced save wrote the local text",
                        ((try? String(contentsOf: beta, encoding: .utf8)) ?? "")
                            .hasPrefix("// local"))

            // A clean tab whose file an agent rewrote should refresh itself.
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            try? "agent rewrote this\n".write(to: beta, atomically: true, encoding: .utf8)
            store.checkAllOnDisk()
            audit.check("a clean tab notices the change", document.changedOnDisk)
            audit.equal("reloading clean tabs picks it up", store.reloadUnmodifiedFromDisk(), 1)
            audit.equal("the tab now shows the new text", document.text, "agent rewrote this\n")

            audit.section("Workspace — unreadable files")
            let blob = store.open(binary)
            audit.check("a NUL byte makes a file read-only, even though it decodes as UTF-8",
                        blob?.isReadable == false)
            audit.check("saving it is refused", !store.save(blob!))
            let bytesAfter = (try? Data(contentsOf: binary)) ?? Data()
            audit.equal("the binary file is untouched", bytesAfter.count, 7)

            let png = root.appendingPathComponent("logo.png")
            try? Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00]).write(to: png)
            audit.equal("a PNG is named for what it is",
                        store.open(png)?.loadNote, "A PNG image, not text.")

            let utf16 = root.appendingPathComponent("wide.txt")
            try? "hello".data(using: .utf16)?.write(to: utf16)
            audit.check("UTF-16 is identified rather than called 'not text'",
                        store.open(utf16)?.loadNote?.contains("UTF-16") == true,
                        store.open(utf16)?.loadNote ?? "no note")

            let bom = root.appendingPathComponent("bom.swift")
            try? (Data([0xEF, 0xBB, 0xBF]) + Data("let a = 1\n".utf8)).write(to: bom)
            let bomDocument = store.open(bom)
            audit.check("a UTF-8 BOM file is editable", bomDocument?.isReadable == true)
            audit.equal("the BOM is not shown as content", bomDocument?.text, "let a = 1\n")

            audit.section("Workspace — file operations")
            let created = try? FileOperations.createFile(named: "new.txt", in: root)
            audit.check("create a file", created != nil
                        && manager.fileExists(atPath: created!.path))
            audit.check("creating over an existing file is refused",
                        (try? FileOperations.createFile(named: "new.txt", in: root)) == nil)
            let folder = try? FileOperations.createFolder(named: "newdir", in: root)
            audit.check("create a folder", folder != nil)
            let renamed = created.flatMap { try? FileOperations.rename($0, to: "renamed.txt") }
            audit.check("rename a file", renamed?.lastPathComponent == "renamed.txt"
                        && manager.fileExists(atPath: renamed!.path))
            let copy = renamed.flatMap { try? FileOperations.duplicate($0) }
            audit.check("duplicate a file", copy != nil
                        && manager.fileExists(atPath: copy!.path))
            audit.check("duplicate does not overwrite the original",
                        copy?.lastPathComponent != renamed?.lastPathComponent)
            audit.check("trashing a file that does not exist reports an error",
                        (try? FileOperations.moveToTrash(
                            root.appendingPathComponent("nope"))) == nil)
        }
    }
}
