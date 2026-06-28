import Foundation
import Testing
import FernletFoundation
import FernletDomainModel
import CloudKitSync
import PrivateMemoryStore
@testable import Fernlet

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
}
