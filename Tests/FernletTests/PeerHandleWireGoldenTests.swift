import Foundation
import FernletCrypto
import FernletDomainModel
import ProximityKit
import Testing

/// P1's acceptance gate: **no wire byte moved.**
///
/// Transport neutrality replaced `MultipeerPeer` with ``PeerHandle`` and `MCSessionSendDataMode` with
/// ``PeerDeliveryMode`` across ~40 signatures. Almost none of that can reach the wire — but exactly
/// one field can, and it is easy to miss: the coordinator writes `peer.advertisedFingerprint` into
/// an envelope's `recipientFingerprint`, and that field is folded into the canonical signing bytes.
/// A rename that changed its type, its optionality, or the moment it is read would move signed bytes
/// and break verification against every already-shipped peer, with no compile error anywhere.
///
/// So these are golden vectors in the style of `FernletIdentityEnvelopeTests`' WI-6 section: fixed
/// input, pinned hex, failure message re-printing the actual so a *deliberate* format bump can be
/// re-pinned by copy-paste. If one of these fails and the change was not a deliberate wire-format
/// change, the change has left P1's scope.
@Suite(.serialized)
struct PeerHandleWireGoldenTests {

    /// The envelope a coordinator builds for a peer that advertised a fingerprint. The vector is the
    /// canonical signing bytes — the layer that actually has to stay stable, since it is what both
    /// ends sign and verify over.
    static let goldenPeerBoundEnvelopeHex = "00000000000000266665726e6c65742e63616e6f6e6963616c2e6964656e746974792d656e76656c6f70652e7632000000000000000211111111222233334444555555555555000000000000000401020304000000000000000405060708000000000000000c4c6f63616c2044657669636501000000000000001061626364656630313233343536373839000000000000001a6665726e6c65742e646961676e6f737469632e6563686f2e7631000000000000000006476f6c64656e000000000000000000000000000000000000000000000000000d7061796c6f61642d6279746573000000006553f10000"

    /// The same envelope with no advertised fingerprint. Registered as its own vector because
    /// `nil` is not "the empty string" on the wire — it is the documented *broadcast* case, and a
    /// refactor that quietly coerced one into the other would still round-trip locally.
    static let goldenBroadcastEnvelopeHex = "00000000000000266665726e6c65742e63616e6f6e6963616c2e6964656e746974792d656e76656c6f70652e7632000000000000000211111111222233334444555555555555000000000000000401020304000000000000000405060708000000000000000c4c6f63616c2044657669636500000000000000001a6665726e6c65742e646961676e6f737469632e6563686f2e7631000000000000000006476f6c64656e000000000000000000000000000000000000000000000000000d7061796c6f61642d6279746573000000006553f10000"

    /// A peer that advertised a fingerprint, built exactly as `MeshMultipeerSession.peer(for:)`
    /// builds one: `advertisedFingerprint` is `discoveryInfo["fp"]`.
    private func fixedAdvertisingHandle() -> PeerHandle {
        let info = ["fp": "abcdef0123456789", "v": "1", "sid": "11111111-2222-3333-4444-555555555555"]
        return PeerHandle(
            id: UUID(uuidString: "99999999-8888-7777-6666-555555555555") ?? UUID(),
            displayHint: "Aisha 🌿",
            discoveryInfo: info,
            advertisedFingerprint: info["fp"],
            endpoint: PeerEndpointKey(UUID(uuidString: "00000000-0000-0000-0000-0000000000aa") ?? UUID())
        )
    }

