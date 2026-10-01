//
//  SealedBackupV2EngineTests.swift
//  FernletTests
//
//  The Sealed backup v2 engine (journal and intimacy Sealed backup v2 design 2026-09-30, §4–§5),
//  driven through the period adapter — the one payload on v2 in this build — over the in-memory cloud
//  and a fake host. Each test names the invariant (BVn) or the design item it pins. The period
//  façades' own behaviour is in SealedBackupChunkTests and SealedBackupRestoreTests.
//

import ProximityKit
import CloudKit
import CloudKitSync
import CoreData
import CryptoKit
import FernletFoundation
import Foundation
import PrivateHealthStore
import PrivateStoreCore
import Testing
@testable import Fernlet

@Suite(.serialized)
struct SealedBackupV2EngineTests {

    // MARK: - The open finding on 8f808232: nothing is written after a turn-off's or a cloud delete

    /// Review finding on unit 5 (8f808232), closed by the gates G: turning the period backup OFF while
    /// an export is mid-upload. The turn-off first stops the engine — the running commit stops before
    /// its next save — and only then deletes, so no chunk or head lands after the delete, and nothing
    /// is written by any later pass while the switch is off.
    @MainActor
    @Test func turningTheBackupOffMidExportWritesNoSetAfterTheDelete() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let holding = HoldingCloudKitRecordDatabase(cloud.database)
        let phone = PeriodBackupDevice(cloud: cloud, writer: "phone", resolved: true, database: holding)
        try phone.seed((0..<300).map { PeriodBackupDevice.record(day: $0) })

        let export = Task { await phone.coordinator.setSealedBackupEnabled(true, payloadType: .periodData) }
        #expect(await yieldUntil { holding.isHoldingSave }, "the export is uploading its first chunk")
        let turnOff = Task {
            await phone.coordinator.setSealedBackupEnabled(false, payloadType: .periodData, deletingAnySlot: false)
        }
        #expect(await yieldUntil { phone.engine.disabling.contains(.periodData) }, "the turn-off is waiting for the engine")
        #expect(cloud.sealedRecords.isEmpty, "the turn-off has not deleted anything yet")

        holding.releaseHeldSave()
        #expect(await turnOff.value, "the delete landed")
        #expect(await !export.value, "the export was stopped, never finished")
        #expect(cloud.sealedRecords.isEmpty, "no chunk or head was written after the delete")

