//
//  LocalFernletRepository.swift
//  Fernlet
//
//  Created by Coding Assistant on 5/16/26.
//

import Foundation
import FernletFoundation
import FernletDomainModel
import FernletScoring
import FernletPersistence

/// The single Codable aggregate both persistence backends serialize — every diary slice (day
/// history, settings, aggregate lists, derived log tables, Tier-2 memories) in one blob.
///
/// ``LocalFernletRepository`` writes it as a pretty-printed JSON file (the local/no-iCloud path,
/// where ``days`` holds the full, uncapped history), while `CoreDataFernletRepository` (in
/// `CloudKitSync`) embeds the identical encoding in a Core Data + CloudKit record — there,
/// ``days`` is only a bounded recent cache and per-row `DayRecord` rows are the uncapped source
/// of truth. Because this type IS the synced payload, it must only ever contain
/// privacy-stripped content: writes arrive through the `SanitizedSnapshot` seam, so sealed
/// narratives (journal bodies destined for the encrypted store, cycle data) never enter the blob.
///
/// The hand-written `init(from:)` decodes every key with `decodeIfPresent` plus a default, so a
/// blob written by an older build (missing newer keys) always decodes; a hard decode failure is
/// reserved for genuine corruption and trips the owning repository's read-only recovery mode.
/// The `apply(_:maxStoredDays:)` / `rebuildDerivedTables(todayKey:recentDays:)` extension methods
/// are the shared write path both repositories funnel through. Declared `@unchecked Sendable`:
/// a plain mutable value type the repositories hand across actor boundaries by copy.
public struct LocalFernletDatabase: Codable, @unchecked Sendable {
    /// Blob format version; currently always 1. Backward compatibility is handled by the
    /// tolerant decoder rather than version branching.
    public var schemaVersion = 1
    /// Timestamp of the last mutation, refreshed by `apply(_:maxStoredDays:)` and the Tier-2
    /// replace path. ISO-8601 round-trips drop fractional seconds.
    public var updatedAt = Date()
    /// Per-day diary history keyed by day key (yyyy-MM-dd). Full and uncapped on the local
    /// path; a bounded recent cache on the Core Data path (see `apply(_:maxStoredDays:)`).
    public var days: [String: FernletDay] = [:]
    /// Per-store guard for the blob→per-row `DayRecord` migration (Core Data path). Lives in the store
    /// (not the keychain) so it shares the store's lifecycle: a data reset re-arms it, and any later
    /// build still lazily backfills rows from the blob until this is true — which is what makes retiring
    /// the blob's `days` safe.
    public var daysMigratedToRows = false
    /// Precomputed counts of day content, kept so iCloud "existing data" detection stays a single-record
    /// read once the Core Data path clears the blob's `days` cache (Stage B). Empty until populated; the
    /// local/no-iCloud path leaves it empty (it has no cloud detection).
    public var dayContentSummary = DayContentSummary()
    /// User settings, already privacy-stripped by the sanitizing snapshot factories.
    public var settings = FernletSettings()
    /// Recently logged meals surfaced for quick re-logging.
    public var recentMeals: [Meal] = []
    /// The journal-entry carryover list the snapshot maintains across days.
    public var previousJournals: [JournalEntry] = []
    /// Tier-1 (user-visible, user-editable) memory notes.
    public var memories: [MemoryNote] = []
    /// The user's fitness goals; the first is treated as primary by `TierTwoMemoryEngine`.
    public var goals: [FitnessGoal] = []
    /// Companion workshop state (customization/clothing data).
    public var workshop = WorkshopData()
    /// Derived table: one ``DailyLogRecord`` per day in the recent window. Recomputable —
    /// rebuilt from ``days`` on every save by `rebuildDerivedTables(todayKey:recentDays:)`.
    public var dailyLogs: [DailyLogRecord] = []
    /// Derived table: per-meal ``MealLogRecord`` rows for the recent window. Recomputable.
    public var mealLogs: [MealLogRecord] = []
    /// Derived table: per-workout ``WorkoutLogRecord`` rows for the recent window. Recomputable.
    public var workoutLogs: [WorkoutLogRecord] = []
    /// Derived table: per-entry ``JournalLogRecord`` rows for the recent window. Recomputable.
    public var journalLogs: [JournalLogRecord] = []
    /// Pending AI meal-analysis retries, persisted so they survive relaunch.
    public var retryQueue: [AIAnalysisRetryRecord] = []
    /// Tier-2 behavioral memories inferred by `TierTwoMemoryEngine` on each derived-table
    /// rebuild; also replaceable wholesale via sealed-backup restore.
    public var tierTwoMemories: [TierTwoMemoryRecord] = []
    /// The user's custom food library.
    public var foodItems: [FoodItem] = []
    /// Saved recipe definitions (including mesh-shared recipes).
    public var recipes: [RecipeDefinition] = []
    /// The per-day wellbeing score history.
    public var dailyScores: [DailyHealthScore] = []
    /// Proximity-session audit log entries.
    public var connectionSessionLogs: [ConnectionSessionLog] = []
    /// Trusted proximity-mesh peer records (the persisted half of the trust vault's roster).
    public var trustedProximityPeers: [ProximityTrustedPeerRecord] = []
    /// Trainer-export audit trail events.
    public var trainerAuditEvents: [TrainerAuditEvent] = []

