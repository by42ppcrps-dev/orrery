import Foundation
import Observation

/// Runs a language's own checker over the buffer and turns what it prints into diagnostics.
///
/// Two rules shape this:
///   * It checks what is *in the editor*, not what is on disk, so unsaved edits are covered.
///     The buffer is written to a scratch copy under the same filename and the tool runs there.
///   * When no checker is installed it says which one is missing. An empty problems list has to
///     mean "checked and clean", never "nothing ran".
@MainActor
@Observable
final class DiagnosticsEngine {
    var canExecute: () -> Bool = { true }
    var isEnabled: Bool = UserDefaults.standard.object(forKey: "diagnosticsEnabled") as? Bool
        ?? true {
        didSet { UserDefaults.standard.set(isEnabled, forKey: "diagnosticsEnabled") }
    }

    /// Per-file state, so switching tabs shows what was found for that file.
    private(set) var results: [URL: [Diagnostic]] = [:]
    private(set) var notes: [URL: String] = [:]
    private(set) var running: Set<URL> = []
    private(set) var lastRun: [URL: Date] = [:]

    private var debounces: [URL: Task<Void, Never>] = [:]
    /// Concurrent checks of one file must not clobber each other, and an older check finishing
    /// late must not overwrite a newer result. Found live: two refresh bursts after an
    /// orchestrator run raced — one check deleted the shared scratch copy while the other's
    /// python3 was opening it, which published "[Errno 2] No such file" as an error on line 1
    /// of a perfectly valid file.
    private var checkSequence: [URL: Int] = [:]
    /// URLs whose diagnostics currently come from a live language server.
    private var liveCovered: Set<URL> = []
    /// URLs that have received at least one `publishDiagnostics` while live-covered.
    private var lspPublished: Set<URL> = []
    private var liveServerName: [URL: String] = [:]
    /// Honest "server stopped / missing" sentences. Survive a subsequent one-shot publish
    /// so the Problems pane does not look like a clean bill of health after a crash.
    private var fallbackNotes: [URL: String] = [:]
    /// When set, `description(for:)` includes the language-server honesty sentence
    /// (`unavailableNote`) so "no language server wired" reaches the Problems pane.
    var languageServerNote: ((Language) -> String?)?
    private let scratch: URL

    /// Long enough that typing does not spawn a compiler on every keystroke, short enough that
    /// the underline appears while you are still looking at the line.
    static let debounceSeconds: Double = 0.7

    init() {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("orrery-check-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: scratch)
    }

    /// What will run for this file, in words, for the status bar and the empty problems list.
    func description(for document: CodeDocument) -> String {
        guard canExecute() else { return "Trust this project to run language tools." }
        guard isEnabled else { return "Checking is off." }
        if liveCovered.contains(document.url), let name = liveServerName[document.url] {
            return "Checked live by \(name) (semantic)."
        }
        if let fallback = fallbackNotes[document.url] {
            return fallback
        }
        if document.language.id == "json" {
            return withLanguageServerNote("Checked with the built-in JSON parser.",
                                          language: document.language)
        }
        guard let (checker, _) = Checkers.resolve(for: document.language) else {
            return withLanguageServerNote(Checkers.unavailableNote(for: document.language),
                                          language: document.language)
        }
        return withLanguageServerNote("Checked with \(checker.name). \(checker.scope)",
                                      language: document.language)
    }

    private func withLanguageServerNote(_ base: String, language: Language) -> String {
        guard let extra = languageServerNote?(language), !extra.isEmpty else { return base }
        if base.contains(extra) { return base }
        return base + " " + extra
    }

    func isLiveCovered(_ url: URL) -> Bool { liveCovered.contains(url) }

    func setLiveCoverage(_ url: URL, server: String?) {
        if let server {
            liveCovered.insert(url)
            liveServerName[url] = server
        } else {
            liveCovered.remove(url)
            liveServerName.removeValue(forKey: url)
            // lspPublished is left for noteLSPFailure so it can tell stale LSP results
            // from a one-shot that has not yet published.
        }
    }

    /// Live-server diagnostics replace one-shot checker results for this document.
    /// Bumps the newest-wins sequence so an in-flight `swiftc -parse` cannot overwrite them.
    func applyLSPDiagnostics(_ found: [Diagnostic], for document: CodeDocument) {
        guard isEnabled else { return }
        let url = document.url
        checkSequence[url] = (checkSequence[url] ?? 0) + 1
        liveCovered.insert(url)
        lspPublished.insert(url)
        if let source = found.first?.source {
            liveServerName[url] = source
        }
        fallbackNotes[url] = nil
        results[url] = found
        notes[url] = nil
        lastRun[url] = Date()
        document.diagnostics = found
    }

    func noteLSPFailure(for url: URL, message: String, document: CodeDocument? = nil) {
        let hadPublish = lspPublished.contains(url)
        liveCovered.remove(url)
        liveServerName.removeValue(forKey: url)
        lspPublished.remove(url)
        fallbackNotes[url] = message
        notes[url] = message
        if hadPublish {
            results[url] = []
            document?.diagnostics = []
        }
    }

    func hasChecker(for language: Language) -> Bool {
        language.id == "json" || Checkers.resolve(for: language) != nil
    }

    func diagnostics(for url: URL) -> [Diagnostic] { results[url] ?? [] }

    func clear(_ url: URL) {
        debounces[url]?.cancel()
        debounces[url] = nil
        results[url] = nil
        notes[url] = nil
        running.remove(url)
        liveCovered.remove(url)
        liveServerName.removeValue(forKey: url)
        lspPublished.remove(url)
        fallbackNotes[url] = nil
    }

    /// Called on every edit. Coalesces bursts of typing into one run.
    func scheduleCheck(_ document: CodeDocument) {
        guard isEnabled, canExecute() else { return }
        let url = document.url
        if liveCovered.contains(url), lspPublished.contains(url) { return }
        debounces[url]?.cancel()
        debounces[url] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.debounceSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.check(document)
        }
    }

