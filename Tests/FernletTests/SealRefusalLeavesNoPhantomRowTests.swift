//
//  SealRefusalLeavesNoPhantomRowTests.swift
//  FernletTests
//
//  Pins the write-side rollback that owner decision D4 turned from tidiness into a data-loss guard.
//  Before D4, `ColumnCrypto` fell open to an un-domained legacy blob when the install's
//  device-binding keychain row was unreadable, so a sealed write never failed *midway*: it either
//  saved or never started. D4 replaced that fallback with
//  `SealedColumnStrictSealError.bindingUnavailable`, which lands in the middle of the sealed
//  repositories' `apply` — after the plaintext identity columns are written and before the
//  ciphertext columns are. The rows these tests hunt for are what that throw leaves behind when
//  nobody undoes it, and they are dangerous precisely because they look FINE: nil ciphertexts open
//  as nil, so a note-less half-built row decrypts into a perfectly valid narrative or log, the
//  pending-narrative drain reads it as "already sealed", skips the buffered payload, and then purges
//  the buffer that held the only copy of the user's note.
//

import CoreData
import CryptoKit
import Foundation
import Testing
import PrivateHealthStore
import PrivateStoreCore
@testable import FernletCrypto

/// A throwaway `UserDefaults` suite per call, so the device-local "this device has stored a
/// narrative/log" divergence latch cannot leak between tests. In production the latch lives in
/// `.standard`, which is process-global under the test runner. Nothing here is expected to latch on
/// the refused writes — injecting the suite is what keeps that a property of the code rather than a
/// coincidence of test ordering.
private func isolatedLatchDefaults() -> UserDefaults {
    UserDefaults(suiteName: "fernlet.tests.sealRefusalLatch.\(UUID().uuidString)") ?? .standard
}

/// Proves the three sealed-write paths that seal *into* a freshly inserted or freshly re-stamped row
/// — `MenstrualNarrativeRepository.insert`, `MenstrualNarrativeRepository.update` and
/// `IntimacyLogRepository.insert` — leave the store exactly as they found it when the seal refuses.
///
/// The refusal is driven through `DeviceBindingID`'s `@TaskLocal` test seam rather than by touching
/// the real keychain row: the override is scoped to this task, so repository suites running
/// concurrently against the genuine install binding are unaffected and no test can leave a poisoned
/// binding behind.
///
/// **`@MainActor` is load-bearing, not decoration.** A task-local is readable only while execution
/// stays inside the binding task, and every repository method wraps its whole body in
/// `context.performAndWait`. `PrivatePersistenceController`'s `container.viewContext` is a
/// main-queue context, so off the main thread that `performAndWait` dispatches ACROSS to the main
/// queue — onto a thread with no current task — and the override reads back as `nil` inside the
/// closure. `DeviceBindingID.current()` then falls through to the test host's real keychain, answers
/// a healthy binding, and the seal SUCCEEDS: `.unavailable` is silently ignored and the refusal
/// these tests exist to observe never happens. Pinning the suite to the main actor puts the caller
/// on the context's own queue, where `performAndWait` is re-entrant and runs the closure INLINE on
/// the calling thread — inside the task, and so inside the override's dynamic extent. Nothing else
/// can interleave: the `withValue` closures are synchronous and have no suspension point, so the
/// override cannot leak to other main-actor work.
///
/// Dropping the annotation does not quietly weaken these tests, it breaks them loudly — every
/// `#expect(throws:)` below fails with "an error was expected but none was thrown" — which is the
/// intended failure mode. Do not "fix" that by relaxing the expectation; the annotation is the fix.
/// The production seam stays `@TaskLocal` precisely so parallel suites cannot leak overrides into
/// each other, and this suite adapts to it rather than the other way round.
///
/// Each test checks the absence of the phantom TWICE, because the row is harmful at two different
/// moments. First through a repository fetch taken immediately after the failure — a Core Data fetch
/// includes pending, unsaved changes by default, which is how `PeriodTrackerStore`'s next drain
/// would meet the phantom before anything is committed. Then again after a *successful* write on the
/// same context: the `PrivatePersistenceController` view context is shared, so a save from anywhere
/// else in the app commits whatever is pending on it, which is what makes an un-rolled-back phantom
/// survive a process restart.
@MainActor
struct SealRefusalLeavesNoPhantomRowTests {
    /// A fixed 32-byte content key. The key is never what fails here — the install binding is.
    private let contentKey = SymmetricKey(data: Data(repeating: 0x5A, count: 32))
    /// The install identity pinned for every write and read that is supposed to SUCCEED.
    private let installID = Data(repeating: 0xC3, count: 16)

    /// Runs `body` with a durable install binding pinned — the "keychain is healthy" state.
    ///
    /// Every successful write AND every read-back must run inside this: the v3 format authenticates
    /// the install binding as additional data, so a row sealed under ``installID`` and then opened
    /// against whatever binding the test host's real keychain holds would fail authentication. That
    /// would still fail the test, but for the wrong reason — it would stop the assertions below from
    /// ever reaching the question they exist to ask.
    private func withHealthyBinding<R>(_ body: () throws -> R) rethrows -> R {
        try DeviceBindingID.$testOverride.withValue(.identifier(installID)) { try body() }
    }

