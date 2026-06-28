import Foundation
import Testing
import CryptoKit
import FernletFoundation
import FernletDomainModel
import CloudKitSync
import PrivateMemoryStore
@testable import Fernlet

/// Test double that wraps a real `JournalNarrativeRepository` but makes `insert` throw the first
/// `failuresRemaining` times it is asked to seal a specific entry id, forwarding everything else. Lets the
/// WI1-1 regression drive a day whose seal fails on the first scrub pass and assert it is retried — and
/// eventually sealed — on a later pass, without looping unboundedly. Reads forward to the real store, so a
/// test can still inspect the sealed ciphertext through the underlying repository.
private final class FailableJournalNarrativeStore: JournalNarrativeStoring {
    enum SimulatedSealFailure: Error { case transient }

    private let wrapped: JournalNarrativeRepository
    private let failID: UUID
    private var failuresRemaining: Int
    private var attemptsByID: [UUID: Int] = [:]

    init(wrapping wrapped: JournalNarrativeRepository, failID: UUID, failuresRemaining: Int) {
        self.wrapped = wrapped
        self.failID = failID
        self.failuresRemaining = failuresRemaining
    }

    /// How many times `insert` has been called for `id` (across scrub passes).
    func insertAttempts(for id: UUID) -> Int { attemptsByID[id, default: 0] }

    func insert(_ narrative: JournalNarrative, contentKey: SymmetricKey?) throws {
        if narrative.id == failID {
            attemptsByID[narrative.id, default: 0] += 1
            if failuresRemaining > 0 {
                failuresRemaining -= 1
                throw SimulatedSealFailure.transient
            }
        }
        try wrapped.insert(narrative, contentKey: contentKey)
    }

    func update(_ narrative: JournalNarrative, contentKey: SymmetricKey?) throws {
        try wrapped.update(narrative, contentKey: contentKey)
    }
    func delete(id: UUID) throws { try wrapped.delete(id: id) }
    func narratives(forDayKey dayKey: String, contentKey: SymmetricKey?) throws -> [JournalNarrative] {
        try wrapped.narratives(forDayKey: dayKey, contentKey: contentKey)
    }
    func narratives(forDayKeys dayKeys: [String], contentKey: SymmetricKey?) throws -> [JournalNarrative] {
        try wrapped.narratives(forDayKeys: dayKeys, contentKey: contentKey)
    }
}

/// Regression test for the WI-1 one-time historical scrub (Docs/Security-Hardening-Plan-2026-06-27.md).
///
/// The past-day strip (`DiaryStore.mutatePastDay`) closes the leak for NEW past-day writes, but journals
/// added/edited on a past date *before* that fix shipped already wrote plaintext into the (iCloud-synced)
/// days blob. Those days are never re-stripped: `FernletSnapshot.forStorage` only sanitises today, and
/// `migrateExistingJournalsToSealedStore` only scans today + `previousJournals` — so a day that has aged
/// out of the recent-journals window keeps its plaintext forever. The scrub (`scrubLeakedPastDayJournals`
/// in the coordinator, orchestrated by `FernletStore.scrubLeakedPastDayJournalsIfNeeded`) runs once per
/// device on journal activation, sealing + blanking that legacy plaintext.
@MainActor
struct PastDayJournalScrubMigrationTests {

