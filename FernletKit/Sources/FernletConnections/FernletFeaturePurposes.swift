// FernletFeaturePurposes.swift
// FernletConnections
//
// Fernlet's feature labels that ProximityKit's doors consume: the heart dead-drop's and presence's
// pair-secret salts, minted as host feature purposes and declared in `.fernlet`'s family
// (`Purposes.fernlet` passes `feature: .fernlet`), so the namespace's one soundness verdict judges them
// with the 39 protocol labels. One spelling per label on Fernlet's side: a caller of ProximityKit's
// `IdentityService.pairSecret(with:purpose:)` passes these constants, and the namespace declares the
// same values. Each is the twin of a FernletCrypto registry entry, spelled identically, until plan
// step C1 retires the twins: `ProximityNamespaceGoldenTests` holds each pair equal, and
// `FernletFeatureGoldenTests` pins the pair secrets the door derives under them to the known answers
// the heart-drop and presence derivations give.

import ProximityKit

/// Fernlet's feature labels that a ProximityKit door consumes: the two pair-secret salts.
///
/// ProximityKit's `IdentityService.pairSecret(with:purpose:)` derives only under a salt its
/// identity's namespace declares, so each constant is declared in `.fernlet`'s family too
/// (``ProximityNamespace/FeaturePurposes/fernlet``). The spellings are frozen protocol
/// data: a changed byte changes every heart day tag and presence tag a pair derives, and a friend's
/// phone stops recognizing this one. The other feature labels Fernlet's features hand CryptoKit
/// themselves stay FernletCrypto registry entries; no ProximityKit door consumes them.
///
/// `nonisolated` against the module's `defaultIsolation(MainActor.self)`: inert `Sendable` value data,
/// like the namespace that declares it.
public nonisolated enum FernletFeaturePurposes {
    /// The heart dead-drop's pair-secret salt, `fernlet.heartdrop.v1`: the twin of
    /// `FernletCryptoPurpose.KeyDerivation.heartDropPairV1`.
    public nonisolated static let heartDropPairV1 =
        ProximityCryptographicPurpose.featureKeyDerivationSalt("fernlet.heartdrop.v1")
    /// Presence's pair-secret salt, `fernlet.presence.tag.v1`: the twin of
    /// `FernletCryptoPurpose.KeyDerivation.presencePairV1`.
    public nonisolated static let presencePairV1 =
        ProximityCryptographicPurpose.featureKeyDerivationSalt("fernlet.presence.tag.v1")
}

nonisolated extension ProximityNamespace.FeaturePurposes {

    /// The feature salts `.fernlet`'s family declares, in this order: the heart dead-drop's
    /// (`family.purposes.feature.heartDropPairV1`), then presence's
    /// (`family.purposes.feature.presencePairV1`).
    public nonisolated static let fernlet = ProximityNamespace.FeaturePurposes([
        "heartDropPairV1": FernletFeaturePurposes.heartDropPairV1,
        "presencePairV1": FernletFeaturePurposes.presencePairV1
    ])
}
