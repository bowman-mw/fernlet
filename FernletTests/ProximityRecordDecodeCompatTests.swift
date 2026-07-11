// ProximityRecordDecodeCompatTests.swift
// Forward-compatibility of the proximity records PERSISTED in the synced blob (trustedProximityPeers,
// trainerAuditEvents, connectionSessionLogs) — distinct from the ProximityKit wire payloads, whose
// strict coding is untouched. A mode/kind/payload-type raw value minted by a NEWER build must freeze
// + park instead of throwing (a throw bricks the whole store — including the trust vault, which is
// security-relevant state).

import Foundation
import Testing
import FernletDomainModel

struct ProximityRecordDecodeCompatTests {
    // MARK: - ProximityTrustedPeerRecord (trust vault)

    @Test func unknownTrustedPeerModeFreezesToTrainerAndParks() throws {
        let record = try decode(ProximityTrustedPeerRecord.self, """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "displayName": "Alex",
          "fingerprint": "AB12",
          "signingPublicKey": "",
          "keyAgreementPublicKey": "",
          "mode": "mentor",
          "firstAcceptedAt": 700000000,
          "lastSeenAt": 700000100
        }
        """)

        // The record (and its identity material) survives; the unknown relationship mode freezes
        // to the narrower-scope .trainer until a build that knows it re-adopts the parked token.
        #expect(record.mode == .trainer)
        #expect(record.unknownModeToken == "mentor")
        #expect(record.fingerprint == "AB12")
        #expect(record.displayName == "Alex")

        let second = try decode(ProximityTrustedPeerRecord.self, JSONEncoder().encode(record))
        #expect(second.unknownModeToken == "mentor")
        #expect(second.mode == .trainer)

        let readopted = try decode(ProximityTrustedPeerRecord.self, """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "displayName": "Alex", "fingerprint": "AB12",
          "signingPublicKey": "", "keyAgreementPublicKey": "",
          "mode": "trainer", "unknownModeToken": "friend",
          "firstAcceptedAt": 700000000, "lastSeenAt": 700000100
        }
        """)
        #expect(readopted.mode == .friend)
        #expect(readopted.unknownModeToken == nil)

        // An explicit local re-trust in a known mode wins over the parked token.
        var edited = record
        edited.mode = .friend
        #expect(edited.unknownModeToken == nil)
    }

