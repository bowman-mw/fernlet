// FernletSocialTestBindings.swift
// FernletTests
//
// ProximityKit plan step A0.4 (Docs/Plan-FernletCoach-ProximityKit-2026-10-01.md §4 A0.4): the one
// place the test target gets back the call shapes of the types that left ProximityKit for
// FernletSocial. Those types kept their names and their APIs when they moved, but an old shape the
// suites were written against, restored for them while the type was still ProximityKit's, follows
// the type here, so `ProximityNamespaceTestBindings.swift` keeps ProximityKit's shapes alone and
// never imports FernletSocial. A shape that builds from FernletSocial's declarations follows them
// here too: the routed type registry's rows are the host's (FernletSocial's `FernletRoutedTypes`,
// every row since plan step A0.5.11), so the registry's and the ack-stage table's shapes, and the
// host doubles' answer for those rows, live in this file.
//
// THE RULE, the same one that file states. A binding restores a call SHAPE, never a value: it passes
// `ProximityNamespace.fernlet`, exactly the value FernletConnections ships and the app hands
// ProximityKit, so a suite that goes through one sees the bytes it always saw, and nothing here may
// pass anything else or compute a label, a row or a name of its own, with one stated exception: the
// recipe-share manager's restored seam initializer, which builds its pair session over the recipe
// profile on its host's own namespace, as the shape it restores (the manager's
// `init(store:makeSession:identity:)`) did and as the production `init(store:)` does. A test that PINS
// a value does not lean on a binding: it names `.fernlet` explicitly, so what it pins is visibly
// Fernlet's.

import FernletConnections
import Foundation
@testable import FernletSocial
@testable import ProximityKit

// MARK: - Presentation strings (A0.3.2)
//
// The hearts copy's first name takes the namespace whose mesh instance-name prefix it hides, last;
// its old shape comes back here with `.fernlet`.

/// The hearts copy's first name in the shape the suites were written against (plan step A0.3.2).
extension PresenceManager {

    /// `firstName(of:in: .fernlet)`. `nonisolated`, as the function it restores is.
    nonisolated static func firstName(of displayName: String) -> String {
        firstName(of: displayName, in: .fernlet)
    }
}

// MARK: - The display-name policy (A0.3.12)
//
// The session message store re-moderates a peer's name under the namespace its caller holds; its
// ingest's old shape, which followed the store to FernletSocial at plan step A0.5.9, comes back here
// with `.fernlet`.

/// The session message store's ingest in the shape the suites were written against (plan step
/// A0.3.12). It inherits the store's main-actor isolation, as the function it restores has.
extension SessionMessageStore {

    /// `receiveIncoming(id:senderFingerprint:senderDisplayName:text:sentAt:seenAt:in: .fernlet)`.
    func receiveIncoming(
        id: UUID, senderFingerprint: String, senderDisplayName: String, text rawText: String,
        sentAt: Date, seenAt: Date
    ) -> Acceptance {
        receiveIncoming(id: id, senderFingerprint: senderFingerprint, senderDisplayName: senderDisplayName,
                        text: rawText, sentAt: sentAt, seenAt: seenAt, in: .fernlet)
    }
}

// MARK: - Record kinds and routed types (A0.3.3; the host's rows since A0.5.9)
//
// ProximityKit's registry is built from the host's rows alone since plan step A0.5.11
// (`init(entries:)`; from A0.5.9 it took them beside resident rows built from the routed types it
// was handed, `increment1(_:hostEntries:)`, until the photo row, the last resident one, left it),
// and its ack-stage projection is the registry's. The two `increment1` shapes the suites were
// written against come back here over Fernlet's host rows, `FernletRoutedTypes.entries`, read off
// `.fernlet`'s `family.vocabulary.routedTypes`, so every spelling keeps its three rows. The
// manifest mint's old shape stays in `ProximityNamespaceTestBindings.swift` and reaches the
// registry shape here within the test module.

/// The shipping registry in the shapes the suites were written against (plan steps A0.3.3, A0.5.9,
/// A0.5.11).
extension MeshRoutedTypeRegistry {

    /// `init(entries:)` over Fernlet's host rows read off `routedTypes`,
    /// `FernletRoutedTypes.entries(routedTypes)`: the registry the engine's `increment1(_:)` built
    /// before the temporary-message row (plan step A0.5.9), the heart row (A0.5.10) and the photo
    /// row (A0.5.11) left it, the engine building `MeshRoutedTypeRegistry(entries:)` over its host's
    /// rows since (S16).
    static func increment1(_ routedTypes: ProximityNamespace.RoutedTypes) -> MeshRoutedTypeRegistry {
        MeshRoutedTypeRegistry(entries: FernletRoutedTypes.entries(routedTypes))
    }

