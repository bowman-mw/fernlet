//
//  SealedBackupPayloadCoverageTests.swift
//  FernletTests
//
//  Security-hardening Phase 3: journal narratives and intimacy logs as first-class sealed-backup
//  payloads. These drive `SealedBackupCoordinator` directly through a fake `SealedBackupContext`, so
//  the restore semantics (insert-into-empty, the one-way divergence latch, the locked-key deferral)
//  and the empty-store-clobber guard are exercised against ISOLATED sealed stores — no CloudKit, no
//  shared on-device store, no `UserDefaults.standard` latch bleed.
//
//  The FernletStore-level halves (journal skeleton reconstruction, the wiring of the store's own
//  wrappers) live in SealedBackupRestoreTests, which needs a real store to observe.
//

import ProximityKit
import CloudKit
import CoreData
import CryptoKit
import Foundation
import Testing
import CloudKitSync
import FernletDomainModel
import FernletFoundation
import PrivateHealthStore
import PrivateMemoryStore
import PrivateStoreCore
@testable import Fernlet

/// A minimal `SealedBackupContext` so the coordinator can be tested without a `FernletStore`.
///
/// Everything it exposes is a plain settable property or a recorded call — the point is that these
/// tests state exactly which host inputs a decision depends on (the content key, the two visibility
/// gates) instead of inferring them from a 5,000-line store.
@MainActor
final class FakeSealedBackupHost: SealedBackupContext {
    var tierTwoMemories: [TierTwoMemoryRecord] = []
    var sealedBackupContentKey: SymmetricKey?
    var isPeriodTrackingVisible = true
    var isIntimacyTrackingVisible = true
    var previousJournals: [JournalEntry] = []
    var memories: [MemoryNote] = []
    var recentMeals: [Meal] = []
    var days: [String: FernletDay] = [:]

    /// Narratives handed to ``reinstateJournalEntries(from:)``, in call order — the journal
    /// self-sufficiency hook's observable effect at this seam.
    private(set) var reinstatedJournalNarratives: [[JournalNarrative]] = []
    private(set) var recordedOutcomes: [SealedBackupPayloadType: SealedBackupRestoreOutcome] = [:]
    /// Per-payload re-upload deferrals, as the coordinator recorded them.
    private(set) var reuploadDeferrals: [SealedBackupPayloadType: Bool] = [:]

    func replaceTierTwoMemories(_ records: [TierTwoMemoryRecord]) { tierTwoMemories = records }
    func loadAllDaysFromRepository() -> [String: FernletDay] { days }
    func recordSealedBackupReuploadDeferred(_ deferred: Bool, payloadType: SealedBackupPayloadType) {
        reuploadDeferrals[payloadType] = deferred
    }
    func recordSealedBackupRestoreOutcome(_ outcome: SealedBackupRestoreOutcome, payloadType: SealedBackupPayloadType) {
        recordedOutcomes[payloadType] = outcome
    }
    func recordSealedBackupEscrowConflict(_ inConflict: Bool) {}

    /// Mirrors `FernletStore.reinstateJournalEntries(from:)`'s load-bearing SIDE EFFECT: it writes day
    /// rows. Without that here, the pass-level freshness interaction (the journal arm's writeback
    /// flipping the whole-device gate under the arms that follow it) is invisible to these tests.
    func reinstateJournalEntries(from narratives: [JournalNarrative]) {
        reinstatedJournalNarratives.append(narratives)
        for (dayKey, rows) in Dictionary(grouping: narratives, by: \.dayKey) {
            var day = days[dayKey] ?? FernletDay(date: dayKey)
            var known = Set(day.journals.map(\.id))
            for row in rows where !known.contains(row.id) {
                day.journals.append(
                    JournalEntry(id: row.id, text: "", tag: row.tag, date: row.entryDate, emotions: [])
                )
                known.insert(row.id)
            }
            days[dayKey] = day
        }
    }
}

@MainActor
@Suite(.serialized)
struct SealedBackupPayloadCoverageTests {

    // MARK: - Fixtures

    private func isolatedDefaults(_ label: String) -> UserDefaults {
        UserDefaults(suiteName: "fernlet.tests.\(label).\(UUID().uuidString)") ?? .standard
    }

    private func makeJournalRepository() -> JournalNarrativeRepository {
        JournalNarrativeRepository(
            context: PrivatePersistenceController(inMemory: true).container.viewContext,
            defaults: isolatedDefaults("journalLatch")
        )
    }

    /// An isolated intimacy funnel. Tests always go through `IntimacyLogStore`, never the raw
    /// repository, because that is the wiring production is grep-walled into — and the coordinator
    /// re-wires the injected store's `isVisible` from the host, so visibility is driven by flipping
    /// `host.isIntimacyTrackingVisible`, never by handing in an ungated store.
    private func makeIntimacyStore() -> IntimacyLogStore {
        IntimacyLogStore(
            repository: IntimacyLogRepository(
                context: PrivatePersistenceController(inMemory: true).container.viewContext,
                defaults: isolatedDefaults("intimacyLatch")
            )
        )
    }