    public init() {}

    /// Tolerant decoder: every key falls back to its default via `decodeIfPresent`, so blobs
    /// written by older builds always decode and only genuine corruption fails the read.
    public nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        days = try container.decodeIfPresent([String: FernletDay].self, forKey: .days) ?? [:]
        daysMigratedToRows = try container.decodeIfPresent(Bool.self, forKey: .daysMigratedToRows) ?? false
        dayContentSummary = try container.decodeIfPresent(DayContentSummary.self, forKey: .dayContentSummary) ?? DayContentSummary()
        settings = try container.decodeIfPresent(FernletSettings.self, forKey: .settings) ?? FernletSettings()
        recentMeals = try container.decodeIfPresent([Meal].self, forKey: .recentMeals) ?? []
        previousJournals = try container.decodeIfPresent([JournalEntry].self, forKey: .previousJournals) ?? []
        memories = try container.decodeIfPresent([MemoryNote].self, forKey: .memories) ?? []
        goals = try container.decodeIfPresent([FitnessGoal].self, forKey: .goals) ?? []
        workshop = try container.decodeIfPresent(WorkshopData.self, forKey: .workshop) ?? WorkshopData()
        dailyLogs = try container.decodeIfPresent([DailyLogRecord].self, forKey: .dailyLogs) ?? []
        mealLogs = try container.decodeIfPresent([MealLogRecord].self, forKey: .mealLogs) ?? []
        workoutLogs = try container.decodeIfPresent([WorkoutLogRecord].self, forKey: .workoutLogs) ?? []
        journalLogs = try container.decodeIfPresent([JournalLogRecord].self, forKey: .journalLogs) ?? []
        retryQueue = try container.decodeIfPresent([AIAnalysisRetryRecord].self, forKey: .retryQueue) ?? []
        tierTwoMemories = try container.decodeIfPresent([TierTwoMemoryRecord].self, forKey: .tierTwoMemories) ?? []
        foodItems = try container.decodeIfPresent([FoodItem].self, forKey: .foodItems) ?? []
        recipes = try container.decodeIfPresent([RecipeDefinition].self, forKey: .recipes) ?? []
        dailyScores = try container.decodeIfPresent([DailyHealthScore].self, forKey: .dailyScores) ?? []
        connectionSessionLogs = try container.decodeIfPresent([ConnectionSessionLog].self, forKey: .connectionSessionLogs) ?? []
        trustedProximityPeers = try container.decodeIfPresent([ProximityTrustedPeerRecord].self, forKey: .trustedProximityPeers) ?? []
        trainerAuditEvents = try container.decodeIfPresent([TrainerAuditEvent].self, forKey: .trainerAuditEvents) ?? []
    }
}

