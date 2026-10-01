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

    /// BV1 (shrinking allowlist): the period payload reaches a chunk upload only through the engine.
    /// The legacy in-place `reconcileChunked` writer is called for the journal and intimacy payloads
    /// only (until their own units move them), and the engine's set-scoped `save` only by its commit.
    @Test func thePeriodPayloadReachesTheUploadOnlyThroughTheEngine() throws {
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
        #expect(legacyCallers.count == 2, "\(legacyCallers)")
        #expect(legacyCallers.allSatisfy { $0.contains(".journalNarratives") || $0.contains(".intimacyLogs") },
                "only the v1 payloads may write in place: \(legacyCallers)")
        #expect(setScopedSavers == ["SealedBackupV2Engine+Commit.swift"])
    }

    // MARK: - Fixtures

    /// Whether `service` holds any backup-escrow key.
    @MainActor
    private static func holdsEscrowKey(_ service: String) -> Bool {
        KeychainItem.loadAll(service: service).contains { $0.account.hasPrefix("backupEscrowPrivateKey") }
    }

    /// A syntactically valid sealed chunk 1 of 2 at `generation` (its bytes never opened).
    @MainActor
    private static func fakeChunk(generation: Int64) -> SealedBackupRecord {
        SealedBackupRecord(
            payloadType: .periodData,
            signingPublicKey: Data(repeating: 1, count: 32),
            keyAgreementPublicKey: Data(repeating: 2, count: 32),
            nonce: Data(repeating: 3, count: 12),
            ciphertext: Data(repeating: 4, count: 16),
            tag: Data(repeating: 5, count: 16),
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            chunkIndex: 1,
            chunkCount: 2,
            generation: generation,
            formatVersion: 2,
            keySalt: Data(repeating: 6, count: 32)
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
