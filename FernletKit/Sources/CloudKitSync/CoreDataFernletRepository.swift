import Combine
import LocalPersistence
import FernletFoundation
import CoreData
import Foundation
import FernletDomainModel
import FernletPersistence

@MainActor
public final class CoreDataFernletRepository: FernletRepository, @MainActor RemoteChangePublishingRepository {
    private static let primaryRecordID = "primary"

    private let controller: PersistenceController
    private let legacyRepository: LocalFernletRepository
    private let dayRecordRepository: any DayRecordRepositoring
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private var cachedDatabase: LocalFernletDatabase?
    private var cachedRecordUpdatedAt: Date?
    /// Decoded day-row history, memoized so the two full-history reads on every launch/foreground/remote
    /// change (`rebuildDerivedSignals` + `reconcileCoinLedger`) — and the month/day views that read past days
    /// — share ONE decode instead of re-scanning the whole (now uncapped) `DayRecord` table each call.
    /// Invalidated conservatively: nil'd on every `saveDatabase` (which follows every day-row write), on the
    /// remote-change/manual cache invalidation, and on entering read-only recovery — so it can never serve a
    /// day that was edited or synced in. Today is always overlaid live by `DiaryStore.loadDays`, so a stale
    /// today-row here is irrelevant.
    private var cachedAllDays: [String: FernletDay]?
    private var persistenceBlockedByDecodeFailure = false
    private var persistenceBlockedByFetchFailure = false
    private var forcedFetchFailureForTesting: Error?
    private var cancellable: AnyCancellable?

    /// Fires after the local cache is invalidated due to a remote change.
    public let remoteChangeSubject = PassthroughSubject<Void, Never>()

    public var remoteChangePublisher: AnyPublisher<Void, Never> {
        remoteChangeSubject.eraseToAnyPublisher()
    }

