// FernletSocialTestBindings.swift
// FernletTests
//
// ProximityKit plan step A0.4 (Docs/Plan-FernletCoach-ProximityKit-2026-10-01.md §4 A0.4): the one
// place the test target gets back the call shapes of the types that left ProximityKit for
// FernletSocial. Those types kept their names and their APIs when they moved, but an old shape the
// suites were written against, restored for them while the type was still ProximityKit's, follows
// the type here, so `ProximityNamespaceTestBindings.swift` keeps ProximityKit's shapes alone and
// never imports FernletSocial. A shape that builds from FernletSocial's declarations follows them
// here too: since plan step A0.5.9 the routed type registry's rows come partly from the host
// (FernletSocial's `FernletRoutedTypes`), so the registry's and the ack-stage table's shapes, and the
// host doubles' answer for those rows, live in this file.
//
// THE RULE, the same one that file states. A binding restores a call SHAPE, never a value: it passes
// `ProximityNamespace.fernlet`, exactly the value FernletConnections ships and the app hands
// ProximityKit, so a suite that goes through one sees the bytes it always saw, and nothing here may
// pass anything else or compute a label, a row or a name of its own. A test that PINS a value does
// not lean on a binding: it names `.fernlet` explicitly, so what it pins is visibly Fernlet's.

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
// ProximityKit's registry builds its resident rows from the routed types it is handed and takes the
// host's rows beside them (`increment1(_:hostEntries:)`, with no default, since plan step A0.5.9), and
// its ack-stage projection is the registry's. The two `increment1` shapes the suites were written
// against come back here over `.fernlet`'s `family.vocabulary.routedTypes` and Fernlet's host rows,
// `FernletRoutedTypes.entries`, read off the same routed types, so every spelling keeps its three
// rows. The manifest mint's old shape stays in `ProximityNamespaceTestBindings.swift` and reaches the
// registry shape here within the test module.

/// The shipping registry in the shapes the suites were written against (plan steps A0.3.3, A0.5.9).
extension MeshRoutedTypeRegistry {

    /// `increment1(_:hostEntries:)` over `routedTypes` with Fernlet's host rows over the same routed
    /// types, `FernletRoutedTypes.entries(routedTypes)`: the registry the engine's
    /// `increment1(_:)` built before the temporary-message row left it. Distinct from
    /// ProximityKit's function by its labels.
    static func increment1(_ routedTypes: ProximityNamespace.RoutedTypes) -> MeshRoutedTypeRegistry {
        increment1(routedTypes, hostEntries: FernletRoutedTypes.entries(routedTypes))
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