    /// Seeds a log through a temporarily-visible copy of the funnel — the store's default gate is
    /// fail-closed, so a raw `insert` would throw.
    private func seed(_ log: IntimacyLog, into store: IntimacyLogStore, key: SymmetricKey?) throws {
        let previous = store.isVisible
        store.isVisible = { true }
        defer { store.isVisible = previous }
        try store.insert(log, contentKey: key)
    }

    private func makeHost(key: SymmetricKey? = SymmetricKey(size: .bits256)) -> FakeSealedBackupHost {
        let host = FakeSealedBackupHost()
        host.sealedBackupContentKey = key
        return host
    }

    private func journalNarrative(_ text: String, dayKey: String = "2026-06-01", at seconds: TimeInterval) -> JournalNarrative {
        let date = Date(timeIntervalSince1970: seconds)
        return JournalNarrative(
            id: UUID(), dayKey: dayKey, tag: .good, entryDate: date,
            text: text, emotions: ["calm"], createdAt: date, updatedAt: date
        )
    }

    private func intimacyLog(_ note: String, at seconds: TimeInterval) -> IntimacyLog {
        IntimacyLog(eventDate: Date(timeIntervalSince1970: seconds), note: note)
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data { try JSONEncoder().encode(value) }

    /// A coordinator wired to a THROWAWAY identity keychain and an in-memory CloudKit database, so the
    /// export/restore halves — the ones that decide what actually reaches (and comes back from) iCloud —
    /// can be driven end to end. Everything else about it is the production object.
    private func makeCloudCoordinator(
        host: FakeSealedBackupHost,
        cloud: FakeSealedBackupCloud
    ) -> SealedBackupCoordinator {
        let keychainService = cloud.keychainService
        let generationDefaults = cloud.generationDefaults
        let database = cloud.database
        return SealedBackupCoordinator(
            host: host,
            identityFactory: { IdentityService(keychainService: keychainService) },
            serviceFactory: { identity in
                SealedBackupService(
                    cloudDataService: CloudKitDataService(
                        accountProvider: AlwaysAvailableAccountProvider(),
                        database: database,
                        zoneID: CKRecordZone.ID(zoneName: "test-zone", ownerName: CKCurrentUserDefaultName),
                        isCloudKitSyncEnabled: { false }
                    ),
                    identityService: identity,
                    generationStore: SealedBackupGenerationStore(defaults: generationDefaults)
                )
            }
        )
    }

    private func makeCloud() throws -> FakeSealedBackupCloud {
        let cloud = FakeSealedBackupCloud(
            keychainService: "com.fernlet.p3-coverage.\(UUID().uuidString)",
            generationDefaults: isolatedDefaults("sealedGeneration")
        )
        // The seal path provisions the escrow key lazily (WS-1); do it up front so both the export and
        // the restore in a single test run under the same key.
        let identity = IdentityService(keychainService: cloud.keychainService)
        try identity.ensureProvisioned()
        identity.provisionBackupEscrowKeyForSealing()
        return cloud
    }

    // MARK: - Export path: the empty-store-clobber guard, driven through the real seam

    /// The clobber case the guard exists for, exercised through the USER-FACING enable rather than the
    /// predicate in isolation. A populated cloud backup meets a local store this device has not restored
    /// into yet: `reconcileChunked` writes a head record even for a count of 0, so an unguarded enable
    /// would replace the whole chunk set with one empty chunk and destroy the very history the backup
    /// exists to recover.
    ///
    /// The enable must still report success — returning false would drop the preference and bounce the
    /// toggle — and must record a deferral so the upload is retried once there IS something to seal.
    @Test func journalEnableFromAnEmptyStoreDefersInsteadOfClobberingTheCloudBackup() async throws {
        let cloud = try makeCloud()
        defer { cloud.tearDown() }
        let host = makeHost()
        let coordinator = makeCloudCoordinator(host: host, cloud: cloud)

        // A device that HAS the history uploads it.
        let populated = makeJournalRepository()
        try populated.insert(journalNarrative("real history", at: 10), contentKey: host.sealedBackupContentKey)
        #expect(await coordinator.setSealedBackupEnabled(
            true, payloadType: .journalNarratives, journalRepository: populated
        ))
        let uploaded = cloud.sealedRecords
        #expect(uploaded.isEmpty == false, "a populated store must actually upload")

