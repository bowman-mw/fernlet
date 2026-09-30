// PrivateHubOpenCoordinatorTests.swift
// FernletTests
//
// Design invariant I33 (period-data design 2026-09-30, §4.9): the no-passcode Private tab's open
// coordinator never deletes a row without the "Remove them and open Private" tap, never mints a
// fresh key over rows no key on this iPhone can open before that tap, removes exactly the rows it
// showed, and clears only the named bookkeeping (the three divergence latches).
//
// Driven over a REAL `FernletLockService` on isolated keychain services and a fake enclave
// (`DeviceCustodyFixture`), and a real in-memory sealed store, so every answer the coordinator
// acts on — the device row, the mint-safety proof, the sealed rows — is the production code's own.

import CoreData
import CryptoKit
import Foundation
import Testing
import FernletDomainModel
import FernletFoundation
import FernletLockUI
import PrivateHealthStore
import PrivateMemoryStore
import PrivateStoreCore
@testable import FernletCrypto
@testable import FernletLock
@testable import Fernlet

/// One coordinator over one fixture's lock service and sealed store, plus the handles a test uses
/// to plant rows and to read what is left.
@MainActor
private struct CoordinatorRig {
    let fixture = DeviceCustodyFixture()
    let latches = UserDefaults(suiteName: "fernlet.tests.hubOpen.\(UUID().uuidString)") ?? .standard
    let service: FernletLockService
    let entries: SealedPriorEntryStore
    let coordinator: PrivateHubOpenCoordinator

    /// - Parameters:
    ///   - periodVisible: The derived period-tracking visibility the store reports.
    ///   - intimacyVisible: The derived intimacy-tracking visibility the store reports.
    ///   - restoresAfterRemoval: The app's "will a Sealed backup really come back" decision.
    init(
        periodVisible: Bool = true,
        intimacyVisible: Bool = true,
        restoresAfterRemoval: @escaping (_ journalKeepsOpenableRows: Bool) -> Bool = { _ in false }
    ) {
        service = fixture.makeService()
        entries = SealedPriorEntryStore(
            controller: fixture.persistence,
            latchDefaults: latches,
            intimacyStore: IntimacyLogStore(repository: IntimacyLogRepository(controller: fixture.persistence, defaults: latches)),
            deviceKeyService: fixture.harness.sealedContentKeyServiceID,
            periodVisible: { periodVisible },
            intimacyVisible: { intimacyVisible },
            restoresAfterRemoval: restoresAfterRemoval
        )
        coordinator = PrivateHubOpenCoordinator(custody: service, entries: entries)
    }

    var cycle: MenstrualNarrativeRepository { MenstrualNarrativeRepository(controller: fixture.persistence, defaults: latches) }
    var journal: JournalNarrativeRepository { JournalNarrativeRepository(controller: fixture.persistence, defaults: latches) }
    var worry: WorryNarrativeRepository { WorryNarrativeRepository(controller: fixture.persistence) }
    var intimacy: IntimacyLogRepository { IntimacyLogRepository(controller: fixture.persistence, defaults: latches) }

    /// This iPhone's journal device key (minted on first use, as the app does while Private is closed).
    var journalDeviceKey: SymmetricKey? {
        KeychainItem.loadOrCreateSymmetricKey(for: .deviceJournalKey, service: fixture.harness.sealedContentKeyServiceID)
    }

    /// A key that sealed rows and then vanished — the key a new iPhone or an erased one no longer has.
    static let lostKey = SymmetricKey(size: .bits256)

    /// Plants one row of every hub-key-only kind under a lost key, one dead and one live journal row,
    /// and one dead worry. Returns the live journal row's id.
    func plantMixedPriorEntries() throws -> UUID {
        try cycle.insert(MenstrualNarrative(hkExternalUUID: "old-cycle", dateKey: "2026-09-01", note: "gone"), contentKey: Self.lostKey)
        try intimacy.insert(IntimacyLog(eventDate: Date(), note: "gone"), contentKey: Self.lostKey)
        try journal.insert(Self.journalNarrative("sealed under the lost key"), contentKey: Self.lostKey)
        let live = Self.journalNarrative("written from Home while Private was closed")
        // A nil device key would make the insert throw `.locked`, so the plant fails loudly.
        try journal.insert(live, contentKey: journalDeviceKey)
        try worry.insert(WorryNarrative(text: "gone"), contentKey: Self.lostKey)
        return live.id
    }

