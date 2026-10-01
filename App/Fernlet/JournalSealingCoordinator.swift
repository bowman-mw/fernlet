import CryptoKit
import FernletFoundation
import Foundation
import FernletDomainModel
import PrivateMemoryStore
import HealthKitGateway

/// The state the journal-sealing flow reads/mutates on the app store.
///
/// Mirrors the `WorkoutSyncContext` host-protocol pattern so ``JournalSealingCoordinator`` depends
/// on this seam rather than the concrete ``FernletStore`` (plan §5d), which is its only production
/// conformer; tests supply fakes. Main-actor isolated because the coordinator mutates the host's
/// live `day`/`previousJournals` in place.
@MainActor
protocol JournalSealingContext: AnyObject {
    var day: FernletDay { get set }
    var previousJournals: [JournalEntry] { get set }
    var todayKey: String { get }
    func scheduleSnapshotSave()
    /// Re-arm the one-time past-day journal scrub (clear its run-once flag + retry budget) so the next
    /// activation/launch re-scans ALL days. Called when a per-entry seal/re-seal fails so an aged-out day's
    /// leaked plaintext — outside the in-memory `previousJournals` window that the per-activation migrate
    /// visits — is eventually re-sealed and stripped instead of lingering in the synced blob forever (F1).
    func requestPastDayJournalRescrub()
    /// A sealed journal row was written, re-sealed or deleted: the journal Sealed backup's upload is
    /// owed (journal and intimacy Sealed backup v2 design 2026-09-30, §4.4), so the next hub settle
    /// re-exports it. Called after every narrative-store mutation this coordinator makes — the seal,
    /// the re-seal, the delete (success or not: the skeleton goes either way, so the export must drop
    /// the entry), the migration and the past-day scrub when they inserted — but NOT after the
    /// device-key fold, which changes ciphertext only (the backup reads both keys, §7.2).
    func sealedJournalStoreDidChange()
}

/// Sealed journal management (Phase S2), extracted from ``FernletStore`` (plan §5d).
///
/// Owns the journal content key, the device fallback key (Keychain), the sealed-entry ID set, and
/// the `JournalNarrativeRepository` — keeping the journal-text sealing store + keychain off the
/// store/core path. The store delegates its journal mutation + snapshot paths here; ``isSealed(_:)``
/// drives the snapshot text-strip.
///
/// Key invariants:
/// - Journal text never reaches the iCloud-synced days blob in plaintext while it has a sealed
///   narrative row: an id in ``sealedJournalIDs`` is stripped by `FernletSnapshot.forStorage` /
///   `mutatePastDay`, and a seal/re-seal FAILURE deliberately keeps the id OUT of the set so the
///   plaintext survives in the blob (bounded transient exposure) rather than being blanked against
///   a missing or stale narrative — no data loss, ever.
/// - While the Private tab is closed (with or without a passcode) entries are sealed under a
///   device-bound Keychain key, so the blob never carries journal text; the next time the tab opens,
///   EVERY such row is folded under the tab's content key (period-data design 2026-09-30, §9.17).
/// - Tag-only mood check-ins (empty text) are never sealed, keeping "empty text + no narrative
///   row" unambiguous; see ``canIdentifyTagOnlyEntries`` for the locked-state caveat.
///
/// Failure recovery is two-tier: the per-activation migration re-seals today + `previousJournals`,
/// and ``JournalSealingContext/requestPastDayJournalRescrub()`` re-arms the full-repository
/// past-day scrub (``scrubbedLeakedPastDayJournals(in:)``) for leaks outside that window. Main-actor
/// isolated; the host is held `unowned` because ``FernletStore`` owns the coordinator.
@MainActor
final class JournalSealingCoordinator {
    /// The lock-lifecycle mode the coordinator was last activated into, which decides the active
    /// key: none (inactive/closed) or the Private tab's content key (open, by passcode or by tap).
    ///
    /// There is no device-key READ mode any more: the no-passcode Private tab has a content key of
    /// its own, so "no lock" no longer means "hydrate under the device key everywhere" — the device
    /// key is only the write fallback while the tab is closed (period-data design 2026-09-30, §9.17).
    ///
    /// Set only by the activate/deactivate lifecycle calls; `activeJournalRefreshKey()` and
    /// ``canIdentifyTagOnlyEntries`` are its two readers.
    private enum JournalActivationMode {
        case inactive
        case sealedUnlocked
        case sealedLocked
    }