        // The same enable from a store that has not restored yet must NOT touch those records.
        let empty = makeJournalRepository()
        #expect(await coordinator.setSealedBackupEnabled(
            true, payloadType: .journalNarratives, journalRepository: empty
        ), "an enable that cannot seal yet must defer, not fail — a false here reverts the toggle")
        #expect(cloud.sealedRecordIdentities == uploaded.map(ObjectIdentifier.init),
                "the empty store replaced the cloud backup")
        #expect(host.reuploadDeferrals[.journalNarratives] == true,
                "a skipped export nobody records is a skip nobody ever retries")
    }

    /// The other half of the dual-key hazard: rows the export key CANNOT OPEN. Journal is the one sealed
    /// store with two possible sealing keys (entries written before a lock existed are sealed under the
    /// device journal key), and the pager `compactMap`s away every row it cannot decrypt. Sizing the
    /// chunk set from the raw row count would therefore upload a set of empty chunks over a good backup
    /// while logging a clean "reconciled".
    @Test func journalEnableRefusesWhenTheExportKeyCannotOpenTheStoredRows() async throws {
        let cloud = try makeCloud()
        defer { cloud.tearDown() }
        let host = makeHost()
        let coordinator = makeCloudCoordinator(host: host, cloud: cloud)

        // A good backup already in iCloud, from a device that could read its own rows.
        let populated = makeJournalRepository()
        try populated.insert(journalNarrative("real history", at: 10), contentKey: host.sealedBackupContentKey)
        _ = await coordinator.setSealedBackupEnabled(
            true, payloadType: .journalNarratives, journalRepository: populated
        )
        let uploaded = cloud.sealedRecordIdentities

        // Rows sealed under a DIFFERENT key: they count, but none of them opens.
        let otherKeyed = makeJournalRepository()
        try otherKeyed.insert(journalNarrative("sealed under the device key", at: 20), contentKey: SymmetricKey(size: .bits256))
        #expect(try otherKeyed.narrativeCount() == 1)
        #expect(try otherKeyed.narratives(offset: 0, limit: 10, contentKey: host.sealedBackupContentKey).isEmpty)

        #expect(await coordinator.setSealedBackupEnabled(
            true, payloadType: .journalNarratives, journalRepository: otherKeyed
        ))
        #expect(cloud.sealedRecordIdentities == uploaded, "unopenable rows were exported as emptiness")
        #expect(host.reuploadDeferrals[.journalNarratives] == true)
    }

    /// The guard has to prove EXPORTABILITY, not row existence — a count cannot see whether the key can
    /// open what it counted.
    @Test func reuploadGuardProvesTheKeyCanOpenTheRowsNotJustThatRowsExist() throws {
        let host = makeHost()
        let coordinator = SealedBackupCoordinator(host: host)
        let repository = makeJournalRepository()
        try repository.insert(journalNarrative("under another key", at: 10), contentKey: SymmetricKey(size: .bits256))

        #expect(coordinator.journalNarrativeCount(repository: repository) == 1, "the row is really there")
        #expect(coordinator.mayReuploadFromLocalStore(.journalNarratives, journalRepository: repository) == false,
                "a row this key cannot open is not something to export")

        // And with no key at all (the app is locked) nothing is exportable.
        host.sealedBackupContentKey = nil
        let openable = makeJournalRepository()
        #expect(coordinator.mayReuploadFromLocalStore(.journalNarratives, journalRepository: openable) == false)
    }

    /// Hidden intimacy must upload NOTHING and must not read as done: the reconcile cannot page the
    /// gated store, so the obligation is recorded and discharged by the un-hide settle.
    @Test func intimacyEnableWhileHiddenDefersAndLeavesTheCloudUntouched() async throws {
        let cloud = try makeCloud()
        defer { cloud.tearDown() }
        let host = makeHost()
        let coordinator = makeCloudCoordinator(host: host, cloud: cloud)
        let store = makeIntimacyStore()
        try seed(intimacyLog("logged while visible", at: 10), into: store, key: host.sealedBackupContentKey)

        host.isIntimacyTrackingVisible = false
        #expect(await coordinator.setSealedBackupEnabled(
            true, payloadType: .intimacyLogs, intimacyStore: store
        ), "hiding must never make the toggle revert — hiding is not a delete")
        #expect(cloud.sealedRecords.isEmpty, "a hidden export must not write anything")
        #expect(host.reuploadDeferrals[.intimacyLogs] == true)

        // Un-hidden, the same enable actually uploads and clears the obligation.
        host.isIntimacyTrackingVisible = true
        #expect(await coordinator.setSealedBackupEnabled(
            true, payloadType: .intimacyLogs, intimacyStore: store
        ))
        #expect(cloud.sealedRecords.isEmpty == false)
        #expect(host.reuploadDeferrals[.intimacyLogs] == false)
    }

    // MARK: - Compensating restore paths (the launch pass is fresh-install-only)

    /// The launch arm can only ever answer `.skippedStoreNotEmpty` on a device that is already in use —
    /// an outcome that is neither `needsAttention` nor `isRetryable`, i.e. silent AND terminal. The
    /// targeted `.payloadStoreOnly` restore is the compensating path, and it must work on exactly that
    /// device.
    @Test func targetedJournalRestoreRecoversOnADeviceThatIsNoLongerFresh() async throws {
        let cloud = try makeCloud()
        defer { cloud.tearDown() }
        let host = makeHost()
        let coordinator = makeCloudCoordinator(host: host, cloud: cloud)

        let source = makeJournalRepository()
        try source.insert(journalNarrative("only in the cloud", at: 10), contentKey: host.sealedBackupContentKey)
        #expect(await coordinator.setSealedBackupEnabled(
            true, payloadType: .journalNarratives, journalRepository: source
        ))

        // The replacement device: day rows already synced down, so it is NOT a fresh install.
        host.days = ["2026-06-01": FernletDay(date: "2026-06-01", bottleCount: 3)]
        let target = makeJournalRepository()

        #expect(await coordinator.restoreSealedBackupOutcome(payloadType: .journalNarratives) == .skippedStoreNotEmpty,
                "the ambient launch arm is fresh-install-only by design")
        let outcome = await coordinator.restoreJournalBackupTargeted(journalRepository: target)
        #expect(outcome == .restored(1))
        let readBack = try target.narratives(offset: 0, limit: 10, contentKey: host.sealedBackupContentKey)
        #expect(readBack.map(\.text) == ["only in the cloud"])
    }

    /// Same for intimacy, plus its gate: hidden defers (retryable — un-hiding IS the retry) and writes
    /// nothing; the identical call succeeds once the surface is visible.
    @Test func targetedIntimacyRestoreDefersWhileHiddenAndRecoversAfterUnhiding() async throws {
        let cloud = try makeCloud()
        defer { cloud.tearDown() }
        let host = makeHost()
        let coordinator = makeCloudCoordinator(host: host, cloud: cloud)

        let source = makeIntimacyStore()
        try seed(intimacyLog("only in the cloud", at: 10), into: source, key: host.sealedBackupContentKey)
        #expect(await coordinator.setSealedBackupEnabled(
            true, payloadType: .intimacyLogs, intimacyStore: source
        ))

        host.days = ["2026-06-01": FernletDay(date: "2026-06-01", bottleCount: 3)]
        let target = makeIntimacyStore()

        host.isIntimacyTrackingVisible = false
        let hidden = await coordinator.restoreIntimacyBackupTargeted(intimacyStore: target)
        #expect(hidden == .deferredTransient)
        #expect(hidden.isRetryable)
        #expect(try target.backupLogCount() == 0)

        host.isIntimacyTrackingVisible = true
        #expect(await coordinator.restoreIntimacyBackupTargeted(intimacyStore: target) == .restored(1))
        #expect(try target.backupPage(offset: 0, limit: 10, contentKey: host.sealedBackupContentKey).map(\.note)
                == ["only in the cloud"])
    }

    /// The targeted paths drop the whole-device freshness gate, so the one-way divergence latch is what
    /// keeps them safe: a user who DELETED their entries must never have them resurrected from the
    /// stale-by-construction cloud copy.
    @Test func targetedRestoresRefuseAnEmptyButDivergedStore() async throws {
        let cloud = try makeCloud()
        defer { cloud.tearDown() }
        let host = makeHost()
        let coordinator = makeCloudCoordinator(host: host, cloud: cloud)

        let source = makeJournalRepository()
        try source.insert(journalNarrative("deleted on the other device", at: 10), contentKey: host.sealedBackupContentKey)
        _ = await coordinator.setSealedBackupEnabled(true, payloadType: .journalNarratives, journalRepository: source)
        let intimacySource = makeIntimacyStore()
        try seed(intimacyLog("deleted", at: 10), into: intimacySource, key: host.sealedBackupContentKey)
        _ = await coordinator.setSealedBackupEnabled(true, payloadType: .intimacyLogs, intimacyStore: intimacySource)

        // Written, then deleted: count 0, latch set.
        let divergedJournal = makeJournalRepository()
        let entry = journalNarrative("written then deleted", at: 20)
        try divergedJournal.insert(entry, contentKey: host.sealedBackupContentKey)
        try divergedJournal.delete(id: entry.id)
        let divergedIntimacy = makeIntimacyStore()
        try seed(intimacyLog("written then deleted", at: 20), into: divergedIntimacy, key: host.sealedBackupContentKey)
        try divergedIntimacy.deleteAll()

        #expect(await coordinator.restoreJournalBackupTargeted(journalRepository: divergedJournal) == .skippedStoreNotEmpty)
        #expect(try divergedJournal.narrativeCount() == 0)
        #expect(await coordinator.restoreIntimacyBackupTargeted(intimacyStore: divergedIntimacy) == .skippedStoreNotEmpty)
        #expect(try divergedIntimacy.backupLogCount() == 0)
    }

    // MARK: - Pass-level freshness (one arm must not sabotage the next)

    /// The journal restore WRITES DAY ROWS (`reinstateJournalEntries` rebuilds the skeletons the UI
    /// renders), and a day carrying journals satisfies `hasLoggedContent`. Re-deriving the whole-device
    /// freshness verdict per payload therefore lets the journal arm turn every arm after it into a
    /// silent, terminal `.skippedStoreNotEmpty`. The launch pass pins the verdict once, before any arm
    /// runs, and threads it through — this proves both the hazard and the fix.
    @Test func journalDaySkeletonWritebackCannotPoisonALaterArmsFreshnessGate() throws {
        let host = makeHost()
        let coordinator = SealedBackupCoordinator(host: host)
        let journal = makeJournalRepository()
        let intimacy = makeIntimacyStore()
        #expect(host.days.isEmpty, "the pass starts on a genuinely fresh device")

        // Arm 1: journal, at the launch scope, on a device that really is fresh.
        #expect(try coordinator.applyRestoredPayload(
            try encode([journalNarrative("restored", at: 100)]),
            payloadType: .journalNarratives,
            journalRepository: journal,
            scope: .freshInstall
        ) == 1)
        #expect(host.days.isEmpty == false, "the journal arm writes day skeletons — that is the hazard")

        // Arm 2 re-deriving the verdict now reads the arm-1 writeback as "device already in use".
        #expect(throws: SealedBackupCoordinator.SealedBackupWiringError.storeNotEmpty) {
            try coordinator.applyRestoredPayload(
                try encode([intimacyLog("restored", at: 100)]),
                payloadType: .intimacyLogs,
                intimacyStore: intimacy,
                scope: .freshInstall
            )
        }

        // With the pass-level verdict pinned (as `restoreSealedBackupsIfNeeded` does), it restores.
        #expect(try coordinator.applyRestoredPayload(
            try encode([intimacyLog("restored", at: 100)]),
            payloadType: .intimacyLogs,
            intimacyStore: intimacy,
            scope: .freshInstall,
            freshInstallOverride: true
        ) == 1)
        #expect(try intimacy.backupLogCount() == 1)
    }

    /// Pinning the whole-device verdict must NOT weaken the per-payload no-clobber checks — they stay
    /// live and unconditional, which is what actually protects the user's data.
    @Test func pinnedFreshnessStillHonorsThePerPayloadStoreChecks() throws {
        let host = makeHost()
        let coordinator = SealedBackupCoordinator(host: host)
        let journal = makeJournalRepository()
        try journal.insert(journalNarrative("written here", at: 10), contentKey: host.sealedBackupContentKey)

        #expect(throws: SealedBackupCoordinator.SealedBackupWiringError.storeNotEmpty) {
            try coordinator.applyRestoredPayload(
                try encode([journalNarrative("from the backup", at: 100)]),
                payloadType: .journalNarratives,
                journalRepository: journal,
                scope: .freshInstall,
                freshInstallOverride: true
            )
        }
        #expect(try journal.narrativeCount() == 1)
    }

    // MARK: - Journal: restore into an empty store

    @Test func journalRestoreWritesNarrativesIntoAnEmptyStore() throws {
        let host = makeHost()
        let coordinator = SealedBackupCoordinator(host: host)
        let repository = makeJournalRepository()
        let narratives = [
            journalNarrative("Slept badly, wrote it down.", at: 100),
            journalNarrative("Better today.", dayKey: "2026-06-02", at: 200)
        ]

        let count = try coordinator.applyRestoredPayload(
            try encode(narratives),
            payloadType: .journalNarratives,
            journalRepository: repository,
            scope: .payloadStoreOnly
        )
        #expect(count == 2)

        let readBack = try repository.narratives(offset: 0, limit: 10, contentKey: host.sealedBackupContentKey)
        #expect(readBack.map(\.text) == ["Slept badly, wrote it down.", "Better today."])
        #expect(readBack.first?.emotions == ["calm"])
        // Self-sufficiency: the skeletons hook fired with exactly what was written.
        #expect(host.reinstatedJournalNarratives.count == 1)
        #expect(host.reinstatedJournalNarratives.first?.count == 2)
    }

    /// Insert-into-empty, never overwrite: a store that already holds journal rows is refused outright
    /// rather than merged, so a restore can never clobber or duplicate the user's own text.
    @Test func journalRestoreRefusesAPopulatedStore() throws {
        let host = makeHost()
        let coordinator = SealedBackupCoordinator(host: host)
        let repository = makeJournalRepository()
        try repository.insert(journalNarrative("Written on this device.", at: 50), contentKey: host.sealedBackupContentKey)

        #expect(throws: SealedBackupCoordinator.SealedBackupWiringError.storeNotEmpty) {
            try coordinator.applyRestoredPayload(
                try encode([journalNarrative("From the backup.", at: 100)]),
                payloadType: .journalNarratives,
                journalRepository: repository,
                scope: .payloadStoreOnly
            )
        }
        #expect(try repository.narrativeCount() == 1)
        #expect(host.reinstatedJournalNarratives.isEmpty, "a refused restore must not touch the day blob")
    }

    /// The empty-but-DIVERGED store: the user wrote entries and deleted them, so the row count is 0
    /// while the cloud copy is stale-by-construction. Restoring there would resurrect deliberately
    /// deleted journal text — the one-way latch is what carries that missing bit.
    @Test func journalRestoreRefusesAnEmptyButDivergedStore() throws {
        let host = makeHost()
        let coordinator = SealedBackupCoordinator(host: host)
        let repository = makeJournalRepository()
        let entry = journalNarrative("Written, then deleted.", at: 50)
        try repository.insert(entry, contentKey: host.sealedBackupContentKey)
        try repository.delete(id: entry.id)
        #expect(try repository.narrativeCount() == 0)
        #expect(repository.hasEverStoredNarrative)

        #expect(throws: SealedBackupCoordinator.SealedBackupWiringError.storeNotEmpty) {
            try coordinator.applyRestoredPayload(
                try encode([journalNarrative("Resurrected?", at: 100)]),
                payloadType: .journalNarratives,
                journalRepository: repository,
                scope: .payloadStoreOnly
            )
        }
        #expect(try repository.narrativeCount() == 0)
    }

    /// Locked at the write point → `.locked`, which the restore classifier maps to the RETRYABLE
    /// `.deferredLocked`; unlocking and retrying is the self-heal, and it must actually work.
    @Test func journalRestoreDefersWhileLockedThenSelfHealsAfterUnlock() throws {
        let host = makeHost(key: nil)   // locked: no content key
        let coordinator = SealedBackupCoordinator(host: host)
        let repository = makeJournalRepository()
        let payload = try encode([journalNarrative("Waiting for the unlock.", at: 100)])

        #expect(throws: SealedBackupCoordinator.SealedBackupWiringError.locked) {
            try coordinator.applyRestoredPayload(
                payload, payloadType: .journalNarratives,
                journalRepository: repository, scope: .payloadStoreOnly
            )
        }
        #expect(try repository.narrativeCount() == 0)
        #expect(repository.hasEverStoredNarrative == false, "a deferred restore must not latch divergence")
        #expect(SealedBackupRestoreOutcome.deferredLocked.isRetryable)

        // The user unlocks; the same payload now lands.
        host.sealedBackupContentKey = SymmetricKey(size: .bits256)
        let count = try coordinator.applyRestoredPayload(
            payload, payloadType: .journalNarratives,
            journalRepository: repository, scope: .payloadStoreOnly
        )
        #expect(count == 1)
        #expect(try repository.narrativeCount() == 1)
    }


    // MARK: - Intimacy: restore through the gated funnel

    @Test func intimacyRestoreWritesLogsIntoAnEmptyStore() throws {
        let host = makeHost()
        let coordinator = SealedBackupCoordinator(host: host)
        let store = makeIntimacyStore()
        let logs = [intimacyLog("first", at: 100), intimacyLog("second", at: 200)]

        let count = try coordinator.applyRestoredPayload(
            try encode(logs),
            payloadType: .intimacyLogs,
            intimacyStore: store,
            scope: .payloadStoreOnly
        )
        #expect(count == 2)
        let readBack = try store.backupPage(offset: 0, limit: 10, contentKey: host.sealedBackupContentKey)
        #expect(readBack.map(\.note) == ["first", "second"])
        #expect(host.reinstatedJournalNarratives.isEmpty, "intimacy restore must not touch journal skeletons")
    }

    @Test func intimacyRestoreRefusesAPopulatedStore() throws {
        let host = makeHost()
        let coordinator = SealedBackupCoordinator(host: host)
        let store = makeIntimacyStore()
        try seed(intimacyLog("logged locally", at: 50), into: store, key: host.sealedBackupContentKey)

        #expect(throws: SealedBackupCoordinator.SealedBackupWiringError.storeNotEmpty) {
            try coordinator.applyRestoredPayload(
                try encode([intimacyLog("from the backup", at: 100)]),
                payloadType: .intimacyLogs,
                intimacyStore: store,
                scope: .payloadStoreOnly
            )
        }
        #expect(try store.backupLogCount() == 1)
    }

    /// The empty-but-DIVERGED store: logged, then deleted, so the count is 0 while the cloud copy is
    /// stale-by-construction. Restoring there would resurrect deliberately deleted intimate notes.
    @Test func intimacyRestoreRefusesAnEmptyButDivergedStore() throws {
        let host = makeHost()
        let coordinator = SealedBackupCoordinator(host: host)
        let store = makeIntimacyStore()
        try seed(intimacyLog("logged, then deleted", at: 50), into: store, key: host.sealedBackupContentKey)
        // Deleting is ungated (hiding must never block a wipe) and latches divergence.
        try store.deleteAll()
        #expect(try store.backupLogCount() == 0)
        #expect(store.hasEverStoredLog)

        #expect(throws: SealedBackupCoordinator.SealedBackupWiringError.storeNotEmpty) {
            try coordinator.applyRestoredPayload(
                try encode([intimacyLog("resurrected?", at: 100)]),
                payloadType: .intimacyLogs,
                intimacyStore: store,
                scope: .payloadStoreOnly
            )
        }
        #expect(try store.backupLogCount() == 0)
    }

    @Test func intimacyRestoreDefersWhileLockedThenSelfHealsAfterUnlock() throws {
        let host = makeHost(key: nil)
        let coordinator = SealedBackupCoordinator(host: host)
        let store = makeIntimacyStore()
        let payload = try encode([intimacyLog("waiting for the unlock", at: 100)])

        #expect(throws: SealedBackupCoordinator.SealedBackupWiringError.locked) {
            try coordinator.applyRestoredPayload(
                payload, payloadType: .intimacyLogs,
                intimacyStore: store, scope: .payloadStoreOnly
            )
        }
        #expect(try store.backupLogCount() == 0)
        #expect(store.hasEverStoredLog == false)

        host.sealedBackupContentKey = SymmetricKey(size: .bits256)
        #expect(try coordinator.applyRestoredPayload(
            payload, payloadType: .intimacyLogs,
            intimacyStore: store, scope: .payloadStoreOnly
        ) == 1)
    }

    /// Hidden at restore → DEFERRED, then restores on un-hide. The write is a decrypt seam, so the
    /// gated funnel refuses it while hidden (a retryable failure, not a silent write behind the gate),
    /// and the identical call succeeds once the surface is visible again. The coordinator re-wires the
    /// injected store's gate from the host, which is why flipping the host is all this test does.
    @Test func intimacyRestoreIsRefusedWhileHiddenAndSucceedsAfterUnhiding() throws {
        let host = makeHost()
        host.isIntimacyTrackingVisible = false
        let coordinator = SealedBackupCoordinator(host: host)
        let store = makeIntimacyStore()
        let payload = try encode([intimacyLog("from the backup", at: 100)])

        #expect(throws: IntimacyTrackingHiddenError.self) {
            try coordinator.applyRestoredPayload(
                payload, payloadType: .intimacyLogs,
                intimacyStore: store, scope: .payloadStoreOnly
            )
        }
        #expect(try store.backupLogCount() == 0)

        host.isIntimacyTrackingVisible = true
        #expect(try coordinator.applyRestoredPayload(
            payload, payloadType: .intimacyLogs,
            intimacyStore: store, scope: .payloadStoreOnly
        ) == 1)
    }

    /// The no-clobber GATE, unlike the write, is deliberately NOT visibility-aware: it counts rows
    /// without decrypting. A hidden store reading as "empty" here would be the hidden-means-empty bug —
    /// the gate would wave a restore through on top of data it could not see.
    @Test func intimacyNoClobberGateNeverReadsAHiddenStoreAsEmpty() throws {
        let host = makeHost()
        let coordinator = SealedBackupCoordinator(host: host)
        let store = makeIntimacyStore()
        try seed(intimacyLog("hidden but present", at: 50), into: store, key: host.sealedBackupContentKey)

        host.isIntimacyTrackingVisible = false
        // storeNotEmpty, NOT "hidden" — the gate ran first and saw the rows through the closed gate.
        #expect(throws: SealedBackupCoordinator.SealedBackupWiringError.storeNotEmpty) {
            try coordinator.applyRestoredPayload(
                try encode([intimacyLog("from the backup", at: 100)]),
                payloadType: .intimacyLogs,
                intimacyStore: store,
                scope: .payloadStoreOnly
            )
        }
        #expect(coordinator.intimacyLogCount(store: store) == 1, "a hidden store must not count as empty")
        #expect(store.hasEverStoredLog, "a hidden store must not read as never-populated")
    }

    // MARK: - Empty-store clobber guards

    /// `reconcileChunked` writes a head record even for a count of 0, so an export from a store this
    /// device has not restored into yet would REPLACE a good cloud backup with a single empty chunk.
    /// An empty store means "not restored yet", never "nothing to back up".
    @Test func reuploadIsRefusedFromAnEmptyJournalStoreAndAllowedFromAPopulatedOne() throws {
        let host = makeHost()
        let coordinator = SealedBackupCoordinator(host: host)
        let empty = makeJournalRepository()
        #expect(coordinator.mayReuploadFromLocalStore(.journalNarratives, journalRepository: empty) == false)

        let populated = makeJournalRepository()
        try populated.insert(journalNarrative("real history", at: 10), contentKey: host.sealedBackupContentKey)
        #expect(coordinator.mayReuploadFromLocalStore(.journalNarratives, journalRepository: populated))
    }

    @Test func reuploadIsRefusedFromAnEmptyIntimacyStoreAndAllowedFromAPopulatedOne() throws {
        let host = makeHost()
        let coordinator = SealedBackupCoordinator(host: host)
        let empty = makeIntimacyStore()
        #expect(coordinator.mayReuploadFromLocalStore(.intimacyLogs, intimacyStore: empty) == false)

        let populated = makeIntimacyStore()
        try seed(intimacyLog("real history", at: 10), into: populated, key: host.sealedBackupContentKey)
        #expect(coordinator.mayReuploadFromLocalStore(.intimacyLogs, intimacyStore: populated))
    }

    /// Hidden intimacy also blocks the re-upload, and for a second reason: while hidden the reconcile
    /// is a SILENT no-op, so calling it would log a false "reconciled" while the cloud chunk stayed
    /// sealed to the escrow key that was just replaced.
    @Test func reuploadIsRefusedWhileIntimacyIsHiddenEvenWithAPopulatedStore() throws {
        let host = makeHost()
        let coordinator = SealedBackupCoordinator(host: host)
        let populated = makeIntimacyStore()
        try seed(intimacyLog("real history", at: 10), into: populated, key: host.sealedBackupContentKey)
        #expect(coordinator.mayReuploadFromLocalStore(.intimacyLogs, intimacyStore: populated))

        host.isIntimacyTrackingVisible = false
        #expect(coordinator.mayReuploadFromLocalStore(.intimacyLogs, intimacyStore: populated) == false)
    }

    /// The counts the guards read work with no content key in play — the guards run while the app may
    /// be locked, and they fail CLOSED at 0 so "unknown" reads as "do not re-upload".
    @Test func countsReadRowsWithoutAKeyAndStartAtZero() throws {
        let host = makeHost()
        let coordinator = SealedBackupCoordinator(host: host)
        let journal = makeJournalRepository()
        let intimacy = makeIntimacyStore()
        #expect(coordinator.journalNarrativeCount(repository: journal) == 0)
        #expect(coordinator.intimacyLogCount(store: intimacy) == 0)

        try journal.insert(journalNarrative("one", at: 1), contentKey: host.sealedBackupContentKey)
        try seed(intimacyLog("one", at: 1), into: intimacy, key: host.sealedBackupContentKey)
        #expect(coordinator.journalNarrativeCount(repository: journal) == 1)
        #expect(coordinator.intimacyLogCount(store: intimacy) == 1)
    }

    // MARK: - Chunked round trip (what the CloudKit path hands back)

    /// Restore receives an ARRAY of decrypted chunks, not one blob. Both new payloads must reassemble
    /// across chunk boundaries in a single all-or-nothing transaction.
    @Test func journalRestoreReassemblesMultipleChunks() throws {
        let host = makeHost()
        let coordinator = SealedBackupCoordinator(host: host)
        let repository = makeJournalRepository()
        let chunks = [
            try encode([journalNarrative("chunk 0 a", at: 10), journalNarrative("chunk 0 b", at: 20)]),
            try encode([journalNarrative("chunk 1 a", at: 30)])
        ]
        let count = try coordinator.applyRestoredChunks(
            chunks, payloadType: .journalNarratives,
            journalRepository: repository, scope: .payloadStoreOnly
        )
        #expect(count == 3)
        #expect(try repository.narrativeCount() == 3)
    }

    @Test func intimacyRestoreReassemblesMultipleChunks() throws {
        let host = makeHost()
        let coordinator = SealedBackupCoordinator(host: host)
        let store = makeIntimacyStore()
        let chunks = [
            try encode([intimacyLog("chunk 0 a", at: 10), intimacyLog("chunk 0 b", at: 20)]),
            try encode([intimacyLog("chunk 1 a", at: 30)])
        ]
        let count = try coordinator.applyRestoredChunks(
            chunks, payloadType: .intimacyLogs,
            intimacyStore: store, scope: .payloadStoreOnly
        )
        #expect(count == 3)
        #expect(try store.backupLogCount() == 3)
    }
}

