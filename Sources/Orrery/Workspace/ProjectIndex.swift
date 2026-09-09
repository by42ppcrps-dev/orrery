import Foundation

/// The project's files, listed once and reused for quick-open and search. Walking a large
/// checkout takes long enough to matter, so it happens off the main thread and the result is
/// published when it lands.
@MainActor
@Observable
final class ProjectIndex {
    private(set) var files: [URL] = []
    private(set) var isScanning = false
    private(set) var truncated = false
    private(set) var scannedAt: Date?
    private var root: URL?
    private var task: Task<Void, Never>?

    /// Directories that are never worth indexing. Matches the file tree's list so the two views
    /// of the project agree.
    static let skippedDirectories: Set<String> = [
        ".git", ".svn", ".hg", "node_modules", ".build", "build", "DerivedData", "target",
        "dist", "out", ".next", ".nuxt", ".venv", "venv", "env", "__pycache__", ".mypy_cache",
        ".pytest_cache", ".ruff_cache", ".tox", "Pods", "Carthage", ".gradle", ".idea",
        ".vscode", ".terraform", "vendor", ".cache", ".parcel-cache", "coverage",
    ]

    /// A monorepo can hold hundreds of thousands of files. Past this the index says so rather
    /// than quietly listing a subset.
    static let fileLimit = 120_000

    func scan(root: URL) {
        self.root = root
        task?.cancel()
        files = []
        isScanning = true
        truncated = false
        let skipped = Self.skippedDirectories
        let limit = Self.fileLimit
        task = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) { () -> ([URL], Bool) in
                var results: [URL] = []
                var hitLimit = false
                let manager = FileManager.default
                guard let walker = manager.enumerator(
                    at: root, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
                    return ([], false)
                }
                // `for case let … in enumerator` is unavailable in an async context, so the
                // iteration is driven by hand.
                while let next = walker.nextObject() {
                    guard let url = next as? URL else { continue }
                    if Task.isCancelled { return (results, hitLimit) }
                    let values = try? url.resourceValues(forKeys: [.isDirectoryKey,
                                                                   .isRegularFileKey])
                    if values?.isDirectory == true {
                        if skipped.contains(url.lastPathComponent) { walker.skipDescendants() }
                        continue
                    }
                    guard values?.isRegularFile == true else { continue }
                    results.append(url)
                    if results.count >= limit { hitLimit = true; break }
                }
                return (results, hitLimit)
            }
            let found = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
            guard let self, !Task.isCancelled else { return }
            self.files = found.0
            self.truncated = found.1
            self.isScanning = false
            self.scannedAt = Date()
        }
    }

    func refresh() {
        if let root { scan(root: root) }
    }

    func cancel() { task?.cancel(); task = nil; isScanning = false }

    /// Path relative to the project root, which is what the user recognises.
    func relativePath(_ url: URL) -> String {
        guard let root else { return url.path }
        return PathHelper.relative(url, toAnyOf: PathHelper.prefixes(for: root))
    }

    func matches(_ query: String, limit: Int = 60) -> [FuzzyMatch] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return files.prefix(limit).map {
                FuzzyMatch(url: $0, display: relativePath($0), score: 0, highlights: [])
            }
        }
        var scored: [FuzzyMatch] = []
        scored.reserveCapacity(min(files.count, 4096))
        for url in files {
            let path = relativePath(url)
            guard let result = FuzzyMatcher.score(query: trimmed, candidate: path) else { continue }
            scored.append(FuzzyMatch(url: url, display: path, score: result.score,
                                     highlights: result.positions))
        }
        scored.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.display.count < $1.display.count
        }
        return Array(scored.prefix(limit))
    }
}

