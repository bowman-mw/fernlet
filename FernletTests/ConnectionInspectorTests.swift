import Testing
import Foundation
@testable import Fernlet

@Suite(.serialized, .timeLimit(.minutes(2))) @MainActor
struct ConnectionInspectorTests {
    private func makeStore() -> FernletStore {
        makeTestStore(date: Date(timeIntervalSince1970: 1_800_000_000))
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

    @Test func beginSessionCreatesLiveLog() {
        let store = makeStore()
        let inspector = store.connectionInspector

        inspector.beginSession(role: .browser, mode: .trainer, localFingerprint: "abcd1234")

        #expect(inspector.liveLog?.role == .browser)
        #expect(inspector.liveLog?.mode == .trainer)
        #expect(inspector.liveLog?.localFingerprint == "abcd1234")
    }

    @Test func recordEventAppendsToLiveLog() {
        let store = makeStore()
        let inspector = store.connectionInspector
        inspector.beginSession(role: .browser, mode: .trainer, localFingerprint: "abcd1234")

        inspector.recordEvent(.inviteSent, message: "invite sent")

        #expect(inspector.liveLog?.events.contains { $0.kind == .inviteSent && $0.message == "invite sent" } == true)
    }

    @Test func recordRangingSampleSubsamplesAtCorrectRate() {
        let store = makeStore()
        let inspector = store.connectionInspector
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
        let store = makeStore()
        let inspector = store.connectionInspector
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

    @Test func historicalLogsCappedAt50() {
        let store = makeStore()
        let inspector = store.connectionInspector

        for index in 0..<60 {
            inspector.beginSession(role: .browser, mode: .trainer, localFingerprint: "abcd1234")
            inspector.endSession(endState: "session-\(index)")
        }

        #expect(inspector.historicalLogs.count == 50)
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

    @Test func exportAsJSONRoundTripsToCodable() throws {
        let store = makeStore()
        let inspector = store.connectionInspector
        inspector.beginSession(role: .browser, mode: .trainer, localFingerprint: "abcd1234")
        inspector.endSession(endState: "completed")

        let data = try inspector.exportAsJSON()
        let decoded = try ConnectionInspector.jsonDecoder().decode([ConnectionSessionLog].self, from: data)

        #expect(decoded == inspector.historicalLogs)
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
