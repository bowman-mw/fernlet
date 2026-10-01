// PrivateHubCustodyWiringTests.swift
// FernletTests
//
// The app-side custody wiring `ContentView` installs at launch (period-data design 2026-09-30):
//   - I28 / review R2-F1: every sealed backup reads the PRIVATE TAB's content key — in both passcode
//     modes and on the Cycle section, where the journal (the old key source) is deactivated.
//   - §9.21: `FernletLockService.reset()` hands its aftermath to the store's reset funnel, which clears
//     the backup bookkeeping that spoke for the destroyed key and holds ambient restores for the
//     device owner (Q14).
// Driven through the same static step `ContentView.wirePrivateHubCustody` runs, over a real lock
// service on isolated keychain services.

import CloudKitSync
import CryptoKit
import Foundation
import Testing
import FernletDomainModel
import FernletFoundation
import PrivateHealthStore
import PrivateMemoryStore
import PrivateStoreCore
@testable import FernletLock
@testable import Fernlet

@Suite(.serialized)
struct PrivateHubCustodyWiringTests {

    /// A throwaway defaults suite (latches and the owner hold are process-global otherwise).
    private static func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "fernlet.tests.custodyWiring.\(UUID().uuidString)") ?? .standard
    }

    @MainActor
    private static func entries(over fixture: DeviceCustodyFixture, latches: UserDefaults) -> SealedPriorEntryStore {
        SealedPriorEntryStore(
            controller: fixture.persistence,
            latchDefaults: latches,
            intimacyStore: IntimacyLogStore(repository: IntimacyLogRepository(controller: fixture.persistence, defaults: latches)),
            deviceKeyService: fixture.harness.sealedContentKeyServiceID,
            restoresAfterRemoval: { false }
        )
    }

    /// I28: on the Cycle section the journal is deactivated, and the backup key used to come from the
    /// journal — so the Cycle settle's period and intimacy backups ran keyless and deferred as
    /// `.locked`, in both modes. Wired to the hub key, it answers there, and nil once Private closes.
    @MainActor
    @Test func theBackupKeyIsTheHubKeyOnTheCycleSectionInBothPasscodeModes() async throws {
        let fixture = DeviceCustodyFixture(enclaveAvailable: false)
        defer { fixture.cleanup() }
        let service = fixture.makeService()
        let store = makeTestStore()
        ContentView.wirePrivateHubCustody(
            store: store,
            lockService: service,
            priorEntries: Self.entries(over: fixture, latches: Self.isolatedDefaults())
        )

        try service.openWithoutPasscode(for: .privateHub, allowingMint: true)
        store.deactivateSealedJournals()   // what switching to the Cycle section does
        let hubKey = try #require(service.contentKey(for: .privateHub))
        #expect(store.sealedBackupContentKey == hubKey, "no passcode: the tap-opened hub key backs the Cycle section")
        service.lock(reason: .manual)
        #expect(store.sealedBackupContentKey == nil, "a closed tab lends the backups no key")

        try await service.configure(credential: .pin6("246810"), grantingScope: .privateHub, acknowledgedPriorData: false)
        store.deactivateSealedJournals()
        #expect(store.sealedBackupContentKey == hubKey, "with a passcode: the same (adopted) key, on the Cycle section too")
    }

    /// §9.21: the reset funnel clears the divergence latches (they spoke for the key the reset just
    /// destroyed) and holds every ambient restore for the device owner, so the cleared latches cannot
    /// turn the next Private settle into an automatic restore.
    @MainActor
    @Test func aResetClearsTheLatchesAndHoldsAmbientRestoresForTheOwner() throws {
        let fixture = DeviceCustodyFixture(enclaveAvailable: false)
        defer { fixture.cleanup() }
        let service = fixture.makeService()
        let store = makeTestStore()
        let latches = Self.isolatedDefaults()
        store.sealedBackupRestoreHold = SealedBackupRestoreHold(defaults: Self.isolatedDefaults())
        let cycle = MenstrualNarrativeRepository(controller: fixture.persistence, defaults: latches)
        let narrative = MenstrualNarrative(hkExternalUUID: "reset", dateKey: "2026-09-30", note: "x")
        try cycle.insert(narrative, contentKey: SymmetricKey(size: .bits256))
        try cycle.delete(id: narrative.id)
        #expect(cycle.hasEverStoredNarrative)
        #expect(!store.sealedBackupRestoreAwaitsOwner)
        ContentView.wirePrivateHubCustody(store: store, lockService: service, priorEntries: Self.entries(over: fixture, latches: latches))

        try service.reset()

        #expect(store.sealedBackupRestoreAwaitsOwner, "after a reset, restores wait for the device owner")
        #expect(!cycle.hasEverStoredNarrative, "the latch spoke for the destroyed key; it is cleared")
    }

    /// Review N-1: the reset funnel keeps only the pre-reset copies that can exist — the payload
    /// backups switched on at the reset — and a delete that lands afterwards ends the claim on that
    /// payload, while the ambient-restore hold stays.
    @MainActor
    @Test func aResetKeepsOnlyTheBackupsThatWereOnAndALandedDeleteEndsTheClaim() {
        let store = makeTestStore()
        store.sealedBackupRestoreHold = SealedBackupRestoreHold(defaults: Self.isolatedDefaults())
        var cleared = false

        store.handleAppLockResetCompleted(
            preferences: StoragePreferences(sealedBackupJournalEnabled: true, sealedBackupIntimacyEnabled: true),
            clearBookkeeping: { cleared = true }
        )

        #expect(cleared)
        #expect(store.sealedBackupPayloadsKeptForOwner == [.journalNarratives, .intimacyLogs])
        #expect(!store.sealedBackupKeepsPreResetCopy(of: .periodData), "period was off: no copy to keep")
        store.recordSealedBackupCloudCopyDeleted(.journalNarratives)
        #expect(store.sealedBackupPayloadsKeptForOwner == [.intimacyLogs], "the deleted journal copy is no longer kept")
        #expect(store.sealedBackupRestoreAwaitsOwner, "ambient restores still wait for the owner")
    }

    /// The period backup's v2 wiring `ContentView` installs (design 2026-09-30 §4.4, §4.5): the period
    /// store's cycle-record funnel moves the host's mutation epoch and marks the backup owed on every
    /// mutation — through the store's hook, never the backup's switch — and every hub session asks the
    /// v2 engine for its settle (restore, then export) on whichever Private section opens first,
    /// instead of the Cycle section running the period settle itself. Read from source: both live
    /// inside private launch steps of the root view.
    @Test func theCycleFunnelMarksThePeriodBackupOwedAndEveryHubSessionAsksTheEngine() throws {
        let source = try String(contentsOf: RepoRoot.url("App/Fernlet/ContentView.swift"), encoding: .utf8)
        #expect(source.contains("periodStore.recordStore.attachMutationHook { [store] in store.markSealedBackupDirty(.periodData) }"))
        #expect(source.contains("store.requestSealedBackupHubSettle()"))
        #expect(source.contains("store.sealedBackupHubSessionEnded()"))
        #expect(!source.contains("await store.settleSealedPeriodBackup()"),
                "the period settle runs on the engine's worker, at every hub session, not in the Cycle section's settle")
        #expect(!source.contains("retryDeferredSealedPeriodBackupIfNeeded()"),
                "the bare re-upload skips the restore")
        #expect(!source.contains("sealedBackupPeriodEnabled ="), "nothing here may flip the period backup's switch")
    }
}
