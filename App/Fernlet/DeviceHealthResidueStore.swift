import Foundation
import FernletFoundation
import FernletPersistence

/// This device's HealthKit residue cache, as one JSON file in Application Support — the place the
/// HealthKit readings live now that no synced write may carry them (owner decision 2026-09-23,
/// App Review 5.1.3(ii)).
///
/// DEVICE-LOCAL, by construction — the same stance as `StressService`'s HRV/RHR sidecar and
/// `FileAIAuditLogStore`:
/// - Application Support is never synced (iCloud here is CloudKit Core Data, not a ubiquity
///   container), and the directory is marked `isExcludedFromBackup`, so the file cannot leave the
///   device through an iCloud or Finder device backup either. The flag sits on the DIRECTORY, which
///   an atomic rewrite of the file inside it does not replace.
/// - It is not part of `FernletSnapshot`, a `DayRecord`, the sealed backup, or the data export's
///   file set, and it lives in the app target — never in a module the walled `CloudKitSync` imports.
/// - Written with complete file protection (encrypted while the device is locked), like the stores
///   the same values used to live in.
/// - Bounded (R3): at most ``maxDays`` day keys; the oldest are evicted past it, and each day's
///   imported workouts are capped by `DeviceHealthResidue`.
/// - Since 2026-09-23 (the body-profile follow-up) it also holds the ONE `DeviceHealthBodyProfile`
///   this device imported from HealthKit — the age, sex, height and weight a Health import used to
///   write into the synced `settings.userProfile`.
///
/// Cleared by "Reset everything" / "Delete everything" (`FernletStore.resetAll`) and by the
/// HealthKit opt-out (`CoreDataHealthKitCacheCleaner`). Both reach the SAME instance in production
/// — ``production`` — so a clear through either is seen by the other and the in-memory view can
/// never write a cleared file back. An unreadable file (the device locked, a protection error) is
/// retried on the next access and never overwritten in the meantime; an undecodable one is replaced
/// (it is a cache of values HealthKit still holds).
@MainActor
final class FileDeviceHealthResidueStore: DeviceHealthResidueStoring {
    /// The production cache — one instance per process, shared by the launch-path `FernletStore`
    /// (`FernletStore.load`) and the HealthKit opt-out cleaner.
    static let production = FileDeviceHealthResidueStore(directory: defaultDirectory())

    /// R3: the most day keys the cache holds. A little over a year, matching the derived-table
    /// window; older days keep their user-authored rows and simply lose their HealthKit context on
    /// this device.
    static let maxDays = 400

    /// The cache file's name inside its directory.
    static let fileName = "health-residue.json"

    /// On-disk shape: the residues, this device's HealthKit body-profile import, and the one-time
    /// scrub marker. `bodyProfile` is optional, so a file written before it existed decodes unchanged.
    private struct Payload: Codable, Equatable {
        var legacySyncedRowsScrubbed = false
        var days: [String: DeviceHealthResidue] = [:]
        var bodyProfile: DeviceHealthBodyProfile?
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

    /// `<Application Support>/FernletDeviceHealth`, falling back to the temporary directory when
    /// Application Support cannot be resolved (never in practice; the fallback is still device-local).
    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("FernletDeviceHealth", isDirectory: true)
    }

    func residue(for dateKey: String) -> DeviceHealthResidue? {
        loadedPayload()?.days[dateKey]
    }

    func allResidues() -> [String: DeviceHealthResidue] {
        loadedPayload()?.days ?? [:]
    }

    func record(_ residue: DeviceHealthResidue?, for dateKey: String) -> Bool {
        guard !dateKey.isEmpty else { return false }
        // Unreadable right now: refuse rather than overwrite a file holding every other day.
        guard var next = loadedPayload() else { return false }
        let normalized = (residue?.isEmpty ?? true) ? nil : residue
        guard next.days[dateKey] != normalized else { return true }
        next.days[dateKey] = normalized
        Self.evictOldest(&next.days)
        return persist(next)
    }

