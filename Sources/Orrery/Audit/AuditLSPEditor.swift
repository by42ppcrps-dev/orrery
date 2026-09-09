import AppKit
import Foundation

/// Section 7b — editor UI on top of the LSP plumbing: completion popup, hover, go-to-definition,
/// `--lsp-probe`, and the timeout-vs-empty distinction. Live checks talk to a real sourcekit-lsp
/// in a temporary SwiftPM package. If the binary is missing, that is named rather than skipped.
@MainActor
enum AuditLSPEditor {

    static func run(_ audit: Auditor) async {
        parsing(audit)
        await probeDispatch(audit)
        popup(audit)
        await tracking(audit)
        honesty(audit)
        await timeoutVersusEmpty(audit)
        await jumpNotes(audit)
        await liveSourcekit(audit)
    }

    // MARK: - Probe parsing and flag values

    private static func parsing(_ audit: Auditor) {
        audit.section("LSP editor — --lsp-probe parsing")

        switch LSPProbe.parse("/tmp/Demo.swift:12:4") {
        case let .success(spec):
            audit.check("file:line:col parses into path, line, and column",
                        spec.path == "/tmp/Demo.swift" && spec.line == 12 && spec.column == 4,
                        "path=\(spec.path) line=\(spec.line) col=\(spec.column)")
        case let .failure(error):
            audit.check("file:line:col parses into path, line, and column", false, error.message)
        }

        switch LSPProbe.parse("Sources/Lib.swift:3:1") {
        case let .success(spec):
            audit.check("a relative path in file:line:col is accepted",
                        spec.path == "Sources/Lib.swift" && spec.line == 3 && spec.column == 1,
                        "path=\(spec.path) line=\(spec.line) col=\(spec.column)")
        case let .failure(error):
            audit.check("a relative path in file:line:col is accepted", false, error.message)
        }

        func rejects(_ spec: String, _ name: String) {
            switch LSPProbe.parse(spec) {
            case .success:
                audit.check(name, false, "parsed \(spec)")
            case .failure:
                audit.check(name, true)
            }
        }
        rejects("Foo.swift:10", "--lsp-probe rejects a spec with no column")
        rejects("Foo.swift:a:1", "--lsp-probe rejects a non-integer line")
        rejects("Foo.swift:0:1", "--lsp-probe rejects a zero line")
        rejects("Foo.swift", "--lsp-probe rejects a spec with no colons")
        rejects("", "--lsp-probe rejects an empty spec")
        rejects(":1:1", "--lsp-probe rejects a spec with an empty path")

        let args = ["Orrery", "--lsp-probe", "Foo.swift:3:1", "/tmp/proj"]
        audit.check("--lsp-probe value is not treated as a project path",
                    LaunchArguments.flagValues(in: args).contains("Foo.swift:3:1")
                    && LaunchArguments.positionalPaths(in: args) == ["/tmp/proj"],
                    "paths=\(LaunchArguments.positionalPaths(in: args))")
        audit.check("--lsp-probe /tmp is not treated as a positional project path",
                    LaunchArguments.positionalPaths(in: ["Orrery", "--lsp-probe", "/tmp"])
                        .isEmpty)
    }

    /// Goes through `openLaunchArguments`, not `runLSPProbe`. Removing the flag dispatch
    /// must fail this check even if `runLSPProbe` still exists.
    private static func probeDispatch(_ audit: Auditor) async {
        audit.section("LSP editor — --lsp-probe launch dispatch")
        let model = AppModel(trust: .forAudit)
        defer { model.shutdown() }
        model.openLaunchArguments(["Orrery", "--lsp-probe", "/nope/missing.swift:2:3"])
        audit.check("openLaunchArguments dispatches --lsp-probe",
                    model.lspProbeTask != nil,
                    "lspProbeTask was nil — the flag was not started")
        let output = await model.lspProbeTask?.value ?? ""
        audit.check("the dispatched --lsp-probe runs the probe",
                    output.hasPrefix("lsp-probe"),
                    output)
    }