        await phone.coordinator.settlePeriodBackup()
        for _ in 0..<200 { await Task.yield() }
        #expect(cloud.sealedRecords.isEmpty, "and no later pass writes while the switch is off")
        #expect(phone.host.reuploadDeferrals[.periodData] == false, "nothing owed for a backup that is off")
    }

    /// The same finding's second half: "Stop syncing and delete iCloud data" turns sync off, then
    /// waits for the engine (``FernletStore/stopSealedBackupsBeforeCloudDelete()``) before its cloud
    /// delete — a commit mid-upload fails the sync gate before its next save, so nothing lands after
    /// `deleteAllCloudKitData`.
    @MainActor
    @Test func stoppingSyncAndDeletingICloudDataWritesNoSetAfterTheDelete() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let holding = HoldingCloudKitRecordDatabase(cloud.database)
        let phone = PeriodBackupDevice(cloud: cloud, writer: "phone", resolved: true, database: holding)
        try phone.seed((0..<300).map { PeriodBackupDevice.record(day: $0) })

        let export = Task { await phone.coordinator.setSealedBackupEnabled(true, payloadType: .periodData) }
        #expect(await yieldUntil { holding.isHoldingSave })
        phone.preferences.iCloudSyncEnabled = false
        let stopped = Task { await phone.engine.quiesce() }
        holding.releaseHeldSave()
        await stopped.value
        _ = try await PeriodBackupDevice.cloudDataService(cloud.database).deleteAllCloudKitData(
            confirmation: DeletionConfirmation(userTypedConfirmation: "DELETE")
        )
        #expect(await !export.value)
        for _ in 0..<200 { await Task.yield() }
        #expect(cloud.sealedRecords.isEmpty, "nothing landed after the cloud delete")
    }

    /// The Privacy & Data half of the same fix, read from source: the cloud delete runs only after the
    /// in-memory sync switch went off AND the engine was waited for.
    @Test func theCloudDeleteWaitsForTheEngineAfterSyncIsOff() throws {
        let source = try String(contentsOf: RepoRoot.url("App/Fernlet/PrivacyDataSettingsView.swift"), encoding: .utf8)
        let start = try #require(source.range(of: "private func disableICloudSyncAndDeleteCloudData()"))
        let body = String(source[start.upperBound...].prefix(4_000))
        let syncOff = try #require(body.range(of: "storagePreferencesStore.update { $0 = updated }"))
        let quiesce = try #require(body.range(of: "await store?.stopSealedBackupsBeforeCloudDelete()"))
        let delete = try #require(body.range(of: "deleteAllCloudKitData("))
        #expect(syncOff.upperBound <= quiesce.lowerBound && quiesce.upperBound <= delete.lowerBound)
    }

    // MARK: - G: the gates (BV2, BV3, BV18, BV21)

    /// BV2: nothing is fetched, opened, decrypted or written unless G holds — the hub closed, the
    /// surface hidden, a duress session, iCloud sync off and the backup off each stop a pass before any
    /// network work.
    @MainActor
    @Test func everyGateStopsAPassBeforeAnyNetworkWork() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let counting = CountingCloudKitRecordDatabase(cloud.database)
        let phone = PeriodBackupDevice(cloud: cloud, writer: "phone", database: counting)
        try phone.seed([PeriodBackupDevice.record(day: 1)])
        let key = phone.key

        phone.host.sealedBackupContentKey = nil
        #expect(await phone.engine.perform(.periodData, trigger: .hubSettle, phases: .both).gateFailure == .hubClosed)
        phone.host.sealedBackupContentKey = key
        phone.host.isPeriodTrackingVisible = false
        #expect(await phone.engine.perform(.periodData, trigger: .hubSettle, phases: .both).gateFailure == .surfaceClosed)
        phone.host.isPeriodTrackingVisible = true
        phone.host.duressSessionActive = true
        #expect(await phone.engine.perform(.periodData, trigger: .hubSettle, phases: .both).gateFailure == .duress)
        phone.host.duressSessionActive = false
        phone.preferences = StoragePreferences(sealedBackupPeriodEnabled: true)
        #expect(await phone.engine.perform(.periodData, trigger: .hubSettle, phases: .both).gateFailure == .backupOff)
        phone.preferences = StoragePreferences(iCloudSyncEnabled: true)
        #expect(await phone.engine.perform(.periodData, trigger: .hubSettle, phases: .both).gateFailure == .backupOff)
        #expect(counting.calls == 0, "no gate let a single CloudKit call through")

        phone.preferences = PeriodBackupDevice.backupOn
        #expect(await phone.engine.perform(.periodData, trigger: .hubSettle, phases: .both).gateFailure == nil)
        #expect(counting.calls > 0, "control: with every gate open the pass runs")
    }

    /// BV3 (R1-BR-12): G is re-checked after every await. A restore suspended in its head fetch while
    /// the surface is hidden opens nothing, merges nothing, records nothing, and drops the status.
    @MainActor
    @Test func aRestoreSuspendedInItsFetchWhileTheSurfaceHidesDecryptsNothing() async throws {
        let (cloud, phone, suspending) = try await suspendedRestore()
        defer { cloud.tearDown() }

        let opened = phone.engine.decryptCount
        phone.host.isPeriodTrackingVisible = false
        suspending.releaseHeldFetch()
        let report = await phone.pendingPass
        #expect(report?.gateFailure == .surfaceClosed)
        #expect(phone.engine.decryptCount == opened, "not even the head was opened")
        #expect(try phone.records.recordCount() == 0)
        #expect(phone.host.recordedOutcomes[.periodData] == nil)
        #expect(!phone.host.sealedBackupBookkeeping.isRestoreResolved(.periodData))
        #expect(phone.host.v2Status[.periodData] == nil)
    }

    /// BV18: a duress session that begins while a restore waits on CloudKit stops it at the next gate:
    /// nothing decrypted, merged or recorded.
    @MainActor
    @Test func aDuressSessionStopsASuspendedRestore() async throws {
        let (cloud, phone, suspending) = try await suspendedRestore()
        defer { cloud.tearDown() }

        let opened = phone.engine.decryptCount
        phone.host.duressSessionActive = true
        suspending.releaseHeldFetch()
        let report = await phone.pendingPass
        #expect(report?.gateFailure == .duress)
        #expect(phone.engine.decryptCount == opened, "not even the head was opened")
        #expect(try phone.records.recordCount() == 0)
        #expect(phone.host.recordedOutcomes[.periodData] == nil)
    }

    /// BV15 (R1-BR-1): "Delete everything" while a restore is suspended in a fake CloudKit fetch — the
    /// wipe raises its bracket and moves the work epoch — lands no row, no bookkeeping, no rollback
    /// floor and no outcome when the fetch resumes.
    @MainActor
    @Test func aRestoreResumedAfterDeleteAllLandsNothing() async throws {
        let (cloud, phone, suspending) = try await suspendedRestore()
        defer { cloud.tearDown() }

        let opened = phone.engine.decryptCount
        phone.host.deleteAllInProgress = true
        phone.host.sealedBackupWorkEpoch += 1
        suspending.releaseHeldFetch()
        let report = await phone.pendingPass
        phone.host.deleteAllInProgress = false
        #expect(report?.stopped == true)
        #expect(phone.engine.decryptCount == opened, "not even the head was opened")
        #expect(try phone.records.recordCount() == 0)
        #expect(!phone.host.sealedBackupBookkeeping.isRestoreResolved(.periodData))
        #expect(phone.acceptedStamp == nil)
        #expect(SealedBackupGenerationStore(defaults: phone.generationDefaults).lastSeen(for: .periodData) == 0)
        #expect(phone.host.recordedOutcomes[.periodData] == nil)
        #expect(phone.host.reuploadDeferrals[.periodData] == nil, "no dirty mark from a stopped restore")
    }

    /// BV15, the reset funnel: an app-lock reset (work epoch moved, owner hold set) while a restore is
    /// suspended — nothing lands.
    @MainActor
    @Test func aRestoreResumedAfterAnAppLockResetLandsNothing() async throws {
        let (cloud, phone, suspending) = try await suspendedRestore()
        defer { cloud.tearDown() }

        let opened = phone.engine.decryptCount
        phone.host.sealedBackupWorkEpoch += 1
        phone.host.sealedBackupRestoreAwaitsOwner = true
        suspending.releaseHeldFetch()
        let report = await phone.pendingPass
        #expect(report?.stopped == true)
        #expect(phone.engine.decryptCount == opened, "not even the head was opened")
        #expect(try phone.records.recordCount() == 0)
        #expect(!phone.host.sealedBackupBookkeeping.isRestoreResolved(.periodData))
        #expect(phone.acceptedStamp == nil)
    }

    /// BV15 via the quiesce itself: delete-all awaits ``SealedBackupV2Engine/quiesceForWipe()``; a pass
    /// suspended in a fetch is cancelled, resumes into a failed gate, and the quiesce returns only once
    /// it has stopped.
    @MainActor
    @Test func theWipesQuiesceWaitsForASuspendedPassAndItLandsNothing() async throws {
        let (cloud, phone, suspending) = try await suspendedRestore()
        defer { cloud.tearDown() }

        let opened = phone.engine.decryptCount
        let quiesce = Task { await phone.engine.quiesceForWipe() }
        for _ in 0..<50 { await Task.yield() }
        suspending.releaseHeldFetch()
        await quiesce.value
        #expect(await phone.pendingPass?.stopped == true)
        #expect(phone.engine.decryptCount == opened, "not even the head was opened")
        #expect(try phone.records.recordCount() == 0)
        #expect(!phone.host.sealedBackupBookkeeping.isRestoreResolved(.periodData))
    }

    /// BV21 (R2-F2): a store that is not attached (a load that failed leaves the controller running
    /// against an empty coordinator) never exports — an empty set would replace the cloud copy.
    @MainActor
    @Test func aStorelessControllerWritesNothingToICloud() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let phone = PeriodBackupDevice(cloud: cloud, writer: "phone", resolved: true)
        try phone.seed([PeriodBackupDevice.record(day: 1)])
        let coordinator = phone.controller.container.persistentStoreCoordinator
        for store in coordinator.persistentStores { try coordinator.remove(store) }
        #expect(!phone.records.isStoreHealthy)

        let report = await phone.engine.perform(.periodData, trigger: .enable, phases: .export)
        #expect(report.gateFailure == .storeUnhealthy)
        #expect(cloud.sealedRecords.isEmpty)
    }

    // MARK: - E2, the mint rule, the owner hold (BV4, BV13, BV16, BV20)

    /// BV20 (R2-F1): no pass mints an escrow key while a set exists in iCloud — a new iPhone whose
    /// synced key has not arrived waits (`.waitingForBackupKey`) instead of minting a divergent one.
    /// With no set anywhere it mints and exports.
    @MainActor
    @Test func noEscrowKeyIsMintedWhileABackupExists() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let first = PeriodBackupDevice(cloud: cloud, writer: "first", resolved: true)
        try first.seed([PeriodBackupDevice.record(day: 1)])
        #expect(await first.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))

        let bare = "com.fernlet.period-v2.bare.\(UUID().uuidString)"
        defer { KeychainItem.deleteAll(service: bare) }
        let newPhone = PeriodBackupDevice(cloud: cloud, writer: "new", resolved: true, keychainService: bare)
        try newPhone.seed([PeriodBackupDevice.record(day: 2)])
        #expect(await newPhone.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))
        #expect(newPhone.host.v2Status[.periodData] == .waitingForBackupKey)
        #expect(!Self.holdsEscrowKey(bare), "no key was minted beside the one still syncing")

        let emptyCloud = try PeriodBackupDevice.makeCloud()
        defer { emptyCloud.tearDown() }
        let alone = "com.fernlet.period-v2.alone.\(UUID().uuidString)"
        defer { KeychainItem.deleteAll(service: alone) }
        let firstEver = PeriodBackupDevice(cloud: emptyCloud, writer: "only", resolved: true, keychainService: alone)
        try firstEver.seed([PeriodBackupDevice.record(day: 3)])
        #expect(await firstEver.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))
        #expect(Self.holdsEscrowKey(alone), "with no backup anywhere the export mints its key")
        #expect(firstEver.host.v2Status[.periodData] == .upToDate)
    }

    /// BV16 (R1-BR-15): while an app-lock reset waits for the device owner, NO restore runs — the
    /// user's Retry and "Restore it here" included. Only the owner-checked release clears the hold.
    @MainActor
    @Test func theOwnerHoldStopsEveryRestoreTriggerTheRetryIncluded() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let first = PeriodBackupDevice(cloud: cloud, writer: "first", resolved: true)
        try first.seed([PeriodBackupDevice.record(day: 1)])
        #expect(await first.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))
        let head = try #require(try await PeriodBackupDevice.cloudHead(cloud))

        let phone = PeriodBackupDevice(cloud: cloud, writer: "phone")
        phone.host.sealedBackupRestoreAwaitsOwner = true
        #expect(await phone.coordinator.restorePeriodBackup(initiatedByUser: true) == .deferredTransient)
        await phone.coordinator.restorePeriodBackupHere(head)
        await phone.coordinator.restoreSealedBackupsIfNeeded(userInitiated: true)
        #expect(try phone.records.recordCount() == 0, "neither the Retry nor the explicit restore ran")
        #expect(phone.host.sealedBackupRestoreAwaitsOwner, "and none of them released the hold")

        await phone.coordinator.releaseRestoreHoldForOwner()
        #expect(!phone.host.sealedBackupRestoreAwaitsOwner)
        #expect(try phone.records.recordCount() == 1, "the owner's release restores")
    }

    /// Design §4.6 / §4.8 item 16 (R2-F7): the owner's "Restore" releases the hold ON THE TAP — in
    /// Settings, where the Private tab is closed and no restore can run yet — and persists it; the
    /// restore then runs at the next settle. E1 keeps every export waiting until that merge has run.
    @MainActor
    @Test func theOwnersReleaseTakesEffectOnTheTapWithThePrivateTabClosed() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let first = PeriodBackupDevice(cloud: cloud, writer: "first", resolved: true)
        try first.seed([PeriodBackupDevice.record(day: 1)])
        #expect(await first.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))
        let firstSet = cloud.sealedRecordIdentities

        let phone = PeriodBackupDevice(cloud: cloud, writer: "phone")
        phone.host.restoreHold.hold(keepingCopiesFrom: PeriodBackupDevice.backupOn)
        let key = phone.key
        phone.host.sealedBackupContentKey = nil
        try phone.seed([PeriodBackupDevice.record(day: 4)], key: key)

        await phone.coordinator.releaseRestoreHoldForOwner()
        #expect(!phone.host.sealedBackupRestoreAwaitsOwner, "released on the tap")
        #expect(try phone.records.recordCount() == 1 && cloud.sealedRecordIdentities == firstSet, "nothing ran yet")

        phone.host.sealedBackupContentKey = key
        await phone.coordinator.settlePeriodBackup()
        #expect(try phone.records.recordCount() == 2, "the next settle restored")
        #expect(try await PeriodBackupDevice.cloudRecordIDs(cloud) == Set(try phone.records.allIDs()), "then exported the union")
    }

    /// BV13 (R1-BR-2): a clone set up from an iPhone device backup — the bookkeeping travels (a high
    /// rollback floor, the original's accepted head, a resolved marker) but the install tag and the
    /// signing key do not. Off at the first settle, then turned on: the travelled accepted head reads
    /// as absent, so the original's set is held, never replaced; with its marker reopened (the "can't
    /// open" check) the clone merges it first.
    @MainActor
    @Test func aDeviceBackupCloneNeverReplacesTheOriginalsSet() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let original = PeriodBackupDevice(cloud: cloud, writer: "original", resolved: true)
        try original.seed([PeriodBackupDevice.record(day: 1)])
        #expect(await original.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))
        let originalSet = cloud.sealedRecordIdentities
        let originalHead = try #require(try await PeriodBackupDevice.cloudHead(cloud))
        let travelled = try #require(original.host.sealedBackupBookkeeping.acceptedHead(.periodData, installTag: original.writer))

        let clone = PeriodBackupDevice(cloud: cloud, writer: "clone", resolved: true,
                                       preferences: StoragePreferences(iCloudSyncEnabled: true))
        clone.host.sealedBackupBookkeeping.recordAcceptedHead(travelled, .periodData, installTag: original.writer)
        var floor = SealedBackupGenerationStore(defaults: clone.generationDefaults)
        floor.recordAccepted(9, for: .periodData)
        try clone.seed([PeriodBackupDevice.record(day: 2)])
        await clone.coordinator.settlePeriodBackup()
        #expect(cloud.sealedRecordIdentities == originalSet)

        clone.preferences = PeriodBackupDevice.backupOn
        #expect(await clone.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))
        #expect(cloud.sealedRecordIdentities == originalSet, "the original's set is never replaced by the clone")
        #expect(clone.host.periodExportState == .heldByAnotherDevice(originalHead))

        clone.host.sealedBackupBookkeeping.reopenRestore(.periodData)
        await clone.coordinator.restorePeriodBackupHere(originalHead)
        #expect(try clone.records.recordCount() == 2, "an explicit restore merges the original's set in")
        #expect(!clone.host.sealedBackupBookkeeping.isRestoreResolved(.periodData),
                "\"Restore it here\" leaves the restore marker alone (R1-BR-4)")
        #expect(cloud.sealedRecordIdentities == originalSet, "and E1 still holds the export until the restore resolves")
    }

    /// §4.2 X8 (R1-BR-3): after the head save the commit re-fetches the head and requires this set's
    /// generation and salt. A head that never landed (the transport answered success, the server kept
    /// the old one) fails the verify: no bookkeeping, the upload stays owed, and the next pass decides.
    @MainActor
    @Test func aCommitWhoseHeadDidNotLandFailsItsVerify() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let dropping = HeadDroppingCloudKitRecordDatabase(cloud.database)
        let phone = PeriodBackupDevice(cloud: cloud, writer: "phone", resolved: true, database: dropping)
        try phone.seed([PeriodBackupDevice.record(day: 1)])

        #expect(await phone.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))
        #expect(phone.host.v2Status[.periodData] == .failed, "the verify found no head of this set")
        #expect(phone.acceptedStamp == nil)
        #expect(SealedBackupGenerationStore(defaults: phone.generationDefaults).lastSeen(for: .periodData) == 0)
        #expect(phone.host.reuploadDeferrals[.periodData] == true)

        dropping.dropsHeads = false
        #expect(await phone.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))
        #expect(phone.host.v2Status[.periodData] == .upToDate)
        #expect(phone.acceptedStamp == PeriodBackupDevice.stamp("phone", 1), "a verified commit, recorded")
    }

    /// Design §9, R2-F3 / BV27: turning this iPhone's switch off while the slot is observed as another
    /// iPhone's KEEPS that backup; "Delete everything" deletes every enabled set whoever wrote it —
    /// set-scoped suffix chunks included.
    @MainActor
    @Test func turningOffKeepsAnotherIPhonesSlotAndDeleteAllDeletesEveryChunk() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let first = PeriodBackupDevice(cloud: cloud, writer: "first", resolved: true)
        try first.seed((0..<300).map { PeriodBackupDevice.record(day: $0) })
        #expect(await first.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))
        let firstSet = cloud.sealedRecordIdentities
        #expect(firstSet.count == 2)

        let second = PeriodBackupDevice(cloud: cloud, writer: "second", resolved: true)
        try second.seed([PeriodBackupDevice.record(day: 9)])
        #expect(await second.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))
        #expect(second.host.periodExportState == .heldByAnotherDevice(PeriodBackupDevice.stamp("first", 1)))

        #expect(await second.coordinator.setSealedBackupEnabled(false, payloadType: .periodData, deletingAnySlot: false))
        #expect(cloud.sealedRecordIdentities == firstSet, "the other iPhone's backup stays in iCloud")
        #expect(second.host.sealedBackupBookkeeping.observedHead(.periodData, installTag: second.writer) != nil)

        #expect(await second.coordinator.setSealedBackupEnabled(false, payloadType: .periodData, deletingAnySlot: true))
        #expect(cloud.sealedRecords.isEmpty, "delete-all's turn-off deletes the head AND every chunk.<i>.<set>")
        #expect(second.host.sealedBackupBookkeeping.observedHead(.periodData, installTag: second.writer) == nil)
    }

    /// BV22 (R2-F12): "Remove them" is an intent carried out at the next pass: it re-classifies the
    /// shown ids and deletes only those still dead — never an id the pause did not name — then the
    /// export writes the rest.
    @MainActor
    @Test func removeThemDeletesOnlyTheShownIDsThatAreStillDead() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let phone = PeriodBackupDevice(cloud: cloud, writer: "phone", resolved: true)
        let good = PeriodBackupDevice.record(day: 1)
        let dead = PeriodBackupDevice.record(day: 2)
        try phone.seed([good])
        try phone.seed([dead], key: SymmetricKey(size: .bits256))
        #expect(await phone.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))
        #expect(phone.host.v2Status[.periodData] == .paused(unopenableIDs: [dead.id]))

        let neverShown = UUID()
        phone.engine.recordIntent(.remove([dead.id, neverShown, good.id]), for: .periodData)
        let report = await phone.engine.perform(.periodData, trigger: .remove([dead.id, neverShown, good.id]), phases: .export)
        #expect(report.exportStatus == .upToDate)
        #expect(try Set(phone.records.allIDs()) == [good.id], "only the shown, still-dead row went; the openable one stayed")
        #expect(try await PeriodBackupDevice.cloudRecordIDs(cloud) == [good.id])
        #expect(phone.engine.intents[.periodData] == nil, "the intent was carried out")
    }

    /// §4.6: an explicit choice made in Settings (the Private tab closed) is an in-memory intent the
    /// next hub settle carries out; until then nothing runs.
    @MainActor
    @Test func anExplicitChoiceWaitsForTheNextHubSettle() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let first = PeriodBackupDevice(cloud: cloud, writer: "first", resolved: true)
        try first.seed([PeriodBackupDevice.record(day: 1)])
        #expect(await first.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))
        let head = try #require(try await PeriodBackupDevice.cloudHead(cloud))

        let phone = PeriodBackupDevice(cloud: cloud, writer: "phone", resolved: true)
        let key = phone.key
        phone.host.sealedBackupContentKey = nil
        await phone.coordinator.restorePeriodBackupHere(head)
        #expect(try phone.records.recordCount() == 0, "nothing runs in Settings")
        #expect(phone.engine.intents[.periodData] == .restoreHere(head, ignoringRollback: true))

        phone.host.sealedBackupContentKey = key
        await phone.coordinator.settlePeriodBackup()
        #expect(try phone.records.recordCount() == 1, "the next settle carried the choice out")
        #expect(phone.engine.intents[.periodData] == nil)
    }

    /// §5.5: a head that opens but whose envelope this build cannot read (a newer build's `"v": 3`) is
    /// never overwritten — not by an automatic export and not by "Start a new backup" — and the export
    /// names it `.needsNewerFernlet`.
    @MainActor
    @Test func aHeadANewerBuildWroteIsNeverOverwritten() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let writer = try PeriodBackupDevice.reader(cloud)
        let tag = PeriodBackupDevice.tag("newer")
        let plaintext = Data(#"{"v":3,"writer":"\#(tag)","set":"\#(tag)","total":0,"records":[]}"#.utf8)
        let head = try writer.sealChunk(plaintext, payloadType: .periodData, chunkIndex: 0, chunkCount: 1,
                                        generation: 5, keySalt: SealedBackupService.mintKeySalt())
        try await writer.save(head, setTag: tag)
        let newerSet = cloud.sealedRecordIdentities

        let phone = PeriodBackupDevice(cloud: cloud, writer: "phone", resolved: true)
        try phone.seed([PeriodBackupDevice.record(day: 1)])
        #expect(await phone.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))
        #expect(phone.host.v2Status[.periodData] == .needsNewerFernlet)
        await phone.coordinator.startNewPeriodBackup()
        #expect(cloud.sealedRecordIdentities == newerSet, "never written over, even by Start new")
        #expect(phone.host.v2Status[.periodData] == .needsNewerFernlet)
    }

    // MARK: - Commit atomicity, set verification, prune (BV6, BV7, §5.2)

    /// BV6 (R1-BR-3, R2-F6): an export stopped part-way — here by a wipe after its first suffix save —
    /// leaves the PREVIOUS head and its whole set untouched and restorable: the new suffix chunk went
    /// under the new set's own name, so it is an orphan, never a mixed set.
    @MainActor
    @Test func anInterruptedExportLeavesThePreviousSetWholeAndRestorable() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let interrupting = InterruptingCloudKitRecordDatabase(cloud.database)
        let phone = PeriodBackupDevice(cloud: cloud, writer: "phone", resolved: true, database: interrupting)
        let history = (0..<300).map { PeriodBackupDevice.record(day: $0) }
        try phone.seed(history)
        #expect(await phone.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))
        let previous = try #require(try await PeriodBackupDevice.cloudHead(cloud))

        try phone.seed((300..<320).map { PeriodBackupDevice.record(day: $0) })
        interrupting.onFirstSave = { phone.host.sealedBackupWorkEpoch += 1 }
        #expect(await !phone.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))

        #expect(try await PeriodBackupDevice.cloudHead(cloud) == previous, "the head is the previous set's")
        #expect(cloud.sealedRecords.count == 3, "the previous two chunks plus one orphan of the stopped set")
        let restorer = PeriodBackupDevice(cloud: cloud, writer: "restorer")
        #expect(await restorer.coordinator.restorePeriodBackup() == .restored(300), "and it restores whole")
    }

    /// BV7 (§5.3): a restore verifies the set before decoding a record — a suffix chunk spliced in from
    /// another set at the same generation (different salt, writer, set) fails closed, merging nothing.
    @MainActor
    @Test func aChunkSplicedInFromAnotherSetFailsClosed() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let a = PeriodBackupDevice(cloud: cloud, writer: "a", resolved: true)
        try a.seed((0..<300).map { PeriodBackupDevice.record(day: $0) })
        #expect(await a.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))
        let aSuffix = try #require(cloud.sealedRecords.first { $0.recordID.recordName.contains(".chunk.") })
        cloud.database.recordsByType["SealedBackupRecord"] = []

        let b = PeriodBackupDevice(cloud: cloud, writer: "b", resolved: true)
        try b.seed((500..<800).map { PeriodBackupDevice.record(day: $0) })
        #expect(await b.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))
        let bSuffix = try #require(cloud.sealedRecords.first { $0.recordID.recordName.contains(".chunk.") })
        let renamed = CKRecord(recordType: "SealedBackupRecord", recordID: bSuffix.recordID)
        for key in aSuffix.allKeys() where key != "encryptedBlob" { renamed[key] = aSuffix[key] }
        let blob = try #require((aSuffix["encryptedBlob"] as? CKAsset)?.fileURL)
        renamed["encryptedBlob"] = CKAsset(fileURL: blob)
        try await cloud.database.saveRecords([renamed])

        let restorer = PeriodBackupDevice(cloud: cloud, writer: "restorer")
        #expect(await restorer.coordinator.restorePeriodBackup() == .deferredTransient)
        #expect(try restorer.records.recordCount() == 0, "nothing from a set that does not verify")
    }

    /// BV7 (§5.3), arm by arm: a two-chunk set whose suffix chunk disagrees with its head in exactly ONE
    /// property — its envelope's writer, its envelope's set (it was fetched under the head's set name),
    /// its salt, or its shape (a v1 bare array behind a v2 head) — or whose head names a total its
    /// records do not reach fails closed and merges nothing; the same set untampered restores whole.
    @MainActor
    @Test(arguments: SetTamper.allCases)
    func everySetCheckFailsClosedOnItsOwn(_ tamper: SetTamper) async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        try await Self.writeTwoChunkSet(cloud, tamper)
        let restorer = PeriodBackupDevice(cloud: cloud, writer: "restorer")
        let outcome = await restorer.coordinator.restorePeriodBackup()
        if tamper == .none {
            #expect(outcome == .restored(2), "the untampered set restores whole")
            #expect(try restorer.records.recordCount() == 2)
        } else {
            #expect(outcome == .deferredTransient, "\(tamper): a set that does not verify fails closed")
            #expect(try restorer.records.recordCount() == 0, "\(tamper): nothing from a set that does not verify")
            #expect(!restorer.host.sealedBackupBookkeeping.isRestoreResolved(.periodData))
        }
    }

    /// The one property ``everySetCheckFailsClosedOnItsOwn(_:)`` breaks.
    enum SetTamper: CaseIterable, Sendable {
        case none, writer, set, salt, v1Suffix, total
    }

    /// Writes a two-chunk v2 period set into `cloud` as another install — head and suffix under the
    /// head's set name, at generation 5 — with `tamper` applied.
    @MainActor
    static func writeTwoChunkSet(_ cloud: FakeSealedBackupCloud, _ tamper: SetTamper) async throws {
        let sealer = try PeriodBackupDevice.reader(cloud)
        let writer = PeriodBackupDevice.tag("crafted")
        let set = SealedBackupSetTag.mint()
        let salt = SealedBackupService.mintKeySalt()
        let head = SealedBackupV2Envelope(writer: writer, set: set, total: tamper == .total ? 3 : 2,
                                          records: [PeriodBackupDevice.record(day: 1)])
        let suffixPlaintext = tamper == .v1Suffix ? Data("[]".utf8) : try SealedBackupV2Format.encode(SealedBackupV2Envelope(
            writer: tamper == .writer ? PeriodBackupDevice.tag("another") : writer,
            set: tamper == .set ? SealedBackupSetTag.mint() : set,
            total: nil, records: [PeriodBackupDevice.record(day: 2)]
        ))
        let suffix = try sealer.sealChunk(suffixPlaintext, payloadType: .periodData, chunkIndex: 1, chunkCount: 2, generation: 5,
                                          keySalt: tamper == .salt ? SealedBackupService.mintKeySalt() : salt)
        let headRecord = try sealer.sealChunk(try SealedBackupV2Format.encode(head), payloadType: .periodData, chunkIndex: 0,
                                              chunkCount: 2, generation: 5, keySalt: salt)
        try await sealer.save(suffix, setTag: set)
        try await sealer.save(headRecord, setTag: set)
    }

    /// §5.2's prune: after a commit, every unscoped (v1) suffix chunk and every chunk of another set
    /// BELOW the committed generation goes; a set at the SAME generation stays (its head may be landing
    /// on another iPhone), and so does the committed set.
    @MainActor
    @Test func thePruneKeepsAConcurrentSetAtTheSameGeneration() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let service = PeriodBackupDevice.cloudDataService(cloud.database)
        let kept = PeriodBackupDevice.tag("kept")
        let concurrent = PeriodBackupDevice.tag("concurrent")
        let older = PeriodBackupDevice.tag("older")
        try await service.saveSealedBackup(Self.fakeChunk(generation: 2), setTag: kept)
        try await service.saveSealedBackup(Self.fakeChunk(generation: 2), setTag: concurrent)
        try await service.saveSealedBackup(Self.fakeChunk(generation: 1), setTag: older)
        try await service.saveSealedBackup(Self.fakeChunk(generation: 1), setTag: nil)

        let pruned = try await service.pruneSealedBackupSets(payloadType: .periodData, keepingSetTag: kept, belowGeneration: 2)
        let names = Set(cloud.sealedRecords.map(\.recordID.recordName))
        #expect(pruned == 2)
        #expect(names == ["sealed-backup.periodData.chunk.1.\(kept)", "sealed-backup.periodData.chunk.1.\(concurrent)"])
    }

    // MARK: - Spacing (BV23) and the serial worker

    /// BV23 (§4.5, R2-F5): an automatic export runs at most once per hub session; a change after it
    /// waits for the next session. A failed automatic export backs off 15 minutes, across sessions.
    @MainActor
    @Test func automaticExportsAreSpacedPerHubSessionAndBackOffAfterAFailure() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let clock = ManualClock()
        let flaky = SaveFailingCloudKitRecordDatabase(cloud.database)
        let phone = PeriodBackupDevice(cloud: cloud, writer: "phone", resolved: true, database: flaky, clock: { clock.now })
        try phone.seed([PeriodBackupDevice.record(day: 1)])

        await phone.coordinator.settlePeriodBackup()
        let first = cloud.sealedRecordIdentities
        #expect(!first.isEmpty)
        try phone.seed([PeriodBackupDevice.record(day: 2)])
        await phone.coordinator.settlePeriodBackup()
        #expect(cloud.sealedRecordIdentities == first, "once per hub session")
        phone.engine.hubSessionEnded()
        await phone.coordinator.settlePeriodBackup()
        #expect(cloud.sealedRecordIdentities != first, "the next session exports the change")

        try phone.seed([PeriodBackupDevice.record(day: 3)])
        flaky.failsSaves = true
        phone.engine.hubSessionEnded()
        await phone.coordinator.settlePeriodBackup()
        #expect(phone.host.v2Status[.periodData] == .failed)
        let attempts = flaky.saveAttempts
        flaky.failsSaves = false
        phone.engine.hubSessionEnded()
        clock.advance(10 * 60)
        await phone.coordinator.settlePeriodBackup()
        #expect(flaky.saveAttempts == attempts, "within 15 minutes of a failure nothing is retried")
        phone.engine.hubSessionEnded()
        clock.advance(6 * 60)
        await phone.coordinator.settlePeriodBackup()
        #expect(phone.host.v2Status[.periodData] == .upToDate, "after the backoff it exports")
        #expect(phone.host.reuploadDeferrals[.periodData] == false)
    }

    /// BV23, the probe: on a clean visit E2 reads only the head's METADATA and decrypts nothing when it
    /// is this install's accepted head; at most once per session and 15 minutes apart.
    @MainActor
    @Test func aCleanVisitProbesTheHeadWithoutDecrypting() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let clock = ManualClock()
        let counting = CountingCloudKitRecordDatabase(cloud.database)
        let phone = PeriodBackupDevice(cloud: cloud, writer: "phone", resolved: true, database: counting, clock: { clock.now })
        try phone.seed([PeriodBackupDevice.record(day: 1)])
        #expect(await phone.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))
        #expect(phone.host.reuploadDeferrals[.periodData] == false)

        phone.engine.hubSessionEnded()
        clock.advance(20 * 60)
        let saves = counting.saves
        let fetches = counting.fetches
        let opened = phone.engine.decryptCount
        await phone.coordinator.settlePeriodBackup()
        #expect(phone.engine.decryptCount == opened, "the accepted head is recognised by its metadata: nothing decrypted")
        #expect(counting.saves == saves, "a clean, unchanged slot writes nothing")
        #expect(counting.fetches == fetches + 1, "one head fetch: the probe")
        #expect(phone.host.v2Status[.periodData] == .upToDate)
        await phone.coordinator.settlePeriodBackup()
        #expect(counting.fetches == fetches + 1, "at most one probe per hub session")
    }

    /// R1-BR-10 / §4.2 X5: the head vanished (deleted elsewhere) while this install's backup is on and
    /// resolved — the probe marks the upload owed and the same pass writes a fresh set.
    @MainActor
    @Test func aVanishedHeadIsReExportedInTheSamePass() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let phone = PeriodBackupDevice(cloud: cloud, writer: "phone", resolved: true)
        try phone.seed([PeriodBackupDevice.record(day: 1)])
        #expect(await phone.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))
        cloud.database.recordsByType["SealedBackupRecord"] = []

        phone.engine.hubSessionEnded()
        await phone.coordinator.settlePeriodBackup()
        #expect(try await PeriodBackupDevice.cloudRecordIDs(cloud) == Set(try phone.records.allIDs()))
        #expect(phone.host.reuploadDeferrals[.periodData] == false)
    }

    /// Design §4.3 / BV14 (R1-BR-11): the marker is seeded ONCE from the legacy latch and, while the
    /// backup is on, the seed owes one export — so every install writes one complete v2 set at its
    /// first Private visit. A present marker is never re-seeded.
    @MainActor
    @Test func theOneTimeSeedOwesOneExportWhileTheBackupIsOn() {
        let store = makeTestStore()
        let defaults = UserDefaults(suiteName: "fernlet.tests.v2Seed.\(UUID().uuidString)") ?? .standard
        store.sealedBackupBookkeeping = SealedBackupBookkeeping(defaults: defaults, legacyLatch: { _ in true })
        store.sealedBackupPreferencesProvider = { PeriodBackupDevice.backupOn }
        store.recordSealedBackupReuploadDeferred(false, payloadType: .periodData)

        store.seedSealedBackupBookkeepingOnce()
        #expect(store.sealedBackupBookkeeping.restoreResolvedIsSet(.periodData), "seeded from the latch")
        #expect(store.sealedBackupPeriodReuploadDeferred, "and one export is owed")
        #expect(store.sealedBackupMutationEpoch(.periodData) == 1)

        store.recordSealedBackupReuploadDeferred(false, payloadType: .periodData)
        store.seedSealedBackupBookkeepingOnce()
        #expect(!store.sealedBackupPeriodReuploadDeferred, "a present marker is never re-seeded")

        let off = makeTestStore()
        off.sealedBackupBookkeeping = SealedBackupBookkeeping(
            defaults: UserDefaults(suiteName: "fernlet.tests.v2SeedOff.\(UUID().uuidString)") ?? .standard,
            legacyLatch: { _ in false }
        )
        off.sealedBackupPreferencesProvider = { StoragePreferences(iCloudSyncEnabled: true) }
        off.recordSealedBackupReuploadDeferred(false, payloadType: .periodData)
        off.seedSealedBackupBookkeepingOnce()
        #expect(off.sealedBackupBookkeeping.seedRestoreMarkerIfAbsent(.periodData) == false, "seeded once")
        #expect(!off.sealedBackupPeriodReuploadDeferred, "a backup that is off owes nothing")
    }

    /// BV1 (the shrinking allowlist, now empty): every payload — period, intimate logs and, since unit
    /// B3, the journal — reaches a chunk upload only through the engine. No app file calls the legacy
    /// in-place `reconcileChunked` writer any more, and the engine's set-scoped `save` is called only
    /// by its commit.
    @Test func theV2PayloadsReachTheUploadOnlyThroughTheEngine() throws {
        let app = RepoRoot.url("App/Fernlet")
        let files = try FileManager.default.contentsOfDirectory(at: app, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        var legacyCallers: [String] = []
        var setScopedSavers: [String] = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for line in source.split(separator: "\n") where line.contains(".reconcileChunked(payloadType:") {
                legacyCallers.append("\(file.lastPathComponent): \(line.trimmingCharacters(in: .whitespaces))")
            }
            if source.contains(".save(record, setTag:") { setScopedSavers.append(file.lastPathComponent) }
        }
        #expect(legacyCallers.isEmpty, "no payload may write in place any more: \(legacyCallers)")
        #expect(setScopedSavers == ["SealedBackupV2Engine+Commit.swift"])
    }

    /// BV24 (§4.2 X7): the prepare's two size bounds. A snapshot over 100 000 records is refused as
    /// `.tooLarge` before a single chunk is read or decrypted, and a set whose sealed chunks pass
    /// 64 MB is refused as soon as they do — nothing saved to iCloud, the rollback mark unmoved.
    @MainActor
    @Test func anOversizeSetIsRefusedAsTooLargeBeforeAnythingIsSaved() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let phone = PeriodBackupDevice(cloud: cloud, writer: "oversize", resolved: true)
        let service = try PeriodBackupDevice.reader(cloud)
        let mark = service.lastSeenGeneration(for: .periodData)

        let tooMany = OversizeBackupAdapter(idCount: SealedBackupV2Engine.maxRecords + 1, recordCharacters: 1)
        let counted = try await phone.engine.prepare(tooMany, service: service, floor: 0, epoch: phone.engine.currentEpoch())
        guard case .refused(.tooLarge) = counted else {
            Issue.record("a snapshot over 100 000 records must be refused as too large, got \(counted)")
            return
        }
        #expect(tooMany.chunkReads == 0, "refused on the snapshot's size, before any chunk is read")

        let tooBig = OversizeBackupAdapter(idCount: 1, recordCharacters: SealedBackupV2Engine.maxPreparedBytes + 1)
        let sized = try await phone.engine.prepare(tooBig, service: service, floor: 0, epoch: phone.engine.currentEpoch())
        guard case .refused(.tooLarge) = sized else {
            Issue.record("a set over 64 MB sealed must be refused as too large, got \(sized)")
            return
        }
        #expect(tooBig.chunkReads == 1)

        #expect(try await PeriodBackupDevice.cloudHead(cloud) == nil, "nothing was saved")
        #expect(service.lastSeenGeneration(for: .periodData) == mark, "the rollback mark is unmoved")
    }

    // MARK: - Fix round 1 (review of B1)

    /// B1-C-B1-1 / B1-D-B1-R1: a first install with no escrow key anywhere, whose cycle backup is the
    /// only one turned on, is backed up. The restore reads the head's existence without a key — none,
    /// so nothing is waiting and the restore resolves — and the export's mint rule mints exactly one
    /// key and commits. (Before: the keyless restore deferred before its fetch, the marker never
    /// resolved, E1 held every export and the only mint sat behind E1.)
    @MainActor
    @Test func aFirstInstallWithNoEscrowKeyMintsOneKeyAndIsBackedUp() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let bare = "com.fernlet.period-v2.firstInstall.\(UUID().uuidString)"
        defer { KeychainItem.deleteAll(service: bare) }
        let phone = PeriodBackupDevice(cloud: cloud, writer: "only", keychainService: bare)
        try phone.seed([PeriodBackupDevice.record(day: 1)])

        #expect(await phone.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))
        await phone.coordinator.settlePeriodBackup()
        #expect(phone.host.sealedBackupBookkeeping.isRestoreResolved(.periodData), "no backup anywhere: nothing to wait for")
        #expect(PeriodBackupDevice.escrowKeyCount(bare) == 1, "exactly one key minted")
        #expect(phone.host.v2Status[.periodData] == .upToDate)
        #expect(try await PeriodBackupDevice.cloudRecordIDs(cloud, keychainService: bare) == Set(try phone.records.allIDs()))
    }

    /// B1-D-B1-R1: a restore that waits on a set this iPhone cannot open (its key has not synced) is
    /// not a dead end — Privacy & Data names it as waiting for its key (B1 fix round 2 N-1) and offers
    /// the confirmed "Start a new backup", which writes this iPhone's history over it and resolves the
    /// restore. Nothing is minted before that choice.
    @MainActor
    @Test func aRestoreWaitingOnASetItCannotOpenOffersStartNew() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let first = PeriodBackupDevice(cloud: cloud, writer: "first", resolved: true)
        try first.seed([PeriodBackupDevice.record(day: 1)])
        #expect(await first.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))
        let bare = "com.fernlet.period-v2.keyless.\(UUID().uuidString)"
        defer { KeychainItem.deleteAll(service: bare) }
        let phone = PeriodBackupDevice(cloud: cloud, writer: "phone", keychainService: bare)
        try phone.seed([PeriodBackupDevice.record(day: 2)])

        await phone.coordinator.settlePeriodBackup()
        #expect(phone.host.recordedOutcomes[.periodData] == .deferredKeyNotSynced)
        #expect(PeriodBackupDevice.escrowKeyCount(bare) == 0, "nothing minted beside the key still syncing")
        #expect(phone.host.periodExportState == .waitingForKey, "named as waiting, with Start a new backup")

        await phone.coordinator.startNewPeriodBackup()
        #expect(try await PeriodBackupDevice.cloudHead(cloud, keychainService: bare)?.writer == phone.writer)
        #expect(phone.host.sealedBackupBookkeeping.isRestoreResolved(.periodData))
    }

    /// B1-D-B1-R1 (design §4.6): a restore refused as older than one this iPhone has seen names that set
    /// with both choices. "Restore it here" merges it; the set this install then accepted is no rollback
    /// of itself, so the next visit's restore resolves and the export follows. (Before: no choice was
    /// offered and every later restore refused the same set again, holding every export behind E1.)
    @MainActor
    @Test func aRolledBackRestoreOffersBothChoicesAndThenResolves() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let first = PeriodBackupDevice(cloud: cloud, writer: "first", resolved: true)
        try first.seed([PeriodBackupDevice.record(day: 1)])
        #expect(await first.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))
        let head = PeriodBackupDevice.stamp("first", 1)
        let phone = PeriodBackupDevice(cloud: cloud, writer: "phone")
        var floor = SealedBackupGenerationStore(defaults: phone.generationDefaults)
        floor.recordAccepted(9, for: .periodData)
        try phone.seed([PeriodBackupDevice.record(day: 5)])

        await phone.coordinator.settlePeriodBackup()
        #expect(phone.host.recordedOutcomes[.periodData] == .rolledBack)
        #expect(phone.host.periodExportState == .olderThanSeen(head), "both choices are offered for the refused set")

        await phone.coordinator.restorePeriodBackupHere(head)
        #expect(try phone.records.recordCount() == 2)
        phone.engine.hubSessionEnded()
        await phone.coordinator.settlePeriodBackup()
        #expect(phone.host.sealedBackupBookkeeping.isRestoreResolved(.periodData), "the accepted set is no rollback of itself")
        #expect(try await PeriodBackupDevice.cloudHead(cloud)?.writer == phone.writer, "and the export follows")
    }

    /// B1-C-B1-2 / B1-D-B1-R2: an iPhone erased and put back from an older device backup of ITSELF
    /// (the same install tag and keychain; the older store, accepted head and floor) finds a newer set
    /// under its own tag. It never writes its older history over it: the restore reopens and merges
    /// that set, and the export then publishes the union — the entry made after the backup survives
    /// on the iPhone and in iCloud. (Unit 5 held this case; B1 had dropped the guard.)
    @MainActor
    @Test func anIPhoneRestoredFromAnOlderBackupOfItselfMergesItsNewerSetFirst() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let phone = PeriodBackupDevice(cloud: cloud, writer: "phone", resolved: true)
        let early = PeriodBackupDevice.record(day: 1)
        try phone.seed([early])
        #expect(await phone.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))
        // The device backup is taken now: the store, the bookkeeping and the floor as they stand.
        let backedUpAccepted = try #require(phone.host.sealedBackupBookkeeping.acceptedHead(.periodData, installTag: phone.writer))
        let backedUpInFlight = phone.host.sealedBackupBookkeeping.inFlightGeneration(.periodData, installTag: phone.writer)
        let later = PeriodBackupDevice.record(day: 2)
        try phone.seed([later])
        phone.engine.hubSessionEnded()
        await phone.coordinator.settlePeriodBackup()
        #expect(try await PeriodBackupDevice.cloudHead(cloud) == PeriodBackupDevice.stamp("phone", 2))

        let restored = PeriodBackupDevice(cloud: cloud, writer: "phone", resolved: true, keychainService: phone.keychainService)
        restored.host.sealedBackupBookkeeping.recordAcceptedHead(backedUpAccepted, .periodData, installTag: restored.writer)
        if let backedUpInFlight {
            restored.host.sealedBackupBookkeeping.recordInFlight(backedUpInFlight, .periodData, installTag: restored.writer)
        }
        var floor = SealedBackupGenerationStore(defaults: restored.generationDefaults)
        floor.recordAccepted(1, for: .periodData)
        try restored.seed([early])

        await restored.coordinator.settlePeriodBackup()
        await restored.coordinator.settlePeriodBackup()
        #expect(try Set(restored.records.allIDs()) == [early.id, later.id], "the entry made after the backup came back")
        #expect(try await PeriodBackupDevice.cloudRecordIDs(cloud) == [early.id, later.id], "and iCloud never lost it")
        #expect(restored.host.sealedBackupBookkeeping.isRestoreResolved(.periodData))
    }

    /// B1-C-B1-3: a "Replace" chosen in Settings and still pending when the app lock is reset does not
    /// outlive the reset — the reset drops every pending choice — so the owner's "Restore" runs the
    /// restore the hold kept (before: the pending Replace took the release's place, skipped the restore
    /// and sat behind the hold for the rest of the process).
    @MainActor
    @Test func aPendingReplaceDoesNotOutliveAnAppLockReset() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let first = PeriodBackupDevice(cloud: cloud, writer: "first", resolved: true)
        try first.seed([PeriodBackupDevice.record(day: 1)])
        #expect(await first.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))
        let head = PeriodBackupDevice.stamp("first", 1)
        let phone = PeriodBackupDevice(cloud: cloud, writer: "phone", resolved: true)
        try phone.seed([PeriodBackupDevice.record(day: 2)])
        #expect(await phone.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))
        #expect(phone.host.periodExportState == .heldByAnotherDevice(head))
        let key = phone.key
        phone.host.sealedBackupContentKey = nil
        await phone.coordinator.replacePeriodBackupWithThisIPhone(head)
        #expect(phone.engine.intents[.periodData] == .replace(head), "pending: the Private tab is closed")

        // The reset funnel's backup half, then the owner's "Restore", then the next Private visit.
        phone.host.sealedBackupWorkEpoch += 1
        phone.host.restoreHold.hold(keepingCopiesFrom: PeriodBackupDevice.backupOn)
        phone.host.sealedBackupBookkeeping.clearForKeyLoss()
        phone.engine.dropPendingChoices()
        await phone.coordinator.releaseRestoreHoldForOwner()
        phone.host.sealedBackupContentKey = key
        await phone.coordinator.settlePeriodBackup()
        #expect(phone.engine.intents.isEmpty)
        #expect(try phone.records.recordCount() == 2, "the owner's restore ran")
        #expect(phone.host.sealedBackupBookkeeping.isRestoreResolved(.periodData))
    }

    /// B1-C-B1-3, the other half: "Remove them" does not waive E1, so a pending Remove never takes the
    /// place of the restore an unresolved install owes — the restore runs first.
    @MainActor
    @Test func aPendingRemoveStillLetsTheOwedRestoreRun() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let phone = PeriodBackupDevice(cloud: cloud, writer: "phone", resolved: true)
        let dead = PeriodBackupDevice.record(day: 2)
        try phone.seed([PeriodBackupDevice.record(day: 1)])
        try phone.seed([dead], key: SymmetricKey(size: .bits256))
        #expect(await phone.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))
        #expect(phone.host.v2Status[.periodData] == .paused(unopenableIDs: [dead.id]))
        phone.engine.recordIntent(.remove([dead.id]), for: .periodData)
        phone.host.sealedBackupBookkeeping.reopenRestore(.periodData)

        await phone.coordinator.settlePeriodBackup()
        #expect(phone.host.recordedOutcomes[.periodData] == .nothingToRestore, "the owed restore ran")
        #expect(phone.host.sealedBackupBookkeeping.isRestoreResolved(.periodData))
    }

    /// B1-C-B1-3: the "entries this iPhone can't open" check tells the app when it clears the backup
    /// bookkeeping, so the pending choices made over it are dropped too.
    @MainActor
    @Test func theCantOpenCheckReportsTheBookkeepingItCleared() {
        let controller = PrivatePersistenceController(inMemory: true)
        let defaults = UserDefaults(suiteName: "fernlet.tests.cantOpenCleared.\(UUID().uuidString)") ?? .standard
        let cleared = ReadCounter()
        let entries = SealedPriorEntryStore(
            controller: controller,
            latchDefaults: defaults,
            intimacyStore: IntimacyLogStore(repository: IntimacyLogRepository(controller: controller, defaults: defaults)),
            restoresAfterRemoval: { false },
            bookkeepingCleared: { cleared.value += 1 }
        )
        entries.clearBackupBookkeeping()
        #expect(cleared.value == 1)
    }

    /// B1-D-B1-R5 / B1-C-B1-4: two iPhones export at once from different floors. B (floor far above)
    /// commits and prunes while A's head is still landing; the prune deletes only sets at or below the
    /// head B read, so A's suffix chunk survives, A's head lands complete and the set it names restores
    /// whole. (Before: B pruned everything below its own generation, A's suffix went, A's verify passed
    /// on the head alone and iCloud held a head over missing chunks.)
    @MainActor
    @Test func aConcurrentExportsSuffixSurvivesTheOtherIPhonesPrune() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let holding = HeadHoldingCloudKitRecordDatabase(cloud.database)
        let phoneA = PeriodBackupDevice(cloud: cloud, writer: "a", resolved: true, database: holding)
        try phoneA.seed((0..<300).map { PeriodBackupDevice.record(day: $0) })
        #expect(await phoneA.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))
        let aFirst = PeriodBackupDevice.stamp("a", 1)
        let aFirstRecord = try #require(try await PeriodBackupDevice.reader(cloud).fetchHeadRecord(payloadType: .periodData))
        let phoneB = PeriodBackupDevice(cloud: cloud, writer: "b", resolved: true)
        phoneB.host.sealedBackupBookkeeping.recordAcceptedHead(
            SealedBackupAcceptedHead(stamp: aFirst, saltPrefix: SealedBackupAcceptedHead.saltPrefix(of: aFirstRecord.keySalt)),
            .periodData, installTag: phoneB.writer
        )
        var bFloor = SealedBackupGenerationStore(defaults: phoneB.generationDefaults)
        bFloor.recordAccepted(11, for: .periodData)
        try phoneB.seed([PeriodBackupDevice.record(day: 900)])

        try phoneA.seed([PeriodBackupDevice.record(day: 400)])
        holding.holdsNextHeadSave = true
        phoneA.engine.hubSessionEnded()
        let aExport = Task { await phoneA.coordinator.settlePeriodBackup() }
        #expect(await yieldUntil { holding.isHoldingHeadSave }, "A's suffix is up; its head is landing")
        await phoneB.coordinator.settlePeriodBackup()
        #expect(try await PeriodBackupDevice.cloudHead(cloud) == PeriodBackupDevice.stamp("b", 12))
        holding.releaseHeldHeadSave()
        await aExport.value

        #expect(try await PeriodBackupDevice.cloudHead(cloud) == PeriodBackupDevice.stamp("a", 2), "A's head landed last")
        #expect(phoneA.host.v2Status[.periodData] == .upToDate)
        let restorer = PeriodBackupDevice(cloud: cloud, writer: "restorer")
        #expect(await restorer.coordinator.restorePeriodBackup() == .restored(301), "and the set it names is whole")
    }

    /// B1-C-B1-4: the commit's verify checks the committed set's suffix chunks by name, not just the
    /// head — a head that landed over chunks that are not there fails it: nothing recorded, the upload
    /// stays owed, and the next export (its own set, by the in-flight generation) writes a whole set.
    @MainActor
    @Test func aCommitWhoseSuffixIsMissingFailsItsVerify() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let dropping = SuffixDroppingCloudKitRecordDatabase(cloud.database)
        let phone = PeriodBackupDevice(cloud: cloud, writer: "phone", resolved: true, database: dropping)
        try phone.seed((0..<300).map { PeriodBackupDevice.record(day: $0) })

        #expect(await phone.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))
        #expect(phone.host.v2Status[.periodData] == .failed, "the head landed over a suffix that is not there")
        #expect(phone.acceptedStamp == nil)
        #expect(SealedBackupGenerationStore(defaults: phone.generationDefaults).lastSeen(for: .periodData) == 0)
        #expect(phone.host.reuploadDeferrals[.periodData] == true)

        dropping.dropsSuffixes = false
        #expect(await phone.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))
        #expect(phone.host.v2Status[.periodData] == .upToDate)
        let restorer = PeriodBackupDevice(cloud: cloud, writer: "restorer")
        #expect(await restorer.coordinator.restorePeriodBackup() == .restored(300))
    }

    /// B1-C-B1-4: the prune never deletes the set the head in iCloud names right now, whatever its
    /// number — its head landed after the bound was read.
    @MainActor
    @Test func thePruneKeepsTheSetTheCurrentHeadNames() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let service = PeriodBackupDevice.cloudDataService(cloud.database)
        let kept = PeriodBackupDevice.tag("kept")
        let current = PeriodBackupDevice.tag("current")
        let stale = PeriodBackupDevice.tag("stale")
        let headSalt = Data(repeating: 7, count: 32)
        try await service.saveSealedBackup(Self.fakeChunk(generation: 1, index: 0, salt: headSalt), setTag: nil)
        try await service.saveSealedBackup(Self.fakeChunk(generation: 1, salt: headSalt), setTag: current)
        try await service.saveSealedBackup(Self.fakeChunk(generation: 1), setTag: stale)

        let pruned = try await service.pruneSealedBackupSets(payloadType: .periodData, keepingSetTag: kept, belowGeneration: 5)
        #expect(pruned == 1)
        #expect(Set(cloud.sealedRecords.map(\.recordID.recordName))
                == ["sealed-backup.periodData", "sealed-backup.periodData.chunk.1.\(current)"])
    }

    /// B1-C-B1-5: a quiesce cancels a restore suspended in CloudKit, whose call then throws (as
    /// CloudKit's own do) — a stop, not a failure: no restore outcome, no status, no backoff, and no
    /// further CloudKit call after the wipe. (Before: the catch-all recorded `.deferredTransient`, so
    /// Privacy & Data showed a cycle "Retry" after "Delete everything".)
    @MainActor
    @Test func aCloudKitCallCancelledByTheWipeRecordsNothing() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let first = PeriodBackupDevice(cloud: cloud, writer: "first", resolved: true)
        try first.seed([PeriodBackupDevice.record(day: 1)])
        #expect(await first.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))
        let suspending = SuspendingFetchCloudKitRecordDatabase(cloud.database)
        suspending.throwsWhenCancelled = true
        let phone = PeriodBackupDevice(cloud: cloud, writer: "phone", database: suspending)
        let engine = phone.engine
        let pass = Task { await engine.perform(.periodData, trigger: .hubSettle, phases: .both) }
        #expect(await yieldUntil { suspending.isHoldingFetch })

        let report = await wipe(phone, releasing: suspending, pass: pass)
        #expect(report.stopped)
        #expect(phone.host.recordedOutcomes[.periodData] == nil, "no restore outcome after the wipe")
        #expect(phone.host.v2Status[.periodData] == nil, "no status either")
        #expect(suspending.fetchCount == 1, "no CloudKit call after the cancelled one")
    }

    /// B1-C-B1-5, the export half: an export suspended in its E2 head fetch, cancelled by the wipe's
    /// quiesce, records no `.failed` and no backoff.
    @MainActor
    @Test func anExportCancelledByTheWipeRecordsNoFailure() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let suspending = SuspendingFetchCloudKitRecordDatabase(cloud.database)
        suspending.throwsWhenCancelled = true
        let phone = PeriodBackupDevice(cloud: cloud, writer: "phone", resolved: true, database: suspending)
        try phone.seed([PeriodBackupDevice.record(day: 1)])
        let engine = phone.engine
        let pass = Task { await engine.perform(.periodData, trigger: .hubSettle, phases: .export) }
        #expect(await yieldUntil { suspending.isHoldingFetch })

        let report = await wipe(phone, releasing: suspending, pass: pass)
        #expect(report.stopped)
        #expect(phone.host.v2Status[.periodData] == nil, "no .failed after the wipe")
        #expect(phone.engine.lastExportFailure[.periodData] == nil, "and no backoff")
        #expect(cloud.sealedRecords.isEmpty)
    }

    /// B1-D-B1-R3 (§5.5): "Start a new backup" writes only over a set this iPhone cannot open. Chosen
    /// while the key was missing, it meets — after the key arrived — another iPhone's set that now
    /// opens: that set is held and named, never written over, and the choice is done with.
    @MainActor
    @Test func startNewNeverWritesOverASetThatOpens() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let first = PeriodBackupDevice(cloud: cloud, writer: "first", resolved: true)
        try first.seed([PeriodBackupDevice.record(day: 1)])
        #expect(await first.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))
        let firstSet = cloud.sealedRecordIdentities
        let bare = "com.fernlet.period-v2.startNew.\(UUID().uuidString)"
        defer { KeychainItem.deleteAll(service: bare) }
        let phone = PeriodBackupDevice(cloud: cloud, writer: "phone", resolved: true, keychainService: bare)
        try phone.seed([PeriodBackupDevice.record(day: 2)])
        #expect(await phone.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))
        #expect(phone.host.v2Status[.periodData] == .waitingForBackupKey)
        let key = phone.key
        phone.host.sealedBackupContentKey = nil
        await phone.coordinator.startNewPeriodBackup()
        #expect(phone.engine.intents[.periodData] == .startNew)

        PeriodBackupDevice.copyEscrowKey(from: cloud, into: bare)
        phone.host.sealedBackupContentKey = key
        await phone.coordinator.settlePeriodBackup()
        #expect(cloud.sealedRecordIdentities == firstSet, "a set that opens is never written over by Start new")
        #expect(phone.host.periodExportState == .heldByAnotherDevice(PeriodBackupDevice.stamp("first", 1)))
        #expect(phone.engine.intents[.periodData] == nil)
    }

    /// B1-D-B1-R4: an accepted head is a SET — its generation and salt prefix — never a writer and a
    /// number alone. Another set with the accepted stamp but another salt (the writer's counters reset
    /// by "Delete everything", then backed up again) is held, never written over.
    @MainActor
    @Test func anAcceptedStampWithAnotherSaltIsAnotherSet() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let phoneA = PeriodBackupDevice(cloud: cloud, writer: "a", resolved: true)
        try phoneA.seed([PeriodBackupDevice.record(day: 1)])
        #expect(await phoneA.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))
        let stamp = PeriodBackupDevice.stamp("a", 1)
        let accepted = try #require(try await PeriodBackupDevice.reader(cloud).fetchHeadRecord(payloadType: .periodData))
        let phoneB = PeriodBackupDevice(cloud: cloud, writer: "b", resolved: true)
        phoneB.host.sealedBackupBookkeeping.recordAcceptedHead(
            SealedBackupAcceptedHead(stamp: stamp, saltPrefix: SealedBackupAcceptedHead.saltPrefix(of: accepted.keySalt)),
            .periodData, installTag: phoneB.writer
        )

        cloud.database.recordsByType["SealedBackupRecord"] = []
        let aAgain = PeriodBackupDevice(cloud: cloud, writer: "a", resolved: true)
        try aAgain.seed([PeriodBackupDevice.record(day: 2)])
        #expect(await aAgain.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))
        #expect(try await PeriodBackupDevice.cloudHead(cloud) == stamp, "the same writer and number, another set")
        let newer = cloud.sealedRecordIdentities

        try phoneB.seed([PeriodBackupDevice.record(day: 9)])
        #expect(await phoneB.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))
        #expect(cloud.sealedRecordIdentities == newer, "never written over")
        #expect(phoneB.host.periodExportState == .heldByAnotherDevice(stamp))
    }

    // MARK: - Fix round 2 (review of B1 fix round 1)

    /// B1 fix round 2 N-1: a new iPhone whose restore waits for the backup key iCloud Keychain is
    /// still syncing is told it is WAITING — never that its backup "was saved with a key this iPhone
    /// doesn't have" beside a Replace that says "your other iPhone keeps its own entries" (there may be
    /// no other iPhone, and the set may be the only copy of the history). Nothing is minted or written
    /// while it waits, and once the key arrives the next visit restores the whole set, which stays in
    /// iCloud. (Before: `derive` mapped `.deferredKeyNotSynced` to `.sealedWithAnotherKey`.)
    @MainActor
    @Test func aNewIPhoneWaitingForItsKeyIsToldToWaitAndRestoresWhenItArrives() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let lost = PeriodBackupDevice(cloud: cloud, writer: "lost", resolved: true)
        let history = [PeriodBackupDevice.record(day: 1), PeriodBackupDevice.record(day: 2)]
        try lost.seed(history)
        #expect(await lost.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))
        let theOnlyCopy = cloud.sealedRecordIdentities
        let bare = "com.fernlet.period-v2.waitingForKey.\(UUID().uuidString)"
        defer { KeychainItem.deleteAll(service: bare) }
        let clock = ManualClock()
        let replacement = PeriodBackupDevice(cloud: cloud, writer: "replacement", keychainService: bare, clock: { clock.now })

        await replacement.coordinator.settlePeriodBackup()
        #expect(replacement.host.recordedOutcomes[.periodData] == .deferredKeyNotSynced)
        #expect(replacement.host.periodExportState == .waitingForKey, "named as waiting for its key")
        #expect(replacement.host.periodExportState != .sealedWithAnotherKey)
        #expect(PeriodBackupDevice.escrowKeyCount(bare) == 0, "nothing minted while the key is on its way")
        #expect(cloud.sealedRecordIdentities == theOnlyCopy, "nothing written over the only copy")

        PeriodBackupDevice.copyEscrowKey(from: cloud, into: bare)
        replacement.engine.hubSessionEnded()
        clock.advance(16 * 60)
        await replacement.coordinator.settlePeriodBackup()
        #expect(try replacement.records.recordCount() == history.count, "the whole history comes back")
        #expect(replacement.host.sealedBackupBookkeeping.isRestoreResolved(.periodData))
        #expect(replacement.host.periodExportState == .clear)
        #expect(try await PeriodBackupDevice.cloudRecordIDs(cloud) == Set(history.map(\.id)), "and stays in iCloud")
    }

    /// B1 fix round 2 N-1: the one status-to-state mapping names each unopenable case for what it is —
    /// a restore waiting for its key as waiting; a set that will not authenticate, or a head sealed
    /// with another key or damaged, as one this iPhone can't open; an export waiting for its key
    /// (possibly for another payload's backup) as nothing to choose.
    @MainActor
    @Test func theExportStateNamesARestoreWaitingForItsKeyAsWaiting() {
        func state(_ status: SealedBackupV2Status) -> PeriodBackupExportState {
            PeriodBackupExportState.derive(status: status, rolledBackStamp: nil, observed: { nil })
        }
        #expect(state(.waitingForRestore(.deferredKeyNotSynced)) == .waitingForKey)
        #expect(state(.waitingForRestore(.notRecognized)) == .sealedWithAnotherKey)
        #expect(state(.headSealedWithOtherKey) == .sealedWithAnotherKey)
        #expect(state(.headDamaged) == .sealedWithAnotherKey)
        #expect(state(.waitingForBackupKey) == .clear)
        #expect(state(.waitingForRestore(.deferredTransient)) == .clear)
    }

    /// B1 fix round 2 N-1 (design §10.1): every "Start a new backup" in Privacy & Data sits behind its
    /// own confirmation — the one that says to wait for the key — and the Replace confirmation, whose
    /// copy promises "your other iPhone keeps its own entries", only ever replaces a named set that
    /// opens. The waiting-for-key row offers Start new, never Replace.
    @Test func everyStartNewSitsBehindItsOwnConfirmation() throws {
        let source = try String(contentsOf: RepoRoot.url("App/Fernlet/PrivacyDataSettingsView.swift"), encoding: .utf8)
        let startNew = try #require(Self.functionBody("private func confirmPeriodBackupStartNew()", in: source))
        let replace = try #require(Self.functionBody("private func confirmPeriodBackupReplace(", in: source))
        #expect(startNew.contains("appStore.startNewPeriodBackup()"))
        #expect(startNew.contains("reset iCloud Keychain"), "the confirmation names the only reasons to start over")
        #expect(!startNew.contains("other iPhone keeps"))
        #expect(!replace.contains("startNewPeriodBackup"), "Replace never runs Start new")
        #expect(source.components(separatedBy: "appStore.startNewPeriodBackup()").count == 2, "one Start new call site")
        let waiting = try #require(Self.functionBody("case .waitingForKey:", in: source, closing: "case .unopenableEntries:"))
        #expect(waiting.contains("periodStartNewButton"))
        #expect(!waiting.contains("confirmPeriodBackupReplace"))
    }

    /// The source from `start` to the next `closing` (by default the next `private func`), or nil.
    private static func functionBody(_ start: String, in source: String, closing: String = "    private ") -> String? {
        guard let begin = source.range(of: start) else { return nil }
        let rest = source[begin.upperBound...]
        let end = rest.range(of: closing)?.lowerBound ?? rest.endIndex
        return String(rest[..<end])
    }

    // MARK: - Fixtures

    /// Plays "Delete everything"'s first leg on `phone` (the bracket raised, the work epoch moved, the
    /// quiesce awaited) while `pass` is suspended in `suspending`'s held fetch, then releases the
    /// fetch and returns the pass's report.
    @MainActor
    private func wipe(
        _ phone: PeriodBackupDevice,
        releasing suspending: SuspendingFetchCloudKitRecordDatabase,
        pass: Task<SealedBackupV2PassReport, Never>
    ) async -> SealedBackupV2PassReport {
        phone.host.deleteAllInProgress = true
        phone.host.sealedBackupWorkEpoch += 1
        let engine = phone.engine
        let quiesce = Task { await engine.quiesceForWipe() }
        for _ in 0..<50 { await Task.yield() }
        suspending.releaseHeldFetch()
        await quiesce.value
        let report = await pass.value
        phone.host.deleteAllInProgress = false
        return report
    }

    /// Whether `service` holds any backup-escrow key.
    @MainActor
    private static func holdsEscrowKey(_ service: String) -> Bool {
        KeychainItem.loadAll(service: service).contains { $0.account.hasPrefix("backupEscrowPrivateKey") }
    }

    /// A syntactically valid sealed chunk `index` of 2 at `generation` (its bytes never opened).
    @MainActor
    private static func fakeChunk(generation: Int64, index: Int = 1, salt: Data = Data(repeating: 6, count: 32)) -> SealedBackupRecord {
        SealedBackupRecord(
            payloadType: .periodData,
            signingPublicKey: Data(repeating: 1, count: 32),
            keyAgreementPublicKey: Data(repeating: 2, count: 32),
            nonce: Data(repeating: 3, count: 12),
            ciphertext: Data(repeating: 4, count: 16),
            tag: Data(repeating: 5, count: 16),
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            chunkIndex: index,
            chunkCount: 2,
            generation: generation,
            formatVersion: 2,
            keySalt: salt
        )
    }

    /// A second iPhone whose ambient restore of the first's set is suspended in its head fetch; its
    /// pass is held in `pendingPass`.
    @MainActor
    private func suspendedRestore() async throws -> (FakeSealedBackupCloud, SuspendedPhone, SuspendingFetchCloudKitRecordDatabase) {
        let cloud = try PeriodBackupDevice.makeCloud()
        let first = PeriodBackupDevice(cloud: cloud, writer: "first", resolved: true)
        try first.seed([PeriodBackupDevice.record(day: 1)])
        #expect(await first.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))
        let suspending = SuspendingFetchCloudKitRecordDatabase(cloud.database)
        let phone = SuspendedPhone(PeriodBackupDevice(cloud: cloud, writer: "second", database: suspending))
        phone.start()
        #expect(await yieldUntil { suspending.isHoldingFetch }, "the restore is waiting on CloudKit")
        return (cloud, phone, suspending)
    }
}