/// The local, iCloud-free `FernletRepository` conformer: persists the whole
/// ``LocalFernletDatabase`` as a single pretty-printed JSON file under Application Support.
///
/// One of the two real conformers to the `FernletRepository` contract (the other is
/// `CoreDataFernletRepository` in `CloudKitSync`). The app's `FernletStore` selects it when
/// `StoragePreferences` chooses local-only storage, and `CoreDataFernletRepository` also holds
/// one as its legacy repository so ``loadDatabaseForMigration(todayKey:)`` can hydrate the Core
/// Data store from a pre-existing local file.
///
/// Behavior:
/// - **Whole-file read-modify-write.** Every save decodes the file, applies the sanitized
///   snapshot/day, rebuilds the derived log tables + Tier-2 memories, and atomically rewrites
///   the file with `.completeFileProtection`. On this path the blob's `days` is the full,
///   uncapped history (no `maxStoredDays` bound is passed).
/// - **Fail-closed corruption handling.** An unreadable or undecodable file flips the instance
///   into read-only recovery mode (`State`'s `persistenceBlockedByDecodeFailure`): reads
///   return a fresh/migrated database, but every save is refused so a later write cannot
///   clobber data that might still be recoverable off disk. A subsequent successful decode or
///   ``purgeAllPersistedData()`` lifts the block.
/// - **Legacy migration.** When no file exists, `LegacyKeys` UserDefaults data (the
///   pre-database persistence) seeds the first database, and the first successful save clears
///   those keys.
/// - **Backup exclusion (security-hardening Phase 6).** When
///   `StoragePreferences.localBackupExcludedFromiOSBackup` is set, the day-blob file itself is
///   flagged `isExcludedFromBackup` — at `init` (covering launch) and again after every
///   successful save, because the atomic rewrite replaces the inode the flag lives on. The file
///   this protects is the LEGACY one: production always runs `CoreDataFernletRepository` over
///   `Fernlet.sqlite` (excluded under the same preference at store load, in `CloudKitSync`'s
///   `PersistenceController`), and this repository is only the one-time legacy-migration source —
///   but the JSON blob can still hold a user's pre-migration history in plaintext, and it was
///   the last local Fernlet-data file the Privacy & Data toggle's "your local Fernlet data is
///   excluded" copy did not reach. The explicit ``applyBackupExclusion(excluded:)`` seam is how
///   a runtime preference change (either direction) reaches the file immediately, mirroring
///   `PrivatePersistenceController.applyBackupExclusion`.
///
/// Concurrency: nonisolated with a fully synchronous API. The struct is a value-type facade over
/// a shared reference-type `State` box, so copies observe the same recovery/cleanup flags; the
/// box is unsynchronized and the type is not `Sendable`, so call sites are expected to confine
/// an instance to a single actor (in practice the MainActor store/save coordinator).
public struct LocalFernletRepository: FernletRepository {
    /// Shared mutable session flags for the value-type repository.
    ///
    /// A reference-type box so every copy of the enclosing struct observes the same
    /// `persistenceBlockedByDecodeFailure` (read-only recovery mode after a corrupt read) and
    /// `pendingLegacyCleanup` (legacy UserDefaults keys awaiting removal after the first
    /// successful save). Unsynchronized — safety relies on single-actor confinement of the
    /// repository, not on locking.
    private final class State {
        var persistenceBlockedByDecodeFailure = false
        var pendingLegacyCleanup = false
    }

    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let state = State()
    /// Live read of the user's `localBackupExcludedFromiOSBackup` choice, consulted at `init` and
    /// after every successful save (the atomic rewrite drops the inode-level exclusion flag).
    /// A closure so tests can pin it without touching the real preferences keychain; production
    /// resolves to `StoragePreferencesStore.currentPreferences()` — the same live-read pattern
    /// `PrivatePersistenceController` uses, so a stale in-memory copy can never mis-flag the file.
    private let backupExclusionPreference: () -> Bool

    /// Creates a repository backed by the given file, defaulting to
    /// `Application Support/Fernlet/FernletDatabase.json` (see ``defaultFileURL()``).
    ///
    /// Applies the backup-exclusion preference to an existing file immediately (set-only: a `true`
    /// preference excludes; a `false` one changes nothing here, because a keychain read that falls
    /// back to defaults must never silently RE-INCLUDE a deliberately excluded file — re-inclusion
    /// goes through the explicit ``applyBackupExclusion(excluded:)`` seam).
    ///
    /// - Parameters:
    ///   - fileURL: Override used by tests and by callers that stage a database in a
    ///     custom location; `nil` selects the production path.
    ///   - backupExclusionPreference: Test seam for the exclusion choice; `nil` selects the live
    ///     `StoragePreferencesStore.currentPreferences()` read.
    public init(fileURL: URL? = nil, backupExclusionPreference: (() -> Bool)? = nil) {
        let resolvedURL = fileURL ?? Self.defaultFileURL()
        assert(!resolvedURL.path.isEmpty, "repository path must not be empty")
        self.fileURL = resolvedURL
        self.encoder = RowPayloadCoders.makeEncoder(prettyPrinted: true)
        self.decoder = RowPayloadCoders.makeDecoder()
        self.backupExclusionPreference = backupExclusionPreference
            ?? { StoragePreferencesStore.currentPreferences().localBackupExcludedFromiOSBackup }
        applyBackupExclusionFromPreferenceIfSet()
    }

    /// Applies (or clears) the day-blob file's `isExcludedFromBackup` flag — the explicit seam for
    /// a runtime preference change, called alongside `PrivatePersistenceController`'s equivalent so
    /// one toggle covers the sealed store AND the local JSON blob in the same moment. Both
    /// directions on purpose: this path carries a deliberate user choice, unlike the fail-safe
    /// set-only application at `init`/save. A no-op when no file exists yet (the flag would land on
    /// nothing; the save path re-applies once the file is written).
    public func applyBackupExclusion(excluded: Bool) {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        BackupExclusion.apply(fileURL: fileURL, excluded: excluded)
    }

