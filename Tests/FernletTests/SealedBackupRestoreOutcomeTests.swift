// SealedBackupRestoreOutcomeTests.swift
// FernletTests
//
// WS-4 (Docs/Sealed-Backup-Escrow-Recovery-FollowUp-2026-06-28.md): restore failures are VISIBLE and
// RETRYABLE, never silently terminal. Covers the outcome enum's classification semantics and the
// host-recording wiring (the observable status is updated) for a merge restore and the retired payload.

import Foundation
import Testing
import CloudKitSync
import PrivateMemoryStore
@testable import Fernlet

@MainActor
struct SealedBackupRestoreOutcomeTests {

    // MARK: - Outcome classification semantics

    @Test func didRestoreOnlyForRestored() {
        #expect(SealedBackupRestoreOutcome.restored(3).didRestore)
        for outcome: SealedBackupRestoreOutcome in [
            .nothingToRestore, .skippedStoreNotEmpty, .deferredKeyNotSynced,
            .deferredLocked, .deferredTransient, .notRecognized, .rolledBack
        ] {
            #expect(outcome.didRestore == false)
        }
    }

    @Test func deferredAndUnrecognizedNeedAttention() {
        // The deferred/unrecognized outcomes are the ones the user must see (WS-4 "visible").
        for outcome: SealedBackupRestoreOutcome in [
            .deferredKeyNotSynced, .deferredLocked, .deferredTransient, .notRecognized, .rolledBack
        ] {
            #expect(outcome.needsAttention)
        }
        // The benign outcomes are silent (nothing to act on).
        for outcome: SealedBackupRestoreOutcome in [
            .restored(1), .nothingToRestore, .skippedStoreNotEmpty
        ] {
            #expect(outcome.needsAttention == false)
        }
    }

    @Test func onlyDeferredOutcomesAreRetryable() {
        // Deferred = a later attempt could succeed.
        for outcome: SealedBackupRestoreOutcome in [
            .deferredKeyNotSynced, .deferredLocked, .deferredTransient
        ] {
            #expect(outcome.isRetryable)
        }
        // notRecognized is terminal for the current backup (a different key won't appear by retrying).
        #expect(SealedBackupRestoreOutcome.notRecognized.isRetryable == false)
        #expect(SealedBackupRestoreOutcome.notRecognized.needsAttention)
        // rolledBack is terminal for the same reason: retrying re-fetches the same substituted
        // record. It must still be visible — a silent rollback is the whole failure mode.
        #expect(SealedBackupRestoreOutcome.rolledBack.isRetryable == false)
        #expect(SealedBackupRestoreOutcome.rolledBack.needsAttention)
        // Benign outcomes are not "retry" prompts.
        for outcome: SealedBackupRestoreOutcome in [.restored(1), .nothingToRestore, .skippedStoreNotEmpty] {
            #expect(outcome.isRetryable == false)
        }
    }

    // MARK: - Host status recording (no network)

    /// Rewritten for unit B3 (design 2026-09-30, R2-F16b; was `restoreOutcomeRecordsSkippedOnPopulatedStore`):
    /// the journal's `.skippedStoreNotEmpty` no longer exists for a populated store — its restore is a
    /// MERGE. A store that already holds entries of its own takes the backup's entries beside them, and
    /// the rich outcome is RECORDED on the host, not silently dropped.
    @Test func aJournalRestoreIntoAPopulatedStoreMergesAndRecordsItsOutcome() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let old = JournalBackupDevice(cloud: cloud, writer: "old", resolved: true)
        try old.write(JournalBackupDevice.entry("from the backup", day: 1))
        #expect(await old.coordinator.setSealedBackupEnabled(true, payloadType: .journalNarratives))
        let phone = JournalBackupDevice(cloud: cloud, writer: "phone")
        try phone.write(JournalBackupDevice.entry("written here", day: 2))
        #expect(phone.host.recordedOutcomes[.journalNarratives] == nil)

        let outcome = await phone.coordinator.restoreSealedBackupOutcome(payloadType: .journalNarratives)

        #expect(outcome == .restored(1))
        #expect(phone.host.recordedOutcomes[.journalNarratives] == .restored(1))
        #expect(Set(try phone.entries().map(\.text)) == ["from the backup", "written here"])
    }

    /// The retired sensitive-notes payload is never restored: the outcome is the benign
    /// `.nothingToRestore` — no banner, no Retry — even on a populated store, and it is still recorded.
    @Test func retiredSensitiveNotesRestoresNothingAndNeedsNoAttention() async {
        let store = makePopulatedTestStore()

        let outcome = await store.restoreSealedBackupOutcome(payloadType: .sensitiveNotes)

        #expect(outcome == .nothingToRestore)
        #expect(outcome.needsAttention == false)
        #expect(store.sealedBackupRestoreStatus[.sensitiveNotes] == .nothingToRestore)
    }
}