/// A ``PeriodBackupDevice`` with one restore pass started and held.
@MainActor
@dynamicMemberLookup
final class SuspendedPhone {
    let device: PeriodBackupDevice
    private var task: Task<SealedBackupV2PassReport, Never>?

    init(_ device: PeriodBackupDevice) { self.device = device }

    subscript<T>(dynamicMember path: KeyPath<PeriodBackupDevice, T>) -> T { device[keyPath: path] }

    /// Starts the ambient restore pass.
    func start() {
        let engine = device.engine
        task = Task { await engine.perform(.periodData, trigger: .hubSettle, phases: .restore) }
    }

    /// The started pass's report, once it ends.
    var pendingPass: SealedBackupV2PassReport? {
        get async { await task?.value }
    }
}

/// A transport that counts every call — "nothing reached CloudKit" is `calls == 0`.
final class CountingCloudKitRecordDatabase: CloudKitRecordDatabase {
    private let base: InMemoryCloudKitRecordDatabase
    /// Every call of any kind.
    private(set) var calls = 0
    /// Record fetches by id.
    private(set) var fetches = 0
    /// Saves.
    private(set) var saves = 0

    init(_ base: InMemoryCloudKitRecordDatabase) { self.base = base }

    func recordZoneIDs() async throws -> [CKRecordZone.ID] {
        calls += 1
        return try await base.recordZoneIDs()
    }
    func recordIDs(matching recordType: String, in zoneID: CKRecordZone.ID) async throws -> [CKRecord.ID] {
        calls += 1
        return try await base.recordIDs(matching: recordType, in: zoneID)
    }
    func records(for recordIDs: [CKRecord.ID]) async throws -> [CKRecord] {
        calls += 1
        fetches += 1
        return try await base.records(for: recordIDs)
    }
    func saveRecords(_ records: [CKRecord]) async throws {
        calls += 1
        saves += 1
        try await base.saveRecords(records)
    }
    func deleteRecords(with recordIDs: [CKRecord.ID]) async throws {
        calls += 1
        try await base.deleteRecords(with: recordIDs)
    }
}

