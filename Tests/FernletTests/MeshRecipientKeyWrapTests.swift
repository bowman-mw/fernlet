// MeshRecipientKeyWrapTests.swift
// FernletTests
//
// P5 item 1 (plan §11, invariant §3.3): the per-recipient content-key wrap.
//
// The suite this file is named for walled the wrap's claims: the addressed recipient opens the key
// and nobody else does; a wrap relabelled to another recipient opens for NEITHER of them (the AAD
// binds the recipient at the key layer, beneath the manifest signature); a wrap bound to one manifest
// opens under no other binding; every wrap draws a fresh ephemeral and nonce; every refusal is named;
// and an unprovisioned identity surfaces its own error rather than a failed open. Since the re-pin to
// ProximityKit 0.1.1 (2026-10-17) that suite, `MeshRecipientKeyWrapTests`, is ProximityKit's package
// suite of the same name and cells, which its own CI runs. This file keeps the one fixture a Fernlet
// suite still reads: the binding perturbation `MeshRoutedItemSealTests` reuses for the item seal's
// three binding fields.

import Foundation
@testable import ProximityKit

/// One binding field per case, each changed alone.
enum MeshRoutedWrapBindingPerturbation: String, CaseIterable, Sendable {
    case itemID, meshID, originFingerprint

    /// `binding` with this one field changed.
    func applied(to binding: MeshRoutedWrapBinding) -> MeshRoutedWrapBinding {
        switch self {
        case .itemID:
            return MeshRoutedWrapBinding(
                meshID: binding.meshID, itemID: MeshMembershipEventFixtures.proposalID,
                originFingerprint: binding.originFingerprint
            )
        case .meshID:
            return MeshRoutedWrapBinding(
                meshID: MeshMembershipEventFixtures.proposalID, itemID: binding.itemID,
                originFingerprint: binding.originFingerprint
            )
        case .originFingerprint:
            return MeshRoutedWrapBinding(meshID: binding.meshID, itemID: binding.itemID, originFingerprint: "fp999")
        }
    }
}
