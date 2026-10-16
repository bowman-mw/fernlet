import Foundation
import DiaryStore
import FernletFoundation
import FernletPersistence

/// This device's AI day summaries, as one JSON file in Application Support — the place they live now
/// that the persisted score history never carries them (owner decision 2026-10-15; the spec excludes
/// `DaySummaryText` from sync).
///
/// DEVICE-LOCAL, by construction — the same stance as `FileDeviceHealthResidueStore`:
/// - Application Support is never synced (iCloud here is CloudKit Core Data, not a ubiquity
///   container), and the directory is marked `isExcludedFromBackup`, so the file cannot leave the
///   device through an iCloud or Finder device backup either. The flag sits on the DIRECTORY, which
///   an atomic rewrite of the file inside it does not replace.
/// - It is not part of `FernletSnapshot`, a `DayRecord`, the sealed backup, or the data export's file
///   set (the export reads the in-memory score rows, which carry this device's summaries), and it
///   lives in the app target — never in a module the walled `CloudKitSync` imports.
/// - Written with complete file protection (encrypted while the device is locked).
/// - Bounded (R3): at most ``maxDays`` day keys, the oldest evicted past it, and each summary capped
///   at `DiaryStore.maxDaySummaryCharacters` — on write AND on decode, so a hand-edited file cannot
///   grow either.
///
/// A separate file from the HealthKit residue cache on purpose: the HealthKit opt-out empties that
/// one, and it must not take the summaries with it. Cleared by "Reset everything" / "Delete
/// everything" (`FernletStore.resetAll`). An unreadable file (the device locked, a protection error)
/// is retried on the next access and never overwritten in the meantime; an undecodable one is
/// replaced (the summaries regenerate — the launch backfill writes one for every logged day missing
/// one).
@MainActor
final class FileDeviceDaySummaryStore: DeviceDaySummaryStoring {
    /// The production store — one instance per process, used by the launch-path `FernletStore`
    /// (`FernletStore.load`).
    static let production = FileDeviceDaySummaryStore(directory: defaultDirectory())

    /// R3: the most day keys the store holds — the score history's own bound, so every score row the
    /// diary keeps can carry its summary and none past it is kept.
    static let maxDays = DiaryStore.maxDailyScoreDays

    /// The file's name inside its directory.
    static let fileName = "day-summaries.json"

    /// On-disk shape: the summaries by day key and the one-time legacy-capture marker. Both keys are
    /// tolerant of absence; ``loadedPayload()`` normalizes what decodes (empty summaries dropped, each
    /// capped, the day count bounded).
    private struct Payload: Codable, Equatable {
        var legacySummariesCaptured = false
        var days: [String: String] = [:]

        init() {}

