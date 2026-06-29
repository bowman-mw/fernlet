// SealedBackupRestoreOutcomeTests.swift
// FernletTests
//
// WS-4 (Docs/Sealed-Backup-Escrow-Recovery-FollowUp-2026-06-28.md): restore failures are VISIBLE and
// RETRYABLE, never silently terminal. Covers the outcome enum's classification semantics and the
// host-recording wiring (the store's observable status is updated) for the no-network short-circuit.

import Foundation
import Testing
import CloudKitSync
@testable import Fernlet

@MainActor
struct SealedBackupRestoreOutcomeTests {

    // MARK: - Outcome classification semantics

    @Test func didRestoreOnlyForRestored() {
        #expect(SealedBackupRestoreOutcome.restored(3).didRestore)
        for outcome: SealedBackupRestoreOutcome in [
            .nothingToRestore, .skippedStoreNotEmpty, .deferredKeyNotSynced,
            .deferredLocked, .deferredTransient, .notRecognized
        ] {
            #expect(outcome.didRestore == false)
        }
    }

    @Test func deferredAndUnrecognizedNeedAttention() {
        // The deferred/unrecognized outcomes are the ones the user must see (WS-4 "visible").
        for outcome: SealedBackupRestoreOutcome in [
            .deferredKeyNotSynced, .deferredLocked, .deferredTransient, .notRecognized
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
        // Benign outcomes are not "retry" prompts.
        for outcome: SealedBackupRestoreOutcome in [.restored(1), .nothingToRestore, .skippedStoreNotEmpty] {
            #expect(outcome.isRetryable == false)
        }
    }

    // MARK: - Host status recording (no network)

    /// A populated store short-circuits restore at the no-clobber gate (before any CloudKit/identity
    /// work) — and the rich outcome is RECORDED on the observable status, not silently dropped.
    @Test func restoreOutcomeRecordsSkippedOnPopulatedStore() async {
        let store = makePopulatedTestStore()
        #expect(store.sealedBackupRestoreStatus[.sensitiveNotes] == nil)

        let outcome = await store.restoreSealedBackupOutcome(payloadType: .sensitiveNotes)

        #expect(outcome == .skippedStoreNotEmpty)
        #expect(store.sealedBackupRestoreStatus[.sensitiveNotes] == .skippedStoreNotEmpty)
    }
}
