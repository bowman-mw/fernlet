// FernletPairProfiles.swift
// FernletConnections
//
// Fernlet's connection profiles for ProximityKit's one-to-one pair session (ProximityKit plan step
// A0.7): what makes a kind of pairing Fernlet's own, read off the host's namespace. The recipe profile
// is the recipe-share radio's row, the TXT mode `recipe` and the audit area `recipeShare`, the values
// the recipe radio and its manager spelled before the profile existed, byte for byte; FernletSocial's
// recipe-share manager builds its pair session over it. `FernletFeatureGoldenTests` 31f pins it.

import ProximityKit

nonisolated extension ProximityPairProfile {

    /// Fernlet's recipe-share profile under `namespace`: its recipe-share radio row
    /// (`family.radios.pair`, `_fernlet-recipe2._udp` / `fernlet-recipe-v1` under `.fernlet`),
    /// the TXT mode `recipe`, and the audit area `recipeShare`: the values the recipe radio and its
    /// manager spelled before the profile existed, byte for byte. Read off the host's own namespace,
    /// as the radio always read its row, so a pair session checking it against that namespace accepts
    /// it. Every value is a frozen token, never localized.
    ///
    /// - Parameter namespace: The host's namespace, whose recipe-share radio row the profile runs on.
    /// - Returns: The recipe profile.
    public static func recipeShare(in namespace: ProximityNamespace) -> ProximityPairProfile {
        ProximityPairProfile(auditArea: "recipeShare", radio: namespace.family.radios.pair,
                             advertisementMode: "recipe")
    }
}

nonisolated extension ProximityTapRendezvousProfile {

    /// Fernlet's tap to connect (World Friends, 2026-10-31): the pair radio's row under its own TXT mode
    /// `tap`, so the recipe radio on the same row never dials it, with the audit area `tapConnect` and
    /// Fernlet's two labels for the rendezvous: the card signature `fernlet.tap.card.v1` (length-prefixed)
    /// and the seal salt `fernlet.tap.seal.v1`. All four spellings are frozen wire tokens: a changed byte
    /// and two Fernlets no longer find, open or verify each other.
    public static func tapToConnect(in namespace: ProximityNamespace) -> ProximityTapRendezvousProfile {
        ProximityTapRendezvousProfile(
            pair: ProximityPairProfile(auditArea: "tapConnect", radio: namespace.family.radios.pair,
                                       advertisementMode: "tap"),
            cardSignature: .featureSignature("fernlet.tap.card.v1", framing: .lengthPrefixed),
            sealSalt: .featureKeyDerivationSalt("fernlet.tap.seal.v1")
        )
    }
}