        /// The two persisted keys (the custom decoder needs them spelled out).
        private enum CodingKeys: String, CodingKey { case legacySummariesCaptured, days }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            legacySummariesCaptured = try container.decodeIfPresent(Bool.self, forKey: .legacySummariesCaptured) ?? false
            days = try container.decodeIfPresent([String: String].self, forKey: .days) ?? [:]
        }
    }

    private let directory: URL
    private let fileURL: URL
    /// The decoded file, or nil until a read succeeds (an unreadable file is retried, not assumed empty).
    private var payload: Payload?

    /// - Parameter directory: Where the file lives. Production passes ``defaultDirectory()``; tests
    ///   pass a unique temporary directory.
    init(directory: URL) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent(Self.fileName)
    }

    /// `<Application Support>/FernletDeviceDaySummaries`, falling back to the temporary directory when
    /// Application Support cannot be resolved (never in practice; the fallback is still device-local).
    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("FernletDeviceDaySummaries", isDirectory: true)
    }

    func allSummaries() -> [String: String]? {
        loadedPayload()?.days
    }

    func record(_ summary: String?, for dateKey: String) -> Bool {
        guard !dateKey.isEmpty else { return false }
        // Unreadable right now: refuse rather than overwrite a file holding every other day.
        guard var next = loadedPayload() else { return false }
        let normalized = Self.normalizedSummary(summary)
        guard next.days[dateKey] != normalized else { return true }
        next.days[dateKey] = normalized
        Self.evictOldest(&next.days)
        return persist(next)
    }

    func clearAll() -> Bool {
        // The session stops serving the summaries at once, whatever the disk says below.
        payload = Payload()
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return true }
        do {
            try FileManager.default.removeItem(at: fileURL)
            return true
        } catch {
            PersistenceFailureAudit.record("daySummaries.clear.failed", error: error)
            return false
        }
    }

    var legacySummariesCaptured: Bool {
        loadedPayload()?.legacySummariesCaptured ?? false
    }

    func markLegacySummariesCaptured() -> Bool {
        guard var next = loadedPayload() else { return false }
        guard !next.legacySummariesCaptured else { return true }
        next.legacySummariesCaptured = true
        return persist(next)
    }

    /// `summary` trimmed and capped at `DiaryStore.maxDaySummaryCharacters`, or nil for nil / empty
    /// text (an empty summary is stored as no entry at all).
    static func normalizedSummary(_ summary: String?) -> String? {
        guard let summary else { return nil }
        let trimmed = String(summary.trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(DiaryStore.maxDaySummaryCharacters))
        return trimmed.isEmpty ? nil : trimmed
    }

    /// `days` with every summary normalized, empty day keys and summaries dropped, and the oldest day
    /// keys evicted past ``maxDays`` — what a decoded file is held to.
    static func normalized(_ days: [String: String]) -> [String: String] {
        var kept: [String: String] = [:]
        // R2: bounded by the decoded dictionary.
        for (dateKey, summary) in days where !dateKey.isEmpty {
            kept[dateKey] = normalizedSummary(summary)
        }
        evictOldest(&kept)
        return kept
    }

    /// Drops the oldest day keys past ``maxDays`` (`yyyy-MM-dd` sorts chronologically). Shared with
    /// the in-memory store so both honor the same bound.
    static func evictOldest(_ days: inout [String: String]) {
        guard days.count > maxDays else { return }
        // R2: bounded by the overflow past `maxDays`.
        for key in days.keys.sorted().prefix(days.count - maxDays) {
            days[key] = nil
        }
    }

    /// The decoded file, reading it on first use. A missing file is an empty store; a file that
    /// cannot be READ (locked device, protection class) returns nil and is retried next time; a file
    /// that reads but cannot be DECODED is treated as empty and will be overwritten.
    private func loadedPayload() -> Payload? {
        if let payload { return payload }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            payload = Payload()
            return payload
        }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            PersistenceFailureAudit.record("daySummaries.read.failed", error: error)
            return nil
        }
        do {
            var decoded = try JSONDecoder().decode(Payload.self, from: data)
            decoded.days = Self.normalized(decoded.days)
            payload = decoded
        } catch {
            PersistenceFailureAudit.record("daySummaries.decode.failed", error: error)
            payload = Payload()
        }
        return payload
    }

    /// Adopts `next` as the live view, then writes it (directory re-created and re-excluded from
    /// backup first, since a clear or a fresh install may have removed it).
    private func persist(_ next: Payload) -> Bool {
        payload = next
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var excluded = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try excluded.setResourceValues(values)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(next).write(to: fileURL, options: [.atomic, .completeFileProtection])
            return true
        } catch {
            // The live view already holds `next`; the next successful write persists it.
            PersistenceFailureAudit.record("daySummaries.write.failed", error: error)
            return false
        }
    }
}

/// The in-memory ``DeviceDaySummaryStoring`` — the default for a `FernletStore` built through the
/// synchronous initializer (tests and previews), so a store that is not handed one can never share,
/// or wipe, another store's summaries (the same per-instance-sidecar lesson as
/// `InMemoryDeviceHealthResidueStore`). The launch path (`FernletStore.load`) always uses
/// ``FileDeviceDaySummaryStore/production``.
@MainActor
final class InMemoryDeviceDaySummaryStore: DeviceDaySummaryStoring {
    private var days: [String: String] = [:]
    private(set) var legacySummariesCaptured = false

    init() {}

    func allSummaries() -> [String: String]? { days }

    func record(_ summary: String?, for dateKey: String) -> Bool {
        guard !dateKey.isEmpty else { return false }
        days[dateKey] = FileDeviceDaySummaryStore.normalizedSummary(summary)
        FileDeviceDaySummaryStore.evictOldest(&days)
        return true
    }

    func clearAll() -> Bool {
        days = [:]
        legacySummariesCaptured = false
        return true
    }

    func markLegacySummariesCaptured() -> Bool {
        legacySummariesCaptured = true
        return true
    }
}