    // MARK: - Popup behaviour

    private static func popup(_ audit: Auditor) {
        audit.section("LSP editor — completion popup")

        let items = [
            LSPCompletionItem(label: "alphaSymbol", detail: nil, kind: "func",
                              insertText: "alphaSymbol", editRange: nil, sortText: "a"),
            LSPCompletionItem(label: "betaSymbol", detail: nil, kind: "func",
                              insertText: "betaSymbol", editRange: nil, sortText: "b"),
            LSPCompletionItem(label: "gammaSymbol", detail: nil, kind: "func",
                              insertText: "gammaSymbol", editRange: nil, sortText: "c"),
        ]

        do {
            let (view, _) = makeView(Languages.swift, "al")
            view.setSelectedRange(NSRange(location: 2, length: 0))
            view.presentCompletions(items, prefix: "al")
            audit.equal("the completion popup filters as you type",
                        view.completionLabels, ["alphaSymbol"])
        }
        do {
            let (view, _) = makeView(Languages.swift, "")
            view.presentCompletions(items, prefix: "")
            view.moveCompletionHighlight(1)
            audit.equal("down arrow selects the next completion",
                        view.selectedCompletionLabel, "betaSymbol")
            view.moveCompletionHighlight(-1)
            audit.equal("up arrow selects the previous completion",
                        view.selectedCompletionLabel, "alphaSymbol")
        }
        do {
            let (view, _) = makeView(Languages.swift, "al")
            view.setSelectedRange(NSRange(location: 2, length: 0))
            view.presentCompletions(items, prefix: "al")
            view.insertNewline(nil)
            audit.equal("Return applies the LSP insertText", view.string, "alphaSymbol")
            audit.check("Return dismisses the popup", !view.isCompletionVisible)
        }
        do {
            let (view, _) = makeView(Languages.swift, "f")
            view.setSelectedRange(NSRange(location: 1, length: 0))
            let edit = LSPCompletionItem(
                label: "foo", detail: nil, kind: "func",
                insertText: "foo()",
                editRange: NSRange(location: 0, length: 1),
                sortText: nil)
            view.presentCompletions([edit], prefix: "f")
            view.insertTab(nil)
            audit.equal("Tab applies the LSP textEdit range", view.string, "foo()")
        }
        do {
            let (view, _) = makeView(Languages.swift, "")
            view.presentCompletions(items, prefix: "")
            audit.check("the popup is visible before Escape", view.isCompletionVisible)
            view.cancelOperation(nil)
            audit.check("Escape dismisses the completion popup", !view.isCompletionVisible)
        }

        for name in [NSAppearance.Name.aqua, .darkAqua] {
            guard let appearance = NSAppearance(named: name) else { continue }
            let popup = CompletionPopupView(frame: .zero)
            popup.setItems(items, prefix: "")
            let size = popup.intrinsicContentSize
            popup.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: popup.frame, styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.appearance = appearance
            window.colorSpace = .sRGB
            window.contentView = popup
            window.layoutIfNeeded()
            popup.needsDisplay = true
            popup.display()
            let counts = AuditRendering.histogram(popup, popup.bounds)
            let nonBg = nonBackgroundPixels(counts, appearance: appearance)
            audit.check("the completion popup renders non-background pixels (\(name.rawValue))",
                        nonBg > 20,
                        "non-background=\(nonBg) colours=\(counts.count)")
            window.contentView = nil
        }
    }

    // MARK: - Tracking area / dwell

