import Foundation
import CryptoKit

struct SearchOptions: Equatable, Sendable {
    var caseSensitive = false
    var wholeWord = false
    var isRegex = false
    /// Comma-separated globs, e.g. `*.swift, Sources/**`. Empty means every indexed file.
    var include = ""
    var exclude = ""
}

struct SearchHit: Identifiable, Hashable, Sendable {
    var id: String { "\(file.path):\(lineNumber):\(column):\(range.location)" }
    let file: URL
    let lineNumber: Int
    let column: Int
    /// UTF-16 range of the match within the whole file, so a replacement lands exactly.
    let range: NSRange
    let preview: String
    /// Offset of the match inside `preview`, for highlighting.
    let previewRange: NSRange
}

struct SearchFileResult: Identifiable, Hashable, Sendable {
    var id: String { file.path }
    let file: URL
    let relativePath: String
    var hits: [SearchHit]
    var digest: Data = Data()
}

/// Project-wide search, run in process.
///
/// ripgrep is not installed here and shelling out to `grep` gives no reliable column offsets,
/// which makes "jump to the match" and "replace in files" unsafe. Doing the scan directly costs
/// a little speed and buys exact ranges, real regex options, and cancellation.
@MainActor
@Observable
final class ProjectSearch {
    var queryDraft = ""
    var replacementDraft = ""
    var optionsDraft = SearchOptions()
    var showsReplacement = false
    var showsFilters = false
    private(set) var results: [SearchFileResult] = []
    private(set) var isSearching = false
    private(set) var totalHits = 0
    private(set) var filesScanned = 0
    private(set) var filesSkipped = 0
    private(set) var note: String?
    private(set) var elapsed: TimeInterval = 0
    private var task: Task<Void, Never>?
    private var completedQuery: String?
    private var completedOptions: SearchOptions?
    private var searchRoot: URL?
    private var wasTruncated = false
    private struct Replacement {
        let path: String
        let original: Data
        let updated: Data
    }
    private var replacementJournal: [Replacement] = []
    private var replacementRoot: URL?
    var canUndoReplacement: Bool { !replacementJournal.isEmpty }
    struct ReplaceFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Files past this are skipped: a search result inside a 50 MB blob is not useful and
    /// reading it stalls the scan.
    nonisolated static let fileSizeLimit = 4_000_000
    /// Stop after this many matches so a one-letter query cannot fill memory.
    nonisolated static let hitLimit = 5_000

    func cancel() {
        task?.cancel()
        task = nil
        isSearching = false
    }

    func clear() {
        cancel()
        results = []
        totalHits = 0
        filesScanned = 0
        filesSkipped = 0
        note = nil
        completedQuery = nil
        completedOptions = nil
        replacementJournal = []
        replacementRoot = nil
    }

    func run(query: String, options: SearchOptions, files: [URL], root: URL) {
        cancel()
        completedQuery = nil
        completedOptions = nil
        let trimmed = query
        guard !trimmed.isEmpty else { clear(); return }

        guard let expression = Self.makeExpression(trimmed, options) else {
            results = []
            totalHits = 0
            note = "Not a valid regular expression."
            return
        }

        isSearching = true
        note = nil
        results = []
        totalHits = 0
        filesScanned = 0
        filesSkipped = 0
        let started = Date()

        let includeFilters = Self.globs(options.include)
        let excludeFilters = Self.globs(options.exclude)
        let rootPrefixes = PathHelper.prefixes(for: root)
        let candidates = files.filter { url in
            let relative = PathHelper.relative(url, toAnyOf: rootPrefixes)
            if !includeFilters.isEmpty,
               !includeFilters.contains(where: { Self.matches(glob: $0, path: relative) }) {
                return false
            }
            if !excludeFilters.isEmpty,
               excludeFilters.contains(where: { Self.matches(glob: $0, path: relative) }) {
                return false
            }
            return true
        }

        task = Task { [weak self] in
            let outcome = await Self.scan(candidates, expression: expression,
                                          rootPrefixes: rootPrefixes, root: root)
            guard let self, !Task.isCancelled else { return }
            self.searchRoot = root
            self.completedQuery = query
            self.completedOptions = options
            self.wasTruncated = outcome.truncated
            self.results = outcome.results
            self.totalHits = outcome.results.reduce(0) { $0 + $1.hits.count }
            self.filesScanned = outcome.scanned
            self.filesSkipped = outcome.skipped
            self.elapsed = -started.timeIntervalSinceNow
            self.isSearching = false
            if outcome.truncated {
                self.note = "Stopped at \(Self.hitLimit) matches — narrow the query."
            } else if candidates.isEmpty {
                self.note = "No files matched the include/exclude filters."
            } else if self.results.isEmpty {
                self.note = "No matches in \(outcome.scanned) files."
                    + (outcome.skipped > 0 ? " \(outcome.skipped) files could not be searched (binary, oversized or unavailable)." : "")
            }
        }
    }