    /// Set-only preference application: excludes the existing file when the preference says so,
    /// and touches nothing otherwise (see the `init` doc for why `false` is deliberately inert
    /// here). Called from `init` and after every successful `saveDatabase` write, because the
    /// atomic rewrite replaces the inode the flag lives on.
    private func applyBackupExclusionFromPreferenceIfSet() {
        guard FileManager.default.fileExists(atPath: fileURL.path), backupExclusionPreference() else { return }
        BackupExclusion.apply(fileURL: fileURL, excluded: true)
    }

    /// Loads the full aggregate for `todayKey`, substituting a fresh empty day when no day row
    /// exists for that key yet. Never fails: corruption degrades to a migrated/fresh database
    /// (and arms read-only recovery mode) rather than throwing.
    public func loadSnapshot(todayKey: String) -> FernletSnapshot {
        assert(!todayKey.isEmpty, "today key required")
        let database = loadDatabase(todayKey: todayKey)
        let day = database.days[todayKey] ?? FernletDay(date: todayKey)
        return .assembled(todayKey: todayKey, day: day, from: database)
    }

    /// Persists a privacy-stripped snapshot: read-modify-write of the whole file, including a
    /// derived-table + Tier-2 rebuild.
    ///
    /// - Parameter sanitized: A `SanitizedSnapshot` — mintable only through the storage privacy
    ///   strip, which is what keeps un-stripped content out of the blob by type.
    /// - Returns: `false` when the save is refused (read-only recovery mode) or any encode/write
    ///   step fails; the on-disk file is left untouched in that case.
    ///   Not discardable (R7): a dropped `false` is a save the caller believes landed.
    public func saveSnapshot(_ sanitized: SanitizedSnapshot) -> Bool {
        let snapshot = sanitized.snapshot
        // Guard, not assert: asserts compile out of Release, and an empty key would write the
        // day under "" (R5). False is the documented not-durable signal the caller retries on.
        guard !snapshot.todayKey.isEmpty else {
            assertionFailure("snapshot key required")
            return false
        }
        var database = loadDatabase(todayKey: snapshot.todayKey)
        database.apply(snapshot)
        database.rebuildDerivedTables(todayKey: snapshot.todayKey)
        return saveDatabase(database)
    }

    /// Persists a single (typically past) day without touching the aggregate slices, then
    /// rebuilds the derived tables so they reflect the edit.
    ///
    /// - Parameters:
    ///   - sanitized: The privacy-stripped day; its `date` must equal `dateKey` (asserted).
    ///   - dateKey: The day being written.
    ///   - todayKey: The current day key, used for the rebuild context.
    /// - Returns: `false` under read-only recovery mode or on any write failure.
    public func updateDay(_ sanitized: SanitizedDay, for dateKey: String, todayKey: String) -> Bool {
        let day = sanitized.day
        // Guards, not asserts: in Release a `day.date != dateKey` mismatch would write the payload
        // under the WRONG key in `database.days` — silent history corruption (R5).
        guard !dateKey.isEmpty, !todayKey.isEmpty, day.date == dateKey else {
            assertionFailure("day key mismatch")
            return false
        }
        var database = loadDatabase(todayKey: todayKey)
        database.days[dateKey] = day
        database.rebuildDerivedTables(todayKey: todayKey)
        return saveDatabase(database)
    }

    /// The concrete on-disk location of the JSON database, surfaced for diagnostics and
    /// migration tooling.
    public func databaseFileURL() -> URL {
        assert(fileURL.pathExtension == "json", "database must be json")
        return fileURL
    }

    /// Human-readable backing-store description (the database file name) for diagnostics.
    public func storageDescription() -> String {
        fileURL.lastPathComponent
    }

    /// Every persisted day keyed by date key — on this path the file itself is the uncapped,
    /// authoritative history the store rehydrates on launch.
    public func loadAllDays() -> [String: FernletDay] {
        loadDatabase(todayKey: FernletDate.dayKey(for: .now)).days
    }

    /// The persisted Tier-2 behavioral memories that seed the inference base.
    public func loadTierTwoMemories() -> [TierTwoMemoryRecord] {
        loadDatabase(todayKey: FernletDate.dayKey(for: .now)).tierTwoMemories
    }