    private static func tracking(_ audit: Auditor) async {
        audit.section("LSP editor — hover tracking")
        let (view, _) = makeView(Languages.swift, "let x = 1\n")
        view.configure()
        let tracks = view.trackingAreas.contains {
            $0.options.contains(.mouseMoved) && $0.options.contains(.inVisibleRect)
        }
        audit.check("the editor installs a mouseMoved tracking area", tracks)
        audit.equal("hover dwell is 0.4 seconds", CodeTextView.hoverDwellSeconds, 0.4)

        let model = AppModel(trust: .forAudit)
        defer { model.shutdown() }
        let hosted = hostedEditor(language: Languages.markdown, text: "# x\n", model: model)
        defer { hosted.window.contentView = nil }
        guard let event = mouseEvent(in: hosted.view, type: .mouseMoved, command: false) else {
            audit.check("a mouse dwell asks the language server for hover", false,
                        "could not synthesize a mouseMoved event")
            return
        }
        hosted.view.mouseMoved(with: event)
        try? await Task.sleep(nanoseconds: 150_000_000)
        audit.check("hover does not fire before the dwell",
                    (model.editorNote ?? "").isEmpty && !hosted.view.isHoverVisible,
                    "note=\(model.editorNote ?? "nil") hoverVisible=\(hosted.view.isHoverVisible)")
        let fired = await waitUntil(1.0) {
            !(model.editorNote ?? "").isEmpty || hosted.view.isHoverVisible
        }
        let note = model.editorNote ?? ""
        audit.check("a mouse dwell asks the language server for hover",
                    fired && (note.lowercased().contains("no language server")
                              || hosted.view.isHoverVisible),
                    note.isEmpty ? "no hover and no note after dwell" : note)
    }

    // MARK: - Honesty: no-server vs empty

    private static func honesty(_ audit: Auditor) {
        audit.section("LSP editor — timeout vs empty vs no server")
        let empty = LSPQueryResult(value: [LSPCompletionItem](), outcome: .success, note: nil)
        let timeout = LSPQueryResult(value: [LSPCompletionItem](), outcome: .timedOut,
                                     note: "The language server did not reply to textDocument/completion within 5s.")
        let none = LSPQueryResult(value: [LSPCompletionItem](), outcome: .noServer,
                                  note: "No language server wired for Python.")
        audit.check("a timeout is not reported as an empty completion list",
                    empty.outcome == .success && timeout.outcome == .timedOut
                    && empty.value.isEmpty && timeout.value.isEmpty)
        audit.check("timeout output is distinct from an empty list",
                    LSPProbe.output(for: timeout) != LSPProbe.output(for: empty)
                    && LSPProbe.output(for: timeout).hasPrefix("lsp-probe timed out:"))
        audit.check("an empty success prints a distinct no-completions line",
                    LSPProbe.output(for: empty) == "lsp-probe: no completions")
        audit.check("no server is distinct from empty success",
                    none.outcome == .noServer
                    && LSPProbe.output(for: none).hasPrefix("lsp-probe:"))
    }

    private static func timeoutVersusEmpty(_ audit: Auditor) async {
        let manager = LSPManager()
        manager.executableOverride = { _ in "/bin/sleep" }
        manager.auditProcessArguments = ["30"]
        manager.auditSkipHandshake = true
        manager.queryDeadline = 0.4
        await Auditor.withTemporaryDirectory { dir in
            let url = dir.appendingPathComponent("Sleep.swift")
            try? "let x = 1\n".write(to: url, atomically: true, encoding: .utf8)
            let document = CodeDocument(url: url)
            await manager.ensureOpen(document, root: dir)
            let result = await manager.completions(for: document, line: 1, column: 5)
            audit.check("a completion timeout is not an empty success",
                        result.outcome == .timedOut && result.value.isEmpty,
                        "outcome=\(result.outcome) note=\(result.note ?? "nil")")
            let probe = LSPProbe.output(for: result)
            audit.check("the probe prints an honest timeout line",
                        probe.hasPrefix("lsp-probe timed out:"),
                        probe)
            await manager.shutdown()
        }

        let missing = LSPManager()
        let markdown = CodeDocument(name: "notes.md", language: Languages.markdown, text: "# x\n")
        let none = await missing.completions(for: markdown, line: 1, column: 1)
        audit.check("completions with no server named as noServer, not empty success",
                    none.outcome == .noServer && none.value.isEmpty
                    && (none.note ?? "").lowercased().contains("no language server"),
                    none.note ?? "nil")
    }