    @Test func scrub_sealsAndBlanksLeakedHistoricalPastDayJournal_andIsRunOnce() {
        let today = Date()
        let (store, repository, _) = makeTestStoreWithRepositories(date: today)

        // Isolate the run-once flag from the shared `.standard` suite so parallel suites don't collide.
        let suiteName = "wi1-scrub-\(UUID().uuidString)"
        let scrubDefaults = UserDefaults(suiteName: suiteName)!
        store.pastDayJournalScrubDefaults = scrubDefaults
        defer { scrubDefaults.removePersistentDomain(forName: suiteName) }

        let todayKey = store.todayKey
        // Far outside the recent-journals window, so ONLY the full-repository scrub can reach it.
        let pastKey = FernletDate.dayKey(for: today.addingTimeInterval(-120 * 86_400))
        #expect(pastKey != todayKey)

        // Seed the PRE-FIX leaked state: a past-day journal whose plaintext was written straight to the
        // blob and never sealed (exactly what the old `updateDay`/`mutatePastDay` path produced). Writing
        // through the repository directly bypasses today's strip — it lives only in the persisted blob.
        var leakedDay = FernletDay(date: pastKey)
        let leaked = JournalEntry(text: "historical leaked secret", tag: .good)
        leakedDay.journals = [leaked]
        #expect(repository.updateDay(leakedDay, for: pastKey, todayKey: todayKey))

        // Pre-condition: the leak is present — plaintext in the blob, nothing sealed yet.
        #expect(repository.loadDay(for: pastKey, todayKey: todayKey).journals.first?.text == "historical leaked secret")
        #expect(store.loadDayWithDecryptedJournals(for: pastKey).journals.first?.text == "historical leaked secret")

        // Run the one-time scrub (fires inside activation, when the device journal key is live).
        store.activateNoLockJournals()

        // The blob (what mirrors to iCloud) no longer carries the plaintext...
        #expect(store.loadDay(for: pastKey).journals.first?.text == "")
        #expect(repository.loadDay(for: pastKey, todayKey: todayKey).journals.first?.text == "")
        // ...and the text survives in the sealed narrative store (hydratable — no data loss).
        #expect(store.loadDayWithDecryptedJournals(for: pastKey).journals.first?.text == "historical leaked secret")

        // The run-once flag is now set to the current version.
        #expect(scrubDefaults.integer(forKey: FernletStore.pastDayJournalScrubFlagKey) == FernletStore.pastDayJournalScrubVersion)

        // Idempotent: a second activation neither loses the text nor resurrects plaintext in the blob.
        store.activateNoLockJournals()
        #expect(store.loadDay(for: pastKey).journals.first?.text == "")
        #expect(store.loadDayWithDecryptedJournals(for: pastKey).journals.first?.text == "historical leaked secret")
    }

    /// Proves the gate is real: once the flag is set, a freshly re-introduced historical leak is NOT
    /// re-scanned (the one-time scan is bounded). New past-day writes are covered by `mutatePastDay`;
    /// only this bulk historical scan is gated.
    @Test func scrub_isGatedByRunOnceFlag() {
        let today = Date()
        let (store, repository, _) = makeTestStoreWithRepositories(date: today)

        let suiteName = "wi1-scrub-gate-\(UUID().uuidString)"
        let scrubDefaults = UserDefaults(suiteName: suiteName)!
        // Pretend the scrub already ran on this device.
        scrubDefaults.set(FernletStore.pastDayJournalScrubVersion, forKey: FernletStore.pastDayJournalScrubFlagKey)
        store.pastDayJournalScrubDefaults = scrubDefaults
        defer { scrubDefaults.removePersistentDomain(forName: suiteName) }

        let todayKey = store.todayKey
        let pastKey = FernletDate.dayKey(for: today.addingTimeInterval(-90 * 86_400))
        var leakedDay = FernletDay(date: pastKey)
        leakedDay.journals = [JournalEntry(text: "untouched legacy entry", tag: .quiet)]
        #expect(repository.updateDay(leakedDay, for: pastKey, todayKey: todayKey))

        store.activateNoLockJournals()

        // Flag already at the current version → the bulk scan is skipped, so this stays as-is.
        #expect(store.loadDay(for: pastKey).journals.first?.text == "untouched legacy entry")
    }

