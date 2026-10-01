import CryptoKit
import FernletFoundation
import FernletLock
import FernletLockUI
import Foundation
import PrivateHealthStore
import PrivateMemoryStore
import PrivateStoreCore

// MARK: - Seams

/// The lock-service operations the no-passcode open needs — `FernletLockService` in production, a
/// double in no test (the tests drive a real service on isolated keychain services), but named as a
/// seam so the coordinator states exactly what it may do to key custody: open, ask, and purge the
/// buffer file it was shown as unopenable. It never deletes a key and never mints one itself.
@MainActor
protocol PrivateHubKeyCustody: AnyObject {
    /// See `FernletLockService.openWithoutPasscode(for:allowingMint:)`.
    func openWithoutPasscode(for scope: FernletLockScope, allowingMint: Bool) throws
    /// See `FernletLockService.checkFreshKeyMintIsSafe(forPasscodeSetup:)`.
    func checkFreshKeyMintIsSafe(forPasscodeSetup: Bool) throws -> FernletLockService.FreshKeyMintVerdict
    /// See `FernletLockService.pendingNarrativesAreUnopenable()`.
    func pendingNarrativesAreUnopenable() throws -> Bool
    /// See `FernletLockService.purgePendingNarratives()`.
    func purgePendingNarratives() throws
}

extension FernletLockService: PrivateHubKeyCustody {}

/// The sealed rows and backup bookkeeping the "entries this iPhone can't open" check reads, and —
/// on the user's Remove tap only — deletes and clears. Every read here is keyless or under a DEVICE
/// key (never the hub key, which does not exist yet when this runs).
@MainActor
protocol PriorPrivateEntryStore: AnyObject {
    /// Keyless count of sealed cycle rows — cycle records and the legacy narratives they replace.
    /// Each was sealed under a hub key.
    func cycleEntryCount() throws -> Int
    /// Keyless count of sealed intimacy rows. Each was sealed under a hub key.
    func intimacyEntryCount() throws -> Int
    /// Journal rows classified under this iPhone's journal device key (absent key ⇒ every row dead).
    func journalOpenability() throws -> SealedRowOpenability
    /// Worry Box rows classified under this iPhone's worry device key (absent key ⇒ every row dead).
    func worryOpenability() throws -> SealedRowOpenability
    /// Whether any of the three sealed-backup divergence latches is set.
    func hasBackupBookkeeping() -> Bool
    /// Keyless delete of every sealed cycle row (records and legacy narratives).
    func removeCycleEntries() throws
    /// Keyless delete of every sealed intimacy row.
    func removeIntimacyEntries() throws
    /// Keyless delete of these journal rows.
    func removeJournalEntries(ids: [UUID]) throws
    /// Keyless delete of these Worry Box rows.
    func removeWorryEntries(ids: [UUID]) throws
    /// Clears the three divergence latches (they spoke for a key that no longer exists).
    func clearBackupBookkeeping()
    /// Whether a Sealed backup would really be restored once the unopenable rows are gone — the card
    /// says so only then (review C-U2-R3).
    ///
    /// - Parameter journalKeepsOpenableRows: Whether journal rows that DO open stay behind the removal
    ///   (they are folded under the new key, so the journal store is not empty and its empty-store-only
    ///   restore refuses).
    func sealedBackupRestoresAfterRemoval(journalKeepsOpenableRows: Bool) -> Bool
    /// The derived period-tracking visibility. A hidden kind is never NAMED on the card: its rows are
    /// counted into the neutral "other private entries" line (review C-U2-R5).
    func isPeriodTrackingVisible() -> Bool
    /// The derived intimacy-tracking visibility (18+ gate included), with the same effect.
    func isIntimacyTrackingVisible() -> Bool
}

// MARK: - Coordinator