    private struct Outcome: Sendable {
        var results: [SearchFileResult]
        var scanned: Int
        var skipped: Int
        var truncated: Bool
    }

    private nonisolated static func scan(_ files: [URL], expression: NSRegularExpression,
                                         rootPrefixes: [String], root: URL) async -> Outcome {
        let limit = hitLimit
        let sizeLimit = fileSizeLimit
        let worker = Task.detached(priority: .userInitiated) { () -> Outcome in
            var collected: [SearchFileResult] = []
            var scanned = 0, skipped = 0, hits = 0
            var truncated = false

            for url in files {
                if Task.isCancelled { break }
                let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
                if let size = attributes?[.size] as? Int, size > sizeLimit { skipped += 1; continue }
                guard let data = try? WorkspaceFileAccess(root: root).read(url.path) else { skipped += 1; continue }
                // A NUL byte early on is the standard, cheap binary test.
                if data.prefix(8_192).contains(0) { skipped += 1; continue }
                guard let text = String(data: data, encoding: .utf8) else { skipped += 1; continue }
                scanned += 1

                let content = text as NSString
                var matches: [NSTextCheckingResult] = []
                expression.enumerateMatches(in: text, range: NSRange(location: 0, length: content.length)) { match, _, stop in
                    if Task.isCancelled || matches.count >= limit - hits {
                        stop.pointee = true
                        return
                    }
                    if let match { matches.append(match) }
                }
                guard !matches.isEmpty else { continue }

                var fileHits: [SearchHit] = []
                var lineNumber = 1
                var lineStart = 0
                var cursor = 0
                for match in matches {
                    // Walk forward to the match, counting lines as we go: one pass per file
                    // rather than one scan per match.
                    while cursor < match.range.location, cursor < content.length {
                        if content.character(at: cursor) == 10 {
                            lineNumber += 1
                            lineStart = cursor + 1
                        }
                        cursor += 1
                    }
                    var start = 0, end = 0, contentsEnd = 0
                    content.getLineStart(&start, end: &end, contentsEnd: &contentsEnd,
                                         for: NSRange(location: match.range.location, length: 0))
                    let previewRange = NSRange(location: start, length: max(0, contentsEnd - start))
                    let preview = content.substring(with: previewRange)
                    fileHits.append(SearchHit(
                        file: url, lineNumber: lineNumber,
                        column: match.range.location - lineStart + 1,
                        range: match.range, preview: preview,
                        previewRange: NSRange(location: match.range.location - start,
                                              length: match.range.length)))
                    hits += 1
                    if hits >= limit { truncated = true; break }
                }
                if !fileHits.isEmpty {
                    let relative = PathHelper.relative(url, toAnyOf: rootPrefixes)
                    collected.append(SearchFileResult(file: url, relativePath: relative,
                                                      hits: fileHits, digest: Data(SHA256.hash(data: data))))
                }
                if truncated { break }
            }
            collected.sort { $0.relativePath < $1.relativePath }
            return Outcome(results: collected, scanned: scanned, skipped: skipped,
                           truncated: truncated)
        }
        return await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
    }

