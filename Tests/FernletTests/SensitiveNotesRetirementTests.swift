//
//  SensitiveNotesRetirementTests.swift
//  FernletTests
//
//  Owner decision 2026-09-23: "Tier 2 sensitive notes shouldn't be backed up to iCloud at all."
//
//  The opt-in "sensitive notes" sealed backup encrypted exactly the Tier-2 behavioral memories, so it
//  is RETIRED: never sealed again, never restored, and a copy already in iCloud is deleted — quietly,
//  idempotently, and audited — by the next backup pass. The `.sensitiveNotes` case itself stays: its
//  rawValue names the CloudKit record and is bound into the GCM AAD, so deleting it would orphan the
//  very records the sweep has to find. These cells drive the real coordinator and the real
//  `SealedBackupService` over an in-memory CloudKit database (`FakeSealedBackupCloud`).
//

import CloudKit
import Foundation
import Testing
import CloudKitSync
import FernletDomainModel
import FernletFoundation
import ProximityKit
@testable import Fernlet

/// An iCloud account that is signed out, so every CloudKit call the sweep makes fails.
private struct SignedOutAccountProvider: CloudKitAccountStatusProviding {
    func accountStatus() async throws -> CKAccountStatus { .noAccount }
}

/// Collects `sealedBackup.` audit events for one test — a lock-guarded reference box, installed on
/// entry and removed by token, in `CompanionRefreshAuditCapture`'s shape.
private final class SealedBackupAuditCapture {
    /// Guards ``storedEvents``; handlers run on whatever executor logged.
    private let lock = NSLock()
    /// Every matching event seen, in order.
    private var storedEvents: [String] = []
    /// The registry token, until it is removed.
    private var token: UUID?

    /// Starts capturing.
    func install() {
        token = FernletAuditLog.addCaptureHandler { [weak self] event, _ in
            guard let self, event.hasPrefix("sealedBackup.") else { return }
            self.lock.lock()
            self.storedEvents.append(event)
            self.lock.unlock()
        }
    }

    /// Stops capturing.
    func uninstall() {
        if let token {
            FernletAuditLog.removeCaptureHandler(token)
            self.token = nil
        }
    }

    /// Every event captured, in order.
    var events: [String] {
        lock.lock(); defer { lock.unlock() }
        return storedEvents
    }
}

/// Pins the retirement of the `.sensitiveNotes` sealed-backup payload end to end.
@MainActor
@Suite(.serialized)
struct SensitiveNotesRetirementTests {

    // MARK: - Fixtures

    private static func isolatedDefaults(_ label: String) -> UserDefaults {
        UserDefaults(suiteName: "fernlet.tests.\(label).\(UUID().uuidString)") ?? .standard
    }

    /// A throwaway keychain slot with an escrow key already provisioned, over an empty in-memory
    /// CloudKit database.
    private func makeCloud() throws -> FakeSealedBackupCloud {
        let cloud = FakeSealedBackupCloud(
            keychainService: "com.fernlet.sensitive-notes-retirement.\(UUID().uuidString)",
            generationDefaults: Self.isolatedDefaults("retirementGeneration")
        )
        let identity = IdentityService(keychainService: cloud.keychainService)
        try identity.ensureProvisioned()
        identity.provisionBackupEscrowKeyForSealing()
        return cloud
    }

    /// The real sealing service over the fake cloud.
    private static func makeService(
        cloud: FakeSealedBackupCloud,
        identity: IdentityService,
        accountProvider: any CloudKitAccountStatusProviding
    ) -> SealedBackupService {
        SealedBackupService(
            cloudDataService: CloudKitDataService(
                accountProvider: accountProvider,
                database: cloud.database,
                zoneID: CKRecordZone.ID(zoneName: "test-zone", ownerName: CKCurrentUserDefaultName),
                isCloudKitSyncEnabled: { false }
            ),
            identityService: identity,
            generationStore: SealedBackupGenerationStore(defaults: cloud.generationDefaults)
        )
    }

    /// The production coordinator, wired to the fake cloud and a throwaway identity keychain.
    private func makeCoordinator(
        host: FakeSealedBackupHost,
        cloud: FakeSealedBackupCloud,
        accountProvider: any CloudKitAccountStatusProviding = AlwaysAvailableAccountProvider()
    ) -> SealedBackupCoordinator {
        let keychainService = cloud.keychainService
        return SealedBackupCoordinator(
            host: host,
            identityFactory: { IdentityService(keychainService: keychainService) },
            serviceFactory: { identity in
                Self.makeService(cloud: cloud, identity: identity, accountProvider: accountProvider)
            }
        )
    }

