import Foundation
import Darwin

struct UsageDay: Codable, Equatable {
    var date: String
    var turns: Int
    var costUSD: Double
}

struct ProviderUsage: Codable, Equatable {
    var turns = 0
    var costUSD = 0.0
    var unpricedTurns = 0
    var lastQuota: String?
    var lastQuotaAt: Date?
    var days: [UsageDay] = []
}

/// Local, owner-only record of what each provider was asked to do and what it reported
/// costing, plus the last quota or rate-limit message it sent. Nothing is sent anywhere.
@MainActor @Observable
final class UsageLedger {
    static let shared = UsageLedger(fileURL: AppModel.persistsPreferences
        ? PrivateProjectFile.defaultDirectory("Usage").appendingPathComponent("usage.json")
        : URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("orrery-headless-usage-\(ProcessInfo.processInfo.processIdentifier).json"))
    static let dayLimit = 90
    private(set) var usage: [Provider: ProviderUsage] = [:]
    private(set) var lastError: String?
    let fileURL: URL
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init(fileURL: URL) {
        self.fileURL = fileURL
        load()
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    func record(turn provider: Provider, costUSD: Double?, on date: Date = Date()) {
        var entry = usage[provider] ?? ProviderUsage()
        entry.turns += 1
        if let costUSD, costUSD > 0 { entry.costUSD += costUSD } else { entry.unpricedTurns += 1 }
        let day = Self.dayFormatter.string(from: date)
        if let index = entry.days.firstIndex(where: { $0.date == day }) {
            entry.days[index].turns += 1
            entry.days[index].costUSD += max(0, costUSD ?? 0)
        } else {
            entry.days.append(UsageDay(date: day, turns: 1, costUSD: max(0, costUSD ?? 0)))
            if entry.days.count > Self.dayLimit { entry.days.removeFirst(entry.days.count - Self.dayLimit) }
        }
        usage[provider] = entry
        scheduleSave()
    }

    func record(quota provider: Provider, text: String, on date: Date = Date()) {
        var entry = usage[provider] ?? ProviderUsage()
        entry.lastQuota = String(text.prefix(300))
        entry.lastQuotaAt = date
        usage[provider] = entry
        scheduleSave()
    }

    /// One line for the Account tab: today, the last seven days, all time, and unpriced turns.
    func summary(for provider: Provider, now: Date = Date()) -> String {
        guard let entry = usage[provider], entry.turns > 0 else { return "No turns recorded yet." }
        let today = Self.dayFormatter.string(from: now)
        let week = (0..<7).compactMap { Calendar(identifier: .iso8601).date(byAdding: .day, value: -$0, to: now) }.map(Self.dayFormatter.string)
        let todayCost = entry.days.first { $0.date == today }?.costUSD ?? 0
        let weekCost = entry.days.filter { week.contains($0.date) }.reduce(0) { $0 + $1.costUSD }
        var parts = [String(format: "Today $%.4f", todayCost), String(format: "7 days $%.4f", weekCost),
                     String(format: "all time $%.4f over %d turn%@", entry.costUSD, entry.turns, entry.turns == 1 ? "" : "s")]
        if entry.unpricedTurns > 0 { parts.append("\(entry.unpricedTurns) reported no cost") }
        return parts.joined(separator: " · ")
    }

    private func load() {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            guard (attributes[.size] as? NSNumber)?.intValue ?? 0 <= 4 * 1024 * 1024 else {
                lastError = "The usage record is unexpectedly large and was not loaded."; return
            }
            let data = try Data(contentsOf: fileURL)
            usage = try JSONDecoder().decode([Provider: ProviderUsage].self, from: data)
        } catch CocoaError.fileReadNoSuchFile { return }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return }
        catch { if FileManager.default.fileExists(atPath: fileURL.path) { lastError = "The usage record could not be read: \(error.localizedDescription)" } }
    }

    private func scheduleSave() {
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let self else { return }
            self.saveTask = nil
            self.saveNow()
        }
    }

    @discardableResult
    func saveNow() -> Bool {
        saveTask?.cancel(); saveTask = nil
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(usage)
            let temporary = directory.appendingPathComponent(".usage-\(UUID().uuidString)")
            try data.write(to: temporary, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporary)
            lastError = nil
            return true
        } catch {
            lastError = "The usage record could not be saved: \(error.localizedDescription)"
            return false
        }
    }
}
