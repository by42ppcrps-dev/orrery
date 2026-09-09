import AppKit
import Foundation

/// One selection, one instruction, one proposal. The agent runs as a fresh one-turn session of
/// the current provider, is told to answer with exactly one fenced block, and has every tool
/// approval refused. The buffer changes only after review, and only if the selection still
/// holds what the agent saw.
@MainActor @Observable
final class InlineEditSession: Identifiable {
    enum Phase: Equatable { case composing, running, reviewing, failed(String), applied }
    static let selectionByteLimit = 200_000
    static let contextLines = 40

    let id = UUID()
    let document: CodeDocument
    let range: NSRange
    let original: String
    let provider: Provider
    let modelID: String?
    @ObservationIgnored weak var textView: CodeTextView?
    var instruction = ""
    var phase: Phase = .composing
    var proposal: String?
    var reply = ""
    var costUSD: Double?
    var applyNote: String?
    var stallTimeout: TimeInterval = 240
    private(set) var refusedTools = 0
    @ObservationIgnored private var collector: TurnCollector?

    init(document: CodeDocument, range: NSRange, original: String, provider: Provider, modelID: String?, textView: CodeTextView? = nil) {
        self.document = document
        self.range = range
        self.original = original
        self.provider = provider
        self.modelID = modelID
        self.textView = textView
    }

    var isRunning: Bool { phase == .running }
    /// True when the change went through the text view, so ⌘Z undoes it.
    private(set) var appliedThroughEditor = false

    var selectionStillMatches: Bool {
        let storage = document.storage
        guard NSMaxRange(range) <= storage.length else { return false }
        return (storage.string as NSString).substring(with: range) == original
    }

    var lineSummary: String {
        let first = document.decorator.lineNumber(at: range.location)
        let last = document.decorator.lineNumber(at: max(range.location, NSMaxRange(range) - 1))
        return first == last ? "line \(first)" : "lines \(first)–\(last)"
    }

    static func prompt(instruction: String, fileName: String, language: Language, selection: String, before: String, after: String) -> String {
        let fence = [selection, before, after].contains { $0.contains("```") } ? "````" : "```"
        let tag = language.extensions.first ?? ""
        var text = """
        You are making one inline edit inside \(fileName) (\(language.name)). Reply with exactly one fenced code block \
        containing the full replacement for the SELECTED text and nothing else: no explanation before or after, \
        no tool calls, do not read or write any file. Keep the indentation and style of the surroundings. \
        If the selection should be removed, reply with an empty fenced block.

        Instruction: \(instruction)

        """
        if !before.isEmpty { text += "\nContext before the selection (do not include it in the reply):\n\(fence)\(tag)\n\(before)\n\(fence)\n" }
        text += "\nSELECTED text to replace:\n\(fence)\(tag)\n\(selection)\n\(fence)\n"
        if !after.isEmpty { text += "\nContext after the selection (do not include it in the reply):\n\(fence)\(tag)\n\(after)\n\(fence)\n" }
        return text
    }

    var prompt: String {
        let text = document.storage.string as NSString
        let beforeEnd = min(range.location, text.length)
        let afterStart = min(NSMaxRange(range), text.length)
        let before = text.substring(with: NSRange(location: 0, length: beforeEnd)).components(separatedBy: "\n").suffix(Self.contextLines).joined(separator: "\n")
        let after = text.substring(from: afterStart).components(separatedBy: "\n").prefix(Self.contextLines).joined(separator: "\n")
        return Self.prompt(instruction: instruction.trimmingCharacters(in: .whitespacesAndNewlines), fileName: document.name,
                           language: document.language, selection: original,
                           before: before.trimmingCharacters(in: .newlines), after: after.trimmingCharacters(in: .newlines))
    }

    /// Old and new for the review diff: a whole-line selection and its replacement both end
    /// with a newline, which would otherwise show as a removed and an added blank line.
    var reviewPair: (old: String, new: String) {
        let new = proposal ?? ""
        guard original.hasSuffix("\n"), new.hasSuffix("\n") else { return (original, new) }
        return (String(original.dropLast()), String(new.dropLast()))
    }