    private unowned let host: any JournalSealingContext
    private let narrativeRepository: any JournalNarrativeStoring

    /// Content key available while the Private tab is open; nil when closed.
    private var journalContentKey: SymmetricKey?
    private var journalActivationMode: JournalActivationMode = .inactive
    /// Device-key rows are folded at most once per process session unless a new device-key write
    /// occurs (or a fold left rows behind). Content-key rows do not open under the device key, so
    /// rescanning them on every open only repeats the walk.
    private var deviceKeyMigrationPending = true
    /// IDs of journal entries whose text is sealed in JournalNarrativeRepository.
    /// Used by the store's `currentSnapshot()` to strip text before persisting to the cloud blob.
    /// Readable by the store (passed to `FernletSnapshot.forStorage`); mutation stays here.
    private(set) var sealedJournalIDs: Set<UUID> = []

    /// Creates the coordinator over its host seam (held `unowned`) and the sealed narrative store.
    init(host: any JournalSealingContext, narrativeRepository: any JournalNarrativeStoring) {
        self.host = host
        self.narrativeRepository = narrativeRepository
    }

    /// Whether the entry's text is sealed in the narrative store (so the snapshot strips it).
    func isSealed(_ id: UUID) -> Bool { sealedJournalIDs.contains(id) }

    /// True while the content key is active (the Private tab is open): sealed entries are hydrated
    /// with their text, so an EMPTY-text entry in memory is genuinely a tag-only mood check-in. While
    /// closed/inactive, stripped sealed entries also sit in memory with empty text — a tag-only
    /// check-in is indistinguishable from them, and callers (e.g. the one-tap mood row's
    /// update-in-place) must fall back to appending instead of mutating what might be a real entry.
    var canIdentifyTagOnlyEntries: Bool {
        switch journalActivationMode {
        case .sealedUnlocked: true
        case .inactive, .sealedLocked: false
        }
    }

    // MARK: - Activation (lock lifecycle)

    /// Call when the Private tab opens (by passcode or by tap): folds every device-key-sealed entry
    /// under the content key, sets the key, populates in-memory journal text from the sealed store,
    /// and migrates legacy plaintext entries.
    func activateSealedJournals(contentKey: SymmetricKey) {
        journalContentKey = contentKey
        journalActivationMode = .sealedUnlocked
        migrateDeviceKeyEntriesToUserKey(userKey: contentKey)
        refreshSealedJournals(contentKey: contentKey)
        migrateExistingJournalsToSealedStore(contentKey: contentKey)
    }

    /// Call on lock: scrubs in-memory journal text for sealed entries and clears the key.
    func deactivateSealedJournals() {
        let ids = sealedJournalIDs
        if !ids.isEmpty {
            host.day.journals = host.day.journals.map { entry in
                guard ids.contains(entry.id) else { return entry }
                return JournalEntry(id: entry.id, text: "", tag: entry.tag, date: entry.date, emotions: [])
            }
            host.previousJournals = host.previousJournals.map { entry in
                guard ids.contains(entry.id) else { return entry }
                return JournalEntry(id: entry.id, text: "", tag: entry.tag, date: entry.date, emotions: [])
            }
            sealedJournalIDs.removeAll()
        }
        journalContentKey = nil
        journalActivationMode = .sealedLocked
    }

    // MARK: - Per-entry sealing (called from the diary mutation paths)