/// Opens the Private tab without a passcode — the app's side of the one-button gate (period-data
/// design 2026-09-30, §4.9, §10.1–§10.2).
///
/// **Before any fresh key is minted, it looks at what is already on this iPhone.** A tap first asks
/// the lock service to open the device-custody key (`allowingMint: false`). Only when that key is
/// definitively ABSENT does this run the check, in order:
/// 1. The lock service's read-only proof that no copy of an earlier key survives anywhere
///    (`checkFreshKeyMintIsSafe`). A throw means a key may still be reachable, and a custodian
///    recovery means the recovery device holds it — either way nothing may be called unopenable, so
///    the answer is "try again" and the gate never shows the card.
/// 2. Keyless counts of the hub-key-only entities (cycle, intimacy): with no hub key anywhere, every
///    such row is provably unopenable. Journal and Worry Box rows are tried under their own device
///    keys — a row that opens is ALIVE (it is folded under the new key once Private opens), a row
///    that refuses is dead, and a row that could not be decided stops the check ("try again"). The
///    pending buffer is dead when its key is gone over a non-empty file. A HIDDEN kind (period or
///    intimacy, by the same derived visibility the rest of the app gates on) is never named on the
///    card — its rows are shown only as "other private entries" — yet they are still removed on the
///    Remove tap, or the fresh key would be minted over them.
/// 3. No dead rows → mint and open (clearing any backup bookkeeping first, audited by kind).
///    Dead rows → nothing is minted and nothing is deleted: the gate shows the counts.
///
/// **Nothing is removed without the Remove tap, and the tap removes exactly what it was shown.**
/// ``removeUnopenableEntriesAndOpen(named:)`` re-runs the whole check and compares the fresh counts
/// with the ones on the card; any difference deletes nothing and re-shows the card. Only then are the
/// dead rows deleted (keylessly), the latches cleared — after the deletes, which set them — and the
/// fresh key minted. The latches are cleared because they speak for a key that no longer exists:
/// the targeted restores at the next hub settle are then free to bring a Sealed backup back, re-sealed
/// under the new key (the awaits-owner hold still stops that after an app-lock reset).
///
/// Stateless between calls (the card carries its own counts back), so a view may construct it.
@MainActor
final class PrivateHubOpenCoordinator: FernletPrivateHubOpening {
    /// Open, ask, purge.
    private let custody: any PrivateHubKeyCustody
    /// The sealed rows and bookkeeping.
    private let entries: any PriorPrivateEntryStore

    /// What the check found: the counts the card would show, the rows behind them, and whether any
    /// bookkeeping was set.
    ///
    /// `counts` is what the user SEES — a hidden kind's rows are folded into its `otherEntries` line,
    /// never named — while the raw cycle and intimacy counts decide what Remove deletes: the hidden
    /// kinds' dead rows go too, or the fresh key would be minted over them.
    private struct Survey {
        var counts: FernletUnopenableEntryCounts
        var cycleRows: Int
        var intimacyRows: Int
        var deadJournalIDs: [UUID]
        var deadWorryIDs: [UUID]
        var hasBookkeeping: Bool
    }

    /// Why a survey could not finish: a row or key that would not answer, or a key that may survive.
    private enum SurveyRefusal: Error {
        case undecided
    }

    /// Creates the coordinator.
    ///
    /// - Parameters:
    ///   - custody: The lock service.
    ///   - entries: The sealed rows and bookkeeping.
    init(custody: any PrivateHubKeyCustody, entries: any PriorPrivateEntryStore) {
        self.custody = custody
        self.entries = entries
    }

    /// Whether the tap screen's line may name cycle entries: only while period tracking is visible,
    /// so a hidden feature is never named on the screen shown to whoever holds the phone.
    var tapGateNamesCycleEntries: Bool { entries.isPeriodTrackingVisible() }

    /// The Unlock button.
    func openPrivateHub() async -> FernletTapOpenOutcome {
        do {
            try custody.openWithoutPasscode(for: .privateHub, allowingMint: false)
            return .opened
        } catch FernletLockError.deviceKeyAbsent {
            return openWithFreshKey(removing: nil)
        } catch {
            return Self.outcome(for: error)
        }
    }

    /// The card's "Remove them and open Private".
    func removeUnopenableEntriesAndOpen(named counts: FernletUnopenableEntryCounts) async -> FernletTapOpenOutcome {
        openWithFreshKey(removing: counts)
    }

