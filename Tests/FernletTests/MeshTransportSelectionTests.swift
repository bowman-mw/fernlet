import Foundation
import Testing
import FernletCrypto
@testable import ProximityKit
@testable import Fernlet

// MARK: - MeshTransportSelectionTests

// P2 item 8: `MeshNetworkManager` takes its radio through a seam instead of owning a
// `MeshMultipeerSession` outright. Three claims are worth a wall here, and each has an obvious way
// to be quietly broken:
//
// 1. **MultipeerConnectivity is still the default on every shipping path.** A seam that made QUIC
//    reachable also made it accidentally reachable; the selection is pinned as a pure function.
// 2. **The QUIC radio gets a real `MeshIntroductionAuthority`.** Nil is not a degraded mode — the
//    transport refuses every tunnel — so a manager that forgot to attach one would present as
//    "QUIC connects to nobody", which is exactly the symptom nobody debugs quickly.
// 3. **Nothing about the choice is stored.** No setting, no UI, no `UserDefaults` key: the
//    selection lasts one launch and owes no row on the persisted-surface wipe ledger.

@Suite(.serialized) @MainActor
struct MeshTransportSelectionTests {
    let store = makeTestStore()

    // MARK: - Selection

    /// The default is MultipeerConnectivity, and an absent/unrecognized selection lands there too.
    /// A garbage value must not leave a build with no radio at all.
    @Test func theShippingDefaultIsMultipeerConnectivity() {
        #expect(MeshTransportFactory.shippingDefault == .multipeer)
        #expect(MeshTransportFactory.resolvedKind(environment: [:]) == .multipeer)
        for junk in ["", "QUIC", "quic ", "multipeer2", "1", "true"] {
            #expect(
                MeshTransportFactory.resolvedKind(
                    environment: [MeshTransportFactory.quicSelectionEnvironmentKey: junk]
                ) == .multipeer,
                "an unrecognized selection (\(junk)) must fall back to the shipping default"
            )
        }
    }

    /// A manager built the way the app builds one runs on the MC radio — the assertion that would
    /// fail the moment a default flipped anywhere in the factory or the initializer.
    @Test func theAppsInitializerRunsOnTheMultipeerRadio() {
        let manager = MeshNetworkManager(store: store)

        #expect(manager.transportForTesting as? MeshMultipeerSession != nil,
                "the public initializer must select MultipeerConnectivity")
        #expect(manager.transportForTesting as? NetworkMeshSession == nil,
                "and must never select the QUIC radio")
    }

    /// QUIC is selectable — by injection, and by the DEBUG-only launch variable the migration's
    /// Simulator lanes use. Both are opt-in; neither is a stored preference.
    @Test func theQUICRadioIsSelectableAndOptIn() {
        #expect(
            MeshTransportFactory.resolvedKind(
                environment: [MeshTransportFactory.quicSelectionEnvironmentKey: MeshTransportKind.quic.rawValue]
            ) == .quic,
            "the DEBUG launch variable must be able to select the QUIC radio"
        )
        let manager = MeshNetworkManager(store: store, transport: NetworkMeshSession())
        #expect(manager.transportForTesting as? NetworkMeshSession != nil,
                "an injected QUIC radio must be the one the manager drives")
    }

    /// Every kind builds the radio it names, so a new case cannot be added without a factory arm.
    @Test func everyTransportKindBuildsItsOwnRadio() {
        for kind in MeshTransportKind.allCases {
            let session = MeshTransportFactory.makeSession(kind)
            switch kind {
            case .multipeer: #expect(session as? MeshMultipeerSession != nil)
            case .quic:      #expect(session as? NetworkMeshSession != nil)
            }
        }
    }

    // MARK: - The introduction authority

    /// A QUIC radio nobody wired authenticates nobody: no authority to verify against, and no
    /// admission gate to consult. Both are fail-closed by design (see `NetworkMeshSession`), and
    /// this pins the starting state that makes them so.
    @Test func aQUICRadioNobodyWiredHoldsNeitherAuthorityNorGate() {
        let session = NetworkMeshSession()

        #expect(session.introductionAuthority == nil, "an unwired radio must not claim an authority")
        #expect(session.invitationGate == nil, "nor an admission gate — both fail closed at nil")
    }

    /// Selecting QUIC attaches the manager as the radio's authority, and its four answers come from
    /// the same state the MC path already trusts.
    @Test func selectingQUICSuppliesTheIntroductionAuthority() {
        let session = NetworkMeshSession()
        let manager = MeshNetworkManager(store: store, transport: session)

        #expect(session.introductionAuthority != nil, "a selected QUIC radio must be given an authority")
        #expect(session.introductionAuthority === manager, "and it is the manager itself")
        #expect(session.introductionAuthority?.localSigningPublicKey == manager.localSigningPublicKey,
                "read through the protocol witness, not the concrete type")
        #expect(!manager.localSigningPublicKey.isEmpty, "and it is a real provisioned key")
        #expect(manager.meshID.uuidString == "00000000-0000-0000-0000-000000000000",
                "with no mesh, both sides must agree on the unbound id rather than invent one")
        #expect(manager.epochRef.isEmpty, "with no group key there is no epoch to name")
        #expect(manager.roster.memberCount == 0, "and an empty roster refuses every stranger")
    }

    /// The authority signs under the channel-introduction domain, and nothing else.
    ///
    /// The bytes are REAL canonical transcript bytes, not a blob: `meshChannelIntroductionV1` is
    /// declared `.lengthPrefixed`, and the purpose wall refuses to sign anything that does not
    /// already carry its own length-prefixed domain tag. Handing it a blob throws
    /// `IdentityError.invalidKeyData` — which is the wall working, and is why this test is written
    /// against `canonicalBytes(for:)` the way the QUIC radio calls it.
    @Test func theAuthoritySignsUnderTheChannelIntroductionDomain() throws {
        let manager = MeshNetworkManager(store: store, transport: NetworkMeshSession())
        let bytes = canonicalBytes(for: MeshChannelIntroductionTranscript(
            protocolVersion: MeshChannelIntroductionFormat.protocolVersion,
            meshID: manager.meshID,
            epochRef: manager.epochRef,
            initiatorSigningPublicKey: manager.localSigningPublicKey,
            responderSigningPublicKey: Data(repeating: 7, count: 32),
            initiatorNonce: Data(repeating: 8, count: 16),
            responderNonce: Data(repeating: 9, count: 16),
            channelBindingHash: Data(repeating: 10, count: 32)
        ))

        let signature = try manager.signChannelIntroduction(bytes)

        #expect(IdentityService.verify(
            signature,
            of: bytes,
            by: manager.localSigningPublicKey,
            purpose: FernletCryptoPurpose.Signature.meshChannelIntroductionV1
        ), "the authority must sign under fernlet.mesh.channel-introduction.v1")
        #expect(!IdentityService.verify(
            signature,
            of: bytes,
            by: manager.localSigningPublicKey,
            purpose: FernletCryptoPurpose.Signature.meshProbeChannelIntroductionV1
        ), "and that signature must not verify under the DEBUG probe's neighbouring purpose")
    }

    /// The purpose wall in the other direction: the authority is not a signing oracle. Bytes that do
    /// not carry the channel-introduction domain are refused at the raw Ed25519 boundary rather than
    /// signed, so wiring the manager in as an authority cannot widen what its identity key will sign.
    @Test func theAuthorityRefusesToSignBytesOutsideItsDomain() {
        let manager = MeshNetworkManager(store: store, transport: NetworkMeshSession())

        #expect(throws: IdentityError.invalidKeyData) {
            try manager.signChannelIntroduction(Data("not a channel-introduction transcript".utf8))
        }
    }

    /// The MC radio is handed the authority too and ignores it by contract — it authenticates one
    /// layer up, inside the slot coordinator's identity introduction. What matters is that giving it
    /// one changes nothing observable, so the wiring can stay identical on both paths.
    @Test func theMultipeerRadioIgnoresTheAuthorityWithoutIncident() {
        let session = MeshMultipeerSession()
        let manager = MeshNetworkManager(store: store, transport: session)

        session.attachIntroductionAuthority(manager)

        #expect((manager.transportForTesting as? MeshMultipeerSession) === session)
    }

    // MARK: - The wiring itself

    /// Every callback a radio can fire is wired. A hook silently left nil is not a compile error and
    /// not a test failure anywhere else — it is a feature that stops happening.
    @Test func theManagerWiresEveryCallbackARadioCanFire() {
        let transport = FakeMeshTransportSession()
        // Held, not discarded: `attachedAuthority` is weak, exactly as the real radio holds it, so a
        // manager released here would take the authority with it and the last expectation would
        // pass or fail on lifetime rather than on wiring.
        let manager = MeshNetworkManager(store: store, transport: transport)

        #expect(transport.handlers.onPeerDiscovered != nil)
        #expect(transport.handlers.onChannelReady != nil)
        #expect(transport.handlers.onPeerDisconnected != nil)
        #expect(transport.handlers.shouldAcceptInvitation != nil)
        #expect(transport.handlers.onTransportError != nil)
        #expect(transport.attachedAuthority != nil, "and the radio is offered an authority")
        #expect((manager.transportForTesting as? FakeMeshTransportSession) === transport)
    }

    /// A radio that cannot start surfaces as the discovery-failure banner, not as a search that
    /// spins forever in silence. Driven through the injected transport, which is the only way to
    /// reach this without a declined Local Network prompt on a device.
    @Test func aTransportErrorBecomesTheDiscoveryFailureBanner() {
        let transport = FakeMeshTransportSession()
        let manager = MeshNetworkManager(store: store, transport: transport)
        #expect(manager.discoveryError == nil)

        transport.failDiscovery("Could not start browsing for nearby Fernlets.")

        #expect(manager.discoveryError == "Could not start browsing for nearby Fernlets.")
    }

    /// The admission gate answers on the injected radio the same way it answered the MC advertiser:
    /// a proximity-join session that is CLOSED admits nobody, an open one with room admits.
    @Test func theAdmissionGateRefusesAClosedProximityJoinSession() {
        let transport = FakeMeshTransportSession()
        let manager = MeshNetworkManager(store: store, transport: transport)
        let peer = PeerHandle(id: UUID(), displayHint: "iPhone", discoveryInfo: nil, advertisedFingerprint: nil)

        manager.markProximityJoinForTesting()
        #expect(transport.offerInboundConnection(from: peer), "an open session with room admits")

        manager.setSessionOpen(false)

        #expect(!transport.offerInboundConnection(from: peer), "a closed proximity-join session admits nobody")
    }
}