    /// Run now — on save, on opening a tab, or from the Problems pane.
    func check(_ document: CodeDocument) async {
        guard canExecute() else { notes[document.url] = "Trust this project to run language tools."; return }
        guard isEnabled, document.isReadable else { return }
        let url = document.url
        let language = document.language
        let text = document.text
        // Once a live server has published, one-shot results would duplicate (or worse,
        // contradict) semantic diagnostics. Until that first publish, the checker still runs.
        if liveCovered.contains(url), lspPublished.contains(url) { return }
        let sequence = (checkSequence[url] ?? 0) + 1
        checkSequence[url] = sequence
        /// Only the newest check for this file may publish; a slower older one is discarded.
        func isCurrent() -> Bool { checkSequence[url] == sequence }

        if language.id == "json" {
            results[url] = Self.checkJSON(text, url: url)
            notes[url] = nil
            lastRun[url] = Date()
            document.diagnostics = results[url] ?? []
            return
        }

        guard let (checker, executable) = Checkers.resolve(for: language) else {
            results[url] = []
            notes[url] = fallbackNotes[url] ?? Checkers.unavailableNote(for: language)
            document.diagnostics = []
            return
        }

        // The tool has to see the buffer, not the last saved version. Same basename, so its
        // messages and any `#include "…"` beside it still make sense — but in a directory of
        // its own, so concurrent checks (or two open files sharing a basename) never share a
        // scratch file one of them will delete.
        let copyDirectory = scratch.appendingPathComponent(UUID().uuidString)
        let copy = copyDirectory.appendingPathComponent(url.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: copyDirectory,
                                                    withIntermediateDirectories: true)
            try text.write(to: copy, atomically: true, encoding: .utf8)
        } catch {
            notes[url] = "Could not stage the file for checking: \(error.localizedDescription)"
            return
        }
        defer { try? FileManager.default.removeItem(at: copyDirectory) }

        running.insert(url)
        defer { running.remove(url) }

        let arguments = checker.arguments(copy)
        let outcome: ProcessRunner.Result
        do {
            outcome = try await ProcessRunner.run(executable, arguments,
                                                  cwd: url.deletingLastPathComponent(),
                                                  timeout: 20)
        } catch {
            if isCurrent() {
                notes[url] = "\(checker.name) could not be run: \(error.localizedDescription)"
            }
            return
        }
        guard !Task.isCancelled, isCurrent() else { return }

        if outcome.timedOut {
            notes[url] = "\(checker.name) did not finish within 20s, so nothing was checked."
            results[url] = []
            document.diagnostics = []
            return
        }

        // The tool saw the scratch copy; the user sees the real file.
        let found = checker.parse(outcome, copy)
            .map { diagnostic -> Diagnostic in
                var mapped = diagnostic
                mapped.file = url
                return mapped
            }
            .filter { $0.line >= 1 }
        results[url] = found
        if let fallback = fallbackNotes[url] {
            notes[url] = fallback
        } else {
            notes[url] = found.isEmpty && outcome.status != 0 && outcome.combined.isEmpty
                ? "\(checker.name) exited \(outcome.status) without saying why."
                : nil
        }
        lastRun[url] = Date()
        document.diagnostics = found
    }

    /// JSON is checked in process by a strict validator rather than `JSONSerialization`,
    /// which accepts input that every other JSON reader rejects. See `JSONValidator`.
    static func checkJSON(_ text: String, url: URL) -> [Diagnostic] {
        JSONValidator.validate(text, url: url)
    }

    /// Byte offset into a UTF-8 document to a 1-based line and column.
    static func position(ofByteOffset offset: Int, in text: String) -> (Int, Int) {
        var line = 1, column = 1, seen = 0
        for character in text {
            if seen >= offset { break }
            seen += character.utf8.count
            if character.isNewline { line += 1; column = 1 } else { column += 1 }
        }
        return (line, column)
    }

    /// Every problem across the open tabs, worst first — what the Problems pane shows when it
    /// is set to the whole project.
    func all(for documents: [CodeDocument]) -> [Diagnostic] {
        documents.flatMap { results[$0.url] ?? [] }
            .sorted {
                if $0.severity != $1.severity { return $0.severity < $1.severity }
                if $0.file.path != $1.file.path { return $0.file.path < $1.file.path }
                return $0.line < $1.line
            }
    }
}