    /// A narrative insert whose seal refuses must leave nothing behind — not even pending. Without
    /// the rollback, the row inserted before the seal keeps its plaintext `hkExternalUUID`, which is
    /// exactly the key `PeriodTrackerStore`'s drain looks a narrative up by; finding it there is what
    /// makes the drain believe the buffered note was already sealed and purge the buffer.
    @Test func aRefusedNarrativeInsertLeavesNoPhantomRow() throws {
        let controller = PrivatePersistenceController(inMemory: true)
        let repository = MenstrualNarrativeRepository(
            context: controller.container.viewContext,
            defaults: isolatedLatchDefaults()
        )
        let refused = MenstrualNarrative(
            hkExternalUUID: "phantom-row-uuid",
            dateKey: "2026-08-29",
            note: "Cramps all evening; slept badly.",
            symptomFlags: [.cramps],
            customSymptomScales: ["fatigue": 4]
        )

        DeviceBindingID.$testOverride.withValue(.unavailable) {
            #expect(throws: ColumnCrypto.SealedColumnStrictSealError.bindingUnavailable) {
                try repository.insert(refused, contentKey: self.contentKey)
            }
        }
        let pending = try withHealthyBinding {
            try repository.narrative(forHKUUID: refused.hkExternalUUID, contentKey: contentKey)
        }
        #expect(pending == nil)

        // The keychain recovers and an unrelated narrative saves: that save commits everything left
        // pending on the shared context, so it is when a surviving phantom would become durable.
        let recovered = MenstrualNarrative(hkExternalUUID: "healthy-row-uuid", dateKey: "2026-08-30", note: "Lighter.")
        try withHealthyBinding { try repository.insert(recovered, contentKey: contentKey) }

        let count = try repository.narrativeCount()
        #expect(count == 1)
        let survivor = try withHealthyBinding {
            try repository.narrative(forHKUUID: recovered.hkExternalUUID, contentKey: contentKey)
        }
        #expect(survivor?.note == recovered.note)
    }

    /// A narrative re-seal that refuses must leave the stored row exactly as it was. `apply`
    /// overwrites the plaintext columns before it seals, so without the rollback the row would carry
    /// the EDIT's `dateKey` while still holding the ORIGINAL note ciphertext — a row that decrypts
    /// cleanly, therefore reads as a successful re-seal to everything downstream, while the edit the
    /// user actually typed exists nowhere.
    @Test func aRefusedNarrativeUpdateLeavesTheStoredRowUntouched() throws {
        let controller = PrivatePersistenceController(inMemory: true)
        let repository = MenstrualNarrativeRepository(
            context: controller.container.viewContext,
            defaults: isolatedLatchDefaults()
        )
        let original = MenstrualNarrative(
            hkExternalUUID: "cycle-day-uuid",
            dateKey: "2026-08-01",
            note: "First draft of the day's note.",
            symptomFlags: [.cramps],
            customSymptomScales: ["fatigue": 2]
        )
        try withHealthyBinding { try repository.insert(original, contentKey: contentKey) }
        var edited = original
        edited.dateKey = "2026-08-02"
        edited.note = "Second draft — re-dated to the day it actually belongs to."

        DeviceBindingID.$testOverride.withValue(.unavailable) {
            #expect(throws: ColumnCrypto.SealedColumnStrictSealError.bindingUnavailable) {
                try repository.update(edited, contentKey: self.contentKey)
            }
        }
        // A later successful write on the shared context commits whatever the failed edit left
        // pending, so the assertions run AFTER one — the durable state is the one that matters.
        let unrelated = MenstrualNarrative(hkExternalUUID: "other-day-uuid", dateKey: "2026-08-03", note: "Fine.")
        try withHealthyBinding { try repository.insert(unrelated, contentKey: contentKey) }

        let stored = try withHealthyBinding {
            try repository.narrative(forHKUUID: original.hkExternalUUID, contentKey: contentKey)
        }
        #expect(stored?.dateKey == original.dateKey)
        #expect(stored?.note == original.note)
        #expect(stored?.symptomFlags == original.symptomFlags)
        #expect(stored?.customSymptomScales == original.customSymptomScales)
    }

    /// An intimacy insert whose note seal refuses must leave no row. The phantom here decrypts to a
    /// log with an EMPTY note (`openString(nil)` is nil and `decryptLog` substitutes `""`), so the
    /// event would read as recorded while the note the user wrote is simply gone.
    @Test func aRefusedIntimacyInsertLeavesNoPhantomRow() throws {
        let controller = PrivatePersistenceController(inMemory: true)
        let repository = IntimacyLogRepository(
            context: controller.container.viewContext,
            defaults: isolatedLatchDefaults()
        )
        let refused = IntimacyLog(
            eventDate: Date(timeIntervalSince1970: 1_787_000_000),
            note: "The note that must not be silently dropped."
        )

        DeviceBindingID.$testOverride.withValue(.unavailable) {
            #expect(throws: ColumnCrypto.SealedColumnStrictSealError.bindingUnavailable) {
                try repository.insert(refused, contentKey: self.contentKey)
            }
        }
        let pending = try withHealthyBinding { try repository.logs(contentKey: contentKey) }
        #expect(pending.isEmpty)

        let recovered = IntimacyLog(eventDate: Date(timeIntervalSince1970: 1_787_086_400), note: "Recorded fine.")
        try withHealthyBinding { try repository.insert(recovered, contentKey: contentKey) }

        let count = try repository.logCount()
        #expect(count == 1)
        let logs = try withHealthyBinding { try repository.logs(contentKey: contentKey) }
        #expect(logs.map(\.id) == [recovered.id])
        #expect(logs.first?.note == recovered.note)
    }
}