    static func journalNarrative(_ text: String) -> JournalNarrative {
        JournalNarrative(id: UUID(), dayKey: "2026-09-02", tag: .good, entryDate: Date(), text: text, emotions: [], createdAt: Date(), updatedAt: Date())
    }

    /// Every sealed row in the fixture's store, counted keylessly.
    func rowCount() throws -> Int { try fixture.persistence.sealedRowCount() }
}

/// A settable stand-in for the owner hold, captured by a rig's backup decision.
@MainActor
private final class HoldSwitch {
    var isHeld = false
}

@Suite(.serialized)
struct PrivateHubOpenCoordinatorTests {

    // MARK: - Nothing on the iPhone, or a key already here

    @MainActor
    @Test func aFirstTapOverAnEmptyStoreMintsAndOpens() async throws {
        let rig = CoordinatorRig()
        defer { rig.fixture.cleanup() }

        #expect(await rig.coordinator.openPrivateHub() == .opened)
        #expect(rig.service.state == .openedWithoutPasscode(scope: .privateHub))
        #expect(rig.fixture.row(.deviceContentKey) != nil, "the first tap mints the device-custody key")

        let first = hubKeyBytes(rig.service)
        rig.service.lock(reason: .manual)
        #expect(await rig.coordinator.openPrivateHub() == .opened)
        #expect(hubKeyBytes(rig.service) == first, "every later tap opens the SAME key")
    }

    // MARK: - Entries no key here can open