    /// The passcode setup's check before it mints a FRESH key over sealed entries (design §4.4 step
    /// 2): the same survey the tap runs, against the setup's own proof
    /// (`checkFreshKeyMintIsSafe(forPasscodeSetup: true)`). Nothing unopenable → the latches that
    /// spoke for a lost key are cleared (the fresh key is about to exist) and the setup may mint;
    /// unopenable rows → the setup sends the user to the Private tab's card; deletes and mints nothing.
    func reviewPriorEntriesBeforeFreshKey() async -> FernletPriorEntriesReview {
        let survey: Survey
        do {
            survey = try surveyPriorEntries(forPasscodeSetup: true)
        } catch {
            FernletAuditLog.log("lock.priorEntries.undecided", context: ["site": "passcodeSetup"])
            return .tryAgain
        }
        guard survey.counts.isEmpty else { return .unopenableEntries(survey.counts) }
        if survey.hasBookkeeping {
            entries.clearBackupBookkeeping()
            FernletAuditLog.log("lock.newKeyOverPriorData", context: Self.auditCounts(survey.counts))
        }
        return .nothingUnopenable
    }

    /// Steps 1–3 of the check, then the mint. `shown` is the card's counts when this is the Remove
    /// tap, nil for a plain Unlock.
    private func openWithFreshKey(removing shown: FernletUnopenableEntryCounts?) -> FernletTapOpenOutcome {
        let survey: Survey
        do {
            survey = try surveyPriorEntries(forPasscodeSetup: false)
        } catch {
            FernletAuditLog.log("lock.priorEntries.undecided", context: ["site": "tap"])
            return .tryAgain
        }
        if !survey.counts.isEmpty {
            // The card, or a Remove tap whose card no longer matches what is here: delete nothing.
            guard let shown, shown == survey.counts else { return .unopenableEntries(survey.counts) }
            do {
                try removeDeadEntries(survey)
            } catch {
                FernletAuditLog.log("lock.priorEntries.removeFailed", context: ["error": "\(type(of: error))"])
                return .tryAgain
            }
        }
        if survey.hasBookkeeping || !survey.counts.isEmpty {
            entries.clearBackupBookkeeping()
            FernletAuditLog.log("lock.newKeyOverPriorData", context: Self.auditCounts(survey.counts))
        }
        do {
            try custody.openWithoutPasscode(for: .privateHub, allowingMint: true)
            return .opened
        } catch {
            return Self.outcome(for: error)
        }
    }

    /// Runs the read-only half of the check. Throws ``SurveyRefusal`` whenever any answer is not
    /// definite — never a partial count.
    ///
    /// - Parameter forPasscodeSetup: Which fresh-key route's proof to run (the tap's, or a setup's).
    private func surveyPriorEntries(forPasscodeSetup: Bool) throws -> Survey {
        guard try custody.checkFreshKeyMintIsSafe(forPasscodeSetup: forPasscodeSetup) == .noEarlierKeySurvives else {
            throw SurveyRefusal.undecided
        }
        let journal = try entries.journalOpenability()
        let worry = try entries.worryOpenability()
        guard journal.transientCount == 0, worry.transientCount == 0 else { throw SurveyRefusal.undecided }
        let cycleRows = try entries.cycleEntryCount()
        let intimacyRows = try entries.intimacyEntryCount()
        var counts = Self.shownCounts(
            cycleRows: cycleRows,
            intimacyRows: intimacyRows,
            periodVisible: entries.isPeriodTrackingVisible(),
            intimacyVisible: entries.isIntimacyTrackingVisible()
        )
        counts.journalEntries = journal.deadIDs.count
        counts.worryEntries = worry.deadIDs.count
        counts.hasUnopenableHeldEntries = try custody.pendingNarrativesAreUnopenable()
        if !counts.isEmpty {
            counts.sealedBackupRestoresAfterRemoval = entries.sealedBackupRestoresAfterRemoval(
                journalKeepsOpenableRows: !journal.openableIDs.isEmpty
            )
        }
        return Survey(
            counts: counts,
            cycleRows: cycleRows,
            intimacyRows: intimacyRows,
            deadJournalIDs: journal.deadIDs,
            deadWorryIDs: worry.deadIDs,
            hasBookkeeping: entries.hasBackupBookkeeping()
        )
    }