    public init(
        controller: PersistenceController? = nil,
        legacyRepository: LocalFernletRepository? = nil,
        dayRecordRepository: (any DayRecordRepositoring)? = nil
    ) {
        let resolvedController = controller ?? .shared
        self.controller = resolvedController
        self.legacyRepository = legacyRepository ?? LocalFernletRepository(fileURL: LocalFernletRepository.defaultFileURL())
        self.dayRecordRepository = dayRecordRepository ?? DayRecordRepository(controller: resolvedController)
        self.encoder = RowPayloadCoders.makeEncoder()
        self.decoder = RowPayloadCoders.makeDecoder()
        self.cancellable = self.controller.remoteChangePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.invalidateCacheIfRecordChanged()
            }
    }

    public func loadSnapshot(todayKey: String) -> FernletSnapshot {
        StartupTiming.timed("CoreDataFernletRepository.loadSnapshot") {
            assert(!todayKey.isEmpty, "today key required")
            let database = loadDatabase(todayKey: todayKey)
            return snapshot(from: database, todayKey: todayKey)
        }
    }

    public func loadSnapshotAsync(todayKey: String) async -> FernletSnapshot {
        let signpostID = StartupTiming.begin("CoreDataFernletRepository.loadSnapshotAsync")
        defer { StartupTiming.end("CoreDataFernletRepository.loadSnapshotAsync", signpostID: signpostID) }

        assert(!todayKey.isEmpty, "today key required")

        if let cached = cachedDatabase {
            let database = cached.daysMigratedToRows ? cached : migrateDaysToRowsIfNeeded(cached)
            return snapshot(from: database, todayKey: todayKey)
        }

        let record: NSManagedObject
        switch fetchRecordResult() {
        case .found(let fetchedRecord):
            record = fetchedRecord
        case .missing:
            clearReadOnlyRecoveryFlags()
            var migrated = migrateDatabase(todayKey: todayKey)
            migrated = migrateDaysToRowsIfNeeded(migrated)
            if cachedDatabase == nil { _ = saveDatabase(migrated) }
            return snapshot(from: migrated, todayKey: todayKey)
        case .failed(let error):
            markPersistenceBlockedByFetchFailure(error)
            return snapshot(from: LocalFernletDatabase(), todayKey: todayKey)
        }
        guard let payload = record.value(forKey: "payloadData") as? Data else {
            print("[Fernlet] Core Data record exists but payloadData is nil; entering read-only recovery mode.")
            markPersistenceBlockedByDecodeFailure()
            return snapshot(from: LocalFernletDatabase(), todayKey: todayKey)
        }

        do {
            let decodedAt = record.value(forKey: "updatedAt") as? Date
            let decoded = try await Self.decodeDatabaseAsync(from: payload)
            // A concurrent saveDatabase() may have installed a fresher cache while we decoded.
            if let fresh = cachedDatabase {
                return snapshot(from: fresh, todayKey: todayKey)
            }
            clearReadOnlyRecoveryFlags()
            let database = migrateDaysToRowsIfNeeded(decoded)
            if cachedDatabase == nil {
                cachedDatabase = database
                cachedRecordUpdatedAt = decodedAt
            }
            return snapshot(from: database, todayKey: todayKey)
        } catch {
            print("[Fernlet] Core Data record decode failed; entering read-only recovery mode: \(error.localizedDescription)")
            markPersistenceBlockedByDecodeFailure()
            return snapshot(from: LocalFernletDatabase(), todayKey: todayKey)
        }
    }

    public func loadDay(for dateKey: String, todayKey: String) -> FernletDay {
        assert(!dateKey.isEmpty, "date key required")
        if let cached = cachedAllDays?[dateKey] { return cached }   // served from the shared day cache (no query)
        let database = loadDatabase(todayKey: todayKey)  // ensure decoded + rows backfilled
        // Blob fallback (safety net for the not-fully-migrated state): while `daysMigratedToRows` is still
        // false (e.g. a failed migration batch), a day may live ONLY in the blob and have no row yet.
        // Reading rows-only would return an empty day; a subsequent edit would then write a near-empty row
        // that migration's content-merge could keep, replacing the original. Fall back to the blob's copy —
        // mirroring `snapshot(from:)`. Post-migration `database.days` is empty, so this is a no-op there.
        return dayRecordRepository.load(dateKeys: [dateKey])[dateKey]
            ?? database.days[dateKey]
            ?? FernletDay(date: dateKey)
    }

    @discardableResult public func saveSnapshot(_ sanitized: SanitizedSnapshot) -> Bool {
        let snapshot = sanitized.snapshot
        assert(!snapshot.todayKey.isEmpty, "snapshot key required")
        var database = loadDatabase(todayKey: snapshot.todayKey)
        // Write today's day to its per-row store FIRST so the derived rebuild (sourced from rows) sees it —
        // but not while persistence is blocked (a failed reload returns the empty fallback, and writing the
        // row then would corrupt it just as saveDatabase refuses the blob). Skip → the whole save is a no-op.
        // The day comes from an already-minted SanitizedSnapshot, so re-wrap its stripped day through the
        // SanitizedDay barrier (no re-strip) rather than handing a raw FernletDay to the synced row store.
        if !isPersistenceBlocked {
            guard writeDayRow(sanitized.sanitizedDay, for: snapshot.todayKey) else {
                // The row write failed/rolled back. Do NOT clear the blob's copy of the day and report a
                // durable save — return false so SnapshotSaveCoordinator retries. The blob still holds
                // today's day (apply below is skipped), so nothing is lost.
                return false
            }
        }
        // While migration is still pending (e.g. a failed batch left the flag false), the blob may hold the
        // only copy of un-migrated days, so don't bound/prune it then. Once migrated, refreshRowDerivedState
        // clears the blob's days entirely, so the bound here is moot — apply still writes the aggregate.
        let blobDayBound = database.daysMigratedToRows ? FernletLimits.derivedLogWindowDays : nil
        database.apply(snapshot, maxStoredDays: blobDayBound)
        refreshRowDerivedState(&database, todayKey: snapshot.todayKey, justWrote: (snapshot.todayKey, snapshot.day))
        return saveDatabase(database, invalidatesDayCache: false)
    }

    /// After day rows are written, refresh the blob's row-derived state from the bounded recent window:
    /// rebuild the derived log tables, recompute the day-content summary (so iCloud detection stays a
    /// single blob read), and — once migration is complete — clear the blob's `days` cache entirely (the
    /// per-row `DayRecord` store is the authoritative, uncapped source of truth).
    ///
    /// `justWrote` is the (dateKey, day) the caller just persisted; when the day-history memo is warm it is
    /// patched in place with that day and the derived window is built from the warm cache — so a normal
    /// save no longer re-fetches and re-decodes the whole (uncapped) row history on the hot path. When the
    /// memo is cold, it falls back to a bounded `loadRecent` fetch.
    private func refreshRowDerivedState(
        _ database: inout LocalFernletDatabase,
        todayKey: String,
        justWrote: (dateKey: String, day: FernletDay)
    ) {
        let recent = recentDayPairs(patching: justWrote)
        database.rebuildDerivedTables(todayKey: todayKey, recentDays: recent)
        database.dayContentSummary = DayContentSummary(days: recent.map(\.1))
        if database.daysMigratedToRows {
            database.days = [:]
        }
    }

    @discardableResult public func updateDay(_ sanitized: SanitizedDay, for dateKey: String, todayKey: String) -> Bool {
        let day = sanitized.day
        assert(!dateKey.isEmpty, "date key required")
        assert(!todayKey.isEmpty, "today key required")
        assert(day.date == dateKey, "day date mismatch")
        var database = loadDatabase(todayKey: todayKey)
        if !isPersistenceBlocked {
            guard writeDayRow(sanitized, for: dateKey) else {
                // Row write failed — surface it so the caller retries instead of treating a lost edit as
                // durable. Nothing was written to the blob for this day (updateDay never does), so the
                // day's prior row/blob copy is untouched.
                return false
            }
        }
        // Pre-migration, the blob still holds un-migrated days and is loadDay's fallback (item B), and
        // migrateDaysToRowsIfNeeded later fans its days into rows. An edit-to-empty of a blob-only day writes
        // NO row (item G deletes instead), so without this the stale non-empty blob copy would survive and
        // resurrect the pre-edit content on the next read/migration. Keep any blob copy of THIS day consistent
        // with the edit — only for keys the blob already holds, so an old past-day edit still can't GROW the
        // blob. Once migrated (blob days cleared), this is a no-op.
        if !database.daysMigratedToRows, database.days[dateKey] != nil {
            if day.hasLoggedContent {
                database.days[dateKey] = day
            } else {
                database.days[dateKey] = nil
            }
        }
        // The edited day lives in its row; refresh the derived tables + detection summary from rows (and,
        // once migrated, keep the blob's days cleared).
        refreshRowDerivedState(&database, todayKey: todayKey, justWrote: (dateKey, day))
        return saveDatabase(database, invalidatesDayCache: false)
    }

    /// Persists one sanitized day to its per-row store, guarding on logged content (item G): a day with no
    /// logged content writes NO row (so a device that merely launched the app doesn't stamp an empty
    /// `DayRecord` that makes every other device read "existing cloud data"). A day that BECOMES empty
    /// (its last entry deleted) deletes any existing row rather than leaving a stale non-empty one. Returns
    /// whether the underlying write succeeded (false → the caller must not treat the save as durable). Also
    /// patches the warm day-history memo in place so the derived rebuild reuses it without a re-fetch.
    private func writeDayRow(_ sanitized: SanitizedDay, for dateKey: String) -> Bool {
        let day = sanitized.day
        if day.hasLoggedContent {
            let ok = dayRecordRepository.upsert([DayRecordUpsert(sanitized: sanitized, updatedAt: Date())])
            if ok { cachedAllDays?[dateKey] = day }
            return ok
        } else {
            // No logged content: remove any prior row so an emptied day doesn't linger. `delete` is a no-op
            // (returns true) when no row exists — the common "empty launch" case writes nothing.
            let ok = dayRecordRepository.delete(dateKeys: [dateKey])
            if ok { cachedAllDays?[dateKey] = nil }
            return ok
        }
    }

    public func storageDescription() -> String {
        "Core Data + iCloud"
    }

    public func invalidateCache() {
        cachedDatabase = nil
        cachedAllDays = nil
        cachedRecordUpdatedAt = nil
        remoteChangeSubject.send()
    }

    public func forceNextFetchFailureForTesting(_ error: Error = CocoaError(.fileReadUnknown)) {
        forcedFetchFailureForTesting = error
    }

    private func invalidateCacheIfRecordChanged() {
        let latestUpdatedAt = fetchRecordUpdatedAt()
        guard latestUpdatedAt != cachedRecordUpdatedAt else { return }

        // Days now live in per-record DayRecords, so NSPersistentCloudKitContainer merges day edits per
        // record: different-day edits on two devices both persist (the old whole-blob union that dropped
        // same-day remote edits is gone), and a same-day conflict resolves by the store's merge policy.
        // A remote change therefore just drops the cached aggregate; day rows are re-read fresh (and
        // duplicate-collapsed) on the next access, so no bespoke merge or feedback-loop guard is needed.
        cachedDatabase = nil
        cachedAllDays = nil
        cachedRecordUpdatedAt = latestUpdatedAt
        remoteChangeSubject.send()
    }

    /// Fans the blob's `days` into per-row `DayRecord`s once (idempotent, batched, crash-safe). Called
    /// only after a CLEAN aggregate decode (never under read-only recovery, which would fan out an empty
    /// fallback). On any batch failure it leaves `daysMigratedToRows` false so a later launch resumes —
    /// `upsert` skips rows already written, so the rows themselves are the progress cursor. This permanent
    /// lazy backfill is what makes retiring the blob's `days` safe.
    private func migrateDaysToRowsIfNeeded(_ database: LocalFernletDatabase) -> LocalFernletDatabase {
        guard !database.daysMigratedToRows else { return database }
        let pairs = database.days.sorted { $0.key < $1.key }
        if !pairs.isEmpty {
            // Backfill+MERGE, not backfill+skip. For a dateKey WITHOUT a row: write it. For a key that
            // ALREADY has a row: normally the row is authoritative (another device wrote a fresher edit
            // that synced in, or a prior batch / updateDay wrote it) so we skip — overwriting with the
            // blob's copy, stamped with the blob's single global `updatedAt`, could clobber a newer edit
            // both locally and back over CloudKit. BUT a mixed-version fleet can leave a fresher edit only
            // in the shared blob: an old build re-writes a same-day edit into `days` (its encoder drops the
            // `daysMigratedToRows` key, so this build re-runs migration) — skipping it as "existing" and
            // then clearing the blob would lose that edit. So when the blob day carries STRICTLY MORE logged
            // content than the existing row, prefer it (overwrite the row). This is best-effort: the legacy
            // blob has only one global `updatedAt`, so true per-day freshness is NOT recoverable — logged-
            // content count is the tiebreak for the transient mixed-version window, chosen to preserve
            // rather than drop user data.
            //
            // PRIVACY (S3): legacy blob days from pre-hardening builds may carry cycle/intimate
            // `healthContext` (and, in principle, sealed-journal plaintext) that the normal saveSnapshot/
            // updateDay path strips before a synced row is written. Route EVERY migration write through the
            // same SanitizedDay strip so no unstripped sensitive content lands in the uncapped, CloudKit-
            // synced DayRecord rows. cycle/intimate are always nil'd. Sealed-journal *text* cannot be
            // stripped here: which journal ids are sealed is app-layer state (DiaryStore's sealed-id hook),
            // not reachable in the repository — so we pass an empty sealed set (unsealed text is legitimate
            // blob content and must be preserved). Any residual sealed-journal plaintext in a legacy blob is
            // self-healed by `DiaryStore.mutatePastDay`, which DOES have the sealed set, the next time that
            // day is touched (matching the existing WI-1 historical-scrub behaviour).
            let stamp = database.updatedAt
            let existingRows = dayRecordRepository.load(dateKeys: pairs.map(\.key))
            // Pre-strip each blob day ONCE (privacy barrier), then decide backfill/overwrite by comparing
            // the STRIPPED copy's content — so soon-to-be-stripped sensitive content can't tip the "richer"
            // heuristic. Each survivor is written through the same SanitizedDay it was compared on.
            let toWrite: [DayRecordUpsert] = pairs.compactMap { key, blobDay in
                let sanitized = SanitizedDay.sanitizing(blobDay, sealedJournalIDs: [])
                if let existing = existingRows[key],
                   Self.loggedContentCount(sanitized.day) <= Self.loggedContentCount(existing) {
                    return nil  // existing row is authoritative (not strictly poorer) → skip
                }
                return DayRecordUpsert(sanitized: sanitized, updatedAt: stamp)
            }
            let batchSize = 250
            var index = 0
            while index < toWrite.count {
                let slice = Array(toWrite[index..<min(index + batchSize, toWrite.count)])
                let ok = dayRecordRepository.upsert(slice)
                guard ok else { return database }  // leave the flag false → resume next launch
                index += batchSize
            }
        }
        var migrated = database
        migrated.daysMigratedToRows = true
        // Seed the detection summary from the blob's days, then retire the blob's day cache (the rows just
        // written are authoritative). The `days` field stays decodable so an older build can still lazily
        // backfill from a blob that predates this clearing.
        //
        // TRADEOFF (item J — intentional, do NOT "fix" by re-seeding blob days): clearing `days` closes the
        // Stage-B privacy leak structurally (days-with-healthContext no longer sit in the synced blob). The
        // cost is a transient UX degradation: an OLD-build second device that adopts this cleared blob shows
        // empty recent history UNTIL it upgrades — after which CloudKit re-imports the per-row DayRecords and
        // history returns. This is NOT data loss: the rows are intact and authoritative. Re-populating
        // `days` here to spare the old build would regress the privacy win, so we accept the degradation.
        migrated.dayContentSummary = DayContentSummary(days: Array(database.days.values))
        migrated.days = [:]
        _ = saveDatabase(migrated)
        return migrated
    }

    /// The bounded recent-day window, oldest-first, for derived-table rebuilds — so a rebuild never scans
    /// the whole (now uncapped) history.
    ///
    /// When the day-history memo (`cachedAllDays`) is warm and migration is complete, the window is built
    /// from that in-memory cache (patched with the just-written `patching` day) — avoiding the per-save
    /// `loadRecent(370)` fetch + decode that defeated the memo on the hottest path. When the cache is cold
    /// or migration is still pending (rows aren't yet authoritative), it falls back to the row fetch,
    /// overlaying the just-written day so a not-yet-persisted-here edit still shows in the derived tables.
    private func recentDayPairs(patching: (dateKey: String, day: FernletDay)? = nil) -> [(String, FernletDay)] {
        if let cache = cachedAllDays, cachedDatabase?.daysMigratedToRows == true {
            var byKey = cache
            if let patching {
                byKey[patching.dateKey] = patching.day
            }
            return boundedRecentPairs(from: byKey)
        }
        var byKey = Dictionary(
            dayRecordRepository.loadRecent(limit: FernletLimits.derivedLogWindowDays).map { ($0.date, $0) },
            uniquingKeysWith: { _, new in new }
        )
        if let patching {
            byKey[patching.dateKey] = patching.day
        }
        return boundedRecentPairs(from: byKey)
    }

    /// The newest `derivedLogWindowDays` days from a day set, oldest-first — the derived tables and
    /// detection summary read this bounded window regardless of history depth.
    private func boundedRecentPairs(from byKey: [String: FernletDay]) -> [(String, FernletDay)] {
        byKey.keys.sorted(by: >)
            .prefix(FernletLimits.derivedLogWindowDays)
            .map { ($0, byKey[$0]!) }
            .sorted { $0.0 < $1.0 }
    }

    public func loadAllDays() -> [String: FernletDay] {
        if let cached = cachedAllDays { return cached }
        let database = loadDatabase(todayKey: FernletDate.dayKey(for: .now))  // ensure decoded + migration attempted
        var all = dayRecordRepository.loadAll()
        // Blob fallback (safety net for the not-fully-migrated state): if migration hasn't completed (a
        // failed batch leaves `daysMigratedToRows` false), a day may live ONLY in the blob with no row yet.
        // Overlay those blob-only days so history doesn't read short — mirroring loadDay/snapshot(from:).
        // Rows are authoritative where both exist, so only fill keys the row store is missing.
        // Post-migration `database.days` is empty, so this is a no-op there.
        if !database.daysMigratedToRows {
            for (key, day) in database.days where all[key] == nil {
                all[key] = day
            }
        }
        // Only memoize once migration has completed and the store is readable. Caching a partially-migrated
        // set (a failed batch leaves `daysMigratedToRows` false) would short-circuit the resume-on-next-load
        // and strand the un-backfilled days.
        if cachedDatabase?.daysMigratedToRows == true, !isPersistenceBlocked {
            cachedAllDays = all
        }
        return all
    }

    public func loadTierTwoMemories() -> [TierTwoMemoryRecord] {
        loadDatabase(todayKey: FernletDate.dayKey(for: .now)).tierTwoMemories
    }

    @discardableResult public func replaceTierTwoMemories(_ records: [TierTwoMemoryRecord]) -> Bool {
        var database = loadDatabase(todayKey: FernletDate.dayKey(for: .now))
        database.tierTwoMemories = records
        database.updatedAt = Date()
        return saveDatabase(database)
    }

    private func loadDatabase(todayKey: String) -> LocalFernletDatabase {
        assert(!todayKey.isEmpty, "today key required")

        if let cached = cachedDatabase {
            // Permanent lazy backfill: if a prior migration attempt didn't finish, retry on every load
            // until the rows are written (the flag flips true) — what makes retiring the blob safe.
            return cached.daysMigratedToRows ? cached : migrateDaysToRowsIfNeeded(cached)
        }

        // Stage 1: Check if a record exists at all.
        let record: NSManagedObject
        switch fetchRecordResult() {
        case .found(let fetchedRecord):
            record = fetchedRecord
        case .missing:
            // No record — first launch or fresh install. Migrate from legacy, then fan its days to rows.
            clearReadOnlyRecoveryFlags()
            var migrated = migrateDatabase(todayKey: todayKey)
            migrated = migrateDaysToRowsIfNeeded(migrated)
            if cachedDatabase == nil { _ = saveDatabase(migrated) }
            return migrated
        case .failed(let error):
            markPersistenceBlockedByFetchFailure(error)
            return LocalFernletDatabase()
        }

        // Stage 2: Record exists — attempt decode.
        guard let data = record.value(forKey: "payloadData") as? Data else {
            print("[Fernlet] Core Data record exists but payloadData is nil; entering read-only recovery mode.")
            markPersistenceBlockedByDecodeFailure()
            return LocalFernletDatabase()
        }

        do {
            let decoded = try StartupTiming.timed("CoreDataFernletRepository.loadDatabase.decode") {
                try decoder.decode(LocalFernletDatabase.self, from: data)
            }
            clearReadOnlyRecoveryFlags()
            let database = migrateDaysToRowsIfNeeded(decoded)
            if cachedDatabase == nil {
                cachedDatabase = database
                cachedRecordUpdatedAt = record.value(forKey: "updatedAt") as? Date
            }
            return database
        } catch {
            // Record exists but is corrupt. Do NOT overwrite with legacy data.
            print("[Fernlet] Core Data record decode failed; entering read-only recovery mode: \(error.localizedDescription)")
            markPersistenceBlockedByDecodeFailure()
            return LocalFernletDatabase()
        }
    }

    /// True while the aggregate store is in read-only recovery (a failed fetch/decode returned the empty
    /// fallback). Day-row writes are skipped in this state so a no-op save can't corrupt a day's row.
    private var isPersistenceBlocked: Bool {
        persistenceBlockedByDecodeFailure || persistenceBlockedByFetchFailure
    }

    /// Whether the snapshot most recently returned by `loadSnapshotAsync` / `loadSnapshot` is the
    /// EMPTY read-only-recovery fallback (a transient Core Data / CloudKit fetch or a payload decode
    /// failed), rather than real data. A remote-change reload MUST consult this before applying the
    /// returned snapshot over live in-memory state — applying the empty fallback blanks every screen
    /// until the next successful reload. The latch is cleared by the next successful load, so reading
    /// it immediately after a load reflects that load's outcome.
    public var isInReadOnlyRecovery: Bool { isPersistenceBlocked }

    private func markPersistenceBlockedByDecodeFailure() {
        persistenceBlockedByDecodeFailure = true
        cachedDatabase = nil
        cachedAllDays = nil
        cachedRecordUpdatedAt = nil
    }

    private func markPersistenceBlockedByFetchFailure(_ error: Error) {
        persistenceBlockedByFetchFailure = true
        cachedDatabase = nil
        cachedAllDays = nil
        print("[Fernlet] Core Data record fetch failed; entering read-only recovery mode: \(error.localizedDescription)")
    }

    /// Clears the read-only recovery latches once the store is readable again. A transient
    /// fetch/decode failure must not permanently block saves for the rest of the session:
    /// the latches only need to hold while the in-memory state may be a failure fallback.
    private func clearReadOnlyRecoveryFlags() {
        persistenceBlockedByDecodeFailure = false
        persistenceBlockedByFetchFailure = false
    }

    /// Erases every persisted day row, the snapshot blob record, the legacy JSON store, and every
    /// in-memory memo of them.
    ///
    /// All three stores must go together. The per-row `DayRecord` store is the authoritative source of
    /// truth, so clearing only the blob leaves the whole history intact; clearing only the rows leaves
    /// the blob's `days` cache to repopulate them; and leaving the legacy JSON file behind lets the
    /// blob→row migration re-seed rows from it on a later launch. The memos must be dropped too, or the
    /// next read serves the data we just deleted straight back.
    ///
    /// When iCloud sync is on, these deletions propagate as ordinary CloudKit deletes.
    @discardableResult public func purgeAllPersistedData() -> Bool {
        var succeeded = dayRecordRepository.deleteAll()

        let context = controller.container.viewContext
        let request = NSFetchRequest<NSManagedObject>(entityName: "FernletDatabaseRecord")
        do {
            for record in try context.fetch(request) { context.delete(record) }
            if context.hasChanges { try context.save() }
        } catch {
            assertionFailure("database record purge failed")
            context.rollback()
            succeeded = false
        }

        if !legacyRepository.purgeAllPersistedData() { succeeded = false }

        cachedDatabase = nil
        cachedRecordUpdatedAt = nil
        cachedAllDays = nil
        // A decode/fetch failure earlier in the session latches writes off. The stores are empty now, so
        // the latch must clear or the user could not save anything after wiping.
        persistenceBlockedByDecodeFailure = false
        persistenceBlockedByFetchFailure = false
        return succeeded
    }

    @discardableResult private func saveDatabase(_ database: LocalFernletDatabase, invalidatesDayCache: Bool = true) -> Bool {
        assert(database.schemaVersion >= 1, "schema version invalid")
        // Most saves (migration, tier-2 memories) may have changed the day history underneath the memo, so
        // drop it — the next read re-decodes the fresh rows. saveSnapshot/updateDay instead patch the memo
        // in place for the single day they wrote (item H) and pass `invalidatesDayCache: false`, so a normal
        // save no longer re-fetches and re-decodes the whole (uncapped) history on the hot path.
        if invalidatesDayCache {
            cachedAllDays = nil
        }
        guard !persistenceBlockedByDecodeFailure else {
            print("[Fernlet] Refusing to save after Core Data database decode failed.")
            return false
        }
        guard !persistenceBlockedByFetchFailure else {
            print("[Fernlet] Refusing to save after Core Data record fetch failed.")
            return false
        }
        guard let data = try? encoder.encode(database) else {
            assertionFailure("Core Data database encode failed")
            return false
        }

        let context = controller.container.viewContext
        let record: NSManagedObject
        switch fetchRecordResult() {
        case .found(let fetchedRecord):
            record = fetchedRecord
        case .missing:
            record = NSEntityDescription.insertNewObject(
                forEntityName: "FernletDatabaseRecord",
                into: context
            )
        case .failed(let error):
            markPersistenceBlockedByFetchFailure(error)
            return false
        }
        record.setValue(Self.primaryRecordID, forKey: "recordID")
        record.setValue(data, forKey: "payloadData")
        record.setValue(Date(), forKey: "updatedAt")

        do {
            if context.hasChanges {
                try context.save()
            }
            cachedDatabase = database  // Update cache with known-good state
            cachedRecordUpdatedAt = record.value(forKey: "updatedAt") as? Date
            return true
        } catch {
            assertionFailure("Core Data database save failed")
            context.rollback()
            cachedDatabase = nil  // Invalidate on failure
            cachedAllDays = nil   // …and the day memo, so a caller that patched it in place re-reads fresh
            return false
        }
    }

    private func fetchRecordUpdatedAt() -> Date? {
        switch fetchRecordResult() {
        case .found(let record):
            return record.value(forKey: "updatedAt") as? Date
        case .missing:
            return nil
        case .failed(let error):
            markPersistenceBlockedByFetchFailure(error)
            return cachedRecordUpdatedAt
        }
    }

    private enum FetchRecordResult {
        case found(NSManagedObject)
        case missing
        case failed(Error)
    }

    private func fetchRecordResult() -> FetchRecordResult {
        if let forcedFetchFailureForTesting {
            self.forcedFetchFailureForTesting = nil
            return .failed(forcedFetchFailureForTesting)
        }

        let context = controller.container.viewContext
        let request = NSFetchRequest<NSManagedObject>(entityName: "FernletDatabaseRecord")
        request.predicate = NSPredicate(format: "recordID == %@", Self.primaryRecordID)
        request.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: false)]
        do {
            let records = try context.fetch(request)
            guard let primary = records.first else { return .missing }
            // Remove duplicate records that can form when two devices first launch before
            // their initial CloudKit import settles. The oldest duplicates are deleted
            // in-context; they will be removed from the store on the next context.save().
            if records.count > 1 {
                records.dropFirst().forEach { context.delete($0) }
            }
            return .found(primary)
        } catch {
            return .failed(error)
        }
    }

    private func migrateDatabase(todayKey: String) -> LocalFernletDatabase {
        assert(!todayKey.isEmpty, "today key required")
        return legacyRepository.loadDatabaseForMigration(todayKey: todayKey)
    }

    private func snapshot(from database: LocalFernletDatabase, todayKey: String) -> FernletSnapshot {
        // Today's day comes from its row (the authoritative day store). While migration is incomplete (a
        // failed/lagging backfill leaves `daysMigratedToRows` false) the row may not be written yet, so fall
        // back to the blob's copy — which still holds the day until migration clears `days` — before
        // returning an empty day. Otherwise an empty today would surface and the next save would clobber the
        // real entries. Post-migration `database.days` is empty, so this fallback is a no-op there.
        let day = dayRecordRepository.load(dateKeys: [todayKey])[todayKey]
            ?? database.days[todayKey]
            ?? FernletDay(date: todayKey)
        return FernletSnapshot(
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

    /// A coarse count of logged items on a day, used ONLY as the migration content-merge tiebreak (item D)
    /// when two same-day copies compete and the legacy blob has no per-day freshness stamp. Counts discrete
    /// entries plus one point each for sleep, water, and real HealthKit content — enough to tell "richer"
    /// from "sparser" without needing FernletDay to be Equatable. Not a durability metric; a heuristic.
    nonisolated private static func loggedContentCount(_ day: FernletDay) -> Int {
        day.meals.count + day.workouts.count + day.plannedWorkouts.count + day.journals.count
            + day.hygiene.count + day.completedPersonalCareTaskIDs.count
            + (day.sleep == nil ? 0 : 1)
            + (day.bottleCount > 0 ? 1 : 0)
            + ((day.healthContext?.hasContent ?? false) ? 1 : 0)
    }

    nonisolated private static func decodeDatabaseAsync(from data: Data) async throws -> LocalFernletDatabase {
        let signpostID = StartupTiming.begin("CoreDataFernletRepository.loadDatabase.decode.async")
        defer { StartupTiming.end("CoreDataFernletRepository.loadDatabase.decode.async", signpostID: signpostID) }

        let decoder = RowPayloadCoders.makeDecoder()
        return try decoder.decode(LocalFernletDatabase.self, from: data)
    }
}