    /// Uploads a backup of `payloadType` through the MECHANISM layer, which can still seal any payload
    /// — standing in for the copy an earlier build left in iCloud.
    private func seedBackup(
        _ payloadType: SealedBackupPayloadType,
        plaintext: Data = Data("[]".utf8),
        in cloud: FakeSealedBackupCloud
    ) async throws {
        let identity = IdentityService(keychainService: cloud.keychainService)
        try identity.ensureProvisioned()
        identity.provisionBackupEscrowKeyForSealing()
        let service = Self.makeService(cloud: cloud, identity: identity, accountProvider: AlwaysAvailableAccountProvider())
        try await service.reconcile(plaintext, payloadType: payloadType, enabled: true)
    }

    private func recordNames(_ cloud: FakeSealedBackupCloud) -> Set<String> {
        Set(cloud.sealedRecords.map(\.recordID.recordName))
    }

    // MARK: - No new uploads

    /// Enabling the retired payload is refused before any escrow key is minted or byte sealed.
    @Test func enablingTheRetiredPayloadUploadsNothing() async throws {
        let cloud = try makeCloud()
        defer { cloud.tearDown() }
        let audit = SealedBackupAuditCapture()
        audit.install()
        defer { audit.uninstall() }
        // Held in a local: the coordinator keeps its host `unowned`, so an inline temporary would be
        // destroyed before the first host read.
        let host = FakeSealedBackupHost()
        let coordinator = makeCoordinator(host: host, cloud: cloud)

        #expect(await coordinator.setSealedBackupEnabled(true, payloadType: .sensitiveNotes) == false)

        #expect(cloud.sealedRecords.isEmpty, "the retired payload reached iCloud")
        #expect(audit.events.contains("sealedBackup.retiredPayloadEnableRefused"))
        // A refusal is not a deferral: nothing is owed, so nothing will ever retry the upload.
        #expect(host.reuploadDeferrals.isEmpty)
    }

    // MARK: - Deleting the surviving copy

    /// The sweep deletes the surviving copy — and only that copy — logs it, and hands the host the
    /// "delete no longer owed" signal that clears the persisted marker.
    @Test func theSweepDeletesTheSurvivingCopyAndNothingElse() async throws {
        let cloud = try makeCloud()
        defer { cloud.tearDown() }
        try await seedBackup(.sensitiveNotes, in: cloud)
        try await seedBackup(.journalNarratives, in: cloud)
        #expect(recordNames(cloud) == ["sealed-backup.sensitiveNotes", "sealed-backup.journalNarratives"])
        let audit = SealedBackupAuditCapture()
        audit.install()
        defer { audit.uninstall() }
        let host = FakeSealedBackupHost()
        let coordinator = makeCoordinator(host: host, cloud: cloud)

        await coordinator.retireSensitiveNotesBackupIfNeeded(backupMayExist: true)

        #expect(recordNames(cloud) == ["sealed-backup.journalNarratives"])
        #expect(host.retiredBackupsDeleted == [.sensitiveNotes])
        #expect(audit.events.contains("sealedBackup.retiredPayloadDeleted"))
    }

    /// Idempotent: a second pass over a container that no longer holds the copy succeeds quietly,
    /// and still leaves every other payload alone.
    @Test func theSweepIsIdempotent() async throws {
        let cloud = try makeCloud()
        defer { cloud.tearDown() }
        try await seedBackup(.sensitiveNotes, in: cloud)
        try await seedBackup(.periodData, in: cloud)
        let host = FakeSealedBackupHost()
        let coordinator = makeCoordinator(host: host, cloud: cloud)

        await coordinator.retireSensitiveNotesBackupIfNeeded(backupMayExist: true)
        await coordinator.retireSensitiveNotesBackupIfNeeded(backupMayExist: true)

        #expect(recordNames(cloud) == ["sealed-backup.periodData"])
        #expect(host.retiredBackupsDeleted == [.sensitiveNotes, .sensitiveNotes])
    }

    /// The marker gates the network: when this install never had the backup there is nothing it owes,
    /// so the pass makes no CloudKit call and reports nothing.
    @Test func theSweepDoesNothingWhenNoCopyIsOwed() async throws {
        let cloud = try makeCloud()
        defer { cloud.tearDown() }
        try await seedBackup(.sensitiveNotes, in: cloud)
        let host = FakeSealedBackupHost()
        let coordinator = makeCoordinator(host: host, cloud: cloud)

        await coordinator.retireSensitiveNotesBackupIfNeeded(backupMayExist: false)

        #expect(recordNames(cloud) == ["sealed-backup.sensitiveNotes"])
        #expect(host.retiredBackupsDeleted.isEmpty)
    }