    /// The cycle and intimacy counts as the card may show them: a visible kind by name, a hidden kind
    /// (period hidden by the user or by the sex-derived default, intimacy hidden or under the 18+
    /// gate) only inside the neutral "other private entries" count — the card is shown to whoever
    /// holds the phone, and a hidden sensitive feature is never named (review C-U2-R5).
    ///
    /// - Parameters:
    ///   - cycleRows: Keyless count of sealed cycle rows.
    ///   - intimacyRows: Keyless count of sealed intimacy rows.
    ///   - periodVisible: The derived period-tracking visibility.
    ///   - intimacyVisible: The derived intimacy-tracking visibility.
    static func shownCounts(
        cycleRows: Int,
        intimacyRows: Int,
        periodVisible: Bool,
        intimacyVisible: Bool
    ) -> FernletUnopenableEntryCounts {
        FernletUnopenableEntryCounts(
            cycleEntries: periodVisible ? cycleRows : 0,
            intimacyEntries: intimacyVisible ? intimacyRows : 0,
            otherEntries: (periodVisible ? 0 : cycleRows) + (intimacyVisible ? 0 : intimacyRows)
        )
    }

    /// Deletes exactly the survey's dead rows, keylessly, and the dead buffer file. Audited by kind
    /// and count only.
    private func removeDeadEntries(_ survey: Survey) throws {
        // The RAW counts, not the shown ones: a hidden kind's dead rows are removed too (they were on
        // the card as "other private entries"), or the fresh key would be minted over them.
        if survey.cycleRows > 0 { try entries.removeCycleEntries() }
        if survey.intimacyRows > 0 { try entries.removeIntimacyEntries() }
        try Self.inBatches(survey.deadJournalIDs) { try entries.removeJournalEntries(ids: $0) }
        try Self.inBatches(survey.deadWorryIDs) { try entries.removeWorryEntries(ids: $0) }
        if survey.counts.hasUnopenableHeldEntries { try custody.purgePendingNarratives() }
        FernletAuditLog.log("lock.unopenableEntriesRemoved", context: Self.auditCounts(survey.counts))
    }

    /// Hands `ids` to `delete` in slices no longer than one delete call accepts. Bounded (R2): the
    /// loop runs `ids.count / maxIDsPerDelete` rounded up times.
    private static func inBatches(_ ids: [UUID], _ delete: ([UUID]) throws -> Void) throws {
        let size = JournalNarrativeRepository.maxIDsPerDelete
        for start in stride(from: 0, to: ids.count, by: size) {
            try delete(Array(ids[start..<min(start + size, ids.count)]))
        }
    }

    /// The gate's answer for a lock-service error: a lost enclave key is terminal, everything else
    /// is a retry (and never names a reset).
    private static func outcome(for error: any Error) -> FernletTapOpenOutcome {
        if case FernletLockError.contentKeyUnrecoverable = error { return .unrecoverable }
        FernletAuditLog.log("lock.tapOpen.refused", context: ["error": "\(type(of: error))"])
        return .tryAgain
    }

    /// Counts by kind for an audit line — numbers only, never an id or a date.
    private static func auditCounts(_ counts: FernletUnopenableEntryCounts) -> [String: String] {
        [
            "cycle": "\(counts.cycleEntries)",
            "intimacy": "\(counts.intimacyEntries)",
            "journal": "\(counts.journalEntries)",
            "worry": "\(counts.worryEntries)",
            "other": "\(counts.otherEntries)",
            "held": counts.hasUnopenableHeldEntries ? "1" : "0"
        ]
    }
}

// MARK: - Production entry store

/// The production ``PriorPrivateEntryStore``: the on-device sealed store's legacy cycle, journal and
/// Worry Box repositories, the gated cycle-record and intimacy funnels (the app target never
/// constructs a raw `CycleRecordRepository` or `IntimacyLogRepository` — only their keyless count
/// and delete are used here), and the journal/worry device keys read WITHOUT minting.
@MainActor
final class SealedPriorEntryStore: PriorPrivateEntryStore {
    private let cycleRepository: MenstrualNarrativeRepository
    /// The sealed cycle records (period-data design 2026-09-30, §5.2): K-sealed like the legacy
    /// narratives, so with no hub key anywhere every row is unopenable and counts on the card.
    private let cycleRecords: CycleRecordStore
    private let journalRepository: JournalNarrativeRepository
    private let worryRepository: WorryNarrativeRepository
    private let intimacyStore: IntimacyLogStore
    /// The keychain service holding the journal and worry device keys.
    private let deviceKeyService: String
    /// Whether a Sealed backup will really be restored after a removal (the app's backup switches, the
    /// owner hold, and whether the journal store will be empty), given whether openable journal rows
    /// stay behind.
    private let restoresAfterRemoval: (_ journalKeepsOpenableRows: Bool) -> Bool
    /// The derived period-tracking visibility; fail-closed (hidden) unless the app wires it.
    private let periodVisible: () -> Bool
    /// The derived intimacy-tracking visibility; fail-closed (hidden) unless the app wires it.
    private let intimacyVisible: () -> Bool