    /// Overwrites the persisted Tier-2 memories wholesale (sealed-backup restore on a fresh
    /// install), bumping `updatedAt`.
    ///
    /// - Returns: Whether the write succeeded (`false` under read-only recovery mode).
    public func replaceTierTwoMemories(_ records: [TierTwoMemoryRecord]) -> Bool {
        var database = loadDatabase(todayKey: FernletDate.dayKey(for: .now))
        database.tierTwoMemories = records
        database.updatedAt = Date()
        return saveDatabase(database)
    }

    /// Exposes the raw decoded database so `CoreDataFernletRepository` can hydrate the Core Data
    /// store from a pre-existing local file (one-time blob migration).
    public func loadDatabaseForMigration(todayKey: String) -> LocalFernletDatabase {
        loadDatabase(todayKey: todayKey)
    }

    /// Reads and decodes the database file; an absent file yields the legacy-UserDefaults
    /// migration, and an unreadable one arms read-only recovery mode.
    private func loadDatabase(todayKey: String) -> LocalFernletDatabase {
        assert(!todayKey.isEmpty, "today key required")
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return migratedDatabase(todayKey: todayKey)
        }
        guard let data = try? Data(contentsOf: fileURL) else {
            print("[Fernlet] Local database could not be read; entering read-only recovery mode.")
            markPersistenceBlockedByDecodeFailure()
            return migratedDatabase(todayKey: todayKey)
        }
        return decodeDatabase(data, todayKey: todayKey)
    }

    /// Decodes the blob; success clears any prior recovery block, while failure arms it and
    /// falls back to the legacy migration so reads still return something usable.
    private func decodeDatabase(_ data: Data, todayKey: String) -> LocalFernletDatabase {
        assert(!data.isEmpty, "database data required")
        assert(!todayKey.isEmpty, "today key required")
        if let database = try? decoder.decode(LocalFernletDatabase.self, from: data) {
            state.persistenceBlockedByDecodeFailure = false
            return database
        }
        print("[Fernlet] Local database decode failed; entering read-only recovery mode.")
        markPersistenceBlockedByDecodeFailure()
        return migratedDatabase(todayKey: todayKey)
    }

    /// Arms read-only recovery mode: subsequent saves are refused until a successful decode or a
    /// purge lifts the block.
    private func markPersistenceBlockedByDecodeFailure() {
        state.persistenceBlockedByDecodeFailure = true
    }

    /// Deletes the whole local store file. Removing the file rather than writing an empty database
    /// leaves nothing on disk to be recovered, and the next `loadDatabase` already treats an absent
    /// file as a fresh database — so this is the same end state a first launch sees.
    ///
    /// - Returns: `false` when the file could not be removed. Not discardable (R7): "delete
    ///   everything" reports the store it could not clear.
    public func purgeAllPersistedData() -> Bool {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return true }
        do {
            try FileManager.default.removeItem(at: fileURL)
            // A decode failure earlier in the session blocks writes; the file is gone now, so the block
            // must lift or the user would be unable to save anything after wiping.
            state.persistenceBlockedByDecodeFailure = false
            return true
        } catch {
            assertionFailure("local database purge failed")
            return false
        }
    }

    /// The single write path: refuses under read-only recovery mode, then encodes and atomically
    /// writes the file, and — on the first success after a legacy migration — clears the old
    /// UserDefaults keys.
    private func saveDatabase(_ database: LocalFernletDatabase) -> Bool {
        assert(database.schemaVersion >= 1, "schema version invalid")
        guard !state.persistenceBlockedByDecodeFailure else {
            print("[Fernlet] Refusing to save after local database decode failed.")
            return false
        }
        guard ensureDirectoryExists() else { return false }
        guard let data = try? encoder.encode(database) else {
            assertionFailure("database encode failed")
            return false
        }
        guard write(data) else { return false }
        // Re-apply the backup-exclusion preference: the atomic write above replaced the inode,
        // which silently dropped any exclusion flag the previous file carried.
        applyBackupExclusionFromPreferenceIfSet()
        if state.pendingLegacyCleanup {
            state.pendingLegacyCleanup = false
            Self.clearLegacyUserDefaultsIfPresent()
        }
        return true
    }

    /// Creates the database's parent directory (with intermediates) if needed; a failure aborts
    /// the save rather than letting the write throw.
    private func ensureDirectoryExists() -> Bool {
        let directory = fileURL.deletingLastPathComponent()
        assert(!directory.path.isEmpty, "directory path required")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return true
        } catch {
            assertionFailure("database directory create failed")
            return false
        }
    }

    /// Writes the encoded blob atomically with `.completeFileProtection` (encrypted at rest,
    /// inaccessible while the device is locked).
    private func write(_ data: Data) -> Bool {
        assert(!data.isEmpty, "write data required")
        do {
            try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
            return true
        } catch {
            assertionFailure("database write failed")
            return false
        }
    }

    /// Builds a first database from the pre-database `LegacyKeys` UserDefaults data (or fresh
    /// defaults on a clean install) and flags the legacy keys for cleanup after the next
    /// successful save.
    private func migratedDatabase(todayKey: String) -> LocalFernletDatabase {
        assert(!todayKey.isEmpty, "today key required")
        var database = LocalFernletDatabase()
        database.days[todayKey] = Self.loadLegacy(FernletDay.self, key: LegacyKeys.day(todayKey)) ?? FernletDay(date: todayKey)
        database.settings = Self.loadLegacy(FernletSettings.self, key: LegacyKeys.settings) ?? FernletSettings()
        database.recentMeals = Self.loadLegacy([Meal].self, key: LegacyKeys.recentMeals) ?? []
        database.previousJournals = Self.loadLegacy([JournalEntry].self, key: LegacyKeys.previousJournals) ?? []
        database.memories = Self.loadLegacy([MemoryNote].self, key: LegacyKeys.memories) ?? []
        database.goals = Self.loadLegacy([FitnessGoal].self, key: LegacyKeys.goals) ?? []
        database.workshop = Self.loadLegacy(WorkshopData.self, key: LegacyKeys.workshop) ?? WorkshopData()
        database.rebuildDerivedTables(todayKey: todayKey)
        state.pendingLegacyCleanup = true
        return database
    }

    /// Removes the pre-database UserDefaults keys (including the per-day `fernlet-day-*`
    /// entries) once their content has been safely persisted to the database file.
    private static func clearLegacyUserDefaultsIfPresent() {
        let knownKeys = [
            LegacyKeys.settings,
            LegacyKeys.recentMeals,
            LegacyKeys.previousJournals,
            LegacyKeys.memories,
            LegacyKeys.goals,
            LegacyKeys.workshop
        ]
        guard knownKeys.contains(where: { UserDefaults.standard.data(forKey: $0) != nil }) else { return }
        knownKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        UserDefaults.standard.dictionaryRepresentation().keys
            .filter { $0.hasPrefix("fernlet-day-") }
            .forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    /// Decodes one legacy UserDefaults value, returning `nil` (not throwing) when the key is
    /// absent or the stored data no longer decodes.
    private static func loadLegacy<T: Decodable>(_ type: T.Type, key: String) -> T? {
        assert(!key.isEmpty, "legacy key required")
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        assert(!data.isEmpty, "legacy data should not be empty")
        return try? JSONDecoder().decode(type, from: data)
    }

    /// The production database location: `Application Support/Fernlet/FernletDatabase.json`
    /// (falling back to the temporary directory only if Application Support is unavailable).
    public static func defaultFileURL() -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        assert(directory != nil, "application support unavailable")
        return (directory ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("Fernlet", isDirectory: true)
            .appendingPathComponent("FernletDatabase.json")
    }

    /// The pre-database UserDefaults keys the original app persisted under.
    ///
    /// Retained solely so ``migratedDatabase(todayKey:)`` can hydrate a first database from an
    /// old install's data and ``clearLegacyUserDefaultsIfPresent()`` can remove the keys once
    /// that data is safely in the file. New code must never write these keys.
    private enum LegacyKeys {
        static let settings = "fernlet-settings"
        static let recentMeals = "fernlet-recent-meals"
        static let previousJournals = "fernlet-previous-journals"
        static let memories = "fernlet-memories"
        static let goals = "fernlet-goals"
        static let workshop = "fernlet-workshop"

        static func day(_ key: String) -> String {
            assert(!key.isEmpty, "legacy day key required")
            return "fernlet-day-\(key)"
        }
    }
}