/// A transport that silently drops every HEAD save while ``dropsHeads`` is on — the save "succeeds"
/// but the server keeps whatever head it had.
final class HeadDroppingCloudKitRecordDatabase: CloudKitRecordDatabase {
    private let base: InMemoryCloudKitRecordDatabase
    /// Whether head saves are dropped.
    var dropsHeads = true

    init(_ base: InMemoryCloudKitRecordDatabase) { self.base = base }

    func recordZoneIDs() async throws -> [CKRecordZone.ID] { try await base.recordZoneIDs() }
    func recordIDs(matching recordType: String, in zoneID: CKRecordZone.ID) async throws -> [CKRecord.ID] {
        try await base.recordIDs(matching: recordType, in: zoneID)
    }
    func records(for recordIDs: [CKRecord.ID]) async throws -> [CKRecord] { try await base.records(for: recordIDs) }
    func saveRecords(_ records: [CKRecord]) async throws {
        let kept = dropsHeads ? records.filter { $0.recordID.recordName.contains(".chunk.") } : records
        try await base.saveRecords(kept)
    }
    func deleteRecords(with recordIDs: [CKRecord.ID]) async throws { try await base.deleteRecords(with: recordIDs) }
}

/// A transport whose saves fail while ``failsSaves`` is on (CloudKit offline).
final class SaveFailingCloudKitRecordDatabase: CloudKitRecordDatabase {
    private let base: InMemoryCloudKitRecordDatabase
    /// Whether every save throws.
    var failsSaves = false
    /// Saves attempted (failed or not).
    private(set) var saveAttempts = 0

