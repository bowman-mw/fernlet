// FernletProtocolNamespace.swift
// FernletConnections
//
// ProximityKit plan step A0.2.2 (Docs/Plan-FernletCoach-ProximityKit-2026-10-01.md §3.2, §4 A0.2):
// Fernlet's protocol identity as ONE `ProximityNamespace` value, `.fernlet`, spelled from the same
// literals today's code already ships, byte for byte. It lives here and not in ProximityKit because
// the edge runs FernletConnections → ProximityKit: ProximityKit cannot name this module, so it can
// never fall back to Fernlet's identity. Nothing reads `.fernlet` yet; A0.2's later commits hand it
// to ProximityKit's readers one consumer family at a time.
//
// Every literal below is pinned by `ProximityNamespaceGoldenTests`' frozen column, so a change here
// is a wire, keychain or on-disk format change for every device already in the field: it fails that
// suite rather than shipping. `service:` sits directly before each keychain service literal, so the
// discovery regex in `PrivacyWipeCoverageTests.keychainServiceLiterals(in:)` keeps finding all three.

import Foundation
import ProximityKit

// MARK: - The namespace

nonisolated extension ProximityNamespace {

    /// Fernlet's family and the Fernlet app's installation: every byte string by which ProximityKit's
    /// wire, keychain and disk formats identify Fernlet, exactly as today's code spells it.
    ///
    /// Sound by construction (`ProximityNamespaceGoldenTests` pins ``ProximityNamespace/soundness``
    /// as `.sound`). The Fernlet Coach app will pair this ``ProximityNamespace/Family`` with an
    /// installation of its own (plan step C1), so the two apps share one wire and never a key, a
    /// file or a log stream.
    public nonisolated static let fernlet = ProximityNamespace(family: .fernlet, installation: .fernletApp)
}

// MARK: - Family

nonisolated extension ProximityNamespace.Family {

    /// What every app on Fernlet's wire shares: the 39 labels, the three radios and the `fernlet`
    /// QR scheme.
    public nonisolated static let fernlet = ProximityNamespace.Family(
        purposes: .fernlet,
        radios: .fernlet,
        verifyQR: ProximityNamespace.VerifyQR(urlScheme: "fernlet")
    )
}

nonisolated extension ProximityNamespace.Purposes {

    /// Fernlet's 39 domain-separation labels, in FernletCrypto's registry grouping.
    public nonisolated static let fernlet = ProximityNamespace.Purposes(
        signature: .fernlet,
        keyDerivation: .fernlet,
        aead: .fernlet,
        hash: .fernlet
    )
}

nonisolated extension ProximityNamespace.Signature {

    /// The seventeen canonical transcripts, the two verify-QR transcripts and the verify-only legacy
    /// pair: FernletCrypto's 21 signature twins, spelled identically.
    public nonisolated static let fernlet = ProximityNamespace.Signature(
        identityEnvelopeV2: "fernlet.canonical.identity-envelope.v2",
        meshAdmissionTokenV2: "fernlet.canonical.mesh-admission-token.v2",
        meshChannelIntroductionV1: "fernlet.mesh.channel-introduction.v1",
        meshMemberDepartureV1: "fernlet.mesh.member-departure.v1",
        meshMemberRemovalV1: "fernlet.mesh.member-removal.v1",
        meshTerminatedV1: "fernlet.mesh.terminated.v1",
        meshInventoryDigestV1: "fernlet.mesh.inventory-digest.v1",
        meshEpochHeadsV1: "fernlet.mesh.epoch-heads.v1",
        meshRemovalProposalV1: "fernlet.mesh.removal-proposal.v1",
        meshRemovalVoteV1: "fernlet.mesh.removal-vote.v1",
        meshKeyAgreementV1: "fernlet.mesh.key-agreement.v1",
        meshRoutedManifestV1: "fernlet.mesh.routed-manifest.v1",
        meshRoutedChunkV1: "fernlet.mesh.routed-chunk.v1",
        meshCustodyReceiptV1: "fernlet.mesh.custody-receipt.v1",
        meshRecipientReceiptV1: "fernlet.mesh.recipient-receipt.v1",
        meshRoutedInventoryDigestV1: "fernlet.mesh.routed-inventory-digest.v1",
        meshRoutedDrainAnswerV1: "fernlet.mesh.routed-drain-answer.v1",
        proximityQRIdentityV1: "fernlet.verify.qr.v1",
        proximityQRResponseV1: "fernlet.verify.response.v1",
        legacyV1: .accepted(
            identityEnvelopeV1: "fernlet.canonical.identity-envelope.v1",
            meshAdmissionTokenV1: "fernlet.canonical.mesh-admission-token.v1"
        )
    )
}