/// The in-memory stand-in for the user's private CloudKit database plus the throwaway keychain the
/// sealed records are sealed under, so an EXPORT can be asserted on: what reached iCloud, and whether a
/// later call left it alone. Real `SealedBackupService` + real crypto sit on top — only the transport
/// and the keychain slot are substituted.
@MainActor
final class FakeSealedBackupCloud {
    let keychainService: String
    let generationDefaults: UserDefaults
    let database = InMemoryCloudKitRecordDatabase()

    init(keychainService: String, generationDefaults: UserDefaults) {
        self.keychainService = keychainService
        self.generationDefaults = generationDefaults
    }

    /// The sealed-backup records currently "in iCloud", in save order.
    var sealedRecords: [CKRecord] { database.recordsByType["SealedBackupRecord"] ?? [] }

    /// Object identities of those records — an untouched chunk set keeps the SAME objects, so this is
    /// how a test asserts that a refused export wrote nothing rather than rewriting identical bytes.
    var sealedRecordIdentities: [ObjectIdentifier] { sealedRecords.map(ObjectIdentifier.init) }

    func tearDown() { KeychainItem.deleteAll(service: keychainService) }
}

/// Minimal `CloudKitRecordDatabase` over a dictionary. Copies the sealed blob asset out of the
/// caller's temporary file the way CloudKit's own upload does, so a record stays readable after the
/// writer's scratch file goes away.
final class InMemoryCloudKitRecordDatabase: CloudKitRecordDatabase {
    var recordsByType: [String: [CKRecord]] = [:]