    /// Rewrite every current hit. Returns the number of files changed, or throws on the first
    /// write that fails so a half-applied replacement is visible rather than silent.
    @discardableResult
    func replaceAll(with replacement: String, query: String,
                    options: SearchOptions, protecting dirtyFiles: [URL] = []) throws -> (files: Int, hits: Int) {
        guard !isSearching, query == completedQuery, options == completedOptions,
              let root = searchRoot, let expression = Self.makeExpression(query, options) else {
            throw ReplaceFailure(message: "Search again before replacing: the query or filters changed.")
        }
        guard !wasTruncated else {
            throw ReplaceFailure(message: "These search results are truncated. Narrow the search before replacing.")
        }
        let protected = Set(dirtyFiles.map { $0.resolvingSymlinksInPath().standardizedFileURL.path })
        let access = WorkspaceFileAccess(root: root)
        var prepared: [Replacement] = []
        var changedHits = 0, bytes = 0
        let template = options.isRegex ? replacement : NSRegularExpression.escapedTemplate(for: replacement)
        // Preflight every file before writing anything. A stale preview must never authorize
        // replacements in text the user has not seen, or overwrite an unsaved editor buffer.
        for result in results {
            guard !protected.contains(result.file.resolvingSymlinksInPath().standardizedFileURL.path) else {
                throw ReplaceFailure(message: "Save or close the unsaved tab \(result.relativePath) before replacing.")
            }
            let data = try access.read(result.file.path)
            guard Data(SHA256.hash(data: data)) == result.digest,
                  let original = String(data: data, encoding: .utf8) else {
                throw ReplaceFailure(message: "\(result.relativePath) changed since the search. Search again.")
            }
            let updated = Data(expression.stringByReplacingMatches(in: original,
                range: NSRange(location: 0, length: (original as NSString).length), withTemplate: template).utf8)
            guard updated != data else { continue }
            bytes += data.count + updated.count
            guard bytes <= 32_000_000, updated.count <= Self.fileSizeLimit else {
                throw ReplaceFailure(message: "Replacement exceeds the safety limit. Narrow the search.")
            }
            prepared.append(Replacement(path: result.file.path, original: data, updated: updated))
            changedHits += result.hits.count
        }
        replacementJournal = []
        replacementRoot = root
        do {
            for item in prepared {
                try access.write(item.updated, to: item.path, expected: item.original)
                replacementJournal.append(item)
            }
        } catch {
            throw ReplaceFailure(message: "Replacement stopped after \(replacementJournal.count) files: \(error.localizedDescription) Use Undo Replace to restore completed writes.")
        }
        completedQuery = nil // the preview no longer matches disk
        return (prepared.count, changedHits)
    }

    @discardableResult
    func undoLastReplacement(protecting dirtyFiles: [URL] = []) throws -> Int {
        guard let root = replacementRoot else { return 0 }
        let access = WorkspaceFileAccess(root: root)
        let protected = Set(dirtyFiles.map { $0.resolvingSymlinksInPath().standardizedFileURL.path })
        for item in replacementJournal {
            guard !protected.contains(URL(fileURLWithPath: item.path).resolvingSymlinksInPath().path),
                  try access.read(item.path) == item.updated else {
                throw ReplaceFailure(message: "A replaced file has newer edits. Undo was refused to protect them.")
            }
        }
        let count = replacementJournal.count
        while let item = replacementJournal.last {
            try access.write(item.original, to: item.path, expected: item.updated)
            replacementJournal.removeLast()
        }
        return count
    }

    static func makeExpression(_ query: String, _ options: SearchOptions) -> NSRegularExpression? {
        var pattern = options.isRegex ? query : NSRegularExpression.escapedPattern(for: query)
        if options.wholeWord { pattern = "\\b(?:\(pattern))\\b" }
        var flags: NSRegularExpression.Options = []
        if !options.caseSensitive { flags.insert(.caseInsensitive) }
        return try? NSRegularExpression(pattern: pattern, options: flags)
    }

    static func globs(_ text: String) -> [String] {
        text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// `*` matches within a path segment, `**` across segments, `?` one character. A pattern
    /// with no slash is matched against the filename alone, which is what people expect from
    /// typing `*.swift`.
    static func matches(glob: String, path: String) -> Bool {
        let target = glob.contains("/") ? path : (path as NSString).lastPathComponent
        var pattern = "^"
        var index = glob.startIndex
        while index < glob.endIndex {
            let character = glob[index]
            switch character {
            case "*":
                let next = glob.index(after: index)
                if next < glob.endIndex, glob[next] == "*" {
                    index = glob.index(after: next)
                    if index < glob.endIndex, glob[index] == "/" {
                        pattern += "(?:.*/)?"
                        index = glob.index(after: index)
                    } else { pattern += ".*" }
                    continue
                }
                pattern += "[^/]*"
            case "?": pattern += "[^/]"
            case ".", "+", "(", ")", "[", "]", "{", "}", "^", "$", "|", "\\":
                pattern += "\\" + String(character)
            default: pattern += String(character)
            }
            index = glob.index(after: index)
        }
        pattern += "$"
        guard let expression = try? NSRegularExpression(pattern: pattern, options: []) else {
            return false
        }
        let range = NSRange(location: 0, length: (target as NSString).length)
        return expression.firstMatch(in: target, options: [], range: range) != nil
    }
}
