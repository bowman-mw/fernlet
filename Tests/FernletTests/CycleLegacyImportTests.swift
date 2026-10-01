import CryptoKit
import FernletFoundation
import Foundation
import HealthKit
import Testing
import HealthKitGateway
import PrivateHealthStore
import PrivateStoreCore
@testable import Fernlet

/// The legacy cycle import (period-data design 2026-09-30, §8; invariant I13): the sealed
/// `MenstrualNarrative` rows and Fernlet's own unmarked Apple Health samples move into sealed records,
/// in two separately tracked halves — idempotent, atomic with the narrative retirement, gated, never
/// importing a marked mirror, completing (never overwriting) what is there, done only as §8.2/§8.3
/// define, and stopped by "Delete everything" (§8.4).
@MainActor
struct CycleLegacyImportTests {
    /// The narrative half: every openable narrative becomes a narrative-only record under its legacy
    /// external id, retired in the SAME save, and the half is marked done.
    @Test func narrativesBecomeRecordsAndAreRetiredAtomically() async throws {
        let harness = CycleStoreHarness()
        let external = UUID()
        try harness.narratives.insert(MenstrualNarrative(
            hkExternalUUID: external.uuidString, dateKey: "2026-05-20", note: "from before", symptomFlags: [.cramps]
        ), contentKey: harness.key)

        await harness.store.runLegacyImportIfNeeded(contentKey: harness.key)

        let record = try #require(try harness.storedRecords().first)
        #expect(record.id == external)
        #expect(record.clinical == nil, "a narrative never knew the clinical fields")
        #expect(record.narrative?.note == "from before")
        #expect(record.narrative?.symptomFlags == [.cramps])
        #expect(record.dayKey == "2026-05-20")
        #expect(record.origin == .importedLegacy)
        #expect(try harness.narratives.narrativeCount() == 0, "retired in the same save")
        #expect(harness.ledger.isNarrativeHalfDone)
    }

    /// I13: running a half twice equals running it once.
    @Test func runningTheImportTwiceEqualsRunningItOnce() async throws {
        let harness = CycleStoreHarness()
        try harness.narratives.insert(MenstrualNarrative(hkExternalUUID: UUID().uuidString, dateKey: "2026-05-20", note: "once"), contentKey: harness.key)
        harness.health.legacySamples = try PeriodTestSupport.legacySamples(for: PeriodTestSupport.record(on: Date(), flow: .light))

        await harness.store.runLegacyImportIfNeeded(contentKey: harness.key)
        let first = try harness.storedRecords()
        // Both halves pending again: the second pass reads the same samples and must change nothing.
        harness.ledgerDefaults.removeObject(forKey: CycleLegacyImportLedger.samplesKey)
        harness.ledgerDefaults.removeObject(forKey: CycleLegacyImportLedger.narrativesKey)
        await harness.store.runLegacyImportIfNeeded(contentKey: harness.key)

        #expect(try harness.storedRecords() == first)
        #expect(first.count == 2)
    }

    /// The case review R2-F6 describes: an entry's narrative and its Health samples share one id and
    /// merge into ONE record carrying both blocks — the cycle-start flag kept.
    @Test func anEntrysNarrativeAndItsSamplesMergeIntoOneRecord() async throws {
        let harness = CycleStoreHarness()
        let logged = CycleRecord(event: UserLoggedCycleEvent(flowLevel: .medium, isCycleStart: true))
        try harness.narratives.insert(MenstrualNarrative(
            hkExternalUUID: logged.id.uuidString, dateKey: logged.dayKey, note: "first day"
        ), contentKey: harness.key)
        harness.health.legacySamples = try PeriodTestSupport.legacySamples(for: logged)

        await harness.store.runLegacyImportIfNeeded(contentKey: harness.key)

        let records = try harness.storedRecords()
        #expect(records.count == 1)
        #expect(records.first?.clinical?.isCycleStart == true)
        #expect(records.first?.clinical?.flowLevel == .medium)
        #expect(records.first?.narrative?.note == "first day")
        #expect(records.first?.loggedAt == logged.loggedAt, "the samples supply the exact time")
    }

    /// I13: a narrative that will not open here is left, counted, named for the card, and the half is
    /// done (every row left is a dead one); only the card's Remove deletes it — exactly it.
    @Test func anUnopenableNarrativeIsLeftNamedAndRemovedOnlyOnTheTap() async throws {
        let harness = CycleStoreHarness()
        try harness.narratives.insert(MenstrualNarrative(hkExternalUUID: UUID().uuidString, dateKey: "2026-05-19", note: "opens"), contentKey: harness.key)
        try harness.narratives.insert(
            MenstrualNarrative(hkExternalUUID: UUID().uuidString, dateKey: "2026-05-20", note: "lost key"),
            contentKey: SymmetricKey(data: Data(repeating: 0x11, count: 32))
        )

        await harness.store.runLegacyImportIfNeeded(contentKey: harness.key)

        #expect(try harness.records.recordCount() == 1)
        #expect(try harness.narratives.narrativeCount() == 1, "the dead row is left")
        #expect(harness.store.unopenableLegacyNarrativeIDs.count == 1)
        #expect(harness.ledger.isNarrativeHalfDone, "every row left is a dead one")

        #expect(try harness.store.removeUnopenableLegacyNarratives() == 1)
        #expect(try harness.narratives.narrativeCount() == 0)
        #expect(try harness.records.recordCount() == 1, "the imported record is untouched")
    }

