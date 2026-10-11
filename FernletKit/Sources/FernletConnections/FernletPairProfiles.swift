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
    /// (`family.radios.recipeShare`, `_fernlet-recipe2._udp` / `fernlet-recipe-v1` under `.fernlet`),
    /// the TXT mode `recipe`, and the audit area `recipeShare`: the values the recipe radio and its
    /// manager spelled before the profile existed, byte for byte. Read off the host's own namespace,
    /// as the radio always read its row, so a pair session checking it against that namespace accepts
    /// it. Every value is a frozen token, never localized.
    ///
    /// - Parameter namespace: The host's namespace, whose recipe-share radio row the profile runs on.
    /// - Returns: The recipe profile.
    public static func recipeShare(in namespace: ProximityNamespace) -> ProximityPairProfile {
        ProximityPairProfile(auditArea: "recipeShare", radio: namespace.family.radios.recipeShare,
                             advertisementMode: "recipe")
    }
}