    private var allRecords: [CKRecord] { recordsByType.values.flatMap { $0 } }

    func recordZoneIDs() async throws -> [CKRecordZone.ID] {
        var seen = Set<String>()
        return allRecords.compactMap { record in
            let zoneID = record.recordID.zoneID
            return seen.insert("\(zoneID.ownerName):\(zoneID.zoneName)").inserted ? zoneID : nil
        }
    }

    func recordIDs(matching recordType: String, in zoneID: CKRecordZone.ID) async throws -> [CKRecord.ID] {
        recordsByType[recordType, default: []].filter { $0.recordID.zoneID == zoneID }.map(\.recordID)
    }

    func records(for recordIDs: [CKRecord.ID]) async throws -> [CKRecord] {
        let requested = Set(recordIDs.map(\.recordName))
        return allRecords.filter { requested.contains($0.recordID.recordName) }
    }

    func saveRecords(_ records: [CKRecord]) async throws {
        for record in records {
            if let asset = record["encryptedBlob"] as? CKAsset, let sourceURL = asset.fileURL {
                let stableURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension("fernlet-sealed-backup-test")
                try FileManager.default.copyItem(at: sourceURL, to: stableURL)
                record["encryptedBlob"] = CKAsset(fileURL: stableURL)
            }
            var existing = recordsByType[record.recordType, default: []]
            existing.removeAll { $0.recordID == record.recordID }
            existing.append(record)
            recordsByType[record.recordType] = existing
        }
    }

    func deleteRecords(with recordIDs: [CKRecord.ID]) async throws {
        let deleted = Set(recordIDs.map(\.recordName))
        for recordType in recordsByType.keys {
            recordsByType[recordType] = recordsByType[recordType, default: []]
                .filter { !deleted.contains($0.recordID.recordName) }
        }
    }
}

/// An iCloud account that is always signed in — these tests are about backup policy, not the sign-in
/// gate, which `CloudKitDataServiceTests` covers.
struct AlwaysAvailableAccountProvider: CloudKitAccountStatusProviding {
    func accountStatus() async throws -> CKAccountStatus { .available }
}
