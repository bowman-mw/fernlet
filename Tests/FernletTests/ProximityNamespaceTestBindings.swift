// ProximityNamespaceTestBindings.swift
// FernletTests
//
// ProximityKit plan step A0.2.3 (Docs/Plan-FernletCoach-ProximityKit-2026-10-01.md §4 A0.2): the one
// place the test target gets back the call shapes A0.2 takes out of ProximityKit. ProximityKit offers
// no namespace default, so every API that used to spell Fernlet's bytes for itself now takes the
// host's `ProximityNamespace`. The suites were written against the old shapes; rather than rewrite
// every construction in every suite, each old shape comes back here once, passing Fernlet's value.
//
// THE RULE. A binding restores a call SHAPE, never a value: it passes `ProximityNamespace.fernlet`,
// exactly the value FernletConnections ships and the app hands ProximityKit, so a suite that goes
// through one sees the bytes it always saw, and nothing here may pass anything else or compute a
// label, a row or a name of its own. A test that PINS a value does not lean on a binding: it names
// `.fernlet` explicitly (`IdentityService(namespace: .fernlet)`), so what it pins is visibly
// Fernlet's and still reads correctly once a binding is retired. Later A0.2 commits add their
// bindings to this file, each beside the API it restores.
//
// Where an API takes the namespace's labels rather than the whole namespace (step A0.2.4 on), the
// binding passes `.fernlet` for a `ProximityNamespace.Purposes`: FernletConnections'
// `ProximityNamespace.Purposes.fernlet`, the very value `ProximityNamespace.fernlet.family.purposes`
// holds (ProximityNamespaceGoldenTests pins the two equal).

import FernletConnections
import Foundation
@testable import ProximityKit

// MARK: - IdentityService (A0.2.3)

/// The two `IdentityService` initializers the suites were written against, restored over
/// `init(namespace:keychainService:)` with Fernlet's namespace (plan step A0.2.3).
///
/// A binding restores a call shape, never a value; a test that pins a value names `.fernlet`
/// explicitly instead of calling one of these. Both inherit the class's main-actor isolation, as the
/// initializers they replace had.
extension IdentityService {

    /// `IdentityService(namespace: .fernlet)`: this device's identity on Fernlet's identity service,
    /// the identity the retired argument-less initializer built.
    convenience init() {
        self.init(namespace: .fernlet)
    }

    /// `IdentityService(namespace: .fernlet, keychainService:)`: an identity on a keychain service of
    /// the test's own, the identity the retired `init(keychainService:)` built.
    ///
    /// - Parameter keychainService: The test's own service, usually a throwaway one.
    convenience init(keychainService: String) {
        self.init(namespace: .fernlet, keychainService: keychainService)
    }
}

// MARK: - Signed transcripts I: the canonical bytes (A0.2.4)
//
// The ten `canonicalBytes(for:)` overloads whose domain step A0.2.4 moved onto the namespace, and the
// membership inventory digest's preimage, each restored over its `in purposes:` form with Fernlet's
// labels. The routed, channel-introduction and QR overloads keep their old shape until step A0.2.5.

/// `canonicalBytes(for: envelope, in: .fernlet)`: the identity envelope under Fernlet's labels.
func canonicalBytes(for envelope: FernletIdentityEnvelope) -> Data {
    canonicalBytes(for: envelope, in: .fernlet)
}

/// `canonicalBytes(for: token, in: .fernlet)`: the admission token under Fernlet's labels.
func canonicalBytes(for token: MeshAdmissionToken) -> Data {
    canonicalBytes(for: token, in: .fernlet)
}

/// `canonicalBytes(for: record, in: .fernlet)`: a departure record under Fernlet's labels.
func canonicalBytes(for record: SignedDepartureRecord) -> Data {
    canonicalBytes(for: record, in: .fernlet)
}

/// `canonicalBytes(for: record, in: .fernlet)`: a completed removal under Fernlet's labels.
func canonicalBytes(for record: SignedRemovalRecord) -> Data {
    canonicalBytes(for: record, in: .fernlet)
}

/// `canonicalBytes(for: record, in: .fernlet)`: a termination record under Fernlet's labels.
func canonicalBytes(for record: SignedTerminationRecord) -> Data {
    canonicalBytes(for: record, in: .fernlet)
}

/// `canonicalBytes(for: payload, in: .fernlet)`: a signed inventory digest under Fernlet's labels.
func canonicalBytes(for payload: MeshInventoryDigestPayload) -> Data {
    canonicalBytes(for: payload, in: .fernlet)
}

