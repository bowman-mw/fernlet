import CryptoKit
import FernletFoundation
import Foundation
import FernletDomainModel
import PrivateMemoryStore
import HealthKitGateway

/// The state the journal-sealing flow reads/mutates on the app store. Mirrors the
/// `WorkoutSyncContext` host-protocol pattern so `JournalSealingCoordinator` depends
/// on this seam rather than the concrete `FernletStore` (plan §5d).
@MainActor
protocol JournalSealingContext: AnyObject {
    var day: FernletDay { get set }
    var previousJournals: [JournalEntry] { get set }
    var todayKey: String { get }
    func scheduleSnapshotSave()
}

/// Sealed journal management (Phase S2), extracted from `FernletStore` (plan §5d).
/// Owns the journal content key, the device fallback key (Keychain), the sealed-entry
/// ID set, and the `JournalNarrativeRepository` — keeping the journal-text sealing
/// store + keychain off the store/core path. The store delegates its journal mutation
/// + snapshot paths here; `isSealed` drives the snapshot text-strip.
@MainActor
final class JournalSealingCoordinator {
    private enum JournalActivationMode {
        case inactive
        case noLock
        case sealedUnlocked
        case sealedLocked
    }

    private unowned let host: any JournalSealingContext
    private let narrativeRepository: any JournalNarrativeStoring

    /// Content key available while the lock is open; nil when locked.
    private var journalContentKey: SymmetricKey?
    private var journalActivationMode: JournalActivationMode = .inactive
    /// IDs of journal entries whose text is sealed in JournalNarrativeRepository.
    /// Used by the store's `currentSnapshot()` to strip text before persisting to the cloud blob.
    /// Readable by the store (passed to `FernletSnapshot.forStorage`); mutation stays here.
    private(set) var sealedJournalIDs: Set<UUID> = []

    init(host: any JournalSealingContext, narrativeRepository: any JournalNarrativeStoring) {
        self.host = host
        self.narrativeRepository = narrativeRepository
    }

    /// The (private) journal content key, surfaced for the sealed period-data backup.
    var contentKey: SymmetricKey? { journalContentKey }

    /// Whether the entry's text is sealed in the narrative store (so the snapshot strips it).
    func isSealed(_ id: UUID) -> Bool { sealedJournalIDs.contains(id) }

    // MARK: - Activation (lock lifecycle)

    /// Call at startup when no lock is configured: seals any legacy plaintext blob entries
    /// with the device key and populates in-memory journal text from the device-key-sealed store.
    func activateNoLockJournals() {
        journalActivationMode = .noLock
        let key = deviceJournalKey
        migrateExistingJournalsToSealedStore(contentKey: key)
        refreshSealedJournals(contentKey: key)
    }