    /// The envelope shape the coordinator emits, parameterized only by the peer's advertised
    /// fingerprint — every other field is fixed so the bytes are reproducible.
    private func envelope(boundTo peer: PeerHandle?) -> FernletIdentityEnvelope {
        FernletIdentityEnvelope(
            schemaVersion: FernletIdentityEnvelope.currentSchemaVersion,
            envelopeID: UUID(uuidString: "11111111-2222-3333-4444-555555555555") ?? UUID(),
            senderSigningPublicKey: Data([0x01, 0x02, 0x03, 0x04]),
            senderKeyAgreementPublicKey: Data([0x05, 0x06, 0x07, 0x08]),
            senderDisplayName: "Local Device",
            recipientFingerprint: peer?.advertisedFingerprint,
            payloadType: .inspectorEcho,
            payloadEncryption: .none,
            payloadSummary: PayloadSummary(title: "Golden"),
            payload: Data("payload-bytes".utf8),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            expiresAt: nil,
            signature: Data("ignored — excluded from canonical bytes".utf8)
        )
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    @Test func aPeerBoundEnvelopeIsGoldenStable() {
        let actual = hex(canonicalBytes(for: envelope(boundTo: fixedAdvertisingHandle())))
        #expect(actual == Self.goldenPeerBoundEnvelopeHex, "actual peer-bound golden hex = \(actual)")
    }

    @Test func aBroadcastEnvelopeIsGoldenStable() {
        let actual = hex(canonicalBytes(for: envelope(boundTo: nil)))
        #expect(actual == Self.goldenBroadcastEnvelopeHex, "actual broadcast golden hex = \(actual)")
    }

    /// The two vectors must differ. If a refactor made `advertisedFingerprint` unreachable — which
    /// is a live hazard, since no shipping radio actually publishes `"fp"` today — both would
    /// collapse onto the broadcast bytes and every other assertion here would still pass.
    @Test func bindingToAPeerChangesTheSignedBytes() {
        let bound = canonicalBytes(for: envelope(boundTo: fixedAdvertisingHandle()))
        let broadcast = canonicalBytes(for: envelope(boundTo: nil))
        #expect(bound != broadcast, "recipientFingerprint stopped reaching the canonical bytes")
    }

    /// A handle whose advertisement carries no `"fp"` produces the broadcast bytes — the same shape
    /// every shipping radio produces today, since none of them publishes the key.
    @Test func aHandleWithoutAnAdvertisedFingerprintIsTheBroadcastCase() {
        let plain = PeerHandle(
            id: UUID(),
            displayHint: "Plain",
            discoveryInfo: ["v": "1"],
            advertisedFingerprint: nil
        )
        #expect(canonicalBytes(for: envelope(boundTo: plain)) == canonicalBytes(for: envelope(boundTo: nil)))
    }

    /// The identity fields of a handle must not reach the wire at all. `displayHint` is peer-supplied
    /// and unauthenticated, `id` and the endpoint key are process-local — if any of them appeared in
    /// signed bytes, a peer could move another peer's signature by renaming itself.
    @Test func noHandleIdentityFieldReachesTheSignedBytes() {
        let handle = fixedAdvertisingHandle()
        let bytes = canonicalBytes(for: envelope(boundTo: handle))

        for forbidden in [handle.displayHint, handle.id.uuidString, handle.id.uuidString.lowercased()] {
            #expect(
                bytes.range(of: Data(forbidden.utf8)) == nil,
                "\"\(forbidden)\" reached the signed envelope bytes"
            )
        }
    }

    /// Framing is below the peer type and must be untouched by it: the same plaintext frames to the
    /// same bytes regardless of which peer it is destined for, and regardless of delivery mode.
    /// ``PeerDeliveryMode`` chooses a transport guarantee, never a payload shape.
    @Test func framingIsIndependentOfPeerAndDeliveryMode() throws {
        let plaintext = Data("frame me".utf8)
        let framed = SealedPayloadFraming.frame(plaintext)

        #expect(SealedPayloadFraming.hasFrameTag(plaintext) == false)
        #expect(try SealedPayloadFraming.unframe(framed) == plaintext)
        #expect(SealedPayloadFraming.frame(plaintext) == framed, "framing must be deterministic")

        for mode in [PeerDeliveryMode.reliable, .bestEffort] {
            _ = mode  // the mode is carried beside the bytes, never mixed into them
            #expect(SealedPayloadFraming.frame(plaintext) == framed)
        }
    }
}