    init(_ base: InMemoryCloudKitRecordDatabase) { self.base = base }

    func recordZoneIDs() async throws -> [CKRecordZone.ID] { try await base.recordZoneIDs() }
    func recordIDs(matching recordType: String, in zoneID: CKRecordZone.ID) async throws -> [CKRecord.ID] {
        try await base.recordIDs(matching: recordType, in: zoneID)
    }
    func records(for recordIDs: [CKRecord.ID]) async throws -> [CKRecord] { try await base.records(for: recordIDs) }
    func saveRecords(_ records: [CKRecord]) async throws {
        saveAttempts += 1
        if failsSaves { throw CKError(.networkUnavailable) }
        try await base.saveRecords(records)
    }
    func deleteRecords(with recordIDs: [CKRecord.ID]) async throws { try await base.deleteRecords(with: recordIDs) }
}

/// BV24's stand-in payload store: a snapshot of `idCount` ids whose every chunk opens to ONE record of
/// `recordCharacters` characters, so the prepare's two size bounds can be crossed without seeding a
/// real store. Every seam is open and healthy; nothing is ever merged or removed.
@MainActor
final class OversizeBackupAdapter: SealedBackupV2Adapter {
    let payload: SealedBackupPayloadType = .periodData
    /// How many ids the snapshot names.
    let idCount: Int
    /// The size of the one record each chunk opens to.
    let recordCharacters: Int
    /// How many chunks the prepare read.
    private(set) var chunkReads = 0

    init(idCount: Int, recordCharacters: Int) {
        self.idCount = idCount
        self.recordCharacters = recordCharacters
    }

    var isSurfaceOpen: Bool { true }
    var isStoreHealthy: Bool { true }
    func withOpenSeam<T>(_ body: () throws -> T) throws -> T { try body() }
    func snapshotIDs() throws -> [UUID] { (0..<idCount).map { _ in UUID() } }
    func classifiedChunk(_ ids: [UUID], hubKey: SymmetricKey) throws -> SealedBackupChunkPage<String> {
        chunkReads += 1
        return SealedBackupChunkPage(records: [String(repeating: "a", count: recordCharacters)])
    }
    func recordID(_ record: String) -> UUID { UUID() }
    func decodeV1Chunk(_ data: Data) throws -> [String] { [] }
    func restoreMerging(_ records: [String], hubKey: SymmetricKey) throws -> SealedBackupMergeResult {
        SealedBackupMergeResult()
    }
    func didRestore(_ result: SealedBackupMergeResult) -> Bool { true }
    func removeStillDead(_ ids: [UUID], hubKey: SymmetricKey) throws -> Int { 0 }
}
