import Testing
import Foundation
import FernletDomainModel
import FernletPersistence
@testable import Fernlet

/// The connection inspector's recorder, and the five claims that are about the store hosting it.
///
/// **Most cells build no store** (2026-09-24; the timeout is finding 5 of §12.3 in
/// `Docs/Plan-ProximityKit-Network-Migration-2026-08-27.md`). `ConnectionInspector` reaches its host
/// at exactly three points — the mode gate in `beginSession`/`endSession`, the history it re-seeds
/// from, and the `replaceConnectionSessionLogs` write-back — and an inspector with no host records
/// unconditionally and persists nowhere, which is the product default (`FernletSettings` defaults to
/// `.live`). So every cell whose claim is about the RECORDER (the live log, the event trail, ranging
/// subsampling, envelope byte counts, the 50-session cap, the JSON export) runs against
/// `ConnectionInspector()` alone — the same object `FernletStore` declares as its
/// `connectionInspector`, minus the attach. The five cells whose claim is about the HOST — the
/// write-back landing in the store's own `connectionSessionLogs`, history re-seeded from the store
/// and purged on attach, the mode set through `setConnectionInspectorMode`, and the presentation flag
/// neither mode raises — keep a real `makeTestStore()`, because the store is what they prove.
///
/// **No `.timeLimit`, deliberately.** Until this restructure the suite carried
/// `.timeLimit(.minutes(2))` — the only time limit in the whole test target — and every cell built a
/// full `FernletStore` on the main actor. Under full-suite load `beginSessionCreatesLiveLog` took
/// ~206 s (P6) and 306 s (P8) against that limit, voiding the runs, and passed alone in 0.2 s. A
/// Swift Testing time limit starts before the test's hop to the main actor, so it measured the main
/// actor's queue behind every other `@MainActor` suite, not this cell — the same deadline-alone
/// mistake the repository's poll helpers answer with a poll floor (`waitUntil` in
/// `MeshSeatTransportProofTests`). Measured 2026-09-24 in one ten-suite run: the FIRST cell here,
/// store-free, took 2.5 s, and each store-backed cell 7–9 ms. The time is the queue's, not the
/// store's, so taking the store out could not by itself have saved a loaded run; the limit is what
/// turned the wait into a failure. Nothing here can hang: every cell is synchronous, every loop is
/// bounded, and no cell awaits anything.
@Suite(.serialized) @MainActor
struct ConnectionInspectorTests {
    /// A real host store, for the five cells whose claim is about the store itself.
    private func makeStore() -> FernletStore {
        makeTestStore(date: Date(timeIntervalSince1970: 1_800_000_000))
    }

    /// The recorder alone: what `FernletStore.connectionInspector` is before `attachStore(_:)` —
    /// recording on (no host has disabled it) and persisting nowhere.
    private func makeRecorder() -> ConnectionInspector {
        ConnectionInspector()
    }

    private func makeLog(startedAt: Date = Date(), id: UUID = UUID()) -> ConnectionSessionLog {
        ConnectionSessionLog(
            id: id,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(5),
            role: .browser,
            mode: .trainer,
            localFingerprint: "local123",
            peer: ConnectionSessionLog.PeerInfo(
                displayName: "Peer",
                advertisedFingerprint: "peer1234",
                confirmedFingerprint: "peer1234",
                signingPublicKey: Data([1, 2, 3]),
                firstSeenAt: startedAt,
                lastSeenAt: startedAt.addingTimeInterval(5)
            ),
            endState: "completed"
        )
    }

    // MARK: - The recorder (no store)

    @Test func beginSessionCreatesLiveLog() {
        let inspector = makeRecorder()

        inspector.beginSession(role: .browser, mode: .trainer, localFingerprint: "abcd1234")

        #expect(inspector.liveLog?.role == .browser)
        #expect(inspector.liveLog?.mode == .trainer)
        #expect(inspector.liveLog?.localFingerprint == "abcd1234")
    }

    @Test func recordEventAppendsToLiveLog() {
        let inspector = makeRecorder()
        inspector.beginSession(role: .browser, mode: .trainer, localFingerprint: "abcd1234")

        inspector.recordEvent(.inviteSent, message: "invite sent")

        #expect(inspector.liveLog?.events.contains { $0.kind == .inviteSent && $0.message == "invite sent" } == true)
    }

    @Test func recordRangingSampleSubsamplesAtCorrectRate() {
        let inspector = makeRecorder()
        inspector.beginSession(role: .browser, mode: .trainer, localFingerprint: "abcd1234")
        let start = Date()

        for index in 0..<30 {
            inspector.recordRangingSample(
                ConnectionSessionLog.DistanceSample(
                    timestamp: start.addingTimeInterval(Double(index) / 30.0),
                    meters: 0.04
                )
            )
        }

        #expect(inspector.liveLog?.ranging.samples.count == 10)
    }