    /// Creates the store.
    ///
    /// - Parameters:
    ///   - controller: The sealed store; `nil` is the shared on-device one.
    ///   - latchDefaults: Suite holding the three divergence latches.
    ///   - intimacyStore: The app's intimacy funnel on the same store.
    ///   - deviceKeyService: The journal/worry device-key service.
    ///   - periodVisible: The derived period-tracking visibility (default: hidden, fail-closed).
    ///   - intimacyVisible: The derived intimacy-tracking visibility (default: hidden, fail-closed).
    ///   - restoresAfterRemoval: Whether a Sealed backup comes back after a removal, given whether
    ///     openable journal rows stay behind.
    init(
        controller: PrivatePersistenceController? = nil,
        latchDefaults: UserDefaults = .standard,
        intimacyStore: IntimacyLogStore,
        deviceKeyService: String = KeychainItem.journalService,
        periodVisible: @escaping () -> Bool = { false },
        intimacyVisible: @escaping () -> Bool = { false },
        restoresAfterRemoval: @escaping (_ journalKeepsOpenableRows: Bool) -> Bool
    ) {
        cycleRepository = MenstrualNarrativeRepository(controller: controller, defaults: latchDefaults)
        cycleRecords = CycleRecordStore(controller: controller)
        journalRepository = JournalNarrativeRepository(controller: controller, defaults: latchDefaults)
        worryRepository = WorryNarrativeRepository(controller: controller)
        self.intimacyStore = intimacyStore
        self.deviceKeyService = deviceKeyService
        self.periodVisible = periodVisible
        self.intimacyVisible = intimacyVisible
        self.restoresAfterRemoval = restoresAfterRemoval
    }

    func cycleEntryCount() throws -> Int { try cycleRepository.narrativeCount() + cycleRecords.recordCount() }
    func intimacyEntryCount() throws -> Int { try intimacyStore.backupLogCount() }
    func journalOpenability() throws -> SealedRowOpenability {
        try journalRepository.openability(under: deviceKey(.deviceJournalKey))
    }
    func worryOpenability() throws -> SealedRowOpenability {
        try worryRepository.openability(under: deviceKey(.deviceWorryKey))
    }
    func hasBackupBookkeeping() -> Bool {
        cycleRepository.hasEverStoredNarrative || journalRepository.hasEverStoredNarrative
            || intimacyStore.hasEverStoredLog
    }
    func removeCycleEntries() throws {
        try cycleRecords.deleteAll()
        try cycleRepository.deleteAll()
    }
    func removeIntimacyEntries() throws { try intimacyStore.deleteAll() }
    func removeJournalEntries(ids: [UUID]) throws { try journalRepository.delete(ids: ids) }
    func removeWorryEntries(ids: [UUID]) throws { try worryRepository.delete(ids: ids) }
    func clearBackupBookkeeping() {
        cycleRepository.clearDivergenceLatch()
        journalRepository.clearDivergenceLatch()
        intimacyStore.clearDivergenceLatch()
    }
    func sealedBackupRestoresAfterRemoval(journalKeepsOpenableRows: Bool) -> Bool {
        restoresAfterRemoval(journalKeepsOpenableRows)
    }
    func isPeriodTrackingVisible() -> Bool { periodVisible() }
    func isIntimacyTrackingVisible() -> Bool { intimacyVisible() }

    /// A device key read WITHOUT minting: found → the key; absent → nil (every row is dead under a key
    /// that does not exist); unreadable → a throw, so nothing is called dead on a read that did not
    /// answer.
    private func deviceKey(_ account: KeychainItem.Account) throws -> SymmetricKey? {
        switch KeychainItem.loadDistinguishingAbsence(account: account.rawValue, service: deviceKeyService) {
        case .found(let data):
            return SymmetricKey(data: data)
        case .absent:
            return nil
        case .unreadable(let status):
            throw FernletLockError.keychainFailure(operation: "read device key", status: status)
        }
    }
}