/// Turning an absolute path into a project-relative one is not string arithmetic on
/// `root.path`. A project under `/tmp` is really `/private/tmp`, a home directory can be
/// symlinked, and `FileManager`'s enumerator hands back the resolved form — so comparing the
/// two raw paths silently produces absolute paths everywhere in the UI.
enum PathHelper {
    /// Every spelling of `root` a file path might be expressed in, each with a trailing slash.
    static func prefixes(for root: URL) -> [String] {
        var seen: [String] = []
        for candidate in [root.path,
                          root.standardizedFileURL.path,
                          root.resolvingSymlinksInPath().path] {
            let withSlash = candidate.hasSuffix("/") ? candidate : candidate + "/"
            if !seen.contains(withSlash) { seen.append(withSlash) }
        }
        return seen
    }

    static func relative(_ url: URL, toAnyOf prefixes: [String]) -> String {
        for prefix in prefixes where url.path.hasPrefix(prefix) {
            return String(url.path.dropFirst(prefix.count))
        }
        // Only pay for a syscall when the cheap comparison did not land.
        let resolved = url.resolvingSymlinksInPath().path
        for prefix in prefixes where resolved.hasPrefix(prefix) {
            return String(resolved.dropFirst(prefix.count))
        }
        return url.path
    }
}

struct FuzzyMatch: Identifiable, Hashable {
    var id: String { url.path }
    let url: URL
    let display: String
    let score: Int
    /// Character offsets in `display` that matched, so the UI can bold them.
    let highlights: [Int]
}

/// Subsequence matching with the scoring that makes a file picker feel right: consecutive runs,
/// word and path boundaries, and the basename all count for more than a scattered match.
enum FuzzyMatcher {
    struct Result { let score: Int; let positions: [Int] }

    static func score(query: String, candidate: String) -> Result? {
        let queryChars = Array(query.lowercased())
        let queryOriginal = Array(query)
        let candidateChars = Array(candidate)
        let lowered = Array(candidate.lowercased())
        guard !queryChars.isEmpty, queryChars.count <= candidateChars.count,
              lowered.count == candidateChars.count else { return nil }

        // A quick subsequence test first: most candidates fail, and failing cheaply matters when
        // the index holds tens of thousands of paths.
        var probe = 0
        for character in lowered where probe < queryChars.count && character == queryChars[probe] {
            probe += 1
        }
        guard probe == queryChars.count else { return nil }

        // Greedy forward pass, then slide each match as far right as it can go while staying a
        // valid subsequence. That prefers matches in the basename over ones in parent folders.
        var positions: [Int] = []
        positions.reserveCapacity(queryChars.count)
        var index = 0
        for character in queryChars {
            while index < lowered.count, lowered[index] != character { index += 1 }
            guard index < lowered.count else { return nil }
            positions.append(index)
            index += 1
        }
        var cursor = candidateChars.count
        for slot in stride(from: positions.count - 1, through: 0, by: -1) {
            var best = positions[slot]
            var forward = best + 1
            while forward < cursor {
                if lowered[forward] == queryChars[slot] { best = forward }
                forward += 1
            }
            positions[slot] = best
            cursor = best
        }

        var total = 0
        var previous = -2
        let separatorIndexes = Set(candidateChars.enumerated()
            .filter { $0.element == "/" }.map(\.offset))
        let basenameStart = (separatorIndexes.max() ?? -1) + 1

        for (order, position) in positions.enumerated() {
            var points = 12
            if position == previous + 1 { points += 14 }               // consecutive run
            if position >= basenameStart { points += 10 }              // in the filename itself
            if position == 0 || separatorIndexes.contains(position - 1) {
                points += 12
            } else {
                let before = candidateChars[position - 1]
                let here = candidateChars[position]
                if before == "_" || before == "-" || before == "." { points += 8 }
                if before.isLowercase && here.isUppercase { points += 8 }   // camelCase boundary
            }
            if order < queryOriginal.count, candidateChars[position] == queryOriginal[order] {
                points += 3                                            // exact case
            }
            total += points
            previous = position
        }
        // Shorter paths win ties; a deep path is rarely what someone typed three letters for.
        total -= candidateChars.count / 8
        total -= (positions.first ?? 0) / 4
        return Result(score: total, positions: positions)
    }
}