    /// Seals a journal entry into JournalNarrativeRepository.
    /// Uses the user content key when a lock is configured; falls back to the device key so that
    /// journal text is never written to the iCloud-synced blob even without a lock.
    func seal(_ entry: JournalEntry, dayKey: String) {
        // Tag-only mood check-ins (empty text) are deliberately NOT sealed: there is nothing to
        // protect (the tag stays plaintext by design, NEW-4), and keeping them out of both the
        // narrative store and `sealedJournalIDs` keeps "empty text" unambiguous — an empty
        // in-memory entry with no narrative row IS a mood check-in, not a stripped sealed entry.
        // (Hydration paths already skip ids with no narrative row, so nothing downstream changes.)
        guard !entry.text.isEmpty else { return }
        // No key obtainable ⇒ take the identical recovery the insert-failure path below documents:
        // the id stays out of `sealedJournalIDs`, so the plaintext is preserved in the days blob and
        // re-sealed by `migrateExistingJournalsToSealedStore` on the next activation, with the
        // past-day rescrub re-armed for days outside the in-memory window.
        guard let key = journalContentKey ?? deviceJournalKey else {
            // `reason`, not `error`: no call threw here, and the audit line is the ONLY record this
            // path leaves. Naming the cause is what lets a triage tell "there was no key to seal
            // under" apart from "the seal itself refused" below — the same split
            // `updateSealedNarrative`'s guard already makes with its `noContentKey`.
            FernletAuditLog.log("journal.seal.failed",
                                context: ["id": entry.id.uuidString, "reason": "noContentKey"])
            host.requestPastDayJournalRescrub()
            return
        }
        let narrative = JournalNarrative(
            id: entry.id, dayKey: dayKey, tag: entry.tag, entryDate: entry.date,
            text: entry.text, emotions: entry.emotions,
            createdAt: entry.date, updatedAt: entry.date
        )
        do {
            try narrativeRepository.insert(narrative, contentKey: key)
            sealedJournalIDs.insert(entry.id)
            if journalContentKey == nil { deviceKeyMigrationPending = true }
            host.sealedJournalStoreDidChange()
        } catch {
            // Carry the error (the `String(describing:)` form every peer audit line uses, e.g.
            // `mesh.encryptedMetadata.sealFailed`). This is the only record the exposure window
            // documented below ever leaves, and the causes it has to keep apart are not
            // interchangeable: a sealed-store insert failure is a storage fault, while
            // `SealedColumnStrictSealError.bindingUnavailable` is the seal REFUSING to mint a
            // device-bound blob — a cause that only became reachable when owner decision D4 closed
            // the writer's legacy fallback, and that previously landed here as a silent success.
            // Without the cause, "why did journal plaintext appear in the synced blob?" has no
            // answer in the trail. The event NAME stays the frozen token it has always been.
            FernletAuditLog.log("journal.seal.failed",
                                context: ["id": entry.id.uuidString, "error": String(describing: error)])
            // Do NOT add the entry to sealedJournalIDs on failure. Because the id is then absent from
            // the sealed set, FernletSnapshot.forStorage / mutatePastDay do NOT strip the entry, so its
            // plaintext stays in the days blob — which is plain JSON and, when iCloud sync is on, mirrors
            // to iCloud. We accept that bounded transient exposure to avoid data loss: the text is never
            // dropped. Recovery: migrateExistingJournalsToSealedStore re-seals today + previousJournals on
            // the next activation; AND we re-arm the full-repository past-day scrub so a leak on a day
            // OUTSIDE that in-memory window (which migrate never visits) is also re-sealed and re-stripped
            // on a later launch — rather than lingering forever (F1).
            host.requestPastDayJournalRescrub()
        }
    }