    /// The card: nothing minted, nothing deleted, every dead kind counted, the live journal row
    /// (it opens under this iPhone's journal device key) NOT counted.
    @MainActor
    @Test func deadRowsShowTheCardAndNothingIsMintedOrDeleted() async throws {
        let rig = CoordinatorRig()
        defer { rig.fixture.cleanup() }
        _ = try rig.plantMixedPriorEntries()
        let before = try rig.rowCount()

        let outcome = await rig.coordinator.openPrivateHub()

        #expect(outcome == .unopenableEntries(FernletUnopenableEntryCounts(
            cycleEntries: 1, intimacyEntries: 1, journalEntries: 1, worryEntries: 1
        )))
        #expect(try rig.rowCount() == before, "the card deletes nothing")
        #expect(rig.fixture.row(.deviceContentKey) == nil, "no key is minted over rows it would strand")
        #expect(rig.service.state == .notConfigured)
        // "Not now" is the card simply going away: a second tap shows the same card, still deleting nothing.
        #expect(await rig.coordinator.openPrivateHub() == outcome)
        #expect(try rig.rowCount() == before)
    }

    /// The Remove tap: exactly the dead rows go (the live journal row stays), the latches the lost key
    /// spoke for are cleared AFTER the deletes that set them, and the fresh key opens Private.
    @MainActor
    @Test func removeDeletesExactlyTheDeadRowsClearsTheLatchesAndOpens() async throws {
        let rig = CoordinatorRig()
        defer { rig.fixture.cleanup() }
        let liveJournalID = try rig.plantMixedPriorEntries()
        guard case .unopenableEntries(let shown) = await rig.coordinator.openPrivateHub() else {
            Issue.record("expected the card")
            return
        }

        #expect(await rig.coordinator.removeUnopenableEntriesAndOpen(named: shown) == .opened)

        #expect(try rig.cycle.narrativeCount() == 0)
        #expect(try rig.intimacy.logCount() == 0)
        #expect(try rig.worry.worries(contentKey: CoordinatorRig.lostKey).isEmpty)
        let journalLeft = try rig.journal.openability(under: rig.journalDeviceKey)
        #expect(journalLeft.openableIDs == [liveJournalID], "the live journal row is never removed")
        #expect(journalLeft.deadIDs.isEmpty)
        #expect(!rig.cycle.hasEverStoredNarrative, "the cycle latch spoke for the lost key; it is cleared")
        #expect(!rig.intimacy.hasEverStoredLog)
        #expect(rig.service.state == .openedWithoutPasscode(scope: .privateHub))
        #expect(rig.fixture.row(.deviceContentKey) != nil)
    }

    /// A Remove tap whose card no longer matches what is here deletes nothing and re-shows the card.
    @MainActor
    @Test func aRemoveTapForAStaleCardDeletesNothing() async throws {
        let rig = CoordinatorRig()
        defer { rig.fixture.cleanup() }
        _ = try rig.plantMixedPriorEntries()
        let before = try rig.rowCount()
        let stale = FernletUnopenableEntryCounts(cycleEntries: 1)

        let outcome = await rig.coordinator.removeUnopenableEntriesAndOpen(named: stale)

        #expect(outcome == .unopenableEntries(FernletUnopenableEntryCounts(
            cycleEntries: 1, intimacyEntries: 1, journalEntries: 1, worryEntries: 1
        )))
        #expect(try rig.rowCount() == before)
        #expect(rig.fixture.row(.deviceContentKey) == nil)
    }

    /// Cycle notes held for Private under a buffer key that is gone are named, and removed on the tap.
    @MainActor
    @Test func unopenableHeldNotesAreNamedAndPurgedOnlyOnRemove() async throws {
        let rig = CoordinatorRig()
        defer { rig.fixture.cleanup() }
        let scope = rig.fixture.harness.narrativeBufferScope
        try PendingNarrativeBuffer(scope: scope).append(PendingNarrativePayload(
            hkExternalUUID: "held", dateKey: "2026-09-03", noteBytes: Data("held".utf8),
            symptomFlagsBytes: nil, customSymptomScalesBytes: nil
        ))
        KeychainItem.deleteAll(service: scope.keychainService)

        let shown = FernletUnopenableEntryCounts(hasUnopenableHeldEntries: true)
        #expect(await rig.coordinator.openPrivateHub() == .unopenableEntries(shown))
        #expect(try rig.service.pendingNarrativesAreUnopenable(), "the card purges nothing")

        #expect(await rig.coordinator.removeUnopenableEntriesAndOpen(named: shown) == .opened)
        #expect(try !rig.service.pendingNarrativesAreUnopenable())
    }

    // MARK: - Hidden kinds are never named (review C-U2-R5)

    /// Intimacy hidden (by the user, or the 18+ gate): the card — shown to whoever holds the phone —
    /// counts those rows only as "other private entries", and the Remove tap still removes them, or
    /// the fresh key would be minted over them.
    @MainActor
    @Test func aHiddenIntimacyKindIsCountedButNeverNamedAndStillRemoved() async throws {
        let rig = CoordinatorRig(intimacyVisible: false)
        defer { rig.fixture.cleanup() }
        _ = try rig.plantMixedPriorEntries()

        let shown = FernletUnopenableEntryCounts(cycleEntries: 1, journalEntries: 1, worryEntries: 1, otherEntries: 1)
        #expect(await rig.coordinator.openPrivateHub() == .unopenableEntries(shown), "no intimacy line; one other entry")
        #expect(rig.coordinator.tapGateNamesCycleEntries, "period is visible, so the tap screen may name cycle")

        #expect(await rig.coordinator.removeUnopenableEntriesAndOpen(named: shown) == .opened)
        #expect(try rig.intimacy.logCount() == 0, "the hidden kind's dead rows are removed with the rest")
        #expect(try rig.cycle.narrativeCount() == 0)
    }

    /// Period hidden (by the user, or by the sex-derived default): no "Cycle entries" line, and the
    /// tap screen's line stops naming cycle.
    @MainActor
    @Test func aHiddenPeriodKindIsNamedNeitherOnTheCardNorOnTheTapScreen() async throws {
        let rig = CoordinatorRig(periodVisible: false)
        defer { rig.fixture.cleanup() }
        _ = try rig.plantMixedPriorEntries()

        #expect(await rig.coordinator.openPrivateHub() == .unopenableEntries(FernletUnopenableEntryCounts(
            intimacyEntries: 1, journalEntries: 1, worryEntries: 1, otherEntries: 1
        )))
        #expect(!rig.coordinator.tapGateNamesCycleEntries)
    }

    /// Both hidden: the two kinds fold into one count, so not even which of them is here shows.
    @MainActor
    @Test func twoHiddenKindsFoldIntoOneOtherCount() {
        #expect(PrivateHubOpenCoordinator.shownCounts(cycleRows: 3, intimacyRows: 2, periodVisible: false, intimacyVisible: false)
                == FernletUnopenableEntryCounts(otherEntries: 5))
        #expect(PrivateHubOpenCoordinator.shownCounts(cycleRows: 3, intimacyRows: 2, periodVisible: true, intimacyVisible: true)
                == FernletUnopenableEntryCounts(cycleEntries: 3, intimacyEntries: 2))
    }

    // MARK: - The backup promise is made only when it will be kept (review C-U2-R3)

    /// The card's "Your Sealed backup will be restored after you continue" follows the real restore
    /// conditions: the journal backup restores only into an EMPTY journal store, so a journal row
    /// that opens (written from Home, folded in at the open) withholds the promise; with only dead
    /// rows it is made; and while an app-lock reset holds every restore for the owner it never is.
    @MainActor
    @Test func theCardPromisesABackupRestoreOnlyWhenOneWillRun() async throws {
        let journalBackupOnly = StoragePreferences(iCloudSyncEnabled: true, sealedBackupJournalEnabled: true)
        let hold = HoldSwitch()
        let decide: (Bool) -> Bool = { journalKeepsOpenableRows in
            ContentView.sealedBackupRestoresAfterRemoval(
                journalBackupOnly,
                intimacyVisible: true,
                restoreHeldForOwner: hold.isHeld,
                journalStoreEmptiesOnRemoval: !journalKeepsOpenableRows
            )
        }

        let withLiveJournal = CoordinatorRig(restoresAfterRemoval: decide)
        defer { withLiveJournal.fixture.cleanup() }
        _ = try withLiveJournal.plantMixedPriorEntries()
        #expect(await Self.promisesRestore(withLiveJournal) == false,
                "a journal row that opens stays behind, so the empty-store journal restore would refuse")

        let deadOnly = CoordinatorRig(restoresAfterRemoval: decide)
        defer { deadOnly.fixture.cleanup() }
        try deadOnly.journal.insert(CoordinatorRig.journalNarrative("sealed under the lost key"), contentKey: CoordinatorRig.lostKey)
        #expect(await Self.promisesRestore(deadOnly) == true, "the journal store empties, so its backup comes back")

        hold.isHeld = true
        #expect(await Self.promisesRestore(deadOnly) == false, "after an app-lock reset nothing is restored on its own")
    }

    /// The decision's intimacy half and its switches, beside the journal half above.
    @MainActor
    @Test func theBackupPromiseNeedsSyncAndAVisibleIntimacyHalf() {
        let intimacyOnly = StoragePreferences(iCloudSyncEnabled: true, sealedBackupIntimacyEnabled: true)
        #expect(ContentView.sealedBackupRestoresAfterRemoval(intimacyOnly, intimacyVisible: true, restoreHeldForOwner: false, journalStoreEmptiesOnRemoval: false))
        #expect(!ContentView.sealedBackupRestoresAfterRemoval(intimacyOnly, intimacyVisible: false, restoreHeldForOwner: false, journalStoreEmptiesOnRemoval: true),
                "a hidden intimacy backup defers its restore")
        #expect(!ContentView.sealedBackupRestoresAfterRemoval(intimacyOnly, intimacyVisible: true, restoreHeldForOwner: true, journalStoreEmptiesOnRemoval: true))
        let syncOff = StoragePreferences(sealedBackupJournalEnabled: true, sealedBackupIntimacyEnabled: true)
        #expect(!ContentView.sealedBackupRestoresAfterRemoval(syncOff, intimacyVisible: true, restoreHeldForOwner: false, journalStoreEmptiesOnRemoval: true))
    }

    /// The card's backup line for the rig's current rows, or nil when there is no card.
    @MainActor
    private static func promisesRestore(_ rig: CoordinatorRig) async -> Bool? {
        guard case .unopenableEntries(let counts) = await rig.coordinator.openPrivateHub() else { return nil }
        return counts.sealedBackupRestoresAfterRemoval
    }

    // MARK: - Bookkeeping only

    /// An empty store whose latches still speak for a key that is gone (a new iPhone whose device
    /// backup excluded the sealed store): no card — the latches are cleared, and Private opens.
    @MainActor
    @Test func bookkeepingAloneIsClearedAndPrivateOpens() async throws {
        let rig = CoordinatorRig()
        defer { rig.fixture.cleanup() }
        let narrative = MenstrualNarrative(hkExternalUUID: "deleted", dateKey: "2026-09-01", note: "x")
        try rig.cycle.insert(narrative, contentKey: CoordinatorRig.lostKey)
        try rig.cycle.delete(id: narrative.id)
        #expect(rig.cycle.hasEverStoredNarrative)

        #expect(await rig.coordinator.openPrivateHub() == .opened)
        #expect(!rig.cycle.hasEverStoredNarrative)
    }

    // MARK: - Never a card while a key may survive

    /// A salt-independent copy of an earlier key survives (a hard-bound lock that lost only its
    /// salt): the rows may still be openable, so the answer is "try again" — never the card, never a
    /// deletion, never a mint.
    @MainActor
    @Test func aKeyCopyThatMaySurviveNeverShowsTheCard() async throws {
        let rig = CoordinatorRig()
        defer { rig.fixture.cleanup() }
        _ = try rig.plantMixedPriorEntries()
        rig.fixture.plant(.seWrappedContentKey, Data("an enclave wrap of an earlier key".utf8))
        let before = try rig.rowCount()

        #expect(await rig.coordinator.openPrivateHub() == .tryAgain)
        #expect(await rig.coordinator.removeUnopenableEntriesAndOpen(named: FernletUnopenableEntryCounts(
            cycleEntries: 1, intimacyEntries: 1, journalEntries: 1, worryEntries: 1
        )) == .tryAgain)
        #expect(try rig.rowCount() == before)
        #expect(rig.fixture.row(.deviceContentKey) == nil)
    }

    /// While a custodian recovery is owed the recovery device holds the key those rows are sealed
    /// under: they are recoverable, so they are never called unopenable or offered for removal.
    @MainActor
    @Test func aRecoveryOwedNeverShowsTheCard() async throws {
        let rig = CoordinatorRig()
        defer { rig.fixture.cleanup() }
        _ = try rig.plantMixedPriorEntries()
        rig.fixture.plant(.recoveryBlob, Data(repeating: 7, count: SHA256.byteCount + 64))
        rig.fixture.plant(.custodianSigningPublicKey, Data(repeating: 1, count: 32))
        rig.fixture.plant(.custodianKeyAgreementPublicKey, Data(repeating: 2, count: 32))
        #expect(rig.service.isAwaitingCustodianRecovery)
        let before = try rig.rowCount()

        #expect(await rig.coordinator.openPrivateHub() == .tryAgain)
        #expect(try rig.rowCount() == before)
    }

    /// A row whose open could not be decided (the install-binding read did not answer) stops the
    /// check: nothing is called dead on a read that did not answer.
    @MainActor
    @Test func anUndecidedRowStopsTheCheck() async throws {
        let rig = CoordinatorRig()
        defer { rig.fixture.cleanup() }
        _ = try rig.plantMixedPriorEntries()
        let before = try rig.rowCount()

        let outcome = await DeviceBindingID.$testOverride.withValue(.readError) {
            await rig.coordinator.openPrivateHub()
        }

        #expect(outcome == .tryAgain)
        #expect(try rig.rowCount() == before)
        #expect(rig.fixture.row(.deviceContentKey) == nil)
    }

    // MARK: - A passcode setup that would mint a fresh key (design §4.4 step 2)

    /// The setup asks the same check: live device-key entries (a journal written from Home before
    /// Private was ever opened) do not block a setup — they are folded in at the next open — and the
    /// check itself mints nothing and deletes nothing.
    @MainActor
    @Test func aSetupOverOnlyLiveEntriesMayMint() async throws {
        let rig = CoordinatorRig()
        defer { rig.fixture.cleanup() }
        try rig.journal.insert(CoordinatorRig.journalNarrative("written from Home"), contentKey: rig.journalDeviceKey)
        let before = try rig.rowCount()

        #expect(await rig.coordinator.reviewPriorEntriesBeforeFreshKey() == .nothingUnopenable)
        #expect(try rig.rowCount() == before)
        #expect(rig.fixture.row(.deviceContentKey) == nil, "the review mints nothing; the setup does")
    }

    /// Dead entries stop the setup at the Private tab's card: nothing is minted or deleted by the
    /// review, and the counts are the card's.
    @MainActor
    @Test func aSetupOverUnopenableEntriesIsSentToThePrivateTab() async throws {
        let rig = CoordinatorRig()
        defer { rig.fixture.cleanup() }
        _ = try rig.plantMixedPriorEntries()
        let before = try rig.rowCount()

        #expect(await rig.coordinator.reviewPriorEntriesBeforeFreshKey() == .unopenableEntries(
            FernletUnopenableEntryCounts(cycleEntries: 1, intimacyEntries: 1, journalEntries: 1, worryEntries: 1)
        ))
        #expect(try rig.rowCount() == before)
        #expect(rig.fixture.row(.deviceContentKey) == nil)
    }

    // MARK: - The device row itself

    /// A device row whose enclave key is gone is the terminal lost-key state, not a card.
    @MainActor
    @Test func anUnopenableDeviceRowIsTheLostKeyCard() async throws {
        let rig = CoordinatorRig()
        defer { rig.fixture.cleanup() }
        #expect(await rig.coordinator.openPrivateHub() == .opened)
        rig.service.lock(reason: .manual)
        rig.fixture.enclave.forcedUnwrapOutcome = .keyAbsent

        #expect(await rig.coordinator.openPrivateHub() == .unrecoverable)
    }
}