    /// A delete that fails (here: signed out of iCloud) keeps the marker — the host is NOT told the
    /// delete landed — so the next launch retries, and the audit log names the failure.
    @Test func aFailedSweepKeepsTheMarkerForTheNextPass() async throws {
        let cloud = try makeCloud()
        defer { cloud.tearDown() }
        try await seedBackup(.sensitiveNotes, in: cloud)
        let audit = SealedBackupAuditCapture()
        audit.install()
        defer { audit.uninstall() }
        let host = FakeSealedBackupHost()
        let coordinator = makeCoordinator(host: host, cloud: cloud, accountProvider: SignedOutAccountProvider())

        await coordinator.retireSensitiveNotesBackupIfNeeded(backupMayExist: true)

        #expect(recordNames(cloud) == ["sealed-backup.sensitiveNotes"])
        #expect(host.retiredBackupsDeleted.isEmpty)
        #expect(audit.events.contains("sealedBackup.retiredPayloadDeleteFailed"))
    }

    // MARK: - No restore

    /// Even with a decryptable copy sitting in iCloud, the retired payload restores nothing: the
    /// launch/Retry path answers `.nothingToRestore` without fetching, and the write point itself
    /// refuses to decode it.
    @Test func restoreNeverBringsTheRetiredPayloadBack() async throws {
        let cloud = try makeCloud()
        defer { cloud.tearDown() }
        let records = [TierTwoMemoryRecord(category: "journal_avoidance_pattern", text: "Avoids.", state: "high_avoidance")]
        let plaintext = try JSONEncoder().encode(records)
        try await seedBackup(.sensitiveNotes, plaintext: plaintext, in: cloud)
        let host = FakeSealedBackupHost()   // a local: the coordinator holds it `unowned`
        let coordinator = makeCoordinator(host: host, cloud: cloud)

        #expect(await coordinator.restoreSealedBackupOutcome(payloadType: .sensitiveNotes) == .nothingToRestore)
        #expect(try coordinator.applyRestoredChunks([plaintext], payloadType: .sensitiveNotes) == 0)
        #expect(recordNames(cloud) == ["sealed-backup.sensitiveNotes"], "restore must not touch the copy either")
        #expect(host.recordedOutcomes[.sensitiveNotes] == .nothingToRestore, "the benign outcome was not recorded")
    }

    /// The coordinator can no longer even NAME Tier-2: the host seam that let it read and overwrite
    /// the records is gone, so no future payload can quietly re-export them.
    @Test func theBackupCoordinatorCannotReachTierTwo() throws {
        let source = try String(
            contentsOf: RepoRoot.url.appendingPathComponent("App/Fernlet/SealedBackupCoordinator.swift"),
            encoding: .utf8
        )
        for token in ["TierTwoMemoryRecord", "tierTwoMemories", "replaceTierTwoMemories"] {
            #expect(!source.contains(token), "SealedBackupCoordinator names \(token)")
        }
    }

    // MARK: - The toggle is gone, the marker is cleared through the store

    /// No user-facing switch or settings-search entry offers the retired backup any more.
    @Test func noSurfaceOffersTheRetiredBackup() throws {
        for path in ["App/Fernlet/PrivacyDataSettingsView.swift", "App/Fernlet/SettingsSearchIndex.swift"] {
            let source = try String(contentsOf: RepoRoot.url.appendingPathComponent(path), encoding: .utf8)
            #expect(!source.contains("Sealed backup for sensitive notes"), "\(path) still offers it")
            #expect(!source.contains("handleSealedBackupToggle(.sensitiveNotes"), "\(path) still toggles it")
        }
    }

    /// The store forwards the sweep's "deleted" signal to the persistence hook `ContentView` wires to
    /// the preferences store — the only writer that can clear the keychain-persisted marker.
    @Test func theStoreForwardsTheClearedMarkerToItsPersistHook() {
        let store = makeTestStore()
        var cleared: [SealedBackupPayloadType] = []
        store.retiredSealedBackupClearedHook = { cleared.append($0) }

        store.recordRetiredSealedBackupDeleted(.sensitiveNotes)

        #expect(cleared == [.sensitiveNotes])
    }
}