nonisolated extension ProximityNamespace.KeyDerivation {

    /// The three HKDF salts, the QUIC channel binding's exporter label and the two sealed mesh stores'
    /// column seals.
    public nonisolated static let fernlet = ProximityNamespace.KeyDerivation(
        proximityTransportV1: "fernlet.proximity.v1",
        meshGroupKeyWrapV1: "fernlet.mesh.groupkey.v1",
        meshTLSExporterV1: "fernlet.mesh.tls-exporter.v1",
        meshRoutedContentKeyWrapV1: "fernlet.mesh.routed.content-key.v1",
        meshSessionContextV1: "fernlet.mesh.session-context.v1",
        meshRoutedStoreV1: "fernlet.mesh.routed-store.v1"
    )
}

nonisolated extension ProximityNamespace.AEAD {

    /// The five labels at the front of Fernlet's AEAD authenticated data.
    public nonisolated static let fernlet = ProximityNamespace.AEAD(
        proximityTransportV2: "fernlet.proximity.transport.aead.v2",
        meshGroupKeyWrapV2: "fernlet.mesh.groupkey.wrap.aead.v2",
        meshEncryptedMetadataV2: "fernlet.mesh.encrypted-metadata.aead.v2",
        meshRoutedContentKeyWrapV1: "fernlet.mesh.routed.content-key.wrap.aead.v1",
        meshRoutedItemV1: "fernlet.mesh.routed.item.aead.v1"
    )
}

nonisolated extension ProximityNamespace.Hash {

    /// The six mesh hash domains and the epoch id's domain, the one label FernletCrypto's registry
    /// does not hold (today `MeshEpochBounds.derivationDomain`).
    public nonisolated static let fernlet = ProximityNamespace.Hash(
        meshInventoryDigestV1: "fernlet.mesh.inventory-digest.hash.v1",
        meshRoutedContentV1: "fernlet.mesh.routed-content.hash.v1",
        meshRoutedChunkV1: "fernlet.mesh.routed-chunk.hash.v1",
        meshRoutedChunkIDV1: "fernlet.mesh.routed-chunk-id.hash.v1",
        meshCustodyReceiptIDV1: "fernlet.mesh.custody-receipt-id.hash.v1",
        meshRecipientReceiptIDV1: "fernlet.mesh.recipient-receipt-id.hash.v1",
        meshEpochIDV1: "fernlet.mesh.epoch.v1"
    )
}

nonisolated extension ProximityNamespace.Radios {

    /// The friend mesh, presence and recipe-share radios' Bonjour service types (each declared in
    /// the app's `NSBonjourServices`) and ALPNs, and the mesh heartbeat datagram.
    public nonisolated static let fernlet = ProximityNamespace.Radios(
        mesh: ProximityNamespace.Radio(serviceType: "_fernlet-mesh2._udp", alpn: "fernlet-mesh-v1"),
        presence: ProximityNamespace.Radio(serviceType: "_fernlet-near2._udp", alpn: "fernlet-near-v1"),
        recipeShare: ProximityNamespace.Radio(serviceType: "_fernlet-recipe2._udp", alpn: "fernlet-recipe-v1"),
        meshHeartbeat: Data("fernlet-mesh-heartbeat".utf8)
    )
}

// MARK: - Installation

nonisolated extension ProximityNamespace.Installation {

    /// The Fernlet app's keychain rows, storage names and log subsystem on this device.
    ///
    /// The three keychain services are rows "Delete everything" already accounts for
    /// (`Docs/PrivacyWipeCoverage.md`); each `service:` label sits directly before its literal so the
    /// wipe wall's discovery still sees them here.
    public nonisolated static let fernletApp = ProximityNamespace.Installation(
        keychain: ProximityNamespace.Keychain(
            identity: ProximityNamespace.Keychain.IdentityRows(
                service: "com.fernlet.identity",
                signingPrivateKey: "signingPrivateKey",
                keyAgreementPrivateKey: "keyAgreementPrivateKey",
                signingPublicKeyCache: "signingPublicKeyCache",
                keyAgreementPublicKeyCache: "keyAgreementPublicKeyCache"
            ),
            meshSessionSealKey: ProximityNamespace.Keychain.Row(
                service: "com.fernlet.mesh-session", account: "meshSessionContextKey"
            ),
            meshRoutedSealKey: ProximityNamespace.Keychain.Row(
                service: "com.fernlet.mesh-routed", account: "meshRoutedStoreKey"
            )
        ),
        storage: ProximityNamespace.Storage(
            directoryName: "Fernlet",
            meshSessionContextFileName: "MeshSessionContext.sealed",
            meshRoutedIndexFileName: "MeshRoutedIndex.sealed",
            meshRoutedChunkDirectoryName: "MeshRoutedChunks"
        ),
        logSubsystem: "com.fernlet"
    )
}