extension LocalFernletDatabase {
    /// Applies today's day + the aggregate slices, refreshing `updatedAt`. `maxStoredDays` bounds the
    /// blob's own `days` window: the Core Data path passes a small bound (its `days` is just a recent
    /// cache — the per-row `DayRecord` store is the uncapped source of truth), while the local/no-iCloud
    /// path passes nil so its single file holds the full, now-uncapped history. When trimming, the
    /// lexicographically oldest date keys are dropped first.
    public mutating func apply(_ snapshot: FernletSnapshot, maxStoredDays: Int? = nil) {
        assert(!snapshot.todayKey.isEmpty, "snapshot key required")
        assert(snapshot.day.date == snapshot.todayKey, "snapshot day mismatch")
        days[snapshot.todayKey] = snapshot.day
        if let maxStoredDays, days.count > maxStoredDays {
            let oldest = days.keys.sorted().prefix(days.count - maxStoredDays)
            oldest.forEach { days.removeValue(forKey: $0) }
        }
        settings = snapshot.settings
        recentMeals = snapshot.recentMeals
        previousJournals = snapshot.previousJournals
        memories = snapshot.memories
        goals = snapshot.goals
        workshop = snapshot.workshop
        foodItems = snapshot.foodItems
        recipes = snapshot.recipes
        dailyScores = snapshot.dailyScores
        retryQueue = snapshot.retryQueue
        connectionSessionLogs = snapshot.connectionSessionLogs
        trustedProximityPeers = snapshot.trustedProximityPeers
        trainerAuditEvents = snapshot.trainerAuditEvents
        updatedAt = Date()
    }

