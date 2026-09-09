import AppKit
import Observation
import CryptoKit

/// Recovery stores the original disk identity alongside unsaved text. Restoring must retain
/// that baseline rather than treating a newer on-disk version as safe to overwrite.
struct DocumentRecoveryRecord: Codable {
    var path: String
    var text: String?
    var diskStamp: Date?
    var diskDigest: Data?
    var diskTarget: String?
    var hasBOM: Bool = false
    var selectionLocation: Int = 0
    var selectionLength: Int = 0
    var scrollOffset: Double = 0
}

/// One open file. Owns its text storage, its highlighting, and everything the editor and the
/// tab bar need to know about it. Text lives in the storage rather than in an observable
/// `String`, so typing does not push the whole file through SwiftUI on every keystroke.
@MainActor
@Observable
final class CodeDocument: Identifiable {
    let id = UUID()
    private(set) var url: URL
    private(set) var language: Language

    @ObservationIgnored let storage = NSTextStorage()
    @ObservationIgnored let decorator: SyntaxDecorator

    /// False when the file is not UTF-8 text, or is too big to edit here. Saving is refused.
    private(set) var isReadable = true
    private(set) var loadNote: String?
    var isDirty = false
    var changedOnDisk = false
    private(set) var diskStamp: Date?
    private var diskDigest: Data?
    private var diskTarget: URL?
    private var hasBOM = false
    @ObservationIgnored private var recoveryRoot: URL?
    var diagnostics: [Diagnostic] = [] {
        didSet { decorator.diagnostics = diagnostics }
    }
    /// Where the caret was when the tab was last active, so switching back returns you there.
    var selection = NSRange(location: 0, length: 0)
    /// Set while the document itself is replacing the text (load, reload), so those writes are
    /// not mistaken for the user's edits.
    @ObservationIgnored private var isLoading = false
    @ObservationIgnored var onRecoveryChange: (() -> Void)?
    var scrollOffset: CGFloat = 0

    var name: String { url.lastPathComponent }
    var text: String { storage.string }
    var lineCount: Int { decorator.lineStartOffsets.count }

    /// 1-based line of the caret, matching Diagnostic / LSP.
    var caretLine: Int { decorator.lineNumber(at: selection.location) }
    /// 1-based column of the caret on `caretLine`.
    var caretColumn: Int {
        let start = decorator.range(ofLine: caretLine)?.location ?? 0
        return max(1, selection.location - start + 1)
    }

    /// SwiftUI's text editor and this one both degrade badly past a couple of megabytes, and
    /// reading a huge file into memory to display it is wasteful anyway.
    static let sizeLimit = 4_000_000

    init(url: URL, recoveryRoot: URL? = nil) {
        let detected = Languages.forFile(url)
        self.url = url
        self.language = detected
        self.decorator = SyntaxDecorator(language: detected)
        self.recoveryRoot = recoveryRoot
        load()
        decorator.attach(to: storage)
        if let refined = Languages.refine(detected, url: url, content: storage.string) { setLanguage(refined) }
        decorator.onCharactersChanged = { [weak self] in self?.noteEdit() }
    }

