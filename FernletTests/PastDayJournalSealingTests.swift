import Foundation
import Testing
import FernletFoundation
import FernletDomainModel
@testable import Fernlet

/// Regression tests for the S3-wall fix (WI-1, Docs/Security-Hardening-Plan-2026-06-27.md):
/// a journal added or edited on a PAST date must never persist its plaintext into the
/// (iCloud-synced) days blob. The text lives only in the encrypted narrative store; the past-day
/// write chokepoint (`DiaryStore.mutatePastDay`) strips sealed text before `repository.updateDay`,
/// mirroring `FernletSnapshot.forStorage` on the today/snapshot path.
///
/// `loadDay(for:)` returns the RAW stored day (what mirrors to iCloud); `loadDayWithDecryptedJournals`
/// re-hydrates from the sealed store. The pairing proves both "no plaintext in the blob" and "no data
/// loss". The no-lock device-key seal path is the common case, so the tests activate it explicitly.
@MainActor
struct PastDayJournalSealingTests {

    @Test func addingJournalOnPastDate_stripsPlaintextFromBlob_butKeepsItSealed() {
        let today = Date()
        let store = makeTestStore(date: today)
        store.activateNoLockJournals()
        let pastKey = FernletDate.dayKey(for: today.addingTimeInterval(-3 * 86_400))
        #expect(pastKey != store.todayKey)

        store.addJournal(text: "secret past entry", tag: .good, date: pastKey)

        // The raw stored day (the blob that mirrors to iCloud) must carry NO journal text.
        let rawJournals = store.loadDay(for: pastKey).journals
        #expect(rawJournals.count == 1)
        #expect(rawJournals.first?.text == "")

        // No data loss: the text round-trips from the sealed narrative store on the hydrated read path.
        let hydrated = store.loadDayWithDecryptedJournals(for: pastKey).journals
        #expect(hydrated.first?.text == "secret past entry")
    }

    @Test func editingJournalOnPastDate_stripsUpdatedPlaintextFromBlob() throws {
        let today = Date()
        let store = makeTestStore(date: today)
        store.activateNoLockJournals()
        let pastKey = FernletDate.dayKey(for: today.addingTimeInterval(-2 * 86_400))

        store.addJournal(text: "original", tag: .good, date: pastKey)
        let entry = try #require(store.loadDayWithDecryptedJournals(for: pastKey).journals.first)

        store.updateJournal(entry, text: "edited secret", tag: .hard, date: pastKey)

        let rawJournals = store.loadDay(for: pastKey).journals
        #expect(rawJournals.first?.text == "")

        let hydrated = store.loadDayWithDecryptedJournals(for: pastKey).journals
        #expect(hydrated.first?.text == "edited secret")
    }

    /// Regression for F1 (Docs/Security-Hardening-Plan-2026-06-27.md): editing a journal that was
    /// sealed in a PRIOR session — and has since aged out of the in-memory `sealedJournalIDs` set (it
    /// is older than the 30-entry `previousJournals` window, so activation never re-seals it) — must
    /// still strip the new plaintext from the blob. The fix records the id as sealed when the past-day
    /// read path (`hydratingDecryptedJournals`) decrypts it for display.
    @Test func editingSealedJournalAfterItAgedOut_stripsPlaintextFromBlob() throws {
        let today = Date()
        let (store1, repository, narratives) = makeTestStoreWithRepositories(date: today)
        store1.activateNoLockJournals()
        let pastKey = FernletDate.dayKey(for: today.addingTimeInterval(-40 * 86_400))
        store1.addJournal(text: "original secret", tag: .good, date: pastKey)
        #expect(store1.loadDay(for: pastKey).journals.first?.text == "")   // sealed + stripped in session 1

        // A brand-new session: fresh store + coordinator over the SAME blob and sealed store. Its
        // in-memory sealedJournalIDs starts empty, and the aged-out past day is outside the
        // previousJournals window, so activation does NOT re-seal it (reproducing the pre-fix state).
        let store2 = makeStoreSharingStores(date: today, repository: repository, narratives: narratives)
        store2.activateNoLockJournals()

        // The user opens the old day; the read decrypts the text for display (and now marks it sealed).
        let entry = try #require(store2.loadDayWithDecryptedJournals(for: pastKey).journals.first)
        #expect(entry.text == "original secret")

        store2.updateJournal(entry, text: "edited secret", tag: .hard, date: pastKey)

        // The blob (mirrors to iCloud) must carry NO plaintext after the edit.
        #expect(store2.loadDay(for: pastKey).journals.first?.text == "")
        // No data loss: the edit round-trips through the sealed store.
        #expect(store2.loadDayWithDecryptedJournals(for: pastKey).journals.first?.text == "edited secret")
    }

    /// A non-journal edit to a past day that already holds a sealed journal must not resurrect the
    /// journal's plaintext into the blob (defense-in-depth: the strip covers EVERY past-day write).
    @Test func unrelatedPastDayEdit_doesNotResurrectSealedJournalText() {
        let today = Date()
        let store = makeTestStore(date: today)
        store.activateNoLockJournals()
        let pastKey = FernletDate.dayKey(for: today.addingTimeInterval(-4 * 86_400))

        store.addJournal(text: "private thoughts", tag: .quiet, date: pastKey)
        store.setBottleCount(5, date: pastKey)   // unrelated mutation routes through mutatePastDay too

        let rawJournals = store.loadDay(for: pastKey).journals
        #expect(rawJournals.first?.text == "")
        #expect(store.loadDay(for: pastKey).bottleCount == 5)
    }

    /// Pure unit test for the shared strip helper: only sealed ids are blanked; others are untouched.
    @Test func strippedIfSealed_blanksOnlySealedEntries() {
        let sealedID = UUID()
        let openID = UUID()
        let sealed = JournalEntry(id: sealedID, text: "private", tag: .good, emotions: ["calm"])
        let open = JournalEntry(id: openID, text: "public", tag: .neutral)
        let ids: Set<UUID> = [sealedID]

        let strippedSealed = sealed.strippedIfSealed(in: ids)
        #expect(strippedSealed.text == "")
        #expect(strippedSealed.emotions.isEmpty)
        #expect(strippedSealed.tag == .good)   // non-sensitive metadata preserved
        #expect(strippedSealed.id == sealedID)
        // Fail-closed allowlist (S3): Equatable spans EVERY stored field, so this proves the strip
        // result is exactly the memberwise reconstruct — text/emotions blanked, the allowlisted
        // id/tag/date/isQuickMood carried, and nothing else riding through. A future stored field
        // must be consciously added to strippedIfSealed (and to this expected value) to survive.
        #expect(strippedSealed == JournalEntry(
            id: sealedID, text: "", tag: .good, date: sealed.date, emotions: [], isQuickMood: false))

        let untouched = open.strippedIfSealed(in: ids)
        #expect(untouched.text == "public")    // unsealed entry keeps its text (no data loss)
    }
}