    // MARK: - Named failures in the status line

    private static func jumpNotes(_ audit: Auditor) async {
        audit.section("LSP editor — go-to-definition honesty")
        let idle = AppModel(trust: .forAudit)
        defer { idle.shutdown() }
        await idle.jumpToDefinition()
        audit.check("a missing definition is named in the status line",
                    (idle.editorNote ?? "").contains("No file open"),
                    idle.editorNote ?? "nil")

        await Auditor.withTemporaryDirectory { dir in
            let url = dir.appendingPathComponent("notes.md")
            try? "# x\n".write(to: url, atomically: true, encoding: .utf8)
            let model = AppModel(trust: .forAudit)
            defer { model.shutdown() }
            model.openProject(dir)
            model.open(file: url)

            let dummy = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 80, height: 80),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = dummy
            _ = window.makeFirstResponder(dummy)
            defer { window.contentView = nil }

            model.editorNote = nil
            await StudioNavigate.jumpToDefinition(model)
            let note = model.editorNote ?? ""
            audit.check("go-to-definition without a language server is named",
                        note.lowercased().contains("no language server")
                        || note.contains("Markdown"),
                        note.isEmpty ? "nil" : note)
            audit.check("the Jump to Definition command uses the focused window model",
                        !(window.firstResponder is CodeTextView)
                        && (note.lowercased().contains("no language server")
                            || note.contains("Markdown")),
                        "firstResponder=\(String(describing: window.firstResponder)) note=\(note.isEmpty ? "nil" : note)")
        }

        let hostedModel = AppModel(trust: .forAudit)
        hostedModel.projectURL = URL(fileURLWithPath: NSTemporaryDirectory())
        defer { hostedModel.shutdown() }
        let hosted = hostedEditor(language: Languages.markdown, text: "# x\n",
                                  model: hostedModel)
        defer { hosted.window.contentView = nil }