/// `canonicalBytes(for: payload, in: .fernlet)`: an epoch-heads message under Fernlet's labels.
func canonicalBytes(for payload: MeshEpochHeadsPayload) -> Data {
    canonicalBytes(for: payload, in: .fernlet)
}

/// `canonicalBytes(for: advertisement, in: .fernlet)`: a key advertisement under Fernlet's labels.
func canonicalBytes(for advertisement: SignedKeyAgreementAdvertisement) -> Data {
    canonicalBytes(for: advertisement, in: .fernlet)
}

/// `canonicalBytes(for: proposal, in: .fernlet)`: a removal proposal under Fernlet's labels.
func canonicalBytes(for proposal: SignedRemovalProposal) -> Data {
    canonicalBytes(for: proposal, in: .fernlet)
}

/// `canonicalBytes(for: vote, in: .fernlet)`: a removal vote under Fernlet's labels.
func canonicalBytes(for vote: SignedRemovalVote) -> Data {
    canonicalBytes(for: vote, in: .fernlet)
}

/// `canonicalInventoryDigestBytes(for: identities, in: .fernlet)`: the membership inventory digest's
/// hash preimage under Fernlet's labels.
func canonicalInventoryDigestBytes(for identities: [MeshRecordIdentity]) -> Data {
    canonicalInventoryDigestBytes(for: identities, in: .fernlet)
}

// MARK: - Signed transcripts I: verifiers and helpers (A0.2.4)

/// The verifier initializer the suites were written against, restored over
/// `init(meshID:founderSigningPublicKey:ledger:purposes:)` with Fernlet's labels (plan step A0.2.4).
extension MeshMembershipRecordVerifier {

    /// A verifier keeping Fernlet's labels as its copy, otherwise exactly the retired initializer.
    ///
    /// - Parameters:
    ///   - meshID: The mesh every accepted record must name.
    ///   - founderSigningPublicKey: The key that may bootstrap an admission, if known.
    ///   - ledger: The records to start from.
    init(meshID: UUID, founderSigningPublicKey: Data? = nil, ledger: MeshMembershipLedger = .empty) {
        self.init(meshID: meshID, founderSigningPublicKey: founderSigningPublicKey, ledger: ledger,
                  purposes: .fernlet)
    }
}

/// The joiner's two ledger steps in the shapes the suites were written against, restored over their
/// `in purposes:` forms with Fernlet's labels (plan step A0.2.4).
extension MeshLedgerAdoption {

    /// `bootstrapVerifier(meshID:ownAdmission:in: .fernlet)`.
    static func bootstrapVerifier(meshID: UUID, ownAdmission: SignedAdmissionRecord) -> MeshLedgerAdoptionOutcome {
        bootstrapVerifier(meshID: meshID, ownAdmission: ownAdmission, in: .fernlet)
    }

    /// `adopt(offered:ownAdmission:meshID:in: .fernlet)`.
    static func adopt(
        offered: MeshMembershipLedger, ownAdmission: SignedAdmissionRecord, meshID: UUID
    ) -> MeshLedgerAdoptionOutcome {
        adopt(offered: offered, ownAdmission: ownAdmission, meshID: meshID, in: .fernlet)
    }
}

/// The digest initializer the suites were written against, restored over
/// `init(meshID:ledger:purposes:)` with Fernlet's labels (plan step A0.2.4).
extension MeshInventoryDigest {

    /// The digest of `ledger`, its records hash under Fernlet's labels.
    init(meshID: UUID, ledger: MeshMembershipLedger) {
        self.init(meshID: meshID, ledger: ledger, purposes: .fernlet)
    }
}

/// The token check the suites were written against, restored over its `in purposes:` form with
/// Fernlet's labels (plan step A0.2.4).
extension MeshAdmissionToken {

    /// `verify(joinerSigningPublicKey:expectedMeshID:expectedAdmitterSigningPublicKey:now:in: .fernlet)`.
    func verify(
        joinerSigningPublicKey presentedKey: Data, expectedMeshID: UUID,
        expectedAdmitterSigningPublicKey: Data?, now: Date = Date()
    ) throws {
        try verify(joinerSigningPublicKey: presentedKey, expectedMeshID: expectedMeshID,
                   expectedAdmitterSigningPublicKey: expectedAdmitterSigningPublicKey, now: now, in: .fernlet)
    }
}