    @Test func recordEnvelopeNeverIncludesPayloadBytes() {
        let inspector = makeRecorder()
        inspector.beginSession(role: .browser, mode: .trainer, localFingerprint: "abcd1234")
        let record = ConnectionSessionLog.EnvelopeRecord(
            envelopeID: UUID(),
            direction: .received,
            payloadType: PayloadType.trainerPlan.rawValue,
            payloadByteCount: 2048,
            timestamp: Date(),
            signatureVerified: true,
            encrypted: false,
            summary: "Plan"
        )

        inspector.recordEnvelope(record)

        #expect(inspector.liveLog?.envelopes.first?.payloadByteCount == 2048)
        #expect(inspector.liveLog?.transport.bytesReceived == 2048)
    }

    @Test func historicalLogsCappedAt50() {
        let inspector = makeRecorder()

        for index in 0..<60 {
            inspector.beginSession(role: .browser, mode: .trainer, localFingerprint: "abcd1234")
            inspector.endSession(endState: "session-\(index)")
        }

        #expect(inspector.historicalLogs.count == 50)
    }

    @Test func exportAsJSONRoundTripsToCodable() throws {
        let inspector = makeRecorder()
        inspector.beginSession(role: .browser, mode: .trainer, localFingerprint: "abcd1234")
        inspector.endSession(endState: "completed")

        let data = try inspector.exportAsJSON()
        let decoded = try ConnectionInspector.jsonDecoder().decode([ConnectionSessionLog].self, from: data)

        #expect(decoded == inspector.historicalLogs)
    }

    // MARK: - The host store (a real one: these claims are about it)

    @Test func endSessionMovesLogToHistorical() {
        let store = makeStore()
        let inspector = store.connectionInspector
        inspector.beginSession(role: .browser, mode: .trainer, localFingerprint: "abcd1234")

        inspector.endSession(endState: "completed")

        #expect(inspector.liveLog == nil)
        #expect(inspector.historicalLogs.count == 1)
        #expect(inspector.historicalLogs.first?.endState == "completed")
        #expect(store.connectionSessionLogs.count == 1)
    }

    @Test func purgeOldRemovesLogsOlderThan60Days() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let inspector = ConnectionInspector(now: { now })
        let old = makeLog(startedAt: now.addingTimeInterval(-70 * 24 * 60 * 60))
        let fresh = makeLog(startedAt: now.addingTimeInterval(-2 * 24 * 60 * 60))
        let store = makeStore()
        store.replaceConnectionSessionLogs([old, fresh])
        inspector.attachStore(store)

        inspector.purgeOld()

        #expect(inspector.historicalLogs.map(\.id) == [fresh.id])
    }

    @Test func disabledModeDoesNotPersist() {
        let store = makeStore()
        store.setConnectionInspectorMode(.disabled)
        let inspector = store.connectionInspector

        inspector.beginSession(role: .browser, mode: .trainer, localFingerprint: "abcd1234")
        inspector.endSession(endState: "completed")

        #expect(inspector.historicalLogs.isEmpty)
        #expect(store.connectionSessionLogs.isEmpty)
    }

    @Test func liveModeDoesNotAutoShowInspector() {
        let store = makeStore()
        store.setConnectionInspectorMode(.live)

        store.connectionInspector.beginSession(role: .browser, mode: .trainer, localFingerprint: "abcd1234")

        #expect(store.showConnectionInspector == false)
        #expect(store.connectionInspector.liveLog != nil)
    }

    @Test func passiveModeDoesNotAutoShowInspector() {
        let store = makeStore()
        store.setConnectionInspectorMode(.passive)

        store.connectionInspector.beginSession(role: .browser, mode: .trainer, localFingerprint: "abcd1234")

        #expect(store.showConnectionInspector == false)
        #expect(store.connectionInspector.liveLog != nil)
    }

    // MARK: - The persisted log in the snapshot (no inspector, no store)

    @Test func replayCachePersistsAcrossSnapshotRoundTrip() throws {
        let log = makeLog()
        let snapshot = FernletSnapshot(
            todayKey: "2026-05-24",
            day: FernletDay(date: "2026-05-24"),
            settings: FernletSettings(),
            recentMeals: [],
            previousJournals: [],
            memories: [],
            goals: [],
            workshop: WorkshopData(),
            connectionSessionLogs: [log]
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(FernletSnapshot.self, from: data)

        #expect(decoded.connectionSessionLogs == [log])
    }

    @Test func oldSnapshotWithoutLogsDecodesWithEmptyArray() throws {
        let snapshot = FernletSnapshot(
            todayKey: "2026-05-24",
            day: FernletDay(date: "2026-05-24"),
            settings: FernletSettings(),
            recentMeals: [],
            previousJournals: [],
            memories: [],
            goals: [],
            workshop: WorkshopData()
        )
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as! [String: Any]
        object.removeValue(forKey: "connectionSessionLogs")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(FernletSnapshot.self, from: legacyData)

        #expect(decoded.connectionSessionLogs.isEmpty)
    }
}
