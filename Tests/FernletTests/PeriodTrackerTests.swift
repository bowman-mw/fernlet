import FernletFoundation
import CoreData
import CryptoKit
import Foundation
import HealthKit
import Testing
import FernletDomainModel
import PrivateStoreCore
import PrivateHealthStore
import HealthKitGateway
import FernletLock
@testable import Fernlet

/// The period store after the cutover (period-data design 2026-09-30, §6.3): Fernlet's sealed record
/// is the source of truth, a save seals FIRST and mirrors to Apple Health second (only while cycle
/// sharing is on), an edit updates in place, a delete removes Fernlet's rows before Health's copies,
/// and the visibility gate keeps the store inert while hidden. Driven over `CycleStoreHarness` (one
/// in-memory sealed stack, the mock Health seam, the mock lock seam).
@MainActor
struct PeriodTrackerTests {
    // MARK: - The legacy narrative repository (still the import's source)

    @Test func narrativeRepositoryRoundTripsWithFixedKey() throws {
        let repository = makeRepository()
        let key = SymmetricKey(data: Data(repeating: 7, count: 32))
        let narrative = MenstrualNarrative(
            hkExternalUUID: "hk-1",
            dateKey: "2026-05-20",
            note: "cramps after lunch",
            symptomFlags: [.cramps, .fatigue],
            customSymptomScales: ["cramps": 6]
        )

        try repository.insert(narrative, contentKey: key)
        let read = try #require(try repository.narrative(forHKUUID: "hk-1", contentKey: key))

        #expect(read.note == "cramps after lunch")
        #expect(read.symptomFlags.sorted() == [.cramps, .fatigue])
        #expect(read.customSymptomScales["cramps"] == 6)
    }