    /// Call on unlock: migrates any device-key-sealed entries, sets the content key,
    /// populates in-memory journal text from the sealed store, and migrates legacy plaintext entries.
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
        let key = journalContentKey ?? deviceJournalKey
        let narrative = JournalNarrative(
            id: entry.id, dayKey: dayKey, tag: entry.tag, entryDate: entry.date,
            text: entry.text, emotions: entry.emotions,
            createdAt: entry.date, updatedAt: entry.date
        )
        do {
            try narrativeRepository.insert(narrative, contentKey: key)
            sealedJournalIDs.insert(entry.id)
        } catch {
            print("[Fernlet] Journal sealing failed for \(entry.id): \(error)")
            // Do NOT add the entry to sealedJournalIDs on failure. Leaving it unsealed keeps
            // its plaintext in the local snapshot (so the user's text is never lost) and lets
            // migrateExistingJournalsToSealedStore (run from activateNoLockJournals /
            // activateSealedJournals on the next launch or unlock) retry sealing it, since it
            // targets exactly `!text.isEmpty && !sealedJournalIDs.contains(id)` entries.
            // We prioritise no-data-loss over the rare transient case where the text briefly
            // remains in the user's own (already-encrypted) private store instead of the
            // app-sealed narrative store.
        }
    }

    /// Re-seals an edited entry's narrative when it is already sealed and a key is available.
    func updateSealedNarrative(for entry: JournalEntry, text trimmed: String, tag: FeelingTag, dayKey: String) {
        guard sealedJournalIDs.contains(entry.id), let key = activeJournalRefreshKey() else { return }
        let updated = JournalNarrative(
            id: entry.id, dayKey: dayKey, tag: tag, entryDate: entry.date,
            text: trimmed, emotions: entry.emotions,
            createdAt: entry.date, updatedAt: Date()
        )
        try? narrativeRepository.update(updated, contentKey: key)
    }

    /// Deletes a sealed narrative and forgets its sealed-ID.
    func deleteSealed(id: UUID) {
        try? narrativeRepository.delete(id: id)
        sealedJournalIDs.remove(id)
    }

    // MARK: - Hydration (read paths)

    /// Returns `day` with empty-text journal entries hydrated from the sealed store (when unlocked).
    func hydratingDecryptedJournals(into day: FernletDay, dateKey: String) -> FernletDay {
        var loaded = day
        let emptyEntries = loaded.journals.filter { $0.text.isEmpty }
        guard !emptyEntries.isEmpty, let key = activeJournalRefreshKey() else { return loaded }
        let narratives = (try? narrativeRepository.narratives(forDayKey: dateKey, contentKey: key)) ?? []
        let byID = Dictionary(narratives.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        loaded.journals = loaded.journals.map { entry in
            guard entry.text.isEmpty, let n = byID[entry.id] else { return entry }
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
        case .noLock:
            return deviceJournalKey
        case .sealedUnlocked:
            return journalContentKey
        }
    }

    /// Device-bound key generated on first use and stored in Keychain (not iCloud-synced).
    /// Used to seal journal text when no user lock is configured, ensuring text never reaches the blob.
    private var deviceJournalKey: SymmetricKey {
        if let data = KeychainItem.load(for: .deviceJournalKey, service: KeychainItem.journalService) {
            return SymmetricKey(data: data)
        }
        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }
        KeychainItem.store(keyData, for: .deviceJournalKey, service: KeychainItem.journalService)
        return key
    }

    /// When the user sets up a lock for the first time, re-encrypts entries that were previously
    /// sealed with the device key so they become protected by the user's content key.
    private func migrateDeviceKeyEntriesToUserKey(userKey: SymmetricKey) {
        let dKey = deviceJournalKey
        let todayNarratives = (try? narrativeRepository.narratives(
            forDayKey: host.todayKey, contentKey: dKey)) ?? []
        let prevDayKeys = Array(Set(
            host.previousJournals.filter { $0.text.isEmpty }.map { FernletDate.dayKey(for: $0.date) }
        ))
        let prevNarratives = prevDayKeys.isEmpty ? [] :
            ((try? narrativeRepository.narratives(
                forDayKeys: prevDayKeys, contentKey: dKey)) ?? [])
        for narrative in todayNarratives + prevNarratives {
            try? narrativeRepository.update(narrative, contentKey: userKey)
        }
    }

    /// Loads decrypted text from the sealed store into in-memory journal entries that have empty text.
    private func refreshSealedJournals(contentKey: SymmetricKey) {
        // Today's journals
        let emptyToday = host.day.journals.filter { $0.text.isEmpty }
        if !emptyToday.isEmpty {
            let narratives = (try? narrativeRepository.narratives(forDayKey: host.todayKey, contentKey: contentKey)) ?? []
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
            let narratives = (try? narrativeRepository.narratives(forDayKeys: dayKeys, contentKey: contentKey)) ?? []
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
            if (try? narrativeRepository.insert(narrative, contentKey: contentKey)) != nil {
                sealedJournalIDs.insert(entry.id)
                anyMigrated = true
            }
        }

        for entry in host.day.journals where !entry.text.isEmpty && !sealedJournalIDs.contains(entry.id) {
            let narrative = JournalNarrative(
                id: entry.id, dayKey: host.todayKey, tag: entry.tag, entryDate: entry.date,
                text: entry.text, emotions: entry.emotions,
                createdAt: entry.date, updatedAt: entry.date
            )
            if (try? narrativeRepository.insert(narrative, contentKey: contentKey)) != nil {
                sealedJournalIDs.insert(entry.id)
                anyMigrated = true
            }
        }

        if anyMigrated {
            // Trigger a save so the stripped (empty-text) version replaces the plaintext in the blob.
            host.scheduleSnapshotSave()
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
        guard let key = activeJournalRefreshKey() else { return PastDayScrubOutcome(changedDays: [:], unsealedFailureCount: 0) }
        var changed: [String: FernletDay] = [:]
        var unsealedFailureCount = 0
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
        return PastDayScrubOutcome(changedDays: changed, unsealedFailureCount: unsealedFailureCount)
    }
}