    /// For tests and scratch buffers.
    init(name: String, language: Language, text: String) {
        self.url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
        self.language = language
        self.decorator = SyntaxDecorator(language: language)
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: text)
        decorator.attach(to: storage)
        decorator.onCharactersChanged = { [weak self] in self?.noteEdit() }
    }

    private func noteEdit() {
        guard !isLoading else { return }
        isDirty = true
        onRecoveryChange?()
    }

    private func load() {
        diskTarget = url.resolvingSymlinksInPath().standardizedFileURL
        diskDigest = nil
        hasBOM = false
        let target = diskTarget ?? url
        let attributes = try? FileManager.default.attributesOfItem(atPath: target.path)
        diskStamp = Self.modificationDate(of: url)
        let size = (attributes?[.size] as? Int) ?? 0
        if size > Self.sizeLimit {
            isReadable = false
            loadNote = String(format: "%.1f MB — too large to edit here. Ask an agent to change "
                              + "it, or open it in another editor.", Double(size) / 1_000_000)
            setText(loadNote ?? "")
            return
        }
        guard let data = try? WorkspaceFileAccess(root: recoveryRoot ?? target.deletingLastPathComponent()).read(target.path) else {
            isReadable = false
            loadNote = "Could not be read."
            setText(loadNote ?? "")
            return
        }
        diskDigest = Data(SHA256.hash(data: data))
        // A NUL byte early in the file is the standard, cheap binary test. `String(contentsOf:)`
        // happily decodes NUL as valid UTF-8, so without this a `.bin` opens as editable text
        // and a save would rewrite it as a lossy string.
        if data.prefix(8_192).contains(0) {
            isReadable = false
            loadNote = Self.encodingNote(for: data)
            setText(loadNote ?? "")
            return
        }
        var payload = data
        // Strip a UTF-8 BOM so it does not show as a stray character at the top of the file.
        if payload.starts(with: [0xEF, 0xBB, 0xBF]) {
            hasBOM = true
            payload = payload.dropFirst(3)
        }
        guard let text = String(data: payload, encoding: .utf8) else {
            isReadable = false
            loadNote = Self.encodingNote(for: data)
            setText(loadNote ?? "")
            return
        }
        isReadable = true
        loadNote = nil
        setText(text)
    }

    private func setText(_ text: String) {
        isLoading = true
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: text)
        storage.endEditing()
        isLoading = false
    }

    /// Name what the file actually is, rather than saying "not text" about everything.
    private static func encodingNote(for data: Data) -> String {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return "UTF-16 text — this editor only writes UTF-8, so it is shown read-only."
        }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "A PNG image, not text." }
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "A JPEG image, not text." }
        if data.starts(with: [0x25, 0x50, 0x44, 0x46]) { return "A PDF, not text." }
        if data.starts(with: [0x50, 0x4B, 0x03, 0x04]) { return "A zip archive, not text." }
        if data.starts(with: [0xCF, 0xFA, 0xED, 0xFE]) { return "A Mach-O binary, not text." }
        return "Binary data — shown as a placeholder and not saveable from here."
    }

    func replaceAll(with text: String) {
        setText(text)
        isDirty = true
        onRecoveryChange?()
    }

    func setLanguage(_ language: Language) {
        self.language = language
        decorator.setLanguage(language)
    }

    /// Re-read from disk, discarding local edits.
    func reload() {
        let previousSelection = selection
        load()
        decorator.rehighlightAll()
        isDirty = false
        changedOnDisk = false
        selection = NSRange(location: min(previousSelection.location, storage.length), length: 0)
        onRecoveryChange?()
    }

    enum SaveResult { case saved, refusedUnreadable, conflicted, failed(String) }

    /// Never overwrites a newer version on disk. An agent editing the same file mid-turn is the
    /// normal case here, not an edge case.
    @discardableResult
    func save() -> SaveResult {
        guard isReadable else { return .refusedUnreadable }
        if diskHasChanged() {
            changedOnDisk = true
            return .conflicted
        }
        do {
            try writeBuffer()
            diskStamp = Self.modificationDate(of: url)
            isDirty = false
            changedOnDisk = false
            onRecoveryChange?()
            return .saved
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Overwrite regardless — only ever from an explicit "save anyway" in the conflict banner.
    @discardableResult
    func forceSave() -> SaveResult {
        guard isReadable else { return .refusedUnreadable }
        do {
            // Never follow a link that was retargeted since opening, even on Save Anyway.
            guard diskTarget == url.resolvingSymlinksInPath().standardizedFileURL else {
                return .failed("The file now points to a different location. Reopen it before saving.")
            }
            try writeBuffer()
            diskStamp = Self.modificationDate(of: url)
            isDirty = false
            changedOnDisk = false
            onRecoveryChange?()
            return .saved
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    func checkDisk() {
        changedOnDisk = diskHasChanged()
    }

    private func diskHasChanged() -> Bool {
        guard diskTarget == url.resolvingSymlinksInPath().standardizedFileURL else { return true }
        guard Self.modificationDate(of: url) == diskStamp else { return true }
        guard let digest = diskDigest else { return false }
        let target = diskTarget ?? url
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: target.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? Int ?? Int.max) <= Self.sizeLimit,
              let data = try? WorkspaceFileAccess(root: recoveryRoot ?? target.deletingLastPathComponent()).read(target.path) else { return true }
        return Data(SHA256.hash(data: data)) != digest
    }

    private func writeBuffer() throws {
        let target = diskTarget ?? url
        let data = (hasBOM ? Data([0xEF, 0xBB, 0xBF]) : Data()) + Data(storage.string.utf8)
        try WorkspaceFileAccess(root: recoveryRoot ?? target.deletingLastPathComponent()).write(data, to: target.path)
        diskDigest = Data(SHA256.hash(data: data))
        diskTarget = target.resolvingSymlinksInPath().standardizedFileURL
    }

    /// Read straight from the filesystem. `URL.resourceValues` caches on the URL instance, so
    /// re-reading the same URL returns the value from when the file was opened.
    static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    func rename(to newURL: URL) {
        url = newURL
        setLanguage(Languages.forFile(newURL))
        diskStamp = Self.modificationDate(of: newURL)
        diskTarget = newURL.resolvingSymlinksInPath().standardizedFileURL
        onRecoveryChange?()
    }

    func recoveryRecord(path: String, includeEdits: Bool) -> DocumentRecoveryRecord {
        DocumentRecoveryRecord(path: path, text: isDirty && includeEdits ? text : nil,
            diskStamp: diskStamp, diskDigest: diskDigest, diskTarget: diskTarget?.path,
            hasBOM: hasBOM, selectionLocation: selection.location,
            selectionLength: selection.length, scrollOffset: Double(scrollOffset))
    }

    /// Called only after DocumentStore validates the project-relative path and baseline.
    func restoreRecovery(_ record: DocumentRecoveryRecord) {
        if let text = record.text {
            setText(text)
            isReadable = true
            loadNote = nil
            diskStamp = record.diskStamp
            diskDigest = record.diskDigest
            diskTarget = record.diskTarget.map { URL(fileURLWithPath: $0) }
            hasBOM = record.hasBOM
            isDirty = true
            changedOnDisk = diskHasChanged()
        }
        let location = min(max(0, record.selectionLocation), storage.length)
        selection = NSRange(location: location,
                            length: min(max(0, record.selectionLength), storage.length - location))
        scrollOffset = record.scrollOffset.isFinite ? max(0, record.scrollOffset) : 0
        decorator.rehighlightAll()
    }
}