    /// ``increment1(_:)`` over `.fernlet`'s `family.vocabulary.routedTypes`: the registry the retired
    /// `increment1` value held.
    static var increment1: MeshRoutedTypeRegistry {
        increment1(ProximityNamespace.fernlet.family.vocabulary.routedTypes)
    }
}

/// The ack-stage projection in the shapes the suites were written against (plan steps A0.3.3,
/// A0.5.9).
extension MeshRoutedAckStageTable {

    /// The `finalAck` column of ``MeshRoutedTypeRegistry/increment1(_:)`` over `routedTypes`, keyed by
    /// their tokens: the projection ProximityKit's `increment1(_:)` returned until plan step A0.5.9,
    /// which deleted it (no shipping code called it).
    static func increment1(_ routedTypes: ProximityNamespace.RoutedTypes) -> MeshRoutedAckStageTable {
        MeshRoutedTypeRegistry.increment1(routedTypes).ackStages
    }

    /// ``increment1(_:)`` over `.fernlet`'s `family.vocabulary.routedTypes`: the table the retired
    /// `increment1` value held.
    static var increment1: MeshRoutedAckStageTable {
        increment1(ProximityNamespace.fernlet.family.vocabulary.routedTypes)
    }
}

// MARK: - The chat's message budget (A0.5.2, A0.5.9)
//
// The text arm counts its per-origin budget against the delivery's `(mesh, origin)` key since plan
// step A0.5.2; the cells were written against the manifest form the mesh manager kept for them, which
// comes back here with the budget at plan step A0.5.9.

/// The chat's per-origin message budget in the manifest shape the cells were written against. It
/// inherits the chat's main-actor isolation, as the function it restores has.
extension MeshSessionChat {

    /// `allowIncomingRoutedText(_:from: MeshRoutedOriginQuotaKey(manifest))`: the item's signed
    /// `(mesh, origin)` key, the one the delivery the engine builds carries.
    func allowIncomingRoutedText(_ messageID: UUID, from manifest: MeshRoutedManifest) -> Bool {
        allowIncomingRoutedText(messageID, from: MeshRoutedOriginQuotaKey(manifest))
    }
}

// MARK: - The host's routed-type rows (A0.5.9)
//
// `ProximityHost.meshRoutedTypeEntries` has no default: which routed types a host's features carry is
// the host's declaration, and the app's store answers Fernlet's rows. The test target's host doubles
// were written against a manager whose registry held Fernlet's three rows, and that answer comes back
// here, once, for every double in this target: Fernlet's host rows over the double's OWN namespace's
// routed types, so a double of another namespace declares its rows under its own tokens. A protocol
// extension supplies a requirement only to the conformances its module can see, so this one is
// invisible to the app module: `FernletStore`'s conformance there answers for itself, and does.

/// The routed-type rows the test target's host doubles hand a manager (plan step A0.5.9). It inherits
/// the protocol's main-actor isolation, as the requirement it answers has.
extension ProximityHost {

    /// `FernletRoutedTypes.entries(proximityNamespace.family.vocabulary.routedTypes)`: Fernlet's host
    /// rows under the double's own namespace.
    var meshRoutedTypeEntries: [MeshRoutedTypeEntry] {
        FernletRoutedTypes.entries(proximityNamespace.family.vocabulary.routedTypes)
    }
}

// MARK: - The recipe-share manager's pair session (plan step A0.7)
//
// The recipe-share manager left ProximityKit for FernletSocial at plan step A0.7.3, its mechanism
// staying behind as ProximityKit's `ProximityPairSession`, which owns the radio, the identity and every
// test seam the suites drive. The manager's seam initializer and its seams come back here, each a
// forwarder to the session's own, so the suites keep the spelling they were written against. The
// initializer is THE RULE's one stated exception: it builds the pair session over FernletConnections'
// recipe profile on the host's OWN namespace, as `init(store:)` does, which is not `.fernlet` when the
// host is foreign. A golden that pins a value builds the session explicitly instead.

/// The recipe-share manager in the shapes the suites were written against (plan step A0.7.3). It
/// inherits the manager's main-actor isolation, as the members it restores had.
extension ProximityRecipeShareManager {

