import AppKit
import Foundation

/// ⌘K inline edits: the reply parser accepts exactly one fenced block, the prompt forbids tools
/// and file writes, the one-shot session is preconfigured, stopped and non-persisting, tool
/// approvals are refused, and the buffer changes only on review of an unchanged selection.
@MainActor
enum AuditInlineEdit {
    static func run(_ audit: Auditor) async {
        audit.section("Inline edit — one fenced block in, one reviewed replacement out")
        audit.equal("a single tagged block is the proposal", InlineEditSession.proposal(in: "Sure:\n```swift\nlet y = 2\n```\nDone."), "let y = 2")
        audit.equal("a bare fence works", InlineEditSession.proposal(in: "```\nx\n```"), "x")
        audit.equal("CRLF replies parse", InlineEditSession.proposal(in: "```\r\nx\r\n```\r\n"), "x")
        audit.equal("a longer fence keeps inner backticks", InlineEditSession.proposal(in: "````md\n```\ncode\n```\n````"), "```\ncode\n```")
        audit.equal("an indented closing fence still closes", InlineEditSession.proposal(in: "```\nx\n  ```"), "x")
        audit.check("no fence means no proposal", InlineEditSession.proposal(in: "I changed it for you.") == nil)
        audit.check("an unclosed fence means no proposal", InlineEditSession.proposal(in: "```swift\nlet y = 2\n") == nil)
        audit.check("two blocks are ambiguous, so no proposal", InlineEditSession.proposal(in: "```\na\n```\n```\nb\n```") == nil)
        audit.equal("an empty block means delete", InlineEditSession.proposal(in: "```\n```"), "")
        audit.equal("a whole-line selection keeps its trailing newline", InlineEditSession.normalized("let y = 2", like: "let x = 1\n"), "let y = 2\n")
        audit.equal("an inline selection never gains a newline", InlineEditSession.normalized("let y = 2\n\n", like: "let x = 1"), "let y = 2")
        audit.equal("an empty proposal stays empty for a whole-line selection", InlineEditSession.normalized("", like: "let x = 1\n"), "")

        let prompt = InlineEditSession.prompt(instruction: "rename x to total", fileName: "a.swift", language: Languages.swift,
                                              selection: "let x = 1", before: "import Foundation", after: "print(x)")
        audit.check("the prompt carries the instruction, the selection and the file",
                    prompt.contains("rename x to total") && prompt.contains("let x = 1") && prompt.contains("a.swift"))
        audit.check("the prompt demands one fenced block and forbids tools and file writes",
                    prompt.contains("exactly one fenced code block") && prompt.contains("no tool calls") && prompt.contains("do not read or write any file"))
        audit.check("context is labeled and excluded from the reply",
                    prompt.contains("Context before") && prompt.contains("Context after") && prompt.contains("do not include it in the reply"))
        audit.check("a selection containing a fence gets a longer fence",
                    InlineEditSession.prompt(instruction: "x", fileName: "n.md", language: Languages.markdown, selection: "```\ncode\n```", before: "", after: "").contains("````"))

        audit.section("Inline edit — the editor command and the one-shot session")
        let (view, document) = makeView(Languages.swift, "let x = 1\nlet y = 2\n")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        defer { window.contentView = nil }
        var captured: (NSRange, String)?
        view.onEditWithAgent = { captured = ($0, $1) }
        view.setSelectedRange(NSRange(location: 4, length: 0))
        view.editSelectionWithAgent(nil)
        audit.equal("with no selection ⌘K takes the caret's whole line", captured?.1, "let x = 1\n")
        view.setSelectedRange(NSRange(location: 0, length: 9))
        view.editSelectionWithAgent(nil)
        audit.equal("with a selection ⌘K takes exactly the selection", captured?.1, "let x = 1")

        let temp = URL(fileURLWithPath: NSTemporaryDirectory())
        let session = InlineEditSession(document: document, range: NSRange(location: 0, length: 9), original: "let x = 1",
                                        provider: .claude, modelID: "claude-fable-5-1", textView: view)
        audit.equal("the session names the selected line", session.lineSummary, "line 1")
        audit.check("the live prompt includes the following line as context", session.prompt.contains("let y = 2"))
        await session.run(makeBackend: { ScriptedBackend(provider: $0, scripts: []) }, project: temp)
        if case let .failed(message) = session.phase { audit.check("an empty instruction is refused before any session starts", message.contains("Say what"), message) }
        else { audit.check("an empty instruction is refused before any session starts", false, "\(session.phase)") }
        session.instruction = "rename x to total"
        let scripted = ScriptedBackend(provider: .claude, scripts: [[
            .permission(PermissionRequest(title: "Write a.swift", detail: "", options: [
                PermissionOption(id: "allow-once", name: "Yes", kind: "allow_once"),
                PermissionOption(id: "reject-once", name: "No", kind: "reject_once")], reply: { _ in })),
            .assistantDelta("Here you go:\n```swift\nlet total = 1\n```\n"),
            .turnFinished(stopReason: "end_turn", costUSD: 0.002)]])
        await session.run(makeBackend: { _ in scripted }, project: temp)
        audit.equal("the scripted turn yields the proposal", session.proposal, "let total = 1")
        audit.equal("the session is in review", session.phase, .reviewing)
        audit.equal("a tool request during the turn was refused, not approved", session.refusedTools, 1)
        audit.check("the backend received the instruction and the selection in one prompt",
                    scripted.prompts.count == 1 && scripted.prompts[0].contains("rename x to total") && scripted.prompts[0].contains("let x = 1"))
        audit.equal("the chosen model was preconfigured", scripted.configuredModel, "claude-fable-5-1")
        audit.check("…before the session started", scripted.configuredBeforeStart)
        audit.equal("the one-shot session is stopped after the answer", scripted.stopCount, 1)
        audit.check("the one-shot session never persists model selection", !scripted.persistsSelection)
        audit.equal("the reported cost is kept", session.costUSD, 0.002)
        audit.check("apply replaces exactly the selection", session.apply() && document.text == "let total = 1\nlet y = 2\n", document.text)
        audit.equal("the session reads applied", session.phase, .applied)
        audit.check("the document is dirty after the edit", document.isDirty)
        audit.check("applying twice is refused", !session.apply())
        view.undoManager?.undo()
        audit.equal("⌘Z in the editor undoes the applied edit", document.text, "let x = 1\nlet y = 2\n")

        let (view2, doc2) = makeView(Languages.swift, "let x = 1\n")
        let changed = InlineEditSession(document: doc2, range: NSRange(location: 0, length: 9), original: "let x = 1", provider: .grok, modelID: nil, textView: view2)
        changed.instruction = "x"
        let scripted2 = ScriptedBackend(provider: .grok, scripts: [[.assistantDelta("```\nlet z = 3\n```"), .turnFinished(stopReason: nil, costUSD: nil)]])
        await changed.run(makeBackend: { _ in scripted2 }, project: temp)
        audit.check("a nil model id leaves the provider's default alone", scripted2.configuredModel == nil)
        doc2.storage.replaceCharacters(in: NSRange(location: 4, length: 1), with: "q")
        audit.check("a selection edited meanwhile is not overwritten",
                    !changed.apply() && doc2.text == "let q = 1\n" && changed.applyNote?.contains("changed") == true, doc2.text)
        audit.equal("…and the session stays in review", changed.phase, .reviewing)

        let prose = InlineEditSession(document: doc2, range: NSRange(location: 0, length: 9), original: "let q = 1", provider: .codex, modelID: nil)
        prose.instruction = "x"
        await prose.run(makeBackend: { _ in ScriptedBackend(provider: .codex, scripts: [[.assistantDelta("I renamed it."), .turnFinished(stopReason: nil, costUSD: nil)]]) }, project: temp)
        if case let .failed(message) = prose.phase {
            audit.check("a reply without a fenced block fails honestly and keeps the reply", message.contains("fenced") && prose.reply == "I renamed it.", message)
        } else { audit.check("a reply without a fenced block fails honestly", false, "\(prose.phase)") }
        audit.check("no proposal means nothing to apply", prose.proposal == nil && !prose.apply())

        let silent = InlineEditSession(document: doc2, range: NSRange(location: 0, length: 9), original: "let q = 1", provider: .codex, modelID: nil)
        silent.instruction = "x"
        silent.stallTimeout = 0.3
        await silent.run(makeBackend: { _ in ScriptedBackend(provider: .codex, scripts: []) }, project: temp)
        if case let .failed(message) = silent.phase { audit.check("a silent agent is reported by the stall deadline", message.contains("silent"), message) }
        else { audit.check("a silent agent is reported by the stall deadline", false, "\(silent.phase)") }

        let cancelled = InlineEditSession(document: doc2, range: NSRange(location: 0, length: 9), original: "let q = 1", provider: .grok, modelID: nil)
        cancelled.instruction = "x"
        cancelled.stallTimeout = 5
        let cancelBackend = ScriptedBackend(provider: .grok, scripts: [])
        let running = Task { await cancelled.run(makeBackend: { _ in cancelBackend }, project: temp) }
        _ = await waitUntil(2) { cancelled.isRunning && cancelBackend.prompts.count == 1 }
        cancelled.cancel()
        await running.value
        audit.equal("cancel ends the turn and says so", cancelled.phase, .failed("Cancelled."))
        audit.check("cancel stops the one-shot session", cancelBackend.stopCount >= 1 && cancelBackend.cancelCount == 1, "stop=\(cancelBackend.stopCount) cancel=\(cancelBackend.cancelCount)")

        audit.section("Inline edit — the app model gates the command")
        let model = AppModel(trust: .forAudit)
        defer { model.shutdown() }
        model.editorNote = nil
        model.beginInlineEdit(document: doc2, range: NSRange(location: 0, length: 9), selection: "let q = 1")
        audit.check("without a project the command explains instead of opening a sheet", model.inlineEdit == nil && (model.editorNote ?? "").contains("Trust"), model.editorNote ?? "nil")
        await Auditor.withTemporaryDirectory { dir in
            model.openProject(dir)
            model.installed[model.provider] = false
            model.editorNote = nil
            model.beginInlineEdit(document: doc2, range: NSRange(location: 0, length: 9), selection: "let q = 1")
            audit.check("a missing CLI is named", model.inlineEdit == nil && (model.editorNote ?? "").contains("not found"), model.editorNote ?? "nil")
            model.installed[model.provider] = true
            model.editorNote = nil
            model.beginInlineEdit(document: doc2, range: NSRange(location: 0, length: 9), selection: String(repeating: "x", count: InlineEditSession.selectionByteLimit + 1))
            audit.check("an oversized selection is refused with a limit", model.inlineEdit == nil && (model.editorNote ?? "").contains("KB"), model.editorNote ?? "nil")
            model.beginInlineEdit(document: doc2, range: NSRange(location: 0, length: 9), selection: "let q = 1")
            audit.check("a trusted project with an installed CLI opens the sheet's session", model.inlineEdit != nil && model.inlineEdit?.provider == model.provider)
            model.inlineEdit = nil

            var settings = AgentSessionSettings()
            settings.resumeSession = "solo-session-123"; settings.planMode = true; settings.outputSchema = "{}"
            model.agentSettings[model.provider] = settings
            audit.equal("the Solo backend still resumes the saved session", model.makeBackend(model.provider).sessionSettings.resumeSession, "solo-session-123")
            let oneShot = model.makeOneShotBackend(model.provider).sessionSettings
            audit.check("the ⌘K backend never resumes the Solo session, plans or formats output",
                        oneShot.resumeSession.isEmpty && !oneShot.planMode && oneShot.outputSchema.isEmpty)
            model.agentSettings[model.provider] = AgentSessionSettings()

            let file = dir.appendingPathComponent("notes.md")
            try? "# title\nsecond line\n".write(to: file, atomically: true, encoding: .utf8)
            model.open(file: file)
            model.editorNote = nil
            if let open = model.activeDocument {
                open.selection = NSRange(location: 9, length: 0)
                model.editActiveSelectionWithAgent()
                audit.equal("with no focused editor the menu falls back to the active document's caret line", model.inlineEdit?.original, "second line\n")
                model.inlineEdit = nil
                open.selection = NSRange(location: 2, length: 5)
                model.editActiveSelectionWithAgent()
                audit.equal("…or to its last selection", model.inlineEdit?.original, "title")
                model.inlineEdit = nil
            } else { audit.check("the fallback needs an active document", false, "no active document after open") }
        }
        let pair = InlineEditSession(document: doc2, range: NSRange(location: 0, length: 10), original: "let q = 1\n", provider: .grok, modelID: nil)
        pair.proposal = "let z = 3\n"
        audit.check("the review diff drops the newline both sides share", pair.reviewPair.old == "let q = 1" && pair.reviewPair.new == "let z = 3")
        let inline = InlineEditSession(document: doc2, range: NSRange(location: 0, length: 9), original: "let q = 1", provider: .grok, modelID: nil)
        inline.proposal = "let z = 3"
        audit.check("an inline selection is diffed as is", inline.reviewPair.old == "let q = 1" && inline.reviewPair.new == "let z = 3")
        var root = URL(fileURLWithPath: #filePath)
        while root.path != "/" && !FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path) { root.deleteLastPathComponent() }
        let app = (try? String(contentsOf: root.appendingPathComponent("Sources/Orrery/OrreryApp.swift"), encoding: .utf8)) ?? ""
        audit.check("the menu command falls back to the active document when no editor is focused", app.contains("model?.editActiveSelectionWithAgent()"))
        audit.check("⌘K is the inline edit and ⌘⇧K belongs to Delete Line alone",
                    app.contains("Edit Selection with Agent…") && app.contains(".keyboardShortcut(\"k\", modifiers: .command)")
                    && app.components(separatedBy: "\"k\", modifiers: [.command, .shift]").count == 2)
    }

    private static func makeView(_ language: Language, _ text: String) -> (CodeTextView, CodeDocument) {
        let document = CodeDocument(name: "scratch.\(language.extensions.first ?? "txt")", language: language, text: text)
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        layoutManager.addTextContainer(container)
        document.storage.addLayoutManager(layoutManager)
        let view = CodeTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        view.configure()
        view.decorator = document.decorator
        view.language = language
        return (view, document)
    }

    private static func waitUntil(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }
}