    /// Re-seals an edited entry's narrative when it is already sealed and a key is available.
    func updateSealedNarrative(for entry: JournalEntry, text trimmed: String, tag: FeelingTag, dayKey: String) {
        guard sealedJournalIDs.contains(entry.id) else { return }
        guard let key = activeJournalRefreshKey() else {
            // Same hazard as the `catch` below, reached a different way. Since the device key now
            // fails CLOSED on an unreadable keychain row, this guard can fire for an entry that IS
            // sealed — and simply returning would leave the id in sealedJournalIDs, so the snapshot /
            // past-day strip would blank the entry against the now-STALE narrative and silently
            // destroy the edit the user just made. Fail the way the catch does: drop the id so the
            // new plaintext survives in the blob, and re-arm the scrub to re-seal it later.
            FernletAuditLog.log("journal.reseal.failed",
                                context: ["id": entry.id.uuidString, "reason": "noContentKey"])
            sealedJournalIDs.remove(entry.id)
            host.requestPastDayJournalRescrub()
            return
        }
        let updated = JournalNarrative(
            id: entry.id, dayKey: dayKey, tag: tag, entryDate: entry.date,
            text: trimmed, emotions: entry.emotions,
            createdAt: entry.date, updatedAt: Date()
        )
        do {
            try narrativeRepository.update(updated, contentKey: key)
            host.sealedJournalStoreDidChange()
        } catch {
            // Re-seal failed. If the id stayed in sealedJournalIDs, the snapshot / past-day strip would
            // blank this entry against the now-STALE narrative copy — silently destroying the user's edit.
            // Instead drop the id (mirroring seal()'s no-data-loss policy): the new plaintext survives in
            // the blob. Recovery for an aged-out day (outside the in-memory previousJournals window that
            // migrateExistingJournalsToSealedStore visits) is the re-armed full-repository scrub, whose
            // insert-upsert overwrites the stale narrative with the blob's current text and re-strips it on
            // a later launch. Bounded transient exposure, but the edit is never lost (F1/F4).
            // Same reasoning as `seal()`'s catch: the id alone cannot say WHICH failure re-opened
            // the exposure window, and this catch's own recovery (drop the id, re-arm the scrub)
            // reads identically whether the store faulted or the seal refused.
            FernletAuditLog.log("journal.reseal.failed",
                                context: ["id": entry.id.uuidString, "error": String(describing: error)])
            sealedJournalIDs.remove(entry.id)
            host.requestPastDayJournalRescrub()
        }
    }

    /// Deletes a sealed narrative and forgets its sealed-ID.
    func deleteSealed(id: UUID) {
        do {
            try narrativeRepository.delete(id: id)
        } catch {
            // The entry is leaving the days blob either way, so the id is dropped from
            // `sealedJournalIDs` in both paths; what is left behind is an ENCRYPTED orphan row in the
            // narrative store (never plaintext), which no read path can reach again.
            FernletAuditLog.log("journal.deleteSealed.failed", context: ["id": id.uuidString])
        }
        sealedJournalIDs.remove(id)
        // Success or not: the entry's skeleton leaves the day either way, so the next export must drop
        // it (an orphan row is never exported, design 2026-09-30 §7.1).
        host.sealedJournalStoreDidChange()
    }

    // MARK: - Hydration (read paths)