    /// Rebuilds the derived log tables + Tier-2 memories. `recentDays` (oldest-first) lets a per-row store
    /// inject a bounded window of days instead of paying a whole-history scan of `self.days`; when omitted
    /// it falls back to the blob's own `days` (the local/no-iCloud path). This is the shared write-path
    /// step both repositories run on every save, which is what makes the derived tables safely
    /// disposable — any frozen or stale row is overwritten on the next save.
    public mutating func rebuildDerivedTables(todayKey: String, recentDays: [(String, FernletDay)]? = nil) {
        assert(!todayKey.isEmpty, "today key required")
        let orderedDays = recentDays ?? Self.sortedDayPairs(days)
        dailyLogs = Self.makeDailyLogs(from: orderedDays)
        mealLogs = Self.makeMealLogs(from: orderedDays)
        workoutLogs = Self.makeWorkoutLogs(from: orderedDays)
        journalLogs = Self.makeJournalLogs(from: orderedDays)
        tierTwoMemories = TierTwoMemoryEngine.updateInferences(existing: tierTwoMemories, from: orderedDays, goals: goals)
    }

    /// Orders the day dictionary oldest-first by date key (day keys sort lexicographically).
    private static func sortedDayPairs(_ days: [String: FernletDay]) -> [(String, FernletDay)] {
        // No upper-bound assertion: day storage is uncapped now (per-row rows for iCloud, a single
        // uncapped file for local-only). The log builders below still bound their output by
        // `derivedLogWindowDays`, so the derived tables stay sized regardless of history depth.
        days.sorted { first, second in first.key < second.key }
    }

    /// One ``DailyLogRecord`` per day, bounded to the trailing ``FernletLimits/derivedLogWindowDays``.
    private static func makeDailyLogs(from days: [(String, FernletDay)]) -> [DailyLogRecord] {
        return days.suffix(FernletLimits.derivedLogWindowDays).map { key, day in
            DailyLogRecord(dateKey: key, day: day)
        }
    }

    /// Per-meal rows for the window, clamped per day (``FernletLimits/maxMealsPerDay``) and
    /// overall (``FernletLimits/maxMealLogs``).
    private static func makeMealLogs(from days: [(String, FernletDay)]) -> [MealLogRecord] {
        let nested = days.suffix(FernletLimits.derivedLogWindowDays).map { key, day in
            day.meals.prefix(FernletLimits.maxMealsPerDay).map { meal in
                MealLogRecord(dateKey: key, meal: meal, totals: MacroTotals(meals: day.meals))
            }
        }
        return Array(nested.joined().prefix(FernletLimits.maxMealLogs))
    }

    /// Per-workout rows for the window, clamped per day (``FernletLimits/maxWorkoutsPerDay``)
    /// and overall (``FernletLimits/maxWorkoutLogs``).
    private static func makeWorkoutLogs(from days: [(String, FernletDay)]) -> [WorkoutLogRecord] {
        let nested = days.suffix(FernletLimits.derivedLogWindowDays).map { key, day in
            day.workouts.prefix(FernletLimits.maxWorkoutsPerDay).map { workout in
                WorkoutLogRecord(dateKey: key, workout: workout)
            }
        }
        return Array(nested.joined().prefix(FernletLimits.maxWorkoutLogs))
    }

    /// Per-entry journal rows for the window, clamped per day (``FernletLimits/maxJournalsPerDay``)
    /// and overall (``FernletLimits/maxJournalLogs``).
    private static func makeJournalLogs(from days: [(String, FernletDay)]) -> [JournalLogRecord] {
        let nested = days.suffix(FernletLimits.derivedLogWindowDays).map { key, day in
            day.journals.prefix(FernletLimits.maxJournalsPerDay).map { journal in
                JournalLogRecord(dateKey: key, journal: journal)
            }
        }
        return Array(nested.joined().prefix(FernletLimits.maxJournalLogs))
    }

}