    /// WI1-1: a day whose seal fails on the first pass must NOT advance the run-once flag — so a later
    /// launch retries it. Here the seal fails exactly once (transient), then succeeds; the second pass
    /// seals + blanks it, advances the flag, and clears the retry counter.
    @Test func scrub_retriesDayWhoseSealFailsOnce_thenSealsItOnNextRun() {
        let today = Date()
        let leakedEntry = JournalEntry(text: "historical leaked secret", tag: .good)

        var failingStore: FailableJournalNarrativeStore!
        let (store, repository, _) = makeTestStoreWithRepositories(date: today) { real in
            failingStore = FailableJournalNarrativeStore(wrapping: real, failID: leakedEntry.id, failuresRemaining: 1)
            return failingStore
        }

        let suiteName = "wi1-scrub-retry-\(UUID().uuidString)"
        let scrubDefaults = UserDefaults(suiteName: suiteName)!
        store.pastDayJournalScrubDefaults = scrubDefaults
        defer { scrubDefaults.removePersistentDomain(forName: suiteName) }

        let todayKey = store.todayKey
        // Far outside the recent-journals window, so ONLY the full-repository scrub can reach it.
        let pastKey = FernletDate.dayKey(for: today.addingTimeInterval(-120 * 86_400))
        #expect(pastKey != todayKey)

        var leakedDay = FernletDay(date: pastKey)
        leakedDay.journals = [leakedEntry]
        #expect(repository.updateDay(leakedDay, for: pastKey, todayKey: todayKey))

        // Pass 1: the seal throws → plaintext preserved (no data loss) and the run-once flag stays UNSET.
        store.activateNoLockJournals()
        #expect(failingStore.insertAttempts(for: leakedEntry.id) == 1)
        #expect(store.loadDay(for: pastKey).journals.first?.text == "historical leaked secret")
        #expect(scrubDefaults.integer(forKey: FernletStore.pastDayJournalScrubFlagKey) < FernletStore.pastDayJournalScrubVersion)
        #expect(scrubDefaults.integer(forKey: FernletStore.pastDayJournalScrubAttemptsKey) == 1)

        // Pass 2: the day is retried (flag still unset). The seal now succeeds → blanked in the blob,
        // sealed in the narrative store, run-once flag advanced, retry counter cleared.
        store.activateNoLockJournals()
        #expect(failingStore.insertAttempts(for: leakedEntry.id) == 2)
        #expect(store.loadDay(for: pastKey).journals.first?.text == "")
        #expect(store.loadDayWithDecryptedJournals(for: pastKey).journals.first?.text == "historical leaked secret")
        #expect(scrubDefaults.integer(forKey: FernletStore.pastDayJournalScrubFlagKey) == FernletStore.pastDayJournalScrubVersion)
        #expect(scrubDefaults.object(forKey: FernletStore.pastDayJournalScrubAttemptsKey) == nil)

        // Idempotent: a third activation does not re-scan (flag set) and does not lose data.
        store.activateNoLockJournals()
        #expect(failingStore.insertAttempts(for: leakedEntry.id) == 2)
        #expect(store.loadDayWithDecryptedJournals(for: pastKey).journals.first?.text == "historical leaked secret")
    }

    /// WI1-1: a *permanently* failing seal must not loop forever. The retry is bounded — after
    /// `pastDayJournalScrubMaxAttempts` passes the scrub gives up (sets the run-once flag), and further
    /// launches do no work. The plaintext is preserved throughout (no data loss).
    @Test func scrub_givesUpAfterMaxAttempts_withoutLoopingUnbounded() {
        let today = Date()
        let leakedEntry = JournalEntry(text: "permanently failing secret", tag: .quiet)

        var failingStore: FailableJournalNarrativeStore!
        let (store, repository, _) = makeTestStoreWithRepositories(date: today) { real in
            // Fail far more times than the retry cap → an entry that can never be sealed.
            failingStore = FailableJournalNarrativeStore(wrapping: real, failID: leakedEntry.id, failuresRemaining: .max)
            return failingStore
        }

        let suiteName = "wi1-scrub-giveup-\(UUID().uuidString)"
        let scrubDefaults = UserDefaults(suiteName: suiteName)!
        store.pastDayJournalScrubDefaults = scrubDefaults
        defer { scrubDefaults.removePersistentDomain(forName: suiteName) }

        let todayKey = store.todayKey
        let pastKey = FernletDate.dayKey(for: today.addingTimeInterval(-200 * 86_400))
        #expect(pastKey != todayKey)

        var leakedDay = FernletDay(date: pastKey)
        leakedDay.journals = [leakedEntry]
        #expect(repository.updateDay(leakedDay, for: pastKey, todayKey: todayKey))

        // Each pass re-scans (flag stays unset) and retries the seal — up to the cap.
        for _ in 0..<FernletStore.pastDayJournalScrubMaxAttempts {
            store.activateNoLockJournals()
        }

        // Attempted exactly `maxAttempts` times, then gave up: flag set, retry counter cleared.
        #expect(failingStore.insertAttempts(for: leakedEntry.id) == FernletStore.pastDayJournalScrubMaxAttempts)
        #expect(scrubDefaults.integer(forKey: FernletStore.pastDayJournalScrubFlagKey) == FernletStore.pastDayJournalScrubVersion)
        #expect(scrubDefaults.object(forKey: FernletStore.pastDayJournalScrubAttemptsKey) == nil)

        // Bounded: further launches do NOT re-scan — no additional seal attempts, no unbounded loop.
        store.activateNoLockJournals()
        store.activateNoLockJournals()
        #expect(failingStore.insertAttempts(for: leakedEntry.id) == FernletStore.pastDayJournalScrubMaxAttempts)

        // No data loss: the still-unsealed plaintext is preserved and remains readable.
        #expect(store.loadDay(for: pastKey).journals.first?.text == "permanently failing secret")
    }
}