    /// I13 / R2-F8: the sample half waits until every cycle type has been asked about — no Health
    /// read at all before, and the half stays pending.
    @Test func theSampleHalfWaitsForDeterminedAuthorization() async throws {
        let harness = CycleStoreHarness()
        harness.health.readDetermined = false
        harness.health.legacySamples = try PeriodTestSupport.legacySamples(for: PeriodTestSupport.record(on: Date(), flow: .light))

        await harness.store.runLegacyImportIfNeeded(contentKey: harness.key)

        #expect(harness.health.count("legacy") == 0)
        #expect(!harness.ledger.isSampleHalfDone)
        #expect(try harness.records.recordCount() == 0)

        harness.health.readDetermined = true
        await harness.store.runLegacyImportIfNeeded(contentKey: harness.key)
        #expect(harness.ledger.isSampleHalfDone)
        #expect(try harness.storedRecords().first?.clinical?.flowLevel == .light)
    }

    /// R2-F8: a read that fails leaves the half pending — it can never finish without its data.
    @Test func aFailedLegacyReadLeavesTheHalfPending() async throws {
        let harness = CycleStoreHarness()
        harness.health.legacyError = HKError(.errorDatabaseInaccessible)

        await harness.store.runLegacyImportIfNeeded(contentKey: harness.key)

        #expect(!harness.ledger.isSampleHalfDone)
    }

    /// I13: a post-cutover mirror (marked) is never imported — it is the user's deleted entry or the
    /// other iPhone's, and surfaces as a Health-only Fernlet day instead.
    @Test func aMarkedMirrorIsNeverImported() async throws {
        let harness = CycleStoreHarness()
        harness.health.legacySamples = try HealthKitService.periodSamples(for: PeriodTestSupport.record(on: Date(), flow: .heavy))

        await harness.store.runLegacyImportIfNeeded(contentKey: harness.key)

        #expect(try harness.records.recordCount() == 0)
        #expect(harness.ledger.isSampleHalfDone, "a clean read with nothing to import still finishes the half")
    }

    /// I13: the import COMPLETES what is there and never overwrites a newer block — an entry the user
    /// already edited keeps its own clinical block over the older legacy samples.
    @Test func theImportNeverOverwritesANewerBlock() async throws {
        let harness = CycleStoreHarness()
        let old = Date(timeIntervalSinceNow: -86_400 * 3)
        let sampleSource = PeriodTestSupport.record(on: old, flow: .light)
        var edited = sampleSource
        edited.clinical = CycleClinicalFields(flowLevel: .heavy, updatedAt: Date())
        try harness.records.insert(edited, contentKey: harness.key)
        harness.health.legacySamples = try PeriodTestSupport.legacySamples(for: sampleSource)

        await harness.store.runLegacyImportIfNeeded(contentKey: harness.key)

        #expect(try harness.storedRecords().first?.clinical?.flowLevel == .heavy)
        #expect(try harness.records.recordCount() == 1)
    }

    /// I10/I13: hidden, the import is a silent no-op — no Health call, nothing written, both halves
    /// still pending for a later un-hide.
    @Test func hiddenTheImportDoesNothing() async throws {
        let harness = CycleStoreHarness(visible: false)
        try harness.narratives.insert(MenstrualNarrative(hkExternalUUID: UUID().uuidString, dateKey: "2026-05-20", note: "kept"), contentKey: harness.key)

        await harness.store.runLegacyImportIfNeeded(contentKey: harness.key)

        #expect(harness.health.calls.isEmpty)
        #expect(try harness.narratives.narrativeCount() == 1)
        #expect(!harness.ledger.isNarrativeHalfDone && !harness.ledger.isSampleHalfDone)
    }

    /// §8.4 / R2-F7: "Delete everything" stops the import while its Health read is in flight — the
    /// writer epoch moves, and the pass writes nothing afterwards, narratives included.
    @Test func stoppingTheWritersMidReadWritesNothing() async throws {
        let harness = CycleStoreHarness()
        try harness.narratives.insert(MenstrualNarrative(hkExternalUUID: UUID().uuidString, dateKey: "2026-05-20", note: "n"), contentKey: harness.key)
        harness.health.legacySamples = try PeriodTestSupport.legacySamples(for: PeriodTestSupport.record(on: Date(), flow: .light))
        let store = harness.store
        harness.health.duringLegacyLoad = { store.cancelBackgroundWriters() }

        await harness.store.runLegacyImportIfNeeded(contentKey: harness.key)

        #expect(try harness.records.recordCount() == 0)
        #expect(try harness.narratives.narrativeCount() == 1)
        #expect(!harness.ledger.isNarrativeHalfDone && !harness.ledger.isSampleHalfDone)
    }

    /// The same recheck in the lock dimension: the hub closes during the legacy read — nothing lands.
    @Test func closingTheHubMidReadWritesNothing() async throws {
        let harness = CycleStoreHarness()
        harness.health.legacySamples = try PeriodTestSupport.legacySamples(for: PeriodTestSupport.record(on: Date(), flow: .light))
        var liveKey: SymmetricKey? = harness.key
        harness.store.attachLiveContentKeyProvider { liveKey }
        harness.health.duringLegacyLoad = { liveKey = nil }

        await harness.store.runLegacyImportIfNeeded(contentKey: harness.key)

        #expect(try harness.records.recordCount() == 0)
        #expect(!harness.ledger.isSampleHalfDone)
    }

    /// Delete-all and the app-lock reset set both halves to done (§8.4): the markers are a write,
    /// never a clear, and a done half never reads Health again.
    @Test func doneHalvesNeverRunAgain() async throws {
        let harness = CycleStoreHarness()
        harness.ledger.markBothHalvesDone()
        harness.health.legacySamples = try PeriodTestSupport.legacySamples(for: PeriodTestSupport.record(on: Date(), flow: .light))

        await harness.store.runLegacyImportIfNeeded(contentKey: harness.key)

        #expect(harness.health.calls.isEmpty)
        #expect(try harness.records.recordCount() == 0)
    }
}