extension FernletSnapshot {
    /// Assembles the snapshot handed to the store from an already-resolved `day` plus the
    /// aggregate slices of a ``LocalFernletDatabase`` — the shared read-side counterpart of the
    /// shared write-side ``LocalFernletDatabase/apply(_:maxStoredDays:)``.
    ///
    /// Day resolution deliberately stays at the call sites because it differs per backend:
    /// ``LocalFernletRepository/loadSnapshot(todayKey:)`` reads the blob's own `days`, while
    /// `CoreDataFernletRepository` (in `CloudKitSync`) prefers its per-row `DayRecord` store
    /// with a pre-migration blob fallback. Only the (identical) slice mapping is shared here.
    public static func assembled(todayKey: String, day: FernletDay, from database: LocalFernletDatabase) -> FernletSnapshot {
        FernletSnapshot(
            todayKey: todayKey,
            day: day,
            settings: database.settings,
            recentMeals: database.recentMeals,
            previousJournals: database.previousJournals,
            memories: database.memories,
            goals: database.goals,
            workshop: database.workshop,
            foodItems: database.foodItems,
            recipes: database.recipes,
            dailyScores: database.dailyScores,
            retryQueue: database.retryQueue,
            connectionSessionLogs: database.connectionSessionLogs,
            trustedProximityPeers: database.trustedProximityPeers,
            trainerAuditEvents: database.trainerAuditEvents
        )
    }
}

/// The persistence-layer size caps: derived-table windows, per-day entry clamps, and log-table
/// ceilings shared by both repositories and the derived-signal/Tier-2 engines.
///
/// These bound only the *recomputable* structures — never day storage itself, which is uncapped
/// (per-row for the iCloud path, a single file for local-only). The log ceilings are sized as
/// window × per-day clamp (370 × 20 meals = 7,400; 370 × 12 = 4,440), so the two sides are
/// consistent by construction: changing one means revisiting the other. Consumers include the
/// derived-table builders here, ``DerivedSignalFactory``, `TierTwoMemoryEngine`,
/// `CoreDataFernletRepository`, and the app-side `CoreDataHealthKitCacheCleaner`.
public enum FernletLimits {
    /// How much day history the derived log tables (daily/meal/workout/journal) retain. Decoupled from
    /// day *storage* (which is per-row and uncapped) — it bounds only the recomputable log tables and the
    /// "year-ago" lookbacks, so derived rebuilds read a fixed recent window instead of the whole history.
    public static let derivedLogWindowDays = 370
    /// Per-day clamp on meals considered by the log builders, macro totals, and signal heuristics.
    public static let maxMealsPerDay = 20
    /// Per-day clamp on workouts considered by the log builders and training-load heuristics.
    public static let maxWorkoutsPerDay = 12
    /// Per-day clamp on journal entries considered by the log builders and mood heuristics.
    public static let maxJournalsPerDay = 12
    /// Overall ceiling on ``MealLogRecord`` rows (window × per-day clamp).
    public static let maxMealLogs = 7_400
    /// Overall ceiling on ``WorkoutLogRecord`` rows (window × per-day clamp).
    public static let maxWorkoutLogs = 4_440
    /// Overall ceiling on ``JournalLogRecord`` rows (window × per-day clamp).
    public static let maxJournalLogs = 4_440
    /// Maximum journal text length; ``JournalLogRecord``'s builder asserts it in debug.
    public static let maxJournalCharacters = 800
    /// Clamp on emotion keys carried per journal log row.
    public static let maxEmotionKeys = 8
    /// The maximum day window ``DerivedSignalFactory`` accepts (and `TierTwoMemoryEngine` uses).
    public static let signalWindowDays = 14
}

extension MacroTotals {
    /// Sums protein/carbs/fat across a day's meals, clamped to ``FernletLimits/maxMealsPerDay``.
    ///
    /// - Important: Asserts (debug-only) that the input is already within the per-day cap; the
    ///   clamp is the release-mode safety net.
    public init(meals: [Meal]) {
        assert(meals.count <= FernletLimits.maxMealsPerDay, "too many meals")
        let limited = meals.prefix(FernletLimits.maxMealsPerDay)
        self.init(
            protein: limited.reduce(0) { $0 + $1.macros.protein },
            carbs: limited.reduce(0) { $0 + $1.macros.carbs },
            fat: limited.reduce(0) { $0 + $1.macros.fat }
        )
    }
}