        hostedModel.editorNote = nil
        guard let click = mouseEvent(in: hosted.view, type: .leftMouseDown, command: true) else {
            audit.check("⌘-click asks for a definition at the click point", false,
                        "could not synthesize a command-click")
            return
        }
        hosted.view.mouseDown(with: click)
        let clicked = await waitUntil(1.0) { !(hostedModel.editorNote ?? "").isEmpty }
        let clickNote = hostedModel.editorNote ?? ""
        audit.check("⌘-click asks for a definition at the click point",
                    clicked && (clickNote.lowercased().contains("no language server")
                                || clickNote.lowercased().contains("no definition")),
                    clickNote.isEmpty ? "no note after ⌘-click" : clickNote)
    }

    // MARK: - Real sourcekit-lsp

    private static func liveSourcekit(_ audit: Auditor) async {
        audit.section("LSP editor — sourcekit-lsp (completion, hover, go-to-def, probe)")
        guard Executables.find(Self.sourcekitCandidates, orNamed: "sourcekit-lsp") != nil else {
            audit.check("sourcekit-lsp is installed", false,
                        "no binary at /usr/bin/sourcekit-lsp or on PATH")
            return
        }

        await Auditor.withTemporaryDirectory { dir in
            writeSwiftPackage(in: dir)
            let lib = dir.appendingPathComponent("Sources/AuditLSPPkg/Lib.swift")
            let call = dir.appendingPathComponent("Sources/AuditLSPPkg/Call.swift")
            let libSource = """
            /// AuditHoverSymbol is used by the editor hover check.
            public enum AuditHoverSymbol {
                /// Returns a greeting used by the completion check.
                public static func greet() -> String { "hello" }
            }

            """
            let callSource = """
            public enum AuditCaller {
                public static func run() {
                    let value = AuditHoverSymbol.greet()
                    _ = value
                }
            }

            """
            try? libSource.write(to: lib, atomically: true, encoding: .utf8)
            try? callSource.write(to: call, atomically: true, encoding: .utf8)

            let expectedDefLine = (libSource.components(separatedBy: "\n").enumerated().first {
                $0.element.contains("public enum AuditHoverSymbol")
            }?.offset ?? 1) + 1

            let model = AppModel(trust: .forAudit)
            defer { model.shutdown() }
            model.openProject(dir)
            model.open(file: lib)
            model.open(file: call)
            guard let callDoc = model.documents.document(for: call),
                  let libDoc = model.documents.document(for: lib) else {
                audit.check("opening the Swift pair created tabs", false)
                return
            }
            await model.lsp.ensureOpen(libDoc, root: dir)
            await model.lsp.ensureOpen(callDoc, root: dir)

            let handshake = await waitUntil(12) {
                model.lsp.initializeResult(for: callDoc) != nil
            }
            guard handshake else {
                audit.check("sourcekit-lsp initialize/initialized handshake completes", false,
                            "no initialize result within 12s")
                return
            }

            let callText = callDoc.text as NSString
            let member = callText.range(of: "AuditHoverSymbol.")
            let symbol = callText.range(of: "AuditHoverSymbol")
            guard member.location != NSNotFound, symbol.location != NSNotFound else {
                audit.check("the call site contains AuditHoverSymbol", false, callDoc.text)
                return
            }
            let memberOffset = member.location + member.length
            let memberLine = callDoc.decorator.lineNumber(at: memberOffset)
            let memberCol = memberOffset
                - (callDoc.decorator.range(ofLine: memberLine)?.location ?? 0) + 1
            let symbolLine = callDoc.decorator.lineNumber(at: symbol.location + 2)
            let symbolCol = symbol.location + 2
                - (callDoc.decorator.range(ofLine: symbolLine)?.location ?? 0) + 1

            var labels: [String] = []
            var compNote: String?
            let gotComp = await waitUntil(20) {
                let result = await model.lsp.completions(for: callDoc, line: memberLine,
                                                         column: memberCol)
                labels = result.value.map(\.label)
                compNote = result.note
                return labels.contains { $0.localizedCaseInsensitiveContains("greet") }
            }
            audit.check("completion at a known caret returns an expected symbol",
                        gotComp,
                        gotComp
                            ? labels.prefix(10).joined(separator: ", ")
                            : "labels=\(labels.prefix(10).joined(separator: ", ")) note=\(compNote ?? "nil")")

            var def: LSPLocation?
            var defNote: String?
            _ = await waitUntil(20) {
                let result = await model.lsp.definition(for: callDoc, line: symbolLine,
                                                        column: symbolCol)
                def = result.value
                defNote = result.note
                return result.value?.url.lastPathComponent == "Lib.swift"
            }
            audit.check("cross-file go-to-definition resolves to the right file",
                        def?.url.lastPathComponent == "Lib.swift",
                        def.map { "\($0.url.lastPathComponent):\($0.line)" } ?? (defNote ?? "nil"))
            audit.check("cross-file go-to-definition resolves to the right line",
                        def?.line == expectedDefLine,
                        "got line \(def?.line ?? -1), expected \(expectedDefLine)")

            if let location = def {
                model.open(file: location.url, atLine: location.line, column: location.column)
                audit.equal("jumping to a definition opens the other file",
                            model.documents.active?.url.lastPathComponent, "Lib.swift")
            } else {
                audit.check("jumping to a definition opens the other file", false, "no location")
            }

            var hoverText = ""
            var hoverNote: String?
            let gotHover = await waitUntil(20) {
                let result = await model.lsp.hover(for: libDoc, line: expectedDefLine, column: 14)
                hoverText = result.value ?? ""
                hoverNote = result.note
                return hoverText.contains("editor hover check")
            }
            audit.check("hover for a documented symbol contains its doc comment text",
                        gotHover,
                        gotHover ? hoverText.prefix(180).replacingOccurrences(of: "\n", with: " ")
                            : "hover=\(hoverText.prefix(120)) note=\(hoverNote ?? "nil")")

            let spec = "\(call.path):\(memberLine):\(memberCol)"
            model.openLaunchArguments(["Orrery", "--lsp-probe", spec])
            guard let task = model.lspProbeTask else {
                audit.check("the --lsp-probe flag prints the labels", false,
                            "openLaunchArguments did not dispatch --lsp-probe")
                return
            }
            let probe = await task.value
            audit.check("the --lsp-probe flag prints the labels",
                        probe.localizedCaseInsensitiveContains("greet")
                        && !probe.hasPrefix("lsp-probe timed out:")
                        && !probe.hasPrefix("lsp-probe error:"),
                        probe)
        }
    }

    // MARK: - Helpers

    private static func hostedEditor(language: Language, text: String, model: AppModel,
                                     document: CodeDocument? = nil)
        -> (view: CodeTextView, document: CodeDocument, window: NSWindow,
            coordinator: CodeEditorView.Coordinator) {
        let (view, created) = makeView(language, text)
        let document = document ?? created
        view.decorator = document.decorator
        view.language = document.language
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.layoutIfNeeded()
        view.layoutManager?.ensureLayout(for: view.textContainer!)
        let coordinator = CodeEditorView.Coordinator(onSave: {}, onEdit: {}, model: model)
        coordinator.textView = view
        coordinator.document = document
        coordinator.attachLSP(to: view)
        return (view, document, window, coordinator)
    }

    private static func mouseEvent(in view: CodeTextView, type: NSEvent.EventType,
                                   command: Bool) -> NSEvent? {
        let local = NSPoint(x: 24, y: 16)
        let location = view.convert(local, to: nil)
        var flags: NSEvent.ModifierFlags = []
        if command { flags.insert(.command) }
        return NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: view.window?.windowNumber ?? 0,
            context: nil,
            eventNumber: 1,
            clickCount: type == .leftMouseDown ? 1 : 0,
            pressure: 1)
    }

    private static func makeView(_ language: Language, _ text: String)
        -> (CodeTextView, CodeDocument) {
        let document = CodeDocument(name: "scratch.\(language.extensions.first ?? "txt")",
                                    language: language, text: text)
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 600,
                                                     height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        layoutManager.addTextContainer(container)
        document.storage.addLayoutManager(layoutManager)
        let view = CodeTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400),
                                textContainer: container)
        view.configure()
        view.decorator = document.decorator
        view.language = language
        return (view, document)
    }

    @discardableResult
    private static func waitUntil(_ timeout: Double,
                                  _ predicate: @MainActor () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await predicate() { return true }
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
        return await predicate()
    }

    private static func nonBackgroundPixels(_ counts: [NSColor: Int],
                                            appearance: NSAppearance) -> Int {
        var background: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            background = EditorTheme.background.usingColorSpace(.sRGB)
        }
        guard let background else { return 0 }
        var total = 0
        for (colour, n) in counts {
            guard let sample = colour.usingColorSpace(.sRGB) else { continue }
            let distance = abs(sample.redComponent - background.redComponent)
                + abs(sample.greenComponent - background.greenComponent)
                + abs(sample.blueComponent - background.blueComponent)
            if distance > 0.08 { total += n }
        }
        return total
    }

    private static let sourcekitCandidates = [
        "/usr/bin/sourcekit-lsp",
        "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/sourcekit-lsp",
    ]

    private static func writeSwiftPackage(in dir: URL) {
        let manifest = """
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(
            name: "AuditLSPPkg",
            platforms: [.macOS(.v14)],
            products: [.library(name: "AuditLSPPkg", targets: ["AuditLSPPkg"])],
            targets: [.target(name: "AuditLSPPkg")]
        )
        """
        try? manifest.write(to: dir.appendingPathComponent("Package.swift"),
                            atomically: true, encoding: .utf8)
        let sources = dir.appendingPathComponent("Sources/AuditLSPPkg")
        try? FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    }
}