    var importedBodyProfile: DeviceHealthBodyProfile? {
        loadedPayload()?.bodyProfile
    }

    func recordImportedBodyProfile(_ profile: DeviceHealthBodyProfile?) -> Bool {
        // Unreadable right now: refuse rather than overwrite a file holding every day's residue.
        guard var next = loadedPayload() else { return false }
        let normalized = (profile?.isEmpty ?? true) ? nil : profile
        guard next.bodyProfile != normalized else { return true }
        next.bodyProfile = normalized
        return persist(next)
    }

    func clearAll() -> Bool {
        // The session stops serving the residue at once, whatever the disk says below.
        payload = Payload()
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return true }
        do {
            try FileManager.default.removeItem(at: fileURL)
            return true
        } catch {
            PersistenceFailureAudit.record("healthResidue.clear.failed", error: error)
            return false
        }
    }

    var legacySyncedRowsScrubbed: Bool {
        loadedPayload()?.legacySyncedRowsScrubbed ?? false
    }

    func markLegacySyncedRowsScrubbed() -> Bool {
        guard var next = loadedPayload() else { return false }
        guard !next.legacySyncedRowsScrubbed else { return true }
        next.legacySyncedRowsScrubbed = true
        return persist(next)
    }

    /// Drops the oldest day keys past ``maxDays`` (`yyyy-MM-dd` sorts chronologically). Shared with
    /// the in-memory store so both honor the same bound.
    static func evictOldest(_ days: inout [String: DeviceHealthResidue]) {
        guard days.count > maxDays else { return }
        for key in days.keys.sorted().prefix(days.count - maxDays) {
            days[key] = nil
        }
    }

    /// The decoded file, reading it on first use. A missing file is an empty cache; a file that
    /// cannot be READ (locked device, protection class) returns nil and is retried next time; a
    /// file that reads but cannot be DECODED is treated as empty and will be overwritten.
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
            PersistenceFailureAudit.record("healthResidue.read.failed", error: error)
            return nil
        }
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            PersistenceFailureAudit.record("healthResidue.decode.failed", error: error)
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
            PersistenceFailureAudit.record("healthResidue.write.failed", error: error)
            return false
        }
    }
}

/// The in-memory ``DeviceHealthResidueStoring`` — the default for a `FernletStore` built through the
/// synchronous initializer (tests and previews), so a store that is not handed a cache can never
/// share, or wipe, another store's (the per-instance-sidecar lesson: an isolation seam whose default
/// is process-global is a cross-suite flake waiting for its first wipe). The launch path
/// (`FernletStore.load`) always uses ``FileDeviceHealthResidueStore/production``.
@MainActor
final class InMemoryDeviceHealthResidueStore: DeviceHealthResidueStoring {
    private var days: [String: DeviceHealthResidue] = [:]
    private(set) var legacySyncedRowsScrubbed = false
    private(set) var importedBodyProfile: DeviceHealthBodyProfile?

    init() {}

    func residue(for dateKey: String) -> DeviceHealthResidue? { days[dateKey] }

    func allResidues() -> [String: DeviceHealthResidue] { days }

    func record(_ residue: DeviceHealthResidue?, for dateKey: String) -> Bool {
        guard !dateKey.isEmpty else { return false }
        days[dateKey] = (residue?.isEmpty ?? true) ? nil : residue
        FileDeviceHealthResidueStore.evictOldest(&days)
        return true
    }

    func recordImportedBodyProfile(_ profile: DeviceHealthBodyProfile?) -> Bool {
        importedBodyProfile = (profile?.isEmpty ?? true) ? nil : profile
        return true
    }

    func clearAll() -> Bool {
        days = [:]
        importedBodyProfile = nil
        legacySyncedRowsScrubbed = false
        return true
    }

    func markLegacySyncedRowsScrubbed() -> Bool {
        legacySyncedRowsScrubbed = true
        return true
    }
}