    /// Returns `day` with empty-text journal entries hydrated from the sealed store (when unlocked).
    func hydratingDecryptedJournals(into day: FernletDay, dateKey: String) -> FernletDay {
        var loaded = day
        let emptyEntries = loaded.journals.filter { $0.text.isEmpty }
        guard !emptyEntries.isEmpty, let key = activeJournalRefreshKey() else { return loaded }
        let narratives = loadNarratives("hydrateDay") {
            try narrativeRepository.narratives(forDayKey: dateKey, contentKey: key)
        }
        let byID = Dictionary(narratives.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        loaded.journals = loaded.journals.map { entry in
            guard entry.text.isEmpty, let n = byID[entry.id] else { return entry }
            // Record the id as sealed (S3): this past-day read decrypts text that lives ONLY in the
            // narrative store, so the entry is genuinely sealed. `refreshSealedJournals` does the same
            // for today + previousJournals; doing it here too keeps the two read paths symmetric.
            // Without it, an entry on a day older than the previousJournals window is absent from
            // `sealedJournalIDs`, and a later edit would (a) skip the `mutatePastDay` strip and leak the
            // new plaintext into the (iCloud-synced) blob, and (b) skip the `updateSealedNarrative`
            // re-seal, leaving the sealed store stale (F1, Docs/Security-Hardening-Plan-2026-06-27.md).
            sealedJournalIDs.insert(entry.id)
            return JournalEntry(id: entry.id, text: n.text, tag: entry.tag, date: entry.date, emotions: n.emotions)
        }
        return loaded
    }

    /// After a snapshot reload, re-hydrate sealed journal text if a key is active.
    func refreshAfterSnapshotApply() {
        guard let key = activeJournalRefreshKey() else { return }
        refreshSealedJournals(contentKey: key)
    }

    // MARK: - Private helpers

    private func activeJournalRefreshKey() -> SymmetricKey? {
        switch journalActivationMode {
        case .inactive, .sealedLocked:
            return nil
        case .sealedUnlocked:
            return journalContentKey
        }
    }

    /// Device-bound key generated on first use and stored in Keychain (not iCloud-synced).
    /// Used to seal journal text while the Private tab is closed, ensuring text never reaches the blob.
    ///
    /// Nil when the keychain row exists but could not be read (a transient failure, or a read before
    /// the first post-boot unlock) — the helper fails closed rather than minting over a key it could
    /// not read, which would destroy every sealed entry. Every caller here treats nil as "no key this
    /// instant": no hydration, no seal, no rekey. The property is recomputed on each access, so the
    /// next attempt after unlock succeeds.
    private var deviceJournalKey: SymmetricKey? {
        KeychainItem.loadOrCreateSymmetricKey(for: .deviceJournalKey, service: KeychainItem.journalService)
    }

    /// Folds EVERY row sealed under the device key (written while the Private tab was closed — from
    /// Home, or before any key existed) under the content key, in the repository's bounded pages.
    ///
    /// The whole table, not a window: the fold this replaced re-keyed only today and the in-memory
    /// `previousJournals` days, so an older entry written from Home stayed under the device key and
    /// never showed in the hub (period-data design 2026-09-30, §9.17). Rows already under the content
    /// key do not open under the device key and are skipped. Anything left behind (a read, a re-seal
    /// or a save that failed) keeps its device-key copy and leaves the fold pending for the next open
    /// — a deferral, never a loss.
    private func migrateDeviceKeyEntriesToUserKey(userKey: SymmetricKey) {
        guard deviceKeyMigrationPending else { return }
        // No device key readable this instant ⇒ nothing can be decrypted to re-key. Pending remains
        // true, so a later journal activation retries; this is a deferral, not a loss.
        guard let dKey = deviceJournalKey else {
            FernletAuditLog.log("journal.rekey.failed", context: [:])
            return
        }
        do {
            let failed = try narrativeRepository.reencryptAll(from: dKey, to: userKey)
            guard failed == 0 else {
                FernletAuditLog.log("journal.rekey.incomplete", context: ["failed": String(failed)])
                return
            }
            deviceKeyMigrationPending = false
        } catch {
            FernletAuditLog.log("journal.rekey.failed", context: ["error": "\(type(of: error))"])
        }
    }

    /// Reads sealed narratives, naming a decrypt/read failure instead of letting it read as "no rows".
    ///
    /// The `[]` fallback is deliberate (nothing hydrates — fail closed, never a plaintext fallback);
    /// the audit line is what distinguishes a failed read from an empty day.
    private func loadNarratives(_ context: String,
                                _ read: () throws -> [JournalNarrative]) -> [JournalNarrative] {
        do {
            return try read()
        } catch {
            FernletAuditLog.log("journal.read.failed", context: ["where": context])
            return []
        }
    }

    /// Loads decrypted text from the sealed store into in-memory journal entries that have empty text.
    private func refreshSealedJournals(contentKey: SymmetricKey) {
        // Today's journals
        let emptyToday = host.day.journals.filter { $0.text.isEmpty }
        if !emptyToday.isEmpty {
            let narratives = loadNarratives("refreshToday") {
                try narrativeRepository.narratives(forDayKey: host.todayKey, contentKey: contentKey)
            }
            let byID = Dictionary(narratives.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            host.day.journals = host.day.journals.map { entry in
                guard entry.text.isEmpty, let n = byID[entry.id] else { return entry }
                sealedJournalIDs.insert(entry.id)
                return JournalEntry(id: entry.id, text: n.text, tag: entry.tag, date: entry.date, emotions: n.emotions)
            }
        }

        // Cross-day previousJournals
        let emptyPrevious = host.previousJournals.filter { $0.text.isEmpty }
        if !emptyPrevious.isEmpty {
            let dayKeys = Array(Set(emptyPrevious.map { FernletDate.dayKey(for: $0.date) }))
            let narratives = loadNarratives("refreshPrevious") {
                try narrativeRepository.narratives(forDayKeys: dayKeys, contentKey: contentKey)
            }
            let byID = Dictionary(narratives.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            host.previousJournals = host.previousJournals.map { entry in
                guard entry.text.isEmpty, let n = byID[entry.id] else { return entry }
                sealedJournalIDs.insert(entry.id)
                return JournalEntry(id: entry.id, text: n.text, tag: entry.tag, date: entry.date, emotions: n.emotions)
            }
        }
    }

    /// One-time migration: seals legacy journal entries that still have plaintext in the blob,
    /// then schedules a save so the stripped version is persisted.
    private func migrateExistingJournalsToSealedStore(contentKey: SymmetricKey) {
        var anyMigrated = false

        for entry in host.previousJournals where !entry.text.isEmpty && !sealedJournalIDs.contains(entry.id) {
            let dayKey = FernletDate.dayKey(for: entry.date)
            let narrative = JournalNarrative(
                id: entry.id, dayKey: dayKey, tag: entry.tag, entryDate: entry.date,
                text: entry.text, emotions: entry.emotions,
                createdAt: entry.date, updatedAt: entry.date
            )
            do {
                try narrativeRepository.insert(narrative, contentKey: contentKey)
                sealedJournalIDs.insert(entry.id)
                anyMigrated = true
            } catch {
                // Plaintext is preserved (no data loss, exactly like `seal()`'s catch); the entry is
                // simply not marked sealed, so the next activation tries this migration again.
                FernletAuditLog.log("journal.migrate.seal.failed", context: ["id": entry.id.uuidString])
            }
        }

        for entry in host.day.journals where !entry.text.isEmpty && !sealedJournalIDs.contains(entry.id) {
            let narrative = JournalNarrative(
                id: entry.id, dayKey: host.todayKey, tag: entry.tag, entryDate: entry.date,
                text: entry.text, emotions: entry.emotions,
                createdAt: entry.date, updatedAt: entry.date
            )
            do {
                try narrativeRepository.insert(narrative, contentKey: contentKey)
                sealedJournalIDs.insert(entry.id)
                anyMigrated = true
            } catch {
                // Plaintext is preserved (no data loss, exactly like `seal()`'s catch); the entry is
                // simply not marked sealed, so the next activation tries this migration again.
                FernletAuditLog.log("journal.migrate.seal.failed", context: ["id": entry.id.uuidString])
            }
        }

        if anyMigrated {
            // Trigger a save so the stripped (empty-text) version replaces the plaintext in the blob.
            host.scheduleSnapshotSave()
            host.sealedJournalStoreDidChange()
        }
    }

    // MARK: - One-time historical scrub (WI-1)

    /// Outcome of one `scrubbedLeakedPastDayJournals` pass.
    /// - `changedDays`: the days whose blob actually changed, so the caller re-persists *only* those.
    /// - `unsealedFailureCount`: how many leaked entries could NOT be sealed this pass (their plaintext was
    ///   deliberately preserved — no data loss). A non-zero count tells the orchestrator NOT to mark the
    ///   one-time scrub complete, so a later launch retries exactly those still-plaintext days (WI1-1).
    struct PastDayScrubOutcome {
        var changedDays: [String: FernletDay]
        var unsealedFailureCount: Int
        /// False when no journal key was active (locked/inactive), so the scan could not actually run. Lets
        /// the orchestrator distinguish a genuine clean pass from a no-key no-op and NOT advance the
        /// run-once flag on the latter (which would permanently disable the scrub).
        var keyActive: Bool
    }

    /// One-time scrub of historical past-day journals that leaked plaintext into the days blob before
    /// the past-day strip (`DiaryStore.mutatePastDay`) existed. `migrateExistingJournalsToSealedStore`
    /// only scans today + `previousJournals`, and `FernletSnapshot.forStorage` only sanitises today, so a
    /// journal written to a now-old day before the fix is never re-stripped and its plaintext lingers in
    /// the (iCloud-synced) blob.
    ///
    /// For each day's journal entries that still carry text, this seals the text into the narrative store
    /// (keyed by the day's key — matching the `seal`/`hydratingDecryptedJournals` convention so reads
    /// re-hydrate) and reports the day with those entries blanked via the shared `strippedIfSealed` helper.
    /// Only days whose blob actually changed are returned in `changedDays`.
    ///
    /// No-op (empty outcome) when no key is active (locked/inactive). `host.todayKey` is skipped — the
    /// snapshot path already owns today. An entry whose seal fails keeps its text (no data loss), exactly
    /// like `seal()`'s catch and `migrateExistingJournalsToSealedStore`; it is also tallied into
    /// `unsealedFailureCount` so the orchestrator can retry it on a later launch instead of giving up after
    /// the first pass (re-running is cheap: already-sealed days now have empty text and are skipped).
    func scrubbedLeakedPastDayJournals(in allDays: [String: FernletDay]) -> PastDayScrubOutcome {
        guard let key = activeJournalRefreshKey() else {
            return PastDayScrubOutcome(changedDays: [:], unsealedFailureCount: 0, keyActive: false)
        }
        var changed: [String: FernletDay] = [:]
        var unsealedFailureCount = 0
        var insertedAny = false
        for (dayKey, day) in allDays where dayKey != host.todayKey {
            var journals = day.journals
            var mutated = false
            for index in journals.indices where !journals[index].text.isEmpty {
                let entry = journals[index]
                if !sealedJournalIDs.contains(entry.id) {
                    let narrative = JournalNarrative(
                        id: entry.id, dayKey: dayKey, tag: entry.tag, entryDate: entry.date,
                        text: entry.text, emotions: entry.emotions,
                        createdAt: entry.date, updatedAt: entry.date
                    )
                    guard (try? narrativeRepository.insert(narrative, contentKey: key)) != nil else {
                        // Seal failed: preserve the plaintext (no data loss) but record the failure so the
                        // orchestrator leaves the run-once flag unset and retries this day on a later launch.
                        unsealedFailureCount += 1
                        continue
                    }
                    sealedJournalIDs.insert(entry.id)
                    insertedAny = true
                }
                journals[index] = entry.strippedIfSealed(in: sealedJournalIDs)
                mutated = true
            }
            if mutated {
                var scrubbed = day
                scrubbed.journals = journals
                changed[dayKey] = scrubbed
            }
        }
        if insertedAny { host.sealedJournalStoreDidChange() }
        return PastDayScrubOutcome(changedDays: changed, unsealedFailureCount: unsealedFailureCount, keyActive: true)
    }
}