    /// The body of the reply's single fenced block. Zero blocks, an unclosed block or more than
    /// one block all mean "no proposal": guessing which block the agent meant is how wrong code
    /// lands in a buffer.
    static func proposal(in reply: String) -> String? {
        let lines = reply.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [String] = []
        var index = 0
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("```") else { index += 1; continue }
            let fence = String(line.prefix { $0 == "`" })
            var body: [String] = []
            var closer = index + 1
            var closed = false
            while closer < lines.count {
                if lines[closer].trimmingCharacters(in: .whitespaces) == fence { closed = true; break }
                body.append(lines[closer]); closer += 1
            }
            guard closed else { return nil }
            blocks.append(body.joined(separator: "\n"))
            index = closer + 1
        }
        return blocks.count == 1 ? blocks[0] : nil
    }

    /// Match the selection's line structure: a whole-line selection keeps its trailing newline,
    /// an inline one never gains one. An empty block stays empty so a line can be removed.
    static func normalized(_ proposal: String, like original: String) -> String {
        guard !proposal.isEmpty else { return "" }
        if original.hasSuffix("\n") { return proposal.hasSuffix("\n") ? proposal : proposal + "\n" }
        var trimmed = proposal
        while trimmed.hasSuffix("\n") { trimmed.removeLast() }
        return trimmed
    }

    func run(makeBackend: (Provider) -> any AgentBackend, project: URL) async {
        guard !isRunning else { return }
        guard !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            phase = .failed("Say what should change first."); return
        }
        phase = .running; proposal = nil; reply = ""; costUSD = nil; applyNote = nil; refusedTools = 0
        let backend = makeBackend(provider)
        backend.persistsSelection = false
        if let modelID, !modelID.isEmpty { backend.preconfigure(model: modelID, effort: nil) }
        let collector = TurnCollector(backend: backend, provider: provider)
        collector.autoApprove = false
        collector.onPermission = { [weak self] request, _ in
            self?.refusedTools += 1
            request.reply(request.options.first { $0.kind.hasPrefix("reject") }?.id)
        }
        self.collector = collector
        await collector.start(project: project)
        let result = await collector.send(prompt, stallTimeout: stallTimeout)
        self.collector = nil
        guard phase == .running else { return }      // cancelled while waiting
        backend.stop()
        reply = result.text
        costUSD = result.costUSD
        if result.failed {
            phase = .failed(result.failureMessage ?? "The turn ended without an answer."); return
        }
        guard let block = Self.proposal(in: result.text) else {
            phase = .failed(result.text.isEmpty
                            ? "The agent answered with nothing, so nothing was applied."
                            : "The agent did not answer with exactly one fenced code block, so nothing was applied. Its reply is below.")
            return
        }
        proposal = Self.normalized(block, like: original)
        phase = .reviewing
    }

    func cancel() {
        guard isRunning else { return }
        phase = .failed("Cancelled.")
        collector?.stop()
        collector = nil
    }

    @discardableResult
    func apply() -> Bool {
        guard phase == .reviewing, let proposal else { return false }
        guard selectionStillMatches else {
            applyNote = "The selection changed since the agent read it, so nothing was applied. Ask again."
            return false
        }
        if let textView, textView.textStorage === document.storage {
            guard textView.replaceForInlineEdit(range: range, expecting: original, with: proposal) else {
                applyNote = "The editor refused the change."; return false
            }
            appliedThroughEditor = true
        } else {
            document.storage.replaceCharacters(in: range, with: proposal)
            appliedThroughEditor = false
        }
        phase = .applied
        return true
    }
}

extension AppModel {
    func beginInlineEdit(document: CodeDocument, range: NSRange, selection: String, textView: CodeTextView? = nil) {
        guard !isShutDown else { return }
        guard projectURL != nil, isProjectTrusted else { editorNote = "Trust the project before asking an agent to edit it."; return }
        guard installed[provider] == true else { editorNote = "\(provider.displayName) CLI not found; pick an installed agent in the toolbar."; return }
        guard selection.utf8.count <= InlineEditSession.selectionByteLimit else {
            editorNote = "Select less: an inline edit takes up to \(InlineEditSession.selectionByteLimit / 1000) KB."; return
        }
        if let running = inlineEdit, running.isRunning { editorNote = "An inline edit is already running."; return }
        let current = backends[provider]?.currentModel
        inlineEdit = InlineEditSession(document: document, range: range, original: selection, provider: provider,
                                       modelID: (current?.isEmpty == false) ? current : nil, textView: textView)
    }

    func runInlineEdit() async {
        guard let session = inlineEdit, let projectURL else { return }
        await session.run(makeBackend: makeOneShotBackend, project: projectURL)
    }

    /// The menu command when no editor has keyboard focus (the sidebar or the assistant does):
    /// use the active document's last selection, or the caret's line.
    func editActiveSelectionWithAgent() {
        guard let document = activeDocument else { editorNote = "Open a file, then ask for an inline edit."; return }
        let text = document.storage.string as NSString
        var range = document.selection
        if NSMaxRange(range) > text.length { range = NSRange(location: min(range.location, text.length), length: 0) }
        if range.length == 0 { range = text.lineRange(for: range) }
        guard range.length > 0 else { editorNote = "Select something first."; return }
        beginInlineEdit(document: document, range: range, selection: text.substring(with: range))
    }
}