    @Test func narrativeRepositoryRejectsWrongKey() throws {
        let repository = makeRepository()
        let key = SymmetricKey(data: Data(repeating: 1, count: 32))
        let wrongKey = SymmetricKey(data: Data(repeating: 2, count: 32))
        try repository.insert(MenstrualNarrative(hkExternalUUID: "hk-2", dateKey: "2026-05-20", note: "private"), contentKey: key)

        #expect(throws: Error.self) {
            _ = try repository.narrative(forHKUUID: "hk-2", contentKey: wrongKey)
        }
    }

    // MARK: - Save: seal first, mirror second (I1, I2, I3)

    /// I2: with sharing OFF and the Private tab open, a log with every field set is SEALED — every
    /// field kept in Fernlet — and nothing reaches Apple Health (I1).
    @Test func withSharingOffAFullLogIsSealedAndNothingReachesHealth() async throws {
        let harness = CycleStoreHarness()

        let outcome = try await harness.store.logEvent(Self.fullEvent(), unlockedContentKey: harness.key)

        #expect(outcome == PeriodLogOutcome(storage: .sealed, healthCopy: .notShared))
        #expect(harness.health.count("writeMirror") == 0, "sharing is off: nothing may reach Health")
        let stored = try #require(try harness.storedRecords().first)
        #expect(stored.clinical?.flowLevel == .medium)
        #expect(stored.clinical?.isCycleStart == true)
        #expect(stored.clinical?.basalBodyTemperature == 36.6)
        #expect(stored.clinical?.temperatureUnit == .celsius)
        #expect(stored.clinical?.cervicalMucusQuality == .eggWhite)
        #expect(stored.clinical?.ovulationTestResult == .positive)
        #expect(stored.clinical?.hasIntermenstrualBleeding == true)
        #expect(stored.narrative?.note == "cramps after lunch")
        #expect(stored.narrative?.symptomFlags == [.cramps])
    }

    /// I2: with NO passcode, sharing off and the Private tab closed, the same full log is HELD in the
    /// pending buffer as a whole record — never refused, never dropped — and nothing reaches Health.
    @Test func withNoPasscodeAndTheTabClosedAFullLogIsHeldNotRefused() async throws {
        let harness = CycleStoreHarness(lockState: .notConfigured)

        let outcome = try await harness.store.logEvent(Self.fullEvent(), unlockedContentKey: nil)

        #expect(outcome == PeriodLogOutcome(storage: .pendingUntilPrivateOpens, healthCopy: .notShared))
        #expect(harness.health.count("writeMirror") == 0)
        let payload = try #require(harness.lock.pending.first)
        let held = try CycleRecord(frozenJSON: try #require(payload.cycleRecordJSON))
        #expect(held.clinical?.flowLevel == .medium && held.narrative?.note == "cramps after lunch")
        #expect(payload.hkExternalUUID == held.id.uuidString)
        #expect(try harness.records.recordCount() == 0, "no key was live, so nothing is sealed yet")
    }

    /// I1 + I3: with sharing ON the mirror is written — AFTER the record is sealed, never before.
    @Test func withSharingOnTheMirrorIsWrittenAfterTheSeal() async throws {
        let harness = CycleStoreHarness()
        harness.health.mirrorEnabled = true
        var sealedWhenHealthWasTouched: Int?
        let records = harness.records
        harness.health.onHealthWrite = { _ in sealedWhenHealthWasTouched = try? records.recordCount() }

        let outcome = try await harness.store.logEvent(Self.fullEvent(), unlockedContentKey: harness.key)

        #expect(outcome.healthCopy == .written)
        #expect(sealedWhenHealthWasTouched == 1, "the record is sealed before Health is touched")
        #expect(harness.health.writtenMirrors.map(\.id) == (try harness.storedRecords()).map(\.id))
    }

    /// A refused mirror keeps the entry and says what happened; "sharing is off" is not a failure.
    @Test func aMirrorFailureKeepsTheEntry() async throws {
        let harness = CycleStoreHarness()
        harness.health.mirrorEnabled = true
        harness.health.writeMirrorError = HKError(.errorAuthorizationDenied)

        let denied = try await harness.store.logEvent(UserLoggedCycleEvent(flowLevel: .light), unlockedContentKey: harness.key)
        #expect(denied == PeriodLogOutcome(storage: .sealed, healthCopy: .failed(.healthDenied)))

        harness.health.writeMirrorError = SharingOffForTest()
        let off = try await harness.store.logEvent(UserLoggedCycleEvent(flowLevel: .heavy), unlockedContentKey: harness.key)
        #expect(off.healthCopy == .notShared)
        #expect(try harness.records.recordCount() == 2, "both entries are kept whatever Health said")
    }

    /// I3: a buffer that refuses throws with NO Health call — nothing is mirrored for an entry Fernlet
    /// did not keep.
    @Test func aBufferFailureMakesNoHealthCall() async throws {
        let harness = CycleStoreHarness(lockState: .locked(cooldownDeadline: nil))
        harness.health.mirrorEnabled = true
        harness.lock.bufferError = PendingNarrativeBufferError.full

        await #expect(throws: PendingNarrativeBufferError.full) {
            _ = try await harness.store.logEvent(UserLoggedCycleEvent(flowLevel: .medium), unlockedContentKey: nil)
        }
        #expect(harness.health.calls.isEmpty, "nothing was kept, so nothing may reach Health")
    }

    /// I3: an entry with nothing in it is refused before anything — no seal, no buffer, no Health.
    @Test func anEmptyEntryIsRefusedBeforeAnything() async throws {
        let harness = CycleStoreHarness()
        harness.health.mirrorEnabled = true

        await #expect(throws: CycleRecordRepositoryError.self) {
            _ = try await harness.store.logEvent(UserLoggedCycleEvent(), unlockedContentKey: harness.key)
        }
        #expect(harness.health.calls.isEmpty)
        #expect(try harness.records.recordCount() == 0)
    }

    /// Notes and symptoms alone are never copied to Health, sharing on or not.
    @Test func aNotesOnlyEntryIsNeverMirrored() async throws {
        let harness = CycleStoreHarness()
        harness.health.mirrorEnabled = true

        let outcome = try await harness.store.logEvent(UserLoggedCycleEvent(note: "tired", symptoms: [.fatigue]), unlockedContentKey: harness.key)

        #expect(outcome == PeriodLogOutcome(storage: .sealed, healthCopy: .notShared))
        #expect(harness.health.calls.isEmpty)
    }

    /// The store with no lock seam wired refuses a closed-tab save instead of claiming a buffer.
    @Test func anUnwiredLockSeamRefusesRatherThanClaimingABuffer() async throws {
        let store = PeriodTrackerStore(
            healthService: MockCycleHealthService(),
            narrativeRepository: makeRepository(),
            recordStore: CycleRecordStore(controller: PrivatePersistenceController(inMemory: true))
        )
        store.attachVisibilityGate { true }

        await #expect(throws: FernletLockError.self) {
            _ = try await store.logEvent(UserLoggedCycleEvent(note: "nowhere to go"), unlockedContentKey: nil)
        }
    }

    // MARK: - The visibility gate (I10)

    @Test func hiddenLogEventIsRefusedBeforeAnything() async throws {
        let harness = CycleStoreHarness(visible: false)
        harness.health.mirrorEnabled = true

        await #expect(throws: PeriodTrackingHiddenError.self) {
            _ = try await harness.store.logEvent(UserLoggedCycleEvent(flowLevel: .medium), unlockedContentKey: harness.key)
        }
        #expect(harness.health.calls.isEmpty)
        #expect(harness.lock.pending.isEmpty)
        #expect(try harness.records.recordCount() == 0)
    }

    /// While hidden a load performs NO Health read and NO decrypt, and scrubs.
    @Test func hiddenLoadPerformsNoHealthReadAndNoDecrypt() async throws {
        let harness = CycleStoreHarness(visible: false)
        try harness.records.insert(PeriodTestSupport.record(on: Date(), flow: .heavy), contentKey: harness.key)

        await harness.store.loadEntries(unlockedContentKey: harness.key)

        #expect(harness.health.count("load") == 0)
        #expect(harness.store.entries.isEmpty)
        #expect(harness.store.prediction == nil)
    }

    /// The pending buffer unseals under a DEVICE key, so the drain must refuse explicitly while hidden,
    /// leaving the buffer intact (hiding is not deleting).
    @Test func hiddenDrainIsRefusedAndLeavesBufferIntact() async throws {
        let harness = CycleStoreHarness(visible: false)
        harness.lock.pending = [try Self.v2Payload(PeriodTestSupport.record(on: Date(), flow: .light))]

        try await harness.store.drainPendingBuffer(contentKey: harness.key)

        #expect(harness.lock.pending.count == 1)
        #expect(try harness.records.recordCount() == 0)
    }

    /// An edit racing a hide is refused before anything changes.
    @Test func hiddenEditIsRefusedBeforeAnythingChanges() async throws {
        var visible = true
        let harness = CycleStoreHarness()
        harness.store.attachVisibilityGate { visible }
        let record = PeriodTestSupport.record(on: Date(), flow: .medium)
        try harness.records.insert(record, contentKey: harness.key)

        visible = false
        await #expect(throws: PeriodTrackingHiddenError.self) {
            _ = try await harness.store.editRecord(record.id, with: UserLoggedCycleEvent(flowLevel: .heavy), unlockedContentKey: harness.key)
        }
        #expect(try harness.storedRecords().first?.clinical?.flowLevel == .medium)
        #expect(harness.health.calls.isEmpty)
    }

    /// I10/I14: deleting works hidden and with no key — hiding must never block "delete my data".
    @Test func deleteDayWorksWhileHidden() async throws {
        let harness = CycleStoreHarness(visible: false)
        let record = PeriodTestSupport.record(on: Date(), flow: .medium)
        let funnel = harness.records
        try funnel.insert(record, contentKey: harness.key)
        let entry = CycleDayEntry(date: Date(), dateKey: record.dayKey, records: [record])

        let outcome = try await harness.store.deleteDay(entry)

        #expect(outcome.removedRecordCount == 1)
        #expect(try funnel.recordCount() == 0)
    }

    // MARK: - Load (§6.3)

    /// G1: a load with no key scrubs — the records are the calendar, and they need the key.
    @Test func aKeylessLoadScrubsAndReadsNothing() async throws {
        let harness = CycleStoreHarness()
        try harness.records.insert(PeriodTestSupport.record(on: Date(), flow: .medium), contentKey: harness.key)

        await harness.store.loadEntries(unlockedContentKey: nil)

        #expect(harness.store.entries.isEmpty)
        #expect(harness.health.calls.isEmpty)
    }

    /// With the cycle capability off, the calendar is Fernlet-only and NO Health read happens.
    @Test func withHealthReadOffNoHealthCallIsMade() async throws {
        let harness = CycleStoreHarness()
        harness.health.readEnabled = false
        try harness.records.insert(PeriodTestSupport.record(on: Date(), flow: .medium), contentKey: harness.key)

        await harness.store.loadEntries(unlockedContentKey: harness.key)

        #expect(harness.health.count("load") == 0)
        #expect(Self.today(in: harness.store)?.flowLevel == .medium, "the record alone puts the day on the calendar")
    }

    /// I12 dedupe: a Fernlet mirror whose record's clinical block is KNOWN is hidden (the record is
    /// authoritative); a Fernlet copy with no record here stays, as a Health-only Fernlet day; other
    /// apps' samples stay, read-only, and are never sealed.
    @Test func mirrorsOfKnownRecordsAreHiddenAndEverythingElseStaysReadOnly() async throws {
        let harness = CycleStoreHarness()
        let today = Date()
        let record = PeriodTestSupport.record(on: today, flow: .medium)
        try harness.records.insert(record, contentKey: harness.key)
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today) ?? today
        let otherPhone = PeriodTestSupport.record(on: yesterday, flow: .heavy)
        let twoDaysAgo = Calendar.current.date(byAdding: .day, value: -2, to: today) ?? today
        harness.health.loadedSamples = try HealthKitService.periodSamples(for: record)
            + HealthKitService.periodSamples(for: otherPhone)
            + CycleStoreHarness.otherAppSamples(flow: .light, on: twoDaysAgo)

        await harness.store.loadEntries(unlockedContentKey: harness.key)

        let todays = try #require(Self.entry(on: today, in: harness.store))
        #expect(todays.records.map(\.id) == [record.id])
        #expect(todays.fernletHealthSamples.isEmpty, "the record's own mirror is hidden")
        let healthOnly = try #require(Self.entry(on: yesterday, in: harness.store))
        #expect(healthOnly.isHealthOnlyFernletDay, "a Fernlet copy with no record here stays, read-only")
        let otherApp = try #require(Self.entry(on: twoDaysAgo, in: harness.store))
        #expect(otherApp.records.isEmpty && otherApp.otherHealthSamples.count == 1)
        #expect(otherApp.flowLevel == .light, "other apps' data counts toward the calendar")
        #expect(try harness.records.recordCount() == 1, "Health samples are never sealed")
    }

    /// Fill-on-read (§6.3 step 6): a record whose clinical block is UNKNOWN (a legacy narrative-only
    /// one) is completed from its own Fernlet samples and written back; its samples are then hidden.
    @Test func fillOnReadCompletesAnUnknownClinicalBlock() async throws {
        let harness = CycleStoreHarness()
        let samplesSource = PeriodTestSupport.record(on: Date(), flow: .heavy)
        var narrativeOnly = samplesSource
        narrativeOnly.clinical = nil
        narrativeOnly.narrative = CycleNarrativeFields(note: "from before", symptomFlags: [], customSymptomScales: [:], updatedAt: Date())
        try harness.records.insert(narrativeOnly, contentKey: harness.key)
        harness.health.loadedSamples = try PeriodTestSupport.legacySamples(for: samplesSource)

        await harness.store.loadEntries(unlockedContentKey: harness.key)

        let stored = try #require(try harness.storedRecords().first)
        #expect(stored.clinical?.flowLevel == .heavy, "the clinical block was filled and written back")
        #expect(stored.narrative?.note == "from before", "the narrative block is untouched")
        let today = try #require(Self.today(in: harness.store))
        #expect(today.fernletHealthSamples.isEmpty)
        #expect(today.flowLevel == .heavy)
    }

    /// Fill-on-read completes a record; it never CREATES one (a sample with no record stays a sample).
    @Test func fillOnReadNeverCreatesARecord() async throws {
        let harness = CycleStoreHarness()
        harness.health.loadedSamples = try PeriodTestSupport.legacySamples(for: PeriodTestSupport.record(on: Date(), flow: .light))

        await harness.store.loadEntries(unlockedContentKey: harness.key)

        #expect(try harness.records.recordCount() == 0)
        #expect(Self.today(in: harness.store)?.isHealthOnlyFernletDay == true)
    }

    /// The post-await recheck (§8.4): writers stopped while the Health read is in flight (delete-all's
    /// first leg) — the fill-on-read that load would have written never lands.
    @Test func aFillOnReadBegunBeforeTheWritersStopNeverLands() async throws {
        let harness = CycleStoreHarness()
        let samplesSource = PeriodTestSupport.record(on: Date(), flow: .heavy)
        var narrativeOnly = samplesSource
        narrativeOnly.clinical = nil
        narrativeOnly.narrative = CycleNarrativeFields(note: "from before", symptomFlags: [], customSymptomScales: [:], updatedAt: Date())
        try harness.records.insert(narrativeOnly, contentKey: harness.key)
        harness.health.loadedSamples = try PeriodTestSupport.legacySamples(for: samplesSource)
        let store = harness.store
        harness.health.duringLoad = { store.cancelBackgroundWriters() }

        await harness.store.loadEntries(unlockedContentKey: harness.key)

        #expect(try harness.storedRecords().count == 1)
        #expect(try harness.storedRecords().first?.clinical == nil, "the epoch moved: nothing was written")
    }

    /// Hiding while the Health read is in flight abandons the load — no plaintext published.
    @Test func hidingDuringTheHealthAwaitAbandonsTheLoad() async throws {
        var visible = true
        let harness = CycleStoreHarness()
        harness.store.attachVisibilityGate { visible }
        try harness.records.insert(PeriodTestSupport.record(on: Date(), flow: .medium), contentKey: harness.key)
        harness.health.duringLoad = { visible = false }

        await harness.store.loadEntries(unlockedContentKey: harness.key)

        #expect(harness.store.entries.isEmpty)
        #expect(harness.store.prediction == nil)
    }

    /// The same race in the lock dimension: the hub closes (or re-keys) during the Health read.
    @Test func lockingDuringTheHealthAwaitAbandonsTheLoad() async throws {
        let harness = CycleStoreHarness()
        try harness.records.insert(PeriodTestSupport.record(on: Date(), flow: .medium), contentKey: harness.key)
        var liveKey: SymmetricKey? = harness.key
        harness.store.attachLiveContentKeyProvider { liveKey }

        await harness.store.loadEntries(unlockedContentKey: harness.key)
        #expect(!harness.store.entries.isEmpty)

        harness.health.duringLoad = { liveKey = nil }
        await harness.store.loadEntries(unlockedContentKey: harness.key)
        #expect(harness.store.entries.isEmpty)

        harness.health.duringLoad = { liveKey = SymmetricKey(data: Data(repeating: 23, count: 32)) }
        await harness.store.loadEntries(unlockedContentKey: harness.key)
        #expect(harness.store.entries.isEmpty)
    }

    /// Hiding never deletes: hidden, the store reads nothing; un-hidden, the same record is back.
    @Test func hidingKeepsDataAndUnhidingRestoresIt() async throws {
        var visible = false
        let harness = CycleStoreHarness()
        harness.store.attachVisibilityGate { visible }
        let funnel = harness.records
        try funnel.insert(PeriodTestSupport.record(on: Date(), flow: .light, symptoms: [.acne]), contentKey: harness.key)

        await harness.store.loadEntries(unlockedContentKey: harness.key)
        #expect(harness.store.entries.isEmpty)

        visible = true
        await harness.store.loadEntries(unlockedContentKey: harness.key)
        #expect(Self.today(in: harness.store)?.symptomFlags == [.acne])
    }

    /// A logged "None" is a logged none — not menstrual (today's "any flow sample is menstrual" fix).
    @Test func aLoggedNoneFlowIsNotMenstrual() async throws {
        let harness = CycleStoreHarness()
        try harness.records.insert(PeriodTestSupport.record(on: Date(), flow: PeriodFlowLevel.none), contentKey: harness.key)

        await harness.store.loadEntries(unlockedContentKey: harness.key)

        #expect(Self.today(in: harness.store)?.flowLevel == PeriodFlowLevel.none)
        #expect(Self.today(in: harness.store)?.phase == .unknown)
        #expect(harness.store.currentPhase == .unknown)
    }

    @Test func currentPhaseUsesObservedFlowOnly() async throws {
        let harness = CycleStoreHarness()
        try harness.records.insert(PeriodTestSupport.record(on: Date(), flow: .light), contentKey: harness.key)

        await harness.store.loadEntries(unlockedContentKey: harness.key)

        #expect(harness.store.currentPhaseFromObservations() == .menstrual)
    }

    @Test func loadEntriesBuildsPredictionFromRecords() async throws {
        let harness = CycleStoreHarness()
        let calendar = Calendar.current
        let firstStart = try #require(calendar.date(byAdding: .day, value: -140, to: Date()))
        for cycleIndex in 0..<6 {
            let start = try #require(calendar.date(byAdding: .day, value: cycleIndex * 28, to: firstStart))
            try harness.records.insert(PeriodTestSupport.record(on: start, flow: .medium), contentKey: harness.key)
        }

        await harness.store.loadEntries(unlockedContentKey: harness.key)

        let prediction = try #require(harness.store.prediction)
        #expect(prediction.confidence > 0.5)
    }

    // MARK: - Edit (§6.3)

    /// An edit updates the record IN PLACE: same id, the creation time kept, one row.
    @Test func anEditUpdatesTheRecordInPlace() async throws {
        let harness = CycleStoreHarness()
        let original = PeriodTestSupport.record(on: Date(), flow: .light)
        try harness.records.insert(original, contentKey: harness.key)

        let outcome = try await harness.store.editRecord(
            original.id, with: UserLoggedCycleEvent(date: original.loggedAt, flowLevel: .heavy, note: "worse"), unlockedContentKey: harness.key
        )

        #expect(outcome == PeriodLogOutcome(storage: .sealed, healthCopy: .notShared))
        let stored = try harness.storedRecords()
        #expect(stored.count == 1)
        #expect(stored.first?.id == original.id)
        #expect(stored.first?.createdAt == original.createdAt)
        #expect(stored.first?.clinical?.flowLevel == .heavy)
        #expect(stored.first?.narrative?.note == "worse")
    }

    /// Q1: with sharing OFF an edit removes Fernlet's older Health copy, and says so ONLY when a
    /// sample was really deleted; it never writes.
    @Test func withSharingOffAnEditRemovesTheStaleCopyAndSaysSoOnlyWhenOneWent() async throws {
        let harness = CycleStoreHarness()
        let record = PeriodTestSupport.record(on: Date(), flow: .light)
        try harness.records.insert(record, contentKey: harness.key)

        harness.health.deleteMirrorResult = 2
        let removed = try await harness.store.editRecord(record.id, with: UserLoggedCycleEvent(flowLevel: .medium), unlockedContentKey: harness.key)
        #expect(removed.healthCopy == .removedStaleCopy)

        harness.health.deleteMirrorResult = 0
        let nothing = try await harness.store.editRecord(record.id, with: UserLoggedCycleEvent(flowLevel: .heavy), unlockedContentKey: harness.key)
        #expect(nothing.healthCopy == .notShared, "no copy was there: nothing to say")
        #expect(harness.health.count("writeMirror") == 0)
    }

    /// With sharing ON an edit deletes Fernlet's copy and writes the new one, in that order.
    @Test func withSharingOnAnEditRewritesTheMirror() async throws {
        let harness = CycleStoreHarness()
        harness.health.mirrorEnabled = true
        let record = PeriodTestSupport.record(on: Date(), flow: .light)
        try harness.records.insert(record, contentKey: harness.key)

        let outcome = try await harness.store.editRecord(record.id, with: UserLoggedCycleEvent(flowLevel: .medium), unlockedContentKey: harness.key)

        #expect(outcome.healthCopy == .written)
        #expect(harness.health.calls == ["deleteMirror", "writeMirror"])
        #expect(harness.health.writtenMirrors.first?.clinical?.flowLevel == .medium)
    }

    /// A rewrite refused after the delete is reported; the edit itself stays saved.
    @Test func aRewriteRefusedAfterTheDeleteIsReported() async throws {
        let harness = CycleStoreHarness()
        harness.health.mirrorEnabled = true
        harness.health.writeMirrorError = HKError(.errorAuthorizationDenied)
        let record = PeriodTestSupport.record(on: Date(), flow: .light)
        try harness.records.insert(record, contentKey: harness.key)

        let outcome = try await harness.store.editRecord(record.id, with: UserLoggedCycleEvent(flowLevel: .medium), unlockedContentKey: harness.key)

        #expect(outcome.healthCopy == .failed(.healthDenied))
        #expect(try harness.storedRecords().first?.clinical?.flowLevel == .medium)
    }

    /// An edit that leaves an UNKNOWN block empty leaves it unknown: a legacy narrative-only record
    /// edited for its note does not gain a "none" clinical block — and its Fernlet samples in Apple
    /// Health, the block's not-yet-imported source, are never touched, so they can still complete it
    /// (review round 1, C-U4-R1 / L-U4-1: the edit used to delete them, sharing on or off, and say
    /// "removed its older copy"). Health here holds three such samples; neither sharing state may
    /// reach them.
    @Test(arguments: [false, true])
    func anEditKeepsAnUnknownBlockUnknown(sharing: Bool) async throws {
        let harness = CycleStoreHarness()
        harness.health.mirrorEnabled = sharing
        harness.health.deleteMirrorResult = 3
        let narrativeOnly = Self.narrativeOnlyRecord()
        try harness.records.insert(narrativeOnly, contentKey: harness.key)

        let outcome = try await harness.store.editRecord(
            narrativeOnly.id, with: UserLoggedCycleEvent(note: "edited", symptoms: [.cramps]), unlockedContentKey: harness.key
        )

        let stored = try #require(try harness.storedRecords().first)
        #expect(stored.clinical == nil)
        #expect(stored.narrative?.note == "edited")
        #expect(harness.health.count("deleteMirror") == 0, "the record's pre-cutover samples were deleted")
        #expect(harness.health.deletedMirrorIDs.isEmpty)
        #expect(harness.health.calls.isEmpty, "a note-only edit of an unknown block has nothing for Apple Health")
        #expect(outcome.healthCopy == .notShared)
    }

    /// An edit that gives an UNKNOWN block fields still never deletes the record's pre-cutover
    /// samples: with sharing on, the new block is written BESIDE them (the next edit, of a now-known
    /// block, replaces the lot); with sharing off, Apple Health is not touched at all.
    @Test func anEditThatFillsAnUnknownBlockWritesBesideItsLegacySamples() async throws {
        let harness = CycleStoreHarness()
        harness.health.deleteMirrorResult = 3
        let sharingOff = Self.narrativeOnlyRecord()
        let sharingOn = Self.narrativeOnlyRecord()
        try harness.records.insert(sharingOff, contentKey: harness.key)
        try harness.records.insert(sharingOn, contentKey: harness.key)
        let event = UserLoggedCycleEvent(date: sharingOff.loggedAt, flowLevel: .medium, note: "with flow", symptoms: [.cramps])

        let off = try await harness.store.editRecord(sharingOff.id, with: event, unlockedContentKey: harness.key)
        #expect(off.healthCopy == .notShared)
        #expect(harness.health.calls.isEmpty)

        harness.health.mirrorEnabled = true
        let on = try await harness.store.editRecord(sharingOn.id, with: event, unlockedContentKey: harness.key)
        #expect(on.healthCopy == .written)
        #expect(harness.health.calls == ["writeMirror"], "the legacy samples were deleted before the write")
        #expect(try harness.storedRecords().allSatisfy { $0.clinical?.flowLevel == .medium })
    }

    /// An emptied edit of a record whose clinical block is UNKNOWN removes the entry and keeps its
    /// Fernlet samples in Apple Health (review round 1, C-U4-R1): emptying a note must not silently
    /// delete flow history the sheet never showed. The same emptied edit of a KNOWN block still
    /// removes its copy — the control that keeps this from passing vacuously.
    @Test func anEmptiedEditOfAnUnknownBlockKeepsItsHealthSamples() async throws {
        let harness = CycleStoreHarness()
        harness.health.deleteMirrorResult = 3
        let narrativeOnly = Self.narrativeOnlyRecord()
        let logged = PeriodTestSupport.record(on: Date(), flow: .light)
        try harness.records.insert(narrativeOnly, contentKey: harness.key)
        try harness.records.insert(logged, contentKey: harness.key)

        let kept = try await harness.store.deleteRecord(narrativeOnly)
        #expect(kept == PeriodDeleteOutcome(removedRecordCount: 1, healthCopy: .none))
        #expect(harness.health.count("deleteMirror") == 0)

        let removed = try await harness.store.deleteRecord(logged)
        #expect(removed == PeriodDeleteOutcome(removedRecordCount: 1, healthCopy: .removed))
        #expect(harness.health.deletedMirrorIDs == [logged.id])
        #expect(try harness.records.recordCount() == 0)
    }

    /// Review round 1, R2 (b): with sharing ON and a partial grant — flow allowed, temperature denied —
    /// editing a flow-only day still REWRITES the mirror. The refused kind is one the entry never
    /// held, so nothing of Fernlet's was left behind and the write's own share check decides. The edit
    /// used to stop at the refusal, so every edit silently removed the day from Apple Health.
    @Test func withSharingOnARefusedKindTheEntryNeverHeldStillRewritesTheMirror() async throws {
        let harness = CycleStoreHarness()
        harness.health.mirrorEnabled = true
        harness.health.deleteMirrorResult = 1
        harness.health.deleteMirrorRefused = [.basalBodyTemperature]
        let record = PeriodTestSupport.record(on: Date(), flow: .light)
        try harness.records.insert(record, contentKey: harness.key)

        let outcome = try await harness.store.editRecord(record.id, with: UserLoggedCycleEvent(flowLevel: .medium), unlockedContentKey: harness.key)

        #expect(outcome.healthCopy == .written)
        #expect(harness.health.calls == ["deleteMirror", "writeMirror"])
        #expect(harness.health.writtenMirrors.first?.clinical?.flowLevel == .medium)
    }

    /// Review round 1, R2 (a): a user who declined every cycle type on Apple Health's share sheet and
    /// has sharing off is never told Apple Health kept a copy Fernlet never wrote — not on an edit,
    /// not on a delete. HealthKit reports "never granted" exactly as it reports "taken away", and with
    /// sharing off a logged entry was never copied.
    @Test func withSharingOffARefusalOfALoggedEntryIsNeverReported() async throws {
        let harness = CycleStoreHarness()
        harness.health.deleteMirrorRefused = Set(CycleMirrorSampleKind.allCases)
        let record = PeriodTestSupport.record(on: Date(), flow: .light)
        try harness.records.insert(record, contentKey: harness.key)

        let edit = try await harness.store.editRecord(record.id, with: UserLoggedCycleEvent(flowLevel: .heavy), unlockedContentKey: harness.key)
        #expect(edit.healthCopy == .notShared)

        let delete = try await harness.store.deleteDay(CycleDayEntry(date: Date(), dateKey: record.dayKey, records: [record]))
        #expect(delete == PeriodDeleteOutcome(removedRecordCount: 1, healthCopy: .none))
    }

    /// The other side of R2: a refusal IS reported where a Fernlet copy can really be left behind — a
    /// refused kind the entry held, with sharing on (it was copied) or on an entry built from
    /// Fernlet's own Apple Health samples (the copy existed by construction), on an edit and on a
    /// delete alike. A rewrite that succeeded beside a refused older kind still reports it: Apple
    /// Health keeps that kind's stale copy.
    @Test func aRefusalIsReportedWhereAFernletCopyCanRemain() async throws {
        let harness = CycleStoreHarness()
        harness.health.deleteMirrorRefused = [.menstrualFlow]
        var imported = PeriodTestSupport.record(on: Date(), flow: .light)
        imported.origin = .importedLegacy
        try harness.records.insert(imported, contentKey: harness.key)

        let offEdit = try await harness.store.editRecord(imported.id, with: UserLoggedCycleEvent(flowLevel: .medium), unlockedContentKey: harness.key)
        #expect(offEdit.healthCopy == .failed(.healthDenied), "an imported entry's Health copy existed")

        harness.health.mirrorEnabled = true
        let logged = PeriodTestSupport.record(on: Date(), flow: .light)
        try harness.records.insert(logged, contentKey: harness.key)
        let temperatureOnly = UserLoggedCycleEvent(date: logged.loggedAt, basalBodyTemperature: 97.9)
        let onEdit = try await harness.store.editRecord(logged.id, with: temperatureOnly, unlockedContentKey: harness.key)
        #expect(onEdit.healthCopy == .failed(.healthDenied), "the old flow copy stayed beside the new temperature")
        #expect(harness.health.count("writeMirror") == 1, "the rewrite was still attempted")

        let edited = try #require(try harness.storedRecords().first { $0.id == imported.id })
        let delete = try await harness.store.deleteDay(CycleDayEntry(date: Date(), dateKey: edited.dayKey, records: [edited]))
        #expect(delete.healthCopy == .stillInHealth(.healthDenied))
    }

    /// A narrative-only record — the legacy import's (or a v1 drain's) shape: clinical block UNKNOWN.
    private static func narrativeOnlyRecord() -> CycleRecord {
        var record = PeriodTestSupport.record(on: Date(), flow: nil, symptoms: [.cramps])
        record.clinical = nil
        return record
    }

    // MARK: - Delete (§6.3, I32)

    /// I32: Fernlet's rows go FIRST — the store is already empty when Health is first touched.
    @Test func deleteDayRemovesFernletsRowsBeforeHealth() async throws {
        let harness = CycleStoreHarness()
        let record = PeriodTestSupport.record(on: Date(), flow: .medium)
        let funnel = harness.records
        try funnel.insert(record, contentKey: harness.key)
        var rowsWhenHealthWasTouched: Int?
        harness.health.onHealthWrite = { _ in rowsWhenHealthWasTouched = try? funnel.recordCount() }
        harness.health.deleteMirrorResult = 1

        let outcome = try await harness.store.deleteDay(CycleDayEntry(date: Date(), dateKey: record.dayKey, records: [record]))

        #expect(rowsWhenHealthWasTouched == 0)
        #expect(outcome == PeriodDeleteOutcome(removedRecordCount: 1, healthCopy: .removed))
        #expect(harness.health.deletedMirrorIDs == [record.id])
    }

    /// I32: Health failing leaves Fernlet's rows GONE and reports `.stillInHealth` — never a throw
    /// that would make the day undeletable in Fernlet. Both shapes: a delete that failed outright, and
    /// a refused kind the copy held while sharing is on (R2).
    @Test func aHealthFailureLeavesTheRowsGoneAndSaysStillInHealth() async throws {
        let harness = CycleStoreHarness()
        let record = PeriodTestSupport.record(on: Date(), flow: .medium)
        try harness.records.insert(record, contentKey: harness.key)
        harness.health.deleteMirrorError = HKError(.errorDatabaseInaccessible)

        let outcome = try await harness.store.deleteDay(CycleDayEntry(date: Date(), dateKey: record.dayKey, records: [record]))

        #expect(outcome == PeriodDeleteOutcome(removedRecordCount: 1, healthCopy: .stillInHealth(.other)))
        #expect(try harness.records.recordCount() == 0)

        harness.health.deleteMirrorError = nil
        harness.health.deleteMirrorRefused = [.menstrualFlow]
        harness.health.mirrorEnabled = true
        let second = PeriodTestSupport.record(on: Date(), flow: .light)
        try harness.records.insert(second, contentKey: harness.key)
        let refused = try await harness.store.deleteDay(CycleDayEntry(date: Date(), dateKey: second.dayKey, records: [second]))
        #expect(refused == PeriodDeleteOutcome(removedRecordCount: 1, healthCopy: .stillInHealth(.healthDenied)))
    }

    /// R2: a delete refused only for a kind the entry never held reports what really happened —
    /// `.removed` here — never `.stillInHealth`, and every record of the day is still attempted.
    @Test func aDeleteRefusedOnlyForAKindTheEntryNeverHeldIsNotStillInHealth() async throws {
        let harness = CycleStoreHarness()
        harness.health.mirrorEnabled = true
        harness.health.deleteMirrorResult = 1
        harness.health.deleteMirrorRefused = [.basalBodyTemperature, .cervicalMucusQuality]
        let first = PeriodTestSupport.record(on: Date(), flow: .light)
        let second = PeriodTestSupport.record(on: Date(), flow: .medium)
        try harness.records.insert(first, contentKey: harness.key)
        try harness.records.insert(second, contentKey: harness.key)

        let outcome = try await harness.store.deleteDay(CycleDayEntry(date: Date(), dateKey: first.dayKey, records: [first, second]))

        #expect(outcome == PeriodDeleteOutcome(removedRecordCount: 2, healthCopy: .removed))
        #expect(Set(harness.health.deletedMirrorIDs) == [first.id, second.id])
    }

    /// Nothing in Health is `.none`; a day's orphan Fernlet copies (no record here) go too.
    @Test func deleteDayReportsNoneAndRemovesOrphanCopies() async throws {
        let harness = CycleStoreHarness()
        let record = PeriodTestSupport.record(on: Date(), flow: .medium)
        try harness.records.insert(record, contentKey: harness.key)

        let none = try await harness.store.deleteDay(CycleDayEntry(date: Date(), dateKey: record.dayKey, records: [record]))
        #expect(none.healthCopy == PeriodDeleteOutcome.HealthCopy.none)

        let orphans = try HealthKitService.periodSamples(for: PeriodTestSupport.record(on: Date(), flow: .light))
        let orphanDay = CycleDayEntry(date: Date(), dateKey: record.dayKey, fernletHealthSamples: orphans)
        let removed = try await harness.store.deleteDay(orphanDay)
        #expect(removed.healthCopy == .removed)
        #expect(harness.health.deletedAuthoredCount == orphans.count)
    }

    // MARK: - Drain (§6.3)

    @Test func drainSealsWholeRecordsAndPurges() async throws {
        let harness = CycleStoreHarness()
        let record = PeriodTestSupport.record(on: Date(), flow: .medium, symptoms: [.bloating])
        harness.lock.pending = [try Self.v2Payload(record)]

        try await harness.store.drainPendingBuffer(contentKey: harness.key)

        #expect(harness.lock.pending.isEmpty)
        #expect(try harness.storedRecords() == [record])
    }

    /// A v1 payload (a narrative buffered before the cutover) becomes a narrative-only record under
    /// its legacy external id, so it later merges with that entry's legacy samples.
    @Test func drainConvertsAV1NarrativeUnderItsLegacyID() async throws {
        let harness = CycleStoreHarness()
        let external = UUID()
        harness.lock.pending = [PendingNarrativePayload(
            hkExternalUUID: external.uuidString,
            dateKey: "2026-05-20",
            noteBytes: Data("drained note".utf8),
            symptomFlagsBytes: try JSONEncoder().encode([PeriodSymptom.bloating.rawValue]),
            customSymptomScalesBytes: try JSONEncoder().encode(["bloating": 4])
        )]

        try await harness.store.drainPendingBuffer(contentKey: harness.key)

        let stored = try #require(try harness.storedRecords().first)
        #expect(stored.id == external)
        #expect(stored.clinical == nil)
        #expect(stored.narrative?.note == "drained note")
        #expect(stored.narrative?.symptomFlags == [.bloating])
        #expect(stored.dayKey == "2026-05-20")
        #expect(stored.origin == .importedLegacy)
    }

    /// A drain whose purge failed re-drains without duplicates (one merge write, deterministic ids).
    @Test func aPartialDrainReDrainsWithoutDuplicates() async throws {
        let harness = CycleStoreHarness()
        harness.lock.pending = [try Self.v2Payload(PeriodTestSupport.record(on: Date(), flow: .light))]
        harness.lock.purgeErrorOnce = PendingNarrativeBufferError.full

        await #expect(throws: PendingNarrativeBufferError.self) {
            try await harness.store.drainPendingBuffer(contentKey: harness.key)
        }
        try await harness.store.drainPendingBuffer(contentKey: harness.key)

        #expect(try harness.records.recordCount() == 1)
        #expect(harness.lock.pending.isEmpty)
    }

    /// A payload that will not decode throws before anything is written; the buffer is kept.
    @Test func aDrainThatCannotDecodeKeepsTheBuffer() async throws {
        let harness = CycleStoreHarness()
        harness.lock.pending = [
            try Self.v2Payload(PeriodTestSupport.record(on: Date(), flow: .light)),
            PendingNarrativePayload(hkExternalUUID: UUID().uuidString, dateKey: "2026-05-21", noteBytes: nil,
                                    symptomFlagsBytes: Data("not-json".utf8), customSymptomScalesBytes: nil)
        ]

        await #expect(throws: (any Error).self) {
            try await harness.store.drainPendingBuffer(contentKey: harness.key)
        }
        #expect(harness.lock.pending.count == 2)
        #expect(try harness.records.recordCount() == 0)
    }

    // MARK: - Health-only Fernlet days (§7.3)

    /// "Keep in Fernlet" adopts the day's Fernlet copies as one record per copy group, under the
    /// copy's own record id, clinical known and narrative unknown.
    @Test func keepInFernletAdoptsTheDaysCopies() async throws {
        let harness = CycleStoreHarness()
        let otherPhone = PeriodTestSupport.record(on: Date(), flow: .heavy)
        let day = CycleDayEntry(date: Date(), dateKey: otherPhone.dayKey, fernletHealthSamples: try HealthKitService.periodSamples(for: otherPhone))

        #expect(try harness.store.keepHealthOnlyDay(day, contentKey: harness.key) == 1)

        let adopted = try #require(try harness.storedRecords().first)
        #expect(adopted.id == otherPhone.id)
        #expect(adopted.origin == .adoptedFromHealth)
        #expect(adopted.clinical?.flowLevel == .heavy)
        #expect(adopted.narrative == nil)
    }

    @Test func deleteFromHealthRemovesOnlyTheDaysFernletCopies() async throws {
        let harness = CycleStoreHarness()
        let copies = try HealthKitService.periodSamples(for: PeriodTestSupport.record(on: Date(), flow: .light))
        let day = CycleDayEntry(date: Date(), dateKey: FernletDate.dayKey(for: Date()), fernletHealthSamples: copies)

        #expect(try await harness.store.deleteHealthOnlyCopies(day) == copies.count)
        #expect(harness.health.calls == ["deleteAuthored"])
    }

    // MARK: - Source walls

    @Test func menstrualFlowCountReferenceIsRestrictedToAllowedFiles() throws {
        let root = RepoRoot.url
            .appendingPathComponent("App/Fernlet")
        let allowed: Set<String> = [
            "ContentView.swift",
            "HealthKitService.swift",
            "WellbeingModels.swift",
            "PeriodTrackerStore.swift",
            "CycleTrackerView.swift",
            "LogPeriodSheet.swift"
        ]
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" && !allowed.contains($0.lastPathComponent) }
        let leakingFiles = try files.filter { url in
            try String(contentsOf: url, encoding: .utf8).contains("menstrualFlowEventCount")
        }
        #expect(leakingFiles.isEmpty)
    }

    // MARK: - Helpers

    private func makeRepository() -> MenstrualNarrativeRepository {
        MenstrualNarrativeRepository(context: PrivatePersistenceController(inMemory: true).container.viewContext)
    }

    /// A log with every field set.
    static func fullEvent() -> UserLoggedCycleEvent {
        UserLoggedCycleEvent(
            flowLevel: .medium, basalBodyTemperature: 36.6, temperatureUnit: .celsius,
            cervicalMucusQuality: .eggWhite, ovulationTestResult: .positive, hasIntermenstrualBleeding: true,
            isCycleStart: true, note: "cramps after lunch", symptoms: [.cramps], customSymptomScales: ["cramps": 6]
        )
    }

    /// A v2 pending-buffer payload carrying `record`.
    static func v2Payload(_ record: CycleRecord) throws -> PendingNarrativePayload {
        PendingNarrativePayload(cycleRecordID: record.id, dayKey: record.dayKey, cycleRecordJSON: try record.frozenJSON())
    }

    /// The published entry for today.
    static func today(in store: PeriodTrackerStore) -> CycleDayEntry? {
        entry(on: Date(), in: store)
    }

    /// The published entry for `date`'s day.
    static func entry(on date: Date, in store: PeriodTrackerStore) -> CycleDayEntry? {
        let key = FernletDate.dayKey(for: date)
        return store.entries.first { $0.dateKey == key }
    }
}