    @Test func missingTrustedPeerModeKeyStillThrows() throws {
        // Missing KEY ≠ unknown VALUE: every build writes `mode`, so absence is a corrupt/truncated
        // record and must keep failing decode like the historical synthesized-strict decode — only
        // a present-but-unknown value freezes + parks.
        let json = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "displayName": "Alex",
          "fingerprint": "AB12",
          "signingPublicKey": "",
          "keyAgreementPublicKey": "",
          "firstAcceptedAt": 700000000,
          "lastSeenAt": 700000100
        }
        """
        let error = #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(ProximityTrustedPeerRecord.self, from: Data(json.utf8))
        }
        if case .keyNotFound(let key, _)? = error {
            #expect(key.stringValue == "mode")
        } else {
            Issue.record("expected keyNotFound(mode), got \(String(describing: error))")
        }
    }

    // MARK: - TrainerAuditEvent (audit log)

    @Test func unknownAuditKindAndPayloadTypeFreezeAndPark() throws {
        let event = try decode(TrainerAuditEvent.self, """
        {
          "id": "22222222-2222-2222-2222-222222222222",
          "timestamp": 700000000,
          "kind": "planRejected",
          "payloadType": "fernlet.trainer.plan.v2",
          "message": "peer rejected the plan"
        }
        """)

        #expect(event.kind == .stateTransition)
        #expect(event.unknownKindToken == "planRejected")
        #expect(event.payloadType == nil)
        #expect(event.unknownPayloadTypeToken == "fernlet.trainer.plan.v2")
        #expect(event.message == "peer rejected the plan")

        let second = try decode(TrainerAuditEvent.self, JSONEncoder().encode(event))
        #expect(second.unknownKindToken == "planRejected")
        #expect(second.unknownPayloadTypeToken == "fernlet.trainer.plan.v2")

        // A known payload type still decodes typed, no park.
        let known = try decode(TrainerAuditEvent.self, """
        {
          "id": "22222222-2222-2222-2222-222222222222",
          "timestamp": 700000000,
          "kind": "envelopeSent",
          "payloadType": "fernlet.recipe.share.v1",
          "message": "sent"
        }
        """)
        #expect(known.kind == .envelopeSent)
        #expect(known.payloadType == .recipeShare)
        #expect(known.unknownKindToken == nil)
        #expect(known.unknownPayloadTypeToken == nil)
    }

    // MARK: - ConnectionSessionLog (inspector log)

    @Test func unknownSessionLogEnumsFreezeAndParkThroughTheWholeTree() throws {
        let log = try decode(ConnectionSessionLog.self, """
        {
          "id": "33333333-3333-3333-3333-333333333333",
          "startedAt": 700000000,
          "role": "relay",
          "mode": "mentor",
          "localFingerprint": "CD34",
          "ranging": {"mode": "lidar", "samples": []},
          "transport": {
            "mcSessionState": "connected", "bytesSent": 10, "bytesReceived": 20,
            "bluetoothActive": true, "wifiActive": true, "rttSamplesMs": []
          },
          "events": [
            {"id": "44444444-4444-4444-4444-444444444444", "timestamp": 700000001,
             "kind": "hologramProjected", "message": "future thing happened"}
          ],
          "envelopes": [
            {"id": "55555555-5555-5555-5555-555555555555",
             "envelopeID": "66666666-6666-6666-6666-666666666666",
             "direction": "relayed", "payloadType": "fernlet.future.v9",
             "payloadByteCount": 12, "timestamp": 700000002, "encrypted": true, "summary": "s"}
          ],
          "errors": [],
          "endState": "active"
        }
        """)

        #expect(log.role == .browser)
        #expect(log.unknownRoleToken == "relay")
        #expect(log.mode == .friend)
        #expect(log.unknownModeToken == "mentor")
        #expect(log.ranging.mode == ProximityRangingMode.none)
        #expect(log.ranging.unknownModeToken == "lidar")

        let event = try #require(log.events.first)
        #expect(event.kind == .stateTransition)
        #expect(event.unknownKindToken == "hologramProjected")
        #expect(event.message == "future thing happened")

        let envelope = try #require(log.envelopes.first)
        #expect(envelope.direction == .received)
        #expect(envelope.unknownDirectionToken == "relayed")
        // payloadType here is a plain String — a newer wire type never needed tolerance.
        #expect(envelope.payloadType == "fernlet.future.v9")

        let second = try decode(ConnectionSessionLog.self, JSONEncoder().encode(log))
        #expect(second.unknownRoleToken == "relay")
        #expect(second.unknownModeToken == "mentor")
        #expect(second.ranging.unknownModeToken == "lidar")
        #expect(second.events.first?.unknownKindToken == "hologramProjected")
        #expect(second.envelopes.first?.unknownDirectionToken == "relayed")
    }

    @Test func knownSessionLogStillDecodesUnchanged() throws {
        let log = try decode(ConnectionSessionLog.self, """
        {
          "id": "33333333-3333-3333-3333-333333333333",
          "startedAt": 700000000,
          "role": "advertiser",
          "mode": "trainer",
          "localFingerprint": "CD34",
          "ranging": {"mode": "uwb", "samples": []},
          "transport": {
            "mcSessionState": "connected", "bytesSent": 0, "bytesReceived": 0,
            "bluetoothActive": true, "wifiActive": true, "rttSamplesMs": []
          },
          "events": [], "envelopes": [], "errors": [],
          "endState": "ended"
        }
        """)
        #expect(log.role == .advertiser)
        #expect(log.mode == .trainer)
        #expect(log.ranging.mode == .uwb)
        #expect(log.unknownRoleToken == nil)
        #expect(log.unknownModeToken == nil)
        #expect(log.endState == "ended")
    }

    @Test func missingSessionLogRoleKeyStillThrows() throws {
        // Missing KEY ≠ unknown VALUE: `role` was synthesized-strict before the tolerant decode, so
        // a log record without it is corruption and must keep surfacing as a decode failure.
        let json = """
        {
          "id": "33333333-3333-3333-3333-333333333333",
          "startedAt": 700000000,
          "mode": "trainer",
          "localFingerprint": "CD34",
          "ranging": {"mode": "uwb", "samples": []},
          "transport": {
            "mcSessionState": "connected", "bytesSent": 0, "bytesReceived": 0,
            "bluetoothActive": true, "wifiActive": true, "rttSamplesMs": []
          },
          "events": [], "envelopes": [], "errors": [],
          "endState": "ended"
        }
        """
        let error = #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(ConnectionSessionLog.self, from: Data(json.utf8))
        }
        if case .keyNotFound(let key, _)? = error {
            #expect(key.stringValue == "role")
        } else {
            Issue.record("expected keyNotFound(role), got \(String(describing: error))")
        }
    }

    // MARK: - Helpers

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try decode(type, Data(json.utf8))
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}