    /// The seam the suites were written against: the manager over a radio of the test's and an
    /// identity of its own, through the pair session that owns both, under the recipe profile on the
    /// host's own namespace, exactly as `init(store:)` builds it.
    convenience init(
        store: any ProximityHost, makeSession: (() -> any ProximityPairRadioSession)?,
        identity: IdentityService? = nil
    ) {
        self.init(pairSession: ProximityPairSession(
            host: store, profile: .recipeShare(in: store.proximityNamespace),
            makeRadio: makeSession, identity: identity))
    }

    /// `pairSession.makeRetainedConnectionCoordinatorForTesting(peer:transport:ranging:)`.
    func makeRetainedConnectionCoordinatorForTesting(
        peer: PeerHandle, transport: any PeerTransport, ranging: any RangingProvider
    ) -> ProximityCoordinator {
        pairSession.makeRetainedConnectionCoordinatorForTesting(peer: peer, transport: transport, ranging: ranging)
    }

    /// `pairSession.radioForTesting`.
    var radioForTesting: any ProximityPairRadioSession { pairSession.radioForTesting }

    /// `pairSession.connectionCountForTesting`.
    var connectionCountForTesting: Int { pairSession.connectionCountForTesting }

    /// `pairSession.isRunningForTesting`.
    var isRunningForTesting: Bool { pairSession.isRunningForTesting }

    /// `pairSession.markRunningForTesting()`.
    func markRunningForTesting() {
        pairSession.markRunningForTesting()
    }

    /// `pairSession.shouldAcceptDialerForTesting(_:)`.
    func shouldAcceptDialerForTesting(_ peer: PeerHandle) -> Bool {
        pairSession.shouldAcceptDialerForTesting(peer)
    }

    /// `pairSession.resolveDialerForTesting(_:)`.
    func resolveDialerForTesting(_ sessionID: String) -> PeerHandle? {
        pairSession.resolveDialerForTesting(sessionID)
    }

    /// `pairSession.checkCoordinatorStatesForTesting()`.
    func checkCoordinatorStatesForTesting() {
        pairSession.checkCoordinatorStatesForTesting()
    }

    /// `pairSession.transferForTesting`.
    var transferForTesting: ProximityPairTransfer? { pairSession.transferForTesting }

    /// `pairSession.finishShareForTesting(_:token:)`.
    func finishShareForTesting(_ result: ProximityPairSendOutcome.Result, token: UUID?) {
        pairSession.finishShareForTesting(result, token: token)
    }

    /// `pairSession.beginTransferForTesting(recipientID:)`.
    func beginTransferForTesting(recipientID: UUID) {
        pairSession.beginTransferForTesting(recipientID: recipientID)
    }

    /// `pairSession.applyTransferForTesting(_:)`.
    @discardableResult
    func applyTransferForTesting(_ event: ProximityPairTransfer.Event) -> Bool {
        pairSession.applyTransferForTesting(event)
    }

    /// `pairSession.applyTransferForTesting(_:token:)`.
    @discardableResult
    func applyTransferForTesting(_ event: ProximityPairTransfer.Event, token: UUID?) -> Bool {
        pairSession.applyTransferForTesting(event, token: token)
    }

    /// `pairSession.applyDiscoveryGateForTesting(_:)`.
    @discardableResult
    func applyDiscoveryGateForTesting(_ event: ProximityPairDiscoveryGate.Event) -> ProximityPairDiscoveryGate.Verdict {
        pairSession.applyDiscoveryGateForTesting(event)
    }

    /// `pairSession.discoveryInfoForTesting`.
    var discoveryInfoForTesting: [String: String] { pairSession.discoveryInfoForTesting }

    /// `pairSession.shouldAdmitChannel(for:)`.
    func shouldAdmitChannel(for peer: PeerHandle) -> Bool {
        pairSession.shouldAdmitChannel(for: peer)
    }

    /// `pairSession.channelAdmission(for:)`.
    func channelAdmission(for peer: PeerHandle) -> ProximityPairSession.ChannelAdmission {
        pairSession.channelAdmission(for: peer)
    }

    /// `pairSession.sweepParkedConnections(now:)`.
    func sweepParkedConnections(now: Date) {
        pairSession.sweepParkedConnections(now: now)
    }

    /// `pairSession.connectTimeoutSeconds`, read and written.
    var connectTimeoutSeconds: TimeInterval {
        get { pairSession.connectTimeoutSeconds }
        set { pairSession.connectTimeoutSeconds = newValue }
    }
}
